local Config    = require("config")
local Camera    = require("camera")
local PlayerCtx = require("playercontext")
local Hooks     = require("hooks")
local Stance    = require("stance")

local cfg = Config.get()

Camera.init(cfg)
Camera.disable_camera_collision(cfg.DisableCameraCollision)

Hooks.init(Camera, Config)

-- ==================== F8: Reload config ====================

RegisterKeyBindAsync(Key.F8, {}, function()
    cfg = Config.reload()
    Camera.init(cfg) -- Keep camera's internal reference perfectly synchronized

    ExecuteInGameThread(function()
        local isTPS    = (PlayerCtx.is_tps_mode() == true)
        local isLockOn = (PlayerCtx.is_lock_on()  == true)
        local isBattle = (PlayerCtx.is_battle()    == true)

        -- Fetch the live locomotion state (idle, slow_walk, walk, sprint)
        local locoState = PlayerCtx.get_locomotion_state and PlayerCtx.get_locomotion_state()

        local fov =
            (isTPS    and (cfg.fovs.tps or cfg.fovs.fov))
            or (isLockOn and cfg.EnableLockOnCamera and (cfg.fovs.lockon or cfg.fovs.combat))
            or (isBattle and cfg.fovs.combat)
            or (locoState == "idle" and cfg.EnableIdleCamera and cfg.fovs.idle)
            or (locoState == "slow_walk" and cfg.EnableWalkingCamera and cfg.fovs.walk)
            or (locoState == "sprint" and cfg.EnableSprintingCamera and cfg.fovs.sprint)
            or cfg.fovs.fov

        local pos =
            (isLockOn and cfg.EnableLockOnCamera and cfg.LockOnPosition)
            or (isBattle and cfg.CombatPosition)
            or (locoState == "idle" and cfg.EnableIdleCamera and cfg.IdlePosition)
            or (locoState == "slow_walk" and cfg.EnableWalkingCamera and cfg.WalkPosition)
            or (locoState == "sprint" and cfg.EnableSprintingCamera and cfg.SprintPosition)
            or cfg.DefaultPosition

        if isLockOn and cfg.EnableLockOnCamera then
            Camera.start_enforcement(cfg.LockOnPosition, fov)
        else
            Camera.set_fov_via_function(fov)
            Camera.set_camera_relative_location(pos)
        end

        Camera.disable_camera_collision(cfg.DisableCameraCollision)

        print(string.format("[Main] Reloaded. TPS=%s Lock=%s Battle=%s FOV=%.0f Pos=(%.0f,%.0f,%.0f) YawBias=%.1f PitchBias=%.1f\n",
            tostring(isTPS), tostring(isLockOn), tostring(isBattle),
            fov, pos.x, pos.y, pos.z, cfg.LockOnYawBias or 0, cfg.LockOnPitchBias or 0))
    end)
end)

-- ==================== Helpers ====================

local function ensure_lockon_enforcement(cfg)
    if Camera.is_enforcing() then return end
    local fov = cfg.fovs.lockon or cfg.fovs.combat or cfg.fovs.fov
    Camera.start_enforcement(cfg.LockOnPosition, fov)
    print("[Main] Restarted dead enforcement loop\n")
end

local function adjust_current_fov(delta)
    local cfg = Config.get()
    local profile = Stance.get_current_profile()

    if     profile == "tps"    then cfg.fovs.tps    = (cfg.fovs.tps    or cfg.fovs.fov) + delta
    elseif profile == "lockon" then cfg.fovs.lockon = (cfg.fovs.lockon or cfg.fovs.combat or cfg.fovs.fov) + delta
    elseif profile == "battle" then cfg.fovs.combat = (cfg.fovs.combat or cfg.fovs.fov) + delta -- Defensive fallback added
    elseif profile == "idle"   then cfg.fovs.idle   = (cfg.fovs.idle   or cfg.fovs.fov) + delta
    elseif profile == "walk"   then cfg.fovs.walk   = (cfg.fovs.walk   or cfg.fovs.fov) + delta
    elseif profile == "sprint" then cfg.fovs.sprint = (cfg.fovs.sprint or cfg.fovs.fov) + delta
    else                            cfg.fovs.fov    = cfg.fovs.fov + delta
    end

    for k, v in pairs(cfg.fovs) do
        if type(v) == "number" then
            if v < 30  then cfg.fovs[k] = 30  end
            if v > 120 then cfg.fovs[k] = 120 end
        end
    end

    local new_fov
    if     profile == "tps"    then new_fov = cfg.fovs.tps
    elseif profile == "lockon" then new_fov = cfg.fovs.lockon
    elseif profile == "battle" then new_fov = cfg.fovs.combat
    elseif profile == "idle"   then new_fov = cfg.fovs.idle
    elseif profile == "walk"   then new_fov = cfg.fovs.walk
    elseif profile == "sprint" then new_fov = cfg.fovs.sprint
    else                            new_fov = cfg.fovs.fov
    end

    if profile == "lockon" then
        ensure_lockon_enforcement(cfg)
        Camera.update_enforcement_fov(new_fov)
    else
        ExecuteInGameThread(function()
            Camera.set_fov_via_function(new_fov, cfg.KeyFOVTransitionSteps)
        end)
    end

    Config.write()
    print(string.format("[Main] %s FOV = %.0f\n", profile, new_fov))
