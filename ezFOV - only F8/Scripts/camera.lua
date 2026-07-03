local UEHelpers = require("UEHelpers")
local PlayerCtx = require("playercontext")
local Logging   = require("logging")

local math_abs   = math.abs
local math_sin   = math.sin
local math_cos   = math.cos
local math_rad   = math.rad
local math_max   = math.max
local math_min   = math.min
local os_clock   = os.clock

local M = {
    _cfg = nil,
    _already_initialized = false,

    _fov_transition_token = nil,
    _active_target_fov    = nil,

    _cam_transition_token   = nil,
    _active_target_position = nil,
    _active_duration_ms     = nil,
    _anim_start_ms          = nil,

    _enforce_pos        = nil,
    _enforce_fov        = nil,
    _enforce_yaw_bias   = 0,
    _enforce_pitch_bias = 0,
}

local restore_originals -- Forward declaration to fix the visibility crash!

local _transition_busy   = false
local _queued_transition = nil
local _enforce_token     = nil
local _enforce_recovery_tripped = false

local _originals_saved = false
local _saved_originals = {}

local _enf_cam  = nil
local _enf_boom = nil
local _enf_pawn = nil

local _yaw_fn       = nil
local _yaw_tried    = false
local _last_yaw     = nil
local _last_sin     = 0
local _last_cos     = 1
local _yaw_epsilon  = 0.5

local _ENFORCE_TICK_MS   = 8
local _ENFORCE_RETRY_MS  = 50
local _enforce_miss_count = 0

-- Local helper logging functions to prefix messages with the module name and enforce level
local function log_warn(message, once_key, cache)
    Logging.log_warn("Camera", message, once_key, cache)
end

local function log_error(message, once_key, cache)
    Logging.log_error("Camera", message, once_key, cache)
end

local function log_debug(message, once_key, cache)
    Logging.log_debug("Camera", message, once_key, cache)
end
-- ========================================================================================

local function obj_is_valid(obj)
    if not obj then return false end
    if type(obj.IsValid) ~= "function" then return true end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

local function safe_write(fn, context)
    local ok, err = pcall(fn)
    if not ok then
        log_warn((context or "Property write") .. " failed (object likely mid-destruction): " .. tostring(err), "safe_write_fail")
    end
    return ok
end

-- ==================== Yaw reading ====================

local function get_camera_yaw_raw(snap)
    if _yaw_fn then
        local ok, val = pcall(_yaw_fn, snap)
        if ok and val then return tonumber(val) or 0 end
        _yaw_fn    = nil
        _yaw_tried = false
    end

    if _yaw_tried then return 0 end
    _yaw_tried = true

    local ok1, rot1 = pcall(function() return snap.pc:GetControlRotation() end)
    if ok1 and rot1 and rot1.Yaw ~= nil then
        _yaw_fn = function(s) return s.pc:GetControlRotation().Yaw end
        log_debug("Yaw source resolved via GetControlRotation()", "yaw_source_rotation")
        return tonumber(rot1.Yaw) or 0
    end

    local ok2, rot2 = pcall(function() return snap.boom:K2_GetComponentRotation() end)
    if ok2 and rot2 and rot2.Yaw ~= nil then
        _yaw_fn = function(s) return s.boom:K2_GetComponentRotation().Yaw end
        log_debug("Yaw source resolved via boom K2_GetComponentRotation()", "yaw_source_boom")
        return tonumber(rot2.Yaw) or 0
    end

    local ok3, rot3 = pcall(function() return snap.cam:K2_GetComponentRotation() end)
    if ok3 and rot3 and rot3.Yaw ~= nil then
        _yaw_fn = function(s) return s.cam:K2_GetComponentRotation().Yaw end
        log_debug("Yaw source resolved via cam K2_GetComponentRotation()", "yaw_source_cam")
        return tonumber(rot3.Yaw) or 0
    end

    log_error("Unable to locate a valid camera yaw source across the known engine methods; yaw-based bias and lock-on positioning may be unstable.", "yaw_source_failure")
    return 0
end

local function get_yaw_sincos(snap)
    local yaw = get_camera_yaw_raw(snap)
    if _last_yaw and math_abs(yaw - _last_yaw) < _yaw_epsilon then
        return _last_sin, _last_cos
    end
    local rad = math_rad(yaw)
    _last_yaw = yaw
    _last_sin = math_sin(rad)
    _last_cos = math_cos(rad)
    return _last_sin, _last_cos
end

-- ==================== Cleanup ====================

