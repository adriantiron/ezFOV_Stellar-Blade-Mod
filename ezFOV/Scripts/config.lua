local Logging = require("logging")
local Env = require("env").bind("Config")

local format = string.format

local M = {}

local DEFAULTS = {
    path = "UE4SS/Mods/ezFOV/ezFOV.cfg",

    fovs = {
        default = 75,
        fov = 90,
        combat = 90,
        tps = 70,
        idle = 90,
        walk = 90,
        sprint = 90,
        lockon = 90,
    },

    DefaultPosition = { x = 0, y = 0, z = 0 },
    CombatPosition = { x = 0, y = 0, z = 0 },
    LockOnPosition = { x = 0, y = 0, z = 0 },
    IdlePosition = { x = 200, y = 0, z = 0 },
    WalkPosition = { x = 200, y = 0, z = 0 },
    SprintPosition = { x = 0, y = 0, z = 0 },

    FOVTransitionSteps = 60,
    KeyFOVTransitionSteps = 20,
    LockOnExitBlendTime = 0.16,

    DisableCameraCollision = false,
    EnableIdleCamera = true,
    EnableWalkingCamera = true,
    EnableSprintingCamera = true,
    EnableLockOnCamera = true,

    LockOnYawBias = 0,
    LockOnPitchBias = 0,
}

local function log_error(message, once_key)
    Logging.log_error("Config", message, once_key)
end

-- Local helper logging functions to prefix messages with the module name and enforce level
local function log_warn(message, once_key, cache)
    Logging.log_warn("Config", message, once_key, cache)
end

local function log_debug(message, once_key, cache)
    Logging.log_debug("Config", message, once_key, cache)
end
-- ========================================================================================

local function sanitize_number(n)
    return type(n) == "number" and n or tonumber(n) or 0
end

local function sanitize_boolean(v)
    if type(v) == "boolean" then
        return v
    end
    if type(v) == "string" then
        -- Trim any accidental leading/trailing whitespace and lowercase it
        local clean = v:match("^%s*(.-)%s*$"):lower()
        if clean == "true" or clean == "1" then
            return true
        end
        if clean == "false" or clean == "0" then
            return false
        end
    end
    return nil -- Return nil if it's not a clear boolean line, letting defaults handle it
end

local function deep_copy_defaults()
    return {
        path = DEFAULTS.path,
        fovs = {
            default = DEFAULTS.fovs.default,
            fov = DEFAULTS.fovs.fov,
            combat = DEFAULTS.fovs.combat,
            tps = DEFAULTS.fovs.tps,
            idle = DEFAULTS.fovs.idle,
            walk = DEFAULTS.fovs.walk,
            sprint = DEFAULTS.fovs.sprint,
            lockon = DEFAULTS.fovs.lockon,
        },
        DefaultPosition = {
            x = DEFAULTS.DefaultPosition.x,
            y = DEFAULTS.DefaultPosition.y,
            z = DEFAULTS.DefaultPosition.z,
        },
        CombatPosition = {
            x = DEFAULTS.CombatPosition.x,
            y = DEFAULTS.CombatPosition.y,
            z = DEFAULTS.CombatPosition.z,
        },
        LockOnPosition = {
            x = DEFAULTS.LockOnPosition.x,
            y = DEFAULTS.LockOnPosition.y,
            z = DEFAULTS.LockOnPosition.z,
        },
        IdlePosition = { x = DEFAULTS.IdlePosition.x, y = DEFAULTS.IdlePosition.y, z = DEFAULTS.IdlePosition.z },
        WalkPosition = { x = DEFAULTS.WalkPosition.x, y = DEFAULTS.WalkPosition.y, z = DEFAULTS.WalkPosition.z },
        SprintPosition = {
            x = DEFAULTS.SprintPosition.x,
            y = DEFAULTS.SprintPosition.y,
            z = DEFAULTS.SprintPosition.z,
        },

        FOVTransitionSteps = DEFAULTS.FOVTransitionSteps,
        KeyFOVTransitionSteps = DEFAULTS.KeyFOVTransitionSteps,
        LockOnExitBlendTime = DEFAULTS.LockOnExitBlendTime,

        DisableCameraCollision = DEFAULTS.DisableCameraCollision,
        EnableIdleCamera = DEFAULTS.EnableIdleCamera,
        EnableWalkingCamera = DEFAULTS.EnableWalkingCamera,
        EnableSprintingCamera = DEFAULTS.EnableSprintingCamera,
        EnableLockOnCamera = DEFAULTS.EnableLockOnCamera,

        LockOnYawBias = DEFAULTS.LockOnYawBias,
        LockOnPitchBias = DEFAULTS.LockOnPitchBias,
    }
