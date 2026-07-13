local PlayerCtx = require("playercontext")
local Env = require("env").bind("Stance")
local Logging = require("logging")
local Profiles = require("profiles")

local math_abs = math.abs
local P = Profiles.PROFILES

local M = {
    _last_tick = 0.0,
    _min_dt = 0.10,
    _applied_profile = nil,
    _applied_fov = nil,
}

local Camera, Config

-- Component-scoped logger (see Logging.for_component).
local log = Logging.for_component("Stance")

local _ready_warned = false

function M.init(camera_mod, config_mod)
    Camera = camera_mod
    Config = config_mod
    _ready_warned = false
end

local _lockon_last_true = os.clock() -- Initialize to the active engine clock instead of 0
local _LOCKON_EXIT_GRACE = 0.4
local _grace_logged = false

local function safe_call(fn, context)
    local r = nil
    local ok = Env.run_now(context or "stance_safe_call", function()
        r = fn()
    end)
    if ok then
        return r
    end
    return nil
end

local function ready()
    if PlayerCtx.is_disabled() then
        return false
    end
    if PlayerCtx.camera_or_pc_invalid() then
        return false
    end
    if not Camera or not Config then
        if not _ready_warned then
            log.warn("Stance helper was invoked before Camera/Config were initialized.", "stance_not_ready", true)
            _ready_warned = true
        end
        return false
    end
    return true
end

