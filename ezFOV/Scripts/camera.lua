local Env = require("env").bind("Camera")
local PlayerCtx = require("playercontext")
local Logging = require("logging")
local Easing = require("easing")
local Originals = require("camera_originals")
local UEObject = require("ue_object")

local math_abs = math.abs
local math_sin = math.sin
local math_cos = math.cos
local math_rad = math.rad
local math_max = math.max
local math_min = math.min
local math_floor = math.floor
local os_clock = os.clock

local quadratic = Easing.quadratic
local now_ms = Easing.now_ms
local obj_is_valid = UEObject.is_valid

local M = {
    _cfg = nil,
    _already_initialized = false,

    _fov_transition_token = nil,
    _active_target_fov = nil,

    _cam_transition_token = nil,
    _active_target_position = nil,
    _active_duration_ms = nil,
    _anim_start_ms = nil,

    _lockon_exit_token = nil,
    _lockon_exit_active = false,
    _lockon_exit_start_ms = nil,
    _lockon_exit_duration_ms = nil,
    _lockon_exit_from_pos = nil,
    _lockon_exit_to_pos = nil,
    _lockon_exit_from_fov = nil,
    _lockon_exit_to_fov = nil,
    _lockon_was_active = false,

    _enforce_pos = nil,
    _enforce_fov = nil,
    _enforce_yaw_bias = 0,
    _enforce_pitch_bias = 0,
}

local _transition_busy = false
local _queued_transition = nil
local _enforce_token = nil

local _enf_cam = nil
local _enf_boom = nil
local _enf_pawn = nil

local _yaw_fn = nil
local _yaw_tried = false
local _last_yaw = nil
local _last_sin = 0
local _last_cos = 1
local _yaw_epsilon = 0.5

local _ENFORCE_TICK_MS = 8
local _ENFORCE_RETRY_MS = 50
local _enforce_miss_count = 0

local _collision_warn_last = {
    missing_snapshot = 0,
    midthread_snapshot = 0,
    missing_boom = 0,
}
local _lockon_diag_last = {
    branch = 0,
    collapsed = 0,
    success = 0,
    invalid_boom = 0,
    missing_target_offset = 0,
    missing_refs = 0,
}
local _COLLISION_WARN_INTERVAL_SEC = 5.0
local _LOCKON_DIAG_INTERVAL_SEC = 0.75

-- Component-scoped logger (see Logging.for_component).
local log = Logging.for_component("Camera")

local function safe_write(fn, context, once_key)
    local ok, err = pcall(fn)
    if not ok then
        local ctx = context or "property_write"
        log.warn(
            ctx .. " failed (object likely mid-destruction): " .. tostring(err),
            once_key or ("safe_write_fail_" .. ctx),
            true
        )
    end
    return ok
end

local function collision_warn_throttled(slot, message)
    local now = os_clock()
    local last = _collision_warn_last[slot] or 0
    if (now - last) < _COLLISION_WARN_INTERVAL_SEC then
        return
    end
    _collision_warn_last[slot] = now
    log.warn(message)
end

local function lockon_diag_debug(slot, message)
    local now = os_clock()
    local last = _lockon_diag_last[slot] or 0
    if (now - last) < _LOCKON_DIAG_INTERVAL_SEC then
        return
    end
    _lockon_diag_last[slot] = now
    log.debug(message, "lockon_diag_" .. tostring(slot), true)
end

local function lockon_diag_warn(slot, message)
    local now = os_clock()
    local last = _lockon_diag_last[slot] or 0
    if (now - last) < _LOCKON_DIAG_INTERVAL_SEC then
        return
    end
    _lockon_diag_last[slot] = now
    log.warn(message)
end

local function lockon_diag_ref_loss(slot, message, miss_count)
    if (miss_count or 0) >= 3 then
        lockon_diag_warn(slot, message)
        return
    end
    lockon_diag_debug(slot, message)
end

-- ==================== Yaw reading ====================

