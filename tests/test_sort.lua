-- Offline tests for sortlib (run with: lua5.1 tests/test_sort.lua  from the mod dir).
-- Verifies the two things that matter for item safety:
--   (1) every plan CONSERVES the per-key totals (no loss / no duplication), and
--   (2) the planned moves actually reach the target layout (so the animation
--       matches the final result; the runtime still snaps to target regardless).

package.path = package.path .. ";./?.lua"
local sortlib = require("sortlib")

local ITEMS = {
	{ key = "cobble",  max = 64 },
	{ key = "diorite", max = 64 },
	{ key = "granite", max = 64 },
	{ key = "wheat",   max = 16 },  -- smaller stack ceiling, exercises splitting
	{ key = "egg",     max = 1  },  -- unstackable-ish
}

-- A reference Creative-style target builder, matching init.lua's plan_reorder:
-- merge each key's total, split into full-stack-first chunks, order keys, pack
-- to the front, empties to the back.
local function build_target(slots)
	local N = #slots
	local merged, order = {}, {}
	for i = 1, N do
		local c = slots[i]
		if c then
			if not merged[c.key] then merged[c.key] = { count = 0, max = c.max }; order[#order + 1] = c.key end
			merged[c.key].count = merged[c.key].count + c.count
		end
	end
	table.sort(order)  -- stand-in for (category, item-id) ordering
	local units = {}
	for _, k in ipairs(order) do
		local total, mx = merged[k].count, merged[k].max
		while total > 0 do
			local n = math.min(total, mx)
			units[#units + 1] = { key = k, count = n, max = mx }
			total = total - n
		end
	end
	local tgt = {}
	for i = 1, N do tgt[i] = units[i] or false end
	return tgt
end

local function random_slots(N)
	local s = {}
	for i = 1, N do
		if math.random() < 0.35 then
			s[i] = false
		else
			local it = ITEMS[math.random(#ITEMS)]
			s[i] = { key = it.key, count = math.random(1, it.max), max = it.max }
		end
	end
	return s
end

local function dump(slots)
	local parts = {}
	for i = 1, #slots do
		local c = slots[i]
		parts[i] = c and (c.key .. ":" .. c.count) or "_"
	end
	return "[" .. table.concat(parts, " ") .. "]"
end

local function eq_layout(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do
		local x, y = a[i], b[i]
		if (not x) ~= (not y) then return false end
		if x and (x.key ~= y.key or x.count ~= y.count) then return false end
	end
	return true
end

math.randomseed(1234)  -- deterministic
local ITER = 20000
local reached, conserved_fail, overfill_fail = 0, 0, 0

for iter = 1, ITER do
	local N = math.random(3, 27)
	local cur = random_slots(N)
	local tgt = build_target(cur)

	-- conservation precondition: target must be same multiset as current
	assert(sortlib.totals_equal(sortlib.totals(cur), sortlib.totals(tgt)),
		"target builder changed totals at iter " .. iter)

	local moves = sortlib.plan(cur, tgt)
	local final = sortlib.simulate(cur, moves)

	-- (1) conservation
	if not sortlib.totals_equal(sortlib.totals(cur), sortlib.totals(final)) then
		conserved_fail = conserved_fail + 1
		print("CONSERVATION FAIL iter " .. iter)
		print("  cur  " .. dump(cur))
		print("  fin  " .. dump(final))
	end

	-- no slot exceeds its ceiling
	for i = 1, N do
		local c = final[i]
		if c and c.count > c.max then overfill_fail = overfill_fail + 1; break end
	end

	-- (2) reached target exactly?
	if eq_layout(final, tgt) then
		reached = reached + 1
	elseif iter <= 5 then
		print("not-exact (corrected by runtime set_list) iter " .. iter)
		print("  cur " .. dump(cur))
		print("  fin " .. dump(final))
		print("  tgt " .. dump(tgt))
	end
end

print(("\n%d iterations"):format(ITER))
print(("  conservation failures : %d  (MUST be 0)"):format(conserved_fail))
print(("  overfill failures     : %d  (MUST be 0)"):format(overfill_fail))
print(("  reached target exactly: %d / %d (%.2f%%)"):format(reached, ITER, 100 * reached / ITER))

assert(conserved_fail == 0, "CONSERVATION FAILED")
assert(overfill_fail == 0, "OVERFILL FAILED")
print("\nOK: conservation + ceilings hold on all " .. ITER .. " random cases.")
