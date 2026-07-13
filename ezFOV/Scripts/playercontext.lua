local Heartbeat = require("heartbeat")
local Logging = require("logging")
local Constants = require("constants")
local UEObject = require("ue_object")

local math_sqrt = math.sqrt

local PlayerCtx = {
    _disabled = true,
    _pc = nil,
    _pawn = nil,
    _cam = nil,
    _boom = nil,
    _on_disable = {},
    LOCO_STATES = {
        idle = "idle",
        walk = "walk",
        jog = "jog",
        sprint = "sprint",
    },
}

-- Component-scoped logger (see Logging.for_component).
local log = Logging.for_component("PlayerCtx")

local function _drop_caches()
    PlayerCtx._pc = nil
    PlayerCtx._pawn = nil
    PlayerCtx._cam = nil
    PlayerCtx._boom = nil
end

-- Helper functions to keep code DRY and ensure all child caches die with the pawn
local function clear_pawn_caches()
    PlayerCtx._pawn = nil
    PlayerCtx._cam = nil
    PlayerCtx._boom = nil
end

local function _notify_disable()
    for i = 1, #PlayerCtx._on_disable do
        local ok, err = pcall(PlayerCtx._on_disable[i])
        if not ok then
            log.error("on_disable handler error: " .. tostring(err))
        end
    end
end

local obj_is_valid = UEObject.is_valid

local _lockon_fn = nil
local _lockon_tried = false
local _lockon_pawn = nil

local function clear_lockon_caches()
    _lockon_fn = nil
    _lockon_tried = false
    _lockon_pawn = nil
end

local _hb_enabled_prev = Heartbeat.on_enabled
local _hb_disabled_prev = Heartbeat.on_disabled

Heartbeat.on_enabled = function(...)
    if _hb_enabled_prev then
        pcall(_hb_enabled_prev, ...)
    end
    PlayerCtx._disabled = false
end

Heartbeat.on_disabled = function(...)
    if _hb_disabled_prev then
        pcall(_hb_disabled_prev, ...)
    end
    if not PlayerCtx._disabled then
        PlayerCtx._disabled = true
        _drop_caches()
        _notify_disable()
    else
        _drop_caches()
    end
end

function PlayerCtx.init() end

function PlayerCtx.is_disabled()
    return Heartbeat.is_disabled() or PlayerCtx._disabled
end

