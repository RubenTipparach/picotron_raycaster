--[[pod_format="raw"]]

--[[
  Raycaster Rendering Module

  Handles wall rendering using column-based raycasting with tline3d.
  Each wall segment is rendered by projecting to screen space and drawing
  vertical textured columns with proper perspective correction.
]]

local Raycaster = {}

-- Performance tracking
Raycaster.columns_drawn = 0
Raycaster.floor_spans_drawn = 0

--[[
  Clip a wall quad against the view frustum and generate clipped geometry
  Returns array of clipped quads ready for rendering, or empty array if fully clipped
  Each quad has: {bottom1, top1, bottom2, top2, u_start, u_end}
]]
local function clip_wall_quad(player, v1, v2, wall_height, fov, near_plane)
    -- Transform vertices to camera space
    local function to_camera_space(wx, wy, wz)
        local dx = wx - player.x
        local dy = wy - player.y
        local dz = wz - player.z

        -- Rotate by yaw
        local cos_yaw = cos(player.angle)
        local sin_yaw = sin(player.angle)
        local rx = dx * cos_yaw - dz * sin_yaw
        local rz = dx * sin_yaw + dz * cos_yaw

        -- Rotate by pitch
        local cos_pitch = cos(player.pitch)
        local sin_pitch = sin(player.pitch)
        local ry = dy * cos_pitch - rz * sin_pitch
        local final_z = dy * sin_pitch + rz * cos_pitch

        return rx, ry, final_z
    end

    -- Project from camera space to screen space
    local function project_to_screen(cx, cy, cz)
        if cz < near_plane then
            return nil
        end
        local screen_x = 480 / 2 + (cx / cz) * fov
        local screen_y = 270 / 2 - (cy / cz) * fov
        return {x = screen_x, y = screen_y, z = cz}
    end

    -- Get all 4 corners in camera space
    local cx1, cy1_bottom, cz1 = to_camera_space(v1.x, 0, v1.z)
    local _, cy1_top, _ = to_camera_space(v1.x, wall_height, v1.z)
    local cx2, cy2_bottom, cz2 = to_camera_space(v2.x, 0, v2.z)
    local _, cy2_top, _ = to_camera_space(v2.x, wall_height, v2.z)

    -- Clip against near plane (Z axis)
    local u_start = 0
    local u_end = 1

    if cz1 < near_plane and cz2 < near_plane then
        -- Both behind camera
        return {}
    elseif cz1 < near_plane then
        -- Left vertex behind camera - clip it
        local t = (near_plane - cz1) / (cz2 - cz1)
        cx1 = cx1 + (cx2 - cx1) * t
        cy1_bottom = cy1_bottom + (cy2_bottom - cy1_bottom) * t
        cy1_top = cy1_top + (cy2_top - cy1_top) * t
        cz1 = near_plane
        u_start = t  -- UV starts at interpolated position
    elseif cz2 < near_plane then
        -- Right vertex behind camera - clip it
        local t = (near_plane - cz1) / (cz2 - cz1)
        cx2 = cx1 + (cx2 - cx1) * t
        cy2_bottom = cy1_bottom + (cy2_bottom - cy1_bottom) * t
        cy2_top = cy1_top + (cy2_top - cy1_top) * t
        cz2 = near_plane
        u_end = t  -- UV ends at interpolated position
    end

    -- Project clipped vertices to screen
    local bottom1 = project_to_screen(cx1, cy1_bottom, cz1)
    local top1 = project_to_screen(cx1, cy1_top, cz1)
    local bottom2 = project_to_screen(cx2, cy2_bottom, cz2)
    local top2 = project_to_screen(cx2, cy2_top, cz2)

    if not bottom1 or not bottom2 or not top1 or not top2 then
        return {}
    end

    -- Return clipped quad
    return {{
        bottom1 = bottom1,
        top1 = top1,
        bottom2 = bottom2,
        top2 = top2,
        u_start = u_start,
        u_end = u_end
    }}
end

