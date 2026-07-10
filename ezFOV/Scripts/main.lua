local Config = require("config")
local Camera = require("camera")
local Env = require("env").bind("Main")
local PlayerCtx = require("playercontext")
local Hooks = require("hooks")
local Stance = require("stance")
local Logging = require("logging")
local Constants = require("constants")
local Profiles = require("profiles")

-- Component-scoped logger (see Logging.for_component). warn is unused in this module.
local log = Logging.for_component("Main")

local cfg = Config.get()
if not cfg then
    log.error("Main initialization could not load config data; retrying once.", "main_init_missing_cfg")
    cfg = Config.reload()
end

if not cfg then
    log.error("Main initialization aborted because config data is still unavailable.", "main_init_missing_cfg_final")
    return
end

log.debug(
    string.format(
        "Initial config: FOV(default=%.0f,fov=%.0f,combat=%.0f,tps=%.0f,idle=%.0f,walk=%.0f,sprint=%.0f,lockon=%.0f) "
            .. "Pos(default=(%.0f,%.0f,%.0f),combat=(%.0f,%.0f,%.0f),lockon=(%.0f,%.0f,%.0f),idle=(%.0f,%.0f,%.0f),walk=(%.0f,%.0f,%.0f),sprint=(%.0f,%.0f,%.0f)) "
            .. "flags(lockon=%s,idle=%s,walk=%s,sprint=%s,collision=%s) "
            .. "bias(yaw=%.1f,pitch=%.1f) exit_blend=%.3f steps(fov=%d,key=%d)",
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
    ),
    "config_initial_state",
    true
)

local ok_init, init_err = pcall(function()
    Camera.init(cfg)
    Camera.disable_camera_collision(cfg.DisableCameraCollision)
    Hooks.init(Camera, Config)
end)
if not ok_init then
    log.error("Main initialization failed: " .. tostring(init_err), "main_init_failed")
    return
end

log.debug(
    "Logging initialized: debug cache " .. (Logging.is_debug_cache_enabled() and "ENABLED" or "DISABLED"),
    "logging_mode_startup",
    true
)

log.debug(
    "Env initialized: immediate traceback " .. (Env.is_immediate_traceback_enabled() and "ENABLED" or "DISABLED"),
    "env_mode_startup",
    true
)

-- ==================== F8: Reload config ====================

Env.register_safe_keybind(Env.Key.F8, {}, "reload_config_hotkey", function()
    local reloaded_cfg = Config.reload()
    if not reloaded_cfg then
        log.error("Config reload failed; keeping the previous runtime config.", "config_reload_failed")
        return
    end

    cfg = reloaded_cfg
    if Stance.reset_state then
        Stance.reset_state()
    end
    if Hooks.defer_stance_pulse then
        Hooks.defer_stance_pulse(220, "f8_reload")
    end
    Camera.init(cfg) -- Keep camera's internal reference perfectly synchronized

    Env.run_on_game_thread("reload_config_apply", function()
        local state = {
            tps = (PlayerCtx.is_tps_mode() == true),
            lockon = (PlayerCtx.is_lock_on() == true),
            battle = (PlayerCtx.is_battle() == true),
            locomotion = PlayerCtx.get_locomotion_state and PlayerCtx.get_locomotion_state(),
        }
        local profile = Profiles.resolve_profile(state, cfg, PlayerCtx.LOCO_STATES)
        local fov = Profiles.fov_for_profile(profile, cfg)
        local pos = Profiles.position_for_profile(profile, cfg)

        if profile == Profiles.PROFILES.lockon then
            Camera.start_enforcement(cfg.LockOnPosition, fov)
        else
            local should_blend_lockon_exit = Camera.is_enforcing and Camera.is_enforcing()
            if should_blend_lockon_exit and Camera.begin_lockon_exit_blend then
                local started = Camera.begin_lockon_exit_blend(pos, fov, nil, cfg.LockOnExitBlendTime)
                if not started then
                    if Camera.cancel_lockon_exit_blend then
                        Camera.cancel_lockon_exit_blend()
                    end
                    Camera.set_fov_via_function(fov)
                    Camera.set_camera_relative_location(pos)
                end
            else
                if Camera.cancel_lockon_exit_blend then
                    Camera.cancel_lockon_exit_blend()
                end
                Camera.set_fov_via_function(fov)
                Camera.set_camera_relative_location(pos)
            end
        end

        Camera.disable_camera_collision(cfg.DisableCameraCollision)

        log.debug(
            string.format(
                "Reloaded. TPS=%s Lock=%s Battle=%s FOV=%.0f Pos=(%.0f,%.0f,%.0f) YawBias=%.1f PitchBias=%.1f",
                tostring(state.tps),
                tostring(state.lockon),
                tostring(state.battle),
                fov,
                pos.x,
                pos.y,
                pos.z,
                cfg.LockOnYawBias or 0,
                cfg.LockOnPitchBias or 0
            ),
            "reload_config"
        )
    end)
end)

-- ==================== Helpers ====================

