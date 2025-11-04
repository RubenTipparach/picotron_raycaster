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
            local clipped_world_x = v0.world_x + (v1.world_x - v0.world_x) * t
            local clipped_world_z = v0.world_z + (v1.world_z - v0.world_z) * t

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
                world_x = clipped_world_x,
                world_z = clipped_world_z,
                cam_x = clipped_x,
                cam_y = clipped_y
            })
        end
    end

    return result
end

--[[
  Render floor for sector polygons using tline3d
  Uses perspective-correct texture mapping for 3D grid effect

  @param map: map data with faces and vertices
  @param player: player object with position and rotation
  @param floor_sprite: sprite index for floor texture
  @param fog_start: distance where fog starts
  @param fog_end: distance where fog is maximum
]]
function Raycaster.render_floors(map, player, floor_sprite, fog_start, fog_end)
    Raycaster.floor_spans_drawn = 0  -- Reset counter

    local fov = Config.FOV
    local near_plane = Config.NEAR_PLANE
    local texture_size = Config.TEXTURE_SIZE

    -- Process each floor polygon
    for face in all(map.faces) do
        -- Transform vertices to camera space
        local cam_verts = {}

        for i=1,#face do
            local v_idx = face[i]
            local v = map.vertices[v_idx]

            -- Transform to camera space
            local dx = v.x - player.x
            local dy = Config.FLOOR_HEIGHT - player.y  -- Floor at configured height
            local dz = v.z - player.z

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

            add(cam_verts, {
                x = rx,
                y = ry,
                z = final_z,
                world_x = v.x,
                world_z = v.z
            })
        end

        -- Clip against near plane
        local clipped_verts = clip_polygon_near_plane(cam_verts, near_plane)

        if #clipped_verts < 3 then
            goto continue_floor
        end

        -- Project clipped vertices to screen
        local screen_verts = {}
        for v in all(clipped_verts) do
            -- If not already projected (from clipping)
            if not v.w then
                local screen_x = Config.SCREEN_CENTER_X + (v.x / v.z) * fov
                local screen_y = Config.SCREEN_CENTER_Y - (v.y / v.z) * fov
                add(screen_verts, {
                    x = screen_x,
                    y = screen_y,
                    z = v.z,
                    w = 1 / v.z,
                    world_x = v.world_x,
                    world_z = v.world_z
                })
            else
                add(screen_verts, v)
            end
        end

        -- Build edge table for scanline rasterization
        local spans = {}

        -- UV scale factor - larger value = smaller tiles
        local uv_scale = Config.UV_SCALE

        -- For each edge of the polygon
        for i=1,#screen_verts do
            local v0 = screen_verts[i]
            local v1 = screen_verts[(i % #screen_verts) + 1]

            local x0, y0 = v0.x, v0.y
            local x1, y1 = v1.x, v1.y
            local w0, w1 = v0.w, v1.w

            -- Scale down UVs for bigger tiles, then multiply by w for clipspace interpolation
            local u0_w = v0.world_x * uv_scale * w0
            local v0_w = v0.world_z * uv_scale * w0
            local u1_w = v1.world_x * uv_scale * w1
            local v1_w = v1.world_z * uv_scale * w1

            -- Ensure y0 < y1
            if y0 > y1 then
                x0, x1 = x1, x0
                y0, y1 = y1, y0
                w0, w1 = w1, w0
                u0_w, u1_w = u1_w, u0_w
                v0_w, v1_w = v1_w, v0_w
            end

            local dy = y1 - y0
            if dy == 0 then
                goto continue_edge
            end

            local cy0 = flr(y0) + 1
            local dx = (x1 - x0) / dy
            local dw = (w1 - w0) / dy
            local du_w = (u1_w - u0_w) / dy
            local dv_w = (v1_w - v0_w) / dy

            -- Starting position adjustment
            local sy = cy0 - y0
            if y0 < 0 then
                sy = 0
                cy0 = 0
            end

            x0 = x0 + sy * dx
            w0 = w0 + sy * dw
            u0_w = u0_w + sy * du_w
            v0_w = v0_w + sy * dv_w

            if y1 > 269 then
                y1 = 269
            end

            -- Rasterize edge
            for y=cy0, flr(y1) do
                if not spans[y] then
                    spans[y] = {}
                end

                add(spans[y], {
                    x = x0,
                    w = w0,
                    u_w = u0_w,
                    v_w = v0_w
                })

                x0 = x0 + dx
                w0 = w0 + dw
                u0_w = u0_w + du_w
                v0_w = v0_w + dv_w
            end

            ::continue_edge::
        end

        -- Fill spans using tline3d
        for y, span_list in pairs(spans) do
            if #span_list >= 2 then
                -- Sort by x coordinate
                for i=1,#span_list-1 do
                    for j=i+1,#span_list do
                        if span_list[j].x < span_list[i].x then
                            local temp = span_list[i]
                            span_list[i] = span_list[j]
                            span_list[j] = temp
                        end
                    end
                end

                -- Fill between pairs
                for i=1,#span_list-1,2 do
                    local left = span_list[i]
                    local right = span_list[i+1]

                    local x_start = flr(left.x)
                    local x_end = flr(right.x)

                    -- Clamp to screen
                    x_start = max(0, x_start)
                    x_end = min(479, x_end)

                    if x_end > x_start then
                        -- UVs are already in clipspace (u*w, v*w)
                        -- Just multiply by texture_size for final coordinates
                        local u0 = left.u_w * texture_size
                        local v0 = left.v_w * texture_size
                        local u1 = right.u_w * texture_size
                        local v1 = right.v_w * texture_size

                        -- Draw horizontal span with tline3d
                        tline3d(
                            floor_sprite,
                            x_start, y,
                            x_end, y,
                            u0, v0,
                            u1, v1,
                            left.w, right.w
                        )

                        Raycaster.floor_spans_drawn = Raycaster.floor_spans_drawn + 1
                    end
                end
            end
        end

        ::continue_floor::
    end
end

--[[
  Render ceiling for sector polygons using tline3d
  Uses perspective-correct texture mapping for 3D grid effect

  @param map: map data with faces and vertices
  @param player: player object with position and rotation
  @param ceiling_sprite: sprite index for ceiling texture
  @param fog_start: distance where fog starts
  @param fog_end: distance where fog is maximum
]]
function Raycaster.render_ceilings(map, player, ceiling_sprite, fog_start, fog_end)
    Raycaster.ceiling_spans_drawn = 0  -- Reset counter

    local fov = Config.FOV
    local near_plane = Config.NEAR_PLANE
    local ceiling_height = Config.CEILING_HEIGHT
    local texture_size = Config.TEXTURE_SIZE

    -- Process each ceiling polygon
    for face in all(map.faces) do
        -- Transform vertices to camera space (same as floor)
        local cam_verts = {}

        for i=1,#face do
            local v_idx = face[i]
            local v = map.vertices[v_idx]

            -- Transform to camera space (same as floor but at ceiling height)
            local dx = v.x - player.x
            local dy = ceiling_height - player.y  -- Ceiling at fixed y=ceiling_height
            local dz = v.z - player.z

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

            add(cam_verts, {
                x = rx,
                y = ry,
                z = final_z,
                world_x = v.x,
                world_z = v.z
            })
        end

        -- Clip against near plane
        local clipped_verts = clip_polygon_near_plane(cam_verts, near_plane)

        if #clipped_verts < 3 then
            goto continue_ceiling
        end

        -- Project clipped vertices to screen (forward order first)
        local screen_verts_temp = {}
        for v in all(clipped_verts) do
            -- If not already projected (from clipping)
            if not v.w then
                local screen_x = Config.SCREEN_CENTER_X + (v.x / v.z) * fov
                local screen_y = Config.SCREEN_CENTER_Y - (v.y / v.z) * fov
                add(screen_verts_temp, {
                    x = screen_x,
                    y = screen_y,
                    z = v.z,
                    w = 1 / v.z,
                    world_x = v.world_x,
                    world_z = v.world_z
                })
            else
                add(screen_verts_temp, v)
            end
        end

        -- Now reverse the order for ceiling winding
        local screen_verts = {}
        for i=#screen_verts_temp,1,-1 do
            add(screen_verts, screen_verts_temp[i])
        end

        -- Build edge table for scanline rasterization
        local spans = {}

        -- UV scale factor - larger value = smaller tiles
        local uv_scale = Config.UV_SCALE

        -- For each edge of the polygon
        for i=1,#screen_verts do
            local v0 = screen_verts[i]
            local v1 = screen_verts[(i % #screen_verts) + 1]

            local x0, y0 = v0.x, v0.y
            local x1, y1 = v1.x, v1.y
            local w0, w1 = v0.w, v1.w

            -- Scale down UVs for bigger tiles, then multiply by w for clipspace interpolation
            local u0_w = v0.world_x * uv_scale * w0
            local v0_w = v0.world_z * uv_scale * w0
            local u1_w = v1.world_x * uv_scale * w1
            local v1_w = v1.world_z * uv_scale * w1

            -- Ensure y0 < y1
            if y0 > y1 then
                x0, x1 = x1, x0
                y0, y1 = y1, y0
                w0, w1 = w1, w0
                u0_w, u1_w = u1_w, u0_w
                v0_w, v1_w = v1_w, v0_w
            end

            local dy = y1 - y0
            if dy == 0 then
                goto continue_ceiling_edge
            end

            local cy0 = flr(y0) + 1
            local dx = (x1 - x0) / dy
            local dw = (w1 - w0) / dy
            local du_w = (u1_w - u0_w) / dy
            local dv_w = (v1_w - v0_w) / dy

            -- Starting position adjustment
            local sy = cy0 - y0
            if y0 < 0 then
                sy = 0
                cy0 = 0
            end

            x0 = x0 + sy * dx
            w0 = w0 + sy * dw
            u0_w = u0_w + sy * du_w
            v0_w = v0_w + sy * dv_w

            if y1 > 269 then
                y1 = 269
            end

            -- Rasterize edge
            for y=cy0, flr(y1) do
                if not spans[y] then
                    spans[y] = {}
                end

                add(spans[y], {
                    x = x0,
                    w = w0,
                    u_w = u0_w,
                    v_w = v0_w
                })

                x0 = x0 + dx
                w0 = w0 + dw
                u0_w = u0_w + du_w
                v0_w = v0_w + dv_w
            end

            ::continue_ceiling_edge::
        end

        -- Fill spans using tline3d
        for y, span_list in pairs(spans) do
            if #span_list >= 2 then
                -- Sort by x coordinate
                for i=1,#span_list-1 do
                    for j=i+1,#span_list do
                        if span_list[j].x < span_list[i].x then
                            local temp = span_list[i]
                            span_list[i] = span_list[j]
                            span_list[j] = temp
                        end
                    end
                end

                -- Fill between pairs
                for i=1,#span_list-1,2 do
                    local left = span_list[i]
                    local right = span_list[i+1]

                    local x_start = flr(left.x)
                    local x_end = flr(right.x)

                    -- Clamp to screen
                    x_start = max(0, x_start)
                    x_end = min(479, x_end)

                    if x_end > x_start then
                        -- UVs are already in clipspace (u*w, v*w)
                        -- Just multiply by texture_size for final coordinates
                        local u0 = left.u_w * texture_size
                        local v0 = left.v_w * texture_size
                        local u1 = right.u_w * texture_size
                        local v1 = right.v_w * texture_size

                        -- Draw horizontal span with tline3d
                        tline3d(
                            ceiling_sprite,
                            x_start, y,
                            x_end, y,
                            u0, v0,
                            u1, v1,
                            left.w, right.w
                        )

                        Raycaster.ceiling_spans_drawn = Raycaster.ceiling_spans_drawn + 1
                    end
                end
            end
        end

        ::continue_ceiling::
    end
end

return Raycaster
