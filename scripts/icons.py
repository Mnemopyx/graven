#!/usr/bin/env python3
"""Graven's own icons, drawn from shared style rules, and the icon atlas.

    python3 scripts/icons.py svg              # apps/gui/icons/graven/*.svg
    python3 scripts/icons.py build            # apps/gui/icons/graven.png + .json
    python3 scripts/icons.py sheet ATLAS.json OUT.png   # a contact sheet

The style rules, as the owner chose them (blueprint, "Icon style and ribbon
keys"): outlined in one ink at a thin stroke, on a light ground; regions
filled in one solid colour by the kind of thing they show (KIND); a dashed
outline for the container a tool works inside (what it makes is solid); a
ringed + for a tool that adds; the lowest band left light for the key's
fade.

The atlas (the owner's "option B", 2026-11-22): one PNG and its JSON, in
msdf-atlas-gen's layout. Each icon is a cell. RGB holds the ink's signed
distance field, the same value in all three channels (the ink is lines with
round ends and joins, whose distance field is exact: distance to the
nearest centre line less half the stroke), so a standard MSDF reader draws
the ink. Alpha holds a palette index per pixel: 0 background, k the k-th
entry of the JSON's `palette` (the kind filling that pixel, painted in
order). A reader fills each pixel with its kind's colour (nearest texel:
region edges lie under the ink, which hides them) and draws the ink over it
from the field. Distances are stored as 0.5 + d / distanceRange (d in
pixels at the made size, positive inside the ink), as msdf-atlas-gen does.
"""
import json, math, os, sys

STROKE = 1.2  # on the 24-unit grid
INK = "#2a2530"
LIGHT_BELOW = 19
KIND = {
    "container": "#8fd1c3",
    "track": "#f4c95d",
    "drawn": "#f29b6b",
    "guide": "#b8a2e3",
    "select": "#8fc1f0",
    "view": "#c9d6a3",
    "layer": "#d6d3cc",
    "paper": "#ffffff",
}
PALETTE = list(KIND)  # alpha k -> PALETTE[k - 1]

HERE = os.path.dirname(os.path.abspath(__file__))
ICON_DIR = os.path.join(HERE, "..", "apps", "gui", "icons")
SVG_DIR = os.path.join(ICON_DIR, "graven")

# Atlas: a cell's side in pixels for the 24-unit grid, the distance range
# (pixels, both ways), the padding round a cell.
CELL = 64
RANGE = 8.0
PAD = 4

# --- Geometry --------------------------------------------------------------
#
# An icon is a list of parts, in painting order:
#   ("fill", polygon, kind)     a filled region (no ink)
#   ("ink", polyline)           an ink line (open or closed)
# Shapes below make these.


def arc(cx, cy, r, a0, a1, n=8):
    return [(cx + r * math.cos(a0 + (a1 - a0) * i / n), cy + r * math.sin(a0 + (a1 - a0) * i / n)) for i in range(n + 1)]


def rounded(x, y, w, h, r):
    if r <= 0:
        return [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]
    pts = []
    pts += arc(x + w - r, y + r, r, -math.pi / 2, 0)
    pts += arc(x + w - r, y + h - r, r, 0, math.pi / 2)
    pts += arc(x + r, y + h - r, r, math.pi / 2, math.pi)
    pts += arc(x + r, y + r, r, math.pi, 1.5 * math.pi)
    return pts


def closed(poly):
    return poly + [poly[0]]


def rect(x, y, w, h, kind, r=1.2):
    p = rounded(x, y, w, h, r)
    return [("fill", p, kind), ("ink", closed(p))]


def circle(cx, cy, r, kind):
    p = arc(cx, cy, r, 0, 2 * math.pi, 32)[:-1]
    return [("fill", p, kind), ("ink", closed(p))]


def line(x1, y1, x2, y2):
    return [("ink", [(x1, y1), (x2, y2)])]


