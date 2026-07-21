--------------------------------------------------------------------------------
-- copper_golem  --  a self-contained Copper Golem for Mineclonia
--------------------------------------------------------------------------------
--
-- WHAT THIS MOD DOES
--   * Adds a "Copper Golem" entity, built the golem way: place a carved
--     pumpkin on top of a copper block and the two nodes turn into a golem.
--   * The golem oxidises through four IRREVERSIBLE stages over time
--     (normal -> exposed -> weathered -> oxidized), each with its own
--     body + eyes texture pair.
--   * The golem sorts nearby chests: it carries items out of the "wrong" chest
--     into the chest that already holds the most of that kind, gathering like
--     with like (each item type ends up congregating in one chest).
--
-- DESIGN NOTES (read before editing)
--   * ZERO third-party dependencies. Only stable core API is used:
--     register_entity, on_step, the node-meta inventory API, core.add_entity,
--     core.override_item, core.get_node. No mob framework, nothing experimental.
--   * The file is split into labelled sections. The two things most likely to
--     be swapped are kept apart on purpose:
--         (A) MODEL / VISUALS  -- how the golem looks per oxidation stage
--         (B) BEHAVIOUR        -- oxidation timing + chest sorting
--     You can rewrite either without touching the other; they only meet inside
--     the thin entity definition near the bottom.
--   * Oxidation is time-based and one-way, like real copper. Waxing (honeycomb
--     right-click) halts it -- implemented because it was trivial here.
--
-- Mineclonia node names were verified against this install before writing:
--     copper block : mcl_copper:block[ _exposed | _weathered | _oxidized ]
--     carved pumpkin: mcl_farming:pumpkin_face
--     honeycomb     : mcl_honey:honeycomb
--     chest inv     : core.get_inventory({type="node", pos=p}) -> list "main"
--------------------------------------------------------------------------------
---trying to MOD to looks similar or even BETTER than MCraft wrxxnch was here

copper_golem = {}

-- Pure, engine-agnostic move planner for the within-chest animated sort. Kept in
-- its own file so it can be unit-tested offline (tests/). See sortlib.lua.
local sortlib = dofile(core.get_modpath("copper_golem") .. "/sortlib.lua")

--------------------------------------------------------------------------------
-- 0. CONFIG  --  tweak these; everything else reads from here
--------------------------------------------------------------------------------