-- choose_profile wraps the pure Profiles.resolve_profile with the two things that resolver
-- cannot own: the runtime-config error log, and the stateful lock-on grace period (a brief
-- window after lock-on releases during which we keep the lock-on profile so a momentary
-- target toggle does not snap the camera).
local function choose_profile(state, cfg)
    if type(state) ~= "table" then
        return P.default
    end

    -- TPS overrides everything and short-circuits before the config check (matches
    -- resolve_profile's top priority) so it still resolves if the config briefly goes invalid.
    if state.tps == true then
        return P.tps
    end

    local current_cfg = cfg or (Config and Config.get())
    if not current_cfg or type(current_cfg) ~= "table" or type(current_cfg.fovs) ~= "table" then
        log.error("Profile selection aborted because the runtime config is invalid.")
        return P.default
    end

    -- Fresh lock-on: (re)arm the grace timer and take the lock-on profile.
    if state.lockon == true and current_cfg.EnableLockOnCamera then
        _lockon_last_true = os.clock()
        _grace_logged = false
        return P.lockon
    end

    -- Lock-on just released: hold the lock-on profile until the grace window elapses.
    if M._applied_profile == P.lockon and current_cfg.EnableLockOnCamera then
        local since_last = os.clock() - _lockon_last_true
        if since_last < _LOCKON_EXIT_GRACE then
            if not _grace_logged then
                _grace_logged = true
                log.debug(
                    string.format(
                        "Lock-on grace period active (%.0fms remaining)",
                        (_LOCKON_EXIT_GRACE - since_last) * 1000
                    ),
                    "lockon_grace_active",
                    true
                )
            end
            return P.lockon
        end
        log.debug("Lock-on grace period expired, exiting lock-on", "lockon_grace_expired", true)
    end

    -- No lock-on override active: defer to the pure resolver for battle / locomotion / default.
    return Profiles.resolve_profile(state, current_cfg, PlayerCtx.LOCO_STATES)
end

local function apply_fov_transition(target_fov, steps_override)
    if target_fov == nil then
        return
    end
    if M._applied_fov and math_abs(M._applied_fov - target_fov) < 0.1 then
        return
    end
    if not Camera or not Camera.set_fov_via_function then
        log.error("Unable to apply an FOV transition because the camera module is unavailable.")
        return
    end

    local cfg = Config.get()
    if not cfg or type(cfg) ~= "table" then
        log.error("Unable to apply an FOV transition because the config is invalid.")
        return
    end
    local steps = steps_override or cfg.FOVTransitionSteps
    Env.run_on_game_thread("stance_apply_fov", function()
        Camera.set_fov_via_function(target_fov, steps)
    end)
    M._applied_fov = target_fov
end

local function apply_position_for_profile(profile, cfg, steps_override)
    -- Lock-on is driven by the enforcement loop and tps keeps its position; neither uses this path.
    if profile == P.lockon or profile == P.tps then
        return
    end

    local pos = Profiles.position_for_profile(profile, cfg)

    if pos then
        if not Camera or not Camera.set_camera_relative_location then
            log.error("Unable to apply a camera position transition because the camera module is unavailable.")
            return
        end

        Env.run_on_game_thread("stance_apply_position", function()
            Camera.set_camera_relative_location(pos, steps_override)
        end)
    end
end

local function apply_lockon_profile(cfg)
    if not Camera or not Camera.start_enforcement then
        log.error("Unable to enter lock-on mode because the camera module is unavailable.")
        return
    end

    local fov = Profiles.fov_for_profile(P.lockon, cfg)
    M._applied_fov = fov

    if Camera.is_enforcing and Camera.is_enforcing() then
        if Camera.update_enforcement_pos then
            Camera.update_enforcement_pos(cfg.LockOnPosition)
        end
        if Camera.update_enforcement_fov then
            Camera.update_enforcement_fov(fov)
        end
        if Camera.update_enforcement_yaw_bias then
            Camera.update_enforcement_yaw_bias(cfg.LockOnYawBias or 0)
        end
        if Camera.update_enforcement_pitch_bias then
            Camera.update_enforcement_pitch_bias(cfg.LockOnPitchBias or 0)
        end
        return
    end

    Camera.start_enforcement(cfg.LockOnPosition, fov)
end

local function apply_profile(profile, cfg)
    if profile == M._applied_profile then
        if profile == P.lockon then
            apply_lockon_profile(cfg)
        end
        return
    end

    local prev = M._applied_profile
    M._applied_profile = profile

    if profile == P.lockon then
        apply_lockon_profile(cfg)
        return
    end

    local slow_steps = 100
    local steps_override = nil

    -- Slow the transition when entering a traversal/resting state, or when leaving one back to
    -- default/combat, so those camera moves ease in gently instead of snapping.
    local entering_traversal = profile == P.walk or profile == P.sprint or profile == P.idle
    local leaving_traversal = profile == P.default and (prev == P.walk or prev == P.sprint or prev == P.idle)
    if entering_traversal or leaving_traversal then
        steps_override = slow_steps
    end

    if prev == P.lockon and Camera and Camera.begin_lockon_exit_blend then
        local target_fov = Profiles.fov_for_profile(profile, cfg)
        local target_pos = nil
        if profile == P.battle then
            target_pos = cfg.CombatPosition
        elseif profile == P.sprint then
            target_pos = cfg.SprintPosition
        elseif profile == P.idle then
            target_pos = cfg.IdlePosition
        elseif profile == P.walk then
            target_pos = cfg.WalkPosition
        elseif profile == P.default then
            target_pos = cfg.DefaultPosition
        end

        Env.run_on_game_thread("stance_lockon_exit_blend", function()
            local started = Camera.begin_lockon_exit_blend(target_pos, target_fov, nil, cfg.LockOnExitBlendTime)
            if not started then
                log.warn(
                    "Lock-on exit blend could not start; falling back to the standard transition path.",
                    "lockon_exit_fallback",
                    true
                )
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
    apply_fov_transition(Profiles.fov_for_profile(profile, cfg), steps_override)
end

function M.get_current_profile()
    return M._applied_profile or P.default
end

function M.reset_state()
    M._applied_profile = nil
    M._applied_fov = nil
end

function M.pulse()
    if not ready() then
        return
    end

    local t = os.clock()
    if (t - M._last_tick) < M._min_dt then
        return
    end
    M._last_tick = t

    local cfg = Config.get()
    if not cfg or type(cfg) ~= "table" or type(cfg.fovs) ~= "table" then
        log.error("Stance pulse aborted because the runtime config is invalid.")
        return
    end

    local state = {}

    state.tps = (safe_call(function()
        return PlayerCtx.is_tps_mode()
    end, "pulse_tps_eval") == true)

    state.lockon = (safe_call(function()
        return PlayerCtx.is_lock_on()
    end, "pulse_lockon_eval") == true)

    state.battle = (safe_call(function()
        return PlayerCtx.is_battle()
    end, "pulse_battle_eval") == true)

    state.locomotion = safe_call(function()
        return PlayerCtx.get_locomotion_state and PlayerCtx.get_locomotion_state()
    end, "pulse_locomotion_eval")

    local profile = choose_profile(state, cfg)

    apply_profile(profile, cfg)

    if M._applied_profile == P.lockon then
        return
    end

    local transitioning = false
    if Camera and Camera.is_transitioning then
        local transition_state = nil
        local ok_transition = Env.run_now("pulse_post_transition_eval", function()
            transition_state = Camera.is_transitioning()
        end)
        if not ok_transition then
            return
        end
        transitioning = (transition_state == true)
    else
        log.warn(
            "Pulse post-apply is missing Camera.is_transitioning; skipping transition-aware enforcement.",
            "pulse_missing_transition_fn",
            true
        )
        return
    end

    if not transitioning then
        local target_or_err = nil
        local ok_target = Env.run_now("pulse_post_target_fov_eval", function()
            target_or_err = Profiles.fov_for_profile(M._applied_profile, cfg)
        end)
        if not ok_target then
            return
        end

        if target_or_err ~= nil then
            Env.run_on_game_thread("stance_enforce_fov", function()
                if not Camera or type(Camera.enforce_fov) ~= "function" then
                    log.error("Pulse post-apply cannot enforce FOV because Camera.enforce_fov is unavailable.")
                    return
                end
                Camera.enforce_fov(target_or_err)
            end)
        else
            log.warn("Pulse post-apply resolved a nil target FOV; skipping enforcement.", "pulse_post_nil_target", true)
        end
    end
end

return M
