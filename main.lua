--[[pod_format="raw"]]

--[[
  FPS Raycaster System for Picotron

  Features:
  - OBJ file loader with outer edge detection
  - tline3d rendering for walls (sprite-0) and floors (sprite-1)
  - Collision detection
  - WASD + Mouse controls with mouse lock

  Picotron Built-in Functions Used (may show as warnings in IDE):
  - fetch(filename) -- loads files
  - mouse() -- returns mouse_x, mouse_y, mouse_b, wheel_x, wheel_y
  - mouselock(lock, event_sensitivity, move_sensitivity) -- FPS mouse control
  - key(k) -- returns true if key k is held
  - keyp(k) -- returns true if key k is pressed (or repeating)
  - window{} -- configure window properties
  - tline3d() -- render textured 3D triangles

  Mouse Cursor API (via window function):
  - window{cursor=0} -- disable cursor
  - window{cursor="pointer"} -- pointer cursor (hand with finger)
  - window{cursor="grab"} -- grab cursor (open/closed hand)
  - window{cursor="dial"} -- dial cursor (twirling hand)
  - window{cursor="edit"} -- edit cursor
  - window{cursor="crosshair"} -- crosshair (FPS-style)
  - window{cursor=sprite_index} -- custom sprite cursor (integer index)
  - window{cursor=userdata} -- custom sprite cursor (gfx userdata)

  Controls:
  - W/A/S/D: Move forward/left/backward/right
  - Mouse: Look around (when locked with Tab)
  - Arrow Keys: Look around (when mouse not locked)
  - Space: Jump
  - Tab: Toggle mouse lock

  Camera Settings:
  - Pitch clamped to +/- 45 degrees (0.785 radians)
  - Mouse inverted to match FPS convention (right = look right, up = look up)
  - All rotations use floating point for smooth movement

  Debug Visualization:
  - Light blue lines: Floor edges
  - Yellow wireframes: Walls (outer boundaries)
]]

-- Load configuration first
local Config = include("config.lua")

-- Game state
local player = {
    x = 0,
    y = Config.PLAYER_EYE_HEIGHT,  -- eye height
    z = 0,
    angle = 0,  -- yaw (horizontal rotation)
    pitch = 0,  -- look up/down
    vx = 0,
    vy = 0,
    vz = 0,
    radius = Config.PLAYER_COLLISION_RADIUS  -- collision radius
}

-- Map data
local map = {
    vertices = {},  -- {x, y, z}
    faces = {},     -- floor faces {v1, v2, v3, v4, ...}
    walls = {},     -- outer wall edges {v1, v2, height}
    sectors = {},   -- sector-based structure for portal rendering
    bounds = {min_x=0, max_x=0, min_z=0, max_z=0}
}

-- Mouse control state
local mouse_locked = false
local last_mouse_x = 0
local last_mouse_y = 0

-- Debug options
local show_wireframe = false
local show_walls = true
local use_portal_rendering = false  -- Toggle between old and portal rendering
local rendered_sectors = {}  -- Track which sectors were rendered (for wireframe)

-- Performance tracking
local frame_cpu = 0

-- Use config constants for all settings
local MOVE_SPEED = Config.MOVE_SPEED
local JUMP_SPEED = Config.JUMP_SPEED
local GRAVITY = Config.GRAVITY
local FRICTION = Config.FRICTION
local WALL_HEIGHT = Config.WALL_HEIGHT

local FOG_START = Config.FOG_START
local FOG_END = Config.FOG_END

local FOV = Config.FOV
local TURN_SPEED = Config.TURN_SPEED
local PITCH_SPEED = Config.PITCH_SPEED
local MAX_PITCH = Config.MAX_PITCH

local ARROW_TURN_SPEED = Config.ARROW_TURN_SPEED
local ARROW_PITCH_SPEED = Config.ARROW_PITCH_SPEED

-- Sprites for textures
local wall_sprite = Config.SPRITE_WALL
local floor_sprite = Config.SPRITE_FLOOR
local ceiling_sprite = Config.SPRITE_CEILING

-- Load raycaster module (include returns the module)
local Raycaster = include("raycaster.lua")