local function ensure_lockon_enforcement(cfg)
    if not Camera or not Camera.start_enforcement then
        log.error(
            "Unable to restart lock-on enforcement because the camera module is unavailable.",
            "enforcement_restart_missing_camera"
        )
        return
    end
    if not cfg or type(cfg) ~= "table" or not cfg.fovs then
        log.error(
            "Unable to restart lock-on enforcement because the runtime config is invalid.",
            "enforcement_restart_missing_cfg"
        )
        return
    end

    if Camera.is_enforcing() then
        return
    end
    local fov = cfg.fovs.lockon or cfg.fovs.combat or cfg.fovs.fov
    Camera.start_enforcement(cfg.LockOnPosition, fov)
    log.debug("Restarted dead enforcement loop", "restart_enforcement")
end

local function adjust_current_fov(delta)
    local cfg = Config.get()
    if not cfg or type(cfg) ~= "table" or not cfg.fovs then
        log.error("FOV adjustment aborted because the runtime config is invalid.", "adjust_fov_missing_cfg")
        return
    end

    local profile = Stance.get_current_profile()
    local fov_key = Profiles.fov_key_for_profile(profile)

    cfg.fovs[fov_key] = Profiles.fov_for_profile(profile, cfg) + delta

    for k, v in pairs(cfg.fovs) do
        if type(v) == "number" then
            if v < Constants.FOV_MIN then
                cfg.fovs[k] = Constants.FOV_MIN
            end
            if v > Constants.FOV_MAX then
                cfg.fovs[k] = Constants.FOV_MAX
            end
        end
    end

    local new_fov = cfg.fovs[fov_key]

    if profile == Profiles.PROFILES.lockon then
        ensure_lockon_enforcement(cfg)
        Camera.update_enforcement_fov(new_fov)
    else
        Env.run_on_game_thread("adjust_fov", function()
            Camera.set_fov_via_function(new_fov, cfg.KeyFOVTransitionSteps)
        end)
    end

    Config.write()
    log.debug(string.format("%s FOV = %.0f", profile, new_fov), "adjust_fov")
end

local function adjust_current_position(axis, delta)
    local cfg = Config.get()
    if not cfg or type(cfg) ~= "table" then
        log.error("Position adjustment aborted because the runtime config is invalid.", "adjust_position_missing_cfg")
        return
    end

    local profile = Stance.get_current_profile()
    local pos = Profiles.position_for_profile(profile, cfg)

    pos[axis] = (pos[axis] or 0) + delta

    if profile == Profiles.PROFILES.lockon then
        ensure_lockon_enforcement(cfg)
        Camera.update_enforcement_pos(pos)
    else
        Env.run_on_game_thread("adjust_position", function()
            Camera.set_camera_relative_location(pos, cfg.KeyFOVTransitionSteps)
        end)
    end

    Config.write()
    log.debug(string.format("%s Pos = (%.0f, %.0f, %.0f)", profile, pos.x, pos.y, pos.z), "adjust_position")
end

local function adjust_lockon_bias(field, delta)
    local cfg = Config.get()
    if not cfg or type(cfg) ~= "table" then
        log.error("Lock-on bias adjustment aborted because the runtime config is invalid.", "adjust_bias_missing_cfg")
        return
    end

    cfg[field] = (cfg[field] or 0) + delta

    -- Clamp to reasonable range
    if cfg[field] > Constants.LOCKON_BIAS_LIMIT then
        cfg[field] = Constants.LOCKON_BIAS_LIMIT
    end
    if cfg[field] < -Constants.LOCKON_BIAS_LIMIT then
        cfg[field] = -Constants.LOCKON_BIAS_LIMIT
    end

    if Camera.is_enforcing() then
        if field == "LockOnYawBias" then
            Camera.update_enforcement_yaw_bias(cfg.LockOnYawBias)
        elseif field == "LockOnPitchBias" then
            Camera.update_enforcement_pitch_bias(cfg.LockOnPitchBias)
        end
    end

    Config.write()
    log.debug(string.format("%s = %.1f", field, cfg[field]), "adjust_bias")
end

local function apply_for_current_state()
    local cfg = Config.get()
    if not cfg or type(cfg) ~= "table" then
        log.error("State application aborted because the runtime config is invalid.", "apply_state_missing_cfg")
        return
    end

    local state = {
        tps = (PlayerCtx.is_tps_mode() == true),
        lockon = (PlayerCtx.is_lock_on() == true),
        battle = (PlayerCtx.is_battle() == true),
        locomotion = PlayerCtx.get_locomotion_state and PlayerCtx.get_locomotion_state(),
    }
    local profile = Profiles.resolve_profile(state, cfg, PlayerCtx.LOCO_STATES)
    local fov = Profiles.fov_for_profile(profile, cfg)
    local pos = Profiles.position_for_profile(profile, cfg)

    if profile == Profiles.PROFILES.lockon then
        Camera.start_enforcement(cfg.LockOnPosition, fov)
    else
        local should_blend_lockon_exit = Camera.is_enforcing and Camera.is_enforcing()
        if should_blend_lockon_exit and Camera.begin_lockon_exit_blend then
            local started = Camera.begin_lockon_exit_blend(pos, fov, nil, cfg.LockOnExitBlendTime)
            if not started then
                if Camera.cancel_lockon_exit_blend then
                    Camera.cancel_lockon_exit_blend()
                end
                Camera.set_fov_via_function(fov, cfg.KeyFOVTransitionSteps)
                Camera.set_camera_relative_location(pos, cfg.KeyFOVTransitionSteps)
            end
        else
            if Camera.cancel_lockon_exit_blend then
                Camera.cancel_lockon_exit_blend()
            end
            Camera.set_fov_via_function(fov, cfg.KeyFOVTransitionSteps)
            Camera.set_camera_relative_location(pos, cfg.KeyFOVTransitionSteps)
        end
    end
    Camera.disable_camera_collision(cfg.DisableCameraCollision)
