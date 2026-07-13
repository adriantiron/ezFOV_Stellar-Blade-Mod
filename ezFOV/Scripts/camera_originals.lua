-- Non-destructive save / restore of the camera's original TargetOffset (boom) and
-- RelativeRotation (cam), so the mod can hand control back to the game cleanly.
--
-- Extracted from camera.lua as a self-contained concern: it owns its own snapshot state
-- and is invoked only at enforcement start (save) and stop (restore), never on the
-- per-tick hot path.
local Env = require("env").bind("Camera")
local PlayerCtx = require("playercontext")
local Logging = require("logging")
local UEObject = require("ue_object")

local log = Logging.for_component("Camera")

local Originals = {}

local _originals_saved = false
local _saved_originals = {}

local obj_is_valid = UEObject.is_valid

function Originals.save(snap)
    if _originals_saved then
        return
    end

    if not snap then
        log.error("Cannot save camera originals because the snapshot is unavailable.")
        return
    end

    _originals_saved = true
    _saved_originals = {}

    if obj_is_valid(snap.boom) then
        local to = snap.boom.TargetOffset
        if to then
            _saved_originals.target = { X = to.X, Y = to.Y, Z = to.Z }
        end
    end

    if obj_is_valid(snap.cam) then
        local rr = snap.cam.RelativeRotation
        if rr then
            _saved_originals.rel_rot = { Pitch = rr.Pitch, Yaw = rr.Yaw, Roll = rr.Roll }
        end
    end
end

function Originals.restore()
    if not _originals_saved then
        return
    end

    local snap = PlayerCtx.get_snapshot()
    if snap then
        if snap.boom and _saved_originals.target then
            local to = snap.boom.TargetOffset
            if to then
                local pos_restore_ok = Env.run_now("restore_originals_target", function()
                    to.X = _saved_originals.target.X
                    to.Y = _saved_originals.target.Y
                    to.Z = _saved_originals.target.Z
                end)
                if not pos_restore_ok then
                    _originals_saved = false
                    _saved_originals = {}
                    return
                end
            end
        end

        if snap.cam and _saved_originals.rel_rot then
            local rr = snap.cam.RelativeRotation
            if rr then
                local rot_restore_ok = Env.run_now("restore_originals_rotation", function()
                    rr.Pitch = _saved_originals.rel_rot.Pitch
                    rr.Yaw = _saved_originals.rel_rot.Yaw
                    rr.Roll = _saved_originals.rel_rot.Roll
                end)
                if not rot_restore_ok then
                    _originals_saved = false
                    _saved_originals = {}
                    return
                end
            end
        end

        _originals_saved = false
        _saved_originals = {}
    end
end

return Originals
