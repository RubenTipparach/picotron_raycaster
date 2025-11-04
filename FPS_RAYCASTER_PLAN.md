# FPS Raycaster System Design Plan for Picotron

## Overview

This document outlines the design and implementation plan for building a sector-based FPS raycaster system in Picotron, inspired by classic games like Doom, Duke Nukem 3D (Build Engine), Star Wars: Dark Forces, and Star Trek Generations.

## Technical Background

### What is Sector-Based Rendering?

Unlike simple grid-based raycasters (like Wolfenstein 3D), sector-based renderers divide the game world into arbitrary polygonal areas called "sectors" with variable floor and ceiling heights. This allows for:

- Non-uniform room shapes (not just square grids)
- Variable ceiling/floor heights per sector
- Portals between sectors for complex level geometry
- "Rooms over rooms" effect (though not true 3D)
- Steps, slopes, and elevation changes

### Key Technologies Compared

1. **Wolfenstein 3D Style (Basic Raycasting)**
   - Grid-based levels (tiles)
   - All walls same height
   - Simple DDA ray traversal
   - Fast but limited

2. **Doom Engine (BSP-Based)**
   - Binary Space Partitioning (BSP) trees
   - Column-based rendering
   - Sectors with arbitrary shapes
   - No true rooms-over-rooms
   - Precomputed BSP tree (8+ seconds per level)

3. **Build Engine (Duke Nukem 3D, Blood, Shadow Warrior)**
   - Sector-portal system
   - Wall-to-wall sorting algorithm
   - "Bunching" system for efficient rendering
   - Real-time portal traversal
   - Supports room-over-room effects
   - O(n) rendering complexity

4. **Jedi Engine (Dark Forces)**
   - Similar to Build engine
   - Sector-based with "adjoins" (portals)
   - Window coordinate clipping through portals
   - 90-degree horizontal FOV
   - Each sector tracks last frame rendered

### Recommended Approach for Picotron

We'll implement a **Build Engine-inspired portal renderer** because:
- No preprocessing required (unlike BSP)
- Efficient real-time rendering
- Simpler than BSP tree generation
- More flexible than grid-based raycasting
- Well-suited for Picotron's Lua environment

---

## Core System Components

### 1. **Map Data Structures**

#### Vertex Structure
```
vertex {
  x: number  -- world X coordinate
  y: number  -- world Y coordinate
}
```

#### Wall Structure
```
wall {
  v1: vertex_index       -- start vertex
  v2: vertex_index       -- end vertex

  -- Portal information
  portal: sector_index   -- nil if solid wall, sector_index if portal

  -- Texturing
  texture: texture_id
  tex_x_offset: number
  tex_y_offset: number

  -- Properties
  flags: number          -- collision, visibility, etc.
}
```

#### Sector Structure
```
sector {
  -- Geometry
  walls: array[wall_index]  -- ordered list of wall indices

  -- Heights
  floor_height: number
  ceiling_height: number

  -- Textures
  floor_texture: texture_id
  ceiling_texture: texture_id

  -- Lighting/Color
  light_level: number (0-255)

  -- Rendering optimization
  last_frame_rendered: number
}
```

#### Player Structure
```
player {
  x: number              -- world position X
  y: number              -- world position Y
  z: number              -- height (for jumping/crouching)
  angle: number          -- viewing angle (radians)
  sector: sector_index   -- current sector

  -- Movement
  velocity_x: number
  velocity_y: number
  velocity_z: number     -- for jumping/falling

  -- Camera
  pitch: number          -- look up/down angle
  fov: number            -- field of view
}
```

#### Map Structure
```
map {
  vertices: array[vertex]
  walls: array[wall]
  sectors: array[sector]

  -- Spawn points, enemies, items, etc.
  entities: array[entity]
}
```

---

### 2. **Rendering System**

#### Core Rendering Pipeline

1. **Initialization**
   - Set up screen buffer (240x135 or 480x270)
   - Create column occlusion array
   - Initialize frame counter

