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

-- Occlusion buffer for portal rendering
-- Each column tracks [top_y, bottom_y] of filled region
-- top_y starts at screen height, bottom_y starts at 0
-- As walls are drawn, the range shrinks
local occlusion_buffer = {}

--[[
  Initialize occlusion buffer - all columns fully open
]]
function Raycaster.init_occlusion_buffer()
    for x = 0, Config.SCREEN_WIDTH - 1 do
        occlusion_buffer[x] = {
            top_y = 0,              -- Top of visible region (starts at top of screen)
            bottom_y = Config.SCREEN_HEIGHT - 1  -- Bottom of visible region (starts at bottom)
        }
    end
end

--[[
  Mark a column range as filled by a wall
  @param x: screen column
  @param wall_top_y: top Y of wall
  @param wall_bottom_y: bottom Y of wall
]]
function Raycaster.mark_column_filled(x, wall_top_y, wall_bottom_y)
    if x < 0 or x >= Config.SCREEN_WIDTH then return end

    local col = occlusion_buffer[x]

    -- Clamp wall to current visible range
    wall_top_y = max(wall_top_y, col.top_y)
    wall_bottom_y = min(wall_bottom_y, col.bottom_y)

    -- Update visible range
    -- If wall fills from top, move top_y down
    if wall_top_y <= col.top_y + 1 then
        col.top_y = wall_bottom_y
    end

    -- If wall fills from bottom, move bottom_y up
    if wall_bottom_y >= col.bottom_y - 1 then
        col.bottom_y = wall_top_y
    end
end

--[[
  Check if a column is fully occluded (no visible region left)
  @param x: screen column
  @return true if fully occluded
]]
function Raycaster.is_column_occluded(x)
    if x < 0 or x >= Config.SCREEN_WIDTH then return true end
    local col = occlusion_buffer[x]
    return col.top_y >= col.bottom_y
end

--[[
  Get visible Y range for a column
  @param x: screen column
  @return top_y, bottom_y (or nil if fully occluded)
]]
function Raycaster.get_visible_range(x)
    if x < 0 or x >= Config.SCREEN_WIDTH then return nil end
    local col = occlusion_buffer[x]
    if col.top_y >= col.bottom_y then
        return nil  -- Fully occluded
    end
    return col.top_y, col.bottom_y
end

--[[
  Check if a wall segment (screen X range) is fully occluded
  @param x_start, x_end: screen X range of wall
  @return true if fully occluded
]]
function Raycaster.is_wall_occluded(x_start, x_end)
    -- Clamp to screen bounds
    x_start = max(0, min(Config.SCREEN_WIDTH - 1, x_start))
    x_end = max(0, min(Config.SCREEN_WIDTH - 1, x_end))

    -- Check if all columns in range are occluded
    for x = x_start, x_end do
        if not Raycaster.is_column_occluded(x) then
            return false  -- At least one column is visible
        end
    end

    return true  -- All columns occluded
end

--[[
  Get occlusion statistics for debugging
  @return occluded_count, total_count, percentage
]]
function Raycaster.get_occlusion_stats()
    local occluded = 0
    local total = Config.SCREEN_WIDTH

    for x = 0, Config.SCREEN_WIDTH - 1 do
        if Raycaster.is_column_occluded(x) then
            occluded = occluded + 1
        end
    end

    return occluded, total, (occluded / total) * 100
end

