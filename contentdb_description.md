Place a **copper block**, put a **carved pumpkin** on top, and watch a Copper Golem spring to life in a burst of sparks — then leave it alone. It will sort your chests for you.

---

**What it does**

The golem roams the chests near it (within one room) and keeps them organised, automatically and continuously. You don't configure anything in game. Just build it and walk away.

**Between-chest sorting.** For every kind of item, the chest that already holds the most of it becomes its *home*. The golem carries stray stacks from other chests into their home, gathering each item type into one place.

**Within-chest sorting.** Once items are gathered, it physically rearranges each chest — opening the lid, picking stacks up one by one, you can watch it work — until the contents match creative-inventory order: identical items together, whole families grouped, partial stacks merged.

**Double chests as one.** A large double chest is sorted as a single 54-slot grid.

**You steer it with piles.** To choose where something lives, make sure the biggest pile of it is already in the chest you prefer. Drop a stack of cobblestone in your stone chest and the golem brings all the loose cobblestone there. Change your mind later: move the big pile, and the golem follows.

**It never loses items.** Tools, enchanted gear, and anything with custom metadata are never touched. If a chest becomes unreachable, the golem stashes what it's carrying in the nearest available chest instead of dropping it.

---

**It also ages**

The golem oxidises over time, just like copper in the world — visually changing from bright copper through exposed and weathered to fully oxidised, growing slower at each stage until it freezes into a statue. You control this:

- **Right-click with an axe** — scrapes one oxidation stage back (costs a little axe durability, never damages the golem).
- **Right-click with a honeycomb** — waxes it permanently at the current stage.
- **Lightning strike** — resets it to pristine and briefly boosts its speed.

The oxidation stage of the copper block you build with is the stage the golem starts at. Build with a weathered block to get a weathered golem right away.

---

**Combat**

It has HP and fights back like an iron golem — about seven diamond-sword hits to kill. On death it drops a few copper ingots plus whatever it was carrying at the time. It takes no fall damage.

---

**Tips**

- One golem per room is plenty. It settles down once everything is tidy and perks back up when you add items.
- To redirect where an item lives: put a bigger pile of it in your preferred chest (or empty the current home). The golem re-homes it on its next round.
- If your room is larger than ~8 nodes, raise `chest_radius` in the `config` table at the top of `init.lua`.
