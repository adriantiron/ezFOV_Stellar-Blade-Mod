--# selene: allow(global_usage, incorrect_standard_library_use)
package.path = package.path .. ";./ezFOV/Scripts/?.lua;./ezFOV/Scripts/?/init.lua"

-- Offline pre-deploy sanity test (heavier than in-game guards):
-- 1) Parse-check script files
-- 2) Smoke-load core modules with host API stubs
-- 3) Validate logging cache controls and env guard behavior
-- 4) Check baseline config/module invariants

package.preload["UEHelpers"] = function()
    return {}
end

local _original_globals = {
    ExecuteInGameThread = _G.ExecuteInGameThread,
    ExecuteWithDelay = _G.ExecuteWithDelay,
    CancelDelay = _G.CancelDelay,
    RegisterKeyBindAsync = _G.RegisterKeyBindAsync,
    RegisterHook = _G.RegisterHook,
    UnregisterHook = _G.UnregisterHook,
    FindFirstOf = _G.FindFirstOf,
    Key = _G.Key,
    ModifierKey = _G.ModifierKey,
}

local function restore_host_globals()
    for k, v in pairs(_original_globals) do
        _G[k] = v
    end
end

local _thread_invocations = 0
local _delay_invocations = 0
local _delay_token = 0
local _keybind_invocations = 0
local _hook_invocations = 0
local _unhook_invocations = 0

_G.ExecuteInGameThread = function(fn)
    _thread_invocations = _thread_invocations + 1
    if type(fn) == "function" then
        fn()
    end
end

_G.ExecuteWithDelay = function(_ms, fn)
    _delay_token = _delay_token + 1
    _delay_invocations = _delay_invocations + 1
    if type(fn) == "function" then
        fn()
    end
    return _delay_token
end

_G.CancelDelay = function(_token)
    return true
end

_G.RegisterKeyBindAsync = function(_key, _mods, cb)
    _keybind_invocations = _keybind_invocations + 1
    if type(cb) == "function" then
        cb()
    end
end

_G.RegisterHook = function(_path, _pre, _post)
    _hook_invocations = _hook_invocations + 1
    return 101, 202
end

_G.UnregisterHook = function(_path, _pre_id, _post_id)
    _unhook_invocations = _unhook_invocations + 1
end

_G.FindFirstOf = function(_name)
    return nil
end

_G.Key = {
    F8 = 0,
}

_G.ModifierKey = {
    CONTROL = 0,
    ALT = 1,
}

local function assert_compiles(path)
    local chunk, err = loadfile(path)
    assert(chunk ~= nil, "syntax check failed for " .. path .. ": " .. tostring(err))
end

local function assert_true(cond, message)
    assert(cond == true, message)
end

