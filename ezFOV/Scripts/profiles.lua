-- Pure profile resolution: the single source for the state -> profile and
-- profile -> fov / position mappings shared by stance.lua and main.lua.
--
-- Deliberately side-effect free and dependency free (locomotion-state values are
-- passed in) so it can be unit-tested directly. The lock-on grace period is NOT here:
-- it is stateful (time + last-applied profile) and lives in stance.lua, which wraps
-- resolve_profile with that behaviour.
local Profiles = {}

Profiles.PROFILES = {
    default = "default",
    tps = "tps",
    lockon = "lockon",
    battle = "battle",
    idle = "idle",
    walk = "walk",
    sprint = "sprint",
}

local P = Profiles.PROFILES

-- Resolve the active profile from the current player state.
--   state       : { tps, lockon, battle, locomotion } (locomotion is a loco_states value)
--   cfg         : the runtime config (for the Enable* feature toggles)
--   loco_states : PlayerCtx.LOCO_STATES (passed in to keep this module dependency-free)
-- Priority: tps > lock-on > battle > sprint/idle/slow_walk > default. The optional
-- profiles are gated by their Enable* toggles; battle and tps are not gated.
function Profiles.resolve_profile(state, cfg, loco_states)
    if type(state) ~= "table" or type(cfg) ~= "table" or type(cfg.fovs) ~= "table" then
        return P.default
    end

    if state.tps == true then
        return P.tps
    end
    if state.lockon == true and cfg.EnableLockOnCamera then
        return P.lockon
    end
    if state.battle == true then
        return P.battle
    end

    if type(loco_states) == "table" then
        if state.locomotion == loco_states.sprint and cfg.EnableSprintingCamera then
            return P.sprint
        end
        if state.locomotion == loco_states.idle and cfg.EnableIdleCamera then
            return P.idle
        end
        if state.locomotion == loco_states.slow_walk and cfg.EnableWalkingCamera then
            return P.walk
        end
    end

    return P.default
end

-- The FOV a profile should use, with graceful fallbacks to the base FOV.
function Profiles.fov_for_profile(profile, cfg)
    if profile == P.tps then
        return cfg.fovs.tps or cfg.fovs.fov
    end
    if profile == P.lockon then
        return cfg.fovs.lockon or cfg.fovs.combat or cfg.fovs.fov
    end
    if profile == P.battle then
        return cfg.fovs.combat or cfg.fovs.fov
    end
    if profile == P.idle then
        return cfg.fovs.idle or cfg.fovs.fov
    end
    if profile == P.walk then
        return cfg.fovs.walk or cfg.fovs.fov
    end
    if profile == P.sprint then
        return cfg.fovs.sprint or cfg.fovs.fov
    end
    return cfg.fovs.fov
end

-- The config position table a profile maps to. tps and default both use DefaultPosition;
-- callers that must not move the camera for a given profile (e.g. stance skips tps/lock-on)
-- apply their own guard before using this.
function Profiles.position_for_profile(profile, cfg)
    if profile == P.lockon then
        return cfg.LockOnPosition
    end
    if profile == P.battle then
        return cfg.CombatPosition
    end
    if profile == P.idle then
        return cfg.IdlePosition
    end
    if profile == P.walk then
        return cfg.WalkPosition
    end
    if profile == P.sprint then
        return cfg.SprintPosition
    end
    return cfg.DefaultPosition
end

-- The cfg.fovs field a profile's FOV is stored under, for callers that WRITE the value
-- (e.g. live FOV adjustment) rather than just read it via fov_for_profile.
local FOV_KEY = {
    [P.tps] = "tps",
    [P.lockon] = "lockon",
    [P.battle] = "combat",
    [P.idle] = "idle",
    [P.walk] = "walk",
    [P.sprint] = "sprint",
    [P.default] = "fov",
}

function Profiles.fov_key_for_profile(profile)
    return FOV_KEY[profile] or "fov"
end

return Profiles
