local PlayerCtx = require("playercontext")
local Heartbeat = require("heartbeat")
local Stance    = require("stance")

local os_clock = os.clock

local H = {}

local last_state_change = 0
local STATE_CHANGE_COOLDOWN = 0.3

function H.init(Camera, Config)
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
        print("[Hooks] ClientRestart: clearing caches and stopping enforcement\n")
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
                    ExecuteInGameThread(function()
                        H.Camera.set_fov_via_function(cfg.fovs.fov)
                        H.Camera.set_camera_relative_location(cfg.DefaultPosition)
                        H.Camera.disable_camera_collision(cfg.DisableCameraCollision)
                    end)
                    H._cold_applied = true
                    print("[Hooks] Cold-applied default camera on first safe pulse\n")
                end
            end
        end

        Stance.pulse()
    end)
end

return H