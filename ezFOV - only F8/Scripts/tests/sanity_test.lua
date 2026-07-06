package.path = package.path .. ";./ezFOV - only F8/Scripts/?.lua;./ezFOV - only F8/Scripts/?/init.lua"

-- Offline pre-deploy sanity test (heavier than in-game guards):
-- 1) Parse-check script files
-- 2) Smoke-load core modules with host API stubs
-- 3) Validate logging cache controls and env guard behavior
-- 4) Check baseline config/module invariants

package.preload["UEHelpers"] = function()
	return {}
end

local _thread_invocations = 0
local _delay_invocations = 0
local _delay_token = 0
local _keybind_invocations = 0
local _hook_invocations = 0
local _unhook_invocations = 0

_G.ExecuteInGameThread = function(fn)
	_thread_invocations = _thread_invocations + 1
	if type(fn) == "function" then fn() end
end

_G.ExecuteWithDelay = function(_ms, fn)
	_delay_token = _delay_token + 1
	_delay_invocations = _delay_invocations + 1
	if type(fn) == "function" then fn() end
	return _delay_token
end

_G.CancelDelay = function(_token)
	return true
end

_G.RegisterKeyBindAsync = function(_key, _mods, cb)
	_keybind_invocations = _keybind_invocations + 1
	if type(cb) == "function" then cb() end
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

local script_files = {
	"./ezFOV - only F8/Scripts/env.lua",
	"./ezFOV - only F8/Scripts/logging.lua",
	"./ezFOV - only F8/Scripts/heartbeat.lua",
	"./ezFOV - only F8/Scripts/playercontext.lua",
	"./ezFOV - only F8/Scripts/config.lua",
	"./ezFOV - only F8/Scripts/camera.lua",
	"./ezFOV - only F8/Scripts/stance.lua",
	"./ezFOV - only F8/Scripts/hooks.lua",
	"./ezFOV - only F8/Scripts/main.lua",
	"./ezFOV - only F8/Scripts/tests/sanity_test.lua",
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
assert(type(Env.set_immediate_traceback_enabled) == "function", "env module should expose immediate traceback setter")
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

-- Env guard behavior checks
local ran_immediate = false
assert_true(Env.run_now("Sanity", "immediate_ok", function()
	ran_immediate = true
end), "run_now should return true for non-throwing callback")
assert_true(ran_immediate, "run_now should execute callback")

local guard_error_logs = with_captured_print(function()
	Env.set_immediate_traceback_enabled(false)
	local ok = Env.run_now("Sanity", "immediate_fail", function()
		error("boom")
	end)
	assert(ok == false, "run_now should return false on callback failure")
	Env.set_immediate_traceback_enabled(true)
end)
assert(#guard_error_logs >= 1, "failing run_now should produce an error log")

local ran_thread = false
assert_true(Env.run_on_game_thread("Sanity", "thread_ok", function()
	ran_thread = true
end), "run_on_game_thread should schedule with host stub")
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

print("module_sanity_test ok")
