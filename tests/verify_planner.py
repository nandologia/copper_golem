#!/usr/bin/env python3
"""1:1 Python port of sortlib.plan, to verify the algorithm offline (no lua on box).
Keep in lockstep with ../sortlib.lua. Same indices conceptually (0-based here)."""
import random

def plan(current, target):
    N = len(target)
    W = [dict(c) if c else None for c in current]
    while len(W) < N:
        W.append(None)
    moves = []

    def record(frm, to, count):
        moves.append((frm, to, count))
        fk, fmax = W[frm]['key'], W[frm]['max']
        W[frm]['count'] -= count
        if W[frm]['count'] == 0:
            W[frm] = None
        if W[to] is None:
            W[to] = {'key': fk, 'count': count, 'max': fmax}
        else:
            W[to]['count'] += count

    def push_right(i, amount, k, mx):
        j = i + 1
        while amount > 0 and j < N:
            if W[j] and W[j]['key'] == k:
                r = mx - W[j]['count']
                if r > 0:
                    m = min(amount, r); record(i, j, m); amount -= m
            j += 1
        j = i + 1
        while amount > 0 and j < N:
            if W[j] is None:
                m = min(amount, mx); record(i, j, m); amount -= m
            j += 1
        return amount

    def pull_left(i, k, need):
        j = i + 1
        while need > 0 and j < N:
            if W[j] and W[j]['key'] == k:
                m = min(need, W[j]['count']); record(j, i, m); need -= m
            j += 1
        return need

    for i in range(N):
        t = target[i]
        if t:
            if W[i] and W[i]['key'] != t['key']:
                push_right(i, W[i]['count'], W[i]['key'], W[i]['max'])  # evict wrong item
            if W[i] and W[i]['key'] != t['key']:
                continue  # congested: couldn't vacate; the atomic finalize fixes it
            have = W[i]['count'] if W[i] else 0
            if have > t['count']:
                push_right(i, have - t['count'], t['key'], t['max'])   # shed surplus
            elif have < t['count']:
                pull_left(i, t['key'], t['count'] - have)              # gather deficit
        elif W[i]:
            push_right(i, W[i]['count'], W[i]['key'], W[i]['max'])     # clear toward empty
    return moves, W

def simulate(state, moves):
    W = [dict(c) if c else None for c in state]
    for frm, to, count in moves:
        f = W[frm]; key, mx = f['key'], f['max']
        f['count'] -= count
        if f['count'] == 0:
            W[frm] = None
        if W[to] is None:
            W[to] = {'key': key, 'count': count, 'max': mx}
        else:
            W[to]['count'] += count
    return W

def totals(state):
    t = {}
    for c in state:
        if c:
            t[c['key']] = t.get(c['key'], 0) + c['count']
    return t

ITEMS = [('cobble',64),('diorite',64),('granite',64),('wheat',16),('egg',1)]

def build_target(slots):
    N = len(slots)
    merged, order = {}, []
    for c in slots:
        if c:
            if c['key'] not in merged:
                merged[c['key']] = {'count':0,'max':c['max']}; order.append(c['key'])
            merged[c['key']]['count'] += c['count']
    order.sort()
    units = []
    for k in order:
        total, mx = merged[k]['count'], merged[k]['max']
        while total > 0:
            n = min(total, mx); units.append({'key':k,'count':n,'max':mx}); total -= n
    return [units[i] if i < len(units) else None for i in range(N)]

def random_slots(N):
    s = []
    for _ in range(N):
        if random.random() < 0.35:
            s.append(None)
        else:
            k, mx = random.choice(ITEMS)
            s.append({'key':k,'count':random.randint(1,mx),'max':mx})
    return s

def eq_layout(a, b):
    if len(a) != len(b): return False
    for x, y in zip(a, b):
        if (x is None) != (y is None): return False
        if x and (x['key'] != y['key'] or x['count'] != y['count']): return False
    return True

random.seed(1234)
ITER = 50000
reached = cons_fail = overfill = 0
for it in range(ITER):
    N = random.randint(3, 27)
    cur = random_slots(N)
    tgt = build_target(cur)
    assert totals(cur) == totals(tgt), "target builder changed totals"
    moves, _ = plan(cur, tgt)
    final = simulate(cur, moves)
    if totals(cur) != totals(final):
        cons_fail += 1
    if any(c and c['count'] > c['max'] for c in final):
        overfill += 1
    if eq_layout(final, tgt):
        reached += 1

print(f"{ITER} iterations")
print(f"  conservation failures : {cons_fail}  (MUST be 0)")
print(f"  overfill failures     : {overfill}  (MUST be 0)")
print(f"  reached target exactly: {reached}/{ITER} ({100*reached/ITER:.2f}%)")
assert cons_fail == 0 and overfill == 0, "SAFETY FAIL"
print("OK")
