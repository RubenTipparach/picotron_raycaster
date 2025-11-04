# Debug Visualization Guide

## What You'll See

The FPS raycaster now includes **debug wireframe rendering** to help you visualize the level geometry even if textures aren't rendering.

### Color Coding

- **Light Blue Lines** - Floor edges (all edges of floor polygons)
- **Yellow Wireframes** - Walls (outer boundary edges with height)
  - Bottom edge
  - Top edge
  - Vertical edges connecting bottom to top

### Why Debug Lines?

Sometimes `tline3d()` may not render textures properly if:
- Sprites 0 and 1 don't exist or are empty
- Texture coordinates are out of range
- Z-depth issues cause clipping

The debug lines use simple `line()` drawing which always works, so you can see:
- Level shape and layout
- Wall positions and heights
- Camera orientation
- Movement through the space

## HUD Information

The on-screen display shows:

```
pos: X, Z           - Player world position
angle: N°           - Horizontal rotation (0-360°)
pitch: N°           - Vertical look angle
verts: N            - Total vertices loaded from OBJ
walls: N            - Outer wall edges detected
faces: N            - Floor polygons loaded
```

## Controls

**Movement:**
- `W` - Move forward
- `S` - Move backward
- `A` - Strafe left
- `D` - Strafe right
- `Space` - Jump

**Camera:**
- `Mouse` - Look around (when locked)
- `Tab` - Toggle mouse lock/unlock

**Tips:**
- Press Tab to lock mouse for smooth camera control
- Use WASD to walk around and see walls from different angles
- Jump to get a higher view of the level
- Check the vertex/wall/face counts to verify OBJ loaded correctly

## Troubleshooting

### No lines visible?
- Check that `level_test.obj` loaded (see console output)
- Verify verts/walls/faces counts are > 0
- Try moving with WASD - you might be inside a wall
- Look around with mouse - geometry might be behind you

### Lines look weird?
- Might be Z-fighting at very close range
- Try moving back a bit
- Check that wall heights are reasonable (default: 2.5 units)

### Can't see floor edges?
- Floor edges are at Y=0, look down to see them
- If player Y is high, floor might be far away
- Check OBJ file has faces defined (`f` lines)

### Walls rendering as single lines?
- Wall height might be 0
- Check `WALL_HEIGHT` constant (should be 2.5)
- Verify OBJ has valid edge boundaries

## Expected Output Example

For a simple square room, you should see:
```
     ╔═══════════════╗   <- Top edges (yellow)
     ║               ║
     ║               ║   <- Vertical edges (yellow)
     ║               ║
     ╚═══════════════╝   <- Bottom edges (yellow)

  ┌─────────────────┐    <- Floor edges (light blue)
  │                 │
  └─────────────────┘
```

## Next Steps

Once you can see the debug wireframes:

1. Verify level shape matches your OBJ file
2. Test movement and collision
3. Confirm wall heights look correct
4. Create sprites 0 and 1 for textures
5. Watch tline3d render over the wireframes!

The debug lines will always render alongside textures, so you can keep them on to understand what's happening under the hood.