def dashes(points, on=2.0, off=1.5):
    """A dashed polyline as separate ink lines: dash k covers [k * period,
    k * period + on] of its length, cut where it turns a corner."""
    segs = []
    at = 0.0
    for (x1, y1), (x2, y2) in zip(points, points[1:]):
        n = math.hypot(x2 - x1, y2 - y1)
        segs.append((at, n, x1, y1, x2, y2))
        at += n
    total, period, out, k = at, on + off, [], 0
    while k * period < total:
        d0, d1 = k * period, min(k * period + on, total)
        piece = []
        for (s0, n, x1, y1, x2, y2) in segs:
            lo, hi = max(d0, s0), min(d1, s0 + n)
            if hi - lo > 1e-6:
                a0, a1 = (lo - s0) / n, (hi - s0) / n
                p0 = (x1 + (x2 - x1) * a0, y1 + (y2 - y1) * a0)
                p1 = (x1 + (x2 - x1) * a1, y1 + (y2 - y1) * a1)
                if piece and math.hypot(piece[-1][0] - p0[0], piece[-1][1] - p0[1]) < 1e-6:
                    piece.append(p1)
                else:
                    if piece:
                        out.append(("ink", piece))
                    piece = [p0, p1]
        if piece:
            out.append(("ink", piece))
        k += 1
    return out


def container(x, y, w, h, kind="container"):
    """The container a tool works inside: filled, its outline dashed."""
    p = [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]
    return [("fill", p, kind)] + dashes(closed(p))


def arrow(x1, y1, x2, y2, head=3.0):
    a = math.atan2(y2 - y1, x2 - x1)
    p1 = (x2 - head * math.cos(a - 0.55), y2 - head * math.sin(a - 0.55))
    p2 = (x2 - head * math.cos(a + 0.55), y2 - head * math.sin(a + 0.55))
    return line(x1, y1, x2, y2) + [("ink", [p1, (x2, y2), p2])]


def adds(x=19, y=14.5):
    """The ringed + of a tool that adds."""
    return circle(x, y, 3.8, "paper") + line(x - 2, y, x + 2, y) + line(x, y - 2, x, y + 2)


def polygon(pts, kind):
    return [("fill", pts, kind), ("ink", closed(pts))]


def polyline(pts):
    return [("ink", pts)]


ICONS = {
    # Containers made on the canvas.
    "add-panel": rect(2.5, 3, 15, 13, "container") + adds(),
    "add-rows": container(2.5, 2, 19, 16) + rect(4.5, 4, 15, 3.4, "track", 0.6) + rect(4.5, 8.3, 15, 3.4, "track", 0.6) + rect(4.5, 12.6, 15, 3.4, "track", 0.6),
    "add-columns": container(2.5, 2, 19, 16) + rect(4.5, 4, 3.4, 12, "track", 0.6) + rect(10.3, 4, 3.4, 12, "track", 0.6) + rect(16.1, 4, 3.4, 12, "track", 0.6),
    "add-track": rect(2, 7.5, 14, 4.5, "track", 0.8) + arrow(17, 9.75, 22.5, 9.75),
    "fit-to-tiles": container(2.5, 3, 19, 5.5) + rect(2.5, 3, 9, 5.5, "track", 0.6) + container(2.5, 10.5, 19, 5.5) + rect(2.5, 10.5, 13, 5.5, "track", 0.6) + arrow(21, 5.75, 13, 5.75) + arrow(21, 13.25, 17, 13.25),
    # Guides.
    "construction-line": dashes([(1.5, 16.5), (22.5, 3.5)], 2.4, 1.8) + circle(7, 13.1, 1.9, "guide") + circle(17, 6.9, 1.9, "guide"),
    # The view's layers.
    "layers": polygon([(12, 2), (21, 6.5), (12, 11), (3, 6.5)], "layer") + polyline([(3, 10), (12, 14.5), (21, 10)]) + polyline([(3, 13.5), (12, 18), (21, 13.5)]),
}

# --- SVG -------------------------------------------------------------------


def to_svg(parts):
    out = []
    # Paths only: DVUI's SVG reader knows no polygon or polyline.
    d = lambda p: "M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in p)
    for part in parts:
        if part[0] == "fill":
            out.append(f'<path d="{d(part[1])} Z" fill="{KIND[part[2]]}"/>')
        else:
            out.append(f'<path d="{d(part[1])}" fill="none" stroke="{INK}" stroke-width="{STROKE}" stroke-linecap="round" stroke-linejoin="round"/>')
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">{"".join(out)}</svg>\n'