--[[
  Calculate screen-space bounding box for a portal wall
  @param map: map data
  @param player: player object
  @param wall: wall data with v1, v2
  @param sector: sector containing the wall
  @return x_min, x_max, y_min, y_max (or nil if portal is off-screen)
]]
function Raycaster.get_portal_screen_bounds(map, player, wall, sector)
    local v1 = map.vertices[wall.v1]
    local v2 = map.vertices[wall.v2]
    local fov = Config.FOV
    local near_plane = Config.NEAR_PLANE
    local wall_height = sector.ceiling_height - sector.floor_height

    -- Transform to camera space
    local function to_camera_space(wx, wy, wz)
        local dx = wx - player.x
        local dy = wy - player.y
        local dz = wz - player.z

        local cos_yaw = cos(player.angle)
        local sin_yaw = sin(player.angle)
        local rx = dx * cos_yaw - dz * sin_yaw
        local rz = dx * sin_yaw + dz * cos_yaw

        local cos_pitch = cos(player.pitch)
        local sin_pitch = sin(player.pitch)
        local ry = dy * cos_pitch - rz * sin_pitch
        local final_z = dy * sin_pitch + rz * cos_pitch

        return rx, ry, final_z
    end

    -- Get wall corners in camera space
    local cx1, cy1_bottom, cz1 = to_camera_space(v1.x, v1.y, v1.z)
    local _, cy1_top, _ = to_camera_space(v1.x, v1.y + wall_height, v1.z)
    local cx2, cy2_bottom, cz2 = to_camera_space(v2.x, v2.y, v2.z)
    local _, cy2_top, _ = to_camera_space(v2.x, v2.y + wall_height, v2.z)

    -- Check if portal is behind camera
    if cz1 < near_plane and cz2 < near_plane then
        return nil  -- Completely behind camera
    end

    -- Clip to near plane if needed
    if cz1 < near_plane then
        local t = (near_plane - cz1) / (cz2 - cz1)
        cx1 = cx1 + (cx2 - cx1) * t
        cy1_bottom = cy1_bottom + (cy2_bottom - cy1_bottom) * t
        cy1_top = cy1_top + (cy2_top - cy1_top) * t
        cz1 = near_plane
    elseif cz2 < near_plane then
        local t = (near_plane - cz1) / (cz2 - cz1)
        cx2 = cx1 + (cx2 - cx1) * t
        cy2_bottom = cy1_bottom + (cy2_bottom - cy1_bottom) * t
        cy2_top = cy1_top + (cy2_top - cy1_top) * t
        cz2 = near_plane
    end

    -- Project to screen space
    local inv_z1 = 1 / cz1
    local inv_z2 = 1 / cz2

    local x1 = Config.SCREEN_CENTER_X + (cx1 * inv_z1 * fov)
    local x2 = Config.SCREEN_CENTER_X + (cx2 * inv_z2 * fov)

    local y1_bottom = Config.SCREEN_CENTER_Y - (cy1_bottom * inv_z1 * fov)
    local y1_top = Config.SCREEN_CENTER_Y - (cy1_top * inv_z1 * fov)
    local y2_bottom = Config.SCREEN_CENTER_Y - (cy2_bottom * inv_z2 * fov)
    local y2_top = Config.SCREEN_CENTER_Y - (cy2_top * inv_z2 * fov)

    -- Calculate bounding box
    local x_min = flr(min(x1, x2))
    local x_max = flr(max(x1, x2))
    local y_min = flr(min(y1_top, y2_top))
    local y_max = flr(max(y1_bottom, y2_bottom))

    -- Clamp to screen bounds
    x_min = max(0, min(Config.SCREEN_WIDTH - 1, x_min))
    x_max = max(0, min(Config.SCREEN_WIDTH - 1, x_max))
    y_min = max(0, min(Config.SCREEN_HEIGHT - 1, y_min))
    y_max = max(0, min(Config.SCREEN_HEIGHT - 1, y_max))

    return x_min, x_max, y_min, y_max
end

--[[
  Check if a portal is completely occluded by filled columns
  @param x_min, x_max, y_min, y_max: screen-space bounding box
  @return true if portal is fully occluded
]]
function Raycaster.is_portal_occluded(x_min, x_max, y_min, y_max)
    -- Check if all columns in the portal's X range are fully occluded
    -- OR if the visible Y range doesn't overlap with the portal's Y range
    for x = x_min, x_max do
        local top_y, bottom_y = Raycaster.get_visible_range(x)

        if top_y and bottom_y then
            -- Column has visible range - check if it overlaps portal's Y range
            if bottom_y >= y_min and top_y <= y_max then
                return false  -- Found at least one visible pixel in portal area
            end
        end
    end

    return true  -- All columns fully occluded or no overlap with portal
end

--[[
  Check if one bounding box is completely contained within another
  @param inner_x_min, inner_x_max, inner_y_min, inner_y_max: inner box bounds
  @param outer_x_min, outer_x_max, outer_y_min, outer_y_max: outer box bounds
  @return true if inner box is completely contained within outer box
]]
function Raycaster.is_box_contained(inner_x_min, inner_x_max, inner_y_min, inner_y_max,
                                     outer_x_min, outer_x_max, outer_y_min, outer_y_max)
    return inner_x_min >= outer_x_min and
           inner_x_max <= outer_x_max and
           inner_y_min >= outer_y_min and
           inner_y_max <= outer_y_max
