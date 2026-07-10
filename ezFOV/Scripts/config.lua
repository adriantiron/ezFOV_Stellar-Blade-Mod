local Logging = require("logging")
local Env = require("env").bind("Config")
local Constants = require("constants")

local format = string.format

local M = {}

-- Component-scoped logger (see Logging.for_component).
local log = Logging.for_component("Config")

local DEFAULT_PATH = "UE4SS/Mods/ezFOV/ezFOV.cfg"

-- fovs.default and path are internal and never persisted to the .cfg, so they live outside SCHEMA.
local FOV_CLAMP = { min = Constants.FOV_MIN, max = Constants.FOV_MAX }

-- Ordered config schema: the SINGLE source of truth for every persisted .cfg key. It drives the
-- defaults, the parser (load), the full writer, and preset save -- so the key<->field mapping is
-- defined once here instead of being mirrored across those functions.
--   key     .cfg key / parser token
--   path    nested location in the runtime config table
--   kind    "number" | "bool"
--   default default value
--   fmt     string.format spec for writing numbers (nil => tostring)
--   clamp   { min, max } enforced when a value is read
--   floor   lower bound enforced when a value is read (e.g. blend time)
--   section short comment block written before this key in the full file (omitted from presets)

-- A horizontal rule (81 dashes) that frames section banners in the generated .cfg; its width
-- matches the top/bottom header borders so the whole file lines up.
local RULE = "; " .. string.rep("-", 81)

