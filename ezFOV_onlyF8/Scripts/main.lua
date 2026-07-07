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

log_debug(string.format(
    "Initial config: FOV(default=%.0f,fov=%.0f,combat=%.0f,tps=%.0f,idle=%.0f,walk=%.0f,sprint=%.0f,lockon=%.0f) " ..
    "Pos(default=(%.0f,%.0f,%.0f),combat=(%.0f,%.0f,%.0f),lockon=(%.0f,%.0f,%.0f),idle=(%.0f,%.0f,%.0f),walk=(%.0f,%.0f,%.0f),sprint=(%.0f,%.0f,%.0f)) " ..
    "flags(lockon=%s,idle=%s,walk=%s,sprint=%s,collision=%s) " ..
    "bias(yaw=%.1f,pitch=%.1f) exit_blend=%.3f steps(fov=%d,key=%d)",
    cfg.fovs.default or 0,
    cfg.fovs.fov or 0,
    cfg.fovs.combat or 0,
    cfg.fovs.tps or 0,
    cfg.fovs.idle or 0,
    cfg.fovs.walk or 0,
    cfg.fovs.sprint or 0,
    cfg.fovs.lockon or 0,
    cfg.DefaultPosition.x or 0,
    cfg.DefaultPosition.y or 0,
    cfg.DefaultPosition.z or 0,
    cfg.CombatPosition.x or 0,
    cfg.CombatPosition.y or 0,
    cfg.CombatPosition.z or 0,
    cfg.LockOnPosition.x or 0,
    cfg.LockOnPosition.y or 0,
    cfg.LockOnPosition.z or 0,
    cfg.IdlePosition.x or 0,
    cfg.IdlePosition.y or 0,
    cfg.IdlePosition.z or 0,
    cfg.WalkPosition.x or 0,
    cfg.WalkPosition.y or 0,
    cfg.WalkPosition.z or 0,
    cfg.SprintPosition.x or 0,
    cfg.SprintPosition.y or 0,
    cfg.SprintPosition.z or 0,
    tostring(cfg.EnableLockOnCamera),
    tostring(cfg.EnableIdleCamera),
    tostring(cfg.EnableWalkingCamera),
    tostring(cfg.EnableSprintingCamera),
    tostring(cfg.DisableCameraCollision),
    cfg.LockOnYawBias or 0,
    cfg.LockOnPitchBias or 0,
    cfg.LockOnExitBlendTime or 0,
    cfg.FOVTransitionSteps or 0,
    cfg.KeyFOVTransitionSteps or 0
), "config_initial_state", true)

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

log_debug(
    "Env initialized: immediate traceback " .. (Env.is_immediate_traceback_enabled() and "ENABLED" or "DISABLED"),
    "env_mode_startup",
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
    if Hooks.defer_stance_pulse then Hooks.defer_stance_pulse(220, "f8_reload") end
    Camera.init(cfg) -- Keep camera's internal reference perfectly synchronized

    Env.run_on_game_thread("reload_config_apply", function()
        local isTPS    = (PlayerCtx.is_tps_mode() == true)
        local isLockOn = (PlayerCtx.is_lock_on()  == true)
        local isBattle = (PlayerCtx.is_battle()    == true)

        -- Fetch the live locomotion state
        local locoState = PlayerCtx.get_locomotion_state and PlayerCtx.get_locomotion_state()

        local fov =
            (isTPS    and (cfg.fovs.tps or cfg.fovs.fov))
            or (isLockOn and cfg.EnableLockOnCamera and (cfg.fovs.lockon or cfg.fovs.combat))
            or (isBattle and cfg.fovs.combat)
            or (locoState == PlayerCtx.LOCO_STATES.idle and cfg.EnableIdleCamera and cfg.fovs.idle)
            or (locoState == PlayerCtx.LOCO_STATES.slow_walk and cfg.EnableWalkingCamera and cfg.fovs.walk)
            or (locoState == PlayerCtx.LOCO_STATES.sprint and cfg.EnableSprintingCamera and cfg.fovs.sprint)
            or cfg.fovs.fov

        local pos =
            (isLockOn and cfg.EnableLockOnCamera and cfg.LockOnPosition)
            or (isBattle and cfg.CombatPosition)
            or (locoState == PlayerCtx.LOCO_STATES.idle and cfg.EnableIdleCamera and cfg.IdlePosition)
            or (locoState == PlayerCtx.LOCO_STATES.slow_walk and cfg.EnableWalkingCamera and cfg.WalkPosition)
            or (locoState == PlayerCtx.LOCO_STATES.sprint and cfg.EnableSprintingCamera and cfg.SprintPosition)
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

