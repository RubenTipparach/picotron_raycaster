--[[pod_format="raw"]]

--[[
  Raycaster Rendering Module

  Handles wall rendering using column-based raycasting with tline3d.
  Each wall segment is rendered by projecting to screen space and drawing
  vertical textured columns with proper perspective correction.
]]

local Config = include("config.lua")
local Raycaster = {}

-- Performance tracking
Raycaster.columns_drawn = 0
Raycaster.floor_spans_drawn = 0
Raycaster.ceiling_spans_drawn = 0

--[[
  Disable the color table (used after rendering to restore normal colors for UI)
]]
function Raycaster.disable_colortable()
    poke(0x550b, 0x00)  -- Disable color table
end

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
        local screen_x = Config.SCREEN_CENTER_X + (cx / cz) * fov
        local screen_y = Config.SCREEN_CENTER_Y - (cy / cz) * fov
        return {x = screen_x, y = screen_y, z = cz}
    end

    -- Get all 4 corners in camera space
    -- Use actual vertex Y coordinates for floor height
    local cx1, cy1_bottom, cz1 = to_camera_space(v1.x, v1.y, v1.z)
    local _, cy1_top, _ = to_camera_space(v1.x, v1.y + wall_height, v1.z)
    local cx2, cy2_bottom, cz2 = to_camera_space(v2.x, v2.y, v2.z)
    local _, cy2_top, _ = to_camera_space(v2.x, v2.y + wall_height, v2.z)

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

-- Wall columns buffer for batched rendering
-- Format: sprite, x1, y1, x2, y2, u1*w1, v1*w1, u2*w2, v2*w2, w1, w2
local wall_columns = userdata("f64", 11, Config.MAX_WALL_COLUMNS)
local wall_column_count = 0

--[[
  Render walls using column-based rendering with tline3d
  Properly handles frustum clipping to generate visible geometry

  @param map: map data with walls and vertices
  @param player: player object with position and rotation
  @param wall_sprite: sprite index for wall texture
]]
function Raycaster.render_walls(map, player, wall_sprite, fog_start, fog_end)
    Raycaster.columns_drawn = 0  -- Reset counter
    wall_column_count = 0  -- Reset batch counter

    local fov = Config.FOV
    local near_plane = Config.NEAR_PLANE

    -- Fog parameters (default values if not provided)
    fog_start = fog_start or 10
    fog_end = fog_end or 20

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
            local texture_size = Config.TEXTURE_SIZE

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

                    -- Calculate V coordinates using world-space ray intersection
                    -- This handles perspective-correct clipping when wall extends off-screen
                    local v_top = 0
                    local v_bottom = texture_size

                    -- If wall top extends above screen (y_top < 0), find correct V
                    if y_top < 0 then
                        -- Cast ray from camera through top edge of screen (y=0) at this x column
                        -- Ray direction in camera space: (x_cam, y_cam, z_cam)
                        -- Screen y=0 corresponds to y_cam = (0 - screen_center_y) * (z / fov)
                        local screen_y_target = 0
                        local y_cam_direction = (screen_y_target - Config.SCREEN_CENTER_Y) / fov

                        -- Find where this ray intersects the wall plane at depth z
                        -- World Y at screen edge = player.y - y_cam_direction * z
                        local world_y_at_edge = player.y - y_cam_direction * z

                        -- V coordinate is based on world Y position (0 to wall.height maps to texture_size to 0)
                        -- V=0 is top of texture (at Y=wall.height), V=texture_size is bottom (at Y=0)
                        v_top = (wall.height - world_y_at_edge) / wall.height * texture_size
                        y_top = 0
                    end

                    -- If wall bottom extends below screen (y_bottom > 269), find correct V
                    if y_bottom > 269 then
                        -- Cast ray from camera through bottom edge of screen (y=269)
                        local screen_y_target = 269
                        local y_cam_direction = (screen_y_target - Config.SCREEN_CENTER_Y) / fov

                        -- World Y at screen edge
                        local world_y_at_edge = player.y - y_cam_direction * z

                        -- V coordinate based on world Y
                        v_bottom = (wall.height - world_y_at_edge) / wall.height * texture_size
                        y_bottom = 269
                    end

                    -- Add vertical column to batch buffer
                    -- Both U and V need to be multiplied by w for perspective correction
                    if y_bottom > y_top and y_top < Config.SCREEN_HEIGHT and y_bottom > 0 then
                        Raycaster.columns_drawn = Raycaster.columns_drawn + 1

                        -- Add to batch buffer
                        local offset = wall_column_count * 11
                        wall_columns[offset + 0] = wall_sprite
                        wall_columns[offset + 1] = x
                        wall_columns[offset + 2] = y_top
                        wall_columns[offset + 3] = x
                        wall_columns[offset + 4] = y_bottom
                        wall_columns[offset + 5] = u * w
                        wall_columns[offset + 6] = v_top * w
                        wall_columns[offset + 7] = u * w
                        wall_columns[offset + 8] = v_bottom * w
                        wall_columns[offset + 9] = w
                        wall_columns[offset + 10] = w

                        wall_column_count = wall_column_count + 1

                        -- Flush batch if buffer is full
                        if wall_column_count >= Config.MAX_WALL_COLUMNS then
                            tline3d(wall_columns, 0, wall_column_count)
                            wall_column_count = 0
                        end
                    end
                end  -- end depth test
            end  -- end x loop
        end  -- end quad loop

        ::continue::  -- Label for backface culling skip
    end  -- end wall loop

    -- Flush remaining wall columns
    if wall_column_count > 0 then
        tline3d(wall_columns, 0, wall_column_count)
    end
