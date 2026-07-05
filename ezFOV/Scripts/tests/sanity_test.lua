package.path = package.path .. ";./ezFOV/Scripts/?.lua;./ezFOV/Scripts/?/init.lua"

-- General pre-deploy sanity test:
-- 1) Parse-check every Lua file in ezFOV/Scripts
-- 2) Smoke-load core modules with minimal safe stubs

package.preload["UEHelpers"] = function()
	return {}
end

local function assert_compiles(path)
	local chunk, err = loadfile(path)
	assert(chunk ~= nil, "syntax check failed for " .. path .. ": " .. tostring(err))
end

local script_files = {
	"./ezFOV/Scripts/logging.lua",
	"./ezFOV/Scripts/heartbeat.lua",
	"./ezFOV/Scripts/playercontext.lua",
	"./ezFOV/Scripts/config.lua",
	"./ezFOV/Scripts/camera.lua",
	"./ezFOV/Scripts/stance.lua",
	"./ezFOV/Scripts/hooks.lua",
	"./ezFOV/Scripts/main.lua",
}

for _, path in ipairs(script_files) do
	assert_compiles(path)
end

local Logging = require("logging")
local Heartbeat = require("heartbeat")
local PlayerCtx = require("playercontext")
local Config = require("config")
local Camera = require("camera")
local Stance = require("stance")
local Hooks = require("hooks")

assert(type(Logging.log_debug) == "function", "logging module should expose log_debug")
assert(type(Heartbeat.pulse) == "function", "heartbeat module should expose pulse")
assert(type(PlayerCtx.get_snapshot) == "function", "playercontext module should expose get_snapshot")
assert(type(Config.get) == "function", "config module should expose get")
assert(type(Camera.begin_lockon_exit_blend) == "function", "camera module should expose begin_lockon_exit_blend")
assert(type(Stance.pulse) == "function", "stance module should expose pulse")
assert(type(Hooks.init) == "function", "hooks module should expose init")

local cfg = Config.get()
assert(cfg ~= nil, "config module should return a runtime config")
assert(type(cfg.LockOnExitBlendTime) == "number", "LockOnExitBlendTime should be a number")
assert(cfg.LockOnExitBlendTime > 0, "LockOnExitBlendTime should be positive")

print("module_sanity_test ok")
