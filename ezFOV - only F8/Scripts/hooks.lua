local PlayerCtx = require("playercontext")
local Heartbeat = require("heartbeat")
local Stance    = require("stance")
local Env       = require("env").bind("Hooks")
local Logging   = require("logging")

local os_clock = os.clock

local H = {
    _hook_ids = {},
    _initialized = false,
}

local last_state_change = 0
local STATE_CHANGE_COOLDOWN = 0.3

-- Local helper logging functions to prefix messages with the module name and enforce level
local function log_warn(message, once_key, cache)
    Logging.log_warn("Hooks", message, once_key, cache)
end

local function log_error(message, once_key, cache)
    Logging.log_error("Hooks", message, once_key, cache)
end

local function log_debug(message, once_key, cache)
    Logging.log_debug("Hooks", message, once_key, cache)
end
-- ========================================================================================

local function safe_register_hook(func_path, pre_cb, post_cb)
    return Env.safe_register_hook(func_path, pre_cb, post_cb)
end

local function unregister_hook(entry)
    Env.safe_unregister_hook(entry)
end

function H.init(Camera, Config)
    if not Camera or not Config then
        log_error("Hooks initialization aborted because the camera or config dependency was missing.", "hooks_init_missing_dependencies", true)
        return
    end

    if H._initialized then
        log_debug("Hooks already initialized; skipping duplicate registration", "hooks_init_duplicate")
        return
    end

    H.Camera    = Camera
    H.ConfigMod = Config
    H._cold_applied = false

    for _, entry in pairs(H._hook_ids) do
        unregister_hook(entry)
    end
    H._hook_ids = {}

    PlayerCtx.init()

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

    Stance.init(Camera, Config)

    -- -------------------------------------------------------------------------
    -- ClientRestart Hook
    -- -------------------------------------------------------------------------
    H._hook_ids.client_restart = { path = "/Script/Engine.PlayerController:ClientRestart" }
    H._hook_ids.client_restart.pre_id, H._hook_ids.client_restart.post_id = safe_register_hook(
        H._hook_ids.client_restart.path,
        function(self, NewPawn)
            -- ARMOR: Sandbox the callback logic
            local ok, err = pcall(function()
                log_debug("ClientRestart: clearing caches and stopping enforcement", "client_restart")
                if H.Camera and H.Camera.stop_enforcement then
                    H.Camera.stop_enforcement()
                end
                if PlayerCtx.clear_caches then PlayerCtx.clear_caches() end
                if Stance.reset_state then Stance.reset_state() end
                H._cold_applied = false
            end)

            if not ok then log_error("ClientRestart hook error: " .. tostring(err), "hook_err_restart") end
            return nil -- GUARDRAIL: Prevent UE return value override
        end
    )

    -- -------------------------------------------------------------------------
    -- IsBlockingMode Hook
    -- -------------------------------------------------------------------------
    H._hook_ids.blocking_mode = { path = "/Script/SB.SBCharacter:IsBlockingMode" }
    H._hook_ids.blocking_mode.pre_id, H._hook_ids.blocking_mode.post_id = safe_register_hook(
        H._hook_ids.blocking_mode.path,
        function(self, result)
            -- ARMOR: Sandbox the callback logic to protect the engine tick
            local ok, err = pcall(function()
                Heartbeat.pulse()

                if not H._cold_applied then
                    if not PlayerCtx.camera_or_pc_invalid() then
                        local tps      = PlayerCtx.is_tps_mode()
                        local inBattle = PlayerCtx.is_battle()

                        if tps == false and inBattle == false then
                            local cfg = H.ConfigMod.get()
                            if not cfg or type(cfg) ~= "table" then
                                log_error("Cold apply skipped because the runtime config is invalid.", "cold_apply_missing_cfg", true)
                                return  -- Exits the pcall, not the hook
                            end

                            -- Only set _cold_applied if the camera is actually reachable
                            local cam_ok = Env.run_on_game_thread("cold_apply", function()
                                H.Camera.set_fov_via_function(cfg.fovs.fov)
                                H.Camera.set_camera_relative_location(cfg.DefaultPosition)
                                H.Camera.disable_camera_collision(cfg.DisableCameraCollision)
                            end)

                            if cam_ok then
                                H._cold_applied = true
                                log_debug("Cold-applied default camera on first safe pulse", "cold_apply")
                            else
                                log_warn("Cold-apply deferred: Camera interface not ready yet.", "cold_apply_defer")
                            end
                        end
                    end
                end

                Stance.pulse()
            end)

            if not ok then log_error("IsBlockingMode hook error: " .. tostring(err), "hook_err_blocking") end
            return nil -- GUARDRAIL: Prevent UE return value override
        end
    )

    H._initialized = true
end

return H