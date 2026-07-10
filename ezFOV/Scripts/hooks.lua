local PlayerCtx = require("playercontext")
local Heartbeat = require("heartbeat")
local Stance = require("stance")
local Env = require("env").bind("Hooks")
local Logging = require("logging")

local os_clock = os.clock

local H = {
    _hook_ids = {},
    _initialized = false,
}

local last_state_change = 0
local STATE_CHANGE_COOLDOWN = 0.3
local POST_COLD_APPLY_PULSE_DELAY_MS = 120
local RELOAD_DEFER_DEFAULT_MS = 180
local DEBUG_BOOTSTRAP_STATE_MACHINE = false

local BOOTSTRAP_IDLE = "idle"
local BOOTSTRAP_COLD_PENDING = "cold_apply_pending"
local BOOTSTRAP_WAIT_POST_PULSE = "wait_post_cold_pulse"

local Bootstrap = {
    state = BOOTSTRAP_IDLE,
    cold_applied = false,
    post_pulse_requested = false,
    post_pulse_token = nil,
}

-- Component-scoped logger (see Logging.for_component).
local log = Logging.for_component("Hooks")

local function safe_register_hook(func_path, pre_cb, post_cb)
    return Env.safe_register_hook(func_path, pre_cb, post_cb)
end

local function unregister_hook(entry)
    Env.safe_unregister_hook(entry)
end

local function cancel_post_cold_pulse_timer()
    if Bootstrap.post_pulse_token then
        Env.CancelDelay(Bootstrap.post_pulse_token)
        Bootstrap.post_pulse_token = nil
    end
end

local function is_bootstrap_debug_enabled()
    if DEBUG_BOOTSTRAP_STATE_MACHINE == true then
        return true
    end
    if not H.ConfigMod or type(H.ConfigMod.get) ~= "function" then
        return false
    end
    local cfg = H.ConfigMod.get()
    return cfg and cfg.DebugBootstrapStateMachine == true
end

local function is_valid_bootstrap_transition(from_state, to_state)
    if from_state == to_state then
        return true
    end
    if to_state == BOOTSTRAP_IDLE then
        return true
    end
    if from_state == BOOTSTRAP_IDLE and to_state == BOOTSTRAP_COLD_PENDING then
        return true
    end
    if from_state == BOOTSTRAP_COLD_PENDING and to_state == BOOTSTRAP_WAIT_POST_PULSE then
        return true
    end
    return false
end

local function set_bootstrap_state(new_state, reason)
    local prev = Bootstrap.state
    Bootstrap.state = new_state

    if not is_bootstrap_debug_enabled() then
        return
    end

    if is_valid_bootstrap_transition(prev, new_state) then
        log.debug(
            "Bootstrap transition "
                .. tostring(prev)
                .. " -> "
                .. tostring(new_state)
                .. " ("
                .. tostring(reason or "unspecified")
                .. ")",
            "bootstrap_transition_" .. tostring(prev) .. "_to_" .. tostring(new_state)
        )
    else
        log.warn(
            "Bootstrap INVALID transition "
                .. tostring(prev)
                .. " -> "
                .. tostring(new_state)
                .. " ("
                .. tostring(reason or "unspecified")
                .. ")",
            "bootstrap_invalid_transition_" .. tostring(prev) .. "_to_" .. tostring(new_state),
            true
        )
    end
end

local function reset_bootstrap()
    cancel_post_cold_pulse_timer()
    set_bootstrap_state(BOOTSTRAP_IDLE, "reset_bootstrap")
    Bootstrap.cold_applied = false
    Bootstrap.post_pulse_requested = false
end

local function begin_cold_apply_bootstrap()
    set_bootstrap_state(BOOTSTRAP_COLD_PENDING, "begin_cold_apply")
end

local function complete_cold_apply_bootstrap()
    Bootstrap.cold_applied = true
    set_bootstrap_state(BOOTSTRAP_WAIT_POST_PULSE, "complete_cold_apply")
end

local function queue_post_cold_pulse()
    cancel_post_cold_pulse_timer()
    Bootstrap.post_pulse_token = Env.run_after_delay(
        POST_COLD_APPLY_PULSE_DELAY_MS,
        "post_cold_apply_stance_pulse",
        function()
            Bootstrap.post_pulse_token = nil
            Bootstrap.post_pulse_requested = true
        end
    )
end

local function should_run_queued_post_pulse()
    return Bootstrap.state == BOOTSTRAP_WAIT_POST_PULSE and Bootstrap.post_pulse_requested
end

local function consume_queued_post_pulse()
    Bootstrap.post_pulse_requested = false
    set_bootstrap_state(BOOTSTRAP_IDLE, "consume_post_cold_pulse")
end

local function is_bootstrap_gate_active()
    return Bootstrap.state ~= BOOTSTRAP_IDLE
end

function H.defer_stance_pulse(duration_ms, reason)
    local ms = tonumber(duration_ms) or RELOAD_DEFER_DEFAULT_MS
    if ms < 0 then
        ms = 0
    end
    -- Wrapper blocks while (now - last_state_change) < STATE_CHANGE_COOLDOWN,
    -- so shift by cooldown to make external defer duration match requested ms.
    last_state_change = os_clock() + (ms / 1000.0) - STATE_CHANGE_COOLDOWN
    log.debug(
        "Hooks stance pulse deferred for "
            .. tostring(math.floor(ms))
            .. "ms ("
            .. tostring(reason or "unspecified")
            .. ")",
        "hooks_defer_stance_pulse",
        true
    )
