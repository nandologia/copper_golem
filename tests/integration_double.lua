-- Integration test for the double-chest "unit" sorting, run under lupa (real Lua)
-- with a stubbed Minetest inventory API. Loads the ACTUAL init.lua via its
-- COPPER_GOLEM_TEST hook and exercises chest_unit / plan_reorder / unit_set_list,
-- plus a faithful replay of the per-move executor (part_locate + pickup/putdown)
-- so the cross-half moves are covered too.

package.path = package.path .. ";./?.lua"

--------------------------------------------------------------------------------
-- Minimal Minetest API stubs
--------------------------------------------------------------------------------

local STACKMAX = {}  -- item id -> stack max

local ItemStackMT = {}
ItemStackMT.__index = ItemStackMT
function ItemStackMT:is_empty() return self.count == 0 or self.name == "" end
function ItemStackMT:get_name() return self.name end
function ItemStackMT:get_count() return self.count end
function ItemStackMT:set_count(n) self.count = n end
function ItemStackMT:get_wear() return 0 end
function ItemStackMT:get_stack_max() return STACKMAX[self.name] or 64 end
function ItemStackMT:get_meta() return { to_table = function() return {} end } end
function ItemStackMT:to_string()
	if self.name == "" or self.count == 0 then return "" end
	if self.count == 1 then return self.name end
	return self.name .. " " .. self.count
end

function ItemStack(s)
	if type(s) == "table" then return setmetatable({ name = s.name, count = s.count }, ItemStackMT) end
	s = s or ""
	if s == "" then return setmetatable({ name = "", count = 0 }, ItemStackMT) end
	local name, count = s:match("^(%S+)%s+(%d+)$")
	if not name then name, count = s, 1 end
	return setmetatable({ name = name, count = tonumber(count) }, ItemStackMT)
end

-- Fake node inventories, keyed by hashed position.
local INVS = {}
local NODES = {}
local function hashp(p) return p.x .. "," .. p.y .. "," .. p.z end

local InvMT = {}
InvMT.__index = InvMT
function InvMT:get_size(_) return self.size end
function InvMT:get_list(_) return self.list end
function InvMT:set_list(_, l)
	for i = 1, self.size do self.list[i] = l[i] or ItemStack("") end
end
function InvMT:get_stack(_, i) return self.list[i] or ItemStack("") end
function InvMT:set_stack(_, i, st) self.list[i] = ItemStack(st:to_string()) end

local function make_inv(size)
	local l = {}
	for i = 1, size do l[i] = ItemStack("") end
	return setmetatable({ size = size, list = l }, InvMT)
end

vector = {
	new = function(x, y, z) return { x = x, y = y, z = z } end,
	offset = function(p, x, y, z) return { x = p.x + x, y = p.y + y, z = p.z + z } end,
	distance = function(a, b) return 0 end,
}

mcl_util = {
	get_double_container_neighbor_pos = function(pos, param2, side)
		-- mirror of the real helper for param2 == 0
		if side == "right" then return vector.offset(pos, -1, 0, 0)
		else return vector.offset(pos, 1, 0, 0) end
	end,
}

local realcore = {}
realcore.get_modpath = function() return "." end
realcore.get_inventory = function(loc) return INVS[hashp(loc.pos)] end
realcore.get_node = function(p) return NODES[hashp(p)] or { name = "air", param2 = 0 } end
realcore.hash_node_position = function(p) return hashp(p) end
realcore.registered_items = {}
realcore.registered_nodes = {}
realcore.get_item_group = function(name, g)
	local def = realcore.registered_items[name]
	return (def and def.groups and def.groups[g]) or 0
end
realcore.register_on_mods_loaded = function() end
realcore.log = function() end
realcore.serialize = function() return "" end
realcore.deserialize = function() return nil end
core = setmetatable(realcore, { __index = function() return function() end end })

--------------------------------------------------------------------------------
-- Item registry for the test
--------------------------------------------------------------------------------

local function reg(name, max, groups)
	core.registered_items[name] = { description = name, groups = groups or {} }
	STACKMAX[name] = max
end
reg("mcl_core:dirt", 64, { building_block = 1 })
reg("mcl_core:dirt_with_grass", 64, { building_block = 1 })
reg("mcl_core:cobble", 64, { building_block = 1 })
reg("mcl_farming:wheat_seeds", 64, { craftitem = 1 })

--------------------------------------------------------------------------------
-- Load the real mod
--------------------------------------------------------------------------------

COPPER_GOLEM_TEST = true
assert(loadfile("init.lua"))()
local T = copper_golem._test
assert(T and T.plan_reorder, "test hook missing")

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function totals(invs)
	local t = {}
	for _, inv in ipairs(invs) do
		for _, s in ipairs(inv.list) do
			if not s:is_empty() then t[s:get_name()] = (t[s:get_name()] or 0) + s:get_count() end
		end
	end
	return t
end

local function teq(a, b)
	for k, v in pairs(a) do if b[k] ~= v then return false end end
	for k, v in pairs(b) do if a[k] ~= v then return false end end
	return true
end

