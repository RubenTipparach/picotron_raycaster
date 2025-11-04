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
            local texture_size = 16

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
    end  -- end wall loop
end

--[[
  Render floors using horizontal textured spans
  This is a simplified version - floors drawn as solid color for now
]]
function Raycaster.render_floors()
    -- TODO: Implement floor/ceiling rendering using horizontal tline3d spans
    -- For now, floors are not rendered (showing as sky/void)
end

return Raycaster
