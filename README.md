# Chinese Frontiers – Village Manager

UE4SS Lua mod for **Chinese Frontiers** that automatically balances village workforce and production to keep stock at your targets — without cheating.

The game lets you set what share of each workstation's workers goes to each recipe, but it never adjusts those shares for you. Workers keep making things you have thousands of while you run out of what you actually need, and the warehouse chest fills up. Village Manager watches your stock and moves the same sliders you would, every two minutes.

**It does not create items or change game rules.** It only changes the job percentages you can set yourself in Village Management. Workers still need their materials, tools and food.

## Status

**Finished – no further work planned.** The mod does what we built it for, from a new save to the endgame. We won't be adding to it unless there is interest: if you find a bug or want a feature, [open an issue](https://github.com/Binni0911/chinese-frontiers-village-manager/issues) and we'll take a look.

## What it does

- **Targets** – keep a set amount of any item (`Dougong = 1 stack`, `Stone Hoe = 3`).
- **Caps** – stop gathering at a limit and restart lower down (`Wood = 2000, 1500`), so the chest doesn't fill up.
- **Recipe chains** – if Dougong is short it also schedules Brace, then Wedge, as needed.
- **Caravan aware** – items banked in the caravan count towards targets, and it tells you to move ingredients back instead of making more.
- **Tools** – reacts to the game's own "missing tools" warnings.
- **Farm** – stops crops that have enough, gives their share to crops that are short, never plants crops with no seeds, and keeps a food reserve. A new farm with nothing assigned is given work straight away.
- **Kitchen** – skips dishes whose ingredients you don't have, and doesn't make parts (flour, dough) for dishes that can't be finished.
- **Grows with your village** – works from the first warehouse on a new save. The food reserve can scale with your number of workers.
- **Explains itself** – every change is printed with its reason, and one line lists what is missing.

## Install

1. Install [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) (the experimental build supports UE 5.5, which the game uses) into
   `Chinese Frontiers\ChineseFrontiers\Binaries\Win64`.
2. Download the zip from [Releases](https://github.com/Binni0911/chinese-frontiers-village-manager/releases) and copy the `VillageManager` folder into `...\Win64\ue4ss\Mods\`.
3. Add this line to `ue4ss\Mods\mods.txt` (above the `Keybinds` line):
   ```
   VillageManager : 1
   ```
4. Start the game and load your save. The UE4SS console should say `[VillageManager] Loaded.`

## Keys

| Key | What it does |
|---|---|
| Numpad 1 | Show the plan (changes nothing) |
| Numpad 2 | Apply the plan once |
| Numpad 3 | Auto mode on/off (applies every 2 minutes) |
| Numpad 4 | Show caravan contents |
| F6 | Learn job names and recipes from the open Village Management screen |
| F7 | Show material piles (logs, stone blocks, bricks, tiles) |
| F8 | Show warehouse chest contents |
| F9 | List unlocked stations and their current job percentages |

Start with **Numpad 1** and read the plan before applying anything.

## Setting targets

Edit `VillageManager\targets.txt`. Changes are picked up on the next run — no restart needed.

```
Stone Hatchet = 3          keep at least 3
Dougong       = 1 stack    keep one full stack (uses the item's real stack size)
Wood          = 2000, 1500 stop at 2000, start again at 1500
Fish          = 1000, 600  fishing stops at 1000, starts again at 600
Food Reserve  = 100, 150 per worker
                           5 workers: below 500, farm work goes to rice until back at 750
```

`per worker` works on any target: the numbers are multiplied by how many villagers you have, so the line keeps fitting as the village grows.

Names must match what the game shows (F8 lists them). Anything without a line in `targets.txt` is never produced on purpose, only as an ingredient for something that has one.

## Files

| File | Purpose |
|---|---|
| `Scripts/main.lua` | The mod |
| `targets.txt` | What to keep in stock – the one you edit |
| `job_names.txt` | Job IDs, names and ingredients (filled by F6) |
| `stacks.txt` | Remembered stack sizes (filled automatically) |

## Tests

The `tests` folder runs the mod against a fake village built from real save data, so the decision logic can be checked without the game:

```
./tests/run_tests.sh            # check against saved results
./tests/run_tests.sh --update   # save new results after an intended change
```

It checks that the plan matches the saved result, that nothing errors, and that every managed station adds up to 100% (or is paused). Needs Lua 5.4.

## Known limitations

- Tested on an endgame save and a fresh save. Stations are found by their station number, which is the same on both.
- The game doesn't say whether a station is built or only unlocked, so an unlocked but unbuilt station can get a plan. This is harmless: nobody works there yet.
- Chickens and pigs are left to you. If you have no eggs, recipes that need eggs count as blocked.
- Gatherers need tools in the warehouse (hatchet, pickaxe, shovel, hoe, fishing rod). Until the Stonemason tool bench is unlocked you have to craft them yourself; the plan shows a "missing tools" warning when one is short.
- Game patches can rename the internal fields the mod reads (section 3 of `main.lua`). If it stops working after an update, those need re-checking with a UE4SS header dump.
- It overrides manual changes on the stations it manages.

## Extra: FixStuckNPC (Ghosts of the Fallen fix)

In the side quest **Ghosts of the Fallen**, the step "Talk to Daoshi" can point to the small shrine in the Nine Arch Bridge fortress with nobody there. The Daoshi (`BP_NPC_RV_DAOSHI_C`) has spawned about 50 m under the ground. Reloading doesn't fix it.

`FixStuckNPC` is a small separate mod that moves him back up:

1. Copy the `FixStuckNPC` folder into `...\Win64\ue4ss\Mods\` and add `FixStuckNPC : 1` to `mods.txt`.
2. Stand on the quest marker.
3. **Numpad 7** lists characters under you (changes nothing). **Numpad 8** brings the Daoshi up in front of you.

Then talk to him as normal. It works for any NPC stuck under the map near you, but it only picks the Daoshi or the nearest character under you.

## Credits

Designed and play-tested by Binni. Implementation written with Claude (Anthropic).