local function clear_enforcement_caches()
    _enf_cam  = nil
    _enf_boom = nil
    _enf_pawn = nil
    _yaw_fn    = nil
    _yaw_tried = false
    _last_yaw  = nil
    _enforce_miss_count = 0
end

PlayerCtx.on_disable(function()
    if M._fov_transition_token then
        CancelDelay(M._fov_transition_token)
        M._fov_transition_token = nil
    end
    M._active_target_fov = nil

    if M._cam_transition_token then
        CancelDelay(M._cam_transition_token)
        M._cam_transition_token = nil
    end
    M._active_target_position = nil
    _transition_busy = false
    _queued_transition = nil

    clear_enforcement_caches()
end)

-- ==================== Helpers ====================

local function quadratic(t, b, c, d)
    if d == 0 then return b + c end -- Guard against division by zero
    t = t / d
    return -c * t * (t - 2) + b
end

local function now_ms()
    return os_clock() * 1000.0
end

-- ==================== Save / Restore ====================

local function save_originals(snap)
    if _originals_saved then return end
    _originals_saved = true
    _saved_originals = {}

    if not snap then
        log_error("Cannot save camera originals because the snapshot is unavailable.", "save_originals_no_snapshot", true)
        return
    end

    if obj_is_valid(snap.boom) then
        local to = snap.boom.TargetOffset
        if to then _saved_originals.target = { X = to.X, Y = to.Y, Z = to.Z } end
    end

    if obj_is_valid(snap.cam) then
        local rr = snap.cam.RelativeRotation
        if rr then _saved_originals.rel_rot = { Pitch = rr.Pitch, Yaw = rr.Yaw, Roll = rr.Roll } end
    end
end

local function restore_originals()
    if not _originals_saved then return end

    local snap = PlayerCtx.get_snapshot()
    if snap then
        if snap.boom and _saved_originals.target then
            local to = snap.boom.TargetOffset
            if to then
                to.X = _saved_originals.target.X
                to.Y = _saved_originals.target.Y
                to.Z = _saved_originals.target.Z
            end
        end

        if snap.cam and _saved_originals.rel_rot then
            local rr = snap.cam.RelativeRotation
            if rr then
                rr.Pitch = _saved_originals.rel_rot.Pitch
                rr.Yaw   = _saved_originals.rel_rot.Yaw
                rr.Roll  = _saved_originals.rel_rot.Roll
            end
        end
    end

    _originals_saved = false
    _saved_originals = {}
end

-- ==================== Transition check ====================

function M.is_transitioning()
    return M._fov_transition_token ~= nil
        or M._cam_transition_token ~= nil
        or _transition_busy
end

-- ==================== FOV transition ====================

function M.set_fov_via_function(target_fov, overrideSteps)
    if PlayerCtx.camera_or_pc_invalid() then
        log_warn("FOV transition aborted because the player camera context is unavailable.", "fov_transition_invalid_context")
        return
    end

    local snap = PlayerCtx.get_snapshot()
    if not snap then
        log_warn("FOV transition aborted because the camera snapshot is unavailable.", "fov_transition_invalid_snapshot")
        return
    end

    local cam = snap.cam
    if not obj_is_valid(cam) then
        log_warn("FOV transition aborted because the camera component is invalid.", "fov_transition_invalid_cam")
        return
    end

    if M._fov_transition_token then
        CancelDelay(M._fov_transition_token)
        M._fov_transition_token = nil
    end
    M._active_target_fov = target_fov

    local cfg_steps = (M._cfg and M._cfg.FOVTransitionSteps) or 20
    local steps = overrideSteps or math_max(cfg_steps, 10)
    local step = 0
    local current_fov = cam.ManualCameraFov or 75

    local function tick()
        if PlayerCtx.camera_or_pc_invalid() then
            M._fov_transition_token = nil
            M._active_target_fov = nil
            return
        end
        if not obj_is_valid(cam) then
            PlayerCtx.temporarily_disable()
            M._fov_transition_token = nil
            M._active_target_fov = nil
            return
        end

        if step <= steps then
            local eased = quadratic(step, current_fov, target_fov - current_fov, steps)
            cam.bManualCameraFovMode = true
            cam.ManualCameraFov = eased
            step = step + 1
            M._fov_transition_token = ExecuteWithDelay(1, tick)
        else
            M._fov_transition_token = nil
            M._active_target_fov = nil
        end
    end

    tick()
end

-- ==================== Camera position transition ====================

