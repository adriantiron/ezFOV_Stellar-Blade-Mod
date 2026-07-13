local M = {}

local _log_once_cache = {}
local _warn_cache_enabled = true
local _debug_cache_enabled = true

local function normalize_component(component)
    return component and tostring(component) or "Core"
end

function M.log_message(component, level, message, once_key, cache)
    local tag = normalize_component(component)
    local lvl = tostring(level or "INFO")
    local should_cache = cache == true and once_key ~= nil

    -- ERRORS are always emitted because they represent hard failure signals.

    -- Warn cache can be disabled at runtime for deeper troubleshooting sessions.
    if lvl == "WARN" and not _warn_cache_enabled then
        should_cache = false
    end

    -- Debug cache can be disabled at runtime for deep troubleshooting sessions.
    if lvl == "DEBUG" and not _debug_cache_enabled then
        should_cache = false
    end

    if should_cache then
        local cache_key = tag .. "::" .. tostring(once_key)
        if _log_once_cache[cache_key] then
            return
        end
        _log_once_cache[cache_key] = true
    end

    print("[ezFOV][" .. tag .. "][" .. lvl .. "] " .. tostring(message) .. "\n")
end

-- Errors are always emitted because they represent hard failure signals.
function M.log_error(component, message)
    M.log_message(component, "ERROR", message)
end

function M.log_warn(component, message, once_key, cache)
    M.log_message(component, "WARN", message, once_key, cache)
end

function M.log_debug(component, message, once_key, cache)
    M.log_message(component, "DEBUG", message, once_key, cache)
end

-- Returns a logger bound to a component name so callers don't repeat the tag.
-- Each function mirrors the matching M.log_* minus the leading component argument.
function M.for_component(component)
    return {
        error = function(message)
            M.log_error(component, message)
        end,
        warn = function(message, once_key, cache)
            M.log_warn(component, message, once_key, cache)
        end,
        debug = function(message, once_key, cache)
            M.log_debug(component, message, once_key, cache)
        end,
    }
end

function M.clear_once_cache()
    _log_once_cache = {}
end

function M.set_debug_cache_enabled(enabled)
    _debug_cache_enabled = (enabled ~= false)
end

function M.is_debug_cache_enabled()
    return _debug_cache_enabled
end

function M.set_warn_cache_enabled(enabled)
    _warn_cache_enabled = (enabled ~= false)
end

function M.is_warn_cache_enabled()
    return _warn_cache_enabled
end

return M