local config = {
	-- Real-time seconds the golem spends in each oxidation stage before
	-- advancing to the next. A fixed interval is simple and maintainable;
	-- real copper randomises this over a long period. Stage 4 (oxidized)
	-- is terminal. Lower this while testing if you want to watch it change.
	seconds_per_stage = 1200, -- 20 minutes per step

	-- Chest sorter. The golem gathers like items together: it finds a stack
	-- sitting in the "wrong" chest within chest_radius, carries it to the chest
	-- that already holds the most of that item, and deposits it there.
	chest_radius      = 8,    -- nodes, sort radius (source + destination must both fit)
	                          -- kept small on purpose: confines sorting to one room
	                          -- so it won't courier items between rooms of a shared base
	organize_cooldown = 6,    -- seconds between sort trips

	-- Ground pickup. The golem also collects loose dropped items lying on the
	-- floor nearby and carries them into a chest, instead of only reshuffling
	-- items that are already inside chests. Checked before chest-to-chest
	-- sorting on every work cycle, so litter gets priority over tidying.
	pickup_enabled    = true,
	pickup_radius     = 8,    -- nodes, how far it looks for dropped items (like chest_radius)
	seek_recheck      = 3,    -- seconds between "is there work?" scans when idle
	seek_timeout      = 22,   -- give up walking to a chest after this long
	chest_dwell       = 0.6,  -- seconds spent at an open chest (lets the lid animation show)
	sort_move_time    = 0.45, -- seconds per pick-up / put-down beat while reordering a chest

	-- Pathfinding (engine A*, like Mineclonia's own mobs/villagers). Lets the
	-- golem route AROUND walls to reach a chest, and -- crucially -- give up at
	-- once when a chest is walled off with no way to it, instead of grinding
	-- against the wall until seek_timeout.
	path_recheck      = 1.5,  -- seconds between path recomputes while travelling
	unreachable_ttl   = 20,   -- ignore a chest we couldn't reach for this long

	-- Wandering (self-contained AI; no mob framework).
	walk_speed        = 1.4,  -- nodes/sec while strolling
	seek_speed        = 2.0,  -- nodes/sec when heading to a chest
	walk_time_min     = 1.5,  -- seconds of a walk burst
	walk_time_max     = 3.5,
	idle_time_min     = 1.0,  -- seconds of standing still
	idle_time_max     = 3.0,

	-- "Job done, calm down." After this many idle cycles with no chest work to
	-- do, the golem visibly settles: shorter, rarer strolls and longer rests,
	-- and it stops drifting away from the chests it tends. 0 = always restless.
	calm_after        = 5,
}

--------------------------------------------------------------------------------
-- (A) MODEL / VISUALS  --  self-contained; no behaviour logic here
--------------------------------------------------------------------------------
--
-- Four oxidation stages, indexed 1..4. Each provides a body texture and an eyes
-- overlay, combined in-engine with the "body^eyes" texture modifier.
--
-- The mesh is models/copper_golem.b3d, GENERATED by tools/make_model.py from
-- the texture atlas itself: the 64x64 PNGs are box-model entity unwraps
-- (head 8x5x10, nose, antenna, body 8x6x6, two long arms, two legs), and the
-- script derives each box and its UV rect from that layout, then adds bones
-- and a walk animation. If you ever change the atlas layout, edit PARTS in
-- tools/make_model.py and re-run it -- don't hand-edit the .b3d.

local MODEL = "copper_golem.b3d"

-- Animation frame ranges baked into the generated model.
local ANIM = {
	stand = { x = 1,  y = 1  },  -- rest frame (frame 1 = phase 0.0); B3D is 1-indexed
	walk  = { x = 1,  y = 21 },  -- 20-frame swing cycle
	look  = { x = 31, y = 91 },  -- idle head turn+nod (wide yaw & up/down pitch)
}
local ANIM_SPEED = 24 -- frames/sec the model was authored at

-- Four held statue poses (frames 101..104, one each) the golem freezes into when
-- fully oxidized; see tools/make_model.py POSES. Played a single frame at a time.
local NUM_POSES = 4
for p = 1, NUM_POSES do
	ANIM["pose" .. p] = { x = 100 + p, y = 100 + p }
end

local STAGES = {
	{ name = "normal",    body = "copper_golem.png",           eyes = "copper_golem_eyes.png"           },
	{ name = "exposed",   body = "exposed_copper_golem.png",   eyes = "exposed_copper_golem_eyes.png"   },
	{ name = "weathered", body = "weathered_copper_golem.png", eyes = "weathered_copper_golem_eyes.png" },
	{ name = "oxidized",  body = "oxidized_copper_golem.png",  eyes = "oxidized_copper_golem_eyes.png"  },
}

local NUM_STAGES = #STAGES

-- The generated mesh has a single material slot: the full atlas.
local function mesh_textures(stage)
	local s = STAGES[stage]
	return { s.body .. "^" .. s.eyes }
end

-- The static (stage-independent) visual properties of the entity.
-- The model is authored at 1 px = 1/16 node: body 1.0 node tall, antenna tip
-- at ~1.44. Its origin is at the feet, so boxes rise from y=0.
local function base_visual_properties()
	return {
		visual               = "mesh",
		mesh                 = MODEL,
		visual_size          = { x = 1, y = 1, z = 1 },
		collisionbox         = { -0.3, 0.0, -0.3, 0.3, 1.0, 0.3 },
		selectionbox         = { -0.3, 0.0, -0.3, 0.3, 1.45, 0.3 },
		physical             = true,
		collide_with_objects = false,
		stepheight           = 1.05, -- climb a full 1-block step (like an iron golem)
		backface_culling     = false,
		hp_max               = 49,            -- 7 diamond-sword hits (sword = 7 dmg each);
		                                      -- other weapons scale by their own damage
		armor_groups         = { fleshy = 100 }, -- takes full melee damage
	}
end

-- Push the textures for `stage` onto a live object.
local function apply_stage_visuals(object, stage)
	object:set_properties({ textures = mesh_textures(stage) })
end

--------------------------------------------------------------------------------
-- (B) BEHAVIOUR  --  oxidation timing + chest sorting
--------------------------------------------------------------------------------

----------------------------------------
-- B1. Oxidation (time-based, irreversible)
----------------------------------------
--
-- Given the golem's accumulated age in seconds, return which stage it should be
-- in. Monotonic and clamped to the terminal stage, so it can never go backwards.
local function stage_for_age(age_seconds)
	local stage = math.floor(age_seconds / config.seconds_per_stage) + 1
	if stage < 1 then stage = 1 end
	if stage > NUM_STAGES then stage = NUM_STAGES end
	return stage
end

----------------------------------------
-- B2. Chest sorting (gather like items together)
----------------------------------------
--
-- Uses only the core node-meta inventory API. No chest-mod accessor needed:
-- Mineclonia chests are plain meta inventories with a list named "main".

-- Is this node one of Mineclonia's chests (single, double halves, trapped)?
-- We match by mod prefix + "chest" in the name rather than hardcoding the full
-- list, so trapped/redstone variants are picked up automatically.
local function is_chest_node(name)
	if name:sub(1, 11) ~= "mcl_chests:" then return false end
	if name:find("ender", 1, true) then return false end -- per-player inv, skip
	return name:find("chest", 1, true) ~= nil
end

-- The explicit list of chest node names, built once after all mods load, so the
-- area scan below can hand it to core.find_nodes_in_area (a C-side query) instead
-- of a Lua triple-loop -- which keeps a large chest_radius cheap.
local CHEST_NODES = {}
core.register_on_mods_loaded(function()
	for name in pairs(core.registered_nodes) do
		if is_chest_node(name) then CHEST_NODES[#CHEST_NODES + 1] = name end
	end
end)

-- A stack is safe to merge only if it can actually stack (max > 1) and carries
-- no per-item state we'd destroy by rebuilding it (wear or metadata). Tools,
-- named items, damaged gear, etc. are therefore left exactly where they are.
local function is_mergeable(stack)
	if stack:is_empty() then return false end
	if stack:get_stack_max() <= 1 then return false end
	if stack:get_wear() ~= 0 then return false end
	local meta = stack:get_meta():to_table()
	if meta.fields and next(meta.fields) then return false end
	return true
end

-- Creative-inventory ordering, so the within-chest sort lays items out the way
-- Mineclonia's creative menu does: bucket every item into a category, then
-- order alphabetically by item id within it (which clusters families -- all the
-- stones, all the seeds -- because they share an id prefix). This replicates the
-- category test in Mineclonia's mcl_inventory/creative.lua (its category lists
-- are file-locals we can't read), evaluated lazily per item and cached.
local CAT_ORDER = { "blocks", "deco", "redstone", "rail", "food",
	"tools", "combat", "mobs", "brew", "matr", "misc" }
local CAT_INDEX = {}
for i, c in ipairs(CAT_ORDER) do CAT_INDEX[c] = i end

local function compute_kind(name, def)
	local g = def.groups or {}
	local function grp(n) return core.get_item_group(name, n) ~= 0 end
	if grp("building_block") then return CAT_INDEX.blocks end
	if grp("deco_block") then return CAT_INDEX.deco end
	if def._mcl_redstone or grp("redstone_wire") then return CAT_INDEX.redstone end
	if grp("transport") then return CAT_INDEX.rail end
	if (grp("food") and core.get_item_group(name, "brewitem") == 0) or grp("eatable") then return CAT_INDEX.food end
	if grp("tool") or (def.tool_capabilities and def.tool_capabilities.damage_groups == nil) then return CAT_INDEX.tools end
	if grp("weapon") or grp("weapon_ranged") or grp("ammo") or grp("combat_item")
		or ((grp("armor_head") or grp("armor_torso") or grp("armor_legs")
			or grp("armor_feet") or grp("horse_armor")) and g.non_combat_armor ~= 1) then
		return CAT_INDEX.combat
	end
	if grp("spawn_egg") then return CAT_INDEX.mobs end
	if grp("brewitem") then return CAT_INDEX.brew end
	if grp("craftitem") then return CAT_INDEX.matr end
	return CAT_INDEX.misc
end

local KIND = {}  -- item id -> category index (lazy cache)
local function item_rank(name)
	local k = KIND[name]
	if k then return k end
	local def = core.registered_items[name]
	k = def and compute_kind(name, def) or CAT_INDEX.misc
	KIND[name] = k
	return k
end

-- Total order over item ids: category first, then id string (the Creative order).
local function item_less(a, b)
	local ra, rb = item_rank(a), item_rank(b)
	if ra ~= rb then return ra < rb end
	return a < b
end

-- Collect every chest within `radius` nodes of `pos`.
-- Returns a list of { pos = <node pos>, inv = <InvRef> }.
local function nearby_chests(pos, radius)
	local found = {}
	if #CHEST_NODES == 0 then return found end          -- no chest mod loaded
	local minp = { x = pos.x - radius, y = pos.y - radius, z = pos.z - radius }
	local maxp = { x = pos.x + radius, y = pos.y + radius, z = pos.z + radius }
	for _, p in ipairs(core.find_nodes_in_area(minp, maxp, CHEST_NODES)) do
		local inv = core.get_inventory({ type = "node", pos = p })
		if inv and inv:get_size("main") > 0 then
			found[#found + 1] = { pos = p, inv = inv }
		end
	end
	return found
end

-- Take up to 16 of `name` out of the chest at `pos`, from the leftmost slot
-- holding it. Returns the taken ItemStack (empty if the item is gone now).
local function take_from_chest(pos, name)
	local inv = core.get_inventory({ type = "node", pos = pos })
	if not inv then return ItemStack("") end
	for idx, stack in ipairs(inv:get_list("main")) do
		if not stack:is_empty() and stack:get_name() == name then
			local take = math.min(16, stack:get_count())
			stack:set_count(stack:get_count() - take)
			inv:set_stack("main", idx, stack)
			local got = ItemStack(name)
			got:set_count(take)
			return got
		end
	end
	return ItemStack("")
end

-- Put as much of `stack` as fits into the chest at `pos`; returns the leftover
-- (empty if it all fit; the whole stack back if the chest node is gone).
local function put_in_chest(pos, stack)
	local inv = core.get_inventory({ type = "node", pos = pos })
	if not inv then return stack end
	return inv:add_item("main", stack)
end

-- Spill an itemstack onto the ground, so carried items are never destroyed.
local function drop_item(pos, stack)
	if stack and not stack:is_empty() then
		core.add_item({ x = pos.x, y = pos.y + 0.6, z = pos.z }, stack)
	end
end

----------------------------------------
-- B2a. Cosmetics: held item + chest lid
----------------------------------------

-- A tiny attached entity that draws the carried item in the golem's hand, the
-- way held items are shown. Created when the golem picks up, removed on drop.
core.register_entity("copper_golem:held", {
	initial_properties = {
		visual      = "wielditem",
		wield_item  = "",
		visual_size = { x = 0.3, y = 0.3, z = 0.3 }, -- tune: on-screen size of the item
		physical    = false,
		pointable   = false,
		collide_with_objects = false,
		static_save = false,
	},
	on_activate = function(self, staticdata)
		self._age = 0
		if staticdata and staticdata ~= "" then
			self.object:set_properties({ wield_item = staticdata })
		end
	end,
	-- Self-destruct if it ever loses its parent (golem unloaded/removed).
	on_step = function(self, dtime)
		self._age = self._age + dtime
		if self._age > 1 and not self.object:get_attach() then
			self.object:remove()
		end
	end,
})

-- Right-hand attachment for the held item. Offsets are in the golem model's own
-- units (1 px = 0.625 units); the arm_r hand sits ~6 units below the arm bone
-- pivot. TUNE in-game until the item sits nicely in the hand.
local HELD_BONE   = "arm_r"
local HELD_OFFSET = vector.new(0, -5.5, 1.5)
local HELD_ROT    = vector.new(0, 0, 0)

local function hide_held(self)
	if self._held_obj then
		if self._held_obj:get_luaentity() then self._held_obj:remove() end
		self._held_obj = nil
	end
end

local function show_held(self, itemname)
	hide_held(self)
	if not itemname or itemname == "" then return end
	local obj = core.add_entity(self.object:get_pos(), "copper_golem:held", itemname)
	if obj then
		obj:set_attach(self.object, HELD_BONE, HELD_OFFSET, HELD_ROT)
		self._held_obj = obj
	end
end

-- Mineclonia animates a chest via a separate lid entity ("mcl_chests:chest")
-- that tracks who has it open through :open(key)/:close(key). We drive it with a
-- key unique to this golem, so the lid opens/closes for the golem just like for a
-- player -- and won't slam shut on a player who also has it open. No-ops if the
-- lid entity isn't there (animated chests off, or not spawned yet).
-- Return the chest lid entity for the chest at `pos`: the CLOSEST
-- "mcl_chests:chest" entity, not just the first found. This matters in a room of
-- adjacent chests, where several lid entities fall inside any generous radius --
-- grabbing a neighbour's was what left chests stuck open (the lid keyed at open
-- time differed from the one found at close time, so the golem's opener key was
-- never removed and even players couldn't close it). A double chest's single lid
-- sits at the midpoint ~0.5 from each node; a neighbour's lid is >=1.0 away, so
-- nearest reliably picks the right one.
local function chest_lid_entity(pos)
	local best, bestd
	for _, obj in ipairs(core.get_objects_inside_radius(pos, 1.0)) do
		local l = obj:get_luaentity()
		if l and l.name == "mcl_chests:chest" then
			local op = obj:get_pos()
			local d = op and vector.distance(op, pos) or math.huge
			if not bestd or d < bestd then best, bestd = l, d end
		end
	end
	return best
end

local function open_chest_lid(self, pos)
	local lid = chest_lid_entity(pos)
	if lid then lid:open(tostring(self.object)) end
	self._lid_obj = lid   -- remember the EXACT entity so we close this one, not a neighbour
	self._lid_pos = pos
	self._lid_age = 0
end

local function close_chest_lid(self)
	local key = tostring(self.object)
	-- Close the exact entity we opened; if it's gone/replaced, fall back to the
	-- nearest one. Either way clear our tracking so a key can never be left behind.
	local lid = self._lid_obj
	if not (lid and lid.object and lid.object:get_pos()) then
		lid = self._lid_pos and chest_lid_entity(self._lid_pos) or nil
	end
	if lid then lid:close(key) end
	self._lid_obj = nil
	self._lid_pos = nil
end

-- Pick one sorting job: a mergeable stack sitting in a chest that is NOT its
-- "home" (the nearby chest already holding the most of that item), whose home
-- still has room. Carrying it toward the bigger pile gathers like with like
-- (BotW-style); since every move grows the largest pile it always converges,
-- so no memory of past chests is needed. Returns { src=<pos>, name=<item>,
-- dest=<pos> }, or nil when nothing is out of place.
-- The centre of mass of a chest list: the golem's "workplace". The wander uses
-- it as a soft anchor so the golem loiters by the chests it tends instead of
-- roaming off. Returns nil for an empty list (caller keeps its previous anchor).
local function chest_centroid(chests)
	if #chests == 0 then return nil end
	local sx, sy, sz = 0, 0, 0
	for _, c in ipairs(chests) do
		sx, sy, sz = sx + c.pos.x, sy + c.pos.y, sz + c.pos.z
	end
	return { x = sx / #chests, y = sy / #chests, z = sz / #chests }
end

-- `skip` (optional) is a set of core.hash_node_position(chest pos) we currently
-- treat as unreachable; jobs touching one are passed over so the golem doesn't
-- keep re-picking a chest it can't actually get to.
local function plan_sort_job(chests, skip)
	if #chests < 2 then return nil end           -- need a source and a separate home
	local blocked = skip and function(p) return skip[core.hash_node_position(p)] end
		or function() return false end

	-- For each item type, find its home = the chest holding the most of it
	-- (ties broken by the earliest chest in scan order). Store the chest TABLE
	-- so we can compare it by reference below.
	local home = {} -- name -> { chest = <chest>, count = N }
	for _, chest in ipairs(chests) do
		local counts = {}
		for _, stack in ipairs(chest.inv:get_list("main")) do
			if is_mergeable(stack) then
				local n = stack:get_name()
				counts[n] = (counts[n] or 0) + stack:get_count()
			end
		end
		for name, n in pairs(counts) do
			if not home[name] or n > home[name].count then
				home[name] = { chest = chest, count = n }
			end
		end
	end

	-- The first stack that is away from its home AND whose home has room is the
	-- job. (If a home is full, that item just stays put -- natural overflow.)
	for _, chest in ipairs(chests) do
		for _, stack in ipairs(chest.inv:get_list("main")) do
			if is_mergeable(stack) then
				local h = home[stack:get_name()]
				if h.chest ~= chest
						and h.chest.inv:room_for_item("main", ItemStack(stack:get_name()))
						and not blocked(chest.pos) and not blocked(h.chest.pos) then
					return { src = chest.pos, name = stack:get_name(), dest = h.chest.pos }
				end
			end
		end
	end
	return nil
end

----------------------------------------
-- B2b. Ground pickup (loose dropped items -> a chest)
----------------------------------------
--
-- Dropped items are plain "__builtin:item" luaentities carrying an
-- `itemstring` field. We don't touch anything else that might be flying
-- around nearby (players, mobs, the golem's own held-item/lid cosmetics).
local function is_dropped_item_entity(ent)
	return ent ~= nil and ent.name == "__builtin:item"
		and ent.itemstring and ent.itemstring ~= ""
end

-- Every loose item entity within `radius` nodes of `pos`.
local function nearby_dropped_items(pos, radius)
	local found = {}
	for _, obj in ipairs(core.get_objects_inside_radius(pos, radius)) do
		local ent = obj:get_luaentity()
		if is_dropped_item_entity(ent) then
			found[#found + 1] = obj
		end
	end
	return found
end

-- Pick the closest reachable dropped item and a chest to carry it into (the
-- chest already holding the most of that item, same "gather like with like"
-- rule as the chest-to-chest sorter; falls back to any chest with room for a
-- kind that isn't in a chest yet). Returns { obj = <object>, dest = <pos> },
-- or nil if there's nothing to pick up right now.
local function plan_pickup_job(chests, pos, skip)
	if #chests == 0 then return nil end
	local blocked = skip and function(p) return skip[core.hash_node_position(p)] end
		or function() return false end

	local items = nearby_dropped_items(pos, config.pickup_radius)
	if #items == 0 then return nil end
	table.sort(items, function(a, b)
		return vector.distance(pos, a:get_pos()) < vector.distance(pos, b:get_pos())
	end)

	for _, obj in ipairs(items) do
		local ent = obj:get_luaentity()
		local stack = ItemStack(ent.itemstring)
		local name  = stack:get_name()
		if name ~= "" and core.registered_items[name] then
			local dest, best_count = nil, -1
			for _, chest in ipairs(chests) do
				if not blocked(chest.pos) and chest.inv:room_for_item("main", stack) then
					local n = 0
					if is_mergeable(stack) then
						for _, s in ipairs(chest.inv:get_list("main")) do
							if s:get_name() == name then n = n + s:get_count() end
						end
					end
					if n > best_count then best_count, dest = n, chest.pos end
				end
			end
			if dest then return { obj = obj, dest = dest } end
		end
	end
	return nil
end

-- In-place tidy of a SINGLE chest (the original behaviour): merge each item's
-- partial stacks into the fewest stacks possible, reusing the slots it already
-- occupies (full stacks first, leftovers emptied). The courier handles moving
-- items between chests; this handles compacting them within one. Only writes a
-- slot when it actually changes (so it doesn't disturb an open chest formspec).
-- Returns true if anything changed.
local function compact_chest(inv)
	local list = inv:get_list("main")
	local total, slots_of = {}, {}
	for idx, stack in ipairs(list) do
		if is_mergeable(stack) then
			local n = stack:get_name()
			total[n] = (total[n] or 0) + stack:get_count()
			slots_of[n] = slots_of[n] or {}
			slots_of[n][#slots_of[n] + 1] = idx
		end
	end
	local changed = false
	for name, slots in pairs(slots_of) do
		local remaining = total[name]
		local maxn = ItemStack(name):get_stack_max()
		for _, idx in ipairs(slots) do
			local put = math.min(remaining, maxn)
			remaining = remaining - put
			local newstack = put > 0 and ItemStack(name .. " " .. put) or ItemStack("")
			if newstack:to_string() ~= list[idx]:to_string() then
				inv:set_stack("main", idx, newstack)
				changed = true
			end
		end
	end
	return changed
end

-- Tidy every chest within range; returns the positions that changed (for the
-- "working" particles). Used as the golem's fallback job when nothing needs
-- carrying between chests.
local function compact_nearby(chests)
	local changed = {}
	for _, c in ipairs(chests) do
		if compact_chest(c.inv) then changed[#changed + 1] = c.pos end
	end
	return changed
end

----------------------------------------
-- B2c. Within-chest Creative-style sort (the animated shuffle)
----------------------------------------
--
-- Builds the desired Creative-order layout for ONE chest and the sequence of
-- single-stack moves to reach it -- the golem then performs those moves one at a
-- time, picking each stack up into its hand and setting it down, so you watch it
-- physically organise the grid. The hand IS the spare buffer slot, so it works
-- even on a chest with no free slot.
--
-- SAFETY: nothing here can lose or duplicate an item. The move list only ever
-- contains legal moves (verified per-move against the live chest at run time, and
-- proven by tests/), and the chest is snapped to the exact target with a single
-- atomic set_list ONLY when its item totals still equal the target's. If a player
-- changes the chest mid-sort, that guard fails and we leave the chest untouched.

-- A signature -> total-count map of a chest's contents, distinguishing wear and
-- metadata so a worn/named stack is never treated as interchangeable with a plain
-- one. Used to prove a reorder is a pure rearrangement before committing it.
local function inv_totals(list)
	local t = {}
	for _, s in ipairs(list) do
		if not s:is_empty() then
			local m = s:get_meta():to_table()
			local meta = (m.fields and next(m.fields)) and core.serialize(m.fields) or ""
			local key = s:get_name() .. "|" .. s:get_wear() .. "|" .. meta
			t[key] = (t[key] or 0) + s:get_count()
		end
	end
	return t
end

local function totals_match(a, b)
	for k, v in pairs(a) do if b[k] ~= v then return false end end
	for k, v in pairs(b) do if a[k] ~= v then return false end end
	return true
end

-- Synthetic key prefix for stacks that must NOT be merged or split (tools with
-- wear, named/metadata items): each gets a unique token so the planner moves it
-- whole and never combines two different ones.
local SORT_NM = "\1nm"

----------------------------------------
-- Chest "unit": treat a double chest as ONE inventory
----------------------------------------
--
-- A Mineclonia double chest is two separate nodes (`..._left` / `..._right`),
-- each with its own 27-slot "main" list; the formspec just stacks them (top 3
-- rows = the left node, bottom 3 = the right node). So the golem must sort across
-- BOTH halves as a single 54-slot grid, or it organises each half on its own.
--
-- A "unit" is a list of parts { pos = <node pos>, size = <slots> } in the same
-- order the formspec shows them (left/top first). A single chest is a one-part
-- unit, so all the sort code can stay unit-based and not special-case doubles.

local function part_inv(pos)
	return core.get_inventory({ type = "node", pos = pos })
end

-- Map a 1-based logical slot in the combined grid to its (node pos, node slot).
local function part_locate(parts, idx)
	for _, p in ipairs(parts) do
		if idx <= p.size then return p.pos, idx end
		idx = idx - p.size
	end
end

-- The combined "main" list across all parts (list of ItemStack), or nil if any
-- node inventory is gone.
local function unit_combined_list(parts)
	local list = {}
	for _, p in ipairs(parts) do
		local inv = part_inv(p.pos)
		if not inv then return nil end
		local l = inv:get_list("main")
		for i = 1, p.size do list[#list + 1] = l[i] or ItemStack("") end
	end
	return list
end

-- Write a combined target list back, split across the parts. Returns false if a
-- node inventory vanished.
local function unit_set_list(parts, target)
	local off = 0
	for _, p in ipairs(parts) do
		local inv = part_inv(p.pos)
		if not inv then return false end
		local slice = {}
		for i = 1, p.size do slice[i] = target[off + i] or ItemStack("") end
		inv:set_list("main", slice)
		off = off + p.size
	end
	return true
end

-- Resolve a chest node into a unit. For a double chest returns BOTH halves in
-- formspec order (left/top first) and flags when the queried node is the right
-- half (so the scan can de-dupe and only act once per pair). Falls back to a
-- single-node unit if the optional mcl_util helper isn't present.
local function chest_unit(pos)
	local node = core.get_node(pos)
	local name, p2 = node.name, node.param2
	local positions, secondary = nil, false
	local mu = rawget(_G, "mcl_util")
	if mu and mu.get_double_container_neighbor_pos then
		if name:sub(-5) == "_left" then
			local other = mu.get_double_container_neighbor_pos(pos, p2, "left")
			if other and is_chest_node(core.get_node(other).name) then
				positions = { pos, other }            -- left (top) then right (bottom)
			end
		elseif name:sub(-6) == "_right" then
			local other = mu.get_double_container_neighbor_pos(pos, p2, "right")
			if other and is_chest_node(core.get_node(other).name) then
				positions = { other, pos }            -- partner (left) first
				secondary = true
			end
		end
	end
	if not positions then positions = { pos } end
	local parts = {}
	for _, p in ipairs(positions) do
		local inv = part_inv(p)
		if not inv then return nil end
		parts[#parts + 1] = { pos = p, size = inv:get_size("main") }
	end
	return { parts = parts, primary = parts[1].pos, secondary = secondary }
end

-- Plan the reorder of a chest unit (single or double). Returns nil if it is
-- already in order, else { target = <combined list>, moves = <{from,to,count}> }.
local function plan_reorder(parts)
	local list = unit_combined_list(parts)
	if not list then return nil end
	local N = #list
	if N == 0 then return nil end

	local cur = {}        -- planner cells, parallel to the slots
	local merged = {}     -- mergeable item id -> total count
	local morder = {}     -- distinct mergeable ids, in first-seen order
	local nmunits = {}    -- non-mergeable units: { name, key, count, max, stack }
	local nmid = 0
	for i = 1, N do
		local s = list[i]
		if s:is_empty() then
			cur[i] = false
		elseif is_mergeable(s) then
			local nm = s:get_name()
			cur[i] = { key = nm, count = s:get_count(), max = s:get_stack_max() }
			if not merged[nm] then merged[nm] = 0; morder[#morder + 1] = nm end
			merged[nm] = merged[nm] + s:get_count()
		else
			nmid = nmid + 1
			local key = SORT_NM .. nmid
			local c = s:get_count()
			cur[i] = { key = key, count = c, max = c }
			nmunits[#nmunits + 1] = { name = s:get_name(), key = key, count = c, max = c, stack = s }
		end
	end

	-- One "unit" per target slot: mergeable totals split into full-stack-first
	-- chunks, non-mergeables kept whole. Then order everything by Creative order.
	local units = {}
	for _, nm in ipairs(morder) do
		local total, mx = merged[nm], ItemStack(nm):get_stack_max()
		while total > 0 do
			local c = math.min(total, mx)
			units[#units + 1] = { name = nm, key = nm, count = c, max = mx }
			total = total - c
		end
	end
	for _, u in ipairs(nmunits) do units[#units + 1] = u end
	table.sort(units, function(a, b)
		if a.name ~= b.name then return item_less(a.name, b.name) end
		if a.key ~= b.key then return a.key < b.key end  -- stable: group same-item units
		return a.count > b.count                          -- fuller stacks first
	end)

	-- Target cells (for the planner) and target ItemStacks (for the atomic snap).
	local tgt, target = {}, {}
	for i = 1, N do
		local u = units[i]
		if u then
			tgt[i] = { key = u.key, count = u.count, max = u.max }
			target[i] = u.stack or ItemStack(u.name .. " " .. u.count)
		else
			tgt[i] = false
			target[i] = ItemStack("")
		end
	end

	-- Already in order? Then there's nothing to do.
	local same = true
	for i = 1, N do
		if list[i]:to_string() ~= target[i]:to_string() then same = false; break end
	end
	if same then return nil end

	local moves = sortlib.plan(cur, tgt)
	return { target = target, moves = moves }
end

----------------------------------------
-- B3. Movement AI (simple self-contained state machine)
----------------------------------------
--
-- Four modes, no pathfinding, no mob framework -- just velocity + yaw +
-- animation swaps:
--   "idle"      stand still for a random pause
--   "walk"      stroll a random heading for a random burst
--   "to_source" head to the chest holding a misplaced stack (planned every
--               organize_cooldown seconds) and pick up <=16 of it
--   "to_dest"   carry that stack to its home chest and deposit it, with
--               particles over the chest; overflow/unreachable items are dropped
--
-- Fields on `self`:
--   _mode           : one of the four strings above
--   _mode_timer     : seconds left in the current mode
--   _job            : { src, name, dest } the current sort job
--   _carry          : ItemStack being carried from source to destination
--   _organize_cool  : seconds until the next sort trip
--   _anim           : animation currently playing (avoid pointless resets)

local function set_anim(self, name)
	if self._anim == name then return end -- don't restart a looping animation
	self._anim = name
	self.object:set_animation(ANIM[name], ANIM_SPEED, 0, true)
end

local function halt(self)
	local v = self.object:get_velocity()
	self.object:set_velocity({ x = 0, y = v.y, z = 0 })
end

-- Bleed off horizontal velocity while the golem is standing still. Luaentities
-- have no ground friction, so a punch's knockback would otherwise make the golem
-- slide forever as if on ice (a frozen golem looked fine only because its freeze
-- branch hard-halts every tick). Frame-rate-correct decay: a quick shove that
-- settles in a fraction of a second, then snaps to a dead stop.
local function ground_friction(self, dtime)
	local v = self.object:get_velocity()
	if v.x * v.x + v.z * v.z < 0.01 then
		if v.x ~= 0 or v.z ~= 0 then self.object:set_velocity({ x = 0, y = v.y, z = 0 }) end
	else
		local f = math.max(0, 1 - 8 * (dtime or 0))
		self.object:set_velocity({ x = v.x * f, y = v.y, z = v.z * f })
	end
end

-- Drive horizontal velocity along the current yaw every step, so wall
-- collisions (which zero a component) don't leave the golem drifting.
local function push_forward(self, speed)
	local yaw = self.object:get_yaw()
	local v   = self.object:get_velocity()
	self.object:set_velocity({
		x = -math.sin(yaw) * speed,
		y = v.y,
		z =  math.cos(yaw) * speed,
	})
end

-- Face a world position (yaw convention matches push_forward).
local function face_pos(self, target)
	local pos = self.object:get_pos()
	self.object:set_yaw(math.atan2(-(target.x - pos.x), target.z - pos.z))
end

-- 0 when the golem has work / just finished some; ramps to 1 the longer it has
-- had nothing to do. Scales how calm the wander is (rests, stroll length, range).
local function calm_factor(self)
	if config.calm_after <= 0 then return 0 end
	return math.min((self._idle_streak or 0) / config.calm_after, 1)
end

local function start_walk(self)
	self._mode = "walk"
	local calm = calm_factor(self)
	-- Calmer => shorter strolls (down to ~40% of the burst length when fully settled).
	self._mode_timer = (math.random() * (config.walk_time_max - config.walk_time_min)
		+ config.walk_time_min) * (1 - 0.6 * calm)

	-- Heading: if the golem has drifted away from the chests it tends, steer back
	-- toward them so it stays near its workplace; otherwise pick a random heading,
	-- but the calmer it is the more it leans homeward rather than roaming off.
	local pos = self.object:get_pos()
	local yaw
	if self._home and pos then
		local d = vector.distance(pos, self._home)
		if d > config.chest_radius or (calm > 0 and math.random() < calm) then
			yaw = math.atan2(-(self._home.x - pos.x), self._home.z - pos.z)
		end
	end
	self.object:set_yaw(yaw or math.random() * (2 * math.pi))
	set_anim(self, "walk")
end

-- Dumb obstacle avoidance: head for `target`, but if we stop making progress
-- (walked into a wall taller than the 1-block step) sidestep at an angle for a
-- moment, then resume. Cheap and good enough for short indoor chest hops.
local DETOUR_TRIGGER = 1.0          -- seconds of no progress before sidestepping
local DETOUR_TIME    = 0.7          -- seconds spent sidestepping
local DETOUR_ANGLE   = math.rad(75) -- how far to turn off course when stuck

local function travel_toward(self, target, speed_factor, dtime)
	if (self._detour_time or 0) > 0 then
		self._detour_time = self._detour_time - dtime
		self.object:set_yaw(self._detour_yaw)
	else
		face_pos(self, target)
		local pos   = self.object:get_pos()
		local moved = self._last_pos and vector.distance(pos, self._last_pos) or 1
		if moved < 0.04 then
			self._stuck_time = (self._stuck_time or 0) + dtime
			if self._stuck_time > DETOUR_TRIGGER then
				self._stuck_time  = 0
				local side = (math.random() < 0.5) and 1 or -1
				self._detour_yaw  = self.object:get_yaw() + side * DETOUR_ANGLE
				self._detour_time = DETOUR_TIME
			end
		else
			self._stuck_time = 0
		end
		self._last_pos = pos
	end
	push_forward(self, config.seek_speed * speed_factor)
end

-- Engine A* pathfinding -- the same builtin Mineclonia's mobs/villagers use --
-- so the golem routes AROUND obstacles instead of pushing into them, and knows
-- when a chest simply can't be reached. A chest node is solid (walkable), so the
-- pathfinder can't stand ON it; we aim at the chest, and if that yields nothing
-- we try the four floor tiles beside it (one of them is where the golem stands
-- to open it). Returns a waypoint list, or nil when there is no path at all.
-- Floor tiles a golem might stand on to reach a chest: the 4 orthogonal AND 4
-- diagonal neighbours (a chest tucked in a corner may only be approachable from a
-- diagonal). Each is tried at the chest's level, one step down, and one step up,
-- since the standable tile beside a chest can sit at any of those on uneven ground.
local PATH_NEIGHBORS = {
	{ x = 1, z = 0 }, { x = -1, z = 0 }, { x = 0, z = 1 }, { x = 0, z = -1 },
	{ x = 1, z = 1 }, { x = 1, z = -1 }, { x = -1, z = 1 }, { x = -1, z = -1 },
}
local PATH_DY = { 0, -1, 1 }
local function compute_path(self, target)
	local pos = self.object:get_pos()
	if not pos then return nil end
	local s = { x = math.floor(pos.x + 0.5), y = math.floor(pos.y + 0.5), z = math.floor(pos.z + 0.5) }
	local g = { x = math.floor(target.x + 0.5), y = math.floor(target.y + 0.5), z = math.floor(target.z + 0.5) }
	local sd = config.chest_radius + 6   -- search budget: a bit past the work radius
	-- max_jump 1 matches the 1.05 stepheight; max_drop 2 lets it path down ledges.
	local way = core.find_path(s, g, sd, 1, 2, "A*_noprefetch")
	if way then return way end
	-- A chest node is solid, so the pathfinder can't stand on it -- aim instead at a
	-- standable floor tile beside it. The extra candidates (and the level offsets)
	-- are only reached when the direct attempt fails, i.e. when we're about to give
	-- up anyway, so the cost is bounded.
	for _, dy in ipairs(PATH_DY) do
		for _, n in ipairs(PATH_NEIGHBORS) do
			way = core.find_path(s, { x = g.x + n.x, y = g.y + dy, z = g.z + n.z }, sd, 1, 2, "A*_noprefetch")
			if way then return way end
		end
	end
	return nil
end

-- Walk toward `target` along a pathfound route, recomputing periodically. Returns
-- "moving" while it makes its way there, or "blocked" when no path exists -- the
-- caller's cue to give up on this chest rather than shove against a wall. We still
-- hand each leg to travel_toward, whose short sidestep handles the fine wiggle of
-- bumping another entity between waypoints.
local function follow_path(self, target, speed_factor, dtime)
	self._path_cool = (self._path_cool or 0) - dtime
	-- (Re)plan when we have no route, the goal moved, or the timer elapsed.
	local goal_moved = not self._path_goal or vector.distance(self._path_goal, target) > 1
	if not self._path or self._path_cool <= 0 or goal_moved then
		local way = compute_path(self, target)
		self._path_cool = config.path_recheck
		if not way then
			self._path, self._path_goal = nil, nil
			return "blocked"
		end
		self._path, self._path_goal, self._path_idx = way, vector.new(target), 1
	end

	-- Drop waypoints we've reached so we always steer toward the next one.
	local pos = self.object:get_pos()
	while self._path[self._path_idx] do
		local wp = self._path[self._path_idx]
		local dx, dz = wp.x - pos.x, wp.z - pos.z
		if dx * dx + dz * dz > 0.6 * 0.6 then break end
		self._path_idx = self._path_idx + 1
	end

	-- Steer to the next waypoint, or straight at the target once they're consumed.
	travel_toward(self, self._path[self._path_idx] or target, speed_factor, dtime)
	return "moving"
end

-- Remember a chest we just failed to reach so plan_sort_job skips it for a while,
-- instead of re-picking the same unreachable job and trotting at the wall again.
local function mark_unreachable(self, pos)
	if not pos then return end
	self._unreachable = self._unreachable or {}
	self._unreachable[core.hash_node_position(pos)] = core.get_us_time() / 1e6 + config.unreachable_ttl
end

-- Set of currently-blacklisted chest position hashes (expired entries pruned).
local function unreachable_set(self)
	local set = self._unreachable
	if not set then return nil end
	local now, any = core.get_us_time() / 1e6, false
	for hash, expiry in pairs(set) do
		if expiry <= now then set[hash] = nil else any = true end
	end
	return any and set or nil
end

-- Give-up fallback while carrying: tuck the item into a nearby chest (preferring
-- one that already holds it, to stay grouped) instead of littering the floor.
-- Only drops what genuinely won't fit anywhere in range.
local function stash_or_drop(self, pos)
	if not self._carry or self._carry:is_empty() then hide_held(self); return end
	local name   = self._carry:get_name()
	local chests = nearby_chests(pos, config.chest_radius)
	for _, c in ipairs(chests) do          -- first, chests already holding this item
		if c.inv:contains_item("main", ItemStack(name)) then
			self._carry = c.inv:add_item("main", self._carry)
			if self._carry:is_empty() then break end
		end
	end
	for _, c in ipairs(chests) do          -- then any chest with room
		if self._carry:is_empty() then break end
		self._carry = c.inv:add_item("main", self._carry)
	end
	drop_item(pos, self._carry)            -- whatever's left over
	self._carry = ItemStack("")
	hide_held(self)
end

local function start_idle(self)
	self._mode = "idle"
	-- Calmer => longer pauses (up to ~2.5x) so a golem with no work mostly rests.
	self._mode_timer = (math.random() * (config.idle_time_max - config.idle_time_min)
		+ config.idle_time_min) * (1 + 1.5 * calm_factor(self))
	close_chest_lid(self) -- safety: never wander off leaving a lid open
	self._detour_time = 0
	self._stuck_time  = 0
	-- Forget any seek route; a fresh job replans its own. (Inlined rather than
	-- calling clear_path, which is defined further down.)
	self._path, self._path_goal, self._path_idx, self._path_cool = nil, nil, nil, nil
	halt(self)
	-- Occasionally glance around (head yaw clip) instead of standing dead still.
	set_anim(self, math.random() < 0.4 and "look" or "stand")
end

-- Copper sparkles over a chest the golem just sorted into.
local function work_particles(chest_pos)
	core.add_particlespawner({
		amount = 10, time = 0.6,
		minpos = vector.offset(chest_pos, -0.4, 0.55, -0.4),
		maxpos = vector.offset(chest_pos,  0.4, 0.9,  0.4),
		minvel = { x = -0.2, y = 0.3, z = -0.2 },
		maxvel = { x =  0.2, y = 0.8, z =  0.2 },
		minexptime = 0.4, maxexptime = 0.9,
		minsize = 0.8, maxsize = 1.6,
		texture = "mcl_copper_block.png",
	})
end

-- Burst when an axe scrapes a tier of oxidation (or the wax) off the golem.
local function scrape_particles(pos, texture)
	core.add_particlespawner({
		amount = 14, time = 0.3,
		minpos = vector.offset(pos, -0.3, 0.2, -0.3),
		maxpos = vector.offset(pos,  0.3, 1.2,  0.3),
		minvel = { x = -0.6, y = 0.4, z = -0.6 },
		maxvel = { x =  0.6, y = 1.0, z =  0.6 },
		minexptime = 0.3, maxexptime = 0.7,
		minsize = 0.7, maxsize = 1.4,
		texture = texture or "mcl_copper_block.png",
	})
end

-- A flourish of rising gold stars -- feedback for axe de-oxidation.
local function star_particles(pos)
	core.add_particlespawner({
		amount = 16, time = 0.3,
		minpos = vector.offset(pos, -0.3, 0.1, -0.3),
		maxpos = vector.offset(pos,  0.3, 1.2,  0.3),
		minvel = { x = -0.5, y = 0.6, z = -0.5 },
		maxvel = { x =  0.5, y = 1.4, z =  0.5 },
		minacc = { x = 0, y = -1, z = 0 }, maxacc = { x = 0, y = -2, z = 0 },
		minexptime = 0.5, maxexptime = 1.0,
		minsize = 0.7, maxsize = 1.6,
		texture = "copper_golem_star.png",
		glow = 14,
	})
end

-- Destroy the golem (killable like an iron golem): drop its loot + whatever it
-- was carrying, clean up its cosmetics, and remove it.
local DEATH_DROP_MIN, DEATH_DROP_MAX = 1, 3 -- copper ingots dropped on death
local function golem_die(self)
	local pos = self.object:get_pos()
	if pos then
		drop_item(pos, self._carry)        -- never swallow a carried item
		for _ = 1, math.random(DEATH_DROP_MIN, DEATH_DROP_MAX) do
			core.add_item(pos, "mcl_copper:copper_ingot")
		end
		scrape_particles(pos)              -- copper bursts apart
	end
	self._carry = ItemStack("")
	close_chest_lid(self)
	hide_held(self)
	self.object:remove()
end

-- Water interaction (step 4): the golem won't stroll off dry land INTO surface
-- water, but once submerged it just trudges along the bottom (gravity already
-- sinks it; no breath system, so it never drowns). Water contact also speeds up
-- oxidation -- unless waxed, which halts oxidation entirely.
local WATER_OXIDATION_MULT = 3.0   -- oxidation rate multiplier while in water

local function is_water_name(name)
	return core.get_item_group(name, "water") > 0
end

-- Standing in water? (feet node submerged)
local function in_water(self)
	local pos = self.object:get_pos()
	return pos ~= nil and is_water_name(core.get_node(
		{ x = pos.x, y = pos.y + 0.1, z = pos.z }).name)
end

-- Surface water directly ahead at foot level (along the current heading)?
local function water_ahead(self)
	local pos = self.object:get_pos()
	if not pos then return false end
	local yaw = self.object:get_yaw()
	return is_water_name(core.get_node({
		x = pos.x - math.sin(yaw) * 0.8,
		y = pos.y + 0.1,
		z = pos.z + math.cos(yaw) * 0.8,
	}).name)
end

-- Wall directly ahead that the golem can NOT step over? We probe a node-width
-- in front at ~1.2 nodes up -- above the 1.05 stepheight -- so a single 1-block
-- ledge (which it auto-climbs) reads as clear, but a 2+ high wall reads as
-- blocked. This is the "lidar" the plain wander was missing: it lets the stroll
-- turn away from walls instead of grinding into them like a bumper-bot.
local function wall_ahead(self)
	local pos = self.object:get_pos()
	if not pos then return false end
	local yaw = self.object:get_yaw()
	local def = core.registered_nodes[core.get_node({
		x = pos.x - math.sin(yaw) * 0.7,
		y = pos.y + 1.2,
		z = pos.z + math.cos(yaw) * 0.7,
	}).name]
	return def ~= nil and def.walkable
end

-- Oxidation slows the golem down (100% / 75% / 50% / frozen),
-- indexed by _stage 1..4. At the terminal stage the factor is 0: it seizes up.
local STAGE_SPEED = { 1.0, 0.75, 0.5, 0.0 }
local LIGHTNING_BOOST      = 2.0  -- speed multiplier during the post-lightning charge
local LIGHTNING_BOOST_TIME = 8    -- seconds the hyper-charge lasts

-- Leash following (SilverSandstone's "leads" mod; optional, no hard dependency).
-- The mod attaches a lead and pulls the follower with add_velocity once the rope
-- goes taut (its default length is 8 nodes). We keep the golem trotting to within
-- this distance of whoever holds the rope, so it follows like a pet and never
-- fights the pull (we'd lose the tug-of-war anyway -- our AI set_velocitys every
-- step, the pull only add_velocitys). Kept well below the 8-node taut point.
local LEASH_FOLLOW_DIST = 3.0

-- The position of the thing on the OTHER end of our lead (the player or fence
-- knot), or nil when not leashed / the lead is gone. self._leash is the lead
-- luaentity, set by the _leads_lead_add callback; self._leash_is_leader records
-- which end we are, so we follow the opposite connector.
local function leash_anchor(self)
	local lead = self._leash
	if not lead or not lead.object or not lead.object:get_pos() then
		self._leash = nil          -- lead removed/unloaded; forget it
		return nil
	end
	local other = self._leash_is_leader and lead.follower or lead.leader
	if not other or not other.get_pos then return nil end
	return other:get_pos()
end

----------------------------------------
-- B2c (cont.) Animated-sort executor
----------------------------------------

-- Bail out of an in-progress chest reorder without risk: return any in-hand
-- stack to the world via stash_or_drop (tucked into a chest, else dropped -- never
-- lost), let go of the lid, and idle. Used on timeouts, blocked paths, or when the
-- chest changes under us.
local function abort_sort(self, pos)
	if self._carry and not self._carry:is_empty() then
		stash_or_drop(self, pos or self.object:get_pos())
	end
	hide_held(self)
	close_chest_lid(self)
	self._sort = nil
	self._organize_cool = 4
	start_idle(self)
end

-- The reorder queue has drained (or there was nothing to animate): snap the chest
-- to the exact target layout, but ONLY if its item totals still match the target
-- (a pure rearrangement). If they don't -- a player edited it mid-sort -- leave it
-- alone. Either way no item is lost.
local function finalize_sort(self, job)
	local cur = unit_combined_list(job.parts)
	if cur and totals_match(inv_totals(cur), inv_totals(job.target)) then
		unit_set_list(job.parts, job.target)
		work_particles(job.pos)
	end
	if self._carry and not self._carry:is_empty() then
		stash_or_drop(self, self.object:get_pos())   -- paranoia: queue should drain empty-handed
	end
	hide_held(self)
	self._sort = nil
	self._organize_cool = config.organize_cooldown
	start_idle(self)
end

-- One beat of the reorder. Alternates "pickup" (take move.from into the hand,
-- shown in-hand) and "putdown" (place the hand into move.to). Every step first
-- re-checks the live chest against what the plan expects; any mismatch (a player
-- touched the chest) aborts safely rather than misplacing items.
local function sort_step(self, job)
	local mv = job.moves[job.idx]
	if not mv then finalize_sort(self, job); return end

	-- Resolve each endpoint to its node + slot (a move may cross between the two
	-- halves of a double chest -- that's the whole point).
	local fpos, fslot = part_locate(job.parts, mv.from)
	local tpos, tslot = part_locate(job.parts, mv.to)
	local finv = fpos and part_inv(fpos)
	local tinv = tpos and part_inv(tpos)
	if not finv or not tinv then abort_sort(self, self.object:get_pos()); return end

	if job.phase == "pickup" then
		local s = finv:get_stack("main", fslot)
		if s:is_empty() or s:get_count() < mv.count then
			abort_sort(self, self.object:get_pos()); return   -- source changed under us
		end
		-- Take exactly mv.count. For a whole-stack move keep the original stack so
		-- wear/metadata ride along; otherwise build a plain count of that item.
		local got
		if s:get_count() == mv.count then
			got = ItemStack(s:to_string())
			finv:set_stack("main", fslot, ItemStack(""))
		else
			got = ItemStack(s:get_name() .. " " .. mv.count)
			s:set_count(s:get_count() - mv.count)
			finv:set_stack("main", fslot, s)
		end
		self._carry = got
		show_held(self, got:get_name())
		job.phase = "putdown"
	else
		local carry = self._carry
		local dst = tinv:get_stack("main", tslot)
		if dst:is_empty() then
			tinv:set_stack("main", tslot, carry)
		elseif dst:get_name() == carry:get_name()
				and dst:get_count() + carry:get_count() <= dst:get_stack_max() then
			dst:set_count(dst:get_count() + carry:get_count())
			tinv:set_stack("main", tslot, dst)
		else
			-- Destination unexpectedly occupied: put the carry back if its source is
			-- still free, then abort without misplacing anything.
			if finv:get_stack("main", fslot):is_empty() then
				finv:set_stack("main", fslot, carry)
				self._carry = ItemStack("")
			end
			abort_sort(self, self.object:get_pos()); return
		end
		self._carry = ItemStack("")
		hide_held(self)
		job.idx = job.idx + 1
		job.phase = "pickup"
		if not job.moves[job.idx] then finalize_sort(self, job) end
	end
end

-- Pick a nearby chest UNIT (single or double) that isn't in Creative order yet
-- (and isn't currently unreachable) and return a fresh reorder job for it, or nil
-- if all are tidy. Double-chest halves are coalesced so a pair is sorted once, as
-- one 54-slot grid.
local function plan_reorder_nearby(self, chests)
	local skip = unreachable_set(self)
	local seen = {}   -- hashed node positions already accounted for
	for _, c in ipairs(chests) do
		local h = core.hash_node_position(c.pos)
		if not seen[h] and not (skip and skip[h]) then
			local unit = chest_unit(c.pos)
			if not unit then
				seen[h] = true
			elseif unit.secondary then
				-- This is the right half; its left partner (which drives the pair)
				-- will be handled on its own iteration. Don't act here.
				seen[h] = true
			else
				for _, p in ipairs(unit.parts) do seen[core.hash_node_position(p.pos)] = true end
				local r = plan_reorder(unit.parts)
				if r then
					r.parts = unit.parts
					r.pos, r.idx, r.phase = unit.primary, 1, "pickup"
					return r
				end
			end
		end
	end
end

-- Per-step AI update.
local function update_movement(self, dtime)
	-- Watchdog: a chest lid is only meant to be held open for the brief dwell. If
	-- it has stayed open much longer, something went wrong -- force it shut. This
	-- is what guarantees a golem can never leave a chest stuck open.
	if self._lid_pos then
		local m = self._mode
		if m == "to_source" or m == "to_dest" or m == "to_sortchest" then
			self._lid_age = 0   -- actively interacting (sorts can take a while); the mode owns the lid
		else
			-- Lid open but the golem is idle/walking/leashed -> it's orphaned. Force it shut.
			self._lid_age = (self._lid_age or 0) + dtime
			if self._lid_age > config.chest_dwell + 2 then close_chest_lid(self) end
		end
	end

	local speed_factor = STAGE_SPEED[self._stage] or 1.0

	-- Leashed (leads mod): drop everything and follow whoever holds the rope, and
	-- never clobber the pull. Trot toward the holder when the rope would otherwise
	-- go taut, else stand. A frozen (oxidized) golem can't trot but isn't halted
	-- here, so it can still be dragged along by the rope.
	local anchor = leash_anchor(self)
	if anchor then
		close_chest_lid(self)
		self._job = nil
		self._pickup = nil                    -- drop any in-progress ground pickup
		self._sort = nil                      -- drop any in-progress chest reorder
		local pos = self.object:get_pos()
		if pos and self._carry and not self._carry:is_empty() then
			stash_or_drop(self, pos)          -- don't carry chores around on the leash
		end
		local far = pos and vector.distance(pos, anchor) > LEASH_FOLLOW_DIST
		if far and speed_factor > 0 then
			travel_toward(self, anchor, speed_factor, dtime) -- obstacle-aware trot
			set_anim(self, "walk")
		else
			-- Within reach, or frozen. Only damp our own motion when we are NOT
			-- being pulled, so a frozen (oxidized) golem can still be dragged.
			if not far then halt(self) end
			set_anim(self, "stand")
		end
		return
	end

	-- A fully oxidized golem is immobilized -- it seizes up frozen in one of four
	-- random statue poses (head tilt + arm gesture), chosen once and held. The pose
	-- is cleared when something de-oxidizes it (axe/lightning), so it re-rolls a
	-- fresh pose if it ever freezes again.
	if speed_factor <= 0 then
		close_chest_lid(self) -- don't freeze mid-interaction leaving a lid open
		if self._sort then    -- seizing up mid-reorder: return the carry, drop the job
			if self._carry and not self._carry:is_empty() then
				stash_or_drop(self, self.object:get_pos())
			end
			hide_held(self)
			self._sort = nil
		end
		halt(self)
		if not self._pose then self._pose = math.random(NUM_POSES) end
		set_anim(self, "pose" .. self._pose)
		return
	end

	-- Temporary post-lightning hyper-charge.
	if (self._boost_timer or 0) > 0 then
		self._boost_timer = self._boost_timer - dtime
		speed_factor = speed_factor * LIGHTNING_BOOST
	end

	self._mode_timer    = (self._mode_timer or 0) - dtime
	self._organize_cool = (self._organize_cool or 0) - dtime

	local mode = self._mode or "idle"

	if mode == "idle" or mode == "walk" then
		-- Time for a sort trip? Scan the chests ONCE, remember where they are (the
		-- wander anchor), then decide: carry a misplaced stack, tidy in place, or
		-- -- if there's simply nothing to do -- count another calm idle cycle.
		if self._organize_cool <= 0 then
			local pos    = self.object:get_pos()
			local chests = pos and nearby_chests(pos, config.chest_radius) or {}
			self._home   = chest_centroid(chests) or self._home or pos
			-- Loose items on the floor take priority over reshuffling chests.
			local pickup = config.pickup_enabled and pos
				and plan_pickup_job(chests, pos, unreachable_set(self))
			if pickup then
				self._idle_streak = 0       -- there's work: snap back to attentive
				self._pickup = pickup
				self._mode = "to_item"
				self._mode_timer = config.seek_timeout
				set_anim(self, "walk")
				return
			end
			local job    = plan_sort_job(chests, unreachable_set(self))
			if job then
				self._idle_streak = 0       -- there's work: snap back to attentive
				self._job = job
				self._mode = "to_source"
				self._mode_timer = config.seek_timeout
				set_anim(self, "walk")
				return
			end
			-- Nothing to courier between chests: is a chest out of Creative order?
			-- If so, go physically rearrange it (the animated within-chest sort).
			local rsort = plan_reorder_nearby(self, chests)
			if rsort then
				self._idle_streak = 0       -- there's work: stay attentive
				self._sort = rsort
				self._mode = "to_sortchest"
				self._mode_timer = config.seek_timeout
				set_anim(self, "walk")
				return
			end
			-- Nothing to reorder either: tidy partial stacks WITHIN each chest as a
			-- cheap fallback (also a no-op once everything is sorted).
			local tidied = compact_nearby(chests)
			for _, p in ipairs(tidied) do work_particles(p) end
			if #tidied > 0 then
				self._idle_streak = 0       -- did real work: stay attentive
				self._organize_cool = config.organize_cooldown
			else
				-- Truly idle. Let the streak grow so the WANDER calms down, but keep
				-- scanning for work at a steady, snappy cadence -- the find_nodes_in_area
				-- scan is cheap, so the golem stays quick to notice newly-misplaced
				-- items even after it has settled (calm strolling, alert sorting).
				self._idle_streak = (self._idle_streak or 0) + 1
				self._organize_cool = config.seek_recheck
			end
		end
		if self._mode_timer <= 0 then
			if mode == "walk" then
				start_idle(self)
			-- A settled golem often just keeps resting instead of strolling again,
			-- so it stops pacing the room once its chests are organised.
			elseif math.random() < 0.7 * calm_factor(self) then
				start_idle(self)
			else
				start_walk(self)
			end
		elseif mode == "walk" then
			-- "Lidar" for the stroll: turn away from surface water it would walk into
			-- (an already-submerged golem skips this and walks the bottom) and from
			-- walls too tall to step over, instead of grinding into them.
			if (water_ahead(self) and not in_water(self)) or wall_ahead(self) then
				self.object:set_yaw(self.object:get_yaw()
					+ math.pi * (0.5 + math.random()))
				halt(self)
			else
				push_forward(self, config.walk_speed * speed_factor)
			end
		else
			-- Standing idle: rub off any residual velocity (e.g. punch knockback) so
			-- the golem doesn't slide across the floor like it's on ice.
			ground_friction(self, dtime)
		end

	elseif mode == "to_item" then
		-- Walking to a loose item on the floor. Once close enough, pick it up and
		-- hand off to "to_dest" (unchanged) to carry it into the chosen chest --
		-- exactly like a chest-sourced stack, just picked up off the ground first.
		local pos = self.object:get_pos()
		local pk  = self._pickup
		local obj = pk and pk.obj
		local target = obj and obj:get_pos()
		if not pos or not pk or not obj or not target or self._mode_timer <= 0 then
			self._pickup = nil
			self._organize_cool = 4
			start_idle(self)
			return
		end
		local dx, dz = target.x - pos.x, target.z - pos.z
		if dx * dx + dz * dz <= 1.2 * 1.2 then
			-- Arrived: scoop it up (re-read the entity in case it changed/merged
			-- with another drop while we were walking over).
			local ent = obj:get_luaentity()
			local stack = (ent and ent.itemstring and ent.itemstring ~= "")
				and ItemStack(ent.itemstring) or ItemStack("")
			obj:remove()
			self._pickup = nil
			if stack:is_empty() then
				self._organize_cool = 4
				start_idle(self)
			else
				self._carry = stack
				show_held(self, stack:get_name())
				self._job = { dest = pk.dest } -- to_dest only ever reads job.dest
				self._mode = "to_dest"
				self._mode_timer = config.seek_timeout
				face_pos(self, pk.dest)
				set_anim(self, "walk")
			end
		elseif water_ahead(self) and not in_water(self) then
			self._pickup = nil
			self._organize_cool = 4
			start_idle(self)
		elseif follow_path(self, target, speed_factor, dtime) == "blocked" then
			self._pickup = nil
			self._organize_cool = 4
			start_idle(self)
		end

	elseif mode == "to_source" then
		local pos = self.object:get_pos()
		local job = self._job
		-- Dwelling at the open chest: stand for a beat so the lid animation plays.
		if self._lid_pos then
			halt(self)
			self._chest_timer = (self._chest_timer or 0) - dtime
			if self._chest_timer <= 0 then
				close_chest_lid(self)
				if not self._carry or self._carry:is_empty() then
					self._job = nil
					self._organize_cool = 4
					start_idle(self)
				else
					self._mode = "to_dest"
					self._mode_timer = config.seek_timeout
					if job then face_pos(self, job.dest) end
					set_anim(self, "walk")
				end
			end
			return
		end
		-- Travelling to the chest holding the misplaced stack.
		if not pos or not job or not is_chest_node(core.get_node(job.src).name)
				or self._mode_timer <= 0 then
			self._job = nil
			self._organize_cool = 4
			start_idle(self)
			return
		end
		local dx, dz = job.src.x - pos.x, job.src.z - pos.z
		if dx * dx + dz * dz <= 1.6 * 1.6 then
			-- Arrived: open the lid, grab <=16, show it in hand, then dwell.
			open_chest_lid(self, job.src)
			self._carry = take_from_chest(job.src, job.name)
			if not self._carry:is_empty() then show_held(self, self._carry:get_name()) end
			self._chest_timer = config.chest_dwell
			halt(self)
			face_pos(self, job.src)
			set_anim(self, "stand")
		elseif water_ahead(self) and not in_water(self) then
			self._job = nil
			self._organize_cool = 4
			start_idle(self)
		elseif follow_path(self, job.src, speed_factor, dtime) == "blocked" then
			-- No route to that chest (walled off): give up and don't keep picking it.
			mark_unreachable(self, job.src)
			self._job = nil
			self._organize_cool = 4
			start_idle(self)
		end

	elseif mode == "to_dest" then
		local pos = self.object:get_pos()
		local job = self._job
		-- Dwelling at the open home chest after depositing.
		if self._lid_pos then
			halt(self)
			self._chest_timer = (self._chest_timer or 0) - dtime
			if self._chest_timer <= 0 then
				close_chest_lid(self)
				self._job = nil
				self._organize_cool = config.organize_cooldown
				start_idle(self)
			end
			return
		end
		-- Carry the stack to its home chest. Anything that won't fit or can't be
		-- reached is dropped so a carried item is never lost.
		if not pos or not self._carry or self._carry:is_empty() then
			hide_held(self)
			self._job = nil
			start_idle(self)
			return
		end
		if not job or not is_chest_node(core.get_node(job.dest).name)
				or self._mode_timer <= 0 then
			stash_or_drop(self, pos)        -- couldn't reach home: tuck it away, don't litter
			self._job = nil
			self._organize_cool = 4
			start_idle(self)
			return
		end
		local dx, dz = job.dest.x - pos.x, job.dest.z - pos.z
		if dx * dx + dz * dz <= 1.6 * 1.6 then
			-- Arrived: open the lid, deposit (spill overflow), drop the held item,
			-- and tidy the home chest's stacks while we're here.
			open_chest_lid(self, job.dest)
			drop_item(pos, put_in_chest(job.dest, self._carry))
			local dinv = core.get_inventory({ type = "node", pos = job.dest })
			if dinv then compact_chest(dinv) end
			self._carry = ItemStack("")
			hide_held(self)
			work_particles(job.dest)
			self._chest_timer = config.chest_dwell
			halt(self)
			face_pos(self, job.dest)
			set_anim(self, "stand")
		elseif water_ahead(self) and not in_water(self) then
			stash_or_drop(self, pos)        -- water in the way: tuck it away, don't litter
			self._job = nil
			self._organize_cool = 4
			start_idle(self)
		elseif follow_path(self, job.dest, speed_factor, dtime) == "blocked" then
			-- Can't reach the home chest: stash the carry nearby and drop the job.
			mark_unreachable(self, job.dest)
			stash_or_drop(self, pos)
			self._job = nil
			self._organize_cool = 4
			start_idle(self)
		end

	elseif mode == "to_sortchest" then
		-- Walk to a chest that's out of Creative order, then animate the reorder:
		-- one pick-up / put-down per beat until the move queue drains.
		local pos = self.object:get_pos()
		local job = self._sort
		if not pos or not job or not is_chest_node(core.get_node(job.pos).name)
				or self._mode_timer <= 0 then
			abort_sort(self, pos)
			return
		end
		if self._lid_pos then
			-- At the open chest: tick through the move queue.
			halt(self)
			self._chest_timer = (self._chest_timer or 0) - dtime
			if self._chest_timer <= 0 then
				self._chest_timer = config.sort_move_time
				sort_step(self, job)         -- advances one phase; finalises/aborts internally
			end
			return
		end
		local dx, dz = job.pos.x - pos.x, job.pos.z - pos.z
		if dx * dx + dz * dz <= 1.6 * 1.6 then
			-- Arrived: open the lid and start the first beat.
			open_chest_lid(self, job.pos)
			self._chest_timer = config.sort_move_time
			halt(self)
			face_pos(self, job.pos)
			set_anim(self, "stand")
		elseif water_ahead(self) and not in_water(self) then
			abort_sort(self, pos)
		elseif follow_path(self, job.pos, speed_factor, dtime) == "blocked" then
			mark_unreachable(self, job.pos)
			abort_sort(self, pos)
		end
	end
end

--------------------------------------------------------------------------------
-- ENTITY  --  the thin glue between (A) and (B). Holds no heavy logic itself.
--------------------------------------------------------------------------------

local GRAVITY = { x = 0, y = -9.81, z = 0 }

local golem_def = {
	initial_properties = (function()
		local p = base_visual_properties()
		p.textures = mesh_textures(1) -- start un-oxidised; updated on activate
		return p
	end)(),

	-- Persistent fields (saved via get_staticdata):
	_stage      = 1,   -- current oxidation stage 1..4
	_age        = 0,   -- accumulated real seconds, drives oxidation
	_waxed      = false,-- true halts oxidation (honeycomb)
	_creator    = nil, -- player name who built it (cosmetic)
	_carry      = nil, -- ItemStack carried between chests (persisted, see staticdata)
	_pose       = nil, -- 1..NUM_POSES: the frozen statue pose, once oxidized (persisted)
	-- Transient (movement state machine, see B3):
	_mode          = "idle",
	_mode_timer    = 0,
	_job           = nil, -- { src=<pos>, name=<item>, dest=<pos> } the current sort job
	_pickup        = nil, -- { obj=<object>, dest=<pos> } the current ground-item job
	_organize_cool = 0,
	_anim          = nil,
	_boost_timer   = 0,   -- seconds of post-lightning hyper-charge remaining
	_held_obj      = nil, -- attached entity showing the carried item in hand
	_lid_pos       = nil, -- chest pos whose lid this golem currently holds open
	_lid_obj       = nil, -- the exact lid luaentity we opened (so we close that one)
	_chest_timer   = 0,   -- seconds left dwelling at an open chest
	_sort          = nil, -- in-progress within-chest reorder { pos, target, moves, idx, phase }
	_home          = nil, -- centroid of nearby chests; soft anchor for the wander
	_idle_streak   = 0,   -- consecutive no-work cycles; drives "calm down" behaviour
	_leash            = nil, -- the leads-mod lead luaentity we're tied to, if any
	_leash_is_leader  = nil, -- which end of that lead we are (follow the other end)

	-- "leads" mod integration (optional; harmless when the mod isn't present). The
	-- mod reads these off the luaentity: mark the golem leashable and lift the lead
	-- attach point to about chest height instead of the hitbox centre.
	_leads_leashable     = true,
	_leads_attach_offset = 0.7,

	on_activate = function(self, staticdata, dtime_s)
		-- Restore saved state. staticdata is a serialised table; on first spawn
		-- it carries the starting stage chosen from the copper block used.
		local data = staticdata ~= "" and core.deserialize(staticdata) or nil
		if type(data) == "table" then
			self._stage   = data.stage   or 1
			self._age     = data.age     or 0
			self._waxed   = data.waxed   or false
			self._creator = data.creator
			self._carry   = ItemStack(data.carry or "")
			self._pose    = data.pose    -- keep the frozen statue's pose across reloads
		end

		-- Falls under gravity and rests on the ground (engine handles node
		-- collision), but takes NO fall damage -- like an iron/snow golem: the
		-- engine never fall-damages a luaentity, and HP is only ever subtracted in
		-- on_punch. Re-assert the damage groups here so even a golem spawned before
		-- HP existed becomes killable on reload.
		self.object:set_acceleration(GRAVITY)
		self.object:set_armor_groups({ fleshy = 100 })
		apply_stage_visuals(self.object, self._stage)

		-- If it was mid-carry when unloaded, return the item to the world so
		-- nothing is lost; it'll plan a fresh sort job from idle. The held-item
		-- and lid states are transient cosmetics, reset clean on every load.
		local here = self.object:get_pos()
		if here and self._carry and not self._carry:is_empty() then
			drop_item(here, self._carry)
		end
		self._carry    = ItemStack("")
		self._held_obj = nil
		self._lid_pos  = nil
		self._lid_obj  = nil
		self._chest_timer = 0
		self._sort        = nil  -- any in-progress reorder is abandoned on reload (carry dropped above)
		self._home        = nil  -- relearned from the first chest scan after load
		self._idle_streak = 0    -- start attentive; calms down only if work runs out
		self._leash           = nil -- re-set by leads' callback when the lead reloads
		self._leash_is_leader = nil
		self._path        = nil  -- seek route + unreachable-chest memory, both transient
		self._path_goal   = nil
		self._path_idx    = nil
		self._path_cool   = nil
		self._unreachable = nil

		-- Start out standing; the AI state machine takes over from here.
		-- First sort trip comes a few seconds after activation.
		self.object:set_animation(ANIM.stand, ANIM_SPEED, 0, true)
		self._anim          = "stand"
		self._mode          = "idle"
		self._job           = nil
		self._pickup        = nil
		self._mode_timer    = 0
		self._organize_cool = 3
	end,

	-- On removal/unload, let go of any chest lid and clean up the held item, so
	-- nothing is left animated open and no orphan item entity lingers.
	on_deactivate = function(self)
		close_chest_lid(self)
		hide_held(self)
	end,

	-- "leads" mod callbacks: it tells us when a lead is tied to or removed from the
	-- golem. We remember the lead (and which end we are) so update_movement can make
	-- the golem follow whoever holds it. Harmless if the mod is absent (never called).
	_leads_lead_add = function(self, lead, is_leader)
		self._leash = lead
		self._leash_is_leader = is_leader or false
	end,
	_leads_lead_remove = function(self, lead, _is_leader)
		if self._leash == lead then
			self._leash = nil
			self._leash_is_leader = nil
		end
	end,

	get_staticdata = function(self)
		return core.serialize({
			stage   = self._stage,
			age     = self._age,
			waxed   = self._waxed,
			creator = self._creator,
			carry   = (self._carry and self._carry:to_string()) or "",
			pose    = self._pose,
		})
	end,

	on_step = function(self, dtime)
		-- (B3) Movement AI; chest sorting (B2) runs from its to_source/to_dest states.
		update_movement(self, dtime)

		-- (B1) Oxidation -------------------------------------------------------
		if not self._waxed and self._stage < NUM_STAGES then
			-- Water contact accelerates oxidation (waxed golems skip this block).
			local rate = in_water(self) and WATER_OXIDATION_MULT or 1.0
			self._age = self._age + dtime * rate
			local want = stage_for_age(self._age)
			if want > self._stage then
				self._stage = want
				apply_stage_visuals(self.object, self._stage)
			end
		end
	end,

	-- Right-click interactions (neither deals damage):
	--   * Axe       -> scrape one oxidation tier (wax first), the "strip
	--                  with an axe" gesture; a sparkle of stars marks it.
	--   * Honeycomb -> wax the golem to permanently halt oxidation.
	on_rightclick = function(self, clicker)
		if not clicker or not clicker:is_player() then return end
		local wield = clicker:get_wielded_item()
		local pos   = self.object:get_pos()

		-- Axe: de-oxidize one step per right-click.
		if core.get_item_group(wield:get_name(), "axe") > 0 then
			local scraped = false
			if self._waxed then
				self._waxed = false               -- strip the wax first
				scraped = true
			elseif self._stage > 1 then
				self._stage = self._stage - 1
				self._pose = nil  -- no longer fully oxidized: let it move + re-roll its pose
				-- Re-base the oxidation clock to this tier's start, or on_step's
				-- stage_for_age() would just re-oxidize it on the next tick.
				self._age = (self._stage - 1) * config.seconds_per_stage
				apply_stage_visuals(self.object, self._stage)
				scraped = true
			end
			if scraped then
				if pos then star_particles(pos) end
				-- Spend one use of axe durability (skipped in creative).
				local name = clicker:get_player_name()
				if not (core.is_creative_enabled and core.is_creative_enabled(name)) then
					if mcl_util and mcl_util.use_item_durability then
						mcl_util.use_item_durability(wield, 1)
					else
						wield:add_wear_by_uses(200)
					end
					clicker:set_wielded_item(wield)
				end
			end
			return
		end

		-- Honeycomb: wax to permanently stop oxidation (harmless if mcl_honey absent).
		if wield:get_name() == "mcl_honey:honeycomb" and not self._waxed then
			self._waxed = true
			local creative = core.is_creative_enabled
				and core.is_creative_enabled(clicker:get_player_name())
			if not creative then
				wield:take_item(1)
				clicker:set_wielded_item(wield)
			end
			if pos then
				core.add_particlespawner({
					amount = 16, time = 0.4,
					minpos = vector.offset(pos, -0.3, -0.3, -0.3),
					maxpos = vector.offset(pos,  0.3,  0.3,  0.3),
					minvel = { x = -0.3, y = 0.2, z = -0.3 },
					maxvel = { x =  0.3, y = 0.6, z =  0.3 },
					minexptime = 0.5, maxexptime = 1.0,
					minsize = 1, maxsize = 2,
					texture = "mcl_honey_honeycomb.png",
				})
			end
		end
	end,

	-- Punch handling: the golem is killable like an iron golem. Every hit deals its
	-- weapon's damage and dies at 0 HP (see golem_die). De-oxidation is NOT done
	-- here -- right-click with an axe for that (on_rightclick). No hurt particles
	-- (the copper sparkle is reserved for the golem's chest work). Fall damage stays
	-- excluded: the engine never fall-damages a luaentity and HP only drops here.
	on_punch = function(self, puncher, _tflp, _caps, _dir, damage)
		local pos = self.object:get_pos()
		if pos and puncher and puncher:get_pos() then -- a little knockback
			self.object:add_velocity(
				vector.multiply(vector.direction(puncher:get_pos(), pos), 3))
		end
		local hp = self.object:get_hp() - (damage or 0)
		if hp <= 0 then
			golem_die(self)
		else
			self.object:set_hp(hp)
		end
		return true
	end,

	-- Lightning purges ALL oxidation back to pristine and briefly hyper-charges
	-- the golem ("atmospheric restoration"). Returning true skips the
	-- default lightning damage. Mineclonia uses the underscore-prefixed name;
	-- Voxelibre calls the non-prefixed name -- both are wired to the same handler.
	_on_lightning_strike = function(self, _pos, _pos2, _objects)
		self._stage = 1
		self._age   = 0
		self._pose  = nil  -- thawed: drop the frozen statue pose
		apply_stage_visuals(self.object, 1)
		self._boost_timer = LIGHTNING_BOOST_TIME
		local p = self.object:get_pos()
		if p then scrape_particles(p) end
		return true
	end,
}
-- Voxelibre's lightning mod calls on_lightning_strike (no leading underscore).
golem_def.on_lightning_strike = golem_def._on_lightning_strike

core.register_entity("copper_golem:golem", golem_def)

--------------------------------------------------------------------------------
-- SPAWN TRIGGER  --  carved pumpkin on a copper block builds the golem
--------------------------------------------------------------------------------
--
-- The golem starts oxidised to MATCH the copper block it was built from
-- (build one from weathered copper -> it spawns weathered). Irreversible, so it
-- continues from there. This map turns a node name into a starting stage.
local COPPER_BLOCK_STAGE = {
	["mcl_copper:block"]           = 1,
	["mcl_copper:block_exposed"]   = 2,
	["mcl_copper:block_weathered"] = 3,
	["mcl_copper:block_oxidized"]  = 4,
}

-- Particles when a golem is built, mirroring the snow/iron golem feel.
local function spawn_particles(pos)
	core.add_particlespawner({
		amount = 24, time = 0.5,
		minpos = vector.offset(pos, -0.4, -0.4, -0.4),
		maxpos = vector.offset(pos,  0.4,  0.4,  0.4),
		minvel = { x = -0.5, y = 0.3, z = -0.5 },
		maxvel = { x =  0.5, y = 1.0, z =  0.5 },
		minacc = { x = 0, y = -1, z = 0 }, maxacc = { x = 0, y = -2, z = 0 },
		minexptime = 0.6, maxexptime = 1.2,
		minsize = 1, maxsize = 3,
		texture = "copper_golem.png",
	})
end

-- Called after a carved pumpkin is placed at `pos`. If a copper block sits
-- directly below, consume both nodes and summon a golem in their place.
function copper_golem.check_summon(pos, placer)
	-- The pumpkin may already have been consumed by the iron/snow golem check
	-- that runs before us, so confirm it's still there.
	if core.get_node(pos).name ~= "mcl_farming:pumpkin_face" then return end

	local below      = { x = pos.x, y = pos.y - 1, z = pos.z }
	local below_name = core.get_node(below).name
	local start_stage = COPPER_BLOCK_STAGE[below_name]
	if not start_stage then return end -- not a (non-waxed) copper block

	-- Remove the two build nodes and settle anything resting on them.
	core.remove_node(pos)
	core.remove_node(below)
	core.check_for_falling(pos)
	core.check_for_falling(below)

	-- Spawn slightly above the copper block's old position so it drops in.
	local spawn_pos = { x = below.x, y = below.y + 0.5, z = below.z }
	local staticdata = core.serialize({
		stage   = start_stage,
		age     = (start_stage - 1) * config.seconds_per_stage, -- consistent age
		waxed   = false,
		creator = placer and placer:is_player() and placer:get_player_name() or nil,
	})
	local obj = core.add_entity(spawn_pos, "copper_golem:golem", staticdata)
	if obj then
		spawn_particles(spawn_pos)
	end
end

-- Wire ourselves into the carved pumpkin WITHOUT editing the base game: save the
-- pumpkin's existing after_place_node (which handles iron/snow golems) and chain
-- our check after it via core.override_item. mcl_farming is a hard dependency, so
-- the node is guaranteed to exist by the time this runs.
do
	local pumpkin = core.registered_nodes["mcl_farming:pumpkin_face"]
	if pumpkin then
		local original = pumpkin.after_place_node
		core.override_item("mcl_farming:pumpkin_face", {
			after_place_node = function(pos, placer, itemstack, pointed_thing)
				if original then
					original(pos, placer, itemstack, pointed_thing)
				end
				copper_golem.check_summon(pos, placer)
			end,
		})
	else
		core.log("warning",
			"[copper_golem] mcl_farming:pumpkin_face not found; " ..
			"build-to-spawn disabled. Is mcl_farming installed?")
	end
end

core.log("action", "[copper_golem] loaded")

-- Test hook: only exposed when an offline harness sets COPPER_GOLEM_TEST. Never
-- present in-game (the global is never defined), so this is inert in production.
-- Lets tests/ exercise the chest-sort plumbing without the entity/AI machinery.
if rawget(_G, "COPPER_GOLEM_TEST") then
	copper_golem._test = {
		plan_reorder       = plan_reorder,
		plan_reorder_nearby = plan_reorder_nearby,
		chest_unit         = chest_unit,
		unit_combined_list = unit_combined_list,
		unit_set_list      = unit_set_list,
		part_locate        = part_locate,
		item_less          = item_less,
	}
end
