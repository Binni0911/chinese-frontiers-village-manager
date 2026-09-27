--[[
    VillageManager - Chinese Frontiers (UE4SS Lua mod)

    Keeps the village stocked by adjusting the same job percentages you can
    set yourself in Village Management. It never creates items: workers still
    need their materials, tools and food.

    How it decides, every run:
      1. Read stock (warehouse chest + material piles, and the caravan).
      2. Compare against targets.txt and work out what is needed.
      3. Pass the need down the recipe chain (Dougong -> Brace -> Wedge ...).
      4. Turn the needs into percentages for each managed station.
      5. Farm: stop crops that have enough, feed the ones that are short,
         keep food above the reserve.

    Keys (all output goes to the UE4SS console):
      Numpad 1  show the plan (changes nothing)
      Numpad 2  apply the plan once
      Numpad 3  auto mode on/off (applies every 2 minutes)
      Numpad 4  show caravan contents
      F6        learn job names + recipes from the open Village Management screen
      F7        show material piles (logs, stone blocks, bricks, tiles)
      F8        show warehouse chest contents

    Files next to the Scripts folder:
      targets.txt    what to keep in stock (edit this one)
      job_names.txt  job ids, names and ingredients (filled by F6)
      stacks.txt     remembered stack sizes (filled automatically)
]]

------------------------------------------------------------------------
-- 1. SETTINGS
------------------------------------------------------------------------
local AUTO_INTERVAL_MS  = 120000   -- auto mode runs every 2 minutes
local INGREDIENT_BUFFER = 150      -- keep at least this many of each ingredient in the warehouse
local MIN_SHARE         = 0.05     -- smallest share for a job that is needed (5%)
local WARNING_MEMORY_S  = 180      -- how long a "missing tools" warning counts (seconds)
local FARM_PLACE, FARM_STATION, RICE_JOB = 11, 21, 58

-- Stations the manager may change: { workplace, station }
local MANAGED = {
    {8, 9}, {8, 10}, {8, 8},                                   -- carpentry, logs
    {9, 13}, {9, 14},                                          -- tools & refining, stone blocks
    {10, 11}, {10, 12},                                        -- bricks & tiles, mortar
    {6, 17},                                                   -- kitchen
    {3, 1}, {3, 2}, {3, 3}, {3, 4}, {3, 5}, {3, 6}, {3, 7},    -- gatherers
    {7, 15}, {7, 16},                                          -- paint kits, paper
}

-- Pile items are stored in material piles, not in the chest
local PILE_KEY = {
    ["Log"] = "LogSpawner", ["Stone Blocks"] = "StoneSpawner",
    ["Clay Brick"] = "RedBrickSpawner", ["Roof Tiles"] = "CeramicTilesSpawner",
}

-- Which tool each gathering job uses (job id -> tool name)
local TOOL_FOR_JOB = {
    [1] = "Stone Hatchet", [5] = "Stone Hatchet",   -- wood, bamboo
    [3] = "Stone Shovel",  [6] = "Stone Shovel",    -- clay, sand
    [4] = "Stone Pickaxe", [7] = "Stone Pickaxe",   -- limestone, stone
}

-- What counts as food for the food reserve
local FOOD_ITEMS = { "Rice", "Fish", "Pork", "Chicken Meat", "Egg" }

-- Item row names whose display name can't be guessed from the row name
local ROW_ALIAS = {
    Component_WoodPole = "Wooden Pole", Component_Lime = "Limestone",
    Food_Ingredient_Flour = "Rice Flour", Food_Ingredient_Sichuan = "Sichuan Pepper",
    Food_Ingredient_Chicken = "Chicken Meat", Food_Ingredient_WoodEar = "Wood Ear Mushroom",
    Food_Ingredient_Lotus = "Lotus Root", Food_Ingredient_BayLeaf = "Bay Leaf",
    Decoration_BrownKanpweedFlower = "Indigo", Decoration_CarnationFlower = "Gromwell",
    Decoration_GardenCosmosFlower = "Rubia", Decoration_MarigoldFlower = "Curcuma",
    Component_DecorationPaintKit = "Artisan's Paint Kit",
    Component_BuildersPaintKit = "Builder's Paint Kit",
}

------------------------------------------------------------------------
-- 2. SMALL HELPERS
------------------------------------------------------------------------
local function Log(msg) print("[VillageManager] " .. tostring(msg) .. "\n") end
local function Trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function Norm(s) return (s:lower():gsub("[^a-z]", "")) end   -- "Bay Leaf" -> "bayleaf"
local function Pct(x) return string.format("%d%%", math.floor((x or 0) * 100 + 0.5)) end

local scriptDir = debug.getinfo(1, "S").source:match("^@(.*[\\/])") or ""
local FILES = {
    names   = scriptDir .. "..\\job_names.txt",
    targets = scriptDir .. "..\\targets.txt",
    stacks  = scriptDir .. "..\\stacks.txt",
}

