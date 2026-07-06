local Logging = require("logging")

local Env = {
    ExecuteInGameThread = rawget(_G, "ExecuteInGameThread"),
    ExecuteWithDelay = rawget(_G, "ExecuteWithDelay"),
    CancelDelay = rawget(_G, "CancelDelay"),
    RegisterKeyBindAsync = rawget(_G, "RegisterKeyBindAsync"),
    RegisterHook = rawget(_G, "RegisterHook"),
    UnregisterHook = rawget(_G, "UnregisterHook"),
    Key = rawget(_G, "Key"),
    ModifierKey = rawget(_G, "ModifierKey"),
}

local debug_traceback = debug and debug.traceback

local function log_error(component, message, once_key)
    Logging.log_error(component, message, once_key, true)
end

local function format_error_with_trace(err)
    if type(debug_traceback) == "function" then
        return tostring(debug_traceback(tostring(err), 2))
    end
    return tostring(err)
end

local function run_guarded(component, context, kind, fn)
    local ok, err = xpcall(fn, function(e)
        return format_error_with_trace(e)
    end)
    if not ok then
        log_error(component, context .. " failed: " .. tostring(err), context .. "_" .. kind .. "_error")
        return false
    end
    return true
end

function Env.run_now(component, context, fn)
    return run_guarded(component, context, "immediate", fn)
end

function Env.run_on_game_thread(component, context, fn)
    local execute = Env.ExecuteInGameThread
    if type(execute) ~= "function" then
        log_error(component, context .. " failed because ExecuteInGameThread is unavailable.", context .. "_missing_thread_api")
        return
    end

    execute(function()
        run_guarded(component, context, "thread", fn)
    end)
end

function Env.run_after_delay(component, delay_ms, context, fn)
    local execute = Env.ExecuteWithDelay
    if type(execute) ~= "function" then
        log_error(component, context .. " failed because ExecuteWithDelay is unavailable.", context .. "_missing_delay_api")
        return nil
    end

    return execute(delay_ms, function()
        run_guarded(component, context, "delay", fn)
    end)
end

function Env.register_safe_keybind(component, key, modifiers, label, fn)
    local register = Env.RegisterKeyBindAsync
    if type(register) ~= "function" then
        log_error(component, "Keybind registration skipped because RegisterKeyBindAsync is unavailable.", "keybind_register_missing_api")
        return
    end

    register(key, modifiers, function()
        run_guarded(component, label, "keybind", fn)
    end)
end

function Env.safe_register_hook(component, func_path, pre_cb, post_cb)
    local register = Env.RegisterHook
    if not register then
        log_error(component, "RegisterHook API is unavailable.", "hooks_registerhook_missing")
        return nil, nil
    end

    if type(func_path) ~= "string" or func_path == "" then
        log_error(component, "RegisterHook skipped because the function path was invalid.", "hooks_registerhook_invalid_path")
        return nil, nil
    end

    if type(pre_cb) ~= "function" then
        log_error(component, "RegisterHook skipped because the pre-callback was invalid.", "hooks_registerhook_invalid_pre_cb")
        return nil, nil
    end

    if post_cb ~= nil and type(post_cb) ~= "function" then
        log_error(component, "RegisterHook skipped because the post-callback was invalid.", "hooks_registerhook_invalid_post_cb")
        return nil, nil
    end

    local pre_id, post_id
    local ok = run_guarded(component, "hooks_registerhook", "hook", function()
        pre_id, post_id = register(func_path, pre_cb, post_cb)
    end)
    if not ok then
        return nil, nil
    end

    return pre_id, post_id
end

function Env.safe_unregister_hook(component, entry)
    local unregister = Env.UnregisterHook
    if not entry or not unregister then return end
    if entry.pre_id ~= nil or entry.post_id ~= nil then
        run_guarded(component, "hooks_unregisterhook", "hook", function()
            unregister(entry.path, entry.pre_id, entry.post_id)
        end)
    end
    entry.pre_id = nil
    entry.post_id = nil
end

function Env.bind(component)
    local scope = component or "Core"
    return {
        ExecuteInGameThread = Env.ExecuteInGameThread,
        ExecuteWithDelay = Env.ExecuteWithDelay,
        CancelDelay = Env.CancelDelay,
        RegisterKeyBindAsync = Env.RegisterKeyBindAsync,
        RegisterHook = Env.RegisterHook,
        UnregisterHook = Env.UnregisterHook,
        Key = Env.Key,
        ModifierKey = Env.ModifierKey,
        run_on_game_thread = function(context, fn)
            return Env.run_on_game_thread(scope, context, fn)
        end,
        run_after_delay = function(delay_ms, context, fn)
            return Env.run_after_delay(scope, delay_ms, context, fn)
        end,
        run_now = function(context, fn)
            return Env.run_now(scope, context, fn)
        end,
        register_safe_keybind = function(key, modifiers, label, fn)
            return Env.register_safe_keybind(scope, key, modifiers, label, fn)
        end,
        safe_register_hook = function(func_path, pre_cb, post_cb)
            return Env.safe_register_hook(scope, func_path, pre_cb, post_cb)
        end,
        safe_unregister_hook = function(entry)
            return Env.safe_unregister_hook(scope, entry)
        end,
    }
end

return Env