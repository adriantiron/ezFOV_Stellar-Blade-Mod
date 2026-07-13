-- Pure profile resolution: the single source for the state -> profile and
-- profile -> fov / position mappings shared by stance.lua and main.lua.
--
-- Deliberately side-effect free and dependency free (locomotion-state values are
-- passed in) so it can be unit-tested directly. The lock-on grace period is NOT here:
-- it is stateful (time + last-applied profile) and lives in stance.lua, which wraps
-- resolve_profile with that behavior.
local Profiles = {}

Profiles.PROFILES = {
    jog = "jog",
    tps = "tps",
    lockon = "lockon",
    battle = "battle",
    idle = "idle",
    walk = "walk",
    sprint = "sprint",
}

local PRFL = Profiles.PROFILES

-- Resolve the active profile from the current player state.
--   state       : { tps, lockon, battle, locomotion } (locomotion is a loco_states value)
--   cfg         : the runtime config (for the Enable* feature toggles)
--   loco_states : PlayerCtx.LOCO_STATES (passed in to keep this module dependency-free)
-- Priority: tps > lock-on > battle > sprint/idle/walk > jog. The optional
-- profiles are gated by their Enable* toggles; battle and tps are not gated.
function Profiles.resolve_profile(state, cfg, loco_states)
    if type(state) ~= "table" or type(cfg) ~= "table" or type(cfg.fovs) ~= "table" then
        return PRFL.jog
    end

    if state.tps == true then
        return PRFL.tps
    end
    if state.lockon == true and cfg.EnableLockOnCamera then
        return PRFL.lockon
    end
    if state.battle == true then
        return PRFL.battle
    end

    if type(loco_states) == "table" then
        if state.locomotion == loco_states.sprint and cfg.EnableSprintingCamera then
            return PRFL.sprint
        end
        if state.locomotion == loco_states.idle and cfg.EnableIdleCamera then
            return PRFL.idle
        end
        if state.locomotion == loco_states.walk and cfg.EnableWalkingCamera then
            return PRFL.walk
        end
    end

    return PRFL.jog
end

-- The FOV a profile should use, with graceful fallbacks to the base FOV.
function Profiles.fov_for_profile(profile, cfg)
    if profile == PRFL.tps then
        return cfg.fovs.tps or cfg.fovs.jog
    end
    if profile == PRFL.lockon then
        return cfg.fovs.lockon or cfg.fovs.combat or cfg.fovs.jog
    end
    if profile == PRFL.battle then
        return cfg.fovs.combat or cfg.fovs.jog
    end
    if profile == PRFL.idle then
        return cfg.fovs.idle or cfg.fovs.jog
    end
    if profile == PRFL.walk then
        return cfg.fovs.walk or cfg.fovs.jog
    end
    if profile == PRFL.sprint then
        return cfg.fovs.sprint or cfg.fovs.jog
    end
    return cfg.fovs.jog
end

-- The config position table a profile maps to. tps and jog both use JogPosition;
-- callers that must not move the camera for a given profile (e.g. stance skips tps/lock-on)
-- apply their own guard before using this.
function Profiles.position_for_profile(profile, cfg)
    if profile == PRFL.lockon then
        return cfg.LockOnPosition
    end
    if profile == PRFL.battle then
        return cfg.CombatPosition
    end
    if profile == PRFL.idle then
        return cfg.IdlePosition
    end
    if profile == PRFL.walk then
        return cfg.WalkPosition
    end
    if profile == PRFL.sprint then
        return cfg.SprintPosition
    end
    return cfg.JogPosition
end

-- The cfg.fovs field a profile's FOV is stored under, for callers that WRITE the value
-- (e.g. live FOV adjustment) rather than just read it via fov_for_profile.
local FOV_KEY = {
    [PRFL.tps] = "tps",
    [PRFL.lockon] = "lockon",
    [PRFL.battle] = "combat",
    [PRFL.idle] = "idle",
    [PRFL.walk] = "walk",
    [PRFL.sprint] = "sprint",
    [PRFL.jog] = "jog",
}

function Profiles.fov_key_for_profile(profile)
    return FOV_KEY[profile] or "jog"
end

return Profiles
