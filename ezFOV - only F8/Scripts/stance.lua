local PlayerCtx = require("playercontext")

local math_abs = math.abs

local M = {
    _last_tick       = 0.0,
    _min_dt          = 0.10,
    _applied_profile = nil,
    _applied_fov     = nil,
}

local Camera, Config

function M.init(cameraMod, configMod)
    Camera = cameraMod
    Config = configMod
end

local _lockon_last_true  = os.clock() -- Initialize to the active engine clock instead of 0
local _LOCKON_EXIT_GRACE = 0.4
local _grace_logged      = false

local function safe_call(fn)
    local ok, r = pcall(fn)
    if ok then return r end
    return nil
end

local function ready()
    if PlayerCtx.is_disabled()          then return false end
    if PlayerCtx.camera_or_pc_invalid() then return false end
    if not Camera or not Config         then return false end
    return true
end

local function choose_profile(state, cfg)
    if state.tps == true then return "tps" end
	
	local current_cfg = cfg or (Config and Config.get())

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
                print(string.format("[Stance] Lock-on grace period active (%.0fms remaining)\n",
                    (_LOCKON_EXIT_GRACE - since_last) * 1000))
            end
            return "lockon"
        end
        print("[Stance] Lock-on grace period expired, exiting lock-on\n")
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

    local cfg = Config.get()
    local steps = steps_override or cfg.FOVTransitionSteps
    ExecuteInGameThread(function()
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
        ExecuteInGameThread(function()
            Camera.set_camera_relative_location(pos, steps_override)
        end)
    end
end

local function apply_profile(profile, cfg)
    if profile == M._applied_profile then return end

    local prev = M._applied_profile
    M._applied_profile = profile

    if prev == "lockon" then
        Camera.stop_enforcement()
    end

    if profile == "lockon" then
        local fov = fov_for_profile("lockon", cfg)
        M._applied_fov = fov
        Camera.start_enforcement(cfg.LockOnPosition, fov)
        print(string.format("[Stance] -> lockon FOV=%.0f Pos=(%.0f,%.0f,%.0f) YawBias=%.1f PitchBias=%.1f\n",
            fov, cfg.LockOnPosition.x or 0, cfg.LockOnPosition.y or 0, cfg.LockOnPosition.z or 0,
            cfg.LockOnYawBias or 0, cfg.LockOnPitchBias or 0))
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

    apply_position_for_profile(profile, cfg, steps_override)
    apply_fov_transition(fov_for_profile(profile, cfg), steps_override)
end

function M.get_current_profile()
    return M._applied_profile or "default"
end

function M.pulse()
    if not ready() then return end

    local t = os.clock()
    if (t - M._last_tick) < M._min_dt then return end
    M._last_tick = t

    local cfg = Config.get()

    local state = {
        tps    = (safe_call(function() return PlayerCtx.is_tps_mode() end) == true),
        lockon = (safe_call(function() return PlayerCtx.is_lock_on()  end) == true),
        battle = (safe_call(function() return PlayerCtx.is_battle()   end) == true),
        locomotion = safe_call(function()
            return PlayerCtx.get_locomotion_state and PlayerCtx.get_locomotion_state()
        end),
    }

    local profile = choose_profile(state, cfg)
    apply_profile(profile, cfg)

    if M._applied_profile == "lockon" then return end

    if Camera.is_transitioning and not Camera.is_transitioning() then
        local target = fov_for_profile(M._applied_profile, cfg)
        if target then
            ExecuteInGameThread(function()
                Camera.enforce_fov(target)
            end)
        end
    end
end

return M