function M.set_camera_relative_location(target_position, overrideSteps)
    if PlayerCtx.camera_or_pc_invalid() then
        log_warn("Camera position transition aborted because the camera context is unavailable.", "camera_rel_loc_invalid_context", true)
        return
    end

    local snap = PlayerCtx.get_snapshot()
    if not snap then
        log_warn("Camera position transition aborted because the camera snapshot is unavailable.", "camera_rel_loc_no_snapshot", true)
        return
    end

    local cam = snap.cam
    if not obj_is_valid(cam) then
        log_warn("Camera position transition aborted because the camera component is invalid.", "camera_rel_loc_invalid_cam", true)
        return
    end

    local loc = cam and cam.RelativeLocation
    if not loc then
        log_warn("Camera position transition aborted because RelativeLocation is unavailable.", "camera_loc_missing")
        PlayerCtx.temporarily_disable()
        return
    end

    local from = { x = loc.X or 0, y = loc.Y or 0, z = loc.Z or 0 }
    local to = {
        x = target_position.x or target_position.X or 0,
        y = target_position.y or target_position.Y or 0,
        z = target_position.z or target_position.Z or 0,
    }

    if M._active_target_position
       and math_abs(M._active_target_position.x - to.x) < 0.01
       and math_abs(M._active_target_position.y - to.y) < 0.01
       and math_abs(M._active_target_position.z - to.z) < 0.01 then
        return
    end

    local cfg_steps = (M._cfg and M._cfg.FOVTransitionSteps) or 100
    local steps_units = overrideSteps or math_max(cfg_steps, 10)
    local unit = (M._cfg and M._cfg.TransitionTimeUnit) or 3
    local duration_ms = math_max(steps_units * unit, 10)

    if _transition_busy then
        if M._active_target_position
           and math_abs(M._active_target_position.x - to.x) < 0.01
           and math_abs(M._active_target_position.y - to.y) < 0.01
           and math_abs(M._active_target_position.z - to.z) < 0.01 then
            M._active_duration_ms = duration_ms
            return
        end
        _queued_transition = { pos = target_position, steps = overrideSteps }
        return
    end

    if M._cam_transition_token then
        CancelDelay(M._cam_transition_token)
        M._cam_transition_token = nil
    end

    M._active_target_position = { x = to.x, y = to.y, z = to.z }
    M._active_duration_ms = duration_ms
    M._anim_start_ms = now_ms()
    _transition_busy = true

    local function restart_from_current()
        local s = PlayerCtx.get_snapshot()
        if not s then return end
        local l = s.cam and s.cam.RelativeLocation
        if not l then
            PlayerCtx.temporarily_disable()
            return
        end
        from.x, from.y, from.z = (l.X or 0), (l.Y or 0), (l.Z or 0)
        M._anim_start_ms = now_ms()
    end

    local function finish()
        _transition_busy = false
        M._cam_transition_token = nil
        M._active_target_position = nil
        if _queued_transition then
            local q = _queued_transition
            _queued_transition = nil
            M.set_camera_relative_location(q.pos, q.steps)
        end
    end

    local function tick()
        if PlayerCtx.camera_or_pc_invalid() then
            finish()
            return
        end

        local elapsed = now_ms() - (M._anim_start_ms or now_ms())
        local dur = math_max(M._active_duration_ms or duration_ms, 10)
		if not dur or dur <= 0 then dur = 10 end
        local t = math_min(math_max(elapsed / dur, 0), 1)

        local eased = {
            x = quadratic(t, from.x, to.x - from.x, 1.0),
            y = quadratic(t, from.y, to.y - from.y, 1.0),
            z = quadratic(t, from.z, to.z - from.z, 1.0),
        }

        local s = PlayerCtx.get_snapshot()
        if not s then finish(); return end
        local l = s.cam and s.cam.RelativeLocation
        if not l then
            PlayerCtx.temporarily_disable()
            finish()
            return
        end

        l.X = eased.x
        l.Y = eased.y
        l.Z = eased.z

        if t < 1.0 then
            M._cam_transition_token = ExecuteWithDelay(1, tick)
            return
        end

        local settle = math_max((M._active_duration_ms or duration_ms) + 20, 100)
        M._cam_transition_token = ExecuteWithDelay(settle, function()
            if PlayerCtx.camera_or_pc_invalid() then finish(); return end

            local s2 = PlayerCtx.get_snapshot()
            if not s2 then finish(); return end
            local l2 = s2.cam and s2.cam.RelativeLocation
            if not l2 then
                PlayerCtx.temporarily_disable()
                finish()
                return
            end

            local dx = math_abs((l2.X or 0) - to.x)
            local dy = math_abs((l2.Y or 0) - to.y)
            local dz = math_abs((l2.Z or 0) - to.z)

            if dx > 10 or dy > 10 or dz > 10 then
                if M._active_target_position
                   and math_abs(M._active_target_position.x - to.x) < 0.01
                   and math_abs(M._active_target_position.y - to.y) < 0.01
                   and math_abs(M._active_target_position.z - to.z) < 0.01 then
                    
                    log_warn(string.format("Camera position interpolation drifted beyond safe bounds (dx:%.1f, dy:%.1f, dz:%.1f); re-syncing from the current camera state.", dx, dy, dz), "camera_transition_drift")
                    
                    restart_from_current()
                    M._cam_transition_token = ExecuteWithDelay(1, tick)
                    return
                end
            end

            finish()
        end)
    end

    if PlayerCtx.camera_or_pc_invalid() then
        _transition_busy = false
        return
    end

    tick()
