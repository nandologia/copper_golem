#!/usr/bin/env python3
"""Generate models/copper_golem.b3d -- the copper golem mesh + walk animation.

The geometry and UV layout are derived from the provided 64x64 texture atlas
(standard Minecraft entity unwrap: top/bottom on the first row, then
right/front/left/back). Parts (pixel units, 16 px = 1 node):

    head   8w x 5h x 10d  uv(0,0)     bone "head"
    nose   3 x 2 x 2      uv(38,0)    bone "head"   (small snout, low on the face)
    shaft  2 x 4 x 2      uv(38,8)    bone "head"   (antenna rod)
    tip    4 x 3 x 2      uv(57,0)    bone "head"   (antenna paddle)
    body   8 x 6 x 6      uv(0,15)    bone "torso"
    arm    3 x 10 x 4     uv(36,16) / uv(50,16)     bones arm_l / arm_r
    leg    4 x 5 x 4      uv(0,27)  / uv(16,27)     bones leg_l / leg_r

Output scale: 1 px = 0.625 b3d units, so the 16 px body height = 10 units
= 1.0 node at visual_size 1 (Luanti renders mesh units / 10).

Animation (24 fps): frames 1..21 = walk cycle (frame 1 = rest/stand pose; legs
swing +-35 deg about X, arms +-20 deg opposite phase); frames 31..91 = idle
"look" cycle (head yaws +-34 deg about Y, the rest of the body at rest).

Run:  python3 make_model.py   (writes ../models/copper_golem.b3d)
"""
import math
import os
import struct

PX = 0.625          # b3d units per texture pixel
TEX_W, TEX_H = 64, 64
FPS = 24.0
WALK_AMP_LEG = math.radians(35)
WALK_AMP_ARM = math.radians(20)

# ---------------------------------------------------------------- geometry --
# Each part: x/y/z ranges in px (y up, +Z = front), uv origin, box w/h/d in px,
# and the bone that drives it. "uv_clamp" parts have left/back faces falling
# off the canvas (artist omitted them); we reuse the right/front rects there.
PARTS = [
    # name      x0  x1   y0  y1   z0  z1   u   v   w  h  d   bone
    ("head",    -4,  4,  11, 16,  -5,  5,   0,  0,  8, 5, 10, "head"),
    ("nose",  -1.5, 1.5, 11, 13,   5,  7,  38,  0,  3, 2,  2, "head"),
    ("shaft",   -1,  1,  16, 20,  -1,  1,  38,  8,  2, 4,  2, "head"),
    ("tip",     -2,  2,  20, 23,  -1,  1,  57,  0,  4, 3,  2, "head"),
    ("body",    -4,  4,   5, 11,  -3,  3,   0, 15,  8, 6,  6, "torso"),
    ("arm_l",   -7, -4,   1, 11,  -2,  2,  36, 16,  3, 10, 4, "arm_l"),
    ("arm_r",    4,  7,   1, 11,  -2,  2,  50, 16,  3, 10, 4, "arm_r"),
    ("leg_l",   -4,  0,   0,  5,  -2,  2,   0, 27,  4, 5,  4, "leg_l"),
    ("leg_r",    0,  4,   0,  5,  -2,  2,  16, 27,  4, 5,  4, "leg_r"),
]
# the tip's left/back rects fall outside the 64px canvas -> mirror visible ones
UV_CLAMP = {"tip"}

# Bone pivots in px (model space); all are children of the root.
BONES = {
    "torso": (0, 5,  0),
    "head":  (0, 11, 0),
    "arm_l": (-5.5, 10.5, 0),
    "arm_r": (5.5, 10.5, 0),
    "leg_l": (-2, 5, 0),
    "leg_r": (2, 5, 0),
}

# ------------------------------------------------------------ mesh building --
verts = []   # (x,y,z, nx,ny,nz, u,v)
tris = []
bone_verts = {b: [] for b in BONES}

def face(corners, normal, uvrect, bone):
    """corners: 4 (x,y,z) px tuples CCW from outside, starting top-left of the
    UV rect; uvrect: (u0,v0,u1,v1) px. Emits 2 triangles."""
    u0, v0, u1, v1 = uvrect
    uvs = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]
    base = len(verts)
    for (x, y, z), (u, v) in zip(corners, uvs):
        verts.append((x*PX, y*PX, z*PX, *normal, u/TEX_W, v/TEX_H))
        bone_verts[bone].append(len(verts) - 1)
    tris.append((base, base+1, base+2))
    tris.append((base, base+2, base+3))

def box(name, x0, x1, y0, y1, z0, z1, u, v, w, h, d, bone):
    """Standard MC entity unwrap. v increases downward (Irrlicht UV origin is
    top-left). Side faces: texture top edge = box top (y1)."""
    top    = (u+d,     v,   u+d+w,   v+d)
    bottom = (u+d+w,   v,   u+d+w+w, v+d)
    right  = (u,       v+d, u+d,     v+d+h)   # -X side
    front  = (u+d,     v+d, u+d+w,   v+d+h)   # +Z
    left   = (u+d+w,   v+d, u+d+w+d, v+d+h)   # +X side
    back   = (u+d+w+d, v+d, u+d+w+d+w, v+d+h) # -Z
    if name in UV_CLAMP:
        left, back = right, front
    # +Z front: viewed from +Z, x decreases left->right in texture space
    face([(x1,y1,z1),(x0,y1,z1),(x0,y0,z1),(x1,y0,z1)], (0,0,1),  front,  bone)
    # -Z back
    face([(x0,y1,z0),(x1,y1,z0),(x1,y0,z0),(x0,y0,z0)], (0,0,-1), back,   bone)
    # -X right side (texture seen from -X)
    face([(x0,y1,z1),(x0,y1,z0),(x0,y0,z0),(x0,y0,z1)], (-1,0,0), right,  bone)
    # +X left side
    face([(x1,y1,z0),(x1,y1,z1),(x1,y0,z1),(x1,y0,z0)], (1,0,0),  left,   bone)
    # +Y top: texture bottom edge (v1) faces front +Z
    face([(x0,y1,z0),(x1,y1,z0),(x1,y1,z1),(x0,y1,z1)], (0,1,0),  top,    bone)
    # -Y bottom
    face([(x0,y0,z1),(x1,y0,z1),(x1,y0,z0),(x0,y0,z0)], (0,-1,0), bottom, bone)