2. **Per-Frame Rendering**
   ```
   for each frame:
     - Clear screen buffer
     - Reset occlusion array (tracks which columns are drawn)
     - Start in player's current sector
     - Recursively render visible sectors via portals
   ```

3. **Sector Rendering Algorithm**
   ```
   function render_sector(sector, clip_left, clip_right, depth):
     -- Check if already rendered this frame
     if sector.last_frame == current_frame then return
     sector.last_frame = current_frame

     -- Transform sector vertices to view space
     transform_vertices_to_viewspace(sector)

     -- Project walls to screen space
     walls_on_screen = []
     for each wall in sector.walls:
       screen_wall = project_wall_to_screen(wall)
       if visible_in_frustum(screen_wall, clip_left, clip_right):
         walls_on_screen.add(screen_wall)

     -- Sort walls front-to-back (painter's algorithm)
     sort_walls_by_depth(walls_on_screen)

     -- Render each wall
     for each screen_wall in walls_on_screen:
       -- Draw ceiling segment
       draw_ceiling_span(screen_wall)

       -- Draw wall segment (or upper/lower steps for portals)
       if screen_wall.is_portal:
         draw_portal_wall(screen_wall)  -- upper/lower parts

         -- Calculate portal clipping bounds
         portal_clip = calculate_portal_clip(screen_wall)

         -- Recurse into next sector
         if depth < MAX_PORTAL_DEPTH:
           render_sector(screen_wall.portal_sector,
                        portal_clip.left,
                        portal_clip.right,
                        depth + 1)
       else:
         draw_solid_wall(screen_wall)

       -- Draw floor segment
       draw_floor_span(screen_wall)

       -- Update occlusion array
       mark_columns_occluded(screen_wall)
   ```

4. **Column Rendering**
   - Each screen column (X coordinate) rendered top-to-bottom
   - Track Y-span that's been drawn (occlusion)
   - Skip columns that are fully occluded

#### Wall Drawing

```
function draw_wall_column(x, top_y, bottom_y, wall, depth):
  -- Calculate texture U coordinate based on wall position
  u = calculate_texture_u(wall, depth)

  -- Get wall height in screen space
  wall_height = bottom_y - top_y

  -- Sample texture and draw vertical strip
  for y = top_y to bottom_y:
    v = (y - top_y) / wall_height  -- texture V coordinate
    color = sample_texture(wall.texture, u, v)

    -- Apply lighting/fog based on depth
    color = apply_lighting(color, depth, wall.sector.light_level)

    -- Draw pixel if not occluded
    if not occluded[x][y]:
      pset(x, y, color)
      occluded[x][y] = true
```

#### Floor/Ceiling Rendering

```
function draw_floor_ceiling_span(x, y_start, y_end, sector, is_floor):
  for y = y_start to y_end:
    -- Ray from camera through pixel (x, y)
    ray = calculate_floor_ray(x, y)

    -- Intersect with floor/ceiling plane
    hit_x, hit_y = intersect_horizontal_plane(
      ray,
      is_floor ? sector.floor_height : sector.ceiling_height
    )

    -- Sample floor/ceiling texture
    texture = is_floor ? sector.floor_texture : sector.ceiling_texture
    color = sample_texture(texture, hit_x, hit_y)

    -- Apply lighting
    color = apply_lighting(color, distance(hit_x, hit_y), sector.light_level)

    pset(x, y, color)
```

---

### 3. **Movement & Collision System**

#### Player Movement
```
function update_player(dt):
  -- Input handling
  if btn(0) then player.angle -= TURN_SPEED * dt      -- left
  if btn(1) then player.angle += TURN_SPEED * dt      -- right

  -- Forward/backward movement
  if btn(2) then  -- forward
    player.velocity_x = cos(player.angle) * MOVE_SPEED
    player.velocity_y = sin(player.angle) * MOVE_SPEED

  if btn(3) then  -- backward
    player.velocity_x = -cos(player.angle) * MOVE_SPEED
    player.velocity_y = -sin(player.angle) * MOVE_SPEED

  -- Apply velocity with collision
  new_x = player.x + player.velocity_x * dt
  new_y = player.y + player.velocity_y * dt

  if not check_collision(new_x, new_y):
    player.x = new_x
    player.y = new_y

    -- Update current sector
    player.sector = find_sector_at(player.x, player.y)

  -- Apply friction
  player.velocity_x *= FRICTION
  player.velocity_y *= FRICTION
```