end

-- ==================== Camera collision ====================

function M.disable_camera_collision(flag)
    local s = PlayerCtx.get_snapshot()
    if not s then
        log_warn("Camera collision toggle skipped because the snapshot is unavailable.", "collision_toggle_missing")
        return
    end

    ExecuteInGameThread(function()
        local snap = PlayerCtx.get_snapshot()
        if not snap then
            log_warn("Camera collision toggle failed because the snapshot became invalid mid-thread.", "collision_toggle_midthread")
            return
        end
        if not obj_is_valid(snap.boom) then
            log_warn("Camera collision toggle skipped because the boom component is unavailable.", "collision_toggle_missing_boom")
            return
        end
        snap.boom.bDoCollisionTest = not flag
    end)
end

-- ==================== Init ====================

function M.init(cfg)
    if not cfg then
        log_error("Camera initialization aborted because no config was provided.", "camera_init_missing_cfg", true)
        return
    end

    if M._already_initialized then return end
    M._already_initialized = true
    M._cfg = cfg

    ExecuteInGameThread(function()
        M.set_fov_via_function(cfg.fovs.fov)
    end)

    ExecuteInGameThread(function()
        M.set_camera_relative_location(cfg.DefaultPosition)
    end)
end

-- ==================== FOV enforcement (non-lock-on) ====================

function M.enforce_fov(target_fov)
    if PlayerCtx.camera_or_pc_invalid() then
        log_warn("FOV enforcement skipped because the camera context is unavailable.", "enforce_fov_invalid_context", true)
        return
    end
    if M._fov_transition_token then return end

    local snap = PlayerCtx.get_snapshot()
    if not snap then
        log_warn("FOV enforcement skipped because the camera snapshot is unavailable.", "enforce_fov_no_snapshot", true)
        return
    end
    local cam = snap.cam

    -- Hard validation check before accessing properties
    if not obj_is_valid(cam) then
        log_warn("FOV enforcement skipped because the camera component is invalid.", "enforce_fov_invalid_cam", true)
        return
    end

    local actual = cam.ManualCameraFov
    if actual == nil then return end

    if math_abs(actual - target_fov) > 0.5 then
        cam.bManualCameraFovMode = true
        cam.ManualCameraFov = target_fov
    end
end

-- ==================== Lock-on enforcement ====================

local function enf_validate_refs()
    if obj_is_valid(_enf_cam)
       and obj_is_valid(_enf_boom)
       and obj_is_valid(_enf_pawn) then
        return true
    end

    local snap = PlayerCtx.get_snapshot()
    if not snap then
        _enf_cam  = nil
        _enf_boom = nil
        _enf_pawn = nil
        return false
    end

    _enf_cam  = snap.cam
    _enf_boom = snap.boom
    _enf_pawn = snap.pawn
    save_originals(snap)
    return true
end