end

local _config_corrupt_warned = false

local function load_file(path, container)
    local f = io.open(path, "r")
    if not f then
        -- Standard behavior: fresh file generation path, no error
        return container
    end

    local success, err = pcall(function()
        for line in f:lines() do
            -- Old greedy capture: if the new version doesn't work, use this
            -- local key, value = line:match("^%s*(%w+)%s*=%s*(.+)%s*$")
            local key, value = line:match("^%s*(%w+)%s*=%s*(.-)%s*$")
            if not key then
                -- Skip blank or malformed lines safely.
            elseif key == "FOV" then
                container.fovs.fov = tonumber(value) or container.fovs.fov
            elseif key == "CombatFOV" then
                container.fovs.combat = tonumber(value) or container.fovs.combat
            elseif key == "TPSFOV" then
                container.fovs.tps = tonumber(value) or container.fovs.tps
            elseif key == "IdleFOV" then
                container.fovs.idle = tonumber(value) or container.fovs.idle
            elseif key == "WalkFOV" then
                container.fovs.walk = tonumber(value) or container.fovs.walk
            elseif key == "SprintFOV" then
                container.fovs.sprint = tonumber(value) or container.fovs.sprint
            elseif key == "LockOnFOV" then
                container.fovs.lockon = tonumber(value) or container.fovs.lockon
            elseif key == "FOVTransitionSteps" then
                container.FOVTransitionSteps = tonumber(value) or container.FOVTransitionSteps
            elseif key == "KeyFOVTransitionSteps" then
                container.KeyFOVTransitionSteps = tonumber(value) or container.KeyFOVTransitionSteps
            elseif key == "LockOnExitBlendTime" then
                local n = tonumber(value)
                if n then
                    container.LockOnExitBlendTime = math.max(0.02, n)
                end
            elseif key == "DefaultCamX" then
                container.DefaultPosition.x = sanitize_number(value)
            elseif key == "DefaultCamY" then
                container.DefaultPosition.y = sanitize_number(value)
            elseif key == "DefaultCamZ" then
                container.DefaultPosition.z = sanitize_number(value)
            elseif key == "CombatCamX" then
                container.CombatPosition.x = sanitize_number(value)
            elseif key == "CombatCamY" then
                container.CombatPosition.y = sanitize_number(value)
            elseif key == "CombatCamZ" then
                container.CombatPosition.z = sanitize_number(value)
            elseif key == "LockOnCamX" then
                container.LockOnPosition.x = sanitize_number(value)
            elseif key == "LockOnCamY" then
                container.LockOnPosition.y = sanitize_number(value)
            elseif key == "LockOnCamZ" then
                container.LockOnPosition.z = sanitize_number(value)
            elseif key == "IdleCamX" then
                container.IdlePosition.x = sanitize_number(value)
            elseif key == "IdleCamY" then
                container.IdlePosition.y = sanitize_number(value)
            elseif key == "IdleCamZ" then
                container.IdlePosition.z = sanitize_number(value)
            elseif key == "WalkCamX" then
                container.WalkPosition.x = sanitize_number(value)
            elseif key == "WalkCamY" then
                container.WalkPosition.y = sanitize_number(value)
            elseif key == "WalkCamZ" then
                container.WalkPosition.z = sanitize_number(value)
            elseif key == "SprintCamX" then
                container.SprintPosition.x = sanitize_number(value)
            elseif key == "SprintCamY" then
                container.SprintPosition.y = sanitize_number(value)
            elseif key == "SprintCamZ" then
                container.SprintPosition.z = sanitize_number(value)
            elseif key == "LockOnYawBias" then
                local n = tonumber(value)
                if n then
                    container.LockOnYawBias = n
                end
            elseif key == "LockOnPitchBias" then
                local n = tonumber(value)
                if n then
                    container.LockOnPitchBias = n
                end
            elseif
                key == "DisableCameraCollision"
                or key == "EnableIdleCamera"
                or key == "EnableWalkingCamera"
                or key == "EnableSprintingCamera"
                or key == "EnableLockOnCamera"
            then
                local bool_val = sanitize_boolean(value)
                if bool_val ~= nil then
                    container[key] = bool_val
                else
                    -- Typo guard: If they wrote garbage, ignore the assignment
                    -- so the mod falls back safely to the hardcoded defaults.
                end
            end
        end
    end)

    f:close()

    if not success then
        if not _config_corrupt_warned then
            log_error(
                "Core syntax error or corruption detected in ezFOV.cfg; falling back to factory defaults.",
                "config_corrupt_fallback"
            )
            _config_corrupt_warned = true
        end
        return deep_copy_defaults() -- Secure fallback
    end

    return container