def write_svgs():
    os.makedirs(SVG_DIR, exist_ok=True)
    for name, parts in ICONS.items():
        with open(os.path.join(SVG_DIR, name + ".svg"), "w") as f:
            f.write(to_svg(parts))
    print(f"{len(ICONS)} SVGs into {os.path.normpath(SVG_DIR)}")


# --- The atlas --------------------------------------------------------------


def cell_image(parts):
    """An icon's cell: the ink's distance (pixels, positive inside) and the
    palette index per pixel."""
    import numpy as np

    s = CELL / 24.0
    ys, xs = np.mgrid[0:CELL, 0:CELL]
    px = (xs + 0.5) / s
    py = (ys + 0.5) / s
    # Distance to the ink's centre lines, in grid units.
    best = np.full((CELL, CELL), 1e9)
    for part in parts:
        if part[0] != "ink":
            continue
        for (x1, y1), (x2, y2) in zip(part[1], part[1][1:]):
            dx, dy = x2 - x1, y2 - y1
            L2 = dx * dx + dy * dy
            if L2 < 1e-12:
                d = np.hypot(px - x1, py - y1)
            else:
                t = np.clip(((px - x1) * dx + (py - y1) * dy) / L2, 0, 1)
                d = np.hypot(px - (x1 + t * dx), py - (y1 + t * dy))
            best = np.minimum(best, d)
    dist = (STROKE / 2 - best) * s
    # Fills, painted in order (even-odd inside test).
    label = np.zeros((CELL, CELL), dtype=np.uint8)
    for part in parts:
        if part[0] != "fill":
            continue
        poly = part[1]
        inside = np.zeros((CELL, CELL), dtype=bool)
        n = len(poly)
        for i in range(n):
            x1, y1 = poly[i]
            x2, y2 = poly[(i + 1) % n]
            cross = (y1 > py) != (y2 > py)
            with np.errstate(divide="ignore", invalid="ignore"):
                xi = x1 + (py - y1) * (x2 - x1) / (y2 - y1)
            inside ^= cross & (px < xi)
        label[inside] = PALETTE.index(part[2]) + 1
    return dist, label


