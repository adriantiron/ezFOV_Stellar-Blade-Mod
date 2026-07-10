-- Shared tuning constants for ezFOV.
-- Gameplay-feel and safety-limit values live here so the knobs are easy to find and
-- adjust in one place; module-internal implementation details stay in their modules.
local Constants = {
    -- Field-of-view clamp bounds, in degrees (applied on live adjustment).
    FOV_MIN = 30,
    FOV_MAX = 120,

    -- Lock-on framing bias clamp, in degrees; applied symmetrically as +/- this value.
    LOCKON_BIAS_LIMIT = 30,

    -- Locomotion classification thresholds: 2D horizontal speed in cm/s.
    LOCO_IDLE_MAX_SPEED = 120, -- speed below this = idle
    LOCO_SLOW_WALK_MAX_SPEED = 240, -- speed below this (and >= idle) = slow walk
    LOCO_SPRINT_MIN_SPEED = 550, -- speed above this = sprint; between the two walk bounds = walk
}

return Constants
