local M = {}

local _log_once_cache = {}

local function normalize_component(component)
    return component and tostring(component) or "Core"
end

function M.log_message(component, level, message, once_key, cache)
    local tag = normalize_component(component)
    local should_cache = cache == true and once_key ~= nil

    if should_cache then
        local cache_key = tag .. "::" .. tostring(once_key)
        if _log_once_cache[cache_key] then return end
        _log_once_cache[cache_key] = true
    end

    print("[ezFOV][" .. tag .. "][" .. tostring(level or "INFO") .. "] " .. tostring(message) .. "\n")
end

function M.log_warn(component, message, once_key, cache)
    M.log_message(component, "WARN", message, once_key, cache)
end

function M.log_error(component, message, once_key, cache)
    M.log_message(component, "ERROR", message, once_key, cache)
end

function M.log_debug(component, message, once_key, cache)
    M.log_message(component, "DEBUG", message, once_key, cache)
end

function M.clear_once_cache()
    _log_once_cache = {}
end

return M
