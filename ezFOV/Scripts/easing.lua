-- Animation math & timing primitives shared by camera.lua's transition, enforcement,
-- and lock-on-exit blend loops. Deliberately pure and dependency-free so it can be
-- unit-tested in isolation.
local Easing = {}

local os_clock = os.clock

-- Quadratic ease-out interpolation.
--   t : elapsed time, b : begin value, c : change (end - begin), d : duration
-- Returns b at t == 0 and b + c at t == d. Guards against a zero duration.
function Easing.quadratic(t, b, c, d)
    if d == 0 then
        return b + c
    end
    t = t / d
    return -c * t * (t - 2) + b
end

-- Monotonic millisecond clock used to drive time-based eased animations.
function Easing.now_ms()
    return os_clock() * 1000.0
end

return Easing