end

--[[
  Portal rendering: recursively render visible sectors
  This is the core of Doom-style rendering!

  @param map: map data with sectors
  @param player: player object
  @param start_sector_idx: sector to start rendering from
  @param wall_sprite, floor_sprite, ceiling_sprite: texture sprites
  @param max_depth: maximum recursion depth (default 8)
  @param visited_out: optional table to fill with visited sector indices (for wireframe)
  @param render_walls: whether to render walls (default true)
]]
function Raycaster.render_portals(map, player, start_sector_idx, wall_sprite, floor_sprite, ceiling_sprite, max_depth, visited_out, render_walls)
    max_depth = max_depth or 8
    render_walls = render_walls == nil and true or render_walls  -- Default to true
    local visited = {}  -- Track visited sectors to prevent loops
    local sectors_rendered = 0

    -- Recursive rendering function
    local function render_sector(sector_idx, depth)
        -- Stop if too deep or already visited this sector
        if depth > max_depth or visited[sector_idx] then
            return
        end

        -- Check if entire screen is occluded (early exit optimization)
        -- SKIP this check for player's sector (depth 0) and adjacent sectors (depth 1)
        -- to prevent flickering when crossing portals
        if depth > 1 then
            local all_occluded = true
            for x = 0, Config.SCREEN_WIDTH - 1 do
                if not Raycaster.is_column_occluded(x) then
                    all_occluded = false
                    break
                end
            end
            if all_occluded then
                return
            end
        end

        visited[sector_idx] = true
        sectors_rendered = sectors_rendered + 1
        local sector = map.sectors[sector_idx]

        -- Collect visible walls and calculate depths
        local visible_walls = {}
        local visible_portals = {}

        for wall in all(sector.walls) do
            local v1 = map.vertices[wall.v1]
            local v2 = map.vertices[wall.v2]

            -- Backface culling
            local wall_mid_x = (v1.x + v2.x) * 0.5
            local wall_mid_z = (v1.z + v2.z) * 0.5
            local to_camera_x = player.x - wall_mid_x
            local to_camera_z = player.z - wall_mid_z
            local dot = wall.normal_x * to_camera_x + wall.normal_z * to_camera_z

            -- For adjacent sectors (depth 0), be VERY lenient with backface culling
            -- Use a negative threshold to prevent portals from disappearing when on the border
            local cull_threshold = (depth == 0) and -0.1 or 0

            if dot > cull_threshold then
                -- Wall faces camera (or close enough for adjacent sectors) - calculate depth
                local depth_sq = to_camera_x * to_camera_x + to_camera_z * to_camera_z

                if wall.portal_to then
                    -- Portal - collect for depth sorting and recursion
                    add(visible_walls, {wall = wall, depth = depth_sq, is_portal = true})
                    add(visible_portals, {wall = wall, depth = depth_sq})
                else
                    -- Solid wall - collect for depth sorting
                    add(visible_walls, {wall = wall, depth = depth_sq, is_portal = false})
                end
            end
        end

        -- Render this sector's floor and ceiling FIRST (as background)
        Raycaster.render_sector_floor(map, player, sector, floor_sprite)
        Raycaster.render_sector_ceiling(map, player, sector, ceiling_sprite)

        -- Collect solid wall bounding boxes for portal culling
        -- We need these BEFORE processing portals to check containment
        local solid_wall_boxes = {}
        for wall_data in all(visible_walls) do
            if not wall_data.is_portal then
                local wall = wall_data.wall
                local wx_min, wx_max, wy_min, wy_max = Raycaster.get_portal_screen_bounds(map, player, wall, sector)
                if wx_min then
                    add(solid_wall_boxes, {
                        x_min = wx_min,
                        x_max = wx_max,
                        y_min = wy_min,
                        y_max = wy_max
                    })
                end
            end
        end

        -- Sort portals by depth (BACK-TO-FRONT for Doom-style rendering)
        for i = 2, #visible_portals do
            local key = visible_portals[i]
            local j = i - 1
            while j >= 1 and visible_portals[j].depth < key.depth do  -- Note: < instead of >
                visible_portals[j + 1] = visible_portals[j]
                j = j - 1
            end
            visible_portals[j + 1] = key
        end

        -- Recursively render visible portals FIRST (BACK-TO-FRONT)
        -- This renders far sectors before near sectors (painter's algorithm)
        for portal_data in all(visible_portals) do
            local portal = portal_data.wall
            if portal.portal_to and not visited[portal.portal_to] then
                -- Calculate portal's screen-space bounding box
                local x_min, x_max, y_min, y_max = Raycaster.get_portal_screen_bounds(map, player, portal, sector)

                if x_min then
                    -- ALWAYS render adjacent sectors (depth 0->1) to prevent flickering
                    -- For deeper sectors (depth 2+), apply occlusion culling
                    local should_render = false
                    local next_depth = depth + 1

                    if next_depth <= 1 then
                        -- Player's sector (depth 0) and direct neighbors (depth 1): always render (no culling)
                        should_render = true
                    else
                        -- Check if portal is fully occluded by occlusion buffer
                        local buffer_occluded = Raycaster.is_portal_occluded(x_min, x_max, y_min, y_max)

                        -- Check if portal is contained within any solid wall's bounding box
                        local contained_by_wall = false
                        for wall_box in all(solid_wall_boxes) do
                            if Raycaster.is_box_contained(x_min, x_max, y_min, y_max,
                                                           wall_box.x_min, wall_box.x_max,
                                                           wall_box.y_min, wall_box.y_max) then
                                contained_by_wall = true
                                break
                            end
                        end

                        -- Only recurse if portal is visible and not hidden behind a wall
                        should_render = not buffer_occluded and not contained_by_wall
                    end

                    if should_render then
                        render_sector(portal.portal_to, next_depth)
                    end
                end
            end
        end

        -- Sort walls by depth (BACK-TO-FRONT)
        -- Using insertion sort (efficient for small arrays)
        for i = 2, #visible_walls do
            local key = visible_walls[i]
            local j = i - 1
            while j >= 1 and visible_walls[j].depth < key.depth do  -- Note: < instead of >
                visible_walls[j + 1] = visible_walls[j]
                j = j - 1
            end
            visible_walls[j + 1] = key
        end

        -- Render solid walls LAST (BACK-TO-FRONT order)
        -- This ensures near walls overdraw far walls
        if render_walls then
            for wall_data in all(visible_walls) do
                if not wall_data.is_portal then
                    local wall = wall_data.wall

                    -- Calculate wall's screen-space bounding box for occlusion test
                    local x_min, x_max, y_min, y_max = Raycaster.get_portal_screen_bounds(map, player, wall, sector)

                    -- Only render if wall has at least some visible pixels (not fully occluded)
                    if x_min and not Raycaster.is_portal_occluded(x_min, x_max, y_min, y_max) then
                        Raycaster.render_wall_segment(map, player, wall, sector, wall_sprite)
                    end
                end
            end
        end
    end

    -- Start rendering from player's sector
    if start_sector_idx then
        render_sector(start_sector_idx, 0)
    end

    -- Copy visited sectors to output table if provided
    if visited_out then
        for sector_idx in pairs(visited) do
            visited_out[sector_idx] = true
        end
    end

    return sectors_rendered
end

--[[
  Render a single sector's floor
]]
function Raycaster.render_sector_floor(map, player, sector, floor_sprite)
    -- Use existing floor rendering but only for this sector's face
    local face = sector.floor_face
    local texture_size = Config.TEXTURE_SIZE
    local uv_scale = Config.UV_SCALE
    local fov = Config.FOV
    local near_plane = Config.NEAR_PLANE

    -- Get vertices for this face (use actual Y from OBJ file)
    local face_verts = {}
    for i = 1, #face do
        local v = map.vertices[face[i]]
        add(face_verts, {x = v.x, y = v.y, z = v.z})
    end

    -- Precompute camera transform
    local cos_yaw = cos(player.angle)
    local sin_yaw = sin(player.angle)
    local cos_pitch = cos(player.pitch)
    local sin_pitch = sin(player.pitch)

    -- Transform vertices to camera space
    local camera_space = {}
    for v in all(face_verts) do
        local wx = v.x - player.x
        local wy = v.y - player.y
        local wz = v.z - player.z

        local cx = wx * cos_yaw - wz * sin_yaw
        local cz = wx * sin_yaw + wz * cos_yaw
        local cy = wy * cos_pitch - cz * sin_pitch
        local final_z = wy * sin_pitch + cz * cos_pitch

        local u = v.x * uv_scale * texture_size
        local v_coord = v.z * uv_scale * texture_size

        add(camera_space, {
            x = cx, y = cy, z = final_z,
            u = u, v = v_coord
        })
    end

    -- Clip polygon against near plane
    local projected = {}
    for i = 1, #camera_space do
        local v0 = camera_space[i]
        local v1 = camera_space[(i % #camera_space) + 1]

        if not (v0.z < near_plane) then
            local inv_z = 1 / v0.z
            local screen_x = Config.SCREEN_CENTER_X + (v0.x * inv_z * fov)
            local screen_y = Config.SCREEN_CENTER_Y - (v0.y * inv_z * fov)
            add(projected, {
                x = screen_x, y = screen_y, z = v0.z,
                w = inv_z, u = v0.u, v = v0.v
            })
        end

        if (v0.z < near_plane) ~= (v1.z < near_plane) then
            local t = (near_plane - v0.z) / (v1.z - v0.z)
            local clipped_z = near_plane
            local clipped_x = v0.x + (v1.x - v0.x) * t
            local clipped_y = v0.y + (v1.y - v0.y) * t
            local clipped_u = v0.u + (v1.u - v0.u) * t
            local clipped_v = v0.v + (v1.v - v0.v) * t

            local inv_z = 1 / clipped_z
            local screen_x = Config.SCREEN_CENTER_X + (clipped_x * inv_z * fov)
            local screen_y = Config.SCREEN_CENTER_Y - (clipped_y * inv_z * fov)
            add(projected, {
                x = screen_x, y = screen_y, z = clipped_z,
                w = inv_z, u = clipped_u, v = clipped_v
            })
        end
    end

    if #projected < 3 then return end

    -- Backface culling
    local v0, v1, v2 = projected[1], projected[2], projected[3]
    local cross = (v1.x - v0.x) * (v2.y - v0.y) - (v1.y - v0.y) * (v2.x - v0.x)
    if cross <= 0 then return end

    -- Render as triangle fan (reuse existing helper)
    local render_textured_triangle = Raycaster.render_textured_triangle
    for i = 2, #projected - 1 do
        local p0, p1, p2 = projected[1], projected[i], projected[i + 1]
        local tri_data = userdata("f64", 6, 3)

        tri_data[0], tri_data[1], tri_data[2] = p0.x, p0.y, 0
        tri_data[3], tri_data[4], tri_data[5] = p0.w, p0.u * p0.w, p0.v * p0.w

        tri_data[6], tri_data[7], tri_data[8] = p1.x, p1.y, 0
        tri_data[9], tri_data[10], tri_data[11] = p1.w, p1.u * p1.w, p1.v * p1.w

        tri_data[12], tri_data[13], tri_data[14] = p2.x, p2.y, 0
        tri_data[15], tri_data[16], tri_data[17] = p2.w, p2.u * p2.w, p2.v * p2.w

        render_textured_triangle(floor_sprite, tri_data)
    end
end

--[[
  Render a single sector's ceiling
]]
function Raycaster.render_sector_ceiling(map, player, sector, ceiling_sprite)
    -- Use existing ceiling rendering but only for this sector's face
    local face = sector.floor_face
    local texture_size = Config.TEXTURE_SIZE
    local uv_scale = Config.UV_SCALE
    local fov = Config.FOV
    local near_plane = Config.NEAR_PLANE

    -- Get vertices for this face at ceiling height
    local face_verts = {}
    for i = 1, #face do
        local v = map.vertices[face[i]]
        -- Use ceiling height instead of floor height
        add(face_verts, {x = v.x, y = v.y + sector.ceiling_height, z = v.z})
    end

    -- Precompute camera transform
    local cos_yaw = cos(player.angle)
    local sin_yaw = sin(player.angle)
    local cos_pitch = cos(player.pitch)
    local sin_pitch = sin(player.pitch)

    -- Transform vertices to camera space
    local camera_space = {}
    for v in all(face_verts) do
        local wx = v.x - player.x
        local wy = v.y - player.y
        local wz = v.z - player.z

        local cx = wx * cos_yaw - wz * sin_yaw
        local cz = wx * sin_yaw + wz * cos_yaw
        local cy = wy * cos_pitch - cz * sin_pitch
        local final_z = wy * sin_pitch + cz * cos_pitch

        local u = v.x * uv_scale * texture_size
        local v_coord = v.z * uv_scale * texture_size

        add(camera_space, {
            x = cx, y = cy, z = final_z,
            u = u, v = v_coord
        })
    end

    -- Clip polygon against near plane
    local projected = {}
    for i = 1, #camera_space do
        local v0 = camera_space[i]
        local v1 = camera_space[(i % #camera_space) + 1]

        if not (v0.z < near_plane) then
            local inv_z = 1 / v0.z
            local screen_x = Config.SCREEN_CENTER_X + (v0.x * inv_z * fov)
            local screen_y = Config.SCREEN_CENTER_Y - (v0.y * inv_z * fov)
            add(projected, {
                x = screen_x, y = screen_y, z = v0.z,
                w = inv_z, u = v0.u, v = v0.v
            })
        end

        if (v0.z < near_plane) ~= (v1.z < near_plane) then
            local t = (near_plane - v0.z) / (v1.z - v0.z)
            local clipped_z = near_plane
            local clipped_x = v0.x + (v1.x - v0.x) * t
            local clipped_y = v0.y + (v1.y - v0.y) * t
            local clipped_u = v0.u + (v1.u - v0.u) * t
            local clipped_v = v0.v + (v1.v - v0.v) * t

            local inv_z = 1 / clipped_z
            local screen_x = Config.SCREEN_CENTER_X + (clipped_x * inv_z * fov)
            local screen_y = Config.SCREEN_CENTER_Y - (clipped_y * inv_z * fov)
            add(projected, {
                x = screen_x, y = screen_y, z = clipped_z,
                w = inv_z, u = clipped_u, v = clipped_v
            })
        end
    end

    if #projected < 3 then return end

    -- Backface culling (inverted for ceiling - we see bottom of polygon)
    local v0, v1, v2 = projected[1], projected[2], projected[3]
    local cross = (v1.x - v0.x) * (v2.y - v0.y) - (v1.y - v0.y) * (v2.x - v0.x)
    if cross >= 0 then return end  -- Note: >= instead of <= (inverted)

    -- Render as triangle fan (reuse existing helper)
    local render_textured_triangle = Raycaster.render_textured_triangle
    for i = 2, #projected - 1 do
        local p0, p1, p2 = projected[1], projected[i], projected[i + 1]
        local tri_data = userdata("f64", 6, 3)

        tri_data[0], tri_data[1], tri_data[2] = p0.x, p0.y, 0
        tri_data[3], tri_data[4], tri_data[5] = p0.w, p0.u * p0.w, p0.v * p0.w

        tri_data[6], tri_data[7], tri_data[8] = p1.x, p1.y, 0
        tri_data[9], tri_data[10], tri_data[11] = p1.w, p1.u * p1.w, p1.v * p1.w

        tri_data[12], tri_data[13], tri_data[14] = p2.x, p2.y, 0
        tri_data[15], tri_data[16], tri_data[17] = p2.w, p2.u * p2.w, p2.v * p2.w

        render_textured_triangle(ceiling_sprite, tri_data)
    end
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

--[[
  Render a single wall segment
  Extracted from render_walls() for per-wall rendering in portal system
]]
function Raycaster.render_wall_segment(map, player, wall, sector, wall_sprite)
    local v1 = map.vertices[wall.v1]
    local v2 = map.vertices[wall.v2]

    local fov = Config.FOV
    local near_plane = Config.NEAR_PLANE
    local texture_size = Config.TEXTURE_SIZE

    -- Use sector's ceiling height as wall height
    local wall_height = sector.ceiling_height - sector.floor_height

    -- Clip wall quad against frustum
    local clipped_quads = clip_wall_quad(player, v1, v2, wall_height, fov, near_plane)

    -- Render each clipped quad
    for quad in all(clipped_quads) do
        local bottom1 = quad.bottom1
        local top1 = quad.top1
        local bottom2 = quad.bottom2
        local top2 = quad.top2
        local u_start_clip = quad.u_start
        local u_end_clip = quad.u_end

        -- Find screen X range
        local x_start = flr(min(bottom1.x, bottom2.x))
        local x_end = flr(max(bottom1.x, bottom2.x))

        -- Clamp to screen bounds
        x_start = max(0, x_start)
        x_end = min(Config.SCREEN_WIDTH - 1, x_end)

        -- Pre-calculate 1/z values for perspective-correct interpolation
        local inv_z1 = 1 / bottom1.z
        local inv_z2 = 1 / bottom2.z

        -- Pre-calculate u/z values
        local u_over_z1 = u_start_clip * inv_z1
        local u_over_z2 = u_end_clip * inv_z2

        -- Draw vertical columns across the wall
        for x = x_start, x_end do
            -- Occlusion culling: skip fully occluded columns
            if Raycaster.is_column_occluded(x) then
                goto skip_column
            end

            -- Calculate interpolation factor (0 to 1) across wall segment
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
            local w = inv_z

            -- Interpolate u/z linearly, then divide by z to get perspective-correct u
            local u_over_z = u_over_z1 + (u_over_z2 - u_over_z1) * t
            local u_t = u_over_z / inv_z

            -- Interpolate Y coordinates (top and bottom of wall)
            local y_top = top1.y + (top2.y - top1.y) * t
            local y_bottom = bottom1.y + (bottom2.y - bottom1.y) * t

            -- Calculate texture U coordinate
            local u = u_t * texture_size

            -- Calculate V coordinates using world-space ray intersection
            local v_top = 0
            local v_bottom = texture_size

            -- If wall top extends above screen (y_top < 0), find correct V
            if y_top < 0 then
                local screen_y_target = 0
                local y_cam_direction = (screen_y_target - Config.SCREEN_CENTER_Y) / fov
                local world_y_at_edge = player.y - y_cam_direction * z
                v_top = (wall_height - world_y_at_edge) / wall_height * texture_size
                y_top = 0
            end

            -- If wall bottom extends below screen (y_bottom > screen height), find correct V
            if y_bottom > Config.SCREEN_HEIGHT - 1 then
                local screen_y_target = Config.SCREEN_HEIGHT - 1
                local y_cam_direction = (screen_y_target - Config.SCREEN_CENTER_Y) / fov
                local world_y_at_edge = player.y - y_cam_direction * z
                v_bottom = (wall_height - world_y_at_edge) / wall_height * texture_size
                y_bottom = Config.SCREEN_HEIGHT - 1
            end

            -- Draw the column immediately (no batching for portal rendering)
            if y_bottom > y_top and y_top < Config.SCREEN_HEIGHT and y_bottom > 0 then
                -- Create a single column for tline3d
                local col_data = userdata("f64", 11, 1)
                col_data[0] = wall_sprite
                col_data[1] = x
                col_data[2] = y_top
                col_data[3] = x
                col_data[4] = y_bottom
                col_data[5] = u * w
                col_data[6] = v_top * w
                col_data[7] = u * w
                col_data[8] = v_bottom * w
                col_data[9] = w
                col_data[10] = w

                tline3d(col_data, 0, 1)

                -- Mark this column as filled by the wall (for occlusion)
                Raycaster.mark_column_filled(x, y_top, y_bottom)
            end

            ::skip_column::
        end
    end
end

--[[
  Disable the color table (used after rendering to restore normal colors for UI)
]]
function Raycaster.disable_colortable()
    poke(0x550b, 0x00)  -- Disable color table
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
                -- Occlusion culling: skip fully occluded columns
                if Raycaster.is_column_occluded(x) then
                    goto skip_column
                end

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

                    -- Mark this column as filled by the wall (for occlusion)
                    Raycaster.mark_column_filled(x, y_top, y_bottom)
                end  -- end depth test

                ::skip_column::
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
-- Export render_textured_triangle for portal rendering
function Raycaster.render_textured_triangle(sprite, vert_data)
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

-- Keep local alias for existing code that uses it
local render_textured_triangle = Raycaster.render_textured_triangle

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