-- Load profiler module
include("profiler.lua")

--[[
  OBJ File Loader
  Loads vertices and faces, discards internal edges
]]
function load_obj(filename)
    local vertices = {}
    local faces = {}

    -- Read file using Picotron's fetch() function
    local file_content = fetch(filename)
    if not file_content then
        printh("Error: Could not load " .. filename)
        return
    end

    local lines = split(file_content, "\n", false)

    -- Parse OBJ file
    for line in all(lines) do
        local parts = split(line, " ", false)

        -- Vertex line: v x y z
        if parts[1] == "v" then
            add(vertices, {
                x = tonum(parts[2]),
                y = tonum(parts[3]),
                z = tonum(parts[4])
            })

        -- Face line: f v1/vt1/vn1 v2/vt2/vn2 ...
        elseif parts[1] == "f" then
            local face = {}
            for i=2,#parts do
                -- Parse vertex index (before first slash)
                local v_idx = tonum(split(parts[i], "/")[1])
                add(face, v_idx)
            end
            if #face >= 3 then
                add(faces, face)
            end
        end
    end

    -- Store in map
    map.vertices = vertices
    map.faces = faces

    -- Calculate bounds
    calculate_bounds()

    -- Extract outer walls (edges that appear only once)
    extract_outer_walls()

    -- Build sector tree for portal rendering
    build_sectors()

    -- Position player at center
    player.x = (map.bounds.min_x + map.bounds.max_x) / 2
    player.z = (map.bounds.min_z + map.bounds.max_z) / 2
end

--[[
  Calculate bounding box of the level
]]
function calculate_bounds()
    if #map.vertices == 0 then return end

    local first = map.vertices[1]
    map.bounds.min_x = first.x
    map.bounds.max_x = first.x
    map.bounds.min_z = first.z
    map.bounds.max_z = first.z

    for v in all(map.vertices) do
        map.bounds.min_x = min(map.bounds.min_x, v.x)
        map.bounds.max_x = max(map.bounds.max_x, v.x)
        map.bounds.min_z = min(map.bounds.min_z, v.z)
        map.bounds.max_z = max(map.bounds.max_z, v.z)
    end
end

