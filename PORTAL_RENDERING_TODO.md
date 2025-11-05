# Portal Rendering Implementation

## Goal
Implement Doom-style portal rendering system for efficient multi-height geometry and occlusion culling.

## Benefits
- Only render visible sectors (massive performance gain)
- Supports multiple floor heights naturally
- Enables room-over-room with careful design
- Perfect for indoor environments

## Implementation Steps

### ✅ Step 1: Reorganize map loader to build sector tree
**Status:** COMPLETE

**What was done:**
- Added `sectors` array to map data structure
- Created `build_sectors()` function that:
  - Converts each floor polygon into a sector
  - Identifies portals (shared edges between sectors)
  - Identifies solid walls (boundary edges)
  - Stores wall normals for backface culling
- Created `find_player_sector()` function using point-in-polygon test
- Updated debug visualization:
  - Green lines = Portals
  - Yellow lines = Solid walls
- Added HUD display showing:
  - Current sector number
  - Portal count
  - Solid wall count

**Files modified:**
- `main.lua`: Added sector building and visualization

---

### ✅ Step 2: Implement column-based occlusion tracking
**Status:** COMPLETE

**Goal:** Track which screen columns are already filled by walls to cull geometry behind them.

**What was done:**
- Created occlusion buffer (480 columns, each tracks visible Y range)
- Added `init_occlusion_buffer()` - initializes all columns as fully open
- Added `mark_column_filled()` - marks a column as partially/fully filled by a wall
- Added `is_column_occluded()` - checks if a column is fully filled
- Added `is_wall_occluded()` - checks if an entire wall segment is occluded
- Added `get_occlusion_stats()` - returns occlusion statistics for debugging
- Integrated into wall renderer:
  - Skip fully occluded columns (early exit)
  - Mark columns as filled after drawing
  - Uses goto label for efficient skipping
- Added HUD display showing:
  - Occluded column count
  - Occlusion percentage

**How it works:**
- Each column starts with visible range [0, 269] (full screen height)
- When a wall is drawn in a column, the range shrinks
- If a wall fills from top: `top_y` moves down to wall bottom
- If a wall fills from bottom: `bottom_y` moves up to wall top
- When `top_y >= bottom_y`, column is fully occluded
- Fully occluded columns skip all rendering (massive performance gain)

**Files modified:**
- `raycaster.lua`: Added occlusion buffer system
- `main.lua`: Initialize buffer each frame, display stats in HUD

---

### ✅ Step 3: Add recursive portal rendering with clipping
**Status:** COMPLETE

**Goal:** Recursively render connected sectors through visible portals.

**What was done:**
- Created `render_portals()` - Main portal rendering entry point with:
  - Recursive sector traversal with depth limit
  - Visited set to prevent infinite loops
  - Early exit when screen is fully occluded
  - Backface culling for portals
  - Separate rendering for solid walls vs portals
  - Returns visited sectors for wireframe visualization
- Implemented `render_sector_floor()` - Renders a single sector's floor polygon:
  - Camera space transform
  - Near plane clipping
  - Backface culling
  - Triangle fan rasterization with perspective-correct UVs
- Implemented `render_sector_ceiling()` - Renders a single sector's ceiling polygon:
  - Same as floor but at ceiling height
  - Inverted backface culling (view from below)
- Implemented `render_wall_segment()` - Single wall rendering:
  - Extracted from `render_walls()` for per-wall rendering
  - Frustum clipping with `clip_wall_quad()`
  - Perspective-correct texture mapping
  - Occlusion culling integration
  - Immediate rendering (no batching)
- Integrated with main rendering:
  - Added `use_portal_rendering` toggle (press P key)
  - Added `rendered_sectors` tracking for wireframe
  - Portal mode replaces floor/ceiling/wall rendering
  - Classic mode still available for comparison
- Updated wireframe visualization:
  - Culled sectors shown in dark blue
  - Rendered sectors shown in yellow (solid) / green (portal)
  - Clearly shows which sectors are visible vs culled
- Added HUD display:
  - Shows current render mode (portal/classic)
  - Press P to toggle between modes

**Future optimization opportunities:**
- Portal screen bounds clipping (track min/max X per portal)
- Better occlusion tracking for partial fills
- Portal wall rendering (upper/lower walls when heights differ)
- Depth-based portal traversal order

**Files modified:**
- `raycaster.lua`:
  - Completed `render_sector_ceiling()` (lines 320-421)
  - Completed `render_wall_segment()` (lines 427-545)
  - Updated `render_portals()` to return visited sectors (line 137, 210-215)
- `main.lua`:
  - Added `use_portal_rendering` toggle and `rendered_sectors` tracking (lines 81-82)
  - Added P key binding to toggle portal rendering (lines 555-558)
  - Modified `_draw()` to support both rendering modes (lines 637-660)
  - Updated wireframe to show culled sectors (lines 692-711)
  - Added render mode to HUD (lines 959-962)

---

## Architecture Summary

### Current Rendering (Working):
```
_draw() {
  init_occlusion_buffer()
  render_floors(all faces)      // Renders every floor polygon
  render_ceilings(all faces)    // Renders every ceiling polygon
  render_walls(all walls)       // Renders every wall with depth buffer
}
```

### Portal Rendering (In Progress):
```
_draw() {
  init_occlusion_buffer()
  player_sector = find_player_sector()
  render_portals(player_sector) {
    render_sector(sector) {
      render_sector_floor(sector.floor_face)
      render_sector_ceiling(sector.floor_face + height)

      for wall in sector.walls {
        if wall.portal_to {
          // Portal - render connecting wall parts
          render_portal_walls(wall, sector, neighbor_sector)
          // Recurse through portal
          render_sector(wall.portal_to)
        } else {
          // Solid wall
          render_wall_segment(wall)
        }
      }
    }
  }
}
```

### Benefits of Portal Rendering:
- ✅ Only render visible sectors (massive perf gain in complex levels)
- ✅ Natural support for multi-height floors
- ✅ Room-over-room with careful design
- ✅ Occlusion culling prevents overdraw
- ✅ No sorting needed (front-to-back traversal)

---

## Notes
- Portal rendering works best with convex sectors
- Non-convex sectors should be split into convex pieces
- Portal clipping ensures proper draw order without sorting
- The framework is ready - just need to complete the helper functions