for p in PARTS:
    box(*p)

# -------------------------------------------------------------- animation ---
def quat_x(angle):
    """Quaternion for rotation about X, b3d storage order (w,x,y,z)."""
    return (math.cos(angle/2), math.sin(angle/2), 0.0, 0.0)

def quat_y(angle):
    """Quaternion for rotation about Y (yaw), b3d storage order (w,x,y,z)."""
    return (math.cos(angle/2), 0.0, math.sin(angle/2), 0.0)

REST = quat_x(0.0)
LOOK_AMP = math.radians(34)        # head yaw sweep for the occasional idle "look"

# Two clips share one 1-indexed timeline (B3D frame 0 => Irrlicht "Illegal frame"):
#   WALK  frames 1..21   legs/arms swing about X; head + torso stay at rest
#   LOOK  frames 31..91  head yaws L->R->L (its children nose/antenna ride along);
#                        legs/arms/torso hold rest
# Frame 1 (walk phase 0.0) doubles as the stand pose. A rest key at frame 31 on
# the head keeps it still through the whole walk clip so the clips never bleed;
# the legs hold their frame-21 pose (phase 0 = rest) all through the look clip.
FRAMES = 91
WALK_KEYF = [(1, 0.0), (6, 1.0), (11, 0.0), (16, -1.0), (21, 0.0)]
LOOK_KEYF = [(31, 0.0), (46, 1.0), (61, 0.0), (76, -1.0), (91, 0.0)]

def bone_keys(bone):
    if bone in ("leg_l", "leg_r", "arm_l", "arm_r"):
        amp  = WALK_AMP_LEG if "leg" in bone else WALK_AMP_ARM
        sign = 1 if bone in ("leg_l", "arm_r") else -1
        keys = [(f, quat_x(sign * amp * ph)) for f, ph in WALK_KEYF]
        keys.append((91, REST))                 # hold rest across the look clip
        return keys
    if bone == "head":
        keys = [(1, REST), (31, REST)]          # rest through the walk clip
        keys += [(f, quat_y(LOOK_AMP * ph)) for f, ph in LOOK_KEYF[1:]]
        return keys
    return [(1, REST), (91, REST)]              # torso: rest the whole timeline

# ------------------------------------------------------------- b3d writing --
def cstr(s): return s.encode() + b"\0"
def f(*vals): return struct.pack("<%df" % len(vals), *vals)
def i(*vals): return struct.pack("<%di" % len(vals), *vals)
def chunk(tag, payload): return tag + struct.pack("<i", len(payload)) + payload

texs = chunk(b"TEXS", cstr("copper_golem.png") + i(0, 0) + f(0,0, 1,1, 0))
brus = chunk(b"BRUS", i(1) + cstr("brush") + f(1,1,1,1, 0) + i(0, 0) + i(0))

vrts = i(1, 1, 2)  # flags=1 (normals), 1 texcoord set, 2 floats each
for vx in verts:
    vrts += f(*vx)
vrts = chunk(b"VRTS", vrts)
tris_pay = i(0)
for t in tris:
    tris_pay += i(*t)
mesh = chunk(b"MESH", i(0) + vrts + chunk(b"TRIS", tris_pay))

anim = chunk(b"ANIM", i(0, FRAMES) + f(FPS))

def bone_node(name):
    px_, py_, pz_ = BONES[name]
    pay = cstr(name) + f(px_*PX, py_*PX, pz_*PX) + f(1,1,1) + f(*REST)
    bone_pay = b""
    for vi in bone_verts[name]:
        bone_pay += i(vi) + f(1.0)
    pay += chunk(b"BONE", bone_pay)
    keys_pay = i(7)  # flags: position + scale + rotation per key
    for frame, q in bone_keys(name):
        keys_pay += i(frame) + f(px_*PX, py_*PX, pz_*PX) + f(1,1,1) + f(*q)
    pay += chunk(b"KEYS", keys_pay)
    return chunk(b"NODE", pay)

root = cstr("root") + f(0,0,0) + f(1,1,1) + f(*REST) + mesh + anim
for b in BONES:
    root += bone_node(b)
root = chunk(b"NODE", root)

out = chunk(b"BB3D", i(1) + texs + brus + root)
dest = os.path.join(os.path.dirname(__file__), "..", "models", "copper_golem.b3d")
with open(dest, "wb") as fh:
    fh.write(out)
print(f"wrote {os.path.normpath(dest)}: {len(out)} bytes, "
      f"{len(verts)} verts, {len(tris)} tris, {len(BONES)} bones, {FRAMES} frames")
