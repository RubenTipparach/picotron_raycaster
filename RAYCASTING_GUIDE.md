# Picotron FPS Raycaster Implementation Guide

## Overview

This is a Doom-style raycaster engine for Picotron that uses column-based wall rendering and scanline-based floor/ceiling rendering. The implementation uses `tline3d` for perspective-correct texture mapping.

---

## Architecture

The raycaster consists of three main rendering systems:

1. **Wall Rendering**: Column-based vertical slices with depth buffering
2. **Floor Rendering**: Horizontal scanline spans using ray-plane intersection
3. **Ceiling Rendering**: Same as floors but for the top half of the screen

---

## Wall Rendering System

### How It Works

Walls are rendered using a **column-based approach** (like Doom and Build Engine):

1. For each wall segment in the level
2. Project the wall's endpoints to screen space
3. Clip against the view frustum (near plane)
4. Render vertical texture columns across the wall's screen width
5. Use a depth buffer to handle overlapping walls correctly

### Key Features

- **Backface Culling**: Precomputed wall normals during level load
- **Frustum Clipping**: Proper near-plane clipping with UV adjustment
- **Depth Buffering**: Per-column depth test for correct occlusion
- **Perspective-Correct Texturing**: Using `w = 1/z` for proper texture mapping

### Wall Rendering Pipeline

```lua
for each wall in level:
    1. Backface culling (dot product with precomputed normal)
    2. Transform wall vertices to camera space
    3. Clip wall quad against near plane
    4. Project to screen space
    5. For each X column across the wall:
        a. Interpolate depth (perspective-correct)
        b. Depth test against buffer
        c. Calculate texture U coordinate
        d. Calculate Y range (top/bottom of wall on screen)
        e. Clip Y range to screen bounds
        f. Draw vertical textured column with tline3d
```

### Perspective-Correct Texture Mapping

The raycaster uses the **1/z interpolation method**:

```lua
-- Pre-calculate inverse depth (1/z) at wall endpoints
inv_z1 = 1 / bottom1.z
inv_z2 = 1 / bottom2.z

-- Pre-calculate u/z for perspective-correct U interpolation
u_over_z1 = u_start * inv_z1
u_over_z2 = u_end * inv_z2

-- For each column X:
t = (x - bottom1.x) / (bottom2.x - bottom1.x)  -- Linear screen-space interpolation

-- Interpolate 1/z linearly (correct in screen space)
inv_z = inv_z1 + (inv_z2 - inv_z1) * t
z = 1 / inv_z

-- Recover perspective-correct U coordinate
u_over_z = u_over_z1 + (u_over_z2 - u_over_z1) * t
u_t = u_over_z / inv_z  -- Divide by 1/z to get correct U

-- Pass to tline3d with w parameter
w = inv_z
tline3d(sprite, x, y_top, x, y_bottom, u*w, v_top*w, u*w, v_bottom*w, w, w)
```

### Backface Culling

Walls have precomputed normals calculated during level load:

```lua
-- During map load (extract_outer_walls):
-- Calculate normal pointing to the RIGHT of the wall edge
-- This makes walls face INWARD (toward the room center)
local edge_dx = v2.x - v1.x
local edge_dz = v2.z - v1.z

-- 90° clockwise rotation: (dx, dz) → (dz, -dx)
wall.normal_x = edge_dz
wall.normal_z = -edge_dx

-- During rendering:
-- Vector from wall midpoint to camera
local to_camera_x = player.x - wall_mid_x
local to_camera_z = player.z - wall_mid_z

-- Dot product test
local dot = wall.normal_x * to_camera_x + wall.normal_z * to_camera_z

-- Skip if camera is behind wall (dot <= 0)
if dot <= 0 then
    skip this wall
end
```

### Depth Buffer

Each X column has a depth value tracking the closest wall rendered so far:

```lua
-- Initialize depth buffer
local depth_buffer = {}
for x = 0, 479 do
    depth_buffer[x] = 99999  -- Far distance
end

-- During rendering
if z < depth_buffer[x] then
    depth_buffer[x] = z  -- Update with closer depth
    -- Draw this column
end
```

---

## Floor Rendering System

### Algorithm Overview

Floor rendering uses the **horizontal scanline technique** from Lode's raycasting tutorial. This is how classic Doom-style engines render floors and ceilings.

### The Key Formula

The core of floor rendering is the **similar triangles formula**:

```
rowDistance = cameraHeight / p
```

Where:
- `cameraHeight` = vertical distance from camera to floor (e.g., 1.7 units for eye height)
- `p` = distance from horizon line on screen (in pixels)
- `rowDistance` = horizontal distance from camera to floor at that scanline

### Why This Works

Imagine looking at a floor:
- The horizon line (screen center) is at infinite distance
- As you look down (increasing Y), the floor gets closer
- The relationship is **inversely proportional**: `distance ∝ 1/p`

This is the "similar triangles" property of perspective projection.

### Floor Rendering Pipeline

