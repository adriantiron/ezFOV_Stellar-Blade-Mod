local PlayerCtx = require("playercontext")
local Heartbeat = require("heartbeat")
local Stance    = require("stance")
local Logging   = require("logging")

local os_clock = os.clock

local H = {}

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

function H.init(Camera, Config)
    if not Camera or not Config then
        log_error("Hooks initialization aborted because the camera or config dependency was missing.", "hooks_init_missing_dependencies", true)
        return
    end

    H.Camera    = Camera
    H.ConfigMod = Config
    H._cold_applied = false

    PlayerCtx.init()

    local original_pulse = Stance.pulse
    Stance.pulse = function()
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
    end

    Stance.init(Camera, Config)

    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self, NewPawn)
        log_debug("ClientRestart: clearing caches and stopping enforcement", "client_restart")
        if H.Camera and H.Camera.stop_enforcement then
            H.Camera.stop_enforcement()
        end
        if PlayerCtx.clear_caches then PlayerCtx.clear_caches() end
        H._cold_applied = false
    end)

    RegisterHook("/Script/SB.SBCharacter:IsBlockingMode", function(self, result)
        Heartbeat.pulse()

        if not H._cold_applied then
            if not PlayerCtx.camera_or_pc_invalid() then
                local tps      = PlayerCtx.is_tps_mode()
                local inBattle = PlayerCtx.is_battle()

                if tps == false and inBattle == false then
                    local cfg = H.ConfigMod.get()
                    if not cfg or type(cfg) ~= "table" then
                        log_error("Cold apply skipped because the runtime config is invalid.", "cold_apply_missing_cfg", true)
                        return
                    end
                    ExecuteInGameThread(function()
                        H.Camera.set_fov_via_function(cfg.fovs.fov)
                        H.Camera.set_camera_relative_location(cfg.DefaultPosition)
                        H.Camera.disable_camera_collision(cfg.DisableCameraCollision)
                    end)
                    H._cold_applied = true
                    log_debug("Cold-applied default camera on first safe pulse", "cold_apply")
                end
            end
        end

        Stance.pulse()
    end)
end

return H