--[[
  Extract outer wall edges
  An edge is outer if it appears in only one face (boundary edge)
]]
function extract_outer_walls()
    local edge_to_face = {}  -- edge -> {face, v1, v2} (with original order)

    -- Track edge occurrences with their face context
    for face in all(map.faces) do
        for i=1,#face do
            local v1 = face[i]
            local v2 = face[(i % #face) + 1]  -- wrap around

            -- Create edge key (smaller index first for consistency)
            local edge_key = min(v1, v2) .. "," .. max(v1, v2)

            if not edge_to_face[edge_key] then
                edge_to_face[edge_key] = {}
            end
            -- Store face reference and original vertex order
            add(edge_to_face[edge_key], {face = face, v1 = v1, v2 = v2})
        end
    end

    -- Extract edges that appear only once (outer boundary)
    -- Use face winding order to determine normal direction
    map.walls = {}
    for edge_key, edge_list in pairs(edge_to_face) do
        if #edge_list == 1 then
            local edge_info = edge_list[1]
            local face = edge_info.face
            local v1_idx = edge_info.v1
            local v2_idx = edge_info.v2

            -- Get vertex positions
            local v1 = map.vertices[v1_idx]
            local v2 = map.vertices[v2_idx]

            -- Calculate wall normal based on face winding order
            -- The face vertices wind counter-clockwise when viewed from above (floor)
            -- So the wall (extruded upward) should face to the RIGHT of the v1→v2 direction
            -- Right = 90° clockwise rotation: (dx, dz) → (dz, -dx)

            local edge_dx = v2.x - v1.x
            local edge_dz = v2.z - v1.z

            -- Normal points to the right of the edge (inward, toward the room)
            local normal_x = edge_dz
            local normal_z = -edge_dx

            add(map.walls, {
                v1 = v1_idx,
                v2 = v2_idx,
                height = WALL_HEIGHT,
                normal_x = normal_x,
                normal_z = normal_z
            })
        end
    end
end

--[[
  Build sector tree for portal rendering
  Each face becomes a sector with walls (portals or solid)
]]
function build_sectors()
    -- Build edge-to-faces mapping
    local edge_to_faces = {}  -- edge_key -> {face_idx1, face_idx2, ...}

    for face_idx = 1, #map.faces do
        local face = map.faces[face_idx]
        for i = 1, #face do
            local v1 = face[i]
            local v2 = face[(i % #face) + 1]

            -- Create normalized edge key (smaller index first)
            local edge_key = min(v1, v2) .. "," .. max(v1, v2)

            if not edge_to_faces[edge_key] then
                edge_to_faces[edge_key] = {}
            end
            add(edge_to_faces[edge_key], {
                face_idx = face_idx,
                v1 = v1,
                v2 = v2
            })
        end
    end

    -- Build sectors - one sector per face
    map.sectors = {}
    for face_idx = 1, #map.faces do
        local face = map.faces[face_idx]
        local sector = {
            floor_face = face,
            floor_height = 0,  -- Default floor height (from vertex Y)
            ceiling_height = Config.WALL_HEIGHT,
            walls = {}
        }

        -- Build walls for this sector
        for i = 1, #face do
            local v1 = face[i]
            local v2 = face[(i % #face) + 1]

            -- Create normalized edge key
            local edge_key = min(v1, v2) .. "," .. max(v1, v2)
            local edge_faces = edge_to_faces[edge_key]

            -- Calculate wall normal (points inward to sector)
            local vert1 = map.vertices[v1]
            local vert2 = map.vertices[v2]
            local edge_dx = vert2.x - vert1.x
            local edge_dz = vert2.z - vert1.z

            -- Normal points right of edge direction (inward)
            local normal_x = edge_dz
            local normal_z = -edge_dx

            local wall = {
                v1 = v1,
                v2 = v2,
                normal_x = normal_x,
                normal_z = normal_z,
                portal_to = nil  -- Will be set if this is a portal
            }

            -- Check if this edge is shared with another face (portal)
            if #edge_faces == 2 then
                -- This is a portal - find the neighboring sector
                local neighbor_idx
                for edge_info in all(edge_faces) do
                    if edge_info.face_idx ~= face_idx then
                        neighbor_idx = edge_info.face_idx
                        break
                    end
                end
                wall.portal_to = neighbor_idx
            end
            -- If #edge_faces == 1, it's a solid wall (portal_to stays nil)

            add(sector.walls, wall)
        end

        add(map.sectors, sector)
    end

    printh("Built " .. #map.sectors .. " sectors")
end

--[[
  Find which sector contains a given point (x, z)
  Uses point-in-polygon test
  Returns sector index or nil
]]
function find_player_sector(x, z)
    for sector_idx = 1, #map.sectors do
        local sector = map.sectors[sector_idx]
        local face = sector.floor_face

        -- Point-in-polygon test using ray casting algorithm
        local inside = false
        local n = #face

        for i = 1, n do
            local v1_idx = face[i]
            local v2_idx = face[(i % n) + 1]
            local v1 = map.vertices[v1_idx]
            local v2 = map.vertices[v2_idx]

            -- Check if ray from point crosses this edge
            if ((v1.z > z) ~= (v2.z > z)) then
                local x_intersect = (v2.x - v1.x) * (z - v1.z) / (v2.z - v1.z) + v1.x
                if x < x_intersect then
                    inside = not inside
                end
            end
        end

        if inside then
            return sector_idx
        end
    end

    return nil
end

--[[
  Initialize game
]]
function _init()
    -- Set video mode to 480x270
    vid(0)

    -- Load level
    load_obj("level_test.obj")

    -- Set up window with crosshair cursor
    window{cursor="crosshair"}

    -- Enable profiler (detailed=true, cpu=true)
    profile.enabled(true, true)

    -- Initialize sprites (you should create these in Picotron sprite editor)
    -- sprite-0: wall texture
    -- sprite-1: floor texture

    printh("=== FPS Raycaster Started ===")
    printh("Loaded " .. #map.vertices .. " vertices")
    printh("Loaded " .. #map.faces .. " faces")
    printh("Found " .. #map.walls .. " outer walls")
    printh("Player spawn: " .. player.x .. ", " .. player.z)
end

--[[
  Update game state
]]
function _update()
    local dt = 1/30  -- Picotron runs at 30fps

    -- Mouse look
    update_mouse_look()

    -- Keyboard movement
    update_movement(dt)

    -- Apply gravity and ground collision
    update_physics(dt)
end

--[[
  Mouse look controls
  Uses mouselock() for smooth FPS-style camera control
  Falls back to arrow keys when mouse is not locked
]]
function update_mouse_look()
    if mouse_locked then
        -- Mouse look (when locked)
        local dx, dy = mouselock(true, 0.5, 0)

        if dx and dy then
            -- Update rotation based on mouse movement (inverted to match FPS convention)
            player.angle += dx * TURN_SPEED * 10.0  -- Add for inverted horizontal
            player.pitch += dy * PITCH_SPEED * 10.0  -- Add for inverted vertical

            -- Clamp pitch to +/- 45 degrees
            player.pitch = mid(-MAX_PITCH, player.pitch, MAX_PITCH)
        end
    else
        -- Arrow key look (when mouse not locked)
        -- Left/Right arrows - rotate horizontally (inverted)
        if key("left") then
            player.angle += ARROW_TURN_SPEED  -- inverted
        end
        if key("right") then
            player.angle -= ARROW_TURN_SPEED  -- inverted
        end

        -- Up/Down arrows - rotate vertically (inverted)
        if key("up") then
            player.pitch += ARROW_PITCH_SPEED  -- inverted
        end
        if key("down") then
            player.pitch -= ARROW_PITCH_SPEED  -- inverted
        end

        -- Clamp pitch to +/- 45 degrees (0.125 in Picotron units)
        player.pitch = mid(-MAX_PITCH, player.pitch, MAX_PITCH)
    end
end

--[[
  Keyboard movement (WASD + Space/C)
  Movement is relative to camera angle (yaw only, not pitch)
  Using CORRECT math from working lounge scene
]]
function update_movement(dt)
    -- CORRECT WASD movement math from lounge scene
    -- Forward direction uses sin/cos pattern
    local forward_x = sin(player.angle)
    local forward_z = cos(player.angle)

    -- Right direction uses cos/-sin pattern
    local right_x = cos(player.angle)
    local right_z = -sin(player.angle)

    -- Calculate intended movement
    local move_x = 0
    local move_z = 0

    -- W - forward (in direction of camera angle)
    if key("w") then
        move_x = move_x + forward_x * MOVE_SPEED * dt
        move_z = move_z + forward_z * MOVE_SPEED * dt
    end

    -- S - backward (opposite of camera angle)
    if key("s") then
        move_x = move_x - forward_x * MOVE_SPEED * dt
        move_z = move_z - forward_z * MOVE_SPEED * dt
    end

    -- A - strafe left (SUBTRACT right vector)
    if key("a") then
        move_x = move_x - right_x * MOVE_SPEED * dt
        move_z = move_z - right_z * MOVE_SPEED * dt
    end

    -- D - strafe right (ADD right vector)
    if key("d") then
        move_x = move_x + right_x * MOVE_SPEED * dt
        move_z = move_z + right_z * MOVE_SPEED * dt
    end

    -- Apply movement with collision detection
    local new_x = player.x + move_x
    local new_z = player.z + move_z

    if not check_collision(new_x, new_z) then
        -- No collision - move freely
        player.x = new_x
        player.z = new_z
    else
        -- Collision detected - try sliding along walls
        if not check_collision(new_x, player.z) then
            -- Can move in X direction
            player.x = new_x
        elseif not check_collision(player.x, new_z) then
            -- Can move in Z direction
            player.z = new_z
        end
        -- If both fail, player doesn't move
    end

    -- Jump (Space)
    if keyp("space") and player.y <= 1.7 then
        player.vy = JUMP_SPEED
    end

    -- Toggle mouse lock (Tab)
    if keyp("tab") then
        mouse_locked = not mouse_locked
        if mouse_locked then
            window{cursor="crosshair"}
        else
            window{cursor="pointer"}
        end
    end

    -- Toggle wireframe (T)
    if keyp("t") then
        show_wireframe = not show_wireframe
    end

    -- Toggle walls (1)
    if keyp("1") then
        show_walls = not show_walls
    end

    -- Toggle portal rendering (P)
    if keyp("p") then
        use_portal_rendering = not use_portal_rendering
    end
end

--[[
  Physics (gravity and ground collision)
]]
function update_physics(dt)
    -- Apply gravity
    player.vy -= GRAVITY * dt
    player.y += player.vy * dt

    -- Ground collision
    if player.y < 1.7 then
        player.y = 1.7
        player.vy = 0
    end
end

--[[
  Check collision with walls
  Uses circle-line segment collision
]]
function check_collision(px, pz)
    for wall in all(map.walls) do
        local v1 = map.vertices[wall.v1]
        local v2 = map.vertices[wall.v2]

        if line_circle_collision(v1.x, v1.z, v2.x, v2.z, px, pz, player.radius) then
            return true
        end
    end
    return false
end

--[[
  Line segment vs circle collision detection
]]
function line_circle_collision(x1, y1, x2, y2, cx, cy, radius)
    -- Vector from line start to circle center
    local dx = cx - x1
    local dy = cy - y1

    -- Vector along line
    local lx = x2 - x1
    local ly = y2 - y1

    -- Project circle center onto line
    local len_sq = lx * lx + ly * ly
    if len_sq == 0 then
        -- Degenerate line
        return sqrt(dx * dx + dy * dy) < radius
    end

    local t = (dx * lx + dy * ly) / len_sq
    t = mid(0, t, 1)  -- clamp to line segment

    -- Closest point on line segment
    local closest_x = x1 + t * lx
    local closest_y = y1 + t * ly

    -- Distance to closest point
    local dist_x = cx - closest_x
    local dist_y = cy - closest_y
    local dist = sqrt(dist_x * dist_x + dist_y * dist_y)

    return dist < radius
end

--[[
  Render the scene using column-based raycasting
  This is how Doom/Build Engine actually worked!
]]
function _draw()
    cls(1)  -- clear to dark blue

    -- Initialize occlusion buffer for this frame
    Raycaster.init_occlusion_buffer()

    if use_portal_rendering then
        -- Portal rendering: recursively render visible sectors
        profile("portal")
        local player_sector = find_player_sector(player.x, player.z)
        -- Clear rendered sectors from last frame
        rendered_sectors = {}
        if player_sector then
            Raycaster.render_portals(map, player, player_sector, wall_sprite, floor_sprite, ceiling_sprite, nil, rendered_sectors, show_walls)
        end
        profile("portal")
    else
        -- Old rendering: render all floors, ceilings, and walls
        profile("floors")
        Raycaster.render_floors(map, player, floor_sprite, FOG_START, FOG_END)
        profile("floors")

        profile("ceilings")
        Raycaster.render_ceilings(map, player, ceiling_sprite, FOG_START, FOG_END)
        profile("ceilings")

        -- Render walls using raycaster module (now handles its own clipping)
        if show_walls then
            profile("walls")
            Raycaster.render_walls(map, player, wall_sprite, FOG_START, FOG_END)
            profile("walls")
        end
    end

    -- Disable color table for UI rendering (restore normal colors)
    Raycaster.disable_colortable()

    -- Draw debug wireframe (toggleable with T key)
    if show_wireframe then
        profile("wireframe")
        render_debug_lines()
        profile("wireframe")
    end

    -- Draw crosshair
    draw_crosshair()

    -- Draw HUD
    draw_hud()

    -- Draw profiler stats
    profile.draw()

    -- Track CPU usage (stat 1 returns CPU usage where 1.0 = 60fps)
    frame_cpu = stat(1)
end


--[[
  Render debug wireframe lines with proper clipping
]]
function render_debug_lines()
    -- Draw all sector walls
    for sector_idx = 1, #map.sectors do
        local sector = map.sectors[sector_idx]

        -- Check if this sector was rendered (only relevant in portal mode)
        local is_rendered = not use_portal_rendering or rendered_sectors[sector_idx]

        for wall in all(sector.walls) do
            local v1 = map.vertices[wall.v1]
            local v2 = map.vertices[wall.v2]

            -- Color based on portal type and render status
            if not is_rendered then
                color(1)  -- dark blue = culled sector (not rendered)
            elseif wall.portal_to then
                color(11)  -- green = portal
            else
                color(10)  -- yellow = solid wall
            end

            -- Draw bottom edge with clipping
            local bottom1, bottom2 = clip_line_to_near_plane(v1.x, v1.y, v1.z, v2.x, v2.y, v2.z)

            -- Draw top edge with clipping
            local top1, top2 = clip_line_to_near_plane(
                v1.x, v1.y + sector.ceiling_height, v1.z,
                v2.x, v2.y + sector.ceiling_height, v2.z
            )

            -- Draw vertical edges with clipping
            local left1, left2 = clip_line_to_near_plane(
                v1.x, v1.y, v1.z,
                v1.x, v1.y + sector.ceiling_height, v1.z
            )
            local right1, right2 = clip_line_to_near_plane(
                v2.x, v2.y, v2.z,
                v2.x, v2.y + sector.ceiling_height, v2.z
            )

            -- Draw all edges that are visible
            if bottom1 and bottom2 then
                line(bottom1.x, bottom1.y, bottom2.x, bottom2.y)
            end
            if top1 and top2 then
                line(top1.x, top1.y, top2.x, top2.y)
            end
            if left1 and left2 then
                line(left1.x, left1.y, left2.x, left2.y)
            end
            if right1 and right2 then
                line(right1.x, right1.y, right2.x, right2.y)
            end
        end
    end
end

--[[
  Collect wall triangles with backface culling
]]
function collect_wall_triangles(triangles)
    for wall in all(map.walls) do
        local v1 = map.vertices[wall.v1]
        local v2 = map.vertices[wall.v2]

        -- Four corners of the wall quad
        local bottom1 = world_to_screen(v1.x, 0, v1.z)
        local top1 = world_to_screen(v1.x, wall.height, v1.z)
        local bottom2 = world_to_screen(v2.x, 0, v2.z)
        local top2 = world_to_screen(v2.x, wall.height, v2.z)

        -- Skip if behind camera
        if bottom1 and top1 and bottom2 and top2 then
            -- Calculate wall length for texture scaling
            local wall_len = sqrt((v2.x - v1.x)^2 + (v2.z - v1.z)^2)
            local u_scale = wall_len * 4  -- texture repeat

            -- Triangle 1: bottom-left, top-left, bottom-right
            -- Backface culling check
            local dx1 = top1.x - bottom1.x
            local dy1 = top1.y - bottom1.y
            local dx2 = bottom2.x - bottom1.x
            local dy2 = bottom2.y - bottom1.y
            local cross1 = dx1 * dy2 - dy1 * dx2

            if cross1 > 0 then
                local avg_z1 = (bottom1.z + top1.z + bottom2.z) / 3
                add(triangles, {
                    p1 = bottom1, p2 = top1, p3 = bottom2,
                    u0 = 0, v0 = 8,
                    u1 = 0, v1 = 0,
                    u2 = u_scale, v2 = 8,
                    sprite = wall_sprite,
                    avg_z = avg_z1
                })
            end

            -- Triangle 2: top-left, top-right, bottom-right
            dx1 = top2.x - top1.x
            dy1 = top2.y - top1.y
            dx2 = bottom2.x - top1.x
            dy2 = bottom2.y - top1.y
            local cross2 = dx1 * dy2 - dy1 * dx2

            if cross2 > 0 then
                local avg_z2 = (top1.z + top2.z + bottom2.z) / 3
                add(triangles, {
                    p1 = top1, p2 = top2, p3 = bottom2,
                    u0 = 0, v0 = 0,
                    u1 = u_scale, v1 = 0,
                    u2 = u_scale, v2 = 8,
                    sprite = wall_sprite,
                    avg_z = avg_z2
                })
            end
        end
    end
end

--[[
  Transform world coordinates to screen space
  Returns {x, y, z, clipped} or nil if behind camera
  clipped flag indicates if point was clipped to near plane
]]
function world_to_screen(wx, wy, wz)
    -- Translate to camera space
    local dx = wx - player.x
    local dy = wy - player.y
    local dz = wz - player.z

    -- Rotate by yaw (horizontal)
    local cos_yaw = cos(player.angle)
    local sin_yaw = sin(player.angle)
    local rx = dx * cos_yaw - dz * sin_yaw
    local rz = dx * sin_yaw + dz * cos_yaw

    -- Rotate by pitch (vertical)
    local cos_pitch = cos(player.pitch)
    local sin_pitch = sin(player.pitch)
    local ry = dy * cos_pitch - rz * sin_pitch
    local final_z = dy * sin_pitch + rz * cos_pitch

    -- Skip if behind camera
    if final_z < 0.1 then
        return nil
    end

    -- Project to screen (480x270)
    local screen_x = 480 / 2 + (rx / final_z) * FOV
    local screen_y = 270 / 2 - (ry / final_z) * FOV

    return {x = screen_x, y = screen_y, z = final_z, clipped = false}
end

--[[
  Clip a line segment against the near plane and return clipped endpoints
  Returns p1_clipped, p2_clipped (both can be nil if fully behind camera)
  Each returned point has {x, y, z, clipped} where clipped indicates it was clipped
]]
function clip_line_to_near_plane(wx1, wy1, wz1, wx2, wy2, wz2)
    local near_plane = 0.1

    -- Transform both points to camera space (before projection)
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

    local cx1, cy1, cz1 = to_camera_space(wx1, wy1, wz1)
    local cx2, cy2, cz2 = to_camera_space(wx2, wy2, wz2)

    -- Check if both behind camera
    if cz1 < near_plane and cz2 < near_plane then
        return nil, nil
    end

    -- Check if both in front (no clipping needed)
    if cz1 >= near_plane and cz2 >= near_plane then
        return world_to_screen(wx1, wy1, wz1), world_to_screen(wx2, wy2, wz2)
    end

    -- One point behind, one in front - clip to near plane
    local t
    if cz1 < near_plane then
        -- Point 1 behind camera, clip it
        t = (near_plane - cz1) / (cz2 - cz1)
        local clipped_x = cx1 + (cx2 - cx1) * t
        local clipped_y = cy1 + (cy2 - cy1) * t
        local clipped_z = near_plane

        -- Project clipped point
        local screen_x = 480 / 2 + (clipped_x / clipped_z) * FOV
        local screen_y = 270 / 2 - (clipped_y / clipped_z) * FOV

        return {x = screen_x, y = screen_y, z = clipped_z, clipped = true},
               world_to_screen(wx2, wy2, wz2)
    else
        -- Point 2 behind camera, clip it
        t = (near_plane - cz1) / (cz2 - cz1)
        local clipped_x = cx1 + (cx2 - cx1) * t
        local clipped_y = cy1 + (cy2 - cy1) * t
        local clipped_z = near_plane

        -- Project clipped point
        local screen_x = 480 / 2 + (clipped_x / clipped_z) * FOV
        local screen_y = 270 / 2 - (clipped_y / clipped_z) * FOV

        return world_to_screen(wx1, wy1, wz1),
               {x = screen_x, y = screen_y, z = clipped_z, clipped = true}
    end
end

--[[
  Draw crosshair
]]
function draw_crosshair()
    local cx = 480 / 2
    local cy = 270 / 2
    local size = 4

    color(7)  -- white
    line(cx - size, cy, cx + size, cy)
    line(cx, cy - size, cx, cy + size)
    pset(cx, cy, 8)  -- red center dot
end

--[[
  Draw HUD
]]
function draw_hud()
    color(7)

    -- Player sector info
    local player_sector = find_player_sector(player.x, player.z)
    if player_sector then
        local sector = map.sectors[player_sector]
        local portal_count = 0
        local solid_count = 0

        for wall in all(sector.walls) do
            if wall.portal_to then
                portal_count = portal_count + 1
            else
                solid_count = solid_count + 1
            end
        end

        print("sector: " .. player_sector, 2, 2, 0)
        print("sector: " .. player_sector, 2, 2)
        print("portals: " .. portal_count, 2, 10, 0)
        print("portals: " .. portal_count, 2, 10)
        print("solid: " .. solid_count, 2, 18, 0)
        print("solid: " .. solid_count, 2, 18)
    end

    -- Occlusion statistics
    local occluded, total, pct = Raycaster.get_occlusion_stats()
    print("occluded: " .. occluded .. "/" .. total, 2, 26, 0)
    print("occluded: " .. occluded .. "/" .. total, 2, 26)
    print("occlusion: " .. flr(pct) .. "%", 2, 34, 0)
    print("occlusion: " .. flr(pct) .. "%", 2, 34)

    -- Rendering mode
    local render_mode = use_portal_rendering and "portal" or "classic"
    print("render(p): " .. render_mode, 2, 42, 0)
    print("render(p): " .. render_mode, 2, 42)

    -- -- Position
    -- print("pos: " .. flr(player.x*10)/10 .. ", " .. flr(player.z*10)/10, 2, 2, 0)
    -- print("pos: " .. flr(player.x*10)/10 .. ", " .. flr(player.z*10)/10, 2, 2)

    -- -- Angle (convert from Picotron 0-1 units to degrees)
    -- local deg = flr(player.angle * 360) % 360
    -- print("angle: " .. deg .. "d", 2, 10, 0)
    -- print("angle: " .. deg .. "d", 2, 10)

    -- -- Pitch (convert from Picotron units to degrees)
    -- local pitch_deg = flr(player.pitch * 360)
    -- print("pitch: " .. pitch_deg .. "d", 2, 18, 0)
    -- print("pitch: " .. pitch_deg .. "d", 2, 18)

    -- -- Map stats
    -- print("verts: " .. #map.vertices, 2, 26, 0)
    -- print("verts: " .. #map.vertices, 2, 26)
    -- print("walls: " .. #map.walls, 2, 34, 0)
    -- print("walls: " .. #map.walls, 2, 34)
    -- print("faces: " .. #map.faces, 2, 42, 0)
    -- print("faces: " .. #map.faces, 2, 42)

    -- -- Performance metrics
    -- print("columns: " .. Raycaster.columns_drawn, 2, 50, 0)
    -- print("columns: " .. Raycaster.columns_drawn, 2, 50)
    -- print("floor spans: " .. Raycaster.floor_spans_drawn, 2, 58, 0)
    -- print("floor spans: " .. Raycaster.floor_spans_drawn, 2, 58)
    -- print("ceiling spans: " .. Raycaster.ceiling_spans_drawn, 2, 66, 0)
    -- print("ceiling spans: " .. Raycaster.ceiling_spans_drawn, 2, 66)

    -- -- CPU usage (1.0 = 60fps, 2.0 = 30fps)
    -- local cpu_str = "cpu: " .. flr(frame_cpu * 100) / 100
    -- print(cpu_str, 2, 74, 0)
    -- print(cpu_str, 2, 74)

    -- -- Calculate FPS from CPU (fps = 60 / cpu_usage)
    -- local fps = 60
    -- if frame_cpu > 0 then
    --     fps = flr(60 / frame_cpu)
    -- end
    -- print("fps: " .. fps, 2, 82, 0)
    -- print("fps: " .. fps, 2, 82)

    -- -- Wireframe toggle state
    -- local wire_state = show_wireframe and "on" or "off"
    -- print("wireframe(t): " .. wire_state, 2, 90, 0)
    -- print("wireframe(t): " .. wire_state, 2, 90)

    -- Instructions
    -- if not mouse_locked then
    --     print("WASD:move Arrows:look Space:jump TAB:lock", 2, 260, 0)
    --     print("WASD:move Arrows:look Space:jump TAB:lock", 2, 260, 10)
    -- else
    --     print("WASD:move Mouse:look Space:jump TAB:unlock", 2, 260, 0)
    --     print("WASD:move Mouse:look Space:jump TAB:unlock", 2, 260, 7)
    -- end
end

--[[
  Main entry point
]]
function _draw_start()
    cls()

    -- Draw loading screen
    color(7)
    print("Loading...", 240/2-20, 135/2)
end