#### Collision Detection
```
function check_collision(x, y):
  sector = find_sector_at(x, y)

  -- Check all walls in current sector
  for each wall in sector.walls:
    -- If wall is solid (not a portal)
    if not wall.portal:
      -- Check line-circle collision
      if line_circle_collision(wall.v1, wall.v2, x, y, PLAYER_RADIUS):
        return true

  return false
```

#### Sector Finding
```
function find_sector_at(x, y):
  -- Start from current sector for optimization
  if point_in_sector(x, y, player.sector):
    return player.sector

  -- Check neighboring sectors through portals
  for each wall in player.sector.walls:
    if wall.portal:
      if point_in_sector(x, y, wall.portal):
        return wall.portal

  -- Fallback: check all sectors
  for each sector in map.sectors:
    if point_in_sector(x, y, sector):
      return sector

  return player.sector  -- stay in current sector if not found
```

---

### 4. **Texture System**

#### Texture Structure
```
texture {
  width: number
  height: number
  data: array[color]  -- indexed color array
}
```

#### Texture Sampling
```
function sample_texture(texture, u, v):
  -- Wrap/clamp UV coordinates
  u = u % 1.0
  v = v % 1.0

  -- Convert to pixel coordinates
  pixel_x = floor(u * texture.width)
  pixel_y = floor(v * texture.height)

  -- Look up color
  index = pixel_y * texture.width + pixel_x
  return texture.data[index]
```

---

### 5. **Math Utilities**

Essential math functions needed:

```
-- Vector operations
function dot(v1, v2)
function cross(v1, v2)
function normalize(v)
function magnitude(v)

-- Line/wall operations
function line_line_intersection(p1, p2, p3, p4)
function point_side_of_line(point, line_start, line_end)
function line_circle_collision(line_start, line_end, circle_x, circle_y, radius)

-- Sector operations
function point_in_sector(x, y, sector)  -- ray casting algorithm
function sector_bounds(sector)          -- AABB for quick rejection

-- Screen projection
function world_to_screen(x, y, z)
function screen_to_world_ray(screen_x, screen_y)

-- Sorting
function sort_walls_by_distance(walls)  -- for painter's algorithm
```

---

### 6. **Map Editor Tools**

To create levels, we need editor functionality:

#### 2D Editor Mode
- Top-down view of level
- Vertex placement and editing
- Wall creation by connecting vertices
- Sector definition (closed loops of walls)
- Portal assignment (linking sectors via walls)
- Texture assignment

#### 3D Preview Mode
- Real-time preview using the renderer
- Camera fly-through
- Lighting preview

#### Map Format (Simple Text/Lua Format)
```
return {
  vertices = {
    {x=0, y=0},
    {x=100, y=0},
    {x=100, y=100},
    {x=0, y=100},
    -- ...
  },

  walls = {
    {v1=1, v2=2, portal=nil, texture=1},
    {v1=2, v2=3, portal=2, texture=1},  -- portal to sector 2
    -- ...
  },

  sectors = {
    {
      walls={1,2,3,4},
      floor_height=0,
      ceiling_height=64,
      floor_texture=2,
      ceiling_texture=3,
      light_level=255
    },
    -- ...
  },

  player_start = {x=50, y=50, angle=0, sector=1}
}
```

---

## Implementation Phases

### Phase 1: Core Renderer (Foundation)
**Goal:** Get basic sector rendering working

1. Set up project structure in Picotron
2. Implement basic data structures (vertex, wall, sector)
3. Create simple test map (1-2 sectors with portal)
4. Implement view transformation math
5. Implement basic wall projection and column rendering
6. Get single sector rendering on screen

