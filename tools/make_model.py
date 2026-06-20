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
"look" cycle (head turns AND nods -- wide yaw plus up/down pitch, iron-golem
style); frames 101..104 = four held statue poses (head tilt + arm gestures) the
frozen, fully-oxidized golem seizes up in -- played one frame at a time.

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

def quat_z(angle):
    """Quaternion for rotation about Z (roll), b3d storage order (w,x,y,z)."""
    return (math.cos(angle/2), 0.0, 0.0, math.sin(angle/2))

def quat_mul(a, b):
    """Hamilton product a*b, storage order (w,x,y,z). Applies b then a."""
    w1, x1, y1, z1 = a
    w2, x2, y2, z2 = b
    return (
        w1*w2 - x1*x2 - y1*y2 - z1*z2,
        w1*x2 + x1*w2 + y1*z2 - z1*y2,
        w1*y2 - x1*z2 + y1*w2 + z1*x2,
        w1*z2 + x1*y2 - y1*x2 + z1*w2,
    )

def euler(pitch=0.0, yaw=0.0, roll=0.0):
    """Compose an orientation from degrees: pitch about X (nod up-/down),
    yaw about Y (turn left/right), roll about Z (arm swings out to the side)."""
    return quat_mul(quat_mul(quat_y(math.radians(yaw)),
                             quat_x(math.radians(pitch))),
                    quat_z(math.radians(roll)))

REST = quat_x(0.0)

# Clips share one 1-indexed timeline (B3D frame 0 => Irrlicht "Illegal frame"):
#   WALK  frames 1..21    legs/arms swing about X; head + torso stay at rest
#   LOOK  frames 31..91   head turns AND nods -- wide left/right yaw plus up/down
#                         pitch, iron-golem style (children nose/antenna ride
#                         along); legs/arms/torso hold rest
#   POSE  frames 101..104 four held statue poses for the frozen (fully-oxidized)
#                         golem -- head tilt + arm gestures, played one frame at a
#                         time (self._pose in init.lua picks 101+(n-1))
# Frame 1 (walk phase 0.0) doubles as the stand pose; the head's frame-31 key is
# rest, holding it still through the walk clip so the clips never bleed.
FRAMES = 104
WALK_KEYF = [(1, 0.0), (6, 1.0), (11, 0.0), (16, -1.0), (21, 0.0)]

# Head idle "look": (frame, yaw deg, pitch deg). Wide sweep -- glances up to the
# left, down at centre, up to the right, then settles. SIGN CONVENTION (Irrlicht
# renders left-handed; verified in-game June 19): +pitch tips the snout UP (look
# above), -pitch tips it DOWN (look below); +yaw turns left, -yaw turns right.
LOOK_HEAD = [
    (31,   0,   0),
    (43,  46,  24),   # turn left, look up
    (55,   0, -18),   # centre, look down
    (67, -46,  26),   # turn right, look up
    (79, -20,  -8),   # slight right, slight down
    (91,   0,   0),
]

# Four freeze poses, indexed 1..4, each a dict of bone -> orientation. Anything
# unlisted holds REST (so the legs always stand). Tunable; arm "roll" swings the
# arm out from the side (+ for arm_r, - for arm_l), "pitch" swings it forward.
POSE_FRAMES = [101, 102, 103, 104]
# SIGN CONVENTION (Irrlicht left-handed; verified in-game June 19):
#   arm  pitch +=swing FORWARD, -=back;  roll: arm_r -=out to its side / up-out,
#        +=in across the body (arm_l mirrored, + = out / up-out);
#   head pitch +=look up, -=down;  yaw +=turn left, -=right;  roll +=tilt right;
#   torso pitch -=lean forward, +=lean back;  roll +=lean right.
# Each pose makes the two arms do DIFFERENT things so none looks like both arms
# pointing the same way.
POSES = [
    {   # 1. Hail -- right arm thrust up-and-out overhead, left arm hanging; head
        # tipped up and turned toward the raised hand.
        "arm_r": euler(roll=-150, pitch=10), "arm_l": euler(roll=12),
        "head":  euler(pitch=22, yaw=-24), "torso": euler(roll=6),
    },
    {   # 2. Presenter -- right arm out to the side, left arm reaching forward;
        # head bowed slightly and turned to the forward hand.
        "arm_r": euler(roll=-88), "arm_l": euler(pitch=82),
        "head":  euler(pitch=-10, yaw=16), "torso": euler(roll=5),
    },
    {   # 3. Reach-and-recoil -- right arm reaching forward, left arm flung back;
        # head down-forward, torso leaning into the reach.
        "arm_r": euler(pitch=90), "arm_l": euler(pitch=-48),
        "head":  euler(pitch=-16, yaw=-10), "torso": euler(pitch=-9),
    },
    {   # 4. Jaunty -- right arm cocked up-and-out, left arm held OUT to its own
        # side (never across the front); head cocked with a matching torso roll.
        # NB: arm_l roll must stay POSITIVE here -- a negative roll swings the left
        # arm inward across the groin, which read as an obscene gesture in-game.
        "arm_r": euler(roll=-120, pitch=14), "arm_l": euler(roll=34),
        "head":  euler(yaw=18, roll=12, pitch=6), "torso": euler(roll=8),
    },
]

def pose_keys(bone):
    return [(fr, pose.get(bone, REST)) for fr, pose in zip(POSE_FRAMES, POSES)]

def bone_keys(bone):
    if bone in ("leg_l", "leg_r", "arm_l", "arm_r"):
        amp  = WALK_AMP_LEG if "leg" in bone else WALK_AMP_ARM
        sign = 1 if bone in ("leg_l", "arm_r") else -1
        keys = [(f, quat_x(sign * amp * ph)) for f, ph in WALK_KEYF]
        keys.append((91, REST))                 # hold rest across the look clip
        return keys + pose_keys(bone)
    if bone == "head":
        keys = [(1, REST)]                      # rest through the walk clip
        keys += [(f, euler(pitch=p, yaw=y)) for f, y, p in LOOK_HEAD]
        return keys + pose_keys(bone)
    return [(1, REST), (91, REST)] + pose_keys(bone)  # torso

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