```lua
horizon = screen_height / 2  -- 135 for 270px tall screen

for each scanline Y from horizon to bottom of screen:
    1. Calculate distance: p = y - horizon
    2. Calculate row_distance = camera_height / p
    3. Cast rays through left and right edges of screen
    4. Find where rays hit floor at row_distance
    5. Calculate texture coordinates at left and right
    6. Draw horizontal textured span with tline3d
```

### Detailed Implementation

```lua
function render_floors(map, player, floor_sprite)
    -- Camera direction (forward vector)
    local dir_x = sin(player.angle)
    local dir_z = cos(player.angle)

    -- Camera plane (perpendicular, defines FOV)
    local plane_x = cos(player.angle) * 0.66  -- FOV ~70 degrees
    local plane_z = -sin(player.angle) * 0.66

    local horizon = screen_height / 2  -- 135

    for y = horizon + 1, screen_height - 1 do
        local p = y - horizon

        if p > 0.1 then  -- Avoid division by zero
            -- Distance to floor at this scanline
            local row_distance = (player.y - floor_height) / p

            if row_distance > 0 and row_distance < 30 then
                -- Leftmost ray (screen x = 0)
                local ray_dir_x0 = dir_x - plane_x
                local ray_dir_z0 = dir_z - plane_z

                -- Rightmost ray (screen x = 479)
                local ray_dir_x1 = dir_x + plane_x
                local ray_dir_z1 = dir_z + plane_z

                -- World coordinates at left edge
                local floor_x_left = player.x + ray_dir_x0 * row_distance
                local floor_z_left = player.z + ray_dir_z0 * row_distance

                -- World coordinates at right edge
                local floor_x_right = player.x + ray_dir_x1 * row_distance
                local floor_z_right = player.z + ray_dir_z1 * row_distance

                -- Texture coordinates (tile every 1 unit, 16x16 texture)
                local tex_u_left = (floor_x_left % 1) * 16
                local tex_v_left = (floor_z_left % 1) * 16
                local tex_u_right = (floor_x_right % 1) * 16
                local tex_v_right = (floor_z_right % 1) * 16

                -- Perspective correction
                local w = 1 / row_distance

                -- Draw horizontal span
                tline3d(
                    floor_sprite,
                    0, y,
                    479, y,
                    tex_u_left * w, tex_v_left * w,
                    tex_u_right * w, tex_v_right * w,
                    w, w
                )
            end
        end
    end
end
```

### Camera Plane Vector

The **camera plane** is perpendicular to the view direction and defines the FOV:

```
FOV angle ≈ 2 * atan(plane_length)
```

For FOV ~70 degrees: `plane_length ≈ 0.66`

The plane vector rotates with the camera:
```lua
-- If camera faces (dir_x, dir_z)
-- Then plane is perpendicular: (plane_x, plane_z)

plane_x = cos(angle) * 0.66   -- 90° rotation from direction
plane_z = -sin(angle) * 0.66
```

### Ray Direction Calculation

For each scanline, we need rays through the left and right screen edges:

```lua
-- Left ray = direction - plane
ray_left_x = dir_x - plane_x
ray_left_z = dir_z - plane_z

-- Right ray = direction + plane
ray_right_x = dir_x + plane_x
ray_right_z = dir_z + plane_z
```

This creates a **ray fan** that covers the entire horizontal field of view.

### Affine vs Perspective Mapping

For **horizontal surfaces** (floors/ceilings), we can use **affine texture mapping**:

- All points on a scanline are at the **same distance** from camera
- This means `w = 1/distance` is **constant** across the scanline
- `tline3d` can linearly interpolate texture coordinates
- This is much faster than per-pixel perspective correction

For **walls**, we need true perspective correction because depth changes across the surface.

### Texture Tiling

The modulo operator creates seamless texture tiling:

```lua
-- World coordinates wrap to 0-1 range
local tex_u = (world_x % 1) * texture_size
local tex_v = (world_z % 1) * texture_size
```

This makes the texture repeat every 1 world unit, creating an infinite tiled floor.

---

## Ceiling Rendering

Ceiling rendering is identical to floor rendering, but:
- Render scanlines from **0 to horizon** (top half of screen)
- Use `ceiling_height` instead of `floor_height`
- Calculate `p = horizon - y` (negative distance from horizon)

---

## Coordinate Systems

### World Space
- X: horizontal (left/right)
- Y: vertical (up/down)
- Z: depth (forward/back)
- Origin: arbitrary world origin

### Camera Space
- Origin: camera position
- Z-axis: forward direction
- X-axis: right direction
- Y-axis: up direction
- Vertices transformed by rotation matrices

### Screen Space
- X: 0 to 479 (horizontal pixels)
- Y: 0 to 269 (vertical pixels)
- Origin: top-left corner
- Horizon: Y = 135 (screen center)

---

## Projection Mathematics

### Perspective Projection

Transform from camera space (cx, cy, cz) to screen space:

```lua
-- Picotron uses a simple perspective projection
screen_x = screen_width/2 + (cx/cz) * fov
screen_y = screen_height/2 - (cy/cz) * fov
```

