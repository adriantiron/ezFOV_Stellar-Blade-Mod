-- This caches the functions in memory, saving a microscopic amount of CPU every frame.
local os_clock = os.clock
local math_floor = math.floor

Heartbeat = {
    disabled = true,
    cap = 3,
    enable_window_ms = 180,
    drop_ms = 200,

    _buf = {}, _head = 1, _count = 0,
    _last_ms = 0,
    _drop_gen = 0,

    on_enabled = function() print("[HB] ENABLED\n") end,
    on_disabled = function() print("[HB] DISABLED\n") end,
}

local function now_ms()
    return os_clock() * 1000.0
end

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
    if Heartbeat._count < Heartbeat.cap then return nil end
    local idx = Heartbeat._head
    return Heartbeat._buf[idx]
end

function Heartbeat.pulse()
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

    ExecuteWithDelay(drop_ms, function()
        if my ~= Heartbeat._drop_gen then return end
        local since = now_ms() - (Heartbeat._last_ms or 0)
        if since < drop_ms - 1 then return end

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
    if type(n)=="number" and n>=3 and n<=12 then Heartbeat.cap = math_floor(n) end
    if type(win_ms)=="number" and win_ms>=40 and win_ms<=200 then Heartbeat.enable_window_ms = math_floor(win_ms) end
    if type(drop_ms)=="number" and drop_ms>=120 and drop_ms<=1000 then Heartbeat.drop_ms = math_floor(drop_ms) end
    Heartbeat._reset_buf()
    Heartbeat.disabled = true
end

return Heartbeat