def build():
    import numpy as np
    from PIL import Image

    names = list(ICONS)
    cols = min(8, len(names))
    rows = (len(names) + cols - 1) // cols
    step = CELL + 2 * PAD
    W, H = cols * step, rows * step
    rgba = np.zeros((H, W, 4), dtype=np.uint8)
    glyphs = []
    for i, name in enumerate(names):
        dist, label = cell_image(ICONS[name])
        v = np.clip(np.round((0.5 + dist / RANGE) * 255), 0, 255).astype(np.uint8)
        x0 = (i % cols) * step + PAD
        y0 = (i // cols) * step + PAD
        for c in range(3):
            rgba[y0:y0 + CELL, x0:x0 + CELL, c] = v
        rgba[y0:y0 + CELL, x0:x0 + CELL, 3] = label
        glyphs.append({
            "index": i,
            "icon": name,
            "advance": 1.0,
            "planeBounds": {"left": 0.0, "top": 0.0, "right": 1.0, "bottom": 1.0},
            "atlasBounds": {"left": x0, "top": y0, "right": x0 + CELL, "bottom": y0 + CELL},
        })
    png = os.path.join(ICON_DIR, "graven.png")
    Image.fromarray(rgba, "RGBA").save(png, optimize=True)
    meta = {
        "atlas": {"type": "msdf", "distanceRange": RANGE, "size": CELL, "width": W, "height": H, "yOrigin": "top"},
        "graven": {
            "format": "graven-icons 1",
            "about": "RGB: the ink's distance field (msdf, all channels equal). Alpha: 0 background, k the palette's k-th entry, the kind filling that pixel.",
            "grid": 24,
            "ink": INK,
            "palette": [{"kind": k, "colour": KIND[k]} for k in PALETTE],
        },
        "glyphs": glyphs,
    }
    with open(os.path.join(ICON_DIR, "graven.json"), "w") as f:
        json.dump(meta, f, indent=1)
    print(f"{len(names)} icons into {os.path.normpath(png)} ({W} x {H}) and graven.json")


# --- Reading it back: the contact sheet -------------------------------------


def hexrgb(h):
    h = h.lstrip("#")
    return [int(h[i:i + 2], 16) for i in (0, 2, 4)]


def render(atlas, meta, glyph, px, ground, ink=None):
    """Icon `glyph` drawn at `px` pixels square over `ground` (RGB), as a
    reader of the format draws it: fills by nearest texel, the ink from the
    field by bilinear sampling, antialiased over a pixel."""
    import numpy as np

    b = glyph["atlasBounds"]
    size = meta["atlas"]["size"]
    rng = meta["atlas"]["distanceRange"]
    pal = [hexrgb(p["colour"]) for p in meta["graven"]["palette"]]
    ink = hexrgb(ink or meta["graven"]["ink"])
    k = size / px  # texels per pixel
    ys, xs = np.mgrid[0:px, 0:px]
    u = b["left"] + (xs + 0.5) * k - 0.5
    v = b["top"] + (ys + 0.5) * k - 0.5
    # Fills: nearest texel.
    lab = atlas[np.clip(np.round(v).astype(int), 0, atlas.shape[0] - 1), np.clip(np.round(u).astype(int), 0, atlas.shape[1] - 1), 3]
    out = np.empty((px, px, 3), dtype=float)
    out[:] = ground
    for i, c in enumerate(pal):
        out[lab == i + 1] = c
    # Ink: bilinear field, distance in screen pixels, a pixel's ramp.
    x0 = np.floor(u).astype(int)
    y0 = np.floor(v).astype(int)
    fx, fy = u - x0, v - y0
    f = atlas[..., 0].astype(float) / 255
    def at(yy, xx):
        return f[np.clip(yy, 0, f.shape[0] - 1), np.clip(xx, 0, f.shape[1] - 1)]
    val = (at(y0, x0) * (1 - fx) * (1 - fy) + at(y0, x0 + 1) * fx * (1 - fy) + at(y0 + 1, x0) * (1 - fx) * fy + at(y0 + 1, x0 + 1) * fx * fy)
    d_px = (val - 0.5) * rng / k
    cov = np.clip(d_px + 0.5, 0, 1)[..., None]
    out = out * (1 - cov) + np.array(ink) * cov
    return out.clip(0, 255).astype(np.uint8)


def sheet(json_path, out_path):
    import numpy as np
    from PIL import Image, ImageDraw

    meta = json.load(open(json_path))
    atlas = np.array(Image.open(os.path.join(os.path.dirname(json_path), "graven.png")).convert("RGBA"))
    sizes = [16, 26, 32, 52, 96]
    grounds = [((246, 245, 242), None), ((44, 34, 54), "#e8e4ee")]
    glyphs = meta["glyphs"]
    colw = sum(s + 12 for s in sizes) + 20
    W = 160 + colw * len(grounds)
    rowh = max(sizes) + 16
    H = 40 + rowh * len(glyphs)
    img = Image.new("RGB", (W, H), (216, 214, 209))
    d = ImageDraw.Draw(img)
    d.text((10, 10), "Graven icons from the atlas: fills by palette index, ink from the distance field (16, 26, 32, 52, 96 px; light and dark ground)", fill=(40, 40, 40))
    for r, g in enumerate(glyphs):
        y = 40 + r * rowh
        d.text((10, y + rowh // 2 - 6), g["icon"], fill=(40, 40, 40))
        x = 160
        for ground, ink in grounds:
            d.rectangle([x - 6, y - 4, x + colw - 20, y + rowh - 8], fill=ground)
            for s in sizes:
                tile = render(atlas, meta, g, s, ground, ink)
                img.paste(Image.fromarray(tile), (x, y + (max(sizes) - s) // 2))
                x += s + 12
            x += 20
    img.save(out_path)
    print(f"sheet into {out_path}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "svg"
    if cmd == "svg":
        write_svgs()
    elif cmd == "build":
        write_svgs()
        build()
    elif cmd == "sheet":
        sheet(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
