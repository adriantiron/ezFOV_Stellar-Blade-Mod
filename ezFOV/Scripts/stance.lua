local PlayerCtx = require("playercontext")
local Env = require("env").bind("Stance")
local Logging   = require("logging")

local math_abs = math.abs

local M = {
    _last_tick       = 0.0,
    _min_dt          = 0.10,
    _applied_profile = nil,
    _applied_fov     = nil,
}

local Camera, Config

-- Local helper logging functions to prefix messages with the module name and enforce level
local function log_error(message, once_key)
    Logging.log_error("Stance", message, once_key)
end

local function log_warn(message, once_key, cache)
    Logging.log_warn("Stance", message, once_key, cache)
end

local function log_debug(message, once_key, cache)
    Logging.log_debug("Stance", message, once_key, cache)
end
-- ========================================================================================

function M.init(cameraMod, configMod)
    Camera = cameraMod
    Config = configMod
    _ready_warned = false
end

local _lockon_last_true  = os.clock() -- Initialize to the active engine clock instead of 0
local _LOCKON_EXIT_GRACE = 0.4
local _grace_logged      = false
local _ready_warned      = false

local function safe_call(fn)
    local ok, r = pcall(fn)
    if ok then return r end
    return nil
end

local function ready()
    if PlayerCtx.is_disabled() then return false end
    if PlayerCtx.camera_or_pc_invalid() then return false end
    if not Camera or not Config then
        if not _ready_warned then
            log_warn("Stance helper was invoked before Camera/Config were initialized.", "stance_not_ready", true)
            _ready_warned = true
        end
        return false
    end
    return true
end

local function choose_profile(state, cfg)
    if not state or type(state) ~= "table" then return "default" end
    if state.tps == true then return "tps" end
	
	local current_cfg = cfg or (Config and Config.get())
    if not current_cfg or type(current_cfg) ~= "table" or type(current_cfg.fovs) ~= "table" then
        log_error("Profile selection aborted because the runtime config is invalid.", "stance_choose_profile_missing_cfg")
        return "default"
    end

    if state.lockon == true and current_cfg.EnableLockOnCamera then
        _lockon_last_true = os.clock()
        _grace_logged = false
        return "lockon"
    end

    if M._applied_profile == "lockon" and current_cfg.EnableLockOnCamera then
        local since_last = os.clock() - _lockon_last_true
        if since_last < _LOCKON_EXIT_GRACE then
            if not _grace_logged then
                _grace_logged = true
                log_debug(string.format("Lock-on grace period active (%.0fms remaining)",
                    (_LOCKON_EXIT_GRACE - since_last) * 1000), "lockon_grace_active")
            end
            return "lockon"
        end
        log_debug("Lock-on grace period expired, exiting lock-on", "lockon_grace_expired")
    end

    if state.battle == true                                then return "battle"  end
    if state.locomotion == "sprint" and current_cfg.EnableSprintingCamera then return "sprint" end
    if state.locomotion == "idle" and current_cfg.EnableIdleCamera then return "idle"   end
    if state.locomotion == "slow_walk" and current_cfg.EnableWalkingCamera then return "walk"   end
    return "default"
end

local function fov_for_profile(profile, cfg)
    if profile == "tps"    then return cfg.fovs.tps    or cfg.fovs.fov end
    if profile == "lockon" then return cfg.fovs.lockon or cfg.fovs.combat or cfg.fovs.fov end
    if profile == "battle" then return cfg.fovs.combat or cfg.fovs.fov end
    if profile == "idle"   then return cfg.fovs.idle   or cfg.fovs.fov end
    if profile == "walk"   then return cfg.fovs.walk   or cfg.fovs.fov end
    if profile == "sprint" then return cfg.fovs.sprint or cfg.fovs.fov end
    return cfg.fovs.fov
end

local function apply_fov_transition(target_fov, steps_override)
    if target_fov == nil then return end
    if M._applied_fov and math_abs(M._applied_fov - target_fov) < 0.1 then return end
    if not Camera or not Camera.set_fov_via_function then
        log_error("Unable to apply an FOV transition because the camera module is unavailable.", "stance_missing_camera_fov")
        return
    end

    local cfg = Config.get()
    if not cfg or type(cfg) ~= "table" then
        log_error("Unable to apply an FOV transition because the config is invalid.", "stance_apply_fov_missing_cfg")
        return
    end
    local steps = steps_override or cfg.FOVTransitionSteps
    Env.run_on_game_thread("stance_apply_fov", function()
        Camera.set_fov_via_function(target_fov, steps)
    end)
    M._applied_fov = target_fov
end

local function apply_position_for_profile(profile, cfg, steps_override)
    if profile == "lockon" or profile == "tps" then return end

    local pos = nil
    if     profile == "battle"  then pos = cfg.CombatPosition
    elseif profile == "sprint"  then pos = cfg.SprintPosition
    elseif profile == "idle"    then pos = cfg.IdlePosition
    elseif profile == "walk"    then pos = cfg.WalkPosition
    elseif profile == "default" then pos = cfg.DefaultPosition
    end

    if pos then
        if not Camera or not Camera.set_camera_relative_location then
            log_error("Unable to apply a camera position transition because the camera module is unavailable.", "stance_missing_camera_position")
            return
        end

        Env.run_on_game_thread("stance_apply_position", function()
            Camera.set_camera_relative_location(pos, steps_override)
        end)
    end
