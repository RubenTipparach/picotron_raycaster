# FPS Raycaster for Picotron

A sector-based FPS raycaster engine for Picotron, inspired by classic games like Doom, Duke Nukem 3D (Build Engine), and Star Wars: Dark Forces.

## Features

✅ **OBJ File Loader** - Loads 3D models from Blender/other tools
✅ **Outer Edge Detection** - Automatically extracts only boundary walls from polygon meshes
✅ **tline3d Rendering** - Hardware-accelerated textured 3D triangle rendering
✅ **Wall Rendering** - Vertical wall quads with texture mapping (sprite-0)
✅ **Floor Rendering** - Horizontal floor triangles with texture mapping (sprite-1)
✅ **Collision Detection** - Circle-line segment collision prevents walking through walls
✅ **WASD Movement** - Classic FPS movement with strafe support
✅ **Mouse Look** - Smooth FPS camera control with pitch/yaw
✅ **Mouse Lock** - Proper mouse capture using `mouselock()` API
✅ **Jump/Gravity** - Physics system with jumping and ground collision

---

## Quick Start

### 1. Load the Cartridge
```bash
# In Picotron terminal
load fps-raycaster.p64
run
```

### 2. Controls
- **W/A/S/D** - Move forward/left/backward/right
- **Mouse** - Look around (when locked)
- **Space** - Jump
- **Escape** - Toggle mouse lock

### 3. Create Levels in Blender

1. Model your level as a single flat mesh (floor plan)
2. Keep it simple - just a 2D shape with faces
3. Export as OBJ file: `File > Export > Wavefront (.obj)`
4. Place in cartridge folder as `level_test.obj`
5. The engine will automatically extract outer walls

---

## File Structure

```
fps-raycaster.p64/
├── main.lua                  # Main game code
├── level_test.obj            # Example level geometry
├── gfx/
│   ├── 0.gfx                # Wall texture (sprite-0)
│   └── 1.gfx                # Floor texture (sprite-1)
├── README.md                 # This file
├── MOUSE_CURSOR_GUIDE.md     # Detailed mouse/cursor documentation
└── FPS_RAYCASTER_PLAN.md     # Full technical design document
```

---

## How It Works

### 1. OBJ Loading
The `load_obj()` function parses Wavefront OBJ files:
- Reads vertex positions (`v x y z`)
- Reads face definitions (`f v1 v2 v3 ...`)
- Stores geometry in map data structure

### 2. Outer Edge Detection
The `extract_outer_walls()` function finds boundary edges:
- Counts how many times each edge appears in faces
- Edges appearing only **once** are outer boundaries
- Edges appearing **twice** are internal (discarded)
- Result: Clean room perimeter for collision and rendering

### 3. Rendering Pipeline

#### Floor Rendering (`render_floors`)
- Triangulates each face using fan triangulation
- Transforms vertices to camera space
- Projects to screen space
- Renders with `tline3d()` using sprite-1 for texture

#### Wall Rendering (`render_walls`)
- For each outer wall edge:
  - Create 4 vertices (bottom-left, top-left, bottom-right, top-right)
  - Transform and project to screen
  - Render as 2 triangles using `tline3d()` with sprite-0

### 4. Collision Detection
- Circle-line segment collision test
- Player has radius of 0.3 units
- Checks against all outer wall edges
- Includes wall sliding for smooth movement

### 5. Camera System
- **Position**: `(x, y, z)` in world space
- **Yaw**: Horizontal rotation (angle)
- **Pitch**: Vertical rotation (look up/down)
- **Projection**: Perspective projection with FOV control

---

## Technical Details

### Data Structures

```lua
-- Vertex
{x, y, z}

-- Wall (outer edge)
{v1, v2, height}

-- Face (floor polygon)
{v1, v2, v3, v4, ...}

-- Player
{
  x, y, z,           -- position
  angle, pitch,      -- rotation
  vx, vy, vz,        -- velocity
  radius             -- collision radius
}
```

### Rendering Math

**World → Camera Space**
```lua
dx = world_x - player.x
dy = world_y - player.y
dz = world_z - player.z

-- Rotate by yaw
rx = dx * cos(angle) - dz * sin(angle)
rz = dx * sin(angle) + dz * cos(angle)

-- Rotate by pitch
ry = dy * cos(pitch) - rz * sin(pitch)
final_z = dy * sin(pitch) + rz * cos(pitch)
```

**Camera → Screen Space**
```lua
screen_x = 240/2 + (rx / final_z) * FOV
screen_y = 135/2 - (ry / final_z) * FOV
```