Where:
- `fov` = field of view scale factor (200 in our implementation)
- Division by `cz` creates perspective (far things appear smaller)
- Negative sign on Y because screen Y increases downward

### Camera Transformation

Transform world point (wx, wy, wz) to camera space:

```lua
-- 1. Translate to camera origin
dx = wx - camera.x
dy = wy - camera.y
dz = wz - camera.z

-- 2. Rotate by yaw (horizontal)
cos_yaw = cos(camera.angle)
sin_yaw = sin(camera.angle)
rx = dx * cos_yaw - dz * sin_yaw
rz = dx * sin_yaw + dz * cos_yaw

-- 3. Rotate by pitch (vertical)
cos_pitch = cos(camera.pitch)
sin_pitch = sin(camera.pitch)
ry = dy * cos_pitch - rz * sin_pitch
final_z = dy * sin_pitch + rz * cos_pitch

-- Result: (rx, ry, final_z) in camera space
```

---

## Performance Optimizations

### 1. Precompute Trigonometry
```lua
-- Calculate once per frame
local cos_yaw = cos(player.angle)
local sin_yaw = sin(player.angle)

-- Reuse for all vertices
```

### 2. Depth Buffer (Walls)
- Prevents overdraw by tracking closest surface per column
- Essential for correct occlusion

### 3. Backface Culling
- Precompute normals during level load
- Single dot product test per wall
- Eliminates ~50% of walls from rendering

### 4. Frustum Culling
- Clip walls against near plane before projection
- Adjust UVs during clipping for correct texturing
- Prevents projection errors for objects behind camera

### 5. Distance Culling (Floors)
```lua
if row_distance < 30 then
    -- Only render nearby floor
end
```

### 6. Affine Mapping (Floors)
- Use constant `w` per scanline
- Faster than per-pixel perspective correction
- No visual artifacts for horizontal surfaces

---

## Common Issues and Solutions

### Issue: Walls appear from behind
**Cause**: Backface culling not working
**Solution**: Ensure wall normals point inward (toward room center)

### Issue: Texture swimming on walls
**Cause**: Not using perspective-correct interpolation
**Solution**: Interpolate `1/z` and `u/z` linearly, then divide

### Issue: Floor texture stretched near horizon
**Cause**: Division by very small `p` values
**Solution**: Add minimum threshold `if p > 0.1 then`

### Issue: Floor appears too close/far
**Cause**: Wrong camera height or FOV
**Solution**: Adjust `player.y` (eye height) and `plane_length` (FOV)

### Issue: Seams between floor tiles
**Cause**: Floating point precision in modulo
**Solution**: Use `(coord % 1) * 16` and ensure texture is 16x16

### Issue: Objects behind camera visible
**Cause**: No near-plane clipping
**Solution**: Implement frustum clipping in camera space before projection

---

## Rendering Order

The correct rendering order is critical for proper depth sorting:

```lua
function _draw()
    cls()  -- Clear screen

    -- 1. Render floors (farthest to nearest, naturally sorted)
    render_floors()

    -- 2. Render walls (with depth buffer)
    render_walls()

    -- 3. Render ceilings (optional)
    render_ceilings()

    -- 4. Render sprites/objects (sorted by depth)
    -- render_sprites()

    -- 5. Render HUD (always on top)
    draw_hud()
end
```

**Why this order?**
- Floors are drawn first (painter's algorithm, farthest scanlines first)
- Walls use depth buffer and naturally occlude floors
- Ceilings can be drawn after walls (also depth buffered)
- Sprites must be sorted and drawn back-to-front
- HUD is always on top (no depth testing)

---

## Future Enhancements

### Ceiling Rendering
- Mirror floor algorithm for top half of screen
- Different texture and height

### Sprite Rendering
- Billboarded sprites for enemies/items
- Sort by depth, render back-to-front
- Use alpha blending for transparency

### Lighting
- Distance-based darkening (fog)
- Sector-based lighting levels
- Dynamic lights

### Advanced Features
- Textured floors/ceilings with height variation
- Slopes and stairs
- Portals and room-over-room
- Skybox rendering

---

## References

- **Lode's Raycasting Tutorial**: https://lodev.org/cgtutor/raycasting.html
  - Comprehensive raycasting guide with floor/ceiling rendering

- **Doom Source Code**: https://github.com/id-Software/DOOM
  - Original implementation of visplanes and spans

- **Fabien Sanglard's Doom Review**: https://fabiensanglard.net/doomIphone/
  - Deep dive into Doom's rendering engine

---

## Summary

This raycaster uses two complementary techniques:

1. **Column-based wall rendering** (like Build Engine)
   - Vertical slices with depth buffering
   - Perspective-correct texture mapping

2. **Scanline-based floor rendering** (like Doom)
   - Horizontal spans using ray-plane intersection
   - Affine mapping (constant depth per scanline)

Together, these create a fast, authentic Doom-style FPS engine that runs well on Picotron's limited hardware!