local function with_captured_print(fn)
    local old_print = print
    local logs = {}
    print = function(msg)
        logs[#logs + 1] = tostring(msg)
    end

    local ok, err = pcall(fn, logs)
    print = old_print
    if not ok then
        error(err)
    end
    return logs
end

local function run_tests()
    local script_files = {
        "./ezFOV/Scripts/env.lua",
        "./ezFOV/Scripts/logging.lua",
        "./ezFOV/Scripts/constants.lua",
        "./ezFOV/Scripts/heartbeat.lua",
        "./ezFOV/Scripts/playercontext.lua",
        "./ezFOV/Scripts/config.lua",
        "./ezFOV/Scripts/camera.lua",
        "./ezFOV/Scripts/stance.lua",
        "./ezFOV/Scripts/hooks.lua",
        "./ezFOV/Scripts/main.lua",
        "./ezFOV/Scripts/tests/sanity_test.lua",
    }

    for _, path in ipairs(script_files) do
        assert_compiles(path)
    end

    local Logging = require("logging")
    local Env = require("env")
    local Heartbeat = require("heartbeat")
    local PlayerCtx = require("playercontext")
    local Config = require("config")
    local Camera = require("camera")
    local Stance = require("stance")
    local Hooks = require("hooks")

    -- API smoke checks
    assert(type(Logging.log_debug) == "function", "logging module should expose log_debug")
    assert(type(Logging.set_warn_cache_enabled) == "function", "logging module should expose warning cache setter")
    assert(type(Logging.set_debug_cache_enabled) == "function", "logging module should expose debug cache setter")
    assert(type(Env.run_now) == "function", "env module should expose run_now")
    assert(
        type(Env.set_immediate_traceback_enabled) == "function",
        "env module should expose immediate traceback setter"
    )
    assert(type(Heartbeat.pulse) == "function", "heartbeat module should expose pulse")
    assert(type(PlayerCtx.get_snapshot) == "function", "playercontext module should expose get_snapshot")
    assert(type(Config.get) == "function", "config module should expose get")
    assert(type(Camera.begin_lockon_exit_blend) == "function", "camera module should expose begin_lockon_exit_blend")
    assert(type(Stance.pulse) == "function", "stance module should expose pulse")
    assert(type(Hooks.init) == "function", "hooks module should expose init")

    -- Logging cache behavior checks
    Logging.clear_once_cache()
    Logging.set_warn_cache_enabled(true)
    local warn_cached_logs = with_captured_print(function()
        Logging.log_warn("Sanity", "warn once", "warn_key", true)
        Logging.log_warn("Sanity", "warn once", "warn_key", true)
    end)
    assert(#warn_cached_logs == 1, "warn cache enabled should suppress duplicate once-key logs")

    Logging.clear_once_cache()
    Logging.set_warn_cache_enabled(false)
    local warn_uncached_logs = with_captured_print(function()
        Logging.log_warn("Sanity", "warn uncached", "warn_key", true)
        Logging.log_warn("Sanity", "warn uncached", "warn_key", true)
    end)
    assert(#warn_uncached_logs == 2, "warn cache disabled should emit duplicate once-key logs")
    Logging.set_warn_cache_enabled(true)

    Logging.clear_once_cache()
    Logging.set_debug_cache_enabled(true)
    local debug_cached_logs = with_captured_print(function()
        Logging.log_debug("Sanity", "debug once", "debug_key", true)
        Logging.log_debug("Sanity", "debug once", "debug_key", true)
    end)
    assert(#debug_cached_logs == 1, "debug cache enabled should suppress duplicate once-key logs")

    Logging.clear_once_cache()
    Logging.set_debug_cache_enabled(false)
    local debug_uncached_logs = with_captured_print(function()
        Logging.log_debug("Sanity", "debug uncached", "debug_key", true)
        Logging.log_debug("Sanity", "debug uncached", "debug_key", true)
    end)
    assert(#debug_uncached_logs == 2, "debug cache disabled should emit duplicate once-key logs")
    Logging.set_debug_cache_enabled(true)

    local error_logs = with_captured_print(function()
        Logging.log_error("Sanity", "error A", "same_key")
        Logging.log_error("Sanity", "error B", "same_key")
    end)
    assert(#error_logs == 2, "errors should always emit even with matching once key")

    -- for_component: bound logger carries the component tag and forwards to log_*
    assert(type(Logging.for_component) == "function", "logging module should expose for_component")
    local bound = Logging.for_component("SanityBound")
    assert(
        type(bound.error) == "function" and type(bound.warn) == "function" and type(bound.debug) == "function",
        "for_component should expose error/warn/debug"
    )
    local bound_logs = with_captured_print(function()
        bound.debug("bound message")
    end)
    assert(#bound_logs == 1, "for_component logger should emit a line")
    assert(bound_logs[1]:find("SanityBound", 1, true) ~= nil, "for_component log should carry the component tag")

    -- Env guard behavior checks
    local ran_immediate = false
    assert_true(
        Env.run_now("Sanity", "immediate_ok", function()
            ran_immediate = true
        end),
        "run_now should return true for non-throwing callback"
    )
    assert_true(ran_immediate, "run_now should execute callback")

    local guard_error_logs = with_captured_print(function()
        local prev_mode = Env.is_immediate_traceback_enabled()
        Env.set_immediate_traceback_enabled(false)

        local ok_run, run_err = pcall(function()
            local ok = Env.run_now("Sanity", "immediate_fail", function()
                error("boom")
            end)
            assert(ok == false, "run_now should return false on callback failure")
        end)

        Env.set_immediate_traceback_enabled(prev_mode)

        if not ok_run then
            error(run_err)
        end
    end)
    assert(#guard_error_logs >= 1, "failing run_now should produce an error log")

    local ran_thread = false
    assert_true(
        Env.run_on_game_thread("Sanity", "thread_ok", function()
            ran_thread = true
        end),
        "run_on_game_thread should schedule with host stub"
    )
    assert_true(ran_thread, "run_on_game_thread should execute callback under host stub")

    local ran_delay = false
    local token = Env.run_after_delay("Sanity", 1, "delay_ok", function()
        ran_delay = true
    end)
    assert(type(token) == "number", "run_after_delay should return token under host stub")
    assert_true(ran_delay, "run_after_delay should execute callback under host stub")

    assert(_thread_invocations >= 1, "thread host stub should be hit at least once")
    assert(_delay_invocations >= 1, "delay host stub should be hit at least once")

    -- Hook helper checks
    local pre_id, post_id = Env.safe_register_hook("Sanity", "Game.Path:Func", function() end, nil)
    assert(pre_id ~= nil and post_id ~= nil, "safe_register_hook should return ids under host stub")
    local entry = { path = "Game.Path:Func", pre_id = pre_id, post_id = post_id }
    Env.safe_unregister_hook("Sanity", entry)
    assert(entry.pre_id == nil and entry.post_id == nil, "safe_unregister_hook should clear hook ids")
    assert(_hook_invocations >= 1, "register hook stub should be hit at least once")
    assert(_unhook_invocations >= 1, "unregister hook stub should be hit at least once")

    -- Config invariants
    local cfg = Config.get()
    assert(cfg ~= nil, "config module should return a runtime config")
    assert(type(cfg.LockOnExitBlendTime) == "number", "LockOnExitBlendTime should be a number")
    assert(cfg.LockOnExitBlendTime > 0, "LockOnExitBlendTime should be positive")
    assert(type(cfg.fovs) == "table", "config should include fovs table")
    assert(type(cfg.fovs.fov) == "number", "config fov should be numeric")
    assert(type(cfg.DefaultPosition) == "table", "config should include DefaultPosition")
    assert(type(cfg.DefaultPosition.x) == "number", "DefaultPosition.x should be numeric")

    -- Constants module: cross-cutting tuning values used by main/playercontext.
    local Constants = require("constants")
    assert(
        type(Constants.FOV_MIN) == "number" and type(Constants.FOV_MAX) == "number",
        "constants should expose numeric FOV bounds"
    )
    assert(Constants.FOV_MAX > Constants.FOV_MIN, "FOV_MAX should exceed FOV_MIN")
    assert(type(Constants.LOCKON_BIAS_LIMIT) == "number", "constants should expose LOCKON_BIAS_LIMIT")
    assert(
        type(Constants.LOCO_IDLE_MAX_SPEED) == "number"
            and type(Constants.LOCO_SLOW_WALK_MAX_SPEED) == "number"
            and type(Constants.LOCO_SPRINT_MIN_SPEED) == "number",
        "constants should expose numeric locomotion thresholds"
    )

    -- Config round-trip characterization: a full write -> read cycle must preserve every field.
    -- This locks the key<->field mapping shared by write/save_preset/load_file so the upcoming
    -- schema unification can be proven behavior-preserving. Values are chosen to be in-range and
    -- format-safe (<=4 decimals for positions, <=1 for biases) so they survive the write format.
    do
        Config.reload()
        local rt = Config.get()
        local original_path = rt.path
        rt.path = "./ezfov_roundtrip_tmp.cfg"

        rt.fovs.fov = 85
        rt.fovs.combat = 95
        rt.fovs.lockon = 70
        rt.fovs.tps = 65
        rt.fovs.idle = 88
        rt.fovs.walk = 92
        rt.fovs.sprint = 100
        rt.DefaultPosition = { x = 10.0, y = 20.0, z = 30.0 }
        rt.CombatPosition = { x = 40.0, y = 50.0, z = 60.0 }
        rt.LockOnPosition = { x = 70.0, y = 0.0, z = 15.0 }
        rt.IdlePosition = { x = 200.0, y = 5.0, z = 10.0 }
        rt.WalkPosition = { x = 210.0, y = 6.0, z = 11.0 }
        rt.SprintPosition = { x = 220.0, y = 7.0, z = 12.0 }
        rt.LockOnYawBias = 5.0
        rt.LockOnPitchBias = -3.0
        rt.FOVTransitionSteps = 40
        rt.KeyFOVTransitionSteps = 15
        rt.LockOnExitBlendTime = 0.25
        rt.DisableCameraCollision = true
        rt.EnableIdleCamera = false
        rt.EnableWalkingCamera = false
        rt.EnableSprintingCamera = true
        rt.EnableLockOnCamera = false

        -- Main writer emits the expected keys and formats.
        Config.write()
        local wf = io.open(rt.path, "r")
        local written = wf and wf:read("*a") or ""
        if wf then
            wf:close()
        end
        os.remove(rt.path)
        assert(wf ~= nil, "Config.write should produce the config file")
        assert(written:find("FOV=85", 1, true) ~= nil, "written cfg should contain FOV=85")
        assert(written:find("DisableCameraCollision=true", 1, true) ~= nil, "written cfg should contain the collision flag")
        assert(written:find("DefaultCamX=10.0000", 1, true) ~= nil, "written cfg should contain DefaultCamX=10.0000")
        assert(written:find("LockOnYawBias=5.0", 1, true) ~= nil, "written cfg should contain LockOnYawBias=5.0")

        -- Full round-trip through save_preset -> load_preset.
        Config.save_preset(99)
        rt.fovs.fov = 1
        rt.DisableCameraCollision = false
        rt.LockOnYawBias = 0
        local loaded_ok = Config.load_preset(99)
        os.remove(rt.path .. "_preset99")
        assert(loaded_ok == true, "preset 99 should load")

        assert(rt.fovs.fov == 85, "fov should round-trip")
        assert(rt.fovs.combat == 95, "combat fov should round-trip")
        assert(rt.fovs.lockon == 70, "lockon fov should round-trip")
        assert(rt.fovs.tps == 65, "tps fov should round-trip")
        assert(rt.fovs.idle == 88, "idle fov should round-trip")
        assert(rt.fovs.walk == 92, "walk fov should round-trip")
        assert(rt.fovs.sprint == 100, "sprint fov should round-trip")
        assert(rt.DefaultPosition.x == 10 and rt.DefaultPosition.y == 20 and rt.DefaultPosition.z == 30, "default pos round-trip")
        assert(rt.CombatPosition.x == 40 and rt.CombatPosition.y == 50 and rt.CombatPosition.z == 60, "combat pos round-trip")
        assert(rt.LockOnPosition.x == 70 and rt.LockOnPosition.y == 0 and rt.LockOnPosition.z == 15, "lockon pos round-trip")
        assert(rt.IdlePosition.x == 200 and rt.IdlePosition.y == 5 and rt.IdlePosition.z == 10, "idle pos round-trip")
        assert(rt.WalkPosition.x == 210 and rt.WalkPosition.y == 6 and rt.WalkPosition.z == 11, "walk pos round-trip")
        assert(rt.SprintPosition.x == 220 and rt.SprintPosition.y == 7 and rt.SprintPosition.z == 12, "sprint pos round-trip")
        assert(rt.LockOnYawBias == 5.0, "yaw bias should round-trip")
        assert(rt.LockOnPitchBias == -3.0, "pitch bias should round-trip")
        assert(rt.FOVTransitionSteps == 40, "fov transition steps should round-trip")
        assert(rt.KeyFOVTransitionSteps == 15, "key fov transition steps should round-trip")
        assert(rt.LockOnExitBlendTime == 0.25, "blend time should round-trip")
        assert(rt.DisableCameraCollision == true, "collision flag should round-trip")
        assert(rt.EnableIdleCamera == false, "idle enable should round-trip")
        assert(rt.EnableWalkingCamera == false, "walking enable should round-trip")
        assert(rt.EnableSprintingCamera == true, "sprinting enable should round-trip")
        assert(rt.EnableLockOnCamera == false, "lock-on enable should round-trip")

        rt.path = original_path
        Config.reload()
    end

    -- FOV clamp folded into load: out-of-range values are bounded to Constants.FOV_MIN/MAX and
    -- the lock-on exit blend time is floored, regardless of what the file/preset contains.
    do
        Config.reload()
        local rt = Config.get()
        local original_path = rt.path
        rt.path = "./ezfov_clamp_tmp.cfg"
        local pf = io.open(rt.path .. "_preset98", "w")
        assert(pf ~= nil, "clamp test should be able to write its preset file")
        pf:write("FOV=200\nCombatFOV=5\nLockOnExitBlendTime=0.001\n")
        pf:close()
        local clamp_ok = Config.load_preset(98)
        os.remove(rt.path .. "_preset98")
        assert(clamp_ok == true, "clamp preset should load")
        assert(rt.fovs.fov == Constants.FOV_MAX, "over-max FOV should clamp to FOV_MAX on load")
        assert(rt.fovs.combat == Constants.FOV_MIN, "under-min FOV should clamp to FOV_MIN on load")
        assert(rt.LockOnExitBlendTime >= 0.02, "blend time should be floored at 0.02 on load")
        rt.path = original_path
        Config.reload()
    end
end

local function format_error(err)
    if debug and type(debug.traceback) == "function" then
        return debug.traceback(tostring(err), 2)
    end
    return tostring(err)
end

local ok, err = xpcall(run_tests, format_error)
restore_host_globals()
if not ok then
    error(err)
end

print("module_sanity_test ok")