function PlayerCtx.on_disable(fn)
    if type(fn) == "function" then
        PlayerCtx._on_disable[#PlayerCtx._on_disable + 1] = fn
    end
end

function PlayerCtx.force_disable(reason)
    if reason then
        log.warn("force_disable: " .. tostring(reason), "force_disable")
    end
    if not PlayerCtx._disabled then
        PlayerCtx._disabled = true
        _drop_caches()
        _notify_disable()
    else
        _drop_caches()
    end
end

function PlayerCtx.temporarily_disable()
    _drop_caches()
end

function PlayerCtx.clear_caches()
    _drop_caches()
    _lockon_fn = nil
    _lockon_tried = false
    _lockon_pawn = nil
end

function PlayerCtx.get_pc()
    if PlayerCtx.is_disabled() then
        return nil
    end
    if obj_is_valid(PlayerCtx._pc) then
        return PlayerCtx._pc
    end

    local ok, pc = pcall(function()
        return FindFirstOf("SBPlayerController")
    end)
    if not ok or not obj_is_valid(pc) then
        log.debug("get_pc: SBPlayerController not ready yet", "pc_missing", true)
        return nil
    end
    PlayerCtx._pc = pc
    return pc
end

function PlayerCtx.get_pawn()
    if PlayerCtx.is_disabled() then
        return nil
    end

    local pc = PlayerCtx.get_pc()
    if not pc or not obj_is_valid(pc) then
        log.debug("get_pawn: no player controller yet", "pawn_no_pc", true)
        PlayerCtx._pc = nil
        clear_pawn_caches()
        return nil
    end

    -- 1. Query the engine's absolute truth FIRST, safely.
    local ok_engine, engine_pawn = pcall(function()
        return pc.Pawn
    end)
    if not ok_engine or not engine_pawn then
        if not ok_engine then
            log.warn(
                "get_pawn: failed to read pc.Pawn; clearing pawn caches. hb_disabled="
                    .. tostring(Heartbeat.is_disabled()),
                "pawn_read_failed",
                true
            )
        end
        clear_pawn_caches()
        return nil
    end

    -- 2. If the engine's pawn doesn't match our cache, our cache is stale/dead.
    -- We never dereference the old cached pawn here; we only compare the raw pointer identity.
    if PlayerCtx._pawn ~= engine_pawn then
        log.debug("get_pawn: pawn reference changed; updating cache", "pawn_changed", true)
        PlayerCtx._pawn = engine_pawn
        -- Only clear child components so they fetch fresh from the new pawn next time
        PlayerCtx._cam = nil
        PlayerCtx._boom = nil
        clear_lockon_caches()
    end

    -- 3. Only after the pointer has been updated do we validate the new object.
    if not obj_is_valid(PlayerCtx._pawn) then
        log.debug("get_pawn: engine pawn invalid", "pawn_missing", true)
        clear_pawn_caches()
        clear_lockon_caches()
        return nil
    end

    return PlayerCtx._pawn
end

function PlayerCtx.get_camera()
    if PlayerCtx.is_disabled() then
        return nil
    end
    if obj_is_valid(PlayerCtx._cam) then
        return PlayerCtx._cam
    end

    local pawn = PlayerCtx.get_pawn()
    if not pawn then
        log.debug("get_camera: no pawn yet", "cam_no_pawn", true)
        return nil
    end

    local ok, cam = pcall(function()
        return pawn.FollowCamera
    end)
    if not ok or not obj_is_valid(cam) then
        log.debug("get_camera: FollowCamera not ready yet", "cam_missing", true)
        return nil
    end
    PlayerCtx._cam = cam
    return cam
end

function PlayerCtx.get_camera_boom()
    if PlayerCtx.is_disabled() then
        return nil
    end
    if obj_is_valid(PlayerCtx._boom) then
        return PlayerCtx._boom
    end

    local pawn = PlayerCtx.get_pawn()
    if not pawn then
        log.debug("get_camera_boom: no pawn yet", "boom_no_pawn", true)
        return nil
    end

    local ok, boom = pcall(function()
        return pawn.CameraBoom
    end)
    if not ok or not obj_is_valid(boom) then
        log.debug("get_camera_boom: CameraBoom not ready yet", "boom_missing", true)
        return nil
    end
    PlayerCtx._boom = boom
    return boom
end

function PlayerCtx.is_tps_mode()
    if Heartbeat.is_disabled() then
        return nil
    end
    local pawn = PlayerCtx.get_pawn()
    if not obj_is_valid(pawn) then
        return nil
    end
    local ok, result = pcall(function()
        return pawn:IsTPSMode()
    end)
    if ok then
        return result
    end
    log.warn(
        "is_tps_mode: engine call failed while reading TPS state. hb_disabled=" .. tostring(Heartbeat.is_disabled()),
        "tps_mode_read_failed",
        true
    )
    return nil
end

function PlayerCtx.is_battle()
    if Heartbeat.is_disabled() then
        return nil
    end
    local pawn = PlayerCtx.get_pawn()
    if not obj_is_valid(pawn) then
        return nil
    end
    local ok, result = pcall(function()
        return pawn:IsBattle()
    end)
    if ok then
        return result
    end
    log.warn(
        "is_battle: engine call failed while reading battle state. hb_disabled=" .. tostring(Heartbeat.is_disabled()),
        "battle_state_read_failed",
        true
    )
    return nil
end

function PlayerCtx.is_lock_on()
    if Heartbeat.is_disabled() then
        return nil
    end
    local pawn = PlayerCtx.get_pawn()
    if not obj_is_valid(pawn) then
        clear_lockon_caches()
        return nil
    end

    if _lockon_pawn ~= pawn then
        _lockon_fn = nil
        _lockon_tried = false
        _lockon_pawn = pawn
    end

    if _lockon_fn then
        local ok, result = pcall(_lockon_fn, pawn)
        if ok then
            return result
        end
        log.warn(
            "is_lock_on: cached lock-on probe failed; retrying method discovery. hb_disabled="
                .. tostring(Heartbeat.is_disabled()),
            "lockon_probe_failed",
            true
        )
        _lockon_fn = nil
        _lockon_tried = false
    end

    if _lockon_tried then
        return nil
    end
    _lockon_tried = true

    local ok_bl, val_bl = pcall(function()
        return pawn.bLockOn
    end)
    if ok_bl and type(val_bl) == "boolean" then
        _lockon_fn = function(p)
            return p.bLockOn
        end
        log.debug("Lock-on detection: using bLockOn property", "lockon_detect_bLockOn", true)
        return val_bl
    end

    local candidates = {
        {
            name = "IsLockOn",
            fn = function(p)
                return p:IsLockOn()
            end,
        },
        {
            name = "IsLockOnMode",
            fn = function(p)
                return p:IsLockOnMode()
            end,
        },
        {
            name = "IsTargetLockOn",
            fn = function(p)
                return p:IsTargetLockOn()
            end,
        },
    }
    for _, m in ipairs(candidates) do
        local ok, result = pcall(m.fn, pawn)
        if ok then
            _lockon_fn = m.fn
            log.debug("Lock-on detection: using " .. m.name .. "()", "lockon_detect_" .. m.name)
            return result
        end
    end

    local ok_lc, _ = pcall(function()
        return pawn.LockOnCharacter
    end)
    if ok_lc then
        _lockon_fn = function(p)
            local t = p.LockOnCharacter
            if t == nil then
                return false
            end
            if t.IsValid then
                return t:IsValid()
            end
            return true
        end
        log.debug("Lock-on detection: using LockOnCharacter property", "lockon_detect_LockOnCharacter")
        return _lockon_fn(pawn)
    end

    _lockon_fn = nil
    _lockon_tried = false
    log.warn("No lock-on detection method found!", "lockon_detect_none")
    return nil
end

function PlayerCtx.camera_or_pc_invalid()
    if PlayerCtx.is_disabled() then
        return true
    end
    if not PlayerCtx.get_pc() then
        return true
    end
    if not PlayerCtx.get_camera() then
        return true
    end
    return false
end

function PlayerCtx.ensure_ready(require_boom)
    if PlayerCtx.is_disabled() then
        return false
    end
    if not PlayerCtx.get_pc() then
        return false
    end
    if not PlayerCtx.get_pawn() then
        return false
    end
    if not PlayerCtx.get_camera() then
        return false
    end
    if require_boom and not PlayerCtx.get_camera_boom() then
        return false
    end
    return true
end

local _loco = {
    last_state = nil,
    pending_state = nil,
    change_t = 0,
    stable_delay = 0.3,
}

function PlayerCtx.get_locomotion_state()
    local pawn = PlayerCtx.get_pawn()
    if not obj_is_valid(pawn) then
        return _loco.last_state
    end

    local ok_cm, cm = pcall(function()
        return pawn.CharacterMovement
    end)
    if not ok_cm or not cm or (not obj_is_valid(cm)) then
        if not ok_cm then
            log.warn(
                "get_locomotion_state: failed to read CharacterMovement. hb_disabled="
                    .. tostring(Heartbeat.is_disabled()),
                "loco_character_movement_read_failed",
                true
            )
        end
        return _loco.last_state
    end

    local ok_v, v = pcall(function()
        return cm.Velocity
    end)
    if not ok_v or not v then
        if not ok_v then
            log.warn(
                "get_locomotion_state: failed to read movement velocity. hb_disabled="
                    .. tostring(Heartbeat.is_disabled()),
                "loco_velocity_read_failed",
                true
            )
        end
        return _loco.last_state
    end

    local x = v and tonumber(v.X) or 0
    local y = v and tonumber(v.Y) or 0
    local speed2D = math_sqrt(x * x + y * y)

    local new_state
    if speed2D < Constants.LOCO_IDLE_MAX_SPEED then
        new_state = PlayerCtx.LOCO_STATES.idle
    elseif speed2D < Constants.LOCO_WALK_MAX_SPEED then
        new_state = PlayerCtx.LOCO_STATES.walk
    elseif speed2D > Constants.LOCO_SPRINT_MIN_SPEED then
        new_state = PlayerCtx.LOCO_STATES.sprint
    else
        new_state = PlayerCtx.LOCO_STATES.jog
    end

    local now = os.clock()
    if new_state ~= _loco.last_state then
        if _loco.pending_state ~= new_state then
            _loco.pending_state = new_state
            _loco.change_t = now
        elseif (now - _loco.change_t) >= _loco.stable_delay then
            _loco.last_state = new_state
            _loco.pending_state = nil
        end
    else
        _loco.pending_state = nil
    end

    return _loco.last_state
end

function PlayerCtx.get_snapshot()
    if Heartbeat.is_disabled() then
        return nil
    end
    if PlayerCtx._disabled then
        return nil
    end

    if not PlayerCtx.ensure_ready(false) then
        return nil
    end

    local pc = PlayerCtx._pc
    local pawn = PlayerCtx._pawn
    local cam = PlayerCtx._cam
    local boom = PlayerCtx._boom

    if not (obj_is_valid(pc) and obj_is_valid(pawn) and obj_is_valid(cam)) then
        return nil
    end

    return { pc = pc, pawn = pawn, cam = cam, boom = boom }
end

return PlayerCtx