--[[
  Render walls using column-based rendering with tline3d
  Properly handles frustum clipping to generate visible geometry

  @param map: map data with walls and vertices
  @param player: player object with position and rotation
  @param wall_sprite: sprite index for wall texture
]]
function Raycaster.render_walls(map, player, wall_sprite)
    Raycaster.columns_drawn = 0  -- Reset counter

    local fov = 200  -- Match FOV from main
    local near_plane = 0.1

    -- Depth buffer: track closest depth at each X column
    local depth_buffer = {}
    for x = 0, 479 do
        depth_buffer[x] = 99999  -- Initialize to far distance
    end

    -- Render each wall
    for wall in all(map.walls) do
        local v1 = map.vertices[wall.v1]
        local v2 = map.vertices[wall.v2]

        -- Backface culling: use precomputed wall normal
        -- Wall normal was calculated during map load to point inward (toward room center)

        -- Vector from wall midpoint to camera
        local wall_mid_x = (v1.x + v2.x) * 0.5
        local wall_mid_z = (v1.z + v2.z) * 0.5
        local to_camera_x = player.x - wall_mid_x
        local to_camera_z = player.z - wall_mid_z

        -- Dot product: positive = camera on front side, negative = camera on back side
        local dot = wall.normal_x * to_camera_x + wall.normal_z * to_camera_z

        -- Skip if camera is behind wall (dot <= 0 means backface)
        if dot <= 0 then
            goto continue
        end

        -- Clip wall quad against frustum
        local clipped_quads = clip_wall_quad(player, v1, v2, wall.height, fov, near_plane)

        -- Render each clipped quad
        for quad in all(clipped_quads) do
            local bottom1 = quad.bottom1
            local top1 = quad.top1
            local bottom2 = quad.bottom2
            local top2 = quad.top2
            local u_start_clip = quad.u_start
            local u_end_clip = quad.u_end

            -- Each wall segment is exactly 1 texture unit (16x16 pixels)
            -- U goes from 0 to 16 across the width of the segment
            -- V goes from 0 to 16 across the height of the segment
            local texture_size = 32

            -- Find screen X range (left to right)
            -- Use floor for start and ceil for end to ensure we cover all pixels
            local x_start = flr(min(bottom1.x, bottom2.x))
            local x_end = flr(max(bottom1.x, bottom2.x))

            -- Clamp to screen bounds
            x_start = max(0, x_start)
            x_end = min(479, x_end)

            -- Pre-calculate 1/z values for perspective-correct interpolation
            local inv_z1 = 1 / bottom1.z
            local inv_z2 = 1 / bottom2.z

            -- Pre-calculate u/z values for perspective-correct texture interpolation
            local u_over_z1 = u_start_clip * inv_z1
            local u_over_z2 = u_end_clip * inv_z2

            -- Draw vertical columns across the wall
            for x = x_start, x_end do
                -- Calculate interpolation factor (0 to 1) across wall segment in screen space
                local t
                if bottom2.x ~= bottom1.x then
                    t = (x - bottom1.x) / (bottom2.x - bottom1.x)
                else
                    t = 0
                end
                t = mid(0, t, 1)

                -- Interpolate 1/z linearly in screen space (perspective-correct)
                local inv_z = inv_z1 + (inv_z2 - inv_z1) * t
                local z = 1 / inv_z

                -- Depth test: only draw if this is closer than what's already drawn
                if z < depth_buffer[x] then
                    depth_buffer[x] = z  -- Update depth buffer

                    -- w is same as inv_z (1/z) for perspective correction
                    local w = inv_z

                    -- Interpolate u/z linearly, then divide by z to get perspective-correct u
                    local u_over_z = u_over_z1 + (u_over_z2 - u_over_z1) * t
                    local u_t = u_over_z / inv_z  -- Recover perspective-correct u coordinate

                    -- Interpolate Y coordinates (top and bottom of wall)
                    local y_top = top1.y + (top2.y - top1.y) * t
                    local y_bottom = bottom1.y + (bottom2.y - bottom1.y) * t

                    -- Calculate texture U coordinate (using adjusted t for clipping)
                    -- For tline3d with perspective correction, we pass texture coords * w
                    -- tline3d will interpolate and divide by w to get correct perspective
                    local u = u_t * texture_size

                    -- Clip Y coordinates to screen bounds and adjust V accordingly
                    local v_top = 0
                    local v_bottom = texture_size

                    -- If wall extends above screen, clip and adjust V
                    if y_top < 0 then
                        local wall_height = y_bottom - y_top
                        if wall_height > 0 then
                            -- Calculate how much of the texture to skip
                            local clip_ratio = -y_top / wall_height
                            v_top = texture_size * clip_ratio
                        end
                        y_top = 0
                    end

                    -- If wall extends below screen, clip and adjust V
                    if y_bottom > 269 then
                        local wall_height = y_bottom - y_top
                        if wall_height > 0 then
                            -- Calculate how much of the texture to show
                            local visible_ratio = (269 - y_top) / wall_height
                            v_bottom = v_top + texture_size * visible_ratio
                        end
                        y_bottom = 269
                    end

                    -- Draw vertical textured column
                    -- Both U and V need to be multiplied by w for perspective correction
                    if y_bottom > y_top and y_top < 270 and y_bottom > 0 then
                        tline3d(
                            wall_sprite,          -- sprite to sample from
                            x, y_top,             -- top of column (clipped)
                            x, y_bottom,          -- bottom of column (clipped)
                            u * w, v_top * w,     -- texture coord at top (u*w, v*w) for perspective
                            u * w, v_bottom * w,  -- texture coord at bottom (u*w, v*w)
                            w, w                  -- perspective correction (same w for vertical line)
                        )
                        Raycaster.columns_drawn = Raycaster.columns_drawn + 1
                    end
                end  -- end depth test
            end  -- end x loop
        end  -- end quad loop

        ::continue::  -- Label for backface culling skip
    end  -- end wall loop
