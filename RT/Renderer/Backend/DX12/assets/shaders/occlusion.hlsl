#include "include/common.hlsl"

struct OcclusionRayPayload
{
	bool visible;
	float hit_distance;
	int start_segment;
	int num_portal_hits;							// how many portals has ray crossed
	PortalHit portal_hits[RT_NUM_PORTAL_HITS];		// list of last portals crossed 
	bool valid_hit;									// Used to control if a ray needs to be retried due to hitting overlapping segment geometry
	int invalid_primitive_hit;						// what invalid primitive id was hit (so we can ignore it when we try again)
};

void TraceOcclusionRay(RayDesc ray, inout OcclusionRayPayload payload, uint2 pixel_pos)
{
#if RT_DISPATCH_RAYS

    TraceRay(g_scene, RAY_FLAG_CULL_BACK_FACING_TRIANGLES | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER,
        ~0, 1, 0, 1, ray, payload);

#elif RT_INLINE_RAYTRACING

    RayQuery<RAY_FLAG_CULL_BACK_FACING_TRIANGLES> ray_query;
	ray_query.TraceRayInline(
		g_scene,
		RAY_FLAG_CULL_BACK_FACING_TRIANGLES,
		~0,
		ray
	);

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
				if (hit_triangle.portal)
				{
					if (tweak.retrace_rays)
					{
						payload.num_portal_hits++;

						int portal_hit_index = payload.num_portal_hits % RT_NUM_PORTAL_HITS;

						payload.portal_hits[portal_hit_index].segment = hit_triangle.segment;
						payload.portal_hits[portal_hit_index].segment_adjacent = hit_triangle.segment_adjacent;
					}
					
					break;  // never commit portal hits
				}

				Material hit_material;

				if (payload.invalid_primitive_hit != primitive_idx) // ignore invalid primitive
				{
					if (!IsHitTransparent(
						ray_query.CandidateInstanceIndex(),
						ray_query.CandidatePrimitiveIndex(),
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
		payload.visible = false;

		if (tweak.retrace_rays && payload.start_segment != -1)
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
					// found the ray crossed a portal into this segment
					hit_score += 10;
					search_segment = payload.portal_hits[search_index].segment;		// update search segment for next loop
					break;
				}
			}
			hit_score += (search_segment == payload.start_segment);  // new segment is start segment
			for (int search_index = 0; search_index < RT_NUM_PORTAL_HITS; search_index++)
			{
				if (payload.portal_hits[search_index].segment_adjacent == search_segment)
				{
					// found the ray crossed a portal into this segment
					hit_score += 1;
					break;
				}
			}

			if (hit_score > 10)
			{
				payload.valid_hit = true;
				payload.visible = false;
			}
			else
			{
				payload.valid_hit = false;

				payload.invalid_primitive_hit = primitive_idx;
			}
			
		}
		payload.hit_distance = hit_distance;
		
		break;
	}
		case COMMITTED_NOTHING:
		{
			payload.valid_hit = true;
			payload.visible = true;
			break;
		}
	}

#endif
}

[shader("anyhit")]
void OcclusionAnyhit(inout OcclusionRayPayload payload, in BuiltInTriangleIntersectionAttributes attr)
{
    Material hit_material;
    if (IsHitTransparent(InstanceIndex(), PrimitiveIndex(), attr.barycentrics, DispatchRaysIndex().xy, hit_material))
    {
        IgnoreHit();
    }

    if (hit_material.flags & RT_MaterialFlag_NoCastingShadow)
    {
        IgnoreHit();
    }
}

[shader("miss")]
void OcclusionMiss(inout OcclusionRayPayload payload)
{
    payload.visible = true;
}
