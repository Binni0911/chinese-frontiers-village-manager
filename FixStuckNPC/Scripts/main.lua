-- FixStuckNPC
-- Finds an NPC that spawned under the map and moves it up next to you.
--   Numpad 7 = list what is under you (changes nothing)
--   Numpad 8 = bring the stuck NPC up in front of you

local SEARCH_RADIUS = 1500   -- how far sideways to look (1500 = 15 m)
local MIN_BELOW     = 300    -- only count things at least 3 m under you

local function Log(msg)
    print("[FixStuckNPC] " .. msg .. "\n")
end

local function GetPlayer()
    local pc = FindFirstOf("PlayerController")
    if pc and pc:IsValid() and pc.Pawn and pc.Pawn:IsValid() then
        return pc.Pawn
    end
    return nil
end

-- "BP_NPC_Daoshi_C /Game/...PersistentLevel.BP_NPC_Daoshi_C_3" -> class and short name
local function Names(obj)
    local full = obj:GetFullName()
    local class = full:match("^(%S+)") or "?"
    local short = full:match("([^%.:]+)$") or full
    return class, short, full
end

-- Everything of this class that is close sideways and well below you,
-- nearest first. Each entry: {actor, class, name, side, below}
local function FindBelow(className)
    local player = GetPlayer()
    if not player then
        Log("No player found.")
        return {}
    end
    local p = player:K2_GetActorLocation()
    local found = {}

    for _, a in ipairs(FindAllOf(className) or {}) do
        if a:IsValid() and a:GetAddress() ~= player:GetAddress() then
            local class, short, full = Names(a)
            -- skip the template objects, calling functions on them can crash
            if not full:find("Default__", 1, true) then
                local ok, l = pcall(function() return a:K2_GetActorLocation() end)
                if ok and l then
                    local dx, dy = l.X - p.X, l.Y - p.Y
                    local side  = math.sqrt(dx * dx + dy * dy)
                    local below = p.Z - l.Z
                    if side <= SEARCH_RADIUS and below >= MIN_BELOW then
                        found[#found + 1] = { actor = a, class = class, name = short,
                                              side = side, below = below }
                    end
                end
            end
        end
    end

    table.sort(found, function(x, y) return x.side < y.side end)
    return found
end

local function LooksLikeDaoshi(entry)
    local n = (entry.class .. " " .. entry.name):lower()
    return n:find("daoshi", 1, true) or n:find("taoist", 1, true) or n:find("priest", 1, true)
end

local function PrintList(list, label)
    Log(label .. ": " .. #list .. " found")
    for i, e in ipairs(list) do
        Log(string.format("  %d. %-40s %5.1f m sideways, %5.1f m below%s",
            i, e.name, e.side / 100, e.below / 100, LooksLikeDaoshi(e) and "   <- Daoshi?" or ""))
    end
end

local function ListBelow()
    local chars = FindBelow("Character")
    PrintList(chars, "Characters under you")
    if #chars == 0 then
        -- he might not be a Character, so look at everything
        PrintList(FindBelow("Actor"), "Other things under you")
    end
end

local function BringUp()
    local player = GetPlayer()
    if not player then
        Log("No player found.")
        return
    end

    -- pick a Character named like the Daoshi, otherwise the nearest Character under you
    local chars = FindBelow("Character")
    local target = nil
    for _, e in ipairs(chars) do
        if LooksLikeDaoshi(e) then target = e break end
    end
    target = target or chars[1]

    -- last try: any actor whose name looks like the Daoshi
    if not target then
        for _, e in ipairs(FindBelow("Actor")) do
            if LooksLikeDaoshi(e) then target = e break end
        end
    end

    if not target then
        Log("Nothing to move. Press Numpad 7 and send the list to Claude.")
        return
    end

    local p   = player:K2_GetActorLocation()
    local fwd = player:GetActorForwardVector()
    local dest = { X = p.X + fwd.X * 150, Y = p.Y + fwd.Y * 150, Z = p.Z + 50 }

    target.actor:K2_SetActorLocation(dest, false, {}, true)
    Log("Moved " .. target.name .. " up from " .. string.format("%.1f", target.below / 100) .. " m below.")
end

RegisterKeyBind(Key.NUM_SEVEN, function() ExecuteInGameThread(ListBelow) end)
RegisterKeyBind(Key.NUM_EIGHT, function() ExecuteInGameThread(BringUp) end)

Log("Loaded. Numpad 7 = list, Numpad 8 = bring up.")