end

-- ==================== Keybinds: FOV ====================

Env.register_safe_keybind(Env.Key.F5, {}, "adjust_fov_f5", function()
    adjust_current_fov(-25)
end)
Env.register_safe_keybind(Env.Key.F6, {}, "adjust_fov_f6", function()
    adjust_current_fov(-5)
end)
Env.register_safe_keybind(Env.Key.F7, {}, "adjust_fov_f7", function()
    adjust_current_fov(5)
end)

-- ==================== Keybinds: Position ====================

Env.register_safe_keybind(Env.Key.UP_ARROW, { Env.ModifierKey.CONTROL }, "adjust_position_ctrl_up", function()
    adjust_current_position("x", 50)
end)
Env.register_safe_keybind(Env.Key.DOWN_ARROW, { Env.ModifierKey.CONTROL }, "adjust_position_ctrl_down", function()
    adjust_current_position("x", -50)
end)
Env.register_safe_keybind(Env.Key.UP_ARROW, { Env.ModifierKey.ALT }, "adjust_position_alt_up", function()
    adjust_current_position("z", 10)
end)
Env.register_safe_keybind(Env.Key.DOWN_ARROW, { Env.ModifierKey.ALT }, "adjust_position_alt_down", function()
    adjust_current_position("z", -10)
end)
Env.register_safe_keybind(Env.Key.LEFT_ARROW, { Env.ModifierKey.ALT }, "adjust_position_alt_left", function()
    adjust_current_position("y", -10)
end)
Env.register_safe_keybind(Env.Key.RIGHT_ARROW, { Env.ModifierKey.ALT }, "adjust_position_alt_right", function()
    adjust_current_position("y", 10)
end)

-- ==================== Keybinds: Lock-on biases ====================
-- SHIFT + UP/DOWN    = PitchBias (target up/down on screen)
-- SHIFT + LEFT/RIGHT = YawBias   (target left/right on screen)

Env.register_safe_keybind(Env.Key.UP_ARROW, { Env.ModifierKey.SHIFT }, "adjust_bias_shift_up", function()
    adjust_lockon_bias("LockOnPitchBias", 1)
end)
Env.register_safe_keybind(Env.Key.DOWN_ARROW, { Env.ModifierKey.SHIFT }, "adjust_bias_shift_down", function()
    adjust_lockon_bias("LockOnPitchBias", -1)
end)
Env.register_safe_keybind(Env.Key.RIGHT_ARROW, { Env.ModifierKey.SHIFT }, "adjust_bias_shift_right", function()
    adjust_lockon_bias("LockOnYawBias", 1)
end)
Env.register_safe_keybind(Env.Key.LEFT_ARROW, { Env.ModifierKey.SHIFT }, "adjust_bias_shift_left", function()
    adjust_lockon_bias("LockOnYawBias", -1)
end)

-- ==================== Keybinds: Presets ====================

Env.register_safe_keybind(Env.Key.ONE, { Env.ModifierKey.ALT }, "save_preset_1", function()
    Config.save_preset(1)
end)
Env.register_safe_keybind(Env.Key.TWO, { Env.ModifierKey.ALT }, "save_preset_2", function()
    Config.save_preset(2)
end)
Env.register_safe_keybind(Env.Key.THREE, { Env.ModifierKey.ALT }, "save_preset_3", function()
    Config.save_preset(3)
end)
Env.register_safe_keybind(Env.Key.FOUR, { Env.ModifierKey.ALT }, "save_preset_4", function()
    Config.save_preset(4)
end)

-- ==================== Keybinds: Presets Loading loop ====================
-- ALT  + 1-4 = Saves current configurations to preset files (Handled above)
-- CTRL + 1-4 = Loads and dynamically applies preset profiles (Handled here)

local preset_keys = { Env.Key.ONE, Env.Key.TWO, Env.Key.THREE, Env.Key.FOUR }
for i = 1, 4 do
    local key = preset_keys[i]
    local num = i
    Env.register_safe_keybind(key, { Env.ModifierKey.CONTROL }, "load_preset_" .. tostring(num), function()
        if Config.load_preset(num) then
            Config.write()
            Env.run_on_game_thread("apply_preset_" .. tostring(num), function()
                apply_for_current_state()
                log.debug(string.format("Applied Preset %d", num), "apply_preset")
            end)
        end
    end)
end