end

function H.init(Camera, Config)
    log.debug("Hooks init: starting initialization", "hooks_init_start")

    if not Camera or not Config then
        log.error(
            "Hooks initialization aborted because the camera or config dependency was missing.",
            "hooks_init_missing_dependencies"
        )
        return
    end

    if H._initialized then
        log.debug("Hooks already initialized; skipping duplicate registration", "hooks_init_duplicate")
        return
    end

    H.Camera = Camera
    H.ConfigMod = Config
    reset_bootstrap()

    log.debug("Hooks init: clearing previously registered hooks", "hooks_init_clear_old")
    for _, entry in pairs(H._hook_ids) do
        unregister_hook(entry)
    end
    H._hook_ids = {}

    PlayerCtx.init()
    log.debug("Hooks init: PlayerCtx initialized", "hooks_init_playerctx")

    local original_pulse = Stance.pulse
    rawset(Stance, "pulse", function()
        local now = os_clock()
        if (now - last_state_change) < STATE_CHANGE_COOLDOWN then
            return
        end

        local prev_profile = Stance.get_current_profile and Stance.get_current_profile()
        original_pulse()
        local new_profile = Stance.get_current_profile and Stance.get_current_profile()

        if prev_profile ~= new_profile then
            last_state_change = now
        end
    end)
    log.debug("Hooks init: Stance pulse wrapper installed", "hooks_init_pulse_wrap")

    Stance.init(Camera, Config)
    log.debug("Hooks init: Stance initialized", "hooks_init_stance")

    -- -------------------------------------------------------------------------
    -- ClientRestart Hook
    -- -------------------------------------------------------------------------
    H._hook_ids.client_restart = { path = "/Script/Engine.PlayerController:ClientRestart" }
    H._hook_ids.client_restart.pre_id, H._hook_ids.client_restart.post_id = safe_register_hook(
        H._hook_ids.client_restart.path,
        function(self, NewPawn)
            Env.run_now("client_restart_hook", function()
                log.debug("ClientRestart: clearing caches and stopping enforcement", "client_restart")
                if H.Camera and H.Camera.stop_enforcement then
                    H.Camera.stop_enforcement()
                end
                if PlayerCtx.clear_caches then
                    PlayerCtx.clear_caches()
                end
                if Stance.reset_state then
                    Stance.reset_state()
                end
                reset_bootstrap()
            end)
            return nil -- GUARDRAIL: Prevent UE return value override
        end
    )

    log.debug(
        "Hooks init: ClientRestart hook registered pre="
            .. tostring(H._hook_ids.client_restart.pre_id)
            .. " post="
            .. tostring(H._hook_ids.client_restart.post_id),
        "hooks_init_clientrestart_registered"
    )

    -- -------------------------------------------------------------------------
    -- IsBlockingMode Hook
    -- -------------------------------------------------------------------------
    H._hook_ids.blocking_mode = { path = "/Script/SB.SBCharacter:IsBlockingMode" }
    H._hook_ids.blocking_mode.pre_id, H._hook_ids.blocking_mode.post_id = safe_register_hook(
        H._hook_ids.blocking_mode.path,
        function(self, result)
            Env.run_now("isblockingmode_hook", function()
                Heartbeat.pulse()

                if should_run_queued_post_pulse() then
                    original_pulse()
                    consume_queued_post_pulse()
                end

                if not Bootstrap.cold_applied and Bootstrap.state == BOOTSTRAP_IDLE then
                    if not PlayerCtx.camera_or_pc_invalid() then
                        local tps = PlayerCtx.is_tps_mode()
                        local inBattle = PlayerCtx.is_battle()

                        if tps == false and inBattle == false then
                            local cfg = H.ConfigMod.get()
                            if not cfg or type(cfg) ~= "table" then
                                log.error(
                                    "Cold apply skipped because the runtime config is invalid.",
                                    "cold_apply_missing_cfg"
                                )
                                return -- Exits the pcall, not the hook
                            end

                            begin_cold_apply_bootstrap()
                            -- Only set _cold_applied if the camera is actually reachable
                            local cam_ok = Env.run_on_game_thread("cold_apply", function()
                                H.Camera.set_fov_via_function(cfg.fovs.fov)
                                H.Camera.set_camera_relative_location(cfg.DefaultPosition)
                                H.Camera.disable_camera_collision(cfg.DisableCameraCollision)

                                complete_cold_apply_bootstrap()

                                queue_post_cold_pulse()
                            end)

                            if not cam_ok then
                                set_bootstrap_state(BOOTSTRAP_IDLE, "cold_apply_schedule_failed")
                                log.warn("Cold-apply deferred: Camera interface not ready yet.", "cold_apply_defer")
                            end
                        end
                    end
                end

                if is_bootstrap_gate_active() then
                    return
                end

                Stance.pulse()
            end)
            return nil -- GUARDRAIL: Prevent UE return value override
        end
    )

    log.debug(
        "Hooks init: IsBlockingMode hook registered pre="
            .. tostring(H._hook_ids.blocking_mode.pre_id)
            .. " post="
            .. tostring(H._hook_ids.blocking_mode.post_id),
        "hooks_init_blocking_registered"
    )

    H._initialized = true
    log.debug("Hooks init: initialization complete", "hooks_init_complete")
end

return H
