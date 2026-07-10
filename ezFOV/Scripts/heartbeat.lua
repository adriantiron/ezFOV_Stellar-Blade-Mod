local Logging = require("logging")
local Env = require("env").bind("Heartbeat")
local Easing = require("easing")

-- Cache hot-path function references to save a microscopic amount of CPU every frame.
local math_floor = math.floor
local now_ms = Easing.now_ms

-- Component-scoped logger (see Logging.for_component). warn is unused in this module.
local log = Logging.for_component("Heartbeat")

local Heartbeat = {
    disabled = true,
    cap = 3,
    enable_window_ms = 180,
    drop_ms = 200,

    _buf = {},
    _head = 1,
    _count = 0,
    _last_ms = 0,
    _drop_gen = 0,
    _drop_token = nil,

    on_enabled = function()
        log.debug("Heartbeat enabled", "heartbeat_enabled")
    end,
    on_disabled = function()
        log.debug("Heartbeat disabled", "heartbeat_disabled")
    end,
}

function Heartbeat._reset_buf()
    Heartbeat._buf = {}
    Heartbeat._head = 1
    Heartbeat._count = 0
end

function Heartbeat._push(ms)
    local i = Heartbeat._head
    Heartbeat._buf[i] = ms
    Heartbeat._head = (i % Heartbeat.cap) + 1
    if Heartbeat._count < Heartbeat.cap then
        Heartbeat._count = Heartbeat._count + 1
    end
    Heartbeat._last_ms = ms
end

function Heartbeat._oldest()
    if Heartbeat._count < Heartbeat.cap then
        return nil
    end
    local idx = Heartbeat._head
    return Heartbeat._buf[idx]
end

function Heartbeat.pulse()
    if not Heartbeat or type(Heartbeat) ~= "table" then
        log.error("Heartbeat.pulse() called but Heartbeat table is invalid.", "heartbeat_invalid")
        return
    end

    local t = now_ms()
    Heartbeat._push(t)

    if Heartbeat.disabled and Heartbeat._count == Heartbeat.cap then
        local oldest = Heartbeat._oldest()
        if oldest and (t - oldest) <= Heartbeat.enable_window_ms then
            Heartbeat.disabled = false
            Heartbeat.on_enabled()
        end
    end

    Heartbeat._drop_gen = Heartbeat._drop_gen + 1
    local my = Heartbeat._drop_gen
    local drop_ms = Heartbeat.drop_ms

    if Heartbeat._drop_token then
        Env.CancelDelay(Heartbeat._drop_token)
        Heartbeat._drop_token = nil
    end

    Heartbeat._drop_token = Env.run_after_delay(drop_ms, "heartbeat_drop", function()
        Heartbeat._drop_token = nil
        if my ~= Heartbeat._drop_gen then
            return
        end
        local since = now_ms() - (Heartbeat._last_ms or 0)
        if since < drop_ms - 1 then
            return
        end

        if not Heartbeat.disabled then
            Heartbeat.disabled = true
            Heartbeat.on_disabled()
        end
        Heartbeat._reset_buf()
    end)
end

function Heartbeat.is_disabled()
    return Heartbeat.disabled
end

function Heartbeat.set_thresholds(n, win_ms, drop_ms)
    if type(n) == "number" and n >= 3 and n <= 12 then
        Heartbeat.cap = math_floor(n)
    end
    if type(win_ms) == "number" and win_ms >= 40 and win_ms <= 200 then
        Heartbeat.enable_window_ms = math_floor(win_ms)
    end
    if type(drop_ms) == "number" and drop_ms >= 120 and drop_ms <= 1000 then
        Heartbeat.drop_ms = math_floor(drop_ms)
    end
    if Heartbeat._drop_token then
        Env.CancelDelay(Heartbeat._drop_token)
        Heartbeat._drop_token = nil
    end
    Heartbeat._reset_buf()
    Heartbeat.disabled = true
end

return Heartbeat
