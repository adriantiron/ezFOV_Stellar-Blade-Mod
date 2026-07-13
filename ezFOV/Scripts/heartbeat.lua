local Logging = require("logging")
local Env = require("env").bind("Heartbeat")
local Easing = require("easing")

-- Cache hot-path function references to save a microscopic amount of CPU every frame.
local math_floor = math.floor
local now_ms = Easing.now_ms

-- Component-scoped logger (see Logging.for_component). warn is unused in this module.
local log = Logging.for_component("Heartbeat")

-- Floor for the self-re-arming watchdog interval. Prevents sub-frame re-scheduling right
-- at the drop boundary; also caps any added drop-detection latency to this value (~1 frame).
local WATCHDOG_MIN_CHECK_MS = 16

local Heartbeat = {
    disabled = true,
    cap = 3,
    enable_window_ms = 180,
    drop_ms = 200,

    _buf = {},
    _head = 1,
    _count = 0,
    _last_ms = 0,
    _watch_gen = 0,
    _watch_token = nil,
    _watch_armed = false,

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

-- Schedule the next watchdog liveness check `delay_ms` in the future. A generation counter
-- guards against a canceled/superseded timer that still fires (cancel_delay is best-effort).
function Heartbeat._arm_watchdog(delay_ms)
    Heartbeat._watch_gen = Heartbeat._watch_gen + 1
    local my = Heartbeat._watch_gen
    local token = Env.run_after_delay(delay_ms, "heartbeat_watchdog", function()
        Heartbeat._watch_token = nil
        if my ~= Heartbeat._watch_gen then
            return -- superseded by a re-arm/cancel; a newer timer owns detection
        end
        Heartbeat._on_watchdog()
    end)
    Heartbeat._watch_token = token
    -- If the host delay API was unavailable (nil token), leave _armed false so the next
    -- pulse() retries, matching the old per-frame reschedule's resilience.
    Heartbeat._watch_armed = (token ~= nil)
end

-- Single periodic liveness check. Re-arms while pulses are recent; stands the mod down and
-- lets the watchdog die when no pulse has arrived within drop_ms.
function Heartbeat._on_watchdog()
    local drop_ms = Heartbeat.drop_ms
    local since = now_ms() - (Heartbeat._last_ms or 0)

    if since < drop_ms then
        -- Still ticking. Re-arm for exactly the time remaining until the current last pulse
        -- would age past drop_ms, so drop detection fires at _last_ms + drop_ms -- the same
        -- instant the old per-frame debounce would have fired.
        local remaining = drop_ms - since
        if remaining < WATCHDOG_MIN_CHECK_MS then
            remaining = WATCHDOG_MIN_CHECK_MS
        end
        Heartbeat._arm_watchdog(remaining)
        return
    end

    -- Dropped: no pulse within drop_ms. Stand down and let the watchdog die; the next
    -- pulse() re-arms it when ticking resumes.
    Heartbeat._watch_armed = false
    if not Heartbeat.disabled then
        Heartbeat.disabled = true
        Heartbeat.on_disabled()
    end
    Heartbeat._reset_buf()
end

-- Cancel any in-flight watchdog and invalidate its generation.
function Heartbeat._cancel_watchdog()
    Heartbeat._watch_gen = Heartbeat._watch_gen + 1
    if Heartbeat._watch_token then
        Env.cancel_delay(Heartbeat._watch_token)
        Heartbeat._watch_token = nil
    end
    Heartbeat._watch_armed = false
end

function Heartbeat.pulse()
    if not Heartbeat or type(Heartbeat) ~= "table" then
        log.error("Heartbeat.pulse() called but Heartbeat table is invalid.")
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

    -- pulse() no longer schedules a fresh drop timer every frame; it just records the
    -- timestamp (via _push) and ensures the single self-re-arming watchdog is running.
    -- While alive the watchdog keeps itself armed, so this arms only after a drop.
    if not Heartbeat._watch_armed then
        Heartbeat._arm_watchdog(Heartbeat.drop_ms)
    end
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
    Heartbeat._cancel_watchdog()
    Heartbeat._reset_buf()
    Heartbeat.disabled = true
end

return Heartbeat
