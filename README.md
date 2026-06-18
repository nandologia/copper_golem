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
| **Chest sorting** | The golem gathers like items together. It carries up to 16 of a stack out of a chest where it doesn't belong and into the chest that already holds the most of that item — so each item type congregates in one chest. When there's nothing to move between chests, it **compacts the partial stacks within each chest** into the fewest stacks. It opens the chest (animated lid) and you can see the item in its hand as it carries it. |
| **Oxidation** | Visually ages normal → exposed → weathered → oxidized over time (default **20 min/stage**, configurable). Each stage is **slower** (100% / 75% / 50% / frozen); a fully oxidized golem seizes up. Irreversible by time, like Minecraft. |
| **De-oxidation (axe)** | **Right-click** with an **axe** to scrape it back one stage (strips wax first). Stars sparkle; it costs one axe durability; it never deals damage. |
| **Waxing (honeycomb)** | Right-click with a **honeycomb** to permanently halt oxidation at the current stage. |
| **Lightning** | A lightning strike purges **all** oxidation back to pristine and briefly hyper-charges its speed. |
| **Killable** | It has HP and can be fought like an iron golem — about **7 diamond-sword hits** (other weapons scale by their damage). On death it drops a few copper ingots plus whatever it was carrying. It takes **no fall damage**. |
| **Water** | It won't walk off dry land into water, but if it ends up submerged it trudges along the bottom (it never drowns). Standing in water makes it oxidise faster — unless waxed. |
| **Wandering** | Between chest trips it strolls and idles, occasionally turning its head to look around. It climbs 1-block steps and sidesteps simple obstacles; it can't pathfind through mazes. |

**Sorting safety:** items with wear, metadata, or a max stack of 1 (tools,
named/damaged gear) are never touched. If the golem can't reach a chest, it
tucks the item into the nearest one rather than dropping it on the floor.

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
- `chest_radius = 8` — how far it looks for chests to sort.
- `organize_cooldown = 12` — seconds between sort trips.
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