end

--[[
  Raycast floors using Mode 7 style approach
  For each scanline, calculate depth and draw with linear UV interpolation
  This is how SNES Mode 7 and classic Doom did floors/ceilings
  @param player: player object with position and rotation
  @param sprite: sprite index to use
  @param plane_height: y-coordinate of the plane (0 for floor, WALL_HEIGHT for ceiling)
  @param uv_scale: UV scale factor
  @param texture_size: texture size in pixels
  @param y_start: starting screen y coordinate
  @param y_end: ending screen y coordinate
]]
local function raycast_plane(player, sprite, plane_height, uv_scale, texture_size, y_start, y_end)
    local fov = Config.FOV
    local screen_center_x = Config.SCREEN_CENTER_X
    local screen_center_y = Config.SCREEN_CENTER_Y

    local cos_yaw = cos(player.angle)
    local sin_yaw = sin(player.angle)
    local cos_pitch = cos(player.pitch)
    local sin_pitch = sin(player.pitch)

    -- Camera direction vector (forward) - MUST match player movement in main.lua
    -- forward_x = sin(player.angle), forward_z = cos(player.angle)
    local cam_dir_x = sin_yaw
    local cam_dir_z = cos_yaw

    -- Camera plane vector (perpendicular to direction, defines FOV)
    -- Picotron uses 0-1 rotation (not radians!)
    -- Rotating direction by +0.25 (90° right): (sin(a), cos(a)) -> (sin(a+0.25), cos(a+0.25)) = (cos(a), -sin(a))
    -- Rotating direction by -0.25 (90° left):  (sin(a), cos(a)) -> (sin(a-0.25), cos(a-0.25)) = (-cos(a), sin(a))
    -- We want the plane to point to the right (like strafe right), so use +90°
    -- Scale uniformly - multiply by 2 to match the step calculation below (which also uses * 2)
    local plane_x = cos_yaw * 0.66 * 2
    local plane_z = -sin_yaw * 0.66 * 2

    -- For each screen row from y_start to y_end
    for screen_y = y_start, y_end do
        -- Current y position relative to center
        local p = screen_y - screen_center_y

        -- Vertical position of camera (eye height - plane height)
        local pos_z = player.y - plane_height

        -- Horizontal distance from camera to point on ground
        -- This accounts for pitch
        local row_distance = (pos_z * fov) / (p * cos_pitch - fov * sin_pitch)

        -- Skip if behind camera
        if row_distance > 0.01 and row_distance < 100 then
            -- Calculate the step vector for moving along the scanline
            local floor_step_x = row_distance * (plane_x * 2) / 480
            local floor_step_z = row_distance * (plane_z * 2) / 480

            -- Starting position (left edge of screen)
            local floor_x = player.x + row_distance * cam_dir_x - row_distance * plane_x
            local floor_z = player.z + row_distance * cam_dir_z - row_distance * plane_z

            -- Calculate UVs at left edge
            local u_left = floor_x * uv_scale * texture_size
            local v_left = floor_z * uv_scale * texture_size

            -- Calculate UVs at right edge (480 pixels across)
            local floor_x_right = floor_x + floor_step_x * 480
            local floor_z_right = floor_z + floor_step_z * 480
            local u_right = floor_x_right * uv_scale * texture_size
            local v_right = floor_z_right * uv_scale * texture_size

            -- Draw scanline with linear interpolation (no w needed - constant depth per scanline)
            tline3d(sprite, 0, screen_y, 479, screen_y,
                u_left, v_left,
                u_right, v_right)
        end
    end
