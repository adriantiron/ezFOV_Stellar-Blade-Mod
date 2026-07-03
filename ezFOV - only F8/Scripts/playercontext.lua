local Heartbeat = require("heartbeat")
local Logging   = require("logging")

local math_sqrt = math.sqrt

local PlayerCtx = {
    _disabled = true,
    _pc   = nil,
    _pawn = nil,
    _cam  = nil,
    _boom = nil,
    _on_disable = {},
}

-- Local helper logging functions to prefix messages with the module name and enforce level
local function log_warn(message, once_key, cache)
    Logging.log_warn("PlayerCtx", message, once_key, cache)
end

local function log_error(message, once_key, cache)
    Logging.log_error("PlayerCtx", message, once_key, cache)
end

local function log_debug(message, once_key, cache)
    Logging.log_debug("PlayerCtx", message, once_key, cache)
end
-- ========================================================================================

local function _drop_caches()
    PlayerCtx._pc   = nil
    PlayerCtx._pawn = nil
    PlayerCtx._cam  = nil
    PlayerCtx._boom = nil
end

local function _notify_disable()
    for i = 1, #PlayerCtx._on_disable do
        local ok, err = pcall(PlayerCtx._on_disable[i])
        if not ok then log_error("on_disable handler error: " .. tostring(err), "on_disable_handler_error") end
    end
end

local function obj_is_valid(obj)
    if not obj then return false end
    if type(obj.IsValid) ~= "function" then return true end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

local _lockon_fn    = nil
local _lockon_tried = false

local _hb_enabled_prev  = Heartbeat.on_enabled
local _hb_disabled_prev = Heartbeat.on_disabled

Heartbeat.on_enabled = function(...)
    if _hb_enabled_prev then pcall(_hb_enabled_prev, ...) end
    PlayerCtx._disabled = false
end

Heartbeat.on_disabled = function(...)
    if _hb_disabled_prev then pcall(_hb_disabled_prev, ...) end
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
    if reason then log_warn("force_disable: " .. tostring(reason), "force_disable") end
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
    _lockon_fn    = nil
    _lockon_tried = false
end

function PlayerCtx.get_pc()
    if PlayerCtx.is_disabled() then return nil end
    if obj_is_valid(PlayerCtx._pc) then return PlayerCtx._pc end

    local ok, pc = pcall(function() return FindFirstOf("SBPlayerController") end)
    if not ok or not obj_is_valid(pc) then
        log_debug("get_pc: SBPlayerController not ready yet", "pc_missing", true)
        return nil
    end
    PlayerCtx._pc = pc
    return pc
end

function PlayerCtx.get_pawn()
    if PlayerCtx.is_disabled() then return nil end
    if obj_is_valid(PlayerCtx._pawn) then return PlayerCtx._pawn end

    local pc = PlayerCtx.get_pc()
    if not pc then
        log_debug("get_pawn: no player controller yet", "pawn_no_pc", true)
        return nil
    end

    local ok, pawn = pcall(function() return pc.Pawn end)
    if not ok or not obj_is_valid(pawn) then
        log_debug("get_pawn: pawn not ready yet", "pawn_missing", true)
        return nil
    end
    PlayerCtx._pawn = pawn
    return pawn
end

function PlayerCtx.get_camera()
    if PlayerCtx.is_disabled() then return nil end
    if obj_is_valid(PlayerCtx._cam) then return PlayerCtx._cam end

    local pawn = PlayerCtx.get_pawn()
    if not pawn then
        log_debug("get_camera: no pawn yet", "cam_no_pawn", true)
        return nil
    end

    local ok, cam = pcall(function() return pawn.FollowCamera end)
    if not ok or not obj_is_valid(cam) then
        log_debug("get_camera: FollowCamera not ready yet", "cam_missing", true)
        return nil
    end
    PlayerCtx._cam = cam
    return cam
end

function PlayerCtx.get_camera_boom()
    if PlayerCtx.is_disabled() then return nil end
    if obj_is_valid(PlayerCtx._boom) then return PlayerCtx._boom end

    local pawn = PlayerCtx.get_pawn()
    if not pawn then
        log_debug("get_camera_boom: no pawn yet", "boom_no_pawn", true)
        return nil
    end

    local ok, boom = pcall(function() return pawn.CameraBoom end)
    if not ok or not obj_is_valid(boom) then
        log_debug("get_camera_boom: CameraBoom not ready yet", "boom_missing", true)
        return nil
    end
    PlayerCtx._boom = boom
    return boom
end

function PlayerCtx.is_tps_mode()
    if Heartbeat.is_disabled() then return nil end
    local pawn = PlayerCtx.get_pawn()
    if not obj_is_valid(pawn) then return nil end
    local ok, result = pcall(function() return pawn:IsTPSMode() end)
    if ok then return result end
    return nil
end