local function get_camera_yaw_raw(snap)
    if _yaw_fn then
        local ok, val = pcall(_yaw_fn, snap)
        if ok and val then
            return tonumber(val) or 0
        end
        _yaw_fn = nil
        _yaw_tried = false
    end

    if _yaw_tried then
        return 0
    end
    _yaw_tried = true

    local ok1, rot1 = pcall(function()
        return snap.pc:GetControlRotation()
    end)
    if ok1 and rot1 and rot1.Yaw ~= nil then
        _yaw_fn = function(s)
            return s.pc:GetControlRotation().Yaw
        end
        log.debug("Yaw source resolved via GetControlRotation()", "yaw_source_rotation", true)
        return tonumber(rot1.Yaw) or 0
    end

    local ok2, rot2 = pcall(function()
        return snap.boom:K2_GetComponentRotation()
    end)
    if ok2 and rot2 and rot2.Yaw ~= nil then
        _yaw_fn = function(s)
            return s.boom:K2_GetComponentRotation().Yaw
        end
        log.debug("Yaw source resolved via boom K2_GetComponentRotation()", "yaw_source_boom", true)
        return tonumber(rot2.Yaw) or 0
    end

    local ok3, rot3 = pcall(function()
        return snap.cam:K2_GetComponentRotation()
    end)
    if ok3 and rot3 and rot3.Yaw ~= nil then
        _yaw_fn = function(s)
            return s.cam:K2_GetComponentRotation().Yaw
        end
        log.debug("Yaw source resolved via cam K2_GetComponentRotation()", "yaw_source_cam", true)
        return tonumber(rot3.Yaw) or 0
    end

    log.error(
        "Unable to locate a valid camera yaw source across the known engine methods; yaw-based bias and lock-on positioning may be unstable."
    )
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
    _enf_cam = nil
    _enf_boom = nil
    _enf_pawn = nil
    _yaw_fn = nil
    _yaw_tried = false
    _last_yaw = nil
    _enforce_miss_count = 0
end

local function cancel_lockon_exit_blend()
    if M._lockon_exit_token then
        Env.CancelDelay(M._lockon_exit_token)
        M._lockon_exit_token = nil
    end
    M._lockon_exit_active = false
    M._lockon_exit_start_ms = nil
    M._lockon_exit_duration_ms = nil
    M._lockon_exit_from_pos = nil
    M._lockon_exit_to_pos = nil
    M._lockon_exit_from_fov = nil
    M._lockon_exit_to_fov = nil
end

PlayerCtx.on_disable(function()
    if M._fov_transition_token then
        Env.CancelDelay(M._fov_transition_token)
        M._fov_transition_token = nil
    end
    M._active_target_fov = nil

    if M._cam_transition_token then
        Env.CancelDelay(M._cam_transition_token)
        M._cam_transition_token = nil
    end
    M._active_target_position = nil
    _transition_busy = false
    _queued_transition = nil

    cancel_lockon_exit_blend()
    clear_enforcement_caches()
end)

-- ==================== Transition check ====================

function M.is_transitioning()
    return M._fov_transition_token ~= nil or M._cam_transition_token ~= nil or _transition_busy or M._lockon_exit_active
end

-- ==================== FOV transition ====================

function M.set_fov_via_function(target_fov, override_steps)
    if PlayerCtx.camera_or_pc_invalid() then
        log.warn(
            "FOV transition aborted because the player camera context is unavailable.",
            "fov_transition_invalid_context"
        )
        return
    end

    local snap = PlayerCtx.get_snapshot()
    if not snap then
        log.warn(
            "FOV transition aborted because the camera snapshot is unavailable.",
            "fov_transition_invalid_snapshot"
        )
        return
    end

    local cam = snap.cam
    if not obj_is_valid(cam) then
        log.warn("FOV transition aborted because the camera component is invalid.", "fov_transition_invalid_cam")
        return
    end

    if M._fov_transition_token then
        Env.CancelDelay(M._fov_transition_token)
        M._fov_transition_token = nil
    end
    M._active_target_fov = target_fov

    local cfg_steps = (M._cfg and M._cfg.FOVTransitionSteps) or 20
    local steps = override_steps or math_max(cfg_steps, 10)
    local step = 0
    ---@type any
    local cam_any = cam
    local current_fov = cam_any.ManualCameraFov or 75

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
            local write_ok = safe_write(function()
                cam.bManualCameraFovMode = true
                cam.ManualCameraFov = eased
            end, "fov_transition_write")
            if not write_ok then
                M._fov_transition_token = nil
                M._active_target_fov = nil
                return
            end
            step = step + 1
            M._fov_transition_token = Env.run_after_delay(1, "fov_transition", tick)
        else
            M._fov_transition_token = nil
            M._active_target_fov = nil
        end
    end

    Env.run_now("fov_transition_start", tick)