-- Build a bordered section banner: an opening RULE, the given comment lines, then a closing RULE.
-- Keeping the repeated border here lets each schema section read as just its comment text.
local function banner(...)
    local lines = { RULE, ... }
    lines[#lines + 1] = RULE
    return table.concat(lines, "\n")
end

local SCHEMA = {
    {
        key = "DisableCameraCollision",
        path = { "DisableCameraCollision" },
        kind = "bool",
        default = false,
        section = banner(
            "; CAMERA COLLISION",
            "; Prevents the camera from clipping or snapping aggressively forward when hitting",
            "; walls or geometry. Set to true for an unhindered cinematic framing."
        ),
    },

    {
        key = "DefaultCamX",
        path = { "DefaultPosition", "x" },
        kind = "number",
        default = 0,
        fmt = "%.4f",
        section = banner("; DEFAULT CAMERA OFFSETS (Exploration & Idle)"),
    },
    { key = "DefaultCamY", path = { "DefaultPosition", "y" }, kind = "number", default = 0, fmt = "%.4f" },
    { key = "DefaultCamZ", path = { "DefaultPosition", "z" }, kind = "number", default = 0, fmt = "%.4f" },

    {
        key = "CombatCamX",
        path = { "CombatPosition", "x" },
        kind = "number",
        default = 0,
        fmt = "%.4f",
        section = banner("; COMBAT CAMERA OFFSETS (Un-locked Combat Engagement)"),
    },
    { key = "CombatCamY", path = { "CombatPosition", "y" }, kind = "number", default = 0, fmt = "%.4f" },
    { key = "CombatCamZ", path = { "CombatPosition", "z" }, kind = "number", default = 0, fmt = "%.4f" },

    {
        key = "LockOnCamX",
        path = { "LockOnPosition", "x" },
        kind = "number",
        default = 0,
        fmt = "%.4f",
        section = banner("; LOCK-ON CAMERA OFFSETS (Target Tracking Mode)"),
    },
    { key = "LockOnCamY", path = { "LockOnPosition", "y" }, kind = "number", default = 0, fmt = "%.4f" },
    { key = "LockOnCamZ", path = { "LockOnPosition", "z" }, kind = "number", default = 0, fmt = "%.4f" },

    {
        key = "LockOnYawBias",
        path = { "LockOnYawBias" },
        kind = "number",
        default = 0,
        fmt = "%.1f",
        section = banner(
            "; LOCK-ON CAMERA BIASES (Target Framing Rotation & Tilt)",
            ";",
            "; LockOnYawBias (Horizontal Framing):",
            ";   Rotates the camera view horizontally around the target.",
            ";   Positive (+) / [SHIFT + RIGHT ARROW] = Shifts enemy target RIGHT on screen (+1°)",
            ";   Negative (-) / [SHIFT + LEFT ARROW]  = Shifts enemy target LEFT on screen (-1°)",
            ";",
            ";   COMPOSITION TIP: Combine LockOnCamX=60.0 with LockOnYawBias=5.0 to achieve",
            ";   a gorgeous over-the-shoulder split framing (Character LEFT, Enemy RIGHT).",
            ";",
            "; LockOnPitchBias (Vertical Framing):",
            ";   Tilts the camera view plane vertically.",
            ";   Positive (+) / [SHIFT + UP ARROW]    = Tilts camera down / Shifts enemy target UP (+1°)",
            ";   Negative (-) / [SHIFT + DOWN ARROW]  = Tilts camera up / Shifts enemy target DOWN (-1°)"
        ),
    },
    { key = "LockOnPitchBias", path = { "LockOnPitchBias" }, kind = "number", default = 0, fmt = "%.1f" },

    {
        key = "IdleCamX",
        path = { "IdlePosition", "x" },
        kind = "number",
        default = 200,
        fmt = "%.4f",
        section = banner("; IDLE CAMERA OFFSETS (Standing still, out of combat)"),
    },
    { key = "IdleCamY", path = { "IdlePosition", "y" }, kind = "number", default = 0, fmt = "%.4f" },
    { key = "IdleCamZ", path = { "IdlePosition", "z" }, kind = "number", default = 0, fmt = "%.4f" },

    {
        key = "WalkCamX",
        path = { "WalkPosition", "x" },
        kind = "number",
        default = 200,
        fmt = "%.4f",
        section = banner("; WALK CAMERA OFFSETS (Cinematic Slow Walk)"),
    },
    { key = "WalkCamY", path = { "WalkPosition", "y" }, kind = "number", default = 0, fmt = "%.4f" },
    { key = "WalkCamZ", path = { "WalkPosition", "z" }, kind = "number", default = 0, fmt = "%.4f" },

    {
        key = "SprintCamX",
        path = { "SprintPosition", "x" },
        kind = "number",
        default = 0,
        fmt = "%.4f",
        section = banner("; SPRINT CAMERA OFFSETS (High-Speed Traversal)"),
    },
    { key = "SprintCamY", path = { "SprintPosition", "y" }, kind = "number", default = 0, fmt = "%.4f" },
    { key = "SprintCamZ", path = { "SprintPosition", "z" }, kind = "number", default = 0, fmt = "%.4f" },

    {
        key = "FOV",
        path = { "fovs", "fov" },
        kind = "number",
        default = 90,
        clamp = FOV_CLAMP,
        section = banner(
            "; FIELD OF VIEW (FOV Settings)",
            ";",
            "; Baseline vanilla FOV is typically around 70-75.",
            "; Values automatically clamped in [30, 120] interval.",
            "; TPSFOV = 3rd person Ranged mode. It's lower for higher accuracy while aiming..."
        ),
    },
    { key = "CombatFOV", path = { "fovs", "combat" }, kind = "number", default = 90, clamp = FOV_CLAMP },
    { key = "LockOnFOV", path = { "fovs", "lockon" }, kind = "number", default = 90, clamp = FOV_CLAMP },
    { key = "TPSFOV", path = { "fovs", "tps" }, kind = "number", default = 70, clamp = FOV_CLAMP },
    { key = "IdleFOV", path = { "fovs", "idle" }, kind = "number", default = 90, clamp = FOV_CLAMP },
    { key = "WalkFOV", path = { "fovs", "walk" }, kind = "number", default = 90, clamp = FOV_CLAMP },
    { key = "SprintFOV", path = { "fovs", "sprint" }, kind = "number", default = 90, clamp = FOV_CLAMP },

    {
        key = "FOVTransitionSteps",
        path = { "FOVTransitionSteps" },
        kind = "number",
        default = 60,
        section = "; FOV Transition Smoothness (Higher numbers = slower, more cinematic pacing)",
    },
    { key = "KeyFOVTransitionSteps", path = { "KeyFOVTransitionSteps" }, kind = "number", default = 20 },
    { key = "LockOnExitBlendTime", path = { "LockOnExitBlendTime" }, kind = "number", default = 0.16, floor = 0.02 },

    {
        key = "EnableIdleCamera",
        path = { "EnableIdleCamera" },
        kind = "bool",
        default = true,
        section = banner(
            "; FEATURE TOGGLES",
            "; Set true to let this script control properties for that movement stance,",
            "; or false to fall back entirely to vanilla camera rules for that specific state."
        ),
    },
    { key = "EnableWalkingCamera", path = { "EnableWalkingCamera" }, kind = "bool", default = true },
    { key = "EnableSprintingCamera", path = { "EnableSprintingCamera" }, kind = "bool", default = true },
    { key = "EnableLockOnCamera", path = { "EnableLockOnCamera" }, kind = "bool", default = true },
}

local SCHEMA_BY_KEY = {}
for _, entry in ipairs(SCHEMA) do
    SCHEMA_BY_KEY[entry.key] = entry
end

local function sanitize_boolean(v)
    if type(v) == "boolean" then
        return v
    end
    if type(v) == "string" then
        local clean = v:match("^%s*(.-)%s*$"):lower()
        if clean == "true" or clean == "1" then
            return true
        end
        if clean == "false" or clean == "0" then
            return false
        end
    end
    return nil -- not a clear boolean; caller keeps the existing/default value
end

-- Assign a value at a nested path (list of keys), creating intermediate tables as needed.
local function set_path(tbl, path, value)
    local node = tbl
    for i = 1, #path - 1 do
        local k = path[i]
        if type(node[k]) ~= "table" then
            node[k] = {}
        end
        node = node[k]
    end
    node[path[#path]] = value
end

-- Coerce a raw .cfg string into the entry's kind, applying floor/clamp. Returns nil when the
-- value is unusable so the caller keeps whatever default is already in the container.
local function coerce(entry, value)
    if entry.kind == "bool" then
        return sanitize_boolean(value)
    end
    local n = tonumber(value)
    if n == nil then
        return nil
    end
    if entry.floor then
        n = math.max(entry.floor, n)
    end
    if entry.clamp then
        n = math.max(entry.clamp.min, math.min(entry.clamp.max, n))
    end
    return n
end

-- Build a fresh config populated from schema defaults plus the internal (non-persisted) fields.
local function deep_copy_defaults()
    local cfg = { path = DEFAULT_PATH, fovs = { default = 75 } }
    for _, entry in ipairs(SCHEMA) do
        set_path(cfg, entry.path, entry.default)
    end
    return cfg
end

local _config_corrupt_warned = false

local function load_file(path, container)
    local f = io.open(path, "r")
    if not f then
        -- Standard behavior: fresh file generation path, no error
        return container
    end

    local success = pcall(function()
        for line in f:lines() do
            local key, value = line:match("^%s*(%w+)%s*=%s*(.-)%s*$")
            local entry = key and SCHEMA_BY_KEY[key]
            if entry then
                local coerced = coerce(entry, value)
                -- nil means the value was blank/garbage; keep the container's current default.
                if coerced ~= nil then
                    set_path(container, entry.path, coerced)
                end
            end
        end
    end)

    f:close()

    if not success then
        if not _config_corrupt_warned then
            log.error(
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
        CURRENT = load_file(DEFAULT_PATH, deep_copy_defaults())
    end
    return CURRENT
end

function M.reload()
    CURRENT = nil
    return M.get()
end

-- Banner written at the top of the generated .cfg as inline docs for anyone hand-editing it.
local HEADER = [[; =================================================================================
; ALTERNATIVE CAMERA SYSTEM CONFIGURATION
;
; THE COORDINATE MATRIX SYSTEMS:
;
;   1) FOR STANDARD MODES (Default, Combat, Idle, Walk, Sprint):
;      Uses Unreal's Local Attachment Space:
;      X = Forward & Backward / Depth (+In / -Out) -> Acts like a zoom!
;      Y = Sideways / Lateral Offset (+Right / -Left)
;      Z = Up & Down / Height (+Up / -Down)
;
;   2) FOR LOCK-ON MODE ONLY (Rotation-Corrected Matrix):
;      X = Sideways / Lateral Offset (+Right / -Left)
;      Y = Depth Offset (Keep at 0.0 to maintain tight orbital target tracking)
;      Z = Up & Down / Height (+Up / -Down)
;
; GLOBAL CORE HOTKEYS:
;   [F5]                    = Decrease active FOV sharply (-25)
;   [F6]                    = Decrease active FOV smoothly (-5)
;   [F7]                    = Increase active FOV smoothly (+5)
;   [F8]                    = Live Reload this CFG file
;
; CONTEXT-AWARE POSITION HOTKEYS (Modifies your currently active in-game stance):
;   [CTRL + UP/DOWN ARROW]  = Move active camera position on X Axis (+50 / -50 units)
;   [ALT  + LEFT/RIGHT]     = Move active camera position on Y Axis (+10 / -10 units)
;   [ALT  + UP/DOWN ARROW]  = Move active camera position on Z Axis (+10 / -10 units)
;
; PRESET MANAGEMENT HOTKEYS:
;   [CTRL + 1..4]           = Load Saved CFG Preset
;   [ALT  + 1..4]           = Save Current CFG Preset to Slot
; =================================================================================
]]

-- Read a value at a nested path; returns nil if any segment is missing.
local function get_path(tbl, path)
    local node = tbl
    for i = 1, #path do
        if type(node) ~= "table" then
            return nil
        end
        node = node[path[i]]
    end
    return node
end

-- Render one schema field's value for its .cfg line.
local function format_value(entry, value)
    if entry.kind == "bool" then
        return tostring(value)
    end
    if entry.fmt then
        return format(entry.fmt, value or 0)
    end
    return tostring(value)
end

-- Serialize a config to `path` by walking the schema -- the single source for keys/format/order.
--   opts.header    verbatim text written first (nil to skip)
--   opts.sections  when true, emit each field's section comment (full file; omitted for presets)
local function write_config_to(path, cfg, opts)
    local f = io.open(path, "w")
    if not f then
        return false
    end
    if opts.header then
        f:write(opts.header)
    end
    for _, entry in ipairs(SCHEMA) do
        if opts.sections and entry.section then
            f:write("\n" .. entry.section .. "\n")
        end
        f:write(entry.key .. "=" .. format_value(entry, get_path(cfg, entry.path)) .. "\n")
    end
    f:close()
    return true
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
            log.error(
                "Config file write failed because the runtime config is invalid.",
                "config_write_timer_missing_cfg"
            )
            return
        end

        if not write_config_to(cfg.path, cfg, { header = HEADER, sections = true }) then
            log.error("Could not open config file for writing.", "config_write_open_failed")
            return
        end

        log.debug("Saved config to " .. cfg.path, "config_write_saved")
    end)
end

function M.save_preset(num)
    local ok, err = pcall(function()
        local cfg = M.get()
        local p = cfg.path .. "_preset" .. tostring(num)
        if not write_config_to(p, cfg, { header = "; PRESET " .. num .. "\n\n", sections = false }) then
            log.error(format("Could not save preset %d.", num), "preset_save_open_failed")
            return
        end
        log.debug(format("Saved preset %d.", num), "preset_saved")
    end)

    if not ok then
        log.error(format("Preset %d save failed: %s", num, tostring(err)), "preset_save_failed")
    end
end

function M.load_preset(num)
    local cfg = M.get()
    if not cfg or type(cfg) ~= "table" or type(cfg.fovs) ~= "table" then
        log.error(
            format("Preset %d load failed because the runtime config is invalid.", num),
            "preset_load_missing_cfg"
        )
        return false
    end

    local p = cfg.path .. "_preset" .. tostring(num)

    local test = io.open(p, "r")
    if not test then
        log.warn(format("Preset %d was not found.", num), "preset_not_found")
        return false
    end
    test:close()

    local container = deep_copy_defaults()

    -- Protect against internal structure fragmentation during preset load
    local ok, loaded = pcall(function()
        return load_file(p, container)
    end)
    if not ok or not loaded or type(loaded.fovs) ~= "table" then
        log.error(format("Preset %d file is malformed or has invalid structure.", num), "preset_invalid")
        return false
    end

    -- Commit the loaded values onto the live config, driven by the same schema (no field mirror).
    for _, entry in ipairs(SCHEMA) do
        set_path(cfg, entry.path, get_path(loaded, entry.path))
    end

    log.debug(format("Successfully initialized and switched to preset %d.", num), "preset_loaded")
    return true
end

function M.cancel_pending_write()
    if _save_timer then
        Env.CancelDelay(_save_timer)
        _save_timer = nil
    end
end

return M
