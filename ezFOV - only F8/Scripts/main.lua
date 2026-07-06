local Config    = require("config")
local Camera    = require("camera")
local Env       = require("env").bind("Main")
local PlayerCtx = require("playercontext")
local Hooks     = require("hooks")
local Stance    = require("stance")
local Logging   = require("logging")

-- Local helper logging functions to prefix messages with the module name and enforce level
local function log_error(message, once_key)
    Logging.log_error("Main", message, once_key)
end

local function log_warn(message, once_key, cache)
    Logging.log_warn("Main", message, once_key, cache)
end

local function log_debug(message, once_key, cache)
    Logging.log_debug("Main", message, once_key, cache)
end
-- ========================================================================================

local cfg = Config.get()
if not cfg then
    log_error("Main initialization could not load config data; retrying once.", "main_init_missing_cfg")
    cfg = Config.reload()
end

if not cfg then
    log_error("Main initialization aborted because config data is still unavailable.", "main_init_missing_cfg_final")
    return
end

local ok_init, init_err = pcall(function()
    Camera.init(cfg)
    Camera.disable_camera_collision(cfg.DisableCameraCollision)
    Hooks.init(Camera, Config)
end)
if not ok_init then
    log_error("Main initialization failed: " .. tostring(init_err), "main_init_failed")
    return
end

log_debug(
    "Logging initialized: debug cache " .. (Logging.is_debug_cache_enabled() and "ENABLED" or "DISABLED"),
    "logging_mode_startup",
    true
)

-- ==================== F8: Reload config ====================

Env.register_safe_keybind(Env.Key.F8, {}, "reload_config_hotkey", function()
    local reloaded_cfg = Config.reload()
    if not reloaded_cfg then
        log_error("Config reload failed; keeping the previous runtime config.", "config_reload_failed")
        return
    end

    cfg = reloaded_cfg
    if Stance.reset_state then Stance.reset_state() end
    Camera.init(cfg) -- Keep camera's internal reference perfectly synchronized

    Env.run_on_game_thread("reload_config_apply", function()
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
            local should_blend_lockon_exit = Camera.is_enforcing and Camera.is_enforcing()
            if should_blend_lockon_exit and Camera.begin_lockon_exit_blend then
                local started = Camera.begin_lockon_exit_blend(pos, fov, nil, cfg.LockOnExitBlendTime)
                if not started then
                    if Camera.cancel_lockon_exit_blend then Camera.cancel_lockon_exit_blend() end
                    Camera.set_fov_via_function(fov)
                    Camera.set_camera_relative_location(pos)
                end
            else
                if Camera.cancel_lockon_exit_blend then Camera.cancel_lockon_exit_blend() end
                Camera.set_fov_via_function(fov)
                Camera.set_camera_relative_location(pos)
            end
        end

        Camera.disable_camera_collision(cfg.DisableCameraCollision)

        log_debug(string.format("Reloaded. TPS=%s Lock=%s Battle=%s FOV=%.0f Pos=(%.0f,%.0f,%.0f) YawBias=%.1f PitchBias=%.1f",
            tostring(isTPS), tostring(isLockOn), tostring(isBattle),
            fov, pos.x, pos.y, pos.z, cfg.LockOnYawBias or 0, cfg.LockOnPitchBias or 0), "reload_config")
    end)
end)

-- ==================== Helpers ====================

local function ensure_lockon_enforcement(cfg)
    if not Camera or not Camera.start_enforcement then
        log_error("Unable to restart lock-on enforcement because the camera module is unavailable.", "enforcement_restart_missing_camera")
        return
    end
    if not cfg or type(cfg) ~= "table" or not cfg.fovs then
        log_error("Unable to restart lock-on enforcement because the runtime config is invalid.", "enforcement_restart_missing_cfg")
        return
    end

    if Camera.is_enforcing() then return end
    local fov = cfg.fovs.lockon or cfg.fovs.combat or cfg.fovs.fov
    Camera.start_enforcement(cfg.LockOnPosition, fov)
    log_debug("Restarted dead enforcement loop", "restart_enforcement")
end

local function adjust_current_fov(delta)
    local cfg = Config.get()
    if not cfg or type(cfg) ~= "table" or not cfg.fovs then
        log_error("FOV adjustment aborted because the runtime config is invalid.", "adjust_fov_missing_cfg")
        return
    end

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
        Env.run_on_game_thread("adjust_fov", function()
            Camera.set_fov_via_function(new_fov, cfg.KeyFOVTransitionSteps)
        end)
    end

    Config.write()
    log_debug(string.format("%s FOV = %.0f", profile, new_fov), "adjust_fov")
end

local function adjust_current_position(axis, delta)
    local cfg = Config.get()
    if not cfg or type(cfg) ~= "table" then
        log_error("Position adjustment aborted because the runtime config is invalid.", "adjust_position_missing_cfg")
        return
    end

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
        Env.run_on_game_thread("adjust_position", function()
            Camera.set_camera_relative_location(pos, cfg.KeyFOVTransitionSteps)
        end)
    end

    Config.write()
    log_debug(string.format("%s Pos = (%.0f, %.0f, %.0f)", profile, pos.x, pos.y, pos.z), "adjust_position")
end

local function adjust_lockon_bias(field, delta)
    local cfg = Config.get()
    if not cfg or type(cfg) ~= "table" then
        log_error("Lock-on bias adjustment aborted because the runtime config is invalid.", "adjust_bias_missing_cfg")
        return
    end

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
    log_debug(string.format("%s = %.1f", field, cfg[field]), "adjust_bias")
end

local function apply_for_current_state()
    local cfg = Config.get()
    if not cfg or type(cfg) ~= "table" then
        log_error("State application aborted because the runtime config is invalid.", "apply_state_missing_cfg")
        return
    end

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
        local should_blend_lockon_exit = Camera.is_enforcing and Camera.is_enforcing()
        if should_blend_lockon_exit and Camera.begin_lockon_exit_blend then
            local started = Camera.begin_lockon_exit_blend(pos, fov, nil, cfg.LockOnExitBlendTime)
            if not started then
                if Camera.cancel_lockon_exit_blend then Camera.cancel_lockon_exit_blend() end
                Camera.set_fov_via_function(fov, cfg.KeyFOVTransitionSteps)
                Camera.set_camera_relative_location(pos, cfg.KeyFOVTransitionSteps)
            end
        else
            if Camera.cancel_lockon_exit_blend then Camera.cancel_lockon_exit_blend() end
            Camera.set_fov_via_function(fov, cfg.KeyFOVTransitionSteps)
            Camera.set_camera_relative_location(pos, cfg.KeyFOVTransitionSteps)
        end
    end
    Camera.disable_camera_collision(cfg.DisableCameraCollision)
end