---

## Customization

### Change Wall Height
```lua
local WALL_HEIGHT = 2.5  -- Adjust this value
```

### Adjust Movement Speed
```lua
local MOVE_SPEED = 3       -- Movement speed
local TURN_SPEED = 0.002   -- Mouse sensitivity
```

### Change Resolution
```lua
function _init()
    vid(0)  -- 480x270 (default)
    -- or
    vid(3)  -- 240x135 (better performance)
end
```

### Create Wall/Floor Textures
1. Open sprite editor (workspace 2)
2. Edit sprite 0 for wall texture (8x8 or 16x16)
3. Edit sprite 1 for floor texture
4. Save with Ctrl+S

---

## Level Design Tips

### In Blender:

1. **Start Simple**
   - Create a plane
   - Edit mode (Tab)
   - Extrude and shape your room layout

2. **Keep It Flat**
   - All vertices should have same Y coordinate (height)
   - This represents the floor plan

3. **Close Your Shapes**
   - Make sure all walls form closed polygons
   - No gaps or holes

4. **Export Settings**
   - File > Export > Wavefront (.obj)
   - ✅ Apply Modifiers
   - ✅ Write Normals
   - ✅ Include UVs
   - ✅ Triangulate Faces

5. **Example Layout**
   ```
   ┌─────┬─────┐
   │     │     │  Simple L-shaped room
   │     │     │  with 3 connected areas
   ├─────┤     │
   │           │
   └───────────┘
   ```

---

## Performance Tips

1. **Limit Polygon Count**
   - Keep faces under 50 for smooth performance
   - Simplify room geometry

2. **Lower Resolution**
   - Use `vid(3)` for 240x135 (4x faster rendering)

3. **Reduce Texture Size**
   - 8x8 textures are faster than 16x16

4. **Limit Walls**
   - Complex perimeters have more walls to render
   - Keep room shapes simple

---

## Known Limitations

1. **No Rooms Over Rooms**
   - Can't have multi-story buildings
   - All floors are at Y=0

2. **Single Texture Per Surface**
   - All walls use sprite-0
   - All floors use sprite-1

3. **No Slopes**
   - Floors and ceilings are flat
   - Walls are vertical

4. **Simple Collision**
   - Circle-based only
   - No complex collision shapes

---

## Future Enhancements

Potential features to add:

- [ ] Multiple texture support per wall
- [ ] Ceiling rendering
- [ ] Sprite entities (enemies, items)
- [ ] Doors (animated wall heights)
- [ ] Lighting system (per-sector brightness)
- [ ] Texture scrolling/animation
- [ ] Particle effects
- [ ] Sound effects integration
- [ ] Multiple level support
- [ ] Save/load system

---

## Documentation

- **[MOUSE_CURSOR_GUIDE.md](MOUSE_CURSOR_GUIDE.md)** - Complete guide to Picotron's cursor and mouse lock system
- **[FPS_RAYCASTER_PLAN.md](FPS_RAYCASTER_PLAN.md)** - Full technical design document with implementation phases
- **[main.lua](main.lua)** - Fully commented source code

---

## Troubleshooting

### "Error: Could not load level_test.obj"
- Make sure `level_test.obj` is in the cartridge folder
- Check file is valid OBJ format
- Try re-exporting from Blender

### No walls visible
- Check that sprites 0 and 1 exist in `gfx/0.gfx`
- Verify your OBJ has faces, not just vertices
- Make sure camera is inside the level bounds

### Falling through floor
- Player starts at Y=1.7 (eye height)
- Floor should be at Y=0
- Check your OBJ vertical coordinates

### Performance issues
- Try `vid(3)` for lower resolution
- Reduce number of faces in level
- Simplify wall geometry

### Mouse not locking
- Press Escape to toggle mouse lock
- Check that you're running in fullscreen or windowed mode
- Try `window{cursor="crosshair"}` in _init()

---

## Credits

Built with Picotron by Lexaloffle Games
Inspired by:
- Doom (id Software)
- Build Engine (Ken Silverman)
- Dark Forces (LucasArts)
- Wolfenstein 3D (id Software)

---

## License

This is a sample project for Picotron. Feel free to use and modify for your own projects!

---

## Version History

**v1.0** (2025-11-04)
- Initial release
- OBJ loading with outer edge detection
- tline3d rendering for walls and floors
- Full FPS controls with mouse lock
- Collision detection
- Jump/gravity physics
- Complete documentation