end

local function adjust_current_position(axis, delta)
    local cfg = Config.get()
    local profile = Stance.get_current_profile()

    local pos
    if     profile == "lockon" then pos = cfg.LockOnPosition
    elseif profile == "battle" then pos = cfg.CombatPosition
    elseif profile == "idle"   then pos = cfg.IdlePosition
    elseif profile == "walk"   then pos = cfg.WalkPosition
    elseif profile == "sprint" then pos = cfg.SprintPosition
    else                            pos = cfg.DefaultPosition
    end

    pos[axis] = (pos[axis] or 0) + delta

    if profile == "lockon" then
        ensure_lockon_enforcement(cfg)
        Camera.update_enforcement_pos(pos)
    else
        ExecuteInGameThread(function()
            Camera.set_camera_relative_location(pos, cfg.KeyFOVTransitionSteps)
        end)
    end

    Config.write()
    print(string.format("[Main] %s Pos = (%.0f, %.0f, %.0f)\n", profile, pos.x, pos.y, pos.z))
end

local function adjust_lockon_bias(field, delta)
    local cfg = Config.get()
    cfg[field] = (cfg[field] or 0) + delta

    -- Clamp to reasonable range
    if cfg[field] > 30  then cfg[field] = 30  end
    if cfg[field] < -30 then cfg[field] = -30 end

    if Camera.is_enforcing() then
        if field == "LockOnYawBias" then
            Camera.update_enforcement_yaw_bias(cfg.LockOnYawBias)
        elseif field == "LockOnPitchBias" then
            Camera.update_enforcement_pitch_bias(cfg.LockOnPitchBias)
        end
    end

    Config.write()
    print(string.format("[Main] %s = %.1f\n", field, cfg[field]))
end

local function apply_for_current_state()
    local cfg = Config.get()
    local isTPS    = (PlayerCtx.is_tps_mode() == true)
    local isLockOn = (PlayerCtx.is_lock_on()  == true)
    local isBattle = (PlayerCtx.is_battle()    == true)
    local loco     = PlayerCtx.get_locomotion_state and PlayerCtx.get_locomotion_state()

    local fov = cfg.fovs.fov
    local pos = cfg.DefaultPosition

    if isTPS then
        fov = cfg.fovs.tps or cfg.fovs.fov
    elseif isLockOn and cfg.EnableLockOnCamera then
        fov = cfg.fovs.lockon or cfg.fovs.combat or cfg.fovs.fov
        pos = cfg.LockOnPosition
    elseif isBattle then
        fov = cfg.fovs.combat
        pos = cfg.CombatPosition
    elseif loco == "sprint" and cfg.EnableSprintingCamera then
        fov = cfg.fovs.sprint or cfg.fovs.fov
        pos = cfg.SprintPosition
    elseif loco == "idle" and cfg.EnableIdleCamera then
        fov = cfg.fovs.idle or cfg.fovs.fov
        pos = cfg.IdlePosition
    elseif loco == "slow_walk" and cfg.EnableWalkingCamera then
        fov = cfg.fovs.walk or cfg.fovs.fov
        pos = cfg.WalkPosition
    end

    if isLockOn and cfg.EnableLockOnCamera then
        Camera.start_enforcement(cfg.LockOnPosition, fov)
    else
        Camera.set_fov_via_function(fov, cfg.KeyFOVTransitionSteps)
        Camera.set_camera_relative_location(pos, cfg.KeyFOVTransitionSteps)
    end
    Camera.disable_camera_collision(cfg.DisableCameraCollision)
end
