#ifndef PRIMARY_RAY_HLSLI
#define PRIMARY_RAY_HLSLI

#include "include/common.hlsl"

struct PrimaryRayPayload
{
    uint instance_idx;
    uint primitive_idx;
    float2 barycentrics;
    float hit_distance;
    int start_segment;                  
    int num_portal_hits;                        // how many portals has ray crossed
    PortalHit portal_hits[RT_NUM_PORTAL_HITS];  // list of last portals crossed
    bool valid_hit;                             // Used to control if a ray needs to be retried due to hitting overlapping segment geometry
    int invalid_primitive_hit;                  // what invalid primitive id was hit (so we can ignore it when we try again)
    bool hit_terrain;                           // has the ray hit terrain


};

void TracePrimaryRay(RayDesc ray, inout PrimaryRayPayload payload, uint2 pixel_pos)
{
#if RT_DISPATCH_RAYS

    TraceRay(g_scene, RAY_FLAG_CULL_BACK_FACING_TRIANGLES, ~0, 0, 0, 0, ray, payload);

#elif RT_INLINE_RAYTRACING
    
	RayQuery<RAY_FLAG_CULL_BACK_FACING_TRIANGLES> ray_query;
	ray_query.TraceRayInline(
		g_scene,
		RAY_FLAG_CULL_BACK_FACING_TRIANGLES,
		~0,
		ray
	);
	
	// ---------------------------------------------------------------------------------------------------------------
	// Inline raytracing loop, check for (super-)transparency on surface hit

	while (ray_query.Proceed())
	{
		switch (ray_query.CandidateType())
		{
			case CANDIDATE_NON_OPAQUE_TRIANGLE:
			{
                uint instance_idx = ray_query.CandidateInstanceIndex();
                uint primitive_idx = ray_query.CandidatePrimitiveIndex();

                InstanceData instance_data = g_instance_data_buffer[instance_idx];
                RT_Triangle hit_triangle = GetHitTriangle(instance_data.triangle_buffer_idx, primitive_idx);
                float hit_distance = ray_query.CandidateTriangleRayT();

                // if triangle is portal add to list of portal hits (only do on first pass, we reuse the portal hit data in the event of a second pass.)
                if (hit_triangle.portal )
                {
                    if (tweak.retrace_rays)
                    {
                        payload.num_portal_hits++;

                        int portal_hit_index = payload.num_portal_hits % RT_NUM_PORTAL_HITS;

                        payload.portal_hits[portal_hit_index].segment = hit_triangle.segment;
                        payload.portal_hits[portal_hit_index].segment_adjacent = hit_triangle.segment_adjacent;
                    }
                    break;  // always don't commit portal hits
                }

                // check for terrain hit
                if (hit_triangle.terrain)
                {
                    // store the hit information but don't commit the hit, because if there is level geometry behind... render that first
                    payload.hit_terrain = true;
                    payload.instance_idx = instance_idx;
                    payload.primitive_idx = primitive_idx;
                    payload.barycentrics = ray_query.CandidateTriangleBarycentrics();
                    payload.hit_distance = hit_distance;
                    break;  
                }

				Material hit_material;

				// Check for transparency on hit candidate
                if (payload.invalid_primitive_hit != primitive_idx) // ignore invalid primitive
                {
                    if (!IsHitTransparent(
                        instance_idx,
                        primitive_idx,
                        ray_query.CandidateTriangleBarycentrics(),
                        pixel_pos,
                        hit_material
                    ))
                    {
                        ray_query.CommitNonOpaqueTriangleHit();
                    }
                    else
                    {
                        // count a transparent wall as a portal
                        if (tweak.retrace_rays && hit_triangle.segment != -1)
                        {
                            payload.num_portal_hits++;

                            int portal_hit_index = payload.num_portal_hits % RT_NUM_PORTAL_HITS;

                            payload.portal_hits[portal_hit_index].segment = hit_triangle.segment;
                            payload.portal_hits[portal_hit_index].segment_adjacent = hit_triangle.segment_adjacent;
                        }
                    }
                }
				break;
			}
		}
	}
	
	// ---------------------------------------------------------------------------------------------------------------
	// Determine instance/primitive indices, barycentrics and the hit distance
	// Default values are set for a ray miss

	

	switch (ray_query.CommittedStatus())
	{
		case COMMITTED_TRIANGLE_HIT:
		{
            float hit_distance = ray_query.CommittedRayT();

            uint instance_idx = ray_query.CommittedInstanceIndex();
            uint primitive_idx = ray_query.CommittedPrimitiveIndex();

            InstanceData instance_data = g_instance_data_buffer[instance_idx];
            RT_Triangle hit_triangle = GetHitTriangle(instance_data.triangle_buffer_idx, primitive_idx);
            payload.valid_hit = true;

            if (tweak.retrace_rays)
            {
                int hit_score = 0;

                // if hit triangle is world geo (has segment) retrace the ray back to see if it passed through portals that lead to this triangle.  otherwise hit is invalid
                // checking if it passed through 2 seems to get rid of most of the overlapping geo
                int search_segment = hit_triangle.segment;
                hit_score += (search_segment == -1) * 11;  // always render if not world geo (has segment)
                hit_score += (search_segment == payload.start_segment) * 11;  // triangle is in start segment
                for (int search_index = 0; search_index < RT_NUM_PORTAL_HITS; search_index++)
                {
                    if (payload.portal_hits[search_index].segment_adjacent == search_segment)
                    {
                        hit_score += 10;
                        search_segment = payload.portal_hits[search_index].segment;
                        break;
                    }
                }
                hit_score += (search_segment == payload.start_segment);  // new segment is start segment
                for (int search_index = 0; search_index < RT_NUM_PORTAL_HITS; search_index++)
                {
                    if (payload.portal_hits[search_index].segment_adjacent == search_segment)
                    {
                        hit_score += 1;
                        search_segment = payload.portal_hits[search_index].segment;
                        break;
                    }
                }

                if (hit_score > 10)
                {
                    payload.valid_hit = true;
                    payload.instance_idx = instance_idx;
                    payload.primitive_idx = primitive_idx;
                    payload.barycentrics = ray_query.CommittedTriangleBarycentrics();
                }
                else
                {
                    payload.valid_hit = false;
                    payload.invalid_primitive_hit = primitive_idx;
                }
            }
            else
            {
                payload.valid_hit = true;
                payload.instance_idx = instance_idx;
                payload.primitive_idx = primitive_idx;
                payload.barycentrics = ray_query.CommittedTriangleBarycentrics();
            }
            payload.hit_distance = hit_distance;

            break;
		}
		// We do not need this case because we initialize the values by default to be as if the ray missed
		case COMMITTED_NOTHING:
		{
			
            payload.valid_hit = true;   // a miss is still a valid result
                                        
            // Missed level geo... check also missed terrain along the way
            if (!payload.hit_terrain)
            {
                payload.instance_idx = ~0;
                payload.primitive_idx = ~0;
                payload.barycentrics = float2(0.0, 0.0);
                payload.hit_distance = RT_RAY_T_MAX;
            }
			break;
		}
	}

#endif
}

