-- Shared validity guard for UE4SS-exposed objects, which can be mid-destruction on any
-- given frame. Treats a missing IsValid method as "assume valid" and swallows a failing
-- IsValid() call. Its own module so camera.lua and camera_originals.lua share one copy.
local UEObject = {}

function UEObject.is_valid(obj)
    if not obj then
        return false
    end
    if type(obj.IsValid) ~= "function" then
        return true
    end
    local ok, valid = pcall(function()
        return obj:IsValid()
    end)
    return ok and valid == true
end

return UEObject
