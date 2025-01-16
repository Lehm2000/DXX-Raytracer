#include "include/common.hlsl"

struct OcclusionRayPayload
{
	bool visible;
	float hit_distance;
	int num_portal_hits;
	int start_segment;
	PortalHit portal_hits[12];
	bool valid_hit;
	int invalid_primitive_hit;              // what invalid primitive id was hit (so we can ignore it when we try again)
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
					payload.num_portal_hits++;

					int portal_hit_index = payload.num_portal_hits % 12;

					payload.portal_hits[portal_hit_index].segment = hit_triangle.segment;
					payload.portal_hits[portal_hit_index].segment_adjacent = hit_triangle.segment_adjacent;
					payload.portal_hits[portal_hit_index].hit_distance = hit_distance;
					
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
						if (hit_triangle.segment != -1)
						{
							payload.num_portal_hits++;

							int portal_hit_index = payload.num_portal_hits % 12;

							payload.portal_hits[portal_hit_index].segment = hit_triangle.segment;
							payload.portal_hits[portal_hit_index].segment_adjacent = hit_triangle.segment_adjacent;
							payload.portal_hits[portal_hit_index].hit_distance = hit_distance;
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
		payload.visible = true;

		int hit_score = 0;

		// if hit triangle is world geo (has segment) retrace the ray back to see if it passed through portals that lead to this triangle.  otherwise hit is invalid
		int search_segment = hit_triangle.segment;
		hit_score += (search_segment == -1) * 11;  // always render if not world geo (has segment)
		hit_score += (search_segment == payload.start_segment) * 11;  // triangle is in start segment
		for (int search_index = 0; search_index < 12; search_index++)
		{
			if (payload.portal_hits[search_index].segment_adjacent == search_segment)
			{
				//found = true;
				hit_score += 10;
				search_segment = payload.portal_hits[search_index].segment;
				break;
			}
		}
		hit_score += (search_segment == payload.start_segment);  // new segment is start segment
		for (int search_index = 0; search_index < 12; search_index++)
		{
			if (payload.portal_hits[search_index].segment_adjacent == search_segment)
			{
				//found = true;
				hit_score += 1;
				search_segment = payload.portal_hits[search_index].segment;
				break;
			}
		}

		/*// if hit triangle is world geo (belongs to a segment) check the portal hits to see if its segment was the last portal we passed through before getting to it.  otherwise hit is invalid
		if (hit_triangle.segment != -1)
		{
			bool valid_hit = false;
			int search_segment = hit_triangle.segment;
			uint retrace_count = 0;

			while (retrace_count < 2) // retracing back through 2 portals seems to be enough to rid most artifacts
			{
				retrace_count++;

				// check if we have gotten back to the rays origin segment
				if (search_segment == payload.start_segment)
				{
					// we got back to origin, so hit is valid
					break;
				}

				bool found = false;

				// search the portal hits to see if we crossed a portal to get to the current search segment
				for (int search_index = 0; search_index < 12; search_index++)
				{
					if (payload.portal_hits[search_index].segment_adjacent == search_segment)
					{
						found = true;
						search_segment = payload.portal_hits[search_index].segment; // we'll continue the retrace with this segment on the next loop 
						break;
					}
				}

				if (!found)
				{
					// we hit geometry that we didn't cross a portal for.
					payload.valid_hit = false;
					break;
				}

			}
		}*/

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
		payload.hit_distance = hit_distance;

		break;
	}
		case COMMITTED_NOTHING:
		{
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