**Deliverable:** Static view of a simple room

---

### Phase 2: Portal Rendering
**Goal:** Render multiple sectors through portals

1. Implement portal clipping system
2. Implement recursive sector traversal
3. Add occlusion tracking
4. Handle portal step rendering (upper/lower walls)
5. Optimize with frame-based sector tracking

**Deliverable:** Multi-room scene visible through doorways

---

### Phase 3: Player Movement
**Goal:** Free movement through the world

1. Implement player input handling
2. Add basic movement (forward/back, turning)
3. Implement collision detection
4. Add sector transition logic
5. Add strafing movement
6. Implement mouse look (if Picotron supports it)

**Deliverable:** Playable first-person navigation

---

### Phase 4: Floor & Ceiling Rendering
**Goal:** Complete the geometry rendering

1. Implement floor ray casting
2. Implement ceiling ray casting
3. Add floor/ceiling texture mapping
4. Optimize span rendering

**Deliverable:** Fully enclosed rooms with textured surfaces

---

### Phase 5: Texturing & Lighting
**Goal:** Visual polish and atmosphere

1. Create texture loading system
2. Implement wall texture mapping with UV coordinates
3. Add distance-based fog/darkness
4. Implement per-sector lighting
5. Add texture offset support for wall alignment

**Deliverable:** Textured, atmospheric environments

---

### Phase 6: Map Editor (Essential Tool)
**Goal:** Create levels without manual data entry

1. Build 2D top-down editor view
2. Add vertex placement/editing
3. Add wall creation tool
4. Implement sector creation (auto-detect closed loops)
5. Add portal assignment tool
6. Add texture picker
7. Add map save/load
8. Create 3D preview mode

**Deliverable:** Full map editor for level creation

---

### Phase 7: Advanced Features
**Goal:** Game-like functionality