------------------------------------------------------------------------
-- 3. GAME FIELD NAMES
-- Struct fields in this game carry ID suffixes. These come from the
-- UE4SS header dump. If a game patch breaks the mod, re-dump and check these.
------------------------------------------------------------------------
local F = {   -- workstation / job state
    StationIDs    = "WorkStationsID_16_038795414E200FE36FBA18B5E36A28A3",
    StationStates = "WorkStationsStates_18_DDB65DE14D2C24B73F4D6F9A1F061F88",
    Recipes       = "Recipes_34_4BE92CAD49DABB872178398069156C73",
    Force         = "Force_12_4BE92CAD49DABB872178398069156C73",
}
local ECON_FIELD = "Economy_35_3D2230474EB2029A912FF6AA202323FD"
local ITEM = {   -- one slot in a container
    Handle   = "ItemHandle_60_EFC3446F4BEB3A00026CE2A9EAC341F7",
    Amount   = "Amount_63_A266101D46331E1C405B5BBCCD66B5AB",
    Name     = "Name_6_4BDAD3B24B564228353D28A42C703448",
    MaxStack = "MaxStack_17_A4F940864DC6C3A24983778907BB130E",
}

------------------------------------------------------------------------
-- 4. FINDING GAME OBJECTS
------------------------------------------------------------------------
-- The live village controller (not the class template)
local function GetNpcController()
    for _, c in ipairs(FindAllOf("BP_NPC_Controller_C") or {}) do
        local n = c:IsValid() and c:GetFullName() or ""
        if n ~= "" and not n:find("Default__", 1, true) and not n:find("GEN_VARIABLE", 1, true) then
            return c
        end
    end
    return nil
end

-- The live storage component (holds the material piles)
local function GetStorage()
    for _, s in ipairs(FindAllOf("BP_NPC_Storage_Component_C") or {}) do
        if s:IsValid() and s:GetFullName():find("PersistentLevel", 1, true) then return s end
    end
    return nil
end

-- The warehouse chest the villagers use
local function GetStorageChest()
    for _, c in ipairs(FindAllOf("BP_ContainerComponent_C") or {}) do
        local n = c:IsValid() and c:GetFullName() or ""
        if n:find("PersistentLevel.BP_PlayerController", 1, true) and n:find("NPC_StorageChest", 1, true) then
            return c
        end
    end
    return nil
end