end

local function apply_profile(profile, cfg)
    if profile == M._applied_profile then return end

    local prev = M._applied_profile
    M._applied_profile = profile

    if profile == "lockon" then
        if not Camera or not Camera.start_enforcement then
            log_error("Unable to enter lock-on mode because the camera module is unavailable.", "stance_missing_camera_start")
            return
        end
        local fov = fov_for_profile("lockon", cfg)
        M._applied_fov = fov
        Camera.start_enforcement(cfg.LockOnPosition, fov)
        log_debug(string.format("-> lockon FOV=%.0f Pos=(%.0f,%.0f,%.0f) YawBias=%.1f PitchBias=%.1f",
            fov, cfg.LockOnPosition.x or 0, cfg.LockOnPosition.y or 0, cfg.LockOnPosition.z or 0,
            cfg.LockOnYawBias or 0, cfg.LockOnPitchBias or 0), "lockon_profile_applied")
        return
    end

    local slow_steps = 150
    local steps_override = nil

    -- 1. Slow down transitions IF the target profile is a traversal or resting state
    if profile == "walk" or profile == "sprint" or profile == "idle" then
        steps_override = slow_steps
    -- 2. Slow down transitions IF we are exiting a traversal or resting state back to default/combat
    elseif profile == "default" and (prev == "walk" or prev == "sprint" or prev == "idle") then
        steps_override = slow_steps
    end

    if prev == "lockon" and Camera and Camera.begin_lockon_exit_blend then
        local target_fov = fov_for_profile(profile, cfg)
        local target_pos = nil
        if     profile == "battle"  then target_pos = cfg.CombatPosition
        elseif profile == "sprint"  then target_pos = cfg.SprintPosition
        elseif profile == "idle"    then target_pos = cfg.IdlePosition
        elseif profile == "walk"    then target_pos = cfg.WalkPosition
        elseif profile == "default" then target_pos = cfg.DefaultPosition
        end

        Env.run_on_game_thread("stance_lockon_exit_blend", function()
            local started = Camera.begin_lockon_exit_blend(target_pos, target_fov, nil, cfg.LockOnExitBlendTime)
            if not started then
                log_warn("Lock-on exit blend could not start; falling back to the standard transition path.", "lockon_exit_fallback", true)
                if target_pos then
                    Camera.set_camera_relative_location(target_pos, steps_override)
                end
                if target_fov ~= nil then
                    Camera.set_fov_via_function(target_fov, steps_override)
                end
            end
        end)
        return
    end

    apply_position_for_profile(profile, cfg, steps_override)
    apply_fov_transition(fov_for_profile(profile, cfg), steps_override)
end

function M.get_current_profile()
    return M._applied_profile or "default"
end

function M.reset_state()
    M._applied_profile = nil
    M._applied_fov = nil
end

function M.pulse()
    if not ready() then return end

    local t = os.clock()
    if (t - M._last_tick) < M._min_dt then return end
    M._last_tick = t

    local cfg = Config.get()
    if not cfg or type(cfg) ~= "table" or type(cfg.fovs) ~= "table" then
        log_error("Stance pulse aborted because the runtime config is invalid.", "stance_pulse_missing_cfg")
        return
    end

    local state = {}

    -- Optional logging of the pulse state checks. Uncomment for debugging.
    --log_debug("Pulse state: starting TPS check", "pulse_tps_check", true)
    state.tps = (safe_call(function() return PlayerCtx.is_tps_mode() end) == true)

    --log_debug("Pulse state: starting Lockon check", "pulse_lockon_check", true)
    state.lockon = (safe_call(function() return PlayerCtx.is_lock_on() end) == true)

    --log_debug("Pulse state: starting Battle check", "pulse_battle_check", true) -- If you see this, but not the next, is_battle is crashing
    state.battle = (safe_call(function() return PlayerCtx.is_battle() end) == true)

    --log_debug("Pulse state: starting Locomotion check", "pulse_locomotion_check", true)
    state.locomotion = safe_call(function()
        return PlayerCtx.get_locomotion_state and PlayerCtx.get_locomotion_state()
    end)

    --log_debug("Pulse state: gathered. Choosing profile...", "pulse_choose_profile", true)
    local profile = choose_profile(state, cfg)

    --log_debug("Pulse state: applying profile...", "pulse_apply_profile", true)
    apply_profile(profile, cfg)

    --log_debug("Pulse state: profile applied.", "pulse_profile_applied", true)

    if M._applied_profile == "lockon" then return end

    if Camera.is_transitioning and not Camera.is_transitioning() then
        local target = fov_for_profile(M._applied_profile, cfg)
        if target then
            Env.run_on_game_thread("stance_enforce_fov", function()
                Camera.enforce_fov(target)
            end)
        end
    end
end

return M