local function combined_names(parts)
	local list = T.unit_combined_list(parts)
	local out = {}
	for i = 1, #list do out[i] = list[i]:is_empty() and "_" or (list[i]:get_name() .. ":" .. list[i]:get_count()) end
	return out, list
end

-- Faithful replay of the per-move executor against the fake invs.
local function replay(parts, moves)
	local carry
	for _, mv in ipairs(moves) do
		-- pickup
		local fpos, fslot = T.part_locate(parts, mv.from)
		local finv = INVS[hashp(fpos)]
		local s = finv:get_stack("main", fslot)
		assert(not s:is_empty() and s:get_count() >= mv.count, "illegal pickup")
		carry = ItemStack(s:get_name() .. " " .. mv.count)
		s:set_count(s:get_count() - mv.count)
		finv:set_stack("main", fslot, s:get_count() > 0 and s or ItemStack(""))
		-- putdown
		local tpos, tslot = T.part_locate(parts, mv.to)
		local tinv = INVS[hashp(tpos)]
		local dst = tinv:get_stack("main", tslot)
		if dst:is_empty() then
			tinv:set_stack("main", tslot, carry)
		else
			assert(dst:get_name() == carry:get_name()
				and dst:get_count() + carry:get_count() <= dst:get_stack_max(), "illegal putdown")
			dst:set_count(dst:get_count() + carry:get_count())
			tinv:set_stack("main", tslot, dst)
		end
		carry = nil
	end
end

--------------------------------------------------------------------------------
-- Scenario: dirt in the LEFT half, grass in the RIGHT half (the user's bug).
--------------------------------------------------------------------------------

local posL = { x = 10, y = 5, z = 0 }
local posR = { x = 11, y = 5, z = 0 }  -- neighbor for param2==0
NODES[hashp(posL)] = { name = "mcl_chests:chest_left", param2 = 0 }
NODES[hashp(posR)] = { name = "mcl_chests:chest_right", param2 = 0 }
local invL, invR = make_inv(27), make_inv(27)
INVS[hashp(posL)] = invL
INVS[hashp(posR)] = invR

-- left half: dirt in slot 5, cobble in slot 1
invL.list[1] = ItemStack("mcl_core:cobble 64")
invL.list[5] = ItemStack("mcl_core:dirt 40")
-- right half: grass in slot 3, more dirt in slot 20, seeds in slot 8
invR.list[3] = ItemStack("mcl_core:dirt_with_grass 30")
invR.list[20] = ItemStack("mcl_core:dirt 24")
invR.list[8] = ItemStack("mcl_farming:wheat_seeds 10")

local before = totals({ invL, invR })

-- chest_unit from either half resolves to the same pair, left-first.
local uL = T.chest_unit(posL)
local uR = T.chest_unit(posR)
assert(#uL.parts == 2 and uL.parts[1].pos.x == posL.x and uL.parts[2].pos.x == posR.x, "unit order wrong")
assert(uL.secondary == false, "left should be primary")
assert(uR.secondary == true, "right should be flagged secondary")
assert(uR.parts[1].pos.x == posL.x, "right's unit should still list left first")

local r = T.plan_reorder(uL.parts)
assert(r, "expected a reorder job")

-- (A) Replay the animated moves, then snap to target (the runtime's finalize).
replay(uL.parts, r.moves)
local after_replay = totals({ invL, invR })
assert(teq(before, after_replay), "REPLAY changed item totals!")
T.unit_set_list(uL.parts, r.target)

-- (B) Conservation across BOTH halves after the atomic snap.
local after = totals({ invL, invR })
assert(teq(before, after), "unit_set_list changed item totals!")

-- (C) The result is globally sorted across the 54-slot grid: each item is
-- contiguous and the dirt total (64) now occupies ONE full stack, grass follows,
-- spanning the half boundary instead of being organised per-half.
local names, list = combined_names(uL.parts)
-- find first non-empty run structure
local order = {}
for i = 1, #list do
	if not list[i]:is_empty() then order[#order + 1] = { i = i, n = list[i]:get_name(), c = list[i]:get_count() } end
end
-- contiguity: occupied slots must be a prefix 1..k with no gaps
for k = 1, #order do assert(order[k].i == k, "sorted layout has a gap at " .. k) end
-- same items adjacent: no item id appears in two non-adjacent runs
local seen_end = {}
local prev
for _, e in ipairs(order) do
	if e.n ~= prev then
		assert(not seen_end[e.n], "item " .. e.n .. " is split into non-adjacent runs")
		seen_end[prev or ""] = true
	end
	prev = e.n
end
-- dirt (40+24 = 64) collapsed into a single 64 stack, and it sits before grass
local dirt_slots = 0
for _, e in ipairs(order) do if e.n == "mcl_core:dirt" then dirt_slots = dirt_slots + 1 end end
assert(dirt_slots == 1, "dirt (64) should be one merged stack, got " .. dirt_slots .. " slots")

print("combined after sort:")
print("  L: " .. table.concat({ table.unpack(names, 1, 27) }, " "))
print("  R: " .. table.concat({ table.unpack(names, 28, 54) }, " "))
print("\nOK: double chest sorted as ONE 54-slot unit; totals conserved; items grouped across the half boundary.")