end

-- Scanline buffer for batch tline3d calls (11 values per scanline × 270 scanlines)
-- Format: sprite, x1, y1, x2, y2, u1*w1, v1*w1, u2*w2, v2*w2, w1, w2
local floor_scanlines = userdata("f64", 11, 270)

--[[
  Render floor polygons using horizontal scanline spans
  Only renders floor where geometry exists (like Doom's visplanes)
  Uses the actual floor faces from the map
  Uses batched tline3d for performance
]]
function Raycaster.render_floors(map, player, floor_sprite)
    Raycaster.floor_spans_drawn = 0  -- Reset counter

    local screen_width = 480
    local screen_height = 270
    local fov = 200
    local near_plane = 0.1
    local floor_height = 0  -- Y coordinate of floor

    -- Scanline batch counter
    local batch_count = 0

    -- Precompute trig values (optimization)
    local cos_yaw = cos(player.angle)
    local sin_yaw = sin(player.angle)
    local cos_pitch = cos(player.pitch)
    local sin_pitch = sin(player.pitch)

    -- Helper: transform world point to camera space
    local function to_camera_space(wx, wy, wz)
        local dx = wx - player.x
        local dy = wy - player.y
        local dz = wz - player.z

        -- Rotate by yaw (using precomputed values)
        local rx = dx * cos_yaw - dz * sin_yaw
        local rz = dx * sin_yaw + dz * cos_yaw

        -- Rotate by pitch (using precomputed values)
        local ry = dy * cos_pitch - rz * sin_pitch
        local final_z = dy * sin_pitch + rz * cos_pitch

        return rx, ry, final_z
    end

    -- Helper: project camera space to screen space
    local function project_to_screen(cx, cy, cz)
        if cz < near_plane then
            return nil
        end
        local screen_x = screen_width / 2 + (cx / cz) * fov
        local screen_y = screen_height / 2 - (cy / cz) * fov
        return {x = screen_x, y = screen_y, z = cz}
    end

    -- Helper: clip polygon against near plane and return clipped vertices
    local function clip_polygon_near_plane(verts)
        local clipped = {}

        for i = 1, #verts do
            local v1 = verts[i]
            local v2 = verts[(i % #verts) + 1]

            local behind1 = v1.cz < near_plane
            local behind2 = v2.cz < near_plane

            if not behind1 then
                -- v1 is in front, add it
                add(clipped, v1)
            end

            -- Check if edge crosses near plane
            if behind1 ~= behind2 then
                -- Interpolate to find intersection point
                local t = (near_plane - v1.cz) / (v2.cz - v1.cz)

                -- Interpolate camera-space coords
                local cx = v1.cx + (v2.cx - v1.cx) * t
                local cy = v1.cy + (v2.cy - v1.cy) * t
                local cz = near_plane

                -- Interpolate world coords
                local wx = v1.wx + (v2.wx - v1.wx) * t
                local wz = v1.wz + (v2.wz - v1.wz) * t

                -- Interpolate UV coords
                local u = v1.u + (v2.u - v1.u) * t
                local v_coord = v1.v + (v2.v - v1.v) * t

                -- Project clipped vertex
                local p = project_to_screen(cx, cy, cz)
                if p then
                    add(clipped, {cx = cx, cy = cy, cz = cz, wx = wx, wz = wz, u = u, v = v_coord, screen = p})
                end
            end
        end

        return clipped
    end

    -- Render each floor face as horizontal spans
    for face in all(map.faces) do
        -- Get all vertices of the floor polygon with world coords
        local floor_verts = {}

        -- First pass: collect vertices and find bounding box for UV mapping
        local min_wx, max_wx = 99999, -99999
        local min_wz, max_wz = 99999, -99999

        for i = 1, #face do
            local v = map.vertices[face[i]]
            min_wx = min(min_wx, v.x)
            max_wx = max(max_wx, v.x)
            min_wz = min(min_wz, v.z)
            max_wz = max(max_wz, v.z)
        end

        -- Calculate quad dimensions for UV mapping
        local quad_width = max_wx - min_wx
        local quad_depth = max_wz - min_wz

        -- Avoid division by zero
        if quad_width < 0.001 then quad_width = 0.001 end
        if quad_depth < 0.001 then quad_depth = 0.001 end

        -- Second pass: transform vertices to camera space with UV coords
        for i = 1, #face do
            local v = map.vertices[face[i]]
            local cx, cy, cz = to_camera_space(v.x, floor_height, v.z)

            -- Calculate NORMALIZED UV coordinates (0-1 range) based on position within quad bounds
            -- This matches how walls use normalized UVs
            local u = (v.x - min_wx) / quad_width
            local v_coord = (v.z - min_wz) / quad_depth

            add(floor_verts, {
                wx = v.x,
                wz = v.z,
                u = u,
                v = v_coord,
                cx = cx,
                cy = cy,
                cz = cz
            })
        end

        -- Clip polygon against near plane
        local clipped_verts = clip_polygon_near_plane(floor_verts)

        -- Skip if polygon is entirely clipped
        if #clipped_verts < 3 then
            goto skip_polygon
        end

        -- Project clipped vertices to screen space
        local projected = {}
        for v in all(clipped_verts) do
            local p = project_to_screen(v.cx, v.cy, v.cz)
            if p then
                add(projected, {
                    cx = v.cx,
                    cy = v.cy,
                    cz = v.cz,
                    wx = v.wx,
                    wz = v.wz,
                    u = v.u,
                    v = v.v,
                    screen = p
                })
            end
        end

        -- Skip if no vertices projected successfully
        if #projected < 3 then
            goto skip_polygon
        end

        -- Find Y range (min and max screen Y) of this polygon
        local min_y = 99999
        local max_y = -99999
        for p in all(projected) do
            if p.screen then
                min_y = min(min_y, p.screen.y)
                max_y = max(max_y, p.screen.y)
            end
        end

        -- Clamp to screen bounds and bottom half only (floor)
        -- Only render if polygon is visible in bottom half
        if max_y >= screen_height / 2 then
            min_y = max(flr(screen_height / 2) + 1, flr(min_y))
            max_y = min(screen_height - 1, flr(max_y))
        else
            goto skip_polygon
        end

            -- Render horizontal spans for this polygon
            for y = min_y, max_y do
                -- Find X intersections with polygon edges at this Y
                local intersections = {}

                for i = 1, #projected do
                    local j = (i % #projected) + 1
                    local p1 = projected[i]
                    local p2 = projected[j]

                    -- Both vertices need screen projections
                    if p1.screen and p2.screen then
                        local y1 = p1.screen.y
                        local y2 = p2.screen.y

                        -- Check if edge crosses this scanline
                        if (y1 <= y and y2 >= y) or (y2 <= y and y1 >= y) then
                            if abs(y2 - y1) > 0.001 then
                                -- Interpolate to find X at this Y
                                local t = (y - y1) / (y2 - y1)
                                t = mid(0, t, 1)

                                local x = p1.screen.x + (p2.screen.x - p1.screen.x) * t

                                -- Perspective-correct depth interpolation:
                                -- We must interpolate 1/z (not z) linearly in screen space
                                local z1 = p1.screen.z
                                local z2 = p2.screen.z
                                local inv_z1 = 1 / z1
                                local inv_z2 = 1 / z2

                                -- Interpolate 1/z linearly in screen space
                                local inv_z = inv_z1 + (inv_z2 - inv_z1) * t
                                local z = 1 / inv_z  -- Recover perspective-correct depth

                                -- Perspective-correct UV interpolation:
                                local u1 = projected[i].u
                                local v1 = projected[i].v
                                local u2 = projected[j].u
                                local v2 = projected[j].v

                                -- Calculate u/z and v/z at endpoints (which equals u * inv_z)
                                local u_over_z1 = u1 * inv_z1
                                local v_over_z1 = v1 * inv_z1
                                local u_over_z2 = u2 * inv_z2
                                local v_over_z2 = v2 * inv_z2

                                -- Interpolate u/z and v/z linearly in screen space
                                local u_over_z = u_over_z1 + (u_over_z2 - u_over_z1) * t
                                local v_over_z = v_over_z1 + (v_over_z2 - v_over_z1) * t

                                -- Store u/z and v/z (not u and v!) for later perspective division
                                add(intersections, {x = x, z = z, u_over_z = u_over_z, v_over_z = v_over_z})
                            end
                        end
                    end
                end

                -- Sort intersections by X
                for i = 1, #intersections - 1 do
                    for j = i + 1, #intersections do
                        if intersections[j].x < intersections[i].x then
                            intersections[i], intersections[j] = intersections[j], intersections[i]
                        end
                    end
                end

                -- Draw spans between pairs of intersections
                for i = 1, #intersections - 1, 2 do
                    if i + 1 <= #intersections then
                        local x_left = flr(intersections[i].x)
                        local x_right = flr(intersections[i + 1].x)

                        -- Clamp to screen bounds
                        x_left = max(0, x_left)
                        x_right = min(screen_width - 1, x_right)

                        if x_right > x_left then
                            -- Get depth at endpoints
                            local z_left = intersections[i].z
                            local z_right = intersections[i + 1].z

                            -- Calculate W values (1/z) for perspective correction
                            local w_left = 1 / z_left
                            local w_right = 1 / z_right

                            -- Get u/z and v/z at endpoints
                            local u_over_z_left = intersections[i].u_over_z
                            local v_over_z_left = intersections[i].v_over_z
                            local u_over_z_right = intersections[i + 1].u_over_z
                            local v_over_z_right = intersections[i + 1].v_over_z

                            -- For tline3d perspective correction (matching wall renderer):
                            -- UVs are normalized (0-1), need to multiply by texture_size
                            -- We have (u_normalized/z), multiply by texture_size to get (u_pixels/z)
                            -- Then multiply by w to get u_pixels*w for tline3d
                            -- u_pixels*w = (u_normalized * texture_size) * w
                            --            = (u_normalized/z) * texture_size * (1/z) * z
                            --            = (u_normalized/z) * texture_size
                            local texture_size = 16

                            -- Calculate u*w and v*w for perspective-correct texture mapping
                            -- This matches the wall renderer pattern
                            local uw_left = u_over_z_left * texture_size
                            local vw_left = v_over_z_left * texture_size
                            local uw_right = u_over_z_right * texture_size
                            local vw_right = v_over_z_right * texture_size

                            -- Add scanline to batch buffer
                            -- Format: sprite, x1, y1, x2, y2, u1*w1, v1*w1, u2*w2, v2*w2, w1, w2
                            local offset = batch_count * 11
                            floor_scanlines[offset + 0] = floor_sprite
                            floor_scanlines[offset + 1] = x_left
                            floor_scanlines[offset + 2] = y
                            floor_scanlines[offset + 3] = x_right
                            floor_scanlines[offset + 4] = y
                            floor_scanlines[offset + 5] = uw_left
                            floor_scanlines[offset + 6] = vw_left
                            floor_scanlines[offset + 7] = uw_right
                            floor_scanlines[offset + 8] = vw_right
                            floor_scanlines[offset + 9] = w_left
                            floor_scanlines[offset + 10] = w_right

                            batch_count = batch_count + 1
                            Raycaster.floor_spans_drawn = Raycaster.floor_spans_drawn + 1

                            -- Flush batch if buffer is full (270 scanlines max)
                            if batch_count >= 270 then
                                tline3d(floor_scanlines, 0, batch_count)
                                batch_count = 0
                            end
                        end
                    end
                end
            end

        ::skip_polygon::  -- Label for early exit
    end

    -- Flush remaining scanlines
    if batch_count > 0 then
        tline3d(floor_scanlines, 0, batch_count)
    end
end

return Raycaster