end

--[[
  Clip a polygon against the near plane
  Returns array of clipped vertices, or empty if fully clipped
]]
local function clip_polygon_near_plane(verts, near_plane)
    if #verts == 0 then
        return {}
    end

    local result = {}

    for i=1,#verts do
        local v0 = verts[i]
        local v1 = verts[(i % #verts) + 1]

        local behind0 = v0.z < near_plane
        local behind1 = v1.z < near_plane

        -- Both in front - add v0
        if not behind0 then
            add(result, v0)
        end

        -- Edge crosses near plane - add intersection point
        if behind0 ~= behind1 then
            local t = (near_plane - v0.z) / (v1.z - v0.z)
            local clipped_z = near_plane
            local clipped_x = v0.x + (v1.x - v0.x) * t
            local clipped_y = v0.y + (v1.y - v0.y) * t
            local clipped_cam_x = v0.cam_x + (v1.cam_x - v0.cam_x) * t
            local clipped_cam_z = v0.cam_z + (v1.cam_z - v0.cam_z) * t

            -- Re-project clipped vertex
            local fov = Config.FOV
            local screen_x = Config.SCREEN_CENTER_X + (clipped_x / clipped_z) * fov
            local screen_y = Config.SCREEN_CENTER_Y - (clipped_y / clipped_z) * fov
            local w = 1 / clipped_z

            add(result, {
                x = screen_x,
                y = screen_y,
                z = clipped_z,
                w = w,
                cam_x = clipped_cam_x,
                cam_z = clipped_cam_z
            })
        end
    end

    return result
end

-- Scanline buffer for textured triangle rendering (shared with walls)
local scanlines = userdata("f64", 11, 270)

-- Helper function to render a textured triangle
-- Uses the same scanline rasterizer as the lounge renderer
local function render_textured_triangle(sprite, vert_data)
    -- Sort vertices by Y coordinate
    vert_data:sort(1)

    local x1, y1, w1, y2, w2, x3, y3, w3 =
        vert_data[0], vert_data[1], vert_data[3],
        vert_data[7], vert_data[9],
        vert_data[12], vert_data[13], vert_data[15]

    -- Get UV coordinates (already multiplied by w)
    local uv1 = vec(vert_data[4], vert_data[5])
    local uv3 = vec(vert_data[16], vert_data[17])

    local t = (y2 - y1) / (y3 - y1)
    local uvd = (uv3 - uv1) * t + uv1
    local v1, v2 =
        vec(sprite, x1, y1, x1, y1, uv1.x, uv1.y, uv1.x, uv1.y, w1, w1),
        vec(
            sprite,
            vert_data[6], y2,
            (x3 - x1) * t + x1, y2,
            vert_data[10], vert_data[11],
            uvd.x, uvd.y,
            w2, (w3 - w1) * t + w1
        )

    local screen_height = Config.SCREEN_HEIGHT
    local start_y = y1 < -1 and -1 or flr(y1)
    local mid_y = y2 < -1 and -1 or y2 > screen_height - 1 and screen_height - 1 or flr(y2)
    local stop_y = (y3 <= screen_height - 1 and flr(y3) or screen_height - 1)

    -- Top half
    local dy = mid_y - start_y
    if dy > 0 then
        local slope = (v2 - v1):div((y2 - y1))
        scanlines:copy(slope * (start_y + 1 - y1) + v1, true, 0, 0, 11)
            :copy(slope, true, 0, 11, 11, 0, 11, dy - 1)
        tline3d(scanlines:add(scanlines, true, 0, 11, 11, 11, 11, dy - 1), 0, dy)
    end

    -- Bottom half
    dy = stop_y - mid_y
    if dy > 0 then
        local slope = (vec(sprite, x3, y3, x3, y3, uv3.x, uv3.y, uv3.x, uv3.y, w3, w3) - v2) / (y3 - y2)
        scanlines:copy(slope * (mid_y + 1 - y2) + v2, true, 0, 0, 11)
            :copy(slope, true, 0, 11, 11, 0, 11, dy - 1)
        tline3d(scanlines:add(scanlines, true, 0, 11, 11, 11, 11, dy - 1), 0, dy)
    end
end

--[[
  Render floor polygons using per-face projection
  Supports multiple floor heights (stairs, ledges, platforms)

  @param map: map data with faces and vertices
  @param player: player object with position and rotation
  @param floor_sprite: sprite index for floor texture
  @param fog_start: distance where fog starts
  @param fog_end: distance where fog is maximum
]]
function Raycaster.render_floors(map, player, floor_sprite, fog_start, fog_end)
    Raycaster.floor_spans_drawn = 0  -- Reset counter

    local texture_size = Config.TEXTURE_SIZE
    local uv_scale = Config.UV_SCALE
    local fov = Config.FOV
    local near_plane = Config.NEAR_PLANE

    -- Precompute camera transform
    local cos_yaw = cos(player.angle)
    local sin_yaw = sin(player.angle)
    local cos_pitch = cos(player.pitch)
    local sin_pitch = sin(player.pitch)

    -- Process each floor face
    for face in all(map.faces) do
        -- Get vertices for this face (use actual Y from OBJ file)
        local face_verts = {}
        for i = 1, #face do
            local v = map.vertices[face[i]]
            add(face_verts, {x = v.x, y = v.y, z = v.z})
        end

        -- Calculate face center for distance culling
        local center_x, center_z = 0, 0
        for v in all(face_verts) do
            center_x = center_x + v.x
            center_z = center_z + v.z
        end
        center_x = center_x / #face_verts
        center_z = center_z / #face_verts

        -- Distance culling
        local dx = center_x - player.x
        local dz = center_z - player.z
        local dist_sq = dx*dx + dz*dz
        if dist_sq > 400 then  -- 20 units distance
            goto continue_face
        end

        -- Transform vertices to camera space
        local camera_space = {}
        for v in all(face_verts) do
            -- World to camera space
            local wx = v.x - player.x
            local wy = v.y - player.y
            local wz = v.z - player.z

            -- Rotate by yaw
            local cx = wx * cos_yaw - wz * sin_yaw
            local cz = wx * sin_yaw + wz * cos_yaw

            -- Rotate by pitch
            local cy = wy * cos_pitch - cz * sin_pitch
            local final_z = wy * sin_pitch + cz * cos_pitch

            -- Calculate UVs
            local u = v.x * uv_scale * texture_size
            local v_coord = v.z * uv_scale * texture_size

            -- Store camera space vertex (even if behind camera, for clipping)
            add(camera_space, {
                x = cx,
                y = cy,
                z = final_z,
                u = u,
                v = v_coord
            })
        end

        -- Clip polygon against near plane
        local projected = {}
        for i = 1, #camera_space do
            local v0 = camera_space[i]
            local v1 = camera_space[(i % #camera_space) + 1]

            local behind0 = v0.z < near_plane
            local behind1 = v1.z < near_plane

            -- Vertex in front - add it
            if not behind0 then
                local inv_z = 1 / v0.z
                local screen_x = Config.SCREEN_CENTER_X + (v0.x * inv_z * fov)
                local screen_y = Config.SCREEN_CENTER_Y - (v0.y * inv_z * fov)

                add(projected, {
                    x = screen_x,
                    y = screen_y,
                    z = v0.z,
                    w = inv_z,
                    u = v0.u,
                    v = v0.v
                })
            end

            -- Edge crosses near plane - add intersection point
            if behind0 ~= behind1 then
                local t = (near_plane - v0.z) / (v1.z - v0.z)
                local clipped_z = near_plane
                local clipped_x = v0.x + (v1.x - v0.x) * t
                local clipped_y = v0.y + (v1.y - v0.y) * t
                local clipped_u = v0.u + (v1.u - v0.u) * t
                local clipped_v = v0.v + (v1.v - v0.v) * t

                -- Project clipped vertex
                local inv_z = 1 / clipped_z
                local screen_x = Config.SCREEN_CENTER_X + (clipped_x * inv_z * fov)
                local screen_y = Config.SCREEN_CENTER_Y - (clipped_y * inv_z * fov)

                add(projected, {
                    x = screen_x,
                    y = screen_y,
                    z = clipped_z,
                    w = inv_z,
                    u = clipped_u,
                    v = clipped_v
                })
            end
        end

        -- Need at least 3 vertices after clipping
        if #projected < 3 then
            goto continue_face
        end

        -- Backface culling (faces pointing away from camera)
        local v0, v1, v2 = projected[1], projected[2], projected[3]
        local cross = (v1.x - v0.x) * (v2.y - v0.y) - (v1.y - v0.y) * (v2.x - v0.x)
        if cross <= 0 then  -- Clockwise = front-facing for floor
            goto continue_face
        end

        -- Render face as triangle fan (works for convex polygons)
        -- Using tline3d to draw textured triangles
        for i = 2, #projected - 1 do
            local p0 = projected[1]
            local p1 = projected[i]
            local p2 = projected[i + 1]

            -- Create userdata for triangle vertices (x, y, z, w, u, v)
            -- Format: 6 values per vertex, 3 vertices = 18 values
            local tri_data = userdata("f64", 6, 3)

            -- Vertex 0
            tri_data[0] = p0.x
            tri_data[1] = p0.y
            tri_data[2] = 0  -- z (screen space, always 0)
            tri_data[3] = p0.w
            tri_data[4] = p0.u * p0.w
            tri_data[5] = p0.v * p0.w

            -- Vertex 1
            tri_data[6] = p1.x
            tri_data[7] = p1.y
            tri_data[8] = 0
            tri_data[9] = p1.w
            tri_data[10] = p1.u * p1.w
            tri_data[11] = p1.v * p1.w

            -- Vertex 2
            tri_data[12] = p2.x
            tri_data[13] = p2.y
            tri_data[14] = 0
            tri_data[15] = p2.w
            tri_data[16] = p2.u * p2.w
            tri_data[17] = p2.v * p2.w

            -- Render triangle using textri helper
            render_textured_triangle(floor_sprite, tri_data)
        end

        Raycaster.floor_spans_drawn = Raycaster.floor_spans_drawn + 1

        ::continue_face::
    end
end

--[[
  Render ceiling polygons using per-face projection
  Supports multiple ceiling heights

  @param map: map data with faces and vertices
  @param player: player object with position and rotation
  @param ceiling_sprite: sprite index for ceiling texture
  @param fog_start: distance where fog starts
  @param fog_end: distance where fog is maximum
]]
function Raycaster.render_ceilings(map, player, ceiling_sprite, fog_start, fog_end)
    Raycaster.ceiling_spans_drawn = 0  -- Reset counter

    local texture_size = Config.TEXTURE_SIZE
    local uv_scale = Config.UV_SCALE
    local fov = Config.FOV
    local near_plane = Config.NEAR_PLANE

    -- Precompute camera transform
    local cos_yaw = cos(player.angle)
    local sin_yaw = sin(player.angle)
    local cos_pitch = cos(player.pitch)
    local sin_pitch = sin(player.pitch)

    -- Process each ceiling face
    for face in all(map.faces) do
        -- Get vertices for this face (ceiling at wall height above floor)
        local face_verts = {}
        for i = 1, #face do
            local v = map.vertices[face[i]]
            -- Ceiling is at floor Y + wall height
            add(face_verts, {x = v.x, y = v.y + Config.WALL_HEIGHT, z = v.z})
        end

        -- Calculate face center for distance culling
        local center_x, center_z = 0, 0
        for v in all(face_verts) do
            center_x = center_x + v.x
            center_z = center_z + v.z
        end
        center_x = center_x / #face_verts
        center_z = center_z / #face_verts

        -- Distance culling
        local dx = center_x - player.x
        local dz = center_z - player.z
        local dist_sq = dx*dx + dz*dz
        if dist_sq > 400 then  -- 20 units distance
            goto continue_face
        end

        -- Transform vertices to camera space
        local camera_space = {}
        for v in all(face_verts) do
            -- World to camera space
            local wx = v.x - player.x
            local wy = v.y - player.y
            local wz = v.z - player.z

            -- Rotate by yaw
            local cx = wx * cos_yaw - wz * sin_yaw
            local cz = wx * sin_yaw + wz * cos_yaw

            -- Rotate by pitch
            local cy = wy * cos_pitch - cz * sin_pitch
            local final_z = wy * sin_pitch + cz * cos_pitch

            -- Calculate UVs
            local u = v.x * uv_scale * texture_size
            local v_coord = v.z * uv_scale * texture_size

            -- Store camera space vertex (even if behind camera, for clipping)
            add(camera_space, {
                x = cx,
                y = cy,
                z = final_z,
                u = u,
                v = v_coord
            })
        end

        -- Clip polygon against near plane
        local projected = {}
        for i = 1, #camera_space do
            local v0 = camera_space[i]
            local v1 = camera_space[(i % #camera_space) + 1]

            local behind0 = v0.z < near_plane
            local behind1 = v1.z < near_plane

            -- Vertex in front - add it
            if not behind0 then
                local inv_z = 1 / v0.z
                local screen_x = Config.SCREEN_CENTER_X + (v0.x * inv_z * fov)
                local screen_y = Config.SCREEN_CENTER_Y - (v0.y * inv_z * fov)

                add(projected, {
                    x = screen_x,
                    y = screen_y,
                    z = v0.z,
                    w = inv_z,
                    u = v0.u,
                    v = v0.v
                })
            end

            -- Edge crosses near plane - add intersection point
            if behind0 ~= behind1 then
                local t = (near_plane - v0.z) / (v1.z - v0.z)
                local clipped_z = near_plane
                local clipped_x = v0.x + (v1.x - v0.x) * t
                local clipped_y = v0.y + (v1.y - v0.y) * t
                local clipped_u = v0.u + (v1.u - v0.u) * t
                local clipped_v = v0.v + (v1.v - v0.v) * t

                -- Project clipped vertex
                local inv_z = 1 / clipped_z
                local screen_x = Config.SCREEN_CENTER_X + (clipped_x * inv_z * fov)
                local screen_y = Config.SCREEN_CENTER_Y - (clipped_y * inv_z * fov)

                add(projected, {
                    x = screen_x,
                    y = screen_y,
                    z = clipped_z,
                    w = inv_z,
                    u = clipped_u,
                    v = clipped_v
                })
            end
        end

        -- Need at least 3 vertices after clipping
        if #projected < 3 then
            goto continue_face
        end

        -- Backface culling (faces pointing away from camera)
        -- For ceiling, we want counter-clockwise winding (opposite of floor)
        local v0, v1, v2 = projected[1], projected[2], projected[3]
        local cross = (v1.x - v0.x) * (v2.y - v0.y) - (v1.y - v0.y) * (v2.x - v0.x)
        if cross >= 0 then  -- Counter-clockwise = back-facing for ceiling
            goto continue_face
        end

        -- Render face as triangle fan (works for convex polygons)
        for i = 2, #projected - 1 do
            local p0 = projected[1]
            local p1 = projected[i]
            local p2 = projected[i + 1]

            -- Create userdata for triangle vertices
            local tri_data = userdata("f64", 6, 3)

            -- Vertex 0
            tri_data[0] = p0.x
            tri_data[1] = p0.y
            tri_data[2] = 0
            tri_data[3] = p0.w
            tri_data[4] = p0.u * p0.w
            tri_data[5] = p0.v * p0.w

            -- Vertex 1
            tri_data[6] = p1.x
            tri_data[7] = p1.y
            tri_data[8] = 0
            tri_data[9] = p1.w
            tri_data[10] = p1.u * p1.w
            tri_data[11] = p1.v * p1.w

            -- Vertex 2
            tri_data[12] = p2.x
            tri_data[13] = p2.y
            tri_data[14] = 0
            tri_data[15] = p2.w
            tri_data[16] = p2.u * p2.w
            tri_data[17] = p2.v * p2.w

            -- Render triangle
            render_textured_triangle(ceiling_sprite, tri_data)
        end

        Raycaster.ceiling_spans_drawn = Raycaster.ceiling_spans_drawn + 1

        ::continue_face::
    end
end

return Raycaster
