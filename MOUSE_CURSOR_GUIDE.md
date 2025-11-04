# Picotron Mouse Cursor System Guide

## Overview

Picotron provides a flexible cursor system that allows you to customize the mouse cursor appearance and behavior for your FPS raycaster game. This guide covers all available cursor options and how to use them effectively.

---

## WASD Camera-Relative Movement (CRITICAL)

### **Picotron's Coordinate System**
- Angles: 0-1 represents 0-360 degrees
- 0 = right (east)
- 0.25 = up (north)
- 0.5 = left (west)
- 0.75 = down (south)

### **Correct WASD Movement Math (From Working Lounge Scene)**

```lua
-- WASD movement relative to camera yaw (horizontal angle)
-- This is the CORRECT implementation from the lounge scene

-- Forward direction uses sin/cos for yaw angle
local forward_x = sin(camera.ry)   -- ry = yaw angle
local forward_z = cos(camera.ry)

-- Right direction (90 degrees from forward)
local right_x = cos(camera.ry)
local right_z = -sin(camera.ry)    -- Negative sin for right

-- Apply movement
if key("w") then  -- Forward
    camera.x += forward_x * move_speed
    camera.z += forward_z * move_speed
end

if key("s") then  -- Backward
    camera.x -= forward_x * move_speed
    camera.z -= forward_z * move_speed
end

if key("a") then  -- Strafe left
    camera.x += right_x * move_speed
    camera.z += right_z * move_speed
end

if key("d") then  -- Strafe right
    camera.x -= right_x * move_speed
    camera.z -= right_z * move_speed
end
```

### **Why The Lounge Method Works**

1. **Forward uses sin/cos pattern**
   - `forward_x = sin(angle)`
   - `forward_z = cos(angle)`
   - This aligns with how Picotron's rotation works

2. **Right uses cos/-sin pattern**
   - `right_x = cos(angle)`
   - `right_z = -sin(angle)` ← **Negative** for correct right direction

3. **A key ADDS right vector** (counterintuitive but correct!)
   - Moving "left" adds the "right" vector
   - This works because of the coordinate system

4. **D key SUBTRACTS right vector**
   - Moving "right" subtracts the "right" vector
   - Again, coordinate system specific

### **Why This Works**

1. **Forward** = direction camera faces
   - cos/sin of current angle gives forward vector

2. **Right** = 90° clockwise from forward
   - In Picotron: angle - 0.25 (NOT angle + 0.25)
   - 0.25 = 90°, so subtracting rotates clockwise

3. **Left strafe** = negative of right
   - Subtract the right vector

4. **Movement applies to X and Z** (not Y)
   - Y is height (jumping/falling)
   - X/Z is horizontal plane

### **Common Mistakes to Avoid**

❌ **WRONG:**
```lua
local right_x = cos(player.angle + 0.25)  -- This makes right = left!
```

✅ **CORRECT:**
```lua
local right_x = cos(player.angle - 0.25)  -- Right is clockwise
```

---

## Window Cursor API

The cursor is configured using the `window{}` function with a `cursor` parameter:

```lua
window{cursor = value}
```

Where `value` can be:

### 1. **Numeric Value (0 or integer)**
- `0` - Disables/hides the cursor completely
- `integer` - Uses sprite at that index as cursor

```lua
-- Hide cursor completely
window{cursor = 0}

-- Use sprite index 5 as cursor
window{cursor = 5}
```

### 2. **String Value (System Cursors)**
Picotron provides several built-in system cursors:

#### `"pointer"` (Default)
- Hand with a finger that presses down while mouse button is pressed
- Good for: Menu navigation, UI interaction

```lua
window{cursor = "pointer"}
```

#### `"grab"`
- Open hand that changes into grabbing pose while mouse button is pressed
- Good for: Dragging objects, pan/zoom controls

```lua
window{cursor = "grab"}
```

#### `"dial"`
- Hand in a dial-twirling pose that disappears while mouse button is held down
- Good for: Rotation controls, value adjustment

```lua
window{cursor = "dial"}
```

#### `"crosshair"`
- Simple crosshair cursor (perfect for FPS games!)
- Good for: Aiming, precision targeting, FPS games

```lua
window{cursor = "crosshair"}
```

#### `"edit"`
- Text editing cursor
- Good for: Text input fields

```lua
window{cursor = "edit"}
```

### 3. **Userdata (Custom Sprite)**
You can use a sprite userdata object (gfx type) as a custom cursor:

```lua
-- Load a custom cursor from podded sprite data
local custom_cursor = --[[pod_type="gfx"]]unpod("b64:bHo0ABoAAAAYAAAA8AlweHUAQyAQEATwVgcQB8AX0BfABxAH8FY=")
window{cursor = custom_cursor}
```

---

## Mouse Lock for FPS Controls

For FPS-style games, you need smooth mouse look without the cursor moving around the screen. Picotron provides the `mouselock()` function:

### Function Signature
```lua
dx, dy = mouselock(lock, event_sensitivity, move_sensitivity)
```

### Parameters