1. Add height variations (steps, platforms)
2. Implement sprite rendering (enemies, items, decorations)
3. Add basic enemy AI
4. Implement shooting mechanics
5. Add HUD (health, ammo, etc.)
6. Add doors (animated sector ceiling/floor)
7. Add sound effects (Picotron's PFX6416 synthesizer)

**Deliverable:** Playable FPS game prototype

---

### Phase 8: Optimization & Polish
**Goal:** Smooth performance

1. Profile and optimize hot paths
2. Implement frustum culling
3. Add distance culling for far sectors
4. Optimize texture sampling
5. Add level of detail for distant walls
6. Implement efficient sprite sorting

**Deliverable:** Smooth 30-60 FPS gameplay

---

## Picotron-Specific Considerations

### Graphics Capabilities
- **Resolution:** 240x135 (recommended for performance) or 480x270
- **Color System:** 64 definable colors, 4K color lookup table
- **Draw State:** Blend tables, tline3d, stencil clipping
- **Custom Effects:** Shadow rendering, fog, additive blending via color table

### Performance Targets
- Target 30 FPS minimum
- 60 FPS ideal
- Use Picotron's profiling tools to identify bottlenecks
- Consider lower resolution (240x135) for complex scenes

### Lua Optimization Tips
- Use local variables extensively
- Cache table lookups
- Avoid creating garbage in inner loops
- Use integer math where possible
- Profile with Picotron's built-in profiler

### Cartridge Size
- .p64.png format: 256KB compressed
- Budget texture space carefully
- Use palette-based textures (8-bit indexed)
- Consider procedural textures for variation

---

## Required Art Assets

### Textures
- Wall textures (64x64 or 32x32): ~10-20 variants
  - Stone walls
  - Metal panels
  - Tech walls
  - Doors
- Floor textures (64x64): ~5-10 variants
- Ceiling textures (64x64): ~5-10 variants
- Sprite textures:
  - Weapons (first-person view)
  - Enemies (8 rotation angles)
  - Items (pickups, decorations)
  - Effects (muzzle flash, explosions)

### Color Palette
- Design 64-color palette supporting:
  - Environment colors (walls, floors, ceilings)
  - Character/enemy colors
  - UI colors
  - Lighting gradients (dark to bright versions)

---

## Technical Challenges & Solutions

### Challenge 1: Performance in Lua
**Problem:** Lua can be slow for intensive rendering
**Solutions:**
- Keep resolution lower (240x135)
- Implement aggressive culling
- Use Picotron's built-in graphics primitives where possible
- Cache transformed vertices
- Limit portal recursion depth (3-5 levels)

### Challenge 2: Texture Mapping Precision
**Problem:** Perspective-correct texture mapping is expensive
**Solutions:**
- Use affine texture mapping (acceptable at low res)
- Subdivide long walls for better perspective
- Use simpler textures with less detail at distance

### Challenge 3: Complex Math Operations
**Problem:** Trigonometry and division in inner loops
**Solutions:**
- Pre-calculate sine/cosine lookup tables
- Use incremental calculations where possible
- Cache ray directions per screen column
- Use integer fixed-point math for texture coordinates

### Challenge 4: Collision Detection
**Problem:** Checking collision against many walls is expensive
**Solutions:**
- Only check walls in current sector + adjacent portal sectors
- Use simple circle-line tests (efficient)
- Spatial partitioning if sectors are large
- Early-out tests (bounding boxes)

---

## Success Criteria

### Minimum Viable Product (MVP)
- [ ] Render multiple connected sectors through portals
- [ ] Free first-person movement with collision
- [ ] Textured walls, floors, and ceilings
- [ ] Basic map editor for level creation
- [ ] 30 FPS at 240x135 resolution

### Full Release Goals
- [ ] Smooth 60 FPS at 240x135 resolution
- [ ] Sprite rendering (enemies, items)
- [ ] Shooting mechanics
- [ ] Multiple weapons
- [ ] Enemy AI
- [ ] Sound effects
- [ ] HUD and UI
- [ ] 5-10 playable levels
- [ ] Doors and interactive elements

---

## Development Tools Needed

### Core Engine Code
1. **main.lua** - Entry point, game loop
2. **renderer.lua** - Sector rendering system
3. **player.lua** - Player state and control
4. **collision.lua** - Collision detection
5. **map.lua** - Map data loading and management
6. **texture.lua** - Texture management and sampling
7. **math_utils.lua** - Vector, geometry, projection math
8. **entity.lua** - Sprites, enemies, items

### Editor Tools
1. **editor_main.lua** - Editor entry point
2. **editor_2d.lua** - 2D map view and editing
3. **editor_3d.lua** - 3D preview mode
4. **editor_ui.lua** - UI elements (buttons, panels)
5. **editor_tools.lua** - Vertex, wall, sector editing tools

### Content Creation Tools
1. Texture creation/import tool
2. Palette editor
3. Sprite editor (8-direction rotation)
4. Sound effect synthesizer (PFX6416)

---

## Learning Resources

### Essential Reading
1. **Lodev.org Raycasting Tutorial** - Basic raycasting fundamentals
2. **Fabien Sanglard's Build Engine Internals** - Deep dive into Build engine
3. **The Force Engine Blog** - Dark Forces Jedi Engine details
4. **Portal Rendering Wikipedia** - Portal/sector rendering overview
5. **Picotron Manual** - Official API reference

### Reference Implementations
- Build Engine source code
- Bisqwit's Portal Rendering Engine
- Various raycasting tutorials (adapt from grid to sector-based)

---

## Conclusion

This project will create a fully functional sector-based FPS raycaster in Picotron, capable of rendering complex multi-room environments with portals, textured surfaces, and proper collision detection. The phased approach ensures steady progress from basic rendering to a complete game engine with editing tools.

The Build Engine-inspired approach is well-suited for Picotron's capabilities, offering a good balance between visual complexity and performance in a Lua environment. With careful optimization and the use of Picotron's advanced graphics features (blend tables, color lookup tables), we can achieve a smooth, playable FPS experience reminiscent of classic 90s shooters.

**Next Steps:** Await approval, then begin Phase 1 - Core Renderer implementation.
