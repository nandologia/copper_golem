# Copper Golem (for Mineclonia)

A self-contained [Luanti](https://www.luanti.org/) mod that adds a
Minecraft-style **Copper Golem** to **Mineclonia** — a build-to-spawn worker
that sorts your chests, oxidises over time, and can be scraped, waxed,
zapped, and (if you must) fought.

- **No mob framework.** It's a plain `register_entity` using only stable core
  API (`on_step`, the node-meta inventory API, `core.add_entity`,
  `core.override_item`). Small, readable, and easy to fork.
- **Hard deps:** `mcl_copper`, `mcl_farming`. **Optional:** `mcl_chests`,
  `mcl_honey` (features degrade gracefully if absent).

## Build it

Place a **copper block**, then a **carved pumpkin on top**. Both nodes are
consumed and the golem appears with a copper-spark flourish — exactly like
building an iron or snow golem. It starts at the oxidation stage of the copper
block you used (a weathered block makes a weathered golem). Waxed copper blocks
deliberately don't spawn one.

## What it does

| Feature | In game |
|---|---|
| **Chest sorting** | Keeps the chests around it organised: it gathers each item into the chest that already holds the **most** of it, then physically rearranges every chest into **creative-inventory order** (like items together, families grouped), merging partial stacks. A large **double chest** is treated as one. You can watch it open the lid and carry each stack by hand. **→ [How the sorting works](#how-the-sorting-works).** |
| **Oxidation** | Visually ages normal → exposed → weathered → oxidized over time (default **20 min/stage**, configurable). Each stage is **slower** (100% / 75% / 50% / frozen); a fully oxidized golem seizes up. Irreversible by time, like Minecraft. |
| **De-oxidation (axe)** | **Right-click** with an **axe** to scrape it back one stage (strips wax first). Stars sparkle; it costs one axe durability; it never deals damage. |
| **Waxing (honeycomb)** | Right-click with a **honeycomb** to permanently halt oxidation at the current stage. |
| **Lightning** | A lightning strike purges **all** oxidation back to pristine and briefly hyper-charges its speed. |
| **Killable** | It has HP and can be fought like an iron golem — about **7 diamond-sword hits** (other weapons scale by their damage). On death it drops a few copper ingots plus whatever it was carrying. It takes **no fall damage**. |
| **Water** | It won't walk off dry land into water, but if it ends up submerged it trudges along the bottom (it never drowns). Standing in water makes it oxidise faster — unless waxed. |
| **Wandering** | Between chest trips it strolls and idles, occasionally turning its head to look around, climbing 1-block steps along the way. |
| **Pathfinding** | When heading to a chest it uses the engine's A* pathfinder (the same one Mineclonia's mobs/villagers use) to route **around** walls. If a chest is sealed off with no way to it, the golem gives up at once and looks for other work instead of grinding against the wall. |

## How the sorting works

Spawn a golem near your storage and it quietly keeps the chests around it tidy.
There is nothing to configure in game — just build it and let it work.

**It tends one room.** A golem only looks for chests within about **8 nodes** of
itself (roughly one large room) and never carries items between rooms, so each
golem keeps its own area in order. Put a golem in each storage room.

**The fullest chest wins.** For every kind of item, the chest that already holds
the **most** of that item becomes its **home**. The golem carries that item out
of the other nearby chests and into its home, so each kind ends up gathered in
one place. **This is how you steer it:** to choose where something lives, just
make sure the biggest pile of it is in the chest you want. Drop a stack of
cobblestone in your "stone" chest and the golem will bring all the loose
cobblestone there. (If a home chest fills up, the overflow simply stays put.)

**Inside each chest it sorts like the creative menu.** Once items are gathered,
the golem physically rearranges each chest — picking stacks up one at a time, so
you can watch it — until identical items sit next to each other and whole
families are grouped together (all the stones, all the seeds), in the same order
as Mineclonia's creative inventory. Partial stacks of the same item are merged.

**Double chests count as one.** A large (double) chest is organised as a single
54-slot grid, not two separate halves.

**What it leaves alone, and never loses.** Tools, damaged gear, and anything with
a custom name or metadata are never moved or merged — only ordinary stackable
items are sorted. Nothing is destroyed: if the golem can't reach a chest, it
tucks the carried item into the nearest one instead of dropping it on the floor.

**Tips**

- Want to move an item's "home"? Put a bigger pile of it in the chest you prefer
  (or empty the current home), and the golem re-homes it on its next round.
- Keep the chests you want sorted within ~8 nodes of where the golem roams; raise
  `chest_radius` (see [Tuning](#tuning)) if your room is larger.
- One golem per room is plenty. They settle down and stop pacing once everything
  is tidy, and perk back up when you add or disturb items.

## Install

1. Drop this folder into your Mineclonia world's `mods/`. The mod name is
   `copper_golem`, so name the folder **`copper_golem`** — if you cloned the
   `mcl_copper_golem` repo, rename the folder to `copper_golem`.
2. Enable **Copper Golem** in the world's mod configuration.
3. Restart Luanti fully (models and textures only load at startup); reconnect
   if you're on a server so the client fetches the model/textures.

## How it's built

The mesh and textures are **generated**, not hand-drawn, by two scripts in
`tools/` (require Python 3 + Pillow). You only need to run them if you change
the model or re-skin it.

```
copper_golem/
├── init.lua                 all behaviour, sectioned (config / visuals / AI / entity)
├── mod.conf
├── models/
│   └── copper_golem.b3d     GENERATED — do not hand-edit
├── textures/                8 atlases (4 oxidation stages × body+eyes) + star
├── tools/
│   ├── make_model.py        builds copper_golem.b3d from a box table (PARTS)
│   ├── make_textures.py     skins the golem with Mineclonia's copper-block art
│   └── copper_src/          the 4 source copper-block textures (CC BY-SA, NO11)
├── LICENSE.txt              GPLv3 (code + model)
├── LICENSE-media.md         per-file texture credits (CC BY-SA 4.0)
└── README.md
```

- `make_model.py` builds the mesh from the `PARTS` table (1 px = 1/16 node),
  with 6 bones and two baked animations: a walk cycle and an idle head-turn.
  The texture atlas UV layout is derived from the same table — **`make_textures.py`
  mirrors that `PARTS` table and the two must stay in sync.**
- `make_textures.py` tiles Mineclonia's copper-block textures (one block variant
  per oxidation stage) across the entity UV map, then draws the green-gradient
  eyes. Re-run it to change the look; re-run `make_model.py` if you change the
  geometry. Then restart Luanti.

## Tuning

Edit the `config` table at the top of `init.lua`:

- `seconds_per_stage = 1200` — oxidation pace; drop to e.g. `30` to watch it age.
- `chest_radius = 8` — how far it looks for chests to sort (kept small so it stays within one room rather than couriering items between rooms).
- `organize_cooldown = 6` — seconds between sort trips.
- `path_recheck = 1.5` — seconds between recomputing the route to a chest.
- `unreachable_ttl = 20` — seconds it ignores a chest it couldn't path to.
- `chest_dwell`, `seek_timeout`, `walk_speed` / `seek_speed`, idle/walk burst times.

Combat/visual tunables live next to their code: `hp_max` (entity properties),
the `STAGE_SPEED` table, `LIGHTNING_BOOST*`, `WATER_OXIDATION_MULT`, and the
held-item hand offset (`HELD_OFFSET` / `HELD_ROT`).

## Credits & license

- **Code + model:** © 2026 nando, **GPLv3** — see [`LICENSE.txt`](LICENSE.txt).
- **Textures:** **CC BY-SA 4.0**. The body atlases derive from Mineclonia's
  `mcl_copper` block textures by **NO11**, based on the **Pixel Perfection**
  pack by **XSSheep**. Full per-file breakdown in
  [`LICENSE-media.md`](LICENSE-media.md).
- No Minecraft/Mojang assets are included; the golem is original art inspired by
  the Minecraft concept.

Built with [Claude Code](https://claude.com/claude-code).