-- Every caravan container that is loaded
local function GetCaravans()
    local found = {}
    for _, c in ipairs(FindAllOf("BP_ContainerComponent_C") or {}) do
        if c:IsValid() then
            local n = c:GetFullName():lower()
            if n:find("%.caravanchestcontainer$") and not n:find("default__", 1, true) then found[#found + 1] = c end
        end
    end
    return found
end

-- One station's state inside the controller
local function FindStationState(c, placeWanted, stationWanted)
    local placeIDs, found = c["Workplace id's"], nil
    c.WorkplaceStations:ForEach(function(pi, placeElem)
        if found or placeIDs[pi] ~= placeWanted then return end
        local place = placeElem:get()
        local ids = place[F.StationIDs]
        place[F.StationStates]:ForEach(function(si, stElem)
            if not found and ids[si] == stationWanted then found = stElem:get() end
        end)
    end)
    return found
end

------------------------------------------------------------------------
-- 5. DATA FILES
------------------------------------------------------------------------
-- job_names.txt lines:  workplace|station|jobId|name|needs
local function LoadJobFile()
    local names = {}
    local f = io.open(FILES.names, "r")
    if not f then return names end
    for line in f:lines() do
        line = line:gsub("\r$", "")   -- tolerate Windows line endings
        local place, station, job, name, needs = line:match("^(%d+)|(%d+)|(%d+)|([^|]*)|?(.*)$")
        if job then names[job] = { place = place, station = station, name = name, needs = needs } end
    end
    f:close()
    return names
end

local jobNameCache = nil   -- cleared whenever job_names.txt is saved

local function SaveJobFile(names)
    local f = io.open(FILES.names, "w")
    if not f then Log("Could not write " .. FILES.names) return end
    local ids = {}
    for job in pairs(names) do ids[#ids + 1] = tonumber(job) end
    table.sort(ids)
    for _, job in ipairs(ids) do
        local e = names[tostring(job)]
        f:write(string.format("%s|%s|%d|%s|%s\n", e.place, e.station, job, e.name, e.needs or ""))
    end
    f:close()
    jobNameCache = nil
end

local function JobName(id)
    if not jobNameCache then
        jobNameCache = {}
        local ok, names = pcall(LoadJobFile)
        if ok then for job, e in pairs(names) do jobNameCache[job] = e.name end end
    end
    return jobNameCache[tostring(id)] or ("job " .. tostring(id))
end

-- targets.txt lines:
--   Name = 5            keep at least 5
--   Name = 2 stacks     keep at least two full stacks
--   Name = 3000, 2500   stop at 3000, start again at 2500
local function LoadTargets()
    local t = {}
    local f = io.open(FILES.targets, "r")
    if not f then Log("targets.txt not found") return t end
    for line in f:lines() do
        line = line:gsub("\r$", "")   -- tolerate Windows line endings
        line = line:gsub("#.*$", "")
        local sname, sn = line:match("^%s*(.-)%s*=%s*(%d+)%s*[Ss]tacks?%s*$")
        local name, a, b = line:match("^%s*(.-)%s*=%s*(%d+)%s*,?%s*(%d*)%s*$")
        if sname and sname ~= "" then
            t[Trim(sname)] = { stacks = tonumber(sn), amount = 0 }
        elseif name and name ~= "" then
            t[Trim(name)] = { amount = tonumber(a), resume = tonumber(b) }
        end
    end
    f:close()
    return t
end

-- stacks.txt remembers each item's stack size, so "1 stack" works even at 0 stock
local stackCache, stackCacheLoaded, stackCacheDirty = {}, false, false

local function LoadStackCache()
    if stackCacheLoaded then return end
    stackCacheLoaded = true
    local f = io.open(FILES.stacks, "r")
    if not f then return end
    for line in f:lines() do
        line = line:gsub("\r$", "")   -- tolerate Windows line endings
        local name, size = line:match("^(.-)=(%d+)$")
        if name then stackCache[name] = tonumber(size) end
    end
    f:close()
end

local function SaveStackCache()
    if not stackCacheDirty then return end
    local f = io.open(FILES.stacks, "w")
    if not f then return end
    for name, size in pairs(stackCache) do f:write(name .. "=" .. size .. "\n") end
    f:close()
    stackCacheDirty = false
end

local function LearnStack(name, size)
    LoadStackCache()
    local key = Norm(name)
    if stackCache[key] ~= size then stackCache[key] = size; stackCacheDirty = true end
end

local function StackSize(name)
    LoadStackCache()
    return stackCache[Norm(name)]
end

-- Turn "N stacks" targets into amounts
local function ResolveStackTargets(targets, report)
    for name, t in pairs(targets) do
        if t.stacks then
            local size = StackSize(name)
            if not size then
                size = 100
                report[#report + 1] = "   ? stack size of '" .. name .. "' not known yet, assuming 100"
            end
            t.amount = t.stacks * size
        end
    end
end

------------------------------------------------------------------------
-- 6. RECIPES AND ITEM NAMES
------------------------------------------------------------------------
-- jobs[id] = {name, place, station, needs = {rowName,...}}
-- jobByName[norm name] = id  (farm jobs "Rice & Rice Seed" answer to both names)
local function LoadRecipes()
    local jobs, jobByName = {}, {}
    for id, e in pairs(LoadJobFile()) do
        local jid = tonumber(id)
        local name = Trim(e.name or "")
        local needs = {}
        for row in (e.needs or ""):gmatch("item:([^=,]+)=") do needs[#needs + 1] = row end
        jobs[jid] = { name = name, place = tonumber(e.place), station = tonumber(e.station), needs = needs }
        for part in (name .. " & "):gmatch("(.-) & ") do jobByName[Norm(part)] = jid end
        jobByName[Norm(name)] = jid
    end
    return jobs, jobByName
end

local function IsFarmJob(job)
    return job and job.place == FARM_PLACE and job.station == FARM_STATION
end

-- Item row name -> the name the game shows
local rowNameCache = {}
local function RowToName(row)
    if rowNameCache[row] then return rowNameCache[row] end
    if ROW_ALIAS[row] then return ROW_ALIAS[row] end
    local seed = row:match("^Usable_FarmingSeed_(.+)$")
    if seed then return seed .. " Seed" end
    local s = row:gsub("^Component_", ""):gsub("^Food_Ingredient_", ""):gsub("^Decoration_", "")
    s = s:gsub("^Tool_ImprovedStone", "Stone "):gsub("^Tool_", "")
    return (s:gsub("(%l)(%u)", "%1 %2"))
end

------------------------------------------------------------------------
-- 7. READING STOCK
------------------------------------------------------------------------
-- Adds one container into stock[row] = {name, amount, max}. Returns used and total slots.
local function ReadContainer(container, stock)
    local used, total = 0, 0
    container.Items:ForEach(function(_, elem)
        total = total + 1
        local it = elem:get()
        local amount = it[ITEM.Amount]
        local row = it[ITEM.Handle].RowName:ToString()
        if amount and amount > 0 and row ~= "None" then   -- empty slots show up as "None"
            used = used + 1
            local e = stock[row] or { name = it[ITEM.Name]:ToString(), amount = 0, max = it[ITEM.MaxStack] }
            e.amount = e.amount + amount
            stock[row] = e
        end
    end)
    return used, total
end

local function ReadChestStock()
    local chest = GetStorageChest()
    if not chest then return nil end
    local stock = {}
    local used, total = ReadContainer(chest, stock)
    return stock, used, total
end

local function ReadCaravanStock()
    local stock, used, total = {}, 0, 0
    for _, c in ipairs(GetCaravans()) do
        local ok, u, t = pcall(ReadContainer, c, stock)
        if ok then used = used + u; total = total + t end
    end
    return stock, used, total
end

-- have    = what workers can use (warehouse chest + piles), by normalized name
-- haveAll = have + caravan (used for targets and caps)
local function ReadAllStock()
    local stock, used, total = ReadChestStock()
    if not stock then return nil end
    local have, haveAll = {}, {}
    for row, e in pairs(stock) do
        rowNameCache[row] = e.name
        if e.max and e.max > 0 then LearnStack(e.name, e.max) end
        have[Norm(e.name)] = (have[Norm(e.name)] or 0) + e.amount
    end
    local s = GetStorage()
    if s then
        pcall(function()
            s.MaterialPilesInventory:ForEach(function(k, v)
                local key = k:get():ToString()
                for name, pileKey in pairs(PILE_KEY) do
                    if pileKey == key then have[Norm(name)] = v:get() end
                end
            end)
        end)
    end
    for k, v in pairs(have) do haveAll[k] = v end
    local ok, caravan = pcall(ReadCaravanStock)
    if ok and caravan then
        for _, e in pairs(caravan) do
            if e.max and e.max > 0 then LearnStack(e.name, e.max) end
            haveAll[Norm(e.name)] = (haveAll[Norm(e.name)] or 0) + e.amount
        end
    end
    SaveStackCache()
    return have, haveAll, used, total
end

------------------------------------------------------------------------
-- 8. READING AND WRITING JOB PERCENTAGES
------------------------------------------------------------------------
local function ReadForces(st)
    local current = {}
    st[F.Recipes]:ForEach(function(k, v) current[k:get()] = v:get()[F.Force] end)
    return current
end

-- Writes new Force values into a recipes map
local function WriteForces(recipes, changes)
    recipes:ForEach(function(k, v)
        local job = k:get()
        if changes[job] ~= nil then v:get()[F.Force] = changes[job] end
    end)
end

-- Write to both copies: the one the menu shows and the one the workers use
local function ApplyForces(st, new)
    WriteForces(st[F.Recipes], new)
    local econ = st[ECON_FIELD]
    if econ and econ:IsValid() then WriteForces(econ.Workstation_ref[F.Recipes], new) end
end

------------------------------------------------------------------------
-- 9. WARNING LISTENER
-- Hooks the game's own warning functions. Prints each warning at most
-- once a minute and remembers them for the manager.
------------------------------------------------------------------------
local WARNINGS = {
    NotEnoughResourcesWarning = "missing ingredients",
    NotEnoughToolWarning      = "missing tools",
    FullStorageWarning        = "storage full",
}
local recentWarn = {}   -- "Function:jobId" -> time last seen
local lastPrinted = {}
local hooksDone = false

local function TryAttachWarningHooks()
    if hooksDone then return true end
    local econ = FindFirstOf("BP_NPC_Economy_Work_C")
    if not econ or not econ:IsValid() then return false end
    local classPath = econ:GetClass():GetFullName():gsub("^%S+%s+", "")
    for fn, label in pairs(WARNINGS) do
        local ok, err = pcall(function()
            RegisterHook(classPath .. ":" .. fn, function(_, jobID)
                local id = jobID:get()
                local key = fn .. ":" .. tostring(id)
                local now = os.time()
                recentWarn[key] = now
                if lastPrinted[key] and now - lastPrinted[key] < 60 then return end
                lastPrinted[key] = now
                Log(string.format("WARNING  %-22s -> %s", label, JobName(id)))
            end)
        end)
        if not ok then Log("Could not hook " .. fn .. ": " .. tostring(err)) end
    end
    hooksDone = true
    Log("Warning listener attached.")
    return true
end

------------------------------------------------------------------------
-- 10. MANAGER: WHAT IS NEEDED
------------------------------------------------------------------------
local pileStopped = {}   -- capped item -> true while stopped at its cap

-- demand[job] = urgency (0.2 .. 1.0), reason[job] = text for the plan
local function BuildDemand(targets, jobByName, haveAll, report)
    local demand, reason = {}, {}
    local function add(job, d, why)
        if job and d > (demand[job] or 0) then demand[job] = d; reason[job] = why end
    end

    -- targets.txt
    for name, t in pairs(targets) do
        if name ~= "Food Reserve" then
            local job = jobByName[Norm(name)]
            local amount = haveAll[Norm(name)] or 0
            if not job then
                report[#report + 1] = "   ? no job found for target '" .. name .. "'"
            elseif t.resume then
                -- capped item: stop at the cap, restart at the resume level
                if amount >= t.amount then pileStopped[name] = true end
                if amount <= t.resume then pileStopped[name] = nil end
                if not pileStopped[name] then add(job, 0.5, string.format("%s %d/%d", name, amount, t.amount)) end
            elseif amount < t.amount then
                add(job, 0.2 + 0.8 * (t.amount - amount) / t.amount,
                    string.format("%s %d/%d", name, amount, t.amount))
            end
        end
    end

    -- tools that gatherers reported missing recently
    local now = os.time()
    for key, when in pairs(recentWarn) do
        local fn, id = key:match("^(.-):(%d+)$")
        if fn == "NotEnoughToolWarning" and now - when < WARNING_MEMORY_S then
            local tool = TOOL_FOR_JOB[tonumber(id)]
            if tool then add(jobByName[Norm(tool)], 1.0, tool .. " (workers are waiting for it)") end
        end
    end
    return demand, reason
end

-- Pushes demand down to ingredients that run low (up to 4 steps deep).
-- Fills: farmNeeds[crop] = dish, blocked[job] = missing ingredient,
--        moveAdvice[item] = {caravan, warehouse}
local function PropagateDemand(demand, reason, jobs, jobByName, have, haveAll, farmNeeds, blocked, moveAdvice)
    local queue = {}
    for job in pairs(demand) do queue[#queue + 1] = { job = job, depth = 0 } end
    local i = 1
    while i <= #queue do
        local cur = queue[i]; i = i + 1
        local j = jobs[cur.job]
        if j and cur.depth < 4 then
            for _, row in ipairs(j.needs) do
                local ingName = RowToName(row)
                local amount = have[Norm(ingName)] or 0
                local inCaravan = (haveAll[Norm(ingName)] or 0) - amount
                if amount < INGREDIENT_BUFFER and inCaravan >= INGREDIENT_BUFFER then
                    -- plenty in the caravan: ask the player to move it instead of making more
                    moveAdvice[ingName] = { caravan = inCaravan, warehouse = amount }
                elseif amount < INGREDIENT_BUFFER then
                    local producer = jobByName[Norm(ingName)]
                    local pj = producer and jobs[producer]
                    if amount == 0 and (not producer or IsFarmJob(pj)) then
                        blocked[cur.job] = ingName   -- nothing to make it from right now
                    end
                    if producer and producer ~= cur.job then
                        if IsFarmJob(pj) then
                            farmNeeds[ingName] = j.name   -- farm rules handle this
                        else
                            local d = demand[cur.job] * 0.9
                            if d > (demand[producer] or 0) then
                                demand[producer] = d
                                reason[producer] = string.format("%s for %s (have %d)", ingName, j.name, amount)
                                queue[#queue + 1] = { job = producer, depth = cur.depth + 1 }
                            end
                        end
                    end
                end
            end
        end
    end
end

------------------------------------------------------------------------
-- 11. MANAGER: PERCENTAGES PER STATION
------------------------------------------------------------------------
-- Turns demand weights into 5% steps that add up to 100%
local function SnapShares(want)
    local total = 0
    for _, w in pairs(want) do total = total + w end
    local shares, sum = {}, 0
    for job, w in pairs(want) do
        shares[job] = math.max(MIN_SHARE, math.floor(w / total / 0.05 + 0.5) * 0.05)
        sum = sum + shares[job]
    end
    for _ = 1, 40 do
        if math.abs(sum - 1) < 0.001 then break end
        local best = nil
        for job, s in pairs(shares) do
            if sum > 1 then
                if s > MIN_SHARE + 0.001 and (not best or s > shares[best]) then best = job end
            elseif not best or want[job] > want[best] then best = job end
        end
        if not best then break end
        local step = (sum > 1) and -0.05 or 0.05
        shares[best] = shares[best] + step
        sum = sum + step
    end
    for job, s in pairs(shares) do shares[job] = math.floor(s * 100 + 0.5) / 100 end
    return shares
end

-- New percentages for one station, or nil if nothing changes.
-- A station where nothing is needed is paused (all 0%).
local function PlanStation(c, place, station, demand)
    local st = FindStationState(c, place, station)
    if not st then return nil end
    local current = ReadForces(st)
    local want = {}
    for job in pairs(current) do
        if demand[job] then want[job] = demand[job] end
    end
    local new = {}
    local shares = next(want) and SnapShares(want) or {}
    for job in pairs(current) do new[job] = shares[job] or 0 end
    for job, f in pairs(new) do
        if math.abs(f - (current[job] or 0)) > 0.01 then return st, new, current end
    end
    return nil
end

------------------------------------------------------------------------
-- 12. MANAGER: FARM
--  1) never keep farmers on a crop with no seeds (share goes to rice)
--  2) food below the reserve: move up to 20% back to rice until it recovers
--  3) rice over its cap: rice down to 10%, rest shared by the other crops
--  4) crops with enough stop; their share goes to crops still short,
--     then to crops the kitchen needs, then rice (or idle if rice is full)
------------------------------------------------------------------------
local foodLow, riceHigh = false, false

local function FoodStatus(have, c)
    local total = 0
    for _, n in ipairs(FOOD_ITEMS) do total = total + (have[Norm(n)] or 0) end
    local enough, stopped = true, 0
    pcall(function()
        local fc = c.EconomyFoodController
        if fc and fc:IsValid() then
            enough = fc.IsEnoughFood
            stopped = fc["StoppedNPC's"]:GetArrayNum()
        end
    end)
    return total, enough, stopped
end

local function CropOf(job)   -- "Rice & Rice Seed" -> "Rice", "Rice Seed"
    if not job then return nil end
    return job.name:match("^(.-) & "), job.name:match("& (.+)$")
end

local function PlanFarm(c, jobs, have, haveAll, targets, farmNeeds, lines)
    local st = FindStationState(c, FARM_PLACE, FARM_STATION)
    if not st then return nil end
    local current, new, moved = ReadForces(st), {}, 0
    for job, f in pairs(current) do new[job] = f end

    -- 1) seed guard
    for job, force in pairs(current) do
        local _, seedName = CropOf(jobs[job])
        if force > 0.001 and job ~= RICE_JOB and seedName and (have[Norm(seedName)] or 0) == 0 then
            new[job] = 0
            moved = moved + force
            lines[#lines + 1] = string.format("   Farm: %s %s -> 0%% (no %s left)", jobs[job].name, Pct(force), seedName)
        end
    end

    -- 2) food reserve
    local total, enough, stopped = FoodStatus(have, c)
    lines[#lines + 1] = string.format("   Food: %d in stock, village says %s, %d worker(s) stopped for hunger",
        total, enough and "enough" or "NOT ENOUGH", stopped)
    local reserve = targets["Food Reserve"]
    if reserve then
        if total < reserve.amount or not enough or stopped > 0 then foodLow = true end
        if total >= (reserve.resume or reserve.amount) and enough and stopped == 0 then foodLow = false end
        if foodLow then
            for job, f in pairs(new) do
                if job ~= RICE_JOB and moved < 0.2 and f > 0.05 then
                    local take = math.min(f - 0.05, 0.2 - moved)
                    new[job] = f - take
                    moved = moved + take
                end
            end
            lines[#lines + 1] = "   Food is below the reserve - moving farm work to rice"
        end
    end
    new[RICE_JOB] = math.min(1, (current[RICE_JOB] or 0) + moved)

    -- 3) rice cap
    local riceCap = targets["Rice"]
    if riceCap and not foodLow then
        local rice = have[Norm("Rice")] or 0
        if rice >= riceCap.amount then riceHigh = true end
        if rice <= (riceCap.resume or riceCap.amount) then riceHigh = false end
        if riceHigh and new[RICE_JOB] > 0.101 then
            local others = {}
            for job, f in pairs(new) do
                if job ~= RICE_JOB and f > 0.001 then others[#others + 1] = job end
            end
            if #others > 0 then
                local give = new[RICE_JOB] - 0.10
                while give >= 0.049 do
                    for _, job in ipairs(others) do
                        if give >= 0.049 then new[job] = new[job] + 0.05; give = give - 0.05 end
                    end
                end
                new[RICE_JOB] = 0.10 + give
                lines[#lines + 1] = string.format("   Rice is over its cap (%d) - rice down to 10%%, rest shared by the other crops", rice)
            end
        end
    end

    -- 4) crop targets
    local over, under, isOver = {}, {}, {}
    for job in pairs(new) do
        local crop, seedName = CropOf(jobs[job])
        local tc = crop and targets[crop]
        if tc and job ~= RICE_JOB then
            local amt = haveAll[Norm(crop)] or 0
            if amt >= tc.amount then
                if new[job] > 0.001 then
                    over[#over + 1] = { job = job, crop = crop, amt = amt, target = tc.amount }
                    isOver[job] = true
                end
            elseif (have[Norm(seedName)] or 0) > 0 then
                under[#under + 1] = job
            else
                lines[#lines + 1] = string.format("   Farm: %s is short but there are no %s in the warehouse", crop, seedName)
            end
        end
    end
    if #over > 0 and #under == 0 then
        -- nothing with a target is short: give the share to crops the kitchen needs
        for job in pairs(new) do
            local crop, seedName = CropOf(jobs[job])
            if crop and job ~= RICE_JOB and not isOver[job] and farmNeeds[crop] and (have[Norm(seedName)] or 0) > 0 then
                under[#under + 1] = job
            end
        end
    end
    if #over > 0 then
        local freed = 0
        for _, o in ipairs(over) do
            freed = freed + new[o.job]
            new[o.job] = 0
            lines[#lines + 1] = string.format("   Farm: %s has enough (%d/%d) - stopping it", o.crop, o.amt, o.target)
        end
        while freed >= 0.049 and #under > 0 do
            for _, job in ipairs(under) do
                if freed >= 0.049 then new[job] = new[job] + 0.05; freed = freed - 0.05 end
            end
        end
        if freed > 0.001 then
            if riceHigh then
                lines[#lines + 1] = string.format("   Farm: nothing else needs growing - %d%% of the farm is idle (add a crop target to use it)", math.floor(freed * 100 + 0.5))
            else
                new[RICE_JOB] = (new[RICE_JOB] or 0) + freed
            end
        end
    end

    local changed = false
    for job, f in pairs(new) do
        if math.abs(f - (current[job] or 0)) > 0.01 then
            changed = true
            lines[#lines + 1] = string.format("   Farm: %s %s -> %s", jobs[job] and jobs[job].name or job, Pct(current[job]), Pct(f))
        end
    end
    if not changed then return nil end
    return st, new
end

------------------------------------------------------------------------
-- 13. MANAGER: ONE RUN
------------------------------------------------------------------------
local function RunManager(apply)
    local c = GetNpcController()
    if not c then Log("Manager: village not loaded yet.") return end
    local have, haveAll, used, total = ReadAllStock()
    if not have then Log("Manager: storage not found.") return end

    local report, lines = {}, {}
    local farmNeeds, blocked, moveAdvice = {}, {}, {}
    local targets = LoadTargets()
    ResolveStackTargets(targets, report)
    local jobs, jobByName = LoadRecipes()

    -- what is needed, including ingredients down the chain
    local demand, reason = BuildDemand(targets, jobByName, haveAll, report)
    PropagateDemand(demand, reason, jobs, jobByName, have, haveAll, farmNeeds, blocked, moveAdvice)
    for job, ing in pairs(blocked) do
        demand[job] = nil
        report[#report + 1] = string.format("   - skipping %s: no %s in stock", jobs[job] and jobs[job].name or job, ing)
    end

    -- plan each managed station
    local plans, plannedBy = {}, {}
    for _, ps in ipairs(MANAGED) do
        local st, new, current = PlanStation(c, ps[1], ps[2], demand)
        if st then
            plans[#plans + 1] = { st = st, new = new }
            plannedBy[ps[1] .. ":" .. ps[2]] = new
            lines[#lines + 1] = string.format("  Workplace %d / Station %d:", ps[1], ps[2])
            for job, f in pairs(new) do
                if math.abs(f - (current[job] or 0)) > 0.01 then
                    local name = jobs[job] and jobs[job].name or ("job " .. job)
                    local why = (f > 0 and reason[job]) and ("  <- " .. reason[job]) or ""
                    lines[#lines + 1] = string.format("     %-24s %4s -> %4s%s", name, Pct(current[job]), Pct(f), why)
                end
            end
        end
    end
    local fst, fnew = PlanFarm(c, jobs, have, haveAll, targets, farmNeeds, lines)
    if fst then plans[#plans + 1] = { st = fst, new = fnew } end

    -- which managed stations end up paused
    local paused = {}
    for _, ps in ipairs(MANAGED) do
        local forces = plannedBy[ps[1] .. ":" .. ps[2]]
        if not forces then
            local st = FindStationState(c, ps[1], ps[2])
            forces = st and ReadForces(st) or nil
        end
        if forces then
            local sum, names = 0, {}
            for job, f in pairs(forces) do
                sum = sum + f
                if #names < 3 and jobs[job] then names[#names + 1] = jobs[job].name end
            end
            if sum < 0.001 then paused[#paused + 1] = table.concat(names, "/") end
        end
    end

    -- print the plan
    Log(apply and "=== Manager: applying changes ===" or "=== Manager plan (nothing changed yet) ===")
    Log(string.format("  Warehouse chest: %s of %s slots used", tostring(used), tostring(total)))
    for _, l in ipairs(report) do Log(l) end
    if #plans == 0 then Log("  Everything is on target - no changes needed.") end
    for _, l in ipairs(lines) do Log(l) end
    if #paused > 0 then Log("  Paused (nothing needed): " .. table.concat(paused, ", ")) end
    for ing, m in pairs(moveAdvice) do
        Log(string.format("  Move from caravan: %s (%d there, warehouse has %d)", ing, m.caravan, m.warehouse))
    end
    for ing, dish in pairs(farmNeeds) do
        if not targets[ing] then
            Log(string.format("  Farm advice: grow more %s (needed for %s)", ing, dish))
        end
    end

    if apply then
        for _, p in ipairs(plans) do ApplyForces(p.st, p.new) end
        Log(string.format("  Applied changes to %d station(s).", #plans))
    end
end

------------------------------------------------------------------------
-- 14. INFO COMMANDS (read-only)
------------------------------------------------------------------------
-- F6: learn job ids, names and ingredients from the open Village Management screen
local function LearnNames()
    local buttons = FindAllOf("UI_VMRecipe_Button_C")
    if not buttons then
        Log("No recipe buttons found - open a station in Village Management first.")
        return
    end
    local names, learned = LoadJobFile(), 0
    for _, b in ipairs(buttons) do
        local ok, err = pcall(function()
            if not b:IsValid() or b:GetFullName():find("Default__", 1, true) then return end
            local name = b.RecipeNameText:ToString()
            if name == nil or name == "" then return end
            if tostring(b.RecipeID) == "0" and tostring(b.Workstation) == "0" then return end
            local job = tostring(b.RecipeID)
            local isNew = names[job] == nil
            local needs = {}
            pcall(function()
                b.RequiredItems:ForEach(function(i, h)
                    needs[#needs + 1] = "item:" .. h:get().RowName:ToString() .. "=" .. tostring(b.RequiredAmounts[i])
                end)
            end)
            pcall(function()
                b.RequiredTools:ForEach(function(i, h)
                    needs[#needs + 1] = "tool:" .. h:get().RowName:ToString() .. "=" .. tostring(b.RequiredToolsAmount[i])
                end)
            end)
            names[job] = { place = tostring(b.Building), station = tostring(b.Workstation), name = name,
                           needs = table.concat(needs, ",") }
            Log(string.format("Workplace %s / Station %s  job %s = %s%s",
                tostring(b.Building), tostring(b.Workstation), job, name, isNew and "  (new)" or ""))
            learned = learned + 1
        end)
        if not ok then Log("Skipped a button: " .. tostring(err)) end
    end
    SaveJobFile(names)
    local count = 0
    for _ in pairs(names) do count = count + 1 end
    Log(string.format("Read %d buttons. %d jobs saved in total.", learned, count))
end

-- F7: material piles
local function PrintPiles()
    local s = GetStorage()
    if not s then Log("Village storage not found - load your save first.") return end
    Log("Material piles (cap " .. tostring(s.SpawnersMaxCapacity) .. " each):")
    s.MaterialPilesInventory:ForEach(function(k, v)
        Log("   " .. k:get():ToString() .. " = " .. tostring(v:get()))
    end)
end

-- Shared printer for F8 and Numpad 4
local function PrintContents(title, stock, used, total)
    local rows = {}
    for row, e in pairs(stock) do rows[#rows + 1] = { row = row, name = e.name, amount = e.amount, max = e.max } end
    table.sort(rows, function(a, b) return a.name < b.name end)
    Log(string.format("%s (%d kinds of item, %s of %s slots used):", title, #rows, tostring(used), tostring(total)))
    for _, r in ipairs(rows) do
        Log(string.format("   %-28s %6d   stack %-5s [%s]", r.name, r.amount, tostring(r.max), r.row))
    end
end

-- F8: warehouse chest
local function PrintChest()
    local stock, used, total = ReadChestStock()
    if not stock then Log("Warehouse chest not found - load your save first.") return end
    PrintContents("Warehouse chest", stock, used, total)
end

-- Numpad 4: caravan
local function PrintCaravan()
    if #GetCaravans() == 0 then Log("No caravan storage found.") return end
    local stock, used, total = ReadCaravanStock()
    PrintContents("Caravan", stock, used, total)
end

------------------------------------------------------------------------
-- 15. KEYS AND AUTO MODE
------------------------------------------------------------------------
-- Runs fn on the game thread and reports errors instead of crashing
local function Safe(label, fn)
    return function()
        ExecuteInGameThread(function()
            local ok, err = pcall(fn)
            if not ok then Log(label .. " error: " .. tostring(err)) end
        end)
    end
end

local autoOn = false

RegisterKeyBind(Key.NUM_ONE,   Safe("Manager", function() RunManager(false) end))
RegisterKeyBind(Key.NUM_TWO,   Safe("Manager", function() RunManager(true) end))
RegisterKeyBind(Key.NUM_THREE, function()
    autoOn = not autoOn
    Log(autoOn and "Manager AUTO ON - adjusting every 2 minutes." or "Manager AUTO OFF.")
    if autoOn then Safe("Manager", function() RunManager(true) end)() end
end)
RegisterKeyBind(Key.NUM_FOUR, Safe("Caravan", PrintCaravan))
RegisterKeyBind(Key.F6,       Safe("Learn", LearnNames))
RegisterKeyBind(Key.F7,       Safe("Piles", PrintPiles))
RegisterKeyBind(Key.F8,       Safe("Chest", PrintChest))

-- Auto mode timer
LoopAsync(AUTO_INTERVAL_MS, function()
    if autoOn then Safe("Manager", function() RunManager(true) end)() end
    return false
end)

-- Attach the warning listener once the village is loaded
LoopAsync(5000, function()
    ExecuteInGameThread(function() pcall(TryAttachWarningHooks) end)
    return hooksDone
end)

Log("Loaded. Numpad 1 plan | 2 apply | 3 auto | 4 caravan | F6 learn | F7 piles | F8 chest")
