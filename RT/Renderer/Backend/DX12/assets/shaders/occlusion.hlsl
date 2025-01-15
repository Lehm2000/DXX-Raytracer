#include "include/common.hlsl"

struct OcclusionRayPayload
{
	bool visible;
	float hit_distance;
	int segment_start;              // what segment did the ray start in.
	int segment_tracker[800];       // used to track path of the ray through the segments, if a ray enters a segment the segment it entered from into will be placed in the coresponding index.  Enabling
									// the ability to trace the ray back.  Normally segments are zero based, but when placed in the array, 1 should be added, as 0 needs to represent no data.
	//int num_portal_hits;
	//PortalHit portal_hits[128];
	bool valid_hit;
	int segment_tracker_result;
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
					payload.segment_tracker[hit_triangle.segment_adjacent] = hit_triangle.segment + 1;
					
					/*if (payload.num_portal_hits < 127)
					{
						payload.num_portal_hits++;
						payload.portal_hits[payload.num_portal_hits - 1].segment = hit_triangle.segment;
						payload.portal_hits[payload.num_portal_hits - 1].segment_adjacent = hit_triangle.segment_adjacent;
						payload.portal_hits[payload.num_portal_hits - 1].hit_distance = hit_distance;
					}*/
					
					break;  // never commit portal hits
				}

				Material hit_material;

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
						payload.segment_tracker[hit_triangle.segment_adjacent] = hit_triangle.segment + 1;
						
						/*if (payload.num_portal_hits < 127)
						{
							payload.num_portal_hits++;
							payload.portal_hits[payload.num_portal_hits].segment = hit_triangle.segment;
							payload.portal_hits[payload.num_portal_hits].segment_adjacent = hit_triangle.segment_adjacent;
							payload.portal_hits[payload.num_portal_hits].hit_distance = hit_distance;
						}*/
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

		//for (int cache_index = 0; cache_index < 800; cache_index++)
		//{
			//payload.segment_tracker_result = payload.segment_tracker[cache_index];
		//}

		// if hit triangle is world geo (has segment) retrace the ray back to see if it passed through portals that lead to this triangle.  otherwise hit is invalid
		//if (hit_triangle.segment != -1)
		//{
			payload.valid_hit = false;

			//bool valid_hit = false;

			// verify ray actually entered the segment this triangle is in
			int search_segment = hit_triangle.segment;

			int score = 0;

			score += (hit_triangle.segment == -1) * 11;					// not level geo, always valid
			score += (search_segment == payload.segment_start) * 11;    // is triangle in same segment as player
			score += (payload.segment_tracker[search_segment] != 0) * 10;    // did the ray enter the segment the triangle is in.
			search_segment = payload.segment_tracker[search_segment] - 1;       // get segment that lead to the previous segment
			score += (search_segment == payload.segment_start);            //   is this second segment the start segment
			score += (payload.segment_tracker[search_segment] != 0);      // did the ray pass through the second segment

			payload.valid_hit = score > 10;

			//bool valid_hit = false;

			// verify ray actually entered the segment this triangle is in
			/*int search_segment = hit_triangle.segment;

			if (search_segment == payload.segment_start)
			{
				payload.valid_hit = true;
			}
			else if (payload.segment_tracker[search_segment] != 0)
			{
				search_segment = payload.segment_tracker[search_segment] - 1;

				if (search_segment == payload.segment_start || payload.segment_tracker[search_segment] != 0)
				{
					payload.valid_hit = true;
				}

			}*/


		//}
		
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
				if (search_segment == payload.portal_hits[0].segment)
				{
					// we got back to origin, so hit is valid
					break;
				}

				bool found = false;

				// search the portal hits to see if we crossed a portal to get to the current search segment
				for (int search_index = 0; search_index < 127; search_index++)
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

		if (payload.valid_hit)
		{
			
			payload.visible = false;
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
