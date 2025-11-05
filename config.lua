--[[pod_format="raw"]]

--[[
  Configuration file for FPS Raycaster

  All rendering constants and settings are centralized here
  for easy modification and consistency across the codebase.
]]

local Config = {}

-- Screen dimensions
Config.SCREEN_WIDTH = 480
Config.SCREEN_HEIGHT = 270
Config.SCREEN_CENTER_X = Config.SCREEN_WIDTH / 2
Config.SCREEN_CENTER_Y = Config.SCREEN_HEIGHT / 2

-- Field of view
Config.FOV = 200  -- Higher = wider angle, lower = narrower/zoomed

-- Texture settings
Config.TEXTURE_SIZE = 32  -- Size of texture sprites (32x32)
Config.UV_SCALE = .25     -- UV scale factor for floor/ceiling (smaller = bigger tiles)

-- Sprite indices
Config.SPRITE_WALL = 0
Config.SPRITE_CEILING = 1
Config.SPRITE_FLOOR = 2

-- Rendering limits
Config.MAX_WALL_COLUMNS = Config.SCREEN_WIDTH  -- 480 columns for batched wall rendering
Config.NEAR_PLANE = 0.1  -- Near clipping plane distance

-- World geometry
Config.WALL_HEIGHT = 4
Config.FLOOR_HEIGHT = 0
Config.CEILING_HEIGHT = Config.WALL_HEIGHT

-- Fog settings (depth-based dithering)
Config.FOG_START = 10  -- Distance where fog starts
Config.FOG_END = 20    -- Distance where fog is maximum

-- Player settings
Config.PLAYER_EYE_HEIGHT = 1.7
Config.PLAYER_COLLISION_RADIUS = 0.3

-- Movement settings
Config.MOVE_SPEED = 3
Config.JUMP_SPEED = 5
Config.GRAVITY = 9.8
Config.FRICTION = 0.85

-- Camera settings
Config.TURN_SPEED = 0.02       -- Mouse horizontal sensitivity
Config.PITCH_SPEED = 0.02      -- Mouse vertical sensitivity
Config.MAX_PITCH = 0.125       -- Max look up/down: 45 degrees (45/360 = 0.125)

-- Arrow key rotation (when mouse not locked)
Config.ARROW_TURN_SPEED = 0.015   -- ~0.54 degrees per frame
Config.ARROW_PITCH_SPEED = 0.01   -- ~0.36 degrees per frame

-- Portal rendering settings
Config.SECTOR_BORDER_TOLERANCE = 0.05  -- Buffer zone to prevent flickering when crossing portals

return Config
