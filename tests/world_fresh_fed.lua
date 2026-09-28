-- The fresh village again, but with 700 rice: food is above the reserve
-- (5 workers x 100 = 500), so the farm should share out between rice and
-- the crops that are short and have seeds, not grow only rice.
local W = dofile("world_fresh.lua")
for _, item in ipairs(W.chest) do
  if item[1] == "Rice" then item[2] = 700 end
end
return W