function PlayerCtx.is_battle()
    if Heartbeat.is_disabled() then return nil end
    local pawn = PlayerCtx.get_pawn()
    if not obj_is_valid(pawn) then return nil end
    local ok, result = pcall(function() return pawn:IsBattle() end)
    if ok then return result end
    return nil
end

function PlayerCtx.is_lock_on()
    if Heartbeat.is_disabled() then return nil end
    local pawn = PlayerCtx.get_pawn()
    if not obj_is_valid(pawn) then return nil end

    if _lockon_fn then
        local ok, result = pcall(_lockon_fn, pawn)
        if ok then return result end
        _lockon_fn    = nil
        _lockon_tried = false
    end

    if _lockon_tried then return nil end
    _lockon_tried = true

    local ok_bl, val_bl = pcall(function() return pawn.bLockOn end)
    if ok_bl and type(val_bl) == "boolean" then
        _lockon_fn = function(p) return p.bLockOn end
        log_debug("Lock-on detection: using bLockOn property", "lockon_detect_bLockOn")
        return val_bl
    end

    local candidates = {
        { name = "IsLockOn",       fn = function(p) return p:IsLockOn() end },
        { name = "IsLockOnMode",   fn = function(p) return p:IsLockOnMode() end },
        { name = "IsTargetLockOn", fn = function(p) return p:IsTargetLockOn() end },
    }
    for _, m in ipairs(candidates) do
        local ok, result = pcall(m.fn, pawn)
        if ok then
            _lockon_fn = m.fn
            log_debug("Lock-on detection: using " .. m.name .. "()", "lockon_detect_" .. m.name)
            return result
        end
    end

    local ok_lc, _ = pcall(function() return pawn.LockOnCharacter end)
    if ok_lc then
        _lockon_fn = function(p)
            local t = p.LockOnCharacter
            if t == nil then return false end
            if t.IsValid then return t:IsValid() end
            return true
        end
        log_debug("Lock-on detection: using LockOnCharacter property", "lockon_detect_LockOnCharacter")
        return _lockon_fn(pawn)
    end

    log_warn("No lock-on detection method found!", "lockon_detect_none")
    return nil
end

function PlayerCtx.camera_or_pc_invalid()
    if PlayerCtx.is_disabled() then return true end
    if not PlayerCtx.get_pc()     then return true end
    if not PlayerCtx.get_camera() then return true end
    return false
end

function PlayerCtx.ensure_ready(require_boom)
    if PlayerCtx.is_disabled()    then return false end
    if not PlayerCtx.get_pc()     then return false end
    if not PlayerCtx.get_pawn()   then return false end
    if not PlayerCtx.get_camera() then return false end
    if require_boom and not PlayerCtx.get_camera_boom() then return false end
    return true
end

local _loco = {
    last_state    = nil,
    pending_state = nil,
    change_t      = 0,
    stable_delay  = 0.3,
}

function PlayerCtx.get_locomotion_state()
    local pawn = PlayerCtx.get_pawn()
    if not obj_is_valid(pawn) then
        return _loco.last_state
    end

    local ok_cm, cm = pcall(function() return pawn.CharacterMovement end)
    if not ok_cm or not cm or (not obj_is_valid(cm)) then
        return _loco.last_state
    end

    local ok_v, v = pcall(function() return cm.Velocity end)
    if not ok_v or not v then
        return _loco.last_state
    end

    local x = v and tonumber(v.X) or 0
    local y = v and tonumber(v.Y) or 0
    local speed2D = math_sqrt(x * x + y * y)

    local new_state
    if speed2D < 120 then
        new_state = "idle"
    elseif speed2D < 240 then
        new_state = "slow_walk"
    elseif speed2D > 550 then
        new_state = "sprint"
    else
        new_state = "walk"
    end

    local now = os.clock()
    if new_state ~= _loco.last_state then
        if _loco.pending_state ~= new_state then
            _loco.pending_state = new_state
            _loco.change_t = now
        elseif (now - _loco.change_t) >= _loco.stable_delay then
            _loco.last_state    = new_state
            _loco.pending_state = nil
        end
    else
        _loco.pending_state = nil
    end

    return _loco.last_state
end

function PlayerCtx.get_snapshot()
    if Heartbeat.is_disabled() then return nil end
    if PlayerCtx._disabled      then return nil end

    if not PlayerCtx.ensure_ready(true) then return nil end

    local pc   = PlayerCtx._pc
    local pawn = PlayerCtx._pawn
    local cam  = PlayerCtx._cam
    local boom = PlayerCtx._boom

    if not (obj_is_valid(pc) and obj_is_valid(pawn)
            and obj_is_valid(cam) and obj_is_valid(boom)) then
        return nil
    end

    return { pc = pc, pawn = pawn, cam = cam, boom = boom }
end

return PlayerCtx