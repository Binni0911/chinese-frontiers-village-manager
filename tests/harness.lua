-- Fake UE4SS + fake village for testing the mod without the game.
-- Usage: lua5.4 harness.lua <main.lua> <world.lua> KEY [KEY ...]
-- Set HUNGRY=1 to simulate villagers stopped for lack of food.
-- Prints the mod's console output, then every job's final percentage.
local modFile, worldFile, keys = arg[1], arg[2], {}
for i = 3, #arg do keys[#keys+1] = arg[i] end
local W = dofile(worldFile)
local HUNGRY = os.getenv("HUNGRY") == "1"
local function Wrap(v) return { get = function() return v end } end
local function Arr(list)
  return setmetatable({ ForEach = function(self, fn) for i, v in ipairs(list) do fn(i, Wrap(v)) end end,
                        GetArrayNum = function() return #list end },
                      { __index = function(_, k) return list[k] end })
end
local function Map(pairsList) -- ordered list of {k,v}
  return { ForEach = function(self, fn) for _, kv in ipairs(pairsList) do fn(Wrap(kv[1]), Wrap(kv[2])) end end }
end
local function FNameS(s) return { ToString = function() return s end } end
local function Obj(name, t) t = t or {}; t.IsValid = function() return true end; t.GetFullName = function() return name end; return t end

local F = { StationIDs="WorkStationsID_16_038795414E200FE36FBA18B5E36A28A3", StationStates="WorkStationsStates_18_DDB65DE14D2C24B73F4D6F9A1F061F88",
  Recipes="Recipes_34_4BE92CAD49DABB872178398069156C73", Force="Force_12_4BE92CAD49DABB872178398069156C73" }
local ECON="Economy_35_3D2230474EB2029A912FF6AA202323FD"
-- RENAMED=1 pretends a game update renamed the job percentage field
if os.getenv("RENAMED") == "1" then F.Force = "Force_13_RENAMED" end
local IT = { H="ItemHandle_60_EFC3446F4BEB3A00026CE2A9EAC341F7", A="Amount_63_A266101D46331E1C405B5BBCCD66B5AB",
  N="Name_6_4BDAD3B24B564228353D28A42C703448", M="MaxStack_17_A4F940864DC6C3A24983778907BB130E" }

-- controller
local placeOrder, places, jobRecs = {}, {}, {}
for _, s in ipairs(W.stations) do
  local p, st, jobs = s[1], s[2], s[3]
  if not places[p] then places[p] = { ids = {}, states = {} }; placeOrder[#placeOrder+1] = p end
  local menu, work = {}, {}
  for _, j in ipairs(jobs) do
    local a, b = { [F.Force] = j[2] }, { [F.Force] = j[2] }
    menu[#menu+1] = { j[1], a }; work[#work+1] = { j[1], b }
    jobRecs[#jobRecs+1] = { p, st, j[1], a, b }
  end
  local econ = Obj("econ", { Workstation_ref = { [F.Recipes] = Map(work) } })
  table.insert(places[p].ids, st)
  table.insert(places[p].states, { [F.Recipes] = Map(menu), [ECON] = econ })
end
local placeStructs = {}
for _, p in ipairs(placeOrder) do placeStructs[#placeStructs+1] = { [F.StationIDs] = Arr(places[p].ids), [F.StationStates] = Arr(places[p].states) } end
local ctrl = Obj("BP_NPC_Controller_C /Game/X.Village:PersistentLevel.BP_PlayerController_C_1.NPC_Controller", {
  ["Workplace id's"] = Arr(placeOrder), WorkplaceStations = Arr(placeStructs),
  EconomyFoodController = Obj("food", { IsEnoughFood = not HUNGRY, ["StoppedNPC's"] = Arr(HUNGRY and {1, 2} or {}) }) })

local function Container(name, list)
  local slots = {}
  for _, it in ipairs(list) do
    slots[#slots+1] = { [IT.H] = { RowName = FNameS(it[4]) }, [IT.A] = it[2], [IT.N] = FNameS(it[1]), [IT.M] = it[3] }
  end
  return Obj(name, { Items = Arr(slots) })
end
local chest = Container("BP_ContainerComponent_C /Game/X:PersistentLevel.BP_PlayerController_C_1.NPC_StorageChest", W.chest)
local caravan = Container("BP_ContainerComponent_C /Game/X:PersistentLevel.BP_FPP_Character_Player_C_1.CaravanChestContainer", W.caravan)
local pileList = {}
for k, v in pairs(W.piles) do pileList[#pileList+1] = { FNameS(k), v } end
table.sort(pileList, function(a, b) return a[1].ToString() < b[1].ToString() end)
local storage = Obj("BP_NPC_Storage_Component_C /Game/X:PersistentLevel.BP_PlayerController_C_1.NPC_Storage",
  { MaterialPilesInventory = Map(pileList), SpawnersMaxCapacity = 2000, ChestSlotsNumber = 203 })

-- villagers (plus the class template, which must not be counted)
local workers = { Obj("BP_Character_NPC_Human_Worker_Village_C /Script/X.Default__BP_Character_NPC_Human_Worker_Village_C") }
for i = 1, W.workers or 0 do workers[#workers+1] = Obj("BP_Character_NPC_Human_Worker_Village_C /Game/X:PersistentLevel.Worker_" .. i) end
local byClass = { BP_NPC_Controller_C = { ctrl }, BP_ContainerComponent_C = { chest, caravan }, BP_NPC_Storage_Component_C = { storage },
  BP_Character_NPC_Human_Worker_Village_C = workers }
function FindAllOf(c) return byClass[c] end
function FindFirstOf(c) return (byClass[c] or {})[1] end
function RegisterHook() end
function LoopAsync() end
function ExecuteInGameThread(f) f() end
Key = setmetatable({}, { __index = function(_, k) return k end }); ModifierKey = { CONTROL = "CTRL" }
local binds = {}
function RegisterKeyBind(k, a, b) if type(a) == "function" then binds[k] = a end end

local realPrint = print
print = function(s) s = tostring(s):gsub("\n$", ""):gsub("^%[%w+%] ", ""); io.write(s, "\n") end
dofile(modFile)
for _, k in ipairs(keys) do io.write("### KEY ", k, "\n"); binds[k]() end
io.write("### FINAL FORCES\n")
table.sort(jobRecs, function(a, b) return a[3] < b[3] end)
for _, r in ipairs(jobRecs) do
  io.write(string.format("%d/%d job %d menu=%.2f work=%.2f\n", r[1], r[2], r[3], r[4][F.Force], r[5][F.Force]))
end
