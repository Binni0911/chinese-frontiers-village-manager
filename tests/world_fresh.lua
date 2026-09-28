-- A new village, based on a real fresh save (Sept 2026): warehouse, Carpenter,
-- farm, huts. Workplace numbers differ from the endgame save (Carpenter is
-- workplace 1 here, 8 there) and stone and fishing share job number 7.
-- The kitchen is unlocked but not built, so all its jobs are at 0%.
return {
stations={
{1,9,{{11,0.2},{12,0.2},{13,0.2},{14,0.2},{15,0.2},{16,0.0},{17,0.0},{18,0.0},{84,0.0}}},
{11,19,{{37,0.0},{36,0.0}}},
{11,20,{{35,0.0}}},
{11,21,{{68,0.0},{70,0.0},{63,0.0},{64,0.0},{65,0.0},{71,0.0},{61,0.0},{62,0.0},{67,0.0},{60,0.0},{59,0.0},{58,1.0},{69,0.0},{66,0.0},{72,0.0},{73,0.0},{74,0.0},{75,0.0}}},
{6,17,{{38,0.0},{39,0.0},{40,0.0},{41,0.0},{42,0.0},{43,0.0},{44,0.0},{46,0.0},{47,0.0},{48,0.0},{49,0.0},{50,0.0},{51,0.0},{52,0.0},{53,0.0},{54,0.0},{55,0.0},{56,0.0},{57,0.0}}},
{3,7,{{5,1.0}}},
{3,5,{{3,1.0}}},
{3,6,{{4,1.0}}},
{3,3,{{6,1.0}}},
{3,2,{{7,1.0}}},
{3,1,{{1,1.0}}},
{3,4,{{7,1.0}}},
},chest={
{"Wood",40,500,"Component_Wood"},
{"Fish",12,100,"Food_Ingredient_Fish"},
{"Stone",2100,500,"Component_Stone"},
},caravan={
{"Wood",161,500,"Component_Wood"},
{"Clay",154,500,"Component_Clay"},
{"Bamboo",161,500,"Component_Bamboo"},
},piles={LogSpawner=0,StoneSpawner=0,RedBrickSpawner=0,CeramicTilesSpawner=0}}
