#ifndef PRIMARY_RAY_HLSLI
#define PRIMARY_RAY_HLSLI

#include "include/common.hlsl"

struct PrimaryRayPayload
{
    uint instance_idx;
    uint primitive_idx;
    float2 barycentrics;
    float hit_distance;
};

void TracePrimaryRay(RayDesc ray, inout PrimaryRayPayload payload)
{
    TraceRay(g_scene, RAY_FLAG_CULL_BACK_FACING_TRIANGLES, ~0, 0, 0, 0, ray, payload);
}

struct GeometryRayOutput
{
    InstanceData instance_data;
    RT_Triangle hit_triangle;
    uint material_index;
    float3 albedo;
    float3 emissive;
    float3 world_p; // bullshit because it's not geometry ray output, but it's because in here because this struct is also direct lighting input
    float2 normal;
    float depth;
    float2 motion;
    float3 view_dir;
    float metallic;
    float roughness;
    uint2 vis_prim;
    float2 vis_bary;
};

void GetGeometryDataFromPrimaryRay(RayDesc ray_desc, PrimaryRayPayload ray_payload, uint recursion_depth, inout GeometryRayOutput OUT)
{
    // -------------------------------------------------------------------------------------
    // Determine gbuffer hit world direction value

    OUT.view_dir = ray_desc.Direction;

    // -------------------------------------------------------------------------------------
    // Determine gbuffer visibility values

    OUT.vis_prim = uint2(ray_payload.instance_idx, ray_payload.primitive_idx);
    OUT.vis_bary = ray_payload.barycentrics;

    if (HasHitGeometry(OUT.vis_prim))
    {
        // Get instance data and hit triangle
        OUT.instance_data = g_instance_data_buffer[ray_payload.instance_idx];
        OUT.hit_triangle = GetHitTriangle(OUT.instance_data.triangle_buffer_idx, ray_payload.primitive_idx);

        // -------------------------------------------------------------------------------------
        // Set up hit material

        float2 uv = (float2)0;
        GetHitMaterialAndUVs(OUT.instance_data, OUT.hit_triangle, ray_payload.barycentrics, OUT.material_index, uv);
        Material hit_material = g_materials[OUT.material_index];

        float3 emissive_factor = UnpackRGBE(hit_material.emissive_factor);
		float4 color_mod = UnpackRGBA(OUT.instance_data.material_color)*UnpackRGBA(OUT.hit_triangle.color);

        Texture2D tex_albedo = GetTextureFromIndex(hit_material.albedo_index);

        if (hit_material.flags & RT_MaterialFlag_BlackbodyRadiator)
        {
            // albedo 0, metallic 1 would mean no shading. so this is a nice way to indicate to
            // later passes that this is a blackbody radiator without looking up the material again
            OUT.albedo   = 0;
            OUT.metallic = 1;

			if (tweak.albedo_sample_linear)
			{
                OUT.emissive = tex_albedo.SampleLevel(g_sampler_linear_wrap, uv, 0).rgb;
            }
            else
            {
                OUT.emissive = tex_albedo.SampleLevel(g_sampler_point_wrap, uv, 0).rgb;
            }

			OUT.emissive *= color_mod.rgb;
			OUT.emissive *= emissive_factor;
        }
        else
        {
            Texture2D tex_normal = GetTextureFromIndex(hit_material.normal_index);
            Texture2D tex_metalness = GetTextureFromIndex(hit_material.metalness_index);
            Texture2D tex_roughness = GetTextureFromIndex(hit_material.roughness_index);
            Texture2D tex_emissive = GetTextureFromIndex(hit_material.emissive_index);

            // Get object to world space transform (instance transform) and make 3x3 matrix
            float4x4 to_world = OUT.instance_data.object_to_world;
            float3x3 to_world_no_translate = float3x3(to_world[0].xyz, to_world[1].xyz, to_world[2].xyz);

            // -------------------------------------------------------------------------------------
            // Determine gbuffer normal value

            float3 normals[] =
            {
                OUT.hit_triangle.normal0,
                OUT.hit_triangle.normal1,
                OUT.hit_triangle.normal2,
            };
            float3 interpolated_normal = GetHitAttribute(normals, ray_payload.barycentrics);
            float3 normal = interpolated_normal;

            // -------------------------------------------------------------------------------------
            // Compute texture gradients using ray cones to sample textures anisotropically

            float3 triangle_pos_world[3] = { OUT.hit_triangle.pos0, OUT.hit_triangle.pos1, OUT.hit_triangle.pos2 };
            float3 interpolated_pos_world = GetHitAttribute(triangle_pos_world, ray_payload.barycentrics);
            interpolated_pos_world = mul(to_world, float4(interpolated_pos_world, 1)).xyz;
            triangle_pos_world[0] = mul(to_world, float4(triangle_pos_world[0], 1)).xyz;
            triangle_pos_world[1] = mul(to_world, float4(triangle_pos_world[1], 1)).xyz;
            triangle_pos_world[2] = mul(to_world, float4(triangle_pos_world[2], 1)).xyz;

            float3 interpolated_normal_world = normalize(mul(to_world_no_translate, interpolated_normal));

            float2 triangle_uv[3] = { OUT.hit_triangle.uv0, OUT.hit_triangle.uv1, OUT.hit_triangle.uv2 };
            float half_cone_angle = 0;

            if (recursion_depth == 0)
            {
                RayDesc ray_desc_x = GetRayDesc(DispatchRaysIndex().xy + uint2(1, 0), DispatchRaysDimensions().xy);
                RayDesc ray_desc_y = GetRayDesc(DispatchRaysIndex().xy + uint2(0, 1), DispatchRaysDimensions().xy);
                half_cone_angle = sqrt(1.0 - square(min(dot(ray_desc.Direction, ray_desc_x.Direction), dot(ray_desc.Direction, ray_desc_y.Direction))));
            }
            else
            {
                half_cone_angle = ray_payload.hit_distance * tweak.secondary_bounce_bias + img_roughness[DispatchRaysIndex().xy].r * tweak.secondary_bounce_bias;
            }

            float2 tex_gradient1, tex_gradient2;
            ComputeTextureGradientRayCone(ray_desc.Direction, ray_payload.hit_distance * half_cone_angle, ray_payload.barycentrics,
                interpolated_pos_world, interpolated_normal_world, triangle_pos_world, triangle_uv, tex_gradient1, tex_gradient2);

            // Calculate normal from normal map
            if (tweak.enable_normal_maps)
            {
                float3 tangents[] = {
                    OUT.hit_triangle.tangent0.xyz,
                    OUT.hit_triangle.tangent1.xyz,
                    OUT.hit_triangle.tangent2.xyz,
                };
                float3 tangent = GetHitAttribute(tangents, ray_payload.barycentrics);
                float3 bitangent = cross(interpolated_normal, tangent) * OUT.hit_triangle.tangent0.w;

                // Bring the normal map sample from tangent space to world space
                float3x3 TBN = transpose(float3x3(tangent.xyz, bitangent, interpolated_normal));
                float3 sampled_normal;
                if (tweak.normal_sample_linear)
                {
                    sampled_normal = SampleTextureAnisotropic(tex_normal, g_sampler_linear_wrap, tex_gradient1, tex_gradient2, uv).xyz;
                    //sampled_normal = tex_normal.SampleLevel(g_sampler_linear_wrap, uv, 0).xyz;
                }
                else
                {
                    sampled_normal = SampleTextureAnisotropic(tex_normal, g_sampler_point_wrap, tex_gradient1, tex_gradient2, uv).xyz;
                    //sampled_normal = tex_normal.SampleLevel(g_sampler_point_wrap, uv, 0).xyz;
                }
                sampled_normal = 2.0 * sampled_normal - 1.0;
                sampled_normal = normalize(mul(TBN, sampled_normal));

                normal = sampled_normal;
            }

            // Transform normal to world space
            normal = normalize(mul(to_world_no_translate, normal));

            {
                // Figure out if we have to flip normals. We need to use actual geometric normals for this,
                // not interpolated, because we're concerned with the normal of the actual geometry that is
                // in the acceleration structure. But as a treat, we probably don't need to normalize any
                // of this because we just care about which side of the triangle we are on.

                float3 ab = OUT.hit_triangle.pos1 - OUT.hit_triangle.pos0;
                float3 ac = OUT.hit_triangle.pos2 - OUT.hit_triangle.pos0;
                float3 geometric_normal = cross(ab, ac);

                if (dot(mul(to_world_no_translate, geometric_normal), -OUT.view_dir) < 0)
                {
                    normal = -normal;
                }
            }
            
            OUT.normal = clamp(EncodeNormalOctahedron(normal), 0.0, 1.0);

            // -------------------------------------------------------------------------------------
            // Determine gbuffer depth value
            
            OUT.depth = ray_payload.hit_distance;

            // -------------------------------------------------------------------------------------
            // Determine gbuffer metallic roughness value

			float sampled_metalness;
			float sampled_roughness;
			if (tweak.metallic_roughness_sample_linear)
			{
                sampled_metalness = SampleTextureAnisotropic(tex_metalness, g_sampler_linear_wrap, tex_gradient1, tex_gradient2, uv).r;
                sampled_roughness = SampleTextureAnisotropic(tex_roughness, g_sampler_linear_wrap, tex_gradient1, tex_gradient2, uv).r;
				//sampled_metalness = tex_metalness.SampleLevel(g_sampler_linear_wrap, uv, 0).r;
				//sampled_roughness = tex_roughness.SampleLevel(g_sampler_linear_wrap, uv, 0).r;
			}
			else
			{
                sampled_metalness = SampleTextureAnisotropic(tex_metalness, g_sampler_point_wrap, tex_gradient1, tex_gradient2, uv).r;
                sampled_roughness = SampleTextureAnisotropic(tex_roughness, g_sampler_point_wrap, tex_gradient1, tex_gradient2, uv).r;
				//sampled_metalness = tex_metalness.SampleLevel(g_sampler_point_wrap, uv, 0).r;
				//sampled_roughness = tex_roughness.SampleLevel(g_sampler_point_wrap, uv, 0).r;
			}
            OUT.metallic  = sampled_metalness*hit_material.metalness_factor;
            OUT.roughness = clamp(sampled_roughness*hit_material.roughness_factor, 0.02f, 1.0f);

            if (tweak.override_materials)
            {
                OUT.metallic  = tweak.override_metallic;
                OUT.roughness = tweak.override_roughness;
            }

            // Increase the roughness of secondary bounces to combat fireflies
            // ad-hoc implementation, TODO: learn about path space regularization
            // properly.
            if (tweak.path_space_regularization && recursion_depth > 0)
            {
                OUT.roughness = 1.0; // max(lerp(0.5, 0.2, metallic_roughness.y), metallic_roughness.y);
            }

            // -------------------------------------------------------------------------------------
            // Determine gbuffer albedo value

            if (tweak.albedo_sample_linear)
            {
                OUT.albedo = SampleTextureAnisotropic(tex_albedo, g_sampler_linear_wrap, tex_gradient1, tex_gradient2, uv).rgb;
                //OUT.albedo = tex_albedo.SampleLevel(g_sampler_linear_wrap, uv, 0).xyz;
            }
            else
            {
                OUT.albedo = SampleTextureAnisotropic(tex_albedo, g_sampler_point_wrap, tex_gradient1, tex_gradient2, uv).rgb;
                //OUT.albedo = tex_albedo.SampleLevel(g_sampler_point_wrap, uv, 0).xyz;
            }

            // -----------------------------------------------------------
            // Emissive

            if (tweak.albedo_sample_linear)
            {
                OUT.emissive = SampleTextureAnisotropic(tex_emissive, g_sampler_linear_wrap, tex_gradient1, tex_gradient2, uv).rgb;
                //OUT.emissive = emissive_factor * tex_emissive.SampleLevel(g_sampler_linear_wrap, uv, 0).rgb;
            }
            else
            {
                OUT.emissive = SampleTextureAnisotropic(tex_emissive, g_sampler_point_wrap, tex_gradient1, tex_gradient2, uv).rgb;
                //OUT.emissive = emissive_factor * tex_emissive.SampleLevel(g_sampler_point_wrap, uv, 0).rgb;
            }

            OUT.albedo *= color_mod.rgb;
            OUT.emissive *= color_mod.rgb;
            OUT.emissive *= emissive_factor;
        }
    }
}

#endif /* PRIMARY_RAY_HLSLI */