function M.start_enforcement(pos, fov)
    if M._cam_transition_token then
        CancelDelay(M._cam_transition_token)
        M._cam_transition_token = nil
    end
    if M._fov_transition_token then
        CancelDelay(M._fov_transition_token)
        M._fov_transition_token = nil
    end
    
    -- Absolute clamp to prevent background settle timers from reporting finished states
    M._active_target_position = nil
    M._active_target_fov = nil
    _transition_busy = false
    _queued_transition = nil

    M._enforce_pos = pos and { x = pos.x or 0, y = pos.y or 0, z = pos.z or 0 } or nil
    M._enforce_fov = fov

    -- Read biases from config
    local cfg = require("config").get()
    if not cfg then
        log_error("Lock-on enforcement could not start because the config module returned no data.", "enforcement_start_missing_cfg", true)
        return
    end
    M._enforce_yaw_bias   = cfg.LockOnYawBias   or 0
    M._enforce_pitch_bias = cfg.LockOnPitchBias or 0

    clear_enforcement_caches()

    if _enforce_token then return end

    local function loop()
        if not M._enforce_pos and not M._enforce_fov then
            _enforce_token = nil
            clear_enforcement_caches()
            return
        end

        if not enf_validate_refs() then
            _enforce_miss_count = math_min(_enforce_miss_count + 1, 4)
            _enforce_token = ExecuteWithDelay(_ENFORCE_RETRY_MS * _enforce_miss_count, loop)
            return
        end

        _enforce_miss_count = 0

        -- ===== WRITE POSITION via TargetOffset (yaw-corrected) =====
        if M._enforce_pos then
            local snap_for_yaw = { pc = PlayerCtx._pc, boom = _enf_boom, cam = _enf_cam }
            local sin_y, cos_y = get_yaw_sincos(snap_for_yaw)

            local lateral = M._enforce_pos.x
            local depth   = M._enforce_pos.y
            local height  = M._enforce_pos.z

            local right_x = -sin_y
            local right_y =  cos_y
            local fwd_x   =  cos_y
            local fwd_y   =  sin_y

            local world_x = lateral * right_x + depth * fwd_x
            local world_y = lateral * right_y + depth * fwd_y

            if _enf_boom and obj_is_valid(_enf_boom) then
                local to = _enf_boom.TargetOffset
                if to then
                    to.X = world_x
                    to.Y = world_y
                    to.Z = height
                end
            end
        end

        -- ===== YAW + PITCH BIAS =====
        local has_yaw   = M._enforce_yaw_bias   and M._enforce_yaw_bias   ~= 0
        local has_pitch = M._enforce_pitch_bias and M._enforce_pitch_bias ~= 0
        if has_yaw or has_pitch then
            local rel_rot = obj_is_valid(_enf_cam) and _enf_cam.RelativeRotation or nil
            if rel_rot then
                if has_yaw then
                    rel_rot.Yaw = M._enforce_yaw_bias
                end
                if has_pitch then
                    -- Negative pitch = camera looks down = target shifts UP on screen
                    -- So we negate: positive config value = target UP
                    rel_rot.Pitch = -M._enforce_pitch_bias
                end
            end
        end

        -- ===== FOV =====
        if M._enforce_fov then
            _enf_cam.bManualCameraFovMode = true
            _enf_cam.ManualCameraFov = M._enforce_fov
        end

        _enforce_token = ExecuteWithDelay(_ENFORCE_TICK_MS, loop)
    end

    log_debug(string.format("Enforcement started with Pos=(%.1f,%.1f,%.1f) FOV=%s YawBias=%.1f PitchBias=%.1f",
        M._enforce_pos and M._enforce_pos.x or 0,
        M._enforce_pos and M._enforce_pos.y or 0,
        M._enforce_pos and M._enforce_pos.z or 0,
        tostring(M._enforce_fov or "—"),
        M._enforce_yaw_bias or 0,
        M._enforce_pitch_bias or 0), "enforce_start")

    loop()
end

function M.stop_enforcement()
    local was_active = (M._enforce_pos ~= nil or M._enforce_fov ~= nil or _enforce_token ~= nil)

    M._enforce_pos        = nil
    M._enforce_fov        = nil
    M._enforce_yaw_bias   = 0
    M._enforce_pitch_bias = 0

    if _enforce_token then
        CancelDelay(_enforce_token)
        _enforce_token = nil
    end

    clear_enforcement_caches()

    if was_active then
        -- Force the restoration helper to run inside the thread worker
        restore_originals()
        log_debug("Enforcement stopped and original camera state restoration was requested.", "enforce_stop")
    end
end

function M.update_enforcement_pos(pos)
    if not pos then return end
    if M._enforce_pos then
        M._enforce_pos.x = pos.x or 0
        M._enforce_pos.y = pos.y or 0
        M._enforce_pos.z = pos.z or 0
    else
        M._enforce_pos = { x = pos.x or 0, y = pos.y or 0, z = pos.z or 0 }
    end
end

function M.update_enforcement_fov(fov)
    if fov then M._enforce_fov = fov end
end

function M.update_enforcement_yaw_bias(bias)
    if bias then M._enforce_yaw_bias = bias end
end

function M.update_enforcement_pitch_bias(bias)
    if bias then M._enforce_pitch_bias = bias end
end

function M.is_enforcing()
    return _enforce_token ~= nil
end

return M