end

local CURRENT = nil

function M.get()
    if not CURRENT then
        CURRENT = load_file(DEFAULTS.path, deep_copy_defaults())
    end
    return CURRENT
end

function M.reload()
    CURRENT = nil
    return M.get()
end

local _save_timer = nil

function M.write()
    -- Cancel any pending save if the user presses a hotkey again within 200ms
    if _save_timer then
        Env.CancelDelay(_save_timer)
    end

    -- Wait 200ms after the user finishes adjusting before writing to disk
    _save_timer = Env.run_after_delay(200, "config_write", function()
        _save_timer = nil

        local cfg = M.get()
        if not cfg or type(cfg) ~= "table" then
            log_error(
                "Config file write failed because the runtime config is invalid.",
                "config_write_timer_missing_cfg"
            )
            return
        end

        local f = io.open(cfg.path, "w")
        if not f then
            log_error("Could not open config file for writing.", "config_write_open_failed")
            return
        end

        f:write("; =================================================================================\n")
        f:write("; ALTERNATIVE CAMERA SYSTEM CONFIGURATION\n;\n")
        f:write("; THE COORDINATE MATRIX SYSTEMS:\n;\n")
        f:write(";   1) FOR STANDARD MODES (Default, Combat, Idle, Walk, Sprint):\n")
        f:write(";      Uses Unreal's Local Attachment Space:\n")
        f:write(";      X = Forward & Backward / Depth (+In / -Out) -> Acts like a zoom!\n")
        f:write(";      Y = Sideways / Lateral Offset (+Right / -Left)\n")
        f:write(";      Z = Up & Down / Height (+Up / -Down)\n;\n")
        f:write(";   2) FOR LOCK-ON MODE ONLY (Rotation-Corrected Matrix):\n")
        f:write(";      X = Sideways / Lateral Offset (+Right / -Left)\n")
        f:write(";      Y = Depth Offset (Keep at 0.0 to maintain tight orbital target tracking)\n")
        f:write(";      Z = Up & Down / Height (+Up / -Down)\n;\n")
        f:write("; GLOBAL CORE HOTKEYS:\n")
        f:write(";   [F5]                    = Decrease active profile Field of View sharply (-25 FOV)\n")
        f:write(";   [F6]                    = Decrease active profile Field of View smoothly (-5 FOV)\n")
        f:write(";   [F7]                    = Increase active profile Field of View smoothly (+5 FOV)\n")
        f:write(";   [F8]                    = Live Reload configuration file changes instantly\n;\n")
        f:write("; CONTEXT-AWARE POSITION HOTKEYS (Modifies your currently active in-game mode):\n")
        f:write(";   [CTRL + UP/DOWN ARROW]  = Move active camera position on X Axis (+50 / -50 units)\n")
        f:write(";   [ALT  + LEFT/RIGHT]     = Move active camera position on Y Axis (+10 / -10 units)\n")
        f:write(";   [ALT  + UP/DOWN ARROW]  = Move active camera position on Z Axis (+10 / -10 units)\n;\n")
        f:write("; PRESET MANAGEMENT HOTKEYS:\n")
        f:write(";   [CTRL + 1..4]           = Load Saved Camera Preset Profile\n")
        f:write(";   [ALT  + 1..4]           = Save Current Camera Layout to Preset Slot\n")
        f:write("; =================================================================================\n\n")

        f:write("; ---------------------------------------------------------------------------------\n")
        f:write("; CAMERA COLLISION\n")
        f:write("; Prevents the camera from clipping or snapping aggressively forward when hitting \n")
        f:write("; walls or geometry. Set to true for an unhindered cinematic presentation.\n")
        f:write("; ---------------------------------------------------------------------------------\n")
        f:write("DisableCameraCollision=" .. tostring(cfg.DisableCameraCollision) .. "\n\n")

        f:write("; ---------------------------------------------------------------------------------\n")
        f:write("; DEFAULT CAMERA OFFSETS (Exploration & Idle)\n")
        f:write("; ---------------------------------------------------------------------------------\n")
        f:write(format("DefaultCamX=%.4f\n", cfg.DefaultPosition.x or 0))
        f:write(format("DefaultCamY=%.4f\n", cfg.DefaultPosition.y or 0))
        f:write(format("DefaultCamZ=%.4f\n\n", cfg.DefaultPosition.z or 0))

        f:write("; ---------------------------------------------------------------------------------\n")
        f:write("; COMBAT CAMERA OFFSETS (Un-locked Combat Engagement)\n")
        f:write("; Pulls back or shifts the camera dynamically when weapons are drawn in battle.\n")
        f:write("; ---------------------------------------------------------------------------------\n")
        f:write(format("CombatCamX=%.4f\n", cfg.CombatPosition.x or 0))
        f:write(format("CombatCamY=%.4f\n", cfg.CombatPosition.y or 0))
        f:write(format("CombatCamZ=%.4f\n\n", cfg.CombatPosition.z or 0))

        f:write("; ---------------------------------------------------------------------------------\n")
        f:write("; LOCK-ON CAMERA OFFSETS (Target Tracking Mode)\n")
        f:write("; ---------------------------------------------------------------------------------\n")
        f:write(format("LockOnCamX=%.4f\n", cfg.LockOnPosition.x or 0))
        f:write(format("LockOnCamY=%.4f\n", cfg.LockOnPosition.y or 0))
        f:write(format("LockOnCamZ=%.4f\n\n", cfg.LockOnPosition.z or 0))

        f:write("; ---------------------------------------------------------------------------------\n")
        f:write("; LOCK-ON CAMERA BIASES (Target Framing Rotation & Tilt in Degrees)\n")
        f:write("; ---------------------------------------------------------------------------------\n")
        f:write("; LockOnYawBias (Horizontal Framing):\n")
        f:write(";   Rotates the camera view horizontally around the target.\n")
        f:write(";   Positive (+) / [SHIFT + RIGHT ARROW] = Shifts enemy target RIGHT on screen (+1°)\n")
        f:write(";   Negative (-) / [SHIFT + LEFT ARROW]  = Shifts enemy target LEFT on screen (-1°)\n;\n")
        f:write(";   COMPOSITION TIP: Combine LockOnCamX=60.0 with LockOnYawBias=5.0 to achieve \n")
        f:write(";   a gorgeous over-the-shoulder split framing (Character LEFT, Enemy RIGHT).\n;\n")
        f:write("; LockOnPitchBias (Vertical Framing):\n")
        f:write(";   Tilts the camera view plane vertically.\n")
        f:write(";   Positive (+) / [SHIFT + UP ARROW]    = Tilts camera down / Shifts enemy target UP (+1°)\n")
        f:write(";   Negative (-) / [SHIFT + DOWN ARROW]  = Tilts camera up / Shifts enemy target DOWN (-1°)\n")
        f:write("; ---------------------------------------------------------------------------------\n")
        f:write(format("LockOnYawBias=%.1f\n", cfg.LockOnYawBias or 0))
        f:write(format("LockOnPitchBias=%.1f\n\n", cfg.LockOnPitchBias or 0))

        f:write("; ---------------------------------------------------------------------------------\n")
        f:write("; IDLE CAMERA CONFIGURATION (Standing still out of combat)\n")
        f:write("; ---------------------------------------------------------------------------------\n")
        f:write(format("IdleCamX=%.4f\n", cfg.IdlePosition.x or 0))
        f:write(format("IdleCamY=%.4f\n", cfg.IdlePosition.y or 0))
        f:write(format("IdleCamZ=%.4f\n\n", cfg.IdlePosition.z or 0))

        f:write("; ---------------------------------------------------------------------------------\n")
        f:write("; WALK CAMERA OFFSETS (Cinematic Slow Walk)\n")
        f:write("; Triggers a distinct cinematic frame shift when walking slowly.\n")
        f:write("; ---------------------------------------------------------------------------------\n")
        f:write(format("WalkCamX=%.4f\n", cfg.WalkPosition.x or 0))
        f:write(format("WalkCamY=%.4f\n", cfg.WalkPosition.y or 0))
        f:write(format("WalkCamZ=%.4f\n\n", cfg.WalkPosition.z or 0))

        f:write("; ---------------------------------------------------------------------------------\n")
        f:write("; SPRINT CAMERA OFFSETS (High-Speed Traversal)\n")
        f:write("; ---------------------------------------------------------------------------------\n")
        f:write(format("SprintCamX=%.4f\n", cfg.SprintPosition.x or 0))
        f:write(format("SprintCamY=%.4f\n", cfg.SprintPosition.y or 0))
        f:write(format("SprintCamZ=%.4f\n\n", cfg.SprintPosition.z or 0))

        f:write("; ---------------------------------------------------------------------------------\n")
        f:write("; FIELD OF VIEW (FOV Settings)\n")
        f:write("; ---------------------------------------------------------------------------------\n")
        f:write("; Baseline vanilla FOV is typically around 70-75.\n")
        f:write("; Values automatically clamped between an absolute minimum of 30 and maximum of 120.\n")
        f:write("; TPSFOV = 3rd person Ranged mode. It's lower for higher accuracy while aiming...\n")
        f:write("; ---------------------------------------------------------------------------------\n")
        f:write("FOV=" .. tostring(cfg.fovs.fov) .. "\n")
        f:write("CombatFOV=" .. tostring(cfg.fovs.combat) .. "\n")
        f:write("LockOnFOV=" .. tostring(cfg.fovs.lockon) .. "\n")
        f:write("TPSFOV=" .. tostring(cfg.fovs.tps) .. "\n")
        f:write("IdleFOV=" .. tostring(cfg.fovs.idle) .. "\n")
        f:write("WalkFOV=" .. tostring(cfg.fovs.walk) .. "\n")
        f:write("SprintFOV=" .. tostring(cfg.fovs.sprint) .. "\n\n")
        f:write("; FOV Transition Smoothness (Higher numbers = slower, more cinematic pacing)\n")
        f:write("FOVTransitionSteps=" .. tostring(cfg.FOVTransitionSteps) .. "\n")
        f:write("KeyFOVTransitionSteps=" .. tostring(cfg.KeyFOVTransitionSteps) .. "\n")
        f:write("LockOnExitBlendTime=" .. tostring(cfg.LockOnExitBlendTime or DEFAULTS.LockOnExitBlendTime) .. "\n\n")

        f:write("; ---------------------------------------------------------------------------------\n")
        f:write("; FEATURE TOGGLES\n")
        f:write("; Set true to let this script control properties for that movement profile stance,\n")
        f:write("; or false to fall back entirely to vanilla camera rules for that specific state.\n")
        f:write("; ---------------------------------------------------------------------------------\n")
        f:write("EnableIdleCamera=" .. tostring(cfg.EnableIdleCamera) .. "\n")
        f:write("EnableWalkingCamera=" .. tostring(cfg.EnableWalkingCamera) .. "\n")
        f:write("EnableSprintingCamera=" .. tostring(cfg.EnableSprintingCamera) .. "\n")
        f:write("EnableLockOnCamera=" .. tostring(cfg.EnableLockOnCamera) .. "\n")

        f:close()
        log_debug("Saved config to " .. cfg.path, "config_write_saved")
    end)
end

function M.save_preset(num)
    local ok, err = pcall(function()
        local cfg = M.get()
        local p = cfg.path .. "_preset" .. tostring(num)
        local f = io.open(p, "w")
        if not f then
            log_error(format("Could not save preset %d.", num), "preset_save_open_failed")
            return
        end

        f:write("; PRESET " .. num .. "\n\n")
        f:write("DisableCameraCollision=" .. tostring(cfg.DisableCameraCollision) .. "\n")
        f:write(
            format(
                "DefaultCamX=%.4f\nDefaultCamY=%.4f\nDefaultCamZ=%.4f\n",
                cfg.DefaultPosition.x or 0,
                cfg.DefaultPosition.y or 0,
                cfg.DefaultPosition.z or 0
            )
        )
        f:write(
            format(
                "CombatCamX=%.4f\nCombatCamY=%.4f\nCombatCamZ=%.4f\n",
                cfg.CombatPosition.x or 0,
                cfg.CombatPosition.y or 0,
                cfg.CombatPosition.z or 0
            )
        )
        f:write(
            format(
                "LockOnCamX=%.4f\nLockOnCamY=%.4f\nLockOnCamZ=%.4f\n",
                cfg.LockOnPosition.x or 0,
                cfg.LockOnPosition.y or 0,
                cfg.LockOnPosition.z or 0
            )
        )
        f:write(format("LockOnYawBias=%.1f\n", cfg.LockOnYawBias or 0))
        f:write(format("LockOnPitchBias=%.1f\n", cfg.LockOnPitchBias or 0))
        f:write(
            format(
                "IdleCamX=%.4f\nIdleCamY=%.4f\nIdleCamZ=%.4f\n",
                cfg.IdlePosition.x or 0,
                cfg.IdlePosition.y or 0,
                cfg.IdlePosition.z or 0
            )
        )
        f:write(
            format(
                "WalkCamX=%.4f\nWalkCamY=%.4f\nWalkCamZ=%.4f\n",
                cfg.WalkPosition.x or 0,
                cfg.WalkPosition.y or 0,
                cfg.WalkPosition.z or 0
            )
        )
        f:write(
            format(
                "SprintCamX=%.4f\nSprintCamY=%.4f\nSprintCamZ=%.4f\n",
                cfg.SprintPosition.x or 0,
                cfg.SprintPosition.y or 0,
                cfg.SprintPosition.z or 0
            )
        )
        f:write("FOV=" .. tostring(cfg.fovs.fov) .. "\n")
        f:write("CombatFOV=" .. tostring(cfg.fovs.combat) .. "\n")
        f:write("LockOnFOV=" .. tostring(cfg.fovs.lockon) .. "\n")
        f:write("TPSFOV=" .. tostring(cfg.fovs.tps) .. "\n")
        f:write("IdleFOV=" .. tostring(cfg.fovs.idle) .. "\n")
        f:write("WalkFOV=" .. tostring(cfg.fovs.walk) .. "\n")
        f:write("SprintFOV=" .. tostring(cfg.fovs.sprint) .. "\n")
        f:write("FOVTransitionSteps=" .. tostring(cfg.FOVTransitionSteps) .. "\n")
        f:write("KeyFOVTransitionSteps=" .. tostring(cfg.KeyFOVTransitionSteps) .. "\n")
        f:write("LockOnExitBlendTime=" .. tostring(cfg.LockOnExitBlendTime or DEFAULTS.LockOnExitBlendTime) .. "\n")
        f:write("EnableIdleCamera=" .. tostring(cfg.EnableIdleCamera) .. "\n")
        f:write("EnableWalkingCamera=" .. tostring(cfg.EnableWalkingCamera) .. "\n")
        f:write("EnableSprintingCamera=" .. tostring(cfg.EnableSprintingCamera) .. "\n")
        f:write("EnableLockOnCamera=" .. tostring(cfg.EnableLockOnCamera) .. "\n")

        f:close()
        log_debug(format("Saved preset %d.", num), "preset_saved")
    end)

    if not ok then
        log_error(format("Preset %d save failed: %s", num, tostring(err)), "preset_save_failed")
    end
