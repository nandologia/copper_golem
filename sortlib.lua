--------------------------------------------------------------------------------
-- sortlib.lua  --  pure, engine-agnostic move planner for within-chest sorting
--------------------------------------------------------------------------------
--
-- This file deliberately knows NOTHING about Minetest/Mineclonia: no ItemStack,
-- no `core`. It works on plain Lua slot arrays so it can be unit-tested offline
-- (see tests/test_sort.lua). init.lua adapts a real chest inventory to/from
-- these arrays.
--
-- A slot array is `slots[1..N]`, each entry either:
--     false                         -- empty slot
--     { key=<string>, count=<int>, max=<int> }
--           key   : what occupies the slot (item id for mergeable items, or a
--                   unique synthetic token for unstackable/metadata stacks)
--           count : how many
--           max   : stack ceiling for this key (so we never overfill a slot)
--
-- Every move conserves the total count per key, by construction. The runtime
-- caller does NOT rely on the plan being perfect: after animating the moves it
-- snaps the chest to the exact target with one atomic write, but only when the
-- chest's item totals still match the target's (a pure rearrangement). So a
-- planner shortfall can at worst look slightly off mid-animation; it can never
-- lose or duplicate an item.
--------------------------------------------------------------------------------

local sortlib = {}

local function copyslots(a)
	local b = {}
	for i = 1, #a do
		local c = a[i]
		b[i] = c and { key = c.key, count = c.count, max = c.max } or false
	end
	return b
end
sortlib.copyslots = copyslots

-- Plan a list of { from, to, count } moves turning `current` into `target`.
-- Both arrays must hold the same multiset of (key -> total count) and be the
-- same length. Returns (moves, final_state).
function sortlib.plan(current, target)
	local N = #target
	local W = copyslots(current)
	for i = 1, N do if W[i] == nil then W[i] = false end end
	local moves = {}

	local function record(from, to, count)
		moves[#moves + 1] = { from = from, to = to, count = count }
		local fk, fmax = W[from].key, W[from].max
		W[from].count = W[from].count - count
		if W[from].count == 0 then W[from] = false end
		if not W[to] then
			W[to] = { key = fk, count = count, max = fmax }
		else
			W[to].count = W[to].count + count
		end
	end

	-- Move up to `amount` of key `k` (ceiling `mx`) OUT of slot i, rightward:
	-- into same-key slots that have room first, then into empty slots. Returns
	-- whatever couldn't be placed (normally 0).
	local function push_right(i, amount, k, mx)
		local j = i + 1
		while amount > 0 and j <= N do
			if W[j] and W[j].key == k then
				local r = mx - W[j].count
				if r > 0 then
					local m = math.min(amount, r)
					record(i, j, m); amount = amount - m
				end
			end
			j = j + 1
		end
		j = i + 1
		while amount > 0 and j <= N do
			if not W[j] then
				local m = math.min(amount, mx)
				record(i, j, m); amount = amount - m
			end
			j = j + 1
		end
		return amount
	end

	-- Pull `need` of key `k` INTO slot i from slots to its right. Slot i must be
	-- empty or already hold key `k`. Returns leftover need (normally 0).
	local function pull_left(i, k, need)
		local j = i + 1
		while need > 0 and j <= N do
			if W[j] and W[j].key == k then
				local m = math.min(need, W[j].count)
				record(j, i, m); need = need - m
			end
			j = j + 1
		end
		return need
	end

	for i = 1, N do
		local t = target[i]
		if t then
			if W[i] and W[i].key ~= t.key then
				push_right(i, W[i].count, W[i].key, W[i].max)   -- evict the wrong item
			end
			-- If a congested layout meant we couldn't fully vacate slot i, leave it:
			-- the caller's atomic set_list finalize fixes the remainder. This keeps
			-- every move we DO emit legal (destination empty or same key with room),
			-- so the executor never has to abort mid-sort.
			if not (W[i] and W[i].key ~= t.key) then
				local have = W[i] and W[i].count or 0
				if have > t.count then
					push_right(i, have - t.count, t.key, t.max)     -- shed surplus
				elseif have < t.count then
					pull_left(i, t.key, t.count - have)             -- gather the deficit
				end
			end
		elseif W[i] then
			push_right(i, W[i].count, W[i].key, W[i].max)       -- target empty: clear it
		end
	end
	return moves, W
end

-- Replay moves on a copy of `state`; returns the resulting array. Used by the
-- offline tests and (in spirit) mirrored by the runtime executor.
function sortlib.simulate(state, moves)
	local W = copyslots(state)
	for _, mv in ipairs(moves) do
		local f = W[mv.from]
		local key, max = f.key, f.max
		f.count = f.count - mv.count
		if f.count == 0 then W[mv.from] = false end
		if not W[mv.to] then
			W[mv.to] = { key = key, count = mv.count, max = max }
		else
			W[mv.to].count = W[mv.to].count + mv.count
		end
	end
	return W
end

-- total count per key, for conservation checks
function sortlib.totals(state)
	local t = {}
	for i = 1, #state do
		local c = state[i]
		if c then t[c.key] = (t[c.key] or 0) + c.count end
	end
	return t
end

function sortlib.totals_equal(a, b)
	for k, v in pairs(a) do if b[k] ~= v then return false end end
	for k, v in pairs(b) do if a[k] ~= v then return false end end
	return true
end

return sortlib