struct HitGeometry
{
    InstanceData instance_data;
    RT_Triangle hit_triangle;
    uint material_index;
    float3 albedo;
    float3 emissive;
    float3 world_p;
    float2 normal;
    float depth;
    float2 motion;
    float3 view_dir;
    float metallic;
    float roughness;
    uint2 vis_prim;
    float2 vis_bary;
};

void GetHitGeometryFromRay(RayDesc ray,
    uint instance_index, uint primitive_index, float2 barycentrics, float hit_distance,
    uint recursion_depth, int2 pixel_pos, int2 render_dim, inout HitGeometry OUT,bool do_parallax)
{
    // -------------------------------------------------------------------------------------
    // Determine gbuffer hit world direction value

    OUT.view_dir = ray.Direction;

    // -------------------------------------------------------------------------------------
    // Determine gbuffer visibility values

    OUT.vis_prim = uint2(instance_index, primitive_index);
    OUT.vis_bary = barycentrics;

    if (HasHitGeometry(OUT.vis_prim))
    {
        // Get instance data and hit triangle
        OUT.instance_data = g_instance_data_buffer[instance_index];
        OUT.hit_triangle = GetHitTriangle(OUT.instance_data.triangle_buffer_idx, primitive_index);

        // -------------------------------------------------------------------------------------
        // Set up hit material

        float2 uv = (float2)0;
		float3 interpolated_normal = (float3)0;
		float3 tangent = (float3)0;
        GetHitMaterialAndUVs(OUT.instance_data, OUT.hit_triangle, barycentrics, OUT.material_index, uv, interpolated_normal, tangent);
        Material hit_material = g_materials[OUT.material_index];

        // ==========================================================================
        // parallax mapping
        // ==========================================================================
        if (tweak.enable_parallax_mapping && do_parallax)
        {
            Texture2D tex_height = GetTextureFromIndex(hit_material.height_index);

            float3 bitangent = cross(normalize(tangent), normalize(interpolated_normal)) * OUT.hit_triangle.tangent0.w;

            float3x3 rayTBN = float3x3(normalize(tangent.xyz), normalize(bitangent), normalize(interpolated_normal));

            float3 viewDir = normalize(mul(rayTBN, normalize(ray.Direction.xyz)));

            //Steep Parallax
            const float minLayers = 8.0;
            const float maxLayers = 64.0;

            // reduce the number of layers by angle (if we are looking straight at the surface we don't need as many layers)
            float numLayers = lerp(maxLayers, minLayers, max(dot(float3(0.0, 0.0, 1.0), viewDir), 0.0));

            float layerDepth = 1.0 / numLayers;

            float currentLayerDepth = 0.5;  // start the search in the middle of the height map.
            float2 currentUV = uv;
            float currentDepthMapValue = (tex_height.SampleLevel(g_sampler_linear_wrap, currentUV, 0).r);

            float prevLayerDepth = 0;
            float2 prevUV = (float2)0;
            float prevDepthMapValue = 0;

            // check to see if layerdepth is less than depthmapvalue.  If so the parallax should pop out, otherwise it should recess in.  
            // In other words popout will control the direction we search for the correct layerdepth
            bool popout = currentLayerDepth < currentDepthMapValue;

            float2 P = viewDir.xy * 0.2;  // search down

            if (popout)  // reverse search to up.
            {
                P *= -1.0;
                layerDepth *= -1.0;
            }

            float2 deltaUV = (P / numLayers);

            while (currentLayerDepth < currentDepthMapValue == popout)  // if we were originally below depthmapvalue... see if we are now above, if we were above depthmapvalue... see if we are now below.
            {
                prevUV = currentUV;
                prevDepthMapValue = currentDepthMapValue;
                prevLayerDepth = currentLayerDepth;

                currentUV += deltaUV;
                currentDepthMapValue = (tex_height.SampleLevel(g_sampler_linear_wrap, currentUV, 0).r);
                currentLayerDepth -= layerDepth;
            }

            // Occlusion Pass 
            float currentDepthDiff = currentLayerDepth - currentDepthMapValue;
            float prevDepthDiff = prevDepthMapValue - prevLayerDepth;
            float totalDepthDiff = currentDepthDiff + prevDepthDiff;

            float weight = prevDepthDiff / totalDepthDiff;

            uv = prevUV + (deltaUV * weight);
        }

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

            float3 normal = interpolated_normal;

            // -------------------------------------------------------------------------------------
            // Compute texture gradients using ray cones to sample textures anisotropically

            float3 triangle_pos_world[3] = { OUT.hit_triangle.pos0, OUT.hit_triangle.pos1, OUT.hit_triangle.pos2 };
            float3 interpolated_pos_world = GetHitAttribute(triangle_pos_world, barycentrics);
            interpolated_pos_world = mul(to_world, float4(interpolated_pos_world, 1)).xyz;
            triangle_pos_world[0] = mul(to_world, float4(triangle_pos_world[0], 1)).xyz;
            triangle_pos_world[1] = mul(to_world, float4(triangle_pos_world[1], 1)).xyz;
            triangle_pos_world[2] = mul(to_world, float4(triangle_pos_world[2], 1)).xyz;

            float3 interpolated_normal_world = normalize(mul(to_world_no_translate, interpolated_normal));

            float2 triangle_uv[3] = { OUT.hit_triangle.uv0, OUT.hit_triangle.uv1, OUT.hit_triangle.uv2 };
            float half_cone_angle = 0;

            if (recursion_depth == 0)
            {
                RayDesc ray_x = GetRayDesc(pixel_pos + uint2(1, 0), render_dim);
                RayDesc ray_y = GetRayDesc(pixel_pos + uint2(0, 1), render_dim);
                half_cone_angle = sqrt(1.0 - square(min(dot(ray.Direction, ray_x.Direction), dot(ray.Direction, ray_y.Direction))));
            }
            else
            {
                half_cone_angle = hit_distance * tweak.secondary_bounce_bias + img_roughness[pixel_pos].r * tweak.secondary_bounce_bias;
            }

            float2 tex_gradient1, tex_gradient2;
            ComputeTextureGradientRayCone(ray.Direction, hit_distance * half_cone_angle, barycentrics,
                interpolated_pos_world, interpolated_normal_world, triangle_pos_world, triangle_uv, tex_gradient1, tex_gradient2);

            // Calculate normal from normal map
            if (tweak.enable_normal_maps)
            {
                
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
            
            OUT.depth = hit_distance;

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