end

function M.load_preset(num)
    local cfg = M.get()
    if not cfg or type(cfg) ~= "table" or type(cfg.fovs) ~= "table" then
        log_error(
            format("Preset %d load failed because the runtime config is invalid.", num),
            "preset_load_missing_cfg"
        )
        return false
    end

    local p = cfg.path .. "_preset" .. tostring(num)

    local test = io.open(p, "r")
    if not test then
        log_warn(format("Preset %d was not found.", num), "preset_not_found")
        return false
    end
    test:close()

    local container = deep_copy_defaults()

    -- Protect against internal structure fragmentation during preset load
    local ok, loaded = pcall(function()
        return load_file(p, container)
    end)
    if not ok or not loaded or type(loaded.fovs) ~= "table" then
        log_error(format("Preset %d file is malformed or has invalid structure.", num), "preset_invalid")
        return false
    end

    -- Safely commit loaded variables
    for k, v in pairs(loaded.fovs) do
        cfg.fovs[k] = v
    end
    cfg.DefaultPosition = loaded.DefaultPosition
    cfg.CombatPosition = loaded.CombatPosition
    cfg.LockOnPosition = loaded.LockOnPosition
    cfg.IdlePosition = loaded.IdlePosition
    cfg.WalkPosition = loaded.WalkPosition
    cfg.SprintPosition = loaded.SprintPosition
    cfg.FOVTransitionSteps = loaded.FOVTransitionSteps
    cfg.KeyFOVTransitionSteps = loaded.KeyFOVTransitionSteps
    cfg.LockOnExitBlendTime = loaded.LockOnExitBlendTime or cfg.LockOnExitBlendTime
    cfg.DisableCameraCollision = loaded.DisableCameraCollision
    cfg.EnableIdleCamera = loaded.EnableIdleCamera
    cfg.EnableWalkingCamera = loaded.EnableWalkingCamera
    cfg.EnableSprintingCamera = loaded.EnableSprintingCamera
    cfg.EnableLockOnCamera = loaded.EnableLockOnCamera
    cfg.LockOnYawBias = loaded.LockOnYawBias
    cfg.LockOnPitchBias = loaded.LockOnPitchBias

    log_debug(format("Successfully initialized and switched to preset %d.", num), "preset_loaded")
    return true
end

function M.cancel_pending_write()
    if _save_timer then
        Env.CancelDelay(_save_timer)
        _save_timer = nil
    end
end

return M