1. **`lock`** (boolean)
   - `true` - Request mouse capture from OS
   - `false` - Release mouse capture
   - Controls whether the mouse is "locked" for FPS-style control

2. **`event_sensitivity`** (number, 0..4)
   - Controls how fast dx, dy change
   - `1.0` = once per Picotron pixel
   - Lower values (e.g., `0.05`) = slower, smoother rotation
   - Higher values = faster rotation

3. **`move_sensitivity`** (number, 0..4)
   - Controls cursor movement speed
   - `1.0` = cursor continues moving at same speed
   - `0` = cursor stops moving (ideal for FPS)
   - Higher values = cursor moves faster

### Return Values

- **`dx`** - Horizontal mouse movement since last frame
- **`dy`** - Vertical mouse movement since last frame

---

## FPS Implementation Example

Here's how the FPS raycaster implements mouse look:

```lua
-- Global state
local mouse_locked = false

-- In your _init() function
function _init()
    -- Set crosshair cursor for FPS feel
    window{cursor = "crosshair"}
    mouse_locked = true
end

-- In your _update() function
function _update()
    update_mouse_look()
end

-- Mouse look implementation
function update_mouse_look()
    -- Use mouselock for FPS-style mouse look
    -- event_sensitivity 0.5 = smooth rotation speed
    -- move_sensitivity 0 = prevent cursor from moving
    local dx, dy = mouselock(mouse_locked, 0.5, 0)

    if dx and dy then
        -- Update player rotation based on mouse movement
        player.angle -= dx * TURN_SPEED
        player.pitch -= dy * PITCH_SPEED

        -- Clamp pitch to prevent over-rotation
        player.pitch = mid(-1.5, player.pitch, 1.5)
    end
end

-- Toggle mouse lock with Escape key
function update_movement(dt)
    -- ... other movement code ...

    if keyp("escape") then
        mouse_locked = not mouse_locked
        if mouse_locked then
            window{cursor = "crosshair"}
        else
            window{cursor = "pointer"}
        end
    end
end
```

---

## Common Patterns

### 1. **Hide Cursor During Gameplay**
```lua
function _init()
    window{cursor = 0}  -- Hide cursor completely
end
```

### 2. **Toggle Between Menu and Game Cursor**
```lua
local in_menu = false

function toggle_menu()
    in_menu = not in_menu

    if in_menu then
        window{cursor = "pointer"}  -- Show menu cursor
        mouse_locked = false
    else
        window{cursor = "crosshair"}  -- Show FPS cursor
        mouse_locked = true
    end
end
```

### 3. **Custom Animated Cursor**
```lua
local cursor_frame = 0

function _update()
    cursor_frame = (cursor_frame + 1) % 4
    window{cursor = 10 + cursor_frame}  -- Cycle through sprites 10-13
end
```

---

## Best Practices for FPS Games

1. **Use `"crosshair"` cursor** - It's designed for aiming and looks professional
2. **Lock the mouse** - Always use `mouselock()` with `move_sensitivity = 0`
3. **Provide toggle** - Let players press Escape to unlock mouse for menus
4. **Tune sensitivity** - Adjust `event_sensitivity` (0.3-0.8 is usually good)
5. **Visual feedback** - Draw a center-screen crosshair for precise aiming
6. **Clamp pitch** - Prevent looking too far up/down (±1.5 radians is good)

---

## Complete Cursor Configuration Example

```lua
-- Fullscreen FPS with custom settings
function _init()
    -- Set up fullscreen mode
    vid(0)  -- 480x270 resolution

    -- Configure window
    window{
        cursor = "crosshair",        -- FPS-style cursor
        pauseable = false,           -- Disable pause menu
        can_escape_fullscreen = true -- Allow Alt+Enter to exit
    }

    -- Enable mouse lock
    mouse_locked = true
end
```

---

## Troubleshooting

### Cursor not hiding?
- Make sure you use `window{cursor = 0}`, not `window{cursor = nil}`

### Mouse look too fast/slow?
- Adjust the `event_sensitivity` parameter in `mouselock()`
- Also multiply dx/dy by a custom sensitivity multiplier

### Mouse still moves on screen?
- Set `move_sensitivity = 0` in `mouselock()`

### Cursor jumps when locking?
- This is normal OS behavior; the delta values will normalize after first frame

---

## Additional Resources

- See [main.lua](main.lua) for complete FPS implementation
- Picotron Manual: `/system/docs/picotron_manual.txt`
- Section: "Input Controls" (line ~2322)
- Section: "Window Management" (line ~3115)

---

## Summary

The Picotron cursor system is powerful and flexible:

- **System cursors**: `"pointer"`, `"grab"`, `"dial"`, `"crosshair"`, `"edit"`
- **Custom cursors**: Use sprite indices or userdata
- **Hide cursor**: `window{cursor = 0}`
- **FPS mouse lock**: `mouselock(true, 0.5, 0)`

For FPS games, the combination of `window{cursor="crosshair"}` and `mouselock()` provides a professional, smooth mouse look experience!
