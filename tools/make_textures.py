#!/usr/bin/env python3
"""Generate the copper golem's 8 texture atlases from Mineclonia's copper blocks.

Each golem oxidation stage is skinned with the matching base-game copper BLOCK
texture (tools/copper_src/mcl_copper_{block,exposed,weathered,oxidized}.png),
tiled continuously across the entity unwrap so the golem reads as if carved from
that block -- rivets, scuffs and patina come straight from the block art, with a
light per-face bevel for plate definition. The eyes are a separate green
gradient overlay (body^eyes, combined in-engine).

Source blocks are Mineclonia's, by NO11 (GPL / CC BY-SA -- credit + share-alike
when publishing; bundled in tools/copper_src so this script is self-contained).
The output atlases are therefore derivative of that CC BY-SA art.

It mirrors the EXACT UV atlas baked by tools/make_model.py: the PARTS table and
box-unwrap math below are copied from it and MUST stay in sync (change a part's
uv/size there -> change it here -> re-run both).

Run:  python3 make_textures.py            # writes ../textures/*.png
      python3 make_textures.py ./preview  # writes into ./preview instead
"""
import os
import sys
from PIL import Image

TEX_W, TEX_H = 64, 64          # must match make_model.py
SRC_DIR = os.path.join(os.path.dirname(__file__), "copper_src")

# golem stage suffix -> base-game copper block variant it is skinned with
STAGE_SRC = [
    ("",           "mcl_copper_block.png"),
    ("exposed_",   "mcl_copper_exposed.png"),
    ("weathered_", "mcl_copper_weathered.png"),
    ("oxidized_",  "mcl_copper_oxidized.png"),
]

# ---- UV atlas layout: copied from make_model.py (keep in sync!) ------------
# name, x0,x1, y0,y1, z0,z1, u,v, w,h,d, bone  (only u,v,w,h,d matter here)
PARTS = [
    ("head",    -4,    4,    11, 16,  -5,  5,   0,  0,  8, 5, 10, "head"),
    ("nose",    -1.5,  1.5,  11, 13,   5,  7,  38,  0,  3, 2,  2, "head"),
    ("shaft",   -1,    1,    16, 20,  -1,  1,  38,  8,  2, 4,  2, "head"),
    ("tip",     -2,    2,    20, 23,  -1,  1,  57,  0,  4, 3,  2, "head"),
    ("body",    -4,    4,     5, 11,  -3,  3,   0, 15,  8, 6,  6, "torso"),
    ("arm_l",   -7,   -4,     1, 11,  -2,  2,  36, 16,  3, 10, 4, "arm_l"),
    ("arm_r",    4,    7,     1, 11,  -2,  2,  50, 16,  3, 10, 4, "arm_r"),
    ("leg_l",   -4,    0,     0,  5,  -2,  2,   0, 27,  4, 5,  4, "leg_l"),
    ("leg_r",    0,    4,     0,  5,  -2,  2,  16, 27,  4, 5,  4, "leg_r"),
]
UV_CLAMP = {"tip"}

BEVEL_HI = 1.12                # top/left edge of each face (lit)
BEVEL_SH = 0.82               # bottom/right edge (shaded)

# eye gradient (top -> bottom), green; two 2x2 eyes high on the head front face
EYE_TOP = (130, 255, 150)
EYE_BOT = (26, 150, 72)


def box_faces(u, v, w, h, d, clamp=False):
    """The 6 face rects (u0,v0,u1,v1) px -- identical math to make_model.box()."""
    faces = {
        "top":    (u + d,         v,     u + d + w,         v + d),
        "bottom": (u + d + w,     v,     u + d + 2 * w,     v + d),
        "right":  (u,             v + d, u + d,             v + d + h),
        "front":  (u + d,         v + d, u + d + w,         v + d + h),
        "left":   (u + d + w,     v + d, u + 2 * d + w,     v + d + h),
        "back":   (u + 2 * d + w, v + d, u + 2 * d + 2 * w, v + d + h),
    }
    if clamp:
        faces["left"], faces["back"] = faces["right"], faces["front"]
    return faces


def clip(x, lo, hi):
    return max(lo, min(hi, x))


def eye_rects(head_front):
    """Two 2x2 eye boxes, symmetric, in the upper half of the head front face."""
    u0, v0, u1, v1 = (int(round(c)) for c in head_front)   # (10,10,18,15)
    cy = v0                                                # top rows of the face
    return [
        (u0 + 1, cy, u0 + 3, cy + 2),    # left  eye (cols 11-12, rows 10-11)
        (u1 - 3, cy, u1 - 1, cy + 2),    # right eye (cols 15-16, rows 10-11)
    ]


def paint_face(px, block, rect):
    """Tile the copper-block texture into a face rect, lit-from-top-left bevel."""
    bw, bh = block.size
    u0, v0, u1, v1 = (int(round(c)) for c in rect)
    if u1 - u0 <= 0 or v1 - v0 <= 0:
        return
    for y in range(clip(v0, 0, TEX_H), clip(v1, 0, TEX_H)):
        for x in range(clip(u0, 0, TEX_W), clip(u1, 0, TEX_W)):
            r, g, b, a = block.getpixel((x % bw, y % bh))
            f = 1.0
            if x == u0 or y == v0:
                f = BEVEL_HI
            if x == u1 - 1 or y == v1 - 1:
                f = BEVEL_SH
            px[x, y] = (
                clip(int(r * f), 0, 255),
                clip(int(g * f), 0, 255),
                clip(int(b * f), 0, 255),
                255,
            )


def build_body(block):
    img = Image.new("RGBA", (TEX_W, TEX_H), (0, 0, 0, 0))
    px = img.load()
    head_front = None
    for name, *rest in PARTS:
        x0, x1, y0, y1, z0, z1, u, v, w, h, d, bone = rest
        for fname, rect in box_faces(u, v, w, h, d, clamp=(name in UV_CLAMP)).items():
            paint_face(px, block, rect)
        if name == "head":
            head_front = box_faces(u, v, w, h, d)["front"]
    # darken the eye sockets so the green glow overlay reads against the copper
    for ex0, ey0, ex1, ey1 in eye_rects(head_front):
        for y in range(ey0, ey1):
            for x in range(ex0, ex1):
                r, g, b, a = px[x, y]
                px[x, y] = (r // 4, g // 4, b // 4, 255)
    return img, head_front


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def build_eyes(head_front):
    img = Image.new("RGBA", (TEX_W, TEX_H), (0, 0, 0, 0))
    px = img.load()
    for ex0, ey0, ex1, ey1 in eye_rects(head_front):
        span = max(1, ey1 - 1 - ey0)
        for y in range(ey0, ey1):
            col = lerp(EYE_TOP, EYE_BOT, (y - ey0) / span)
            for x in range(ex0, ex1):
                px[x, y] = (*col, 255)
    return img


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(__file__), "..", "textures")
    os.makedirs(out_dir, exist_ok=True)
    for suffix, src in STAGE_SRC:
        block = Image.open(os.path.join(SRC_DIR, src)).convert("RGBA")
        body, head_front = build_body(block)
        body.save(os.path.join(out_dir, f"{suffix}copper_golem.png"))
        build_eyes(head_front).save(
            os.path.join(out_dir, f"{suffix}copper_golem_eyes.png"))
    print(f"wrote 8 copper-block-skinned 64x64 atlases to {os.path.normpath(out_dir)}")


if __name__ == "__main__":
    main()