end

-- ==================== Camera position transition ====================

function M.set_camera_relative_location(target_position, override_steps)
    if PlayerCtx.camera_or_pc_invalid() then
        log.warn(
            "Camera position transition aborted because the camera context is unavailable.",
            "camera_rel_loc_invalid_context",
            true
        )
        return
    end

    local snap = PlayerCtx.get_snapshot()
    if not snap then
        log.warn(
            "Camera position transition aborted because the camera snapshot is unavailable.",
            "camera_rel_loc_no_snapshot",
            true
        )
        return
    end

    local cam = snap.cam
    if not obj_is_valid(cam) then
        log.warn(
            "Camera position transition aborted because the camera component is invalid.",
            "camera_rel_loc_invalid_cam",
            true
        )
        return
    end

    local loc = cam and cam.RelativeLocation
    if not loc then
        log.warn("Camera position transition aborted because RelativeLocation is unavailable.", "camera_loc_missing")
        PlayerCtx.temporarily_disable()
        return
    end

    local from = { x = loc.X or 0, y = loc.Y or 0, z = loc.Z or 0 }
    local to = {
        x = target_position.x or target_position.X or 0,
        y = target_position.y or target_position.Y or 0,
        z = target_position.z or target_position.Z or 0,
    }

    if
        M._active_target_position
        and math_abs(M._active_target_position.x - to.x) < 0.01
        and math_abs(M._active_target_position.y - to.y) < 0.01
        and math_abs(M._active_target_position.z - to.z) < 0.01
    then
        return
    end

    local cfg_steps = (M._cfg and M._cfg.FOVTransitionSteps) or 100
    local steps_units = override_steps or math_max(cfg_steps, 10)
    local unit = (M._cfg and M._cfg.TransitionTimeUnit) or 3
    local duration_ms = math_max(steps_units * unit, 10)

    if _transition_busy then
        if
            M._active_target_position
            and math_abs(M._active_target_position.x - to.x) < 0.01
            and math_abs(M._active_target_position.y - to.y) < 0.01
            and math_abs(M._active_target_position.z - to.z) < 0.01
        then
            M._active_duration_ms = duration_ms
            return
        end
        _queued_transition = { pos = target_position, steps = override_steps }
        return
    end

    if M._cam_transition_token then
        Env.CancelDelay(M._cam_transition_token)
        M._cam_transition_token = nil
    end

    M._active_target_position = { x = to.x, y = to.y, z = to.z }
    M._active_duration_ms = duration_ms
    M._anim_start_ms = now_ms()
    _transition_busy = true

    local function restart_from_current()
        local s = PlayerCtx.get_snapshot()
        if not s then
            return
        end
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
        if not dur or dur <= 0 then
            dur = 10
        end
        local t = math_min(math_max(elapsed / dur, 0), 1)

        local eased = {
            x = quadratic(t, from.x, to.x - from.x, 1.0),
            y = quadratic(t, from.y, to.y - from.y, 1.0),
            z = quadratic(t, from.z, to.z - from.z, 1.0),
        }

        local s = PlayerCtx.get_snapshot()
        if not s then
            finish()
            return
        end
        local l = s.cam and s.cam.RelativeLocation
        if not l then
            PlayerCtx.temporarily_disable()
            finish()
            return
        end

        local write_ok = safe_write(function()
            l.X = eased.x
            l.Y = eased.y
            l.Z = eased.z
        end, "camera_transition_write")
        if not write_ok then
            finish()
            return
        end

        if t < 1.0 then
            M._cam_transition_token = Env.run_after_delay(1, "camera_transition", tick)
            return
        end

        local settle = math_max((M._active_duration_ms or duration_ms) + 20, 100)
        M._cam_transition_token = Env.run_after_delay(settle, "camera_transition_settle", function()
            if PlayerCtx.camera_or_pc_invalid() then
                finish()
                return
            end

            local s2 = PlayerCtx.get_snapshot()
            if not s2 then
                finish()
                return
            end
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
                if
                    M._active_target_position
                    and math_abs(M._active_target_position.x - to.x) < 0.01
                    and math_abs(M._active_target_position.y - to.y) < 0.01
                    and math_abs(M._active_target_position.z - to.z) < 0.01
                then
                    log.warn(
                        string.format(
                            "Camera position interpolation drifted beyond safe bounds (dx:%.1f, dy:%.1f, dz:%.1f); re-syncing from the current camera state.",
                            dx,
                            dy,
                            dz
                        ),
                        "camera_transition_drift"
                    )

                    restart_from_current()
                    M._cam_transition_token = Env.run_after_delay(1, "camera_transition_recover", tick)
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

    Env.run_now("camera_transition_start", tick)
end

-- ==================== Camera collision ====================

function M.disable_camera_collision(flag)
    local s = PlayerCtx.get_snapshot()
    if not s then
        collision_warn_throttled(
            "missing_snapshot",
            "Camera collision toggle skipped because the snapshot is unavailable."
        )
        return
    end

    Env.run_on_game_thread("disable_camera_collision", function()
        local snap = PlayerCtx.get_snapshot()
        if not snap then
            collision_warn_throttled(
                "midthread_snapshot",
                "Camera collision toggle failed because the snapshot became invalid mid-thread."
            )
            return
        end
        if not obj_is_valid(snap.boom) then
            collision_warn_throttled(
                "missing_boom",
                "Camera collision toggle skipped because the boom component is unavailable."
            )
            return
        end
        snap.boom.bDoCollisionTest = not flag
    end)
end

-- ==================== Init ====================

function M.init(cfg)
    if not cfg then
        log.error("Camera initialization aborted because no config was provided.")
        return
    end

    -- Always refresh the live config reference so F8 reload updates transition settings.
    M._cfg = cfg

    if M._already_initialized then
        return
    end
    M._already_initialized = true

    Env.run_on_game_thread("camera_init_set_fov", function()
        M.set_fov_via_function(cfg.fovs.fov)
    end)

    Env.run_on_game_thread("camera_init_set_position", function()
        M.set_camera_relative_location(cfg.DefaultPosition)
    end)
end

-- ==================== FOV enforcement (non-lock-on) ====================

function M.enforce_fov(target_fov)
    if PlayerCtx.camera_or_pc_invalid() then
        log.warn(
            "FOV enforcement skipped because the camera context is unavailable.",
            "enforce_fov_invalid_context",
            true
        )
        return
    end
    if M._fov_transition_token then
        return
    end

    local snap = PlayerCtx.get_snapshot()
    if not snap then
        log.warn("FOV enforcement skipped because the camera snapshot is unavailable.", "enforce_fov_no_snapshot", true)
        return
    end
    local cam = snap.cam

    -- Hard validation check before accessing properties
    if not obj_is_valid(cam) then
        log.warn("FOV enforcement skipped because the camera component is invalid.", "enforce_fov_invalid_cam", true)
        return
    end

    ---@type any
    local cam_any = cam
    local actual = cam_any.ManualCameraFov
    if actual == nil then
        return
    end

    if math_abs(actual - target_fov) > 0.5 then
        safe_write(function()
            cam.bManualCameraFovMode = true
            cam.ManualCameraFov = target_fov
        end, "enforce_fov_write")
    end
end

-- ==================== Lock-on enforcement ====================

local function enf_validate_refs()
    if obj_is_valid(_enf_cam) and obj_is_valid(_enf_boom) and obj_is_valid(_enf_pawn) then
        return true
    end

    local snap = PlayerCtx.get_snapshot()
    if not snap then
        _enf_cam = nil
        _enf_boom = nil
        _enf_pawn = nil
        lockon_diag_ref_loss(
            "missing_refs",
            "Lock-on enforcement could not refresh refs because PlayerCtx.get_snapshot() returned nil.",
            _enforce_miss_count + 1
        )
        return false
    end

    _enf_cam = snap.cam
    _enf_pawn = snap.pawn

    local boom = snap.boom
    if not obj_is_valid(boom) and PlayerCtx.get_camera_boom then
        boom = PlayerCtx.get_camera_boom()
    end

    if not obj_is_valid(_enf_cam) or not obj_is_valid(_enf_pawn) or not obj_is_valid(boom) then
        _enf_boom = nil
        lockon_diag_ref_loss(
            "missing_refs",
            string.format(
                "Lock-on enforcement refs incomplete after refresh: cam=%s pawn=%s boom=%s",
                tostring(obj_is_valid(_enf_cam)),
                tostring(obj_is_valid(_enf_pawn)),
                tostring(obj_is_valid(boom))
            ),
            _enforce_miss_count + 1
        )
        return false
    end

    _enf_boom = boom
    Originals.save(snap)
    return true
end

local function stop_enforcement_loop()
    local was_active = (M._enforce_pos ~= nil or M._enforce_fov ~= nil or _enforce_token ~= nil)

    M._enforce_pos = nil
    M._enforce_fov = nil
    M._enforce_yaw_bias = 0
    M._enforce_pitch_bias = 0
    M._lockon_was_active = false

    if _enforce_token then
        Env.CancelDelay(_enforce_token)
        _enforce_token = nil
    end

    clear_enforcement_caches()
    return was_active
end

function M.cancel_lockon_exit_blend()
    cancel_lockon_exit_blend()
end

function M.begin_lockon_exit_blend(target_position, target_fov, _override_steps, duration_override)
    if PlayerCtx.camera_or_pc_invalid() then
        log.warn(
            "Lock-on exit blend skipped because the camera context is unavailable.",
            "lockon_exit_invalid_context",
            true
        )
        return false
    end

    local cfg = M._cfg or require("config").get()
    local blend_seconds = (type(duration_override) == "number" and duration_override > 0) and duration_override
        or ((cfg and cfg.LockOnExitBlendTime) or 0.16)
    local duration_ms = math_max(math_floor(blend_seconds * 1000), 20)

    local snap = PlayerCtx.get_snapshot()
    if not snap then
        log.warn(
            "Lock-on exit blend skipped because the camera snapshot is unavailable.",
            "lockon_exit_no_snapshot",
            true
        )
        return false
    end

    local cam = snap.cam
    if not obj_is_valid(cam) then
        log.warn("Lock-on exit blend skipped because the camera component is invalid.", "lockon_exit_invalid_cam", true)
        return false
    end

    local from_pos = nil
    ---@type any
    local cam_any = cam
    local loc = cam_any.RelativeLocation
    if loc then
        from_pos = { x = loc.X or 0, y = loc.Y or 0, z = loc.Z or 0 }
    end

    local from_fov = cam_any.ManualCameraFov
    if from_fov == nil then
        from_fov = (cfg and cfg.fovs and cfg.fovs.fov) or 75
    end

    local to_pos = nil
    if target_position then
        to_pos = {
            x = target_position.x or target_position.X or 0,
            y = target_position.y or target_position.Y or 0,
            z = target_position.z or target_position.Z or 0,
        }
    end

    local to_fov = target_fov
    if to_fov == nil then
        to_fov = (cfg and cfg.fovs and cfg.fovs.fov) or from_fov
    end

    if to_fov == nil and (not to_pos or (to_pos.x == 0 and to_pos.y == 0 and to_pos.z == 0)) then
        log.warn(
            "Lock-on exit blend skipped because there was no valid target FOV or position.",
            "lockon_exit_missing_target",
            true
        )
        return false
    end

    if M._fov_transition_token then
        Env.CancelDelay(M._fov_transition_token)
        M._fov_transition_token = nil
    end
    if M._cam_transition_token then
        Env.CancelDelay(M._cam_transition_token)
        M._cam_transition_token = nil
    end
    M._active_target_fov = nil
    M._active_target_position = nil
    _transition_busy = false
    _queued_transition = nil

    cancel_lockon_exit_blend()
    stop_enforcement_loop()

    M._lockon_exit_active = true
    M._lockon_exit_start_ms = now_ms()
    M._lockon_exit_duration_ms = duration_ms
    M._lockon_exit_from_pos = from_pos
    M._lockon_exit_to_pos = to_pos
    M._lockon_exit_from_fov = from_fov
    M._lockon_exit_to_fov = to_fov

    local function tick()
        if PlayerCtx.camera_or_pc_invalid() then
            cancel_lockon_exit_blend()
            return
        end

        local snap_now = PlayerCtx.get_snapshot()
        if not snap_now then
            cancel_lockon_exit_blend()
            return
        end

        local cam_now = snap_now.cam
        if not obj_is_valid(cam_now) then
            cancel_lockon_exit_blend()
            return
        end

        local elapsed = now_ms() - (M._lockon_exit_start_ms or now_ms())
        local dur = math_max(M._lockon_exit_duration_ms or duration_ms, 20)
        local t = math_min(math_max(elapsed / dur, 0), 1)
        local eased = quadratic(t, 0, 1, 1)

        if M._lockon_exit_from_pos and M._lockon_exit_to_pos then
            ---@type any
            local cam_now_any = cam_now
            local loc_now = cam_now_any.RelativeLocation
            if loc_now then
                local write_ok = safe_write(function()
                    loc_now.X = (M._lockon_exit_from_pos.x or 0)
                        + ((M._lockon_exit_to_pos.x or 0) - (M._lockon_exit_from_pos.x or 0)) * eased
                    loc_now.Y = (M._lockon_exit_from_pos.y or 0)
                        + ((M._lockon_exit_to_pos.y or 0) - (M._lockon_exit_from_pos.y or 0)) * eased
                    loc_now.Z = (M._lockon_exit_from_pos.z or 0)
                        + ((M._lockon_exit_to_pos.z or 0) - (M._lockon_exit_from_pos.z or 0)) * eased
                end, "lockon_exit_write_pos")
                if not write_ok then
                    cancel_lockon_exit_blend()
                    return
                end
            end
        end

        if M._lockon_exit_from_fov ~= nil and M._lockon_exit_to_fov ~= nil then
            local fov_ok = safe_write(function()
                cam_now.bManualCameraFovMode = true
                cam_now.ManualCameraFov = (M._lockon_exit_from_fov or 75)
                    + (M._lockon_exit_to_fov - (M._lockon_exit_from_fov or 75)) * eased
            end, "lockon_exit_write_fov")
            if not fov_ok then
                cancel_lockon_exit_blend()
                return
            end
        end

        if t < 1.0 then
            M._lockon_exit_token = Env.run_after_delay(8, "lockon_exit_blend", tick)
            return
        end

        if M._lockon_exit_from_pos and M._lockon_exit_to_pos then
            ---@type any
            local cam_now_any = cam_now
            local loc_now = cam_now_any.RelativeLocation
            if loc_now then
                local final_pos_ok = safe_write(function()
                    loc_now.X = M._lockon_exit_to_pos.x or 0
                    loc_now.Y = M._lockon_exit_to_pos.y or 0
                    loc_now.Z = M._lockon_exit_to_pos.z or 0
                end, "lockon_exit_finalize_pos")
                if not final_pos_ok then
                    cancel_lockon_exit_blend()
                    return
                end
            end
        end

        if M._lockon_exit_from_fov ~= nil and M._lockon_exit_to_fov ~= nil then
            local final_fov_ok = safe_write(function()
                cam_now.bManualCameraFovMode = true
                cam_now.ManualCameraFov = M._lockon_exit_to_fov
            end, "lockon_exit_finalize_fov")
            if not final_fov_ok then
                cancel_lockon_exit_blend()
                return
            end
        end

        cancel_lockon_exit_blend()
    end

    Env.run_now("lockon_exit_start", tick)
    return true
end

function M.start_enforcement(pos, fov)
    if M._cam_transition_token then
        Env.CancelDelay(M._cam_transition_token)
        M._cam_transition_token = nil
    end
    if M._fov_transition_token then
        Env.CancelDelay(M._fov_transition_token)
        M._fov_transition_token = nil
    end

    -- Absolute clamp to prevent background settle timers from reporting finished states
    M._active_target_position = nil
    M._active_target_fov = nil
    _transition_busy = false
    _queued_transition = nil

    M._enforce_pos = pos and { x = pos.x or 0, y = pos.y or 0, z = pos.z or 0 } or nil
    M._enforce_fov = fov
    M._lockon_was_active = true

    M.cancel_lockon_exit_blend()

    -- Read biases from config
    local cfg = require("config").get()
    if not cfg then
        log.error("Lock-on enforcement could not start because the config module returned no data.")
        return
    end
    M._enforce_yaw_bias = cfg.LockOnYawBias or 0
    M._enforce_pitch_bias = cfg.LockOnPitchBias or 0

    clear_enforcement_caches()

    if _enforce_token then
        return
    end

    local function loop()
        local function retry_after_ref_loss(slot, message)
            if message then
                lockon_diag_ref_loss(slot, message, _enforce_miss_count + 1)
            end
            clear_enforcement_caches()
            _enforce_miss_count = math_min(_enforce_miss_count + 1, 4)
            _enforce_token = Env.run_after_delay(_ENFORCE_RETRY_MS * _enforce_miss_count, "lockon_enforce_retry", loop)
        end

        if not M._enforce_pos and not M._enforce_fov then
            _enforce_token = nil
            clear_enforcement_caches()
            return
        end

        if not enf_validate_refs() then
            _enforce_miss_count = math_min(_enforce_miss_count + 1, 4)
            _enforce_token = Env.run_after_delay(_ENFORCE_RETRY_MS * _enforce_miss_count, "lockon_enforce_retry", loop)
            return
        end

        _enforce_miss_count = 0

        -- ===== WRITE POSITION via TargetOffset (yaw-corrected) =====
        local enforce_pos = M._enforce_pos
        if enforce_pos then
            local snap_for_yaw = { pc = PlayerCtx._pc, boom = _enf_boom, cam = _enf_cam }
            local sin_y, cos_y = get_yaw_sincos(snap_for_yaw)

            local lateral = enforce_pos.x or 0
            local depth = enforce_pos.y or 0
            local height = enforce_pos.z or 0

            local right_x = -sin_y
            local right_y = cos_y
            local fwd_x = cos_y
            local fwd_y = sin_y

            local world_x = lateral * right_x + depth * fwd_x
            local world_y = lateral * right_y + depth * fwd_y

            lockon_diag_debug(
                "branch",
                string.format(
                    "Lock-on position branch reached: enforce=(%.2f, %.2f, %.2f) sin=%.4f cos=%.4f world=(%.2f, %.2f, %.2f)",
                    lateral,
                    depth,
                    height,
                    sin_y or 0,
                    cos_y or 0,
                    world_x,
                    world_y,
                    height
                )
            )

            if math_abs(lateral) > 0.01 or math_abs(depth) > 0.01 then
                if math_abs(world_x) <= 0.01 and math_abs(world_y) <= 0.01 then
                    lockon_diag_warn(
                        "collapsed",
                        string.format(
                            "Lock-on position math collapsed to near-zero world offset: enforce=(%.2f, %.2f, %.2f) sin=%.4f cos=%.4f world=(%.2f, %.2f, %.2f)",
                            lateral,
                            depth,
                            height,
                            sin_y or 0,
                            cos_y or 0,
                            world_x,
                            world_y,
                            height
                        )
                    )
                end
            end

            local boom_ref = _enf_boom
            if boom_ref and obj_is_valid(boom_ref) then
                local to = boom_ref.TargetOffset
                if to then
                    lockon_diag_debug(
                        "success",
                        string.format(
                            "Lock-on position attempting TargetOffset write: target=(%.2f, %.2f, %.2f)",
                            world_x,
                            world_y,
                            height
                        )
                    )
                    local pos_ok = safe_write(function()
                        to.X = world_x
                        to.Y = world_y
                        to.Z = height
                    end, "lockon_enforce_write_pos")
                    if not pos_ok then
                        _enforce_token = nil
                        clear_enforcement_caches()
                        return
                    end
                else
                    retry_after_ref_loss(
                        "missing_target_offset",
                        "Lock-on enforcement could not write position because boom.TargetOffset is unavailable."
                    )
                    return
                end
            else
                retry_after_ref_loss(
                    "invalid_boom",
                    "Lock-on enforcement could not write position because the boom reference is invalid."
                )
                return
            end
        end

        -- ===== YAW + PITCH BIAS =====
        local has_yaw = M._enforce_yaw_bias and M._enforce_yaw_bias ~= 0
        local has_pitch = M._enforce_pitch_bias and M._enforce_pitch_bias ~= 0
        if has_yaw or has_pitch then
            ---@type any
            local enf_cam_any = _enf_cam
            if not obj_is_valid(enf_cam_any) then
                retry_after_ref_loss(
                    "missing_refs",
                    "Lock-on enforcement could not write rotation because the camera reference is invalid."
                )
                return
            end
            local rel_rot = obj_is_valid(enf_cam_any) and enf_cam_any.RelativeRotation or nil
            if rel_rot then
                local rot_ok = safe_write(function()
                    if has_yaw then
                        rel_rot.Yaw = M._enforce_yaw_bias
                    end
                    if has_pitch then
                        -- Negative pitch = camera looks down = target shifts UP on screen
                        -- So we negate: positive config value = target UP
                        rel_rot.Pitch = -M._enforce_pitch_bias
                    end
                end, "lockon_enforce_write_rot")
                if not rot_ok then
                    _enforce_token = nil
                    clear_enforcement_caches()
                    return
                end
            end
        end

        -- ===== FOV =====
        if M._enforce_fov then
            ---@type any
            local enf_cam_any = _enf_cam
            if not obj_is_valid(enf_cam_any) then
                retry_after_ref_loss(
                    "missing_refs",
                    "Lock-on enforcement could not write FOV because the camera reference is invalid."
                )
                return
            end
            local fov_ok = safe_write(function()
                enf_cam_any.bManualCameraFovMode = true
                enf_cam_any.ManualCameraFov = M._enforce_fov
            end, "lockon_enforce_write_fov")
            if not fov_ok then
                _enforce_token = nil
                clear_enforcement_caches()
                return
            end
        end

        _enforce_token = Env.run_after_delay(_ENFORCE_TICK_MS, "lockon_enforce_tick", loop)
    end

    Env.run_now("lockon_enforce_start", loop)
end

function M.stop_enforcement()
    local was_active = stop_enforcement_loop()

    if was_active then
        -- Force the restoration helper to run inside the thread worker
        Originals.restore()
        log.debug("Enforcement stopped and original camera state restoration was requested.", "enforce_stop")
    end
end

function M.update_enforcement_pos(pos)
    if not pos then
        return
    end
    if M._enforce_pos then
        M._enforce_pos.x = pos.x or 0
        M._enforce_pos.y = pos.y or 0
        M._enforce_pos.z = pos.z or 0
    else
        M._enforce_pos = { x = pos.x or 0, y = pos.y or 0, z = pos.z or 0 }
    end
end

function M.update_enforcement_fov(fov)
    if fov then
        M._enforce_fov = fov
    end
end

function M.update_enforcement_yaw_bias(bias)
    if bias then
        M._enforce_yaw_bias = bias
    end
end

function M.update_enforcement_pitch_bias(bias)
    if bias then
        M._enforce_pitch_bias = bias
    end
end

function M.is_enforcing()
    return _enforce_token ~= nil
end

return M
