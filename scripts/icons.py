#!/usr/bin/env python3
"""Graven's own icons, drawn from shared style rules, and the icon atlas.

    python3 scripts/icons.py svg              # apps/gui/icons/graven/*.svg
    python3 scripts/icons.py build            # apps/gui/icons/graven.png + .json
    python3 scripts/icons.py sheet ATLAS.json OUT.png   # a contact sheet
    python3 scripts/icons.py ribbon ATLAS.json OUT.png  # as the ribbon draws them

The style rules: style B of the icon style guide, the owner's choice
(2026-11-27; https://claude.ai/artifact/5rY6HHY3TZef3JNcbsZSoS, blueprint
"Icon style guide: style B"). Every filled region outlined in the one ink,
1.35 on the 24 grid, round caps and joins; gaps of at least 1.5 units
between inks, dashes 2 on 1.5 off. Fills flat, each one of six slots named
by role (SLOT), at most three chromatic slots an icon: paper (knock-outs,
blank sheets, the ring of a +), neutral (things with no part in the
action), base (what a tool works in: containers, views), subject (what it
makes or acts on: tracks, text, tiles), mark (drawn geometry, points,
attention), focus (selection, choosing). A dashed outline for the
container a tool works inside (what it makes is solid); a ringed + for a
tool that adds; the lowest band (below LIGHT_BELOW) left light for the
key's fade. On a dark ground the ink is drawn light (DARK_INK) and the
slots take the deeper DARK values (the JSON's `schemes.dark`).

The icon file (the owner's choice, 2026-11-22): one PNG and its JSON, the
JSON in msdf-atlas-gen's layout (`atlas`, `glyphs` with `atlasBounds`), its
type Graven's own ("graven-ink"). Each icon is a cell of the PNG.

  RGB  the icon's ground: a plain raster image in full colour. Sub-pixel
       detail is not asked of it. Two kinds of colour are read specially,
       both named in the JSON: the transparent key (saturated magenta), where
       whatever lies behind the icon shows; and the override keys, each a
       named slot ("base", "subject" ...) whose colour the program may
       replace (a theme, a colour-blind set). An override key is the slot's
       default colour itself, so the PNG looks right as it is.
  A    the ink, one colour chosen when drawing: 0.5 - d / range, d the
       distance (pixels at the made size) to the ink's edge, positive inside.
       So 255 is no ink (pure RGB), low values ink; the edge is 128. Tools
       that drop or premultiply the colour of low-alpha pixels lose only
       colour the ink covers.

Drawing it: each texel's colour is resolved first (key -> transparent,
override -> its colour, as premultiplied RGBA), then filtered (averaged to
shrink, bilinear to enlarge), so neither key shows as a fringe. The ink's
coverage comes from A, sharpened to one pixel at the size drawn (when
shrinking, worked out per texel and averaged, so thin ink keeps its weight).
"""
import json, math, os, sys

STROKE = 1.35  # on the 24-unit grid
INK = "#2a2530"
LIGHT_BELOW = 19
# The fills' slots, by role, and their default colours (each colour is the
# slot's override key in the file).
SLOT = {
    "paper": "#fbfaf7",
    "neutral": "#d6d3cc",
    "base": "#8fd1c3",
    "subject": "#f4c95d",
    "mark": "#f0907a",
    "focus": "#8fc1f0",
}
# On a dark ground (the panes): the ink light, the slots deeper. A first
# set, to be tuned on the panes.
DARK_INK = "#ece6f2"
DARK = {
    "paper": "#3e3150",
    "neutral": "#5d5468",
    "base": "#2f7e70",
    "subject": "#a77f12",
    "mark": "#b14a33",
    "focus": "#2a6fae",
}
KEY = "#ff00ff"  # transparent

HERE = os.path.dirname(os.path.abspath(__file__))
ICON_DIR = os.path.join(HERE, "..", "apps", "gui", "icons")
SVG_DIR = os.path.join(ICON_DIR, "graven")

# The file. A cell is a whole button (its ground may fill it): 64 px, the
# ribbon's pitch at 200 %, a BUTTON-unit grid (2 px a unit). The drawing,
# on its 24-unit grid, sits inside at ART units square (the ribbon's 26 of
# 32), MARGIN all round. The ink's distance range (pixels across both sides
# of the edge); the padding between cells (edge texels repeated, so a
# ground filling its cell keeps its edge when enlarged).
CELL = 64
BUTTON = 32
ART = 26
MARGIN = (BUTTON - ART) / 2
RANGE = 4.0
PAD = 4
# The key in the ribbon's fade: its letters' foot this far above the button's
# bottom (device pixels at 64; the owner, 2026-11-22).
KEY_MARGIN = 6

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


def container(x, y, w, h, kind="base"):
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


def corners(x0, y0, x1, y1, n):
    """Four corner brackets of a frame, each arm `n` long."""
    return (polyline([(x0, y0 + n), (x0, y0), (x0 + n, y0)]) + polyline([(x1 - n, y0), (x1, y0), (x1, y0 + n)])
            + polyline([(x0, y1 - n), (x0, y1), (x0 + n, y1)]) + polyline([(x1 - n, y1), (x1, y1), (x1, y1 - n)]))


def pointer(x, y):
    """The pointer's arrow, its tip at (x, y), on paper."""
    pts = [(0, 0), (0, 7.2), (1.7, 5.6), (2.9, 8.2), (4.1, 7.6), (2.9, 5.1), (5.2, 4.9)]
    return polygon([(x + a, y + b) for a, b in pts], "paper")


def curve(pts, n=10):
    """A smooth line through `pts` (Catmull-Rom), as ink."""
    out = []
    p = [pts[0]] + pts + [pts[-1]]
    for i in range(1, len(p) - 2):
        p0, p1, p2, p3 = p[i - 1], p[i], p[i + 1], p[i + 2]
        for k in range(n):
            t = k / n
            t2, t3 = t * t, t * t * t
            out.append(tuple(0.5 * ((2 * p1[j]) + (-p0[j] + p2[j]) * t + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t2 + (-p0[j] + 3 * p1[j] - 3 * p2[j] + p3[j]) * t3) for j in (0, 1)))
    out.append(pts[-1])
    return [("ink", out)]


def dimension(a, b, off):
    """A dimension between points `a` and `b`: a line `off` to the left of
    them (looking from a to b), arrowheads at both ends, short extension
    lines down to the points."""
    dx, dy = b[0] - a[0], b[1] - a[1]
    n = math.hypot(dx, dy)
    nx, ny = dy / n * off, -dx / n * off
    a2 = (a[0] + nx, a[1] + ny)
    b2 = (b[0] + nx, b[1] + ny)
    gap = 0.25
    ext = line(a[0] + nx * gap, a[1] + ny * gap, a2[0] + nx * 0.2, a2[1] + ny * 0.2) + line(b[0] + nx * gap, b[1] + ny * gap, b2[0] + nx * 0.2, b2[1] + ny * 0.2)
    return ext + arrow(a2[0], a2[1], b2[0], b2[1], 2.2) + arrow(b2[0], b2[1], a2[0], a2[1], 2.2)


def ring(cx, cy, r, a0=0.0, a1=2 * math.pi, n=32):
    """An unfilled circle or arc, as ink (angles clockwise on screen)."""
    return [("ink", arc(cx, cy, r, a0, a1, n))]


def dot(x, y, r=1.7):
    """A sketch point."""
    return circle(x, y, r, "mark")


ICONS = {
    # Containers made on the canvas.
    "add-panel": rect(2.5, 3, 15, 13, "base") + adds(),
    "add-rows": container(2.5, 2, 19, 16) + rect(4.5, 4, 15, 3.4, "subject", 0.6) + rect(4.5, 8.3, 15, 3.4, "subject", 0.6) + rect(4.5, 12.6, 15, 3.4, "subject", 0.6),
    "add-columns": container(2.5, 2, 19, 16) + rect(4.5, 4, 3.4, 12, "subject", 0.6) + rect(10.3, 4, 3.4, 12, "subject", 0.6) + rect(16.1, 4, 3.4, 12, "subject", 0.6),
    "add-track": rect(2, 7.5, 14, 4.5, "subject", 0.8) + arrow(17, 9.75, 22.5, 9.75),
    "fit-to-tiles": container(2.5, 3, 19, 5.5) + rect(2.5, 3, 9, 5.5, "subject", 0.6) + container(2.5, 10.5, 19, 5.5) + rect(2.5, 10.5, 13, 5.5, "subject", 0.6) + arrow(21, 5.75, 13, 5.75) + arrow(21, 13.25, 17, 13.25),
    # Guides.
    "construction-line": dashes([(1.5, 16.5), (22.5, 3.5)], 2.4, 1.8) + circle(7, 13.1, 1.9, "mark") + circle(17, 6.9, 1.9, "mark"),
    # The view's layers.
    "layers": polygon([(12, 2), (21, 6.5), (12, 11), (3, 6.5)], "neutral") + polyline([(3, 10), (12, 14.5), (21, 10)]) + polyline([(3, 13.5), (12, 18), (21, 13.5)]),
    # The view: what is chosen, framed.
    "zoom-to-context": [("fill", [(3, 2), (21, 2), (21, 17), (3, 17)], "base")] + corners(3, 2, 21, 17, 4) + rect(8, 6.5, 8, 6, "focus", 0.8),
    # Choosing: a container's boundary (haloed), an area.
    "select-boundaries": [("fill", rounded(1.2, 1.2, 17.6, 15.6, 2.4), "focus")] + rect(3, 3, 14, 12, "base") + rect(5, 7.2, 10, 3.6, "subject", 0.6) + pointer(15.5, 9.5),
    "select-area": container(3, 2.5, 15, 12, "focus") + pointer(15.5, 9.5),
    # Sketching inside a sketch: one made; a shape drawn; constrained.
    "new-sketch": container(2.5, 2.5, 14.5, 13, "paper") + curve([(4.5, 12.5), (6, 6), (10, 5), (12, 10), (15, 6.5)]) + circle(15, 6.5, 1.5, "mark") + circle(4.5, 12.5, 1.5, "mark") + adds(),
    "add-shape": circle(7.5, 7.5, 4.5, "mark") + rect(9.5, 8.5, 7, 7, "mark", 0.4) + adds(),
    # Text: a style (a line of text set in it, on its track).
    "text-style": rect(2.5, 9.5, 19, 6.5, "subject", 0.8) + polyline([(5, 3), (13, 3)]) + line(9, 3, 9, 13.5) + polyline([(14.5, 13.5), (17, 6.5), (19.5, 13.5)]) + line(15.4, 11, 18.6, 11),
    "constrain": line(4, 15, 18, 9) + circle(4, 15, 1.8, "mark") + circle(18, 9, 1.8, "mark") + dimension((4, 15), (18, 9), 4.2),
    # Sketch geometry, as Properties names a constraint's objects.
    "geo-point": dot(12, 11, 2.6),
    "geo-segment": line(5, 17, 19, 5) + dot(5, 17) + dot(19, 5),
    "geo-circle": ring(12, 11, 7.5) + dot(12, 11, 1.3),
    "geo-arc": ring(12, 13, 8, math.pi, 2 * math.pi, 16) + dot(4, 13) + dot(20, 13) + dot(12, 13, 1.3),
    "geo-line": dashes([(2, 18), (22, 4)], 2.4, 1.6),
    "geo-ray": dot(4, 16) + arrow(4, 16, 21, 5),
    "geo-edge": [("fill", [(4, 4), (20, 4), (20, 18), (4, 18)], "base")] + line(4, 4, 4, 18) + dashes([(4, 4), (20, 4), (20, 18), (4, 18)], 2, 1.5),
    # Constraint kinds.
    "con-coincident": line(3, 17, 12, 10) + line(12, 10, 21, 15) + dot(12, 10, 2.4),
    "con-horizontal": line(4, 12, 20, 12) + dot(4, 12) + dot(20, 12) + line(12, 5, 12, 8),
    "con-vertical": line(12, 3, 12, 19) + dot(12, 3) + dot(12, 19) + line(5, 11, 8, 11),
    "con-on-object": ring(12, 20, 13, math.pi * 1.15, math.pi * 1.85, 16) + dot(12, 7, 2.2),
    "con-locked": rect(6, 10, 12, 9, "mark", 1.0) + ring(12, 10, 4, math.pi, 2 * math.pi, 12) + line(12, 13.5, 12, 15.5),
    "con-distance": dot(4, 16) + dot(20, 8) + dimension((4, 16), (20, 8), 3.5),
    "con-distance-x": dot(4, 16) + dot(20, 16) + line(4, 14, 4, 6) + line(20, 14, 20, 6) + arrow(12, 8, 4, 8, 2.2) + arrow(12, 8, 20, 8, 2.2),
    "con-distance-y": dot(6, 3.5) + dot(6, 18.5) + line(8, 3.5, 18, 3.5) + line(8, 18.5, 18, 18.5) + arrow(16, 11, 16, 3.5, 2.2) + arrow(16, 11, 16, 18.5, 2.2),
    "con-line-distance": line(3, 18, 21, 18) + dot(12, 5) + arrow(12, 11.5, 12, 5.5, 2.2) + arrow(12, 11.5, 12, 18, 2.2),
    "con-radius": ring(12, 11, 8) + dot(12, 11, 1.3) + arrow(12, 11, 17.6, 5.4, 2.4),
    "con-diameter": ring(12, 11, 8) + arrow(12, 11, 17.6, 5.4, 2.4) + arrow(12, 11, 6.4, 16.6, 2.4),
    "con-angle": line(4, 18, 21, 18) + line(4, 18, 17, 5) + ring(4, 18, 10, -math.pi / 4, 0, 8),
    "con-parallel": line(4, 14, 14, 4) + line(10, 20, 20, 10),
    "con-perpendicular": line(4, 18, 20, 18) + line(12, 18, 12, 4) + polyline([(12, 14), (16, 14), (16, 18)]),
    "con-tangent": ring(10, 12, 6.5) + line(3, 5.5, 21, 5.5) + dot(10, 5.5, 1.5),
    "con-equal": line(3, 8, 13, 8) + line(11, 15, 21, 15) + line(8, 6, 8, 10) + line(16, 13, 16, 17),
    "con-equal-distance": line(3, 12, 21, 12) + dot(3, 12) + dot(12, 12) + dot(21, 12) + line(6.5, 9.5, 8.5, 14.5) + line(15.5, 9.5, 17.5, 14.5),
    "con-symmetric": dashes([(12, 2), (12, 20)], 2, 1.5) + dot(5, 11) + dot(19, 11) + arrow(9.5, 11, 6.5, 11, 2) + arrow(14.5, 11, 17.5, 11, 2),
}

# --- SVG -------------------------------------------------------------------


def to_svg(parts):
    out = []
    # Paths only: DVUI's SVG reader knows no polygon or polyline.
    d = lambda p: "M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in p)
    for part in parts:
        if part[0] == "fill":
            out.append(f'<path d="{d(part[1])} Z" fill="{SLOT[part[2]]}"/>')
        else:
            out.append(f'<path d="{d(part[1])}" fill="none" stroke="{INK}" stroke-width="{STROKE}" stroke-linecap="round" stroke-linejoin="round"/>')
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">{"".join(out)}</svg>\n'


def write_svgs():
    os.makedirs(SVG_DIR, exist_ok=True)
    for name, parts in ICONS.items():
        with open(os.path.join(SVG_DIR, name + ".svg"), "w") as f:
            f.write(to_svg(parts))
    print(f"{len(ICONS)} SVGs into {os.path.normpath(SVG_DIR)}")


# --- The icon file -----------------------------------------------------------


def cell_image(parts):
    """An icon's cell: the ink's distance (pixels, positive inside) and its
    ground (RGB, the key where nothing is filled). Parts are painted in
    order, so a fill hides the ink beneath it: the distance there becomes
    at most minus the depth inside the fill (fields combined by min and
    max, exact where it matters, at the edges)."""
    import numpy as np

    s = CELL / BUTTON * ART / 24.0  # pixels per drawing unit
    off = CELL / BUTTON * MARGIN
    ys, xs = np.mgrid[0:CELL, 0:CELL]
    px = (xs + 0.5 - off) / s
    py = (ys + 0.5 - off) / s

    def seg_dist(pts):
        best = np.full((CELL, CELL), 1e9)
        for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
            dx, dy = x2 - x1, y2 - y1
            L2 = dx * dx + dy * dy
            if L2 < 1e-12:
                d = np.hypot(px - x1, py - y1)
            else:
                t = np.clip(((px - x1) * dx + (py - y1) * dy) / L2, 0, 1)
                d = np.hypot(px - (x1 + t * dx), py - (y1 + t * dy))
            best = np.minimum(best, d)
        return best

    dist = np.full((CELL, CELL), -1e9)
    rgb = np.empty((CELL, CELL, 3), dtype=np.uint8)
    rgb[:] = hexrgb(KEY)
    for part in parts:
        if part[0] == "ink":
            dist = np.maximum(dist, (STROKE / 2 - seg_dist(part[1])) * s)
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
        rgb[inside] = hexrgb(SLOT[part[2]])
        depth = seg_dist(poly + [poly[0]]) * s
        dist = np.where(inside, np.minimum(dist, -depth), dist)
    return dist, rgb


def build():
    import numpy as np
    from PIL import Image

    names = list(ICONS)
    cols = min(8, len(names))
    rows = (len(names) + cols - 1) // cols
    step = CELL + 2 * PAD
    W, H = cols * step, rows * step
    rgba = np.zeros((H, W, 4), dtype=np.uint8)
    rgba[..., :3] = hexrgb(KEY)
    rgba[..., 3] = 255
    glyphs = []
    for i, name in enumerate(names):
        dist, rgb = cell_image(ICONS[name])
        x0 = (i % cols) * step + PAD
        y0 = (i // cols) * step + PAD
        a = np.clip(np.round((0.5 - dist / RANGE) * 255), 0, 255).astype(np.uint8)
        cell = np.dstack([rgb, a])
        rgba[y0 - PAD:y0 + CELL + PAD, x0 - PAD:x0 + CELL + PAD] = np.pad(cell, ((PAD, PAD), (PAD, PAD), (0, 0)), mode="edge")
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
        "atlas": {"type": "graven-ink", "distanceRange": RANGE, "size": CELL, "width": W, "height": H, "yOrigin": "top"},
        "graven": {
            "format": "graven-icons 1",
            "about": "RGB: the icon's ground, a raster; `transparent` lets what is behind show, `overrides` name colours a program may replace. A: the ink, 0.5 - d / distanceRange (d px to the ink's edge, positive inside): 255 no ink, 128 the edge. Straight alpha, not premultiplied.",
            "button": "each cell is a whole button; its ground may fill it",
            "grid": 24,
            "art": {"grid": BUTTON, "left": MARGIN, "top": MARGIN, "size": ART},
            "ink": INK,
            "transparent": KEY,
            "overrides": [{"key": SLOT[k], "name": k} for k in SLOT],
            "schemes": {"dark": {"ink": DARK_INK, "slots": DARK}},
        },
        "glyphs": glyphs,
    }
    with open(os.path.join(ICON_DIR, "graven.json"), "w") as f:
        json.dump(meta, f, indent=1)
    print(f"{len(names)} icons into {os.path.normpath(png)} ({W} x {H}) and graven.json")


# --- Reading it back ---------------------------------------------------------


def hexrgb(h):
    h = h.lstrip("#")
    return [int(h[i:i + 2], 16) for i in (0, 2, 4)]


def resolve(cell, meta, recolour):
    """A cell's ground as premultiplied RGBA floats (0..1): the key made
    transparent, override keys given their slot's colour (`recolour` maps
    names to colours; a slot not in it keeps its key)."""
    import numpy as np

    g = meta["graven"]
    rgb = cell[..., :3].astype(int)
    out = np.empty(cell.shape[:2] + (4,), dtype=float)
    out[..., :3] = rgb / 255
    out[..., 3] = 1
    def is_(c):
        c = hexrgb(c)
        return (rgb[..., 0] == c[0]) & (rgb[..., 1] == c[1]) & (rgb[..., 2] == c[2])
    for o in g.get("overrides", []):
        if o["name"] in recolour:
            out[is_(o["key"]), :3] = np.array(hexrgb(recolour[o["name"]])) / 255
    out[is_(g["transparent"])] = 0
    return out


def render(atlas, meta, glyph, px, ground, ink=None, recolour={}, shrink="average"):
    # Shrinking by less than half reads the field directly (averaging over
    # 1.2 texels a pixel beats against the texel grid: uneven dashes); by
    # half or more, texels drawn sharply and averaged.
    """Icon `glyph` drawn `px` pixels square over `ground` (RGB 0..255)."""
    import numpy as np
    from PIL import Image

    b = glyph["atlasBounds"]
    size = meta["atlas"]["size"]
    rng = meta["atlas"]["distanceRange"]
    ink = np.array(hexrgb(ink or meta["graven"]["ink"])) / 255
    ground = np.asarray(ground, dtype=float) / 255  # a colour, or px x px x 3
    k = size / px  # texels per pixel
    if shrink == "average" and k >= 2:
        # Shrinking: each texel drawn sharply (the ink over one texel), then
        # averaged down: thin ink keeps its weight.
        cell = atlas[b["top"]:b["bottom"], b["left"]:b["right"]]
        col = resolve(cell, meta, recolour)
        cov = np.clip((0.5 - cell[..., 3] / 255) * rng + 0.5, 0, 1)[..., None]
        out = ground * (1 - col[..., 3:]) + col[..., :3]
        out = out * (1 - cov) + ink * cov
        chans = [np.asarray(Image.fromarray(out[..., c].astype(np.float32), "F").resize((px, px), Image.BOX)) for c in range(3)]
        out = np.stack(chans, -1)
    else:
        # Enlarging: the ground bilinear from resolved texels; the ink's
        # field bilinear, its edge one screen pixel wide.
        pad = 1
        x0, y0 = b["left"] - pad, b["top"] - pad
        cell = atlas[y0:b["bottom"] + pad, x0:b["right"] + pad]
        col = resolve(cell, meta, recolour)
        a = cell[..., 3] / 255
        ys, xs = np.mgrid[0:px, 0:px]
        u = (xs + 0.5) * k - 0.5 + pad
        v = (ys + 0.5) * k - 0.5 + pad
        iu, iv = np.floor(u).astype(int), np.floor(v).astype(int)
        fu, fv = (u - iu)[..., None], (v - iv)[..., None]
        def bil(f):
            f = f if f.ndim == 3 else f[..., None]
            at = lambda yy, xx: f[np.clip(yy, 0, f.shape[0] - 1), np.clip(xx, 0, f.shape[1] - 1)]
            return at(iv, iu) * (1 - fu) * (1 - fv) + at(iv, iu + 1) * fu * (1 - fv) + at(iv + 1, iu) * (1 - fu) * fv + at(iv + 1, iu + 1) * fu * fv
        c = bil(col)
        cov = np.clip((0.5 - bil(a)) * rng / k + 0.5, 0, 1)
        out = ground * (1 - c[..., 3:]) + c[..., :3]
        out = out * (1 - cov) + ink * cov
    return (out * 255).clip(0, 255).round().astype(np.uint8)


def sheet(json_path, out_path):
    import numpy as np
    from PIL import Image, ImageDraw

    meta = json.load(open(json_path))
    atlas = np.array(Image.open(os.path.join(os.path.dirname(json_path), "graven.png")).convert("RGBA"))
    sizes = [16, 26, 32, 64, 96, 128]
    columns = [
        ("light", (246, 245, 242), None, {}),
        ("dark pane: light ink, the dark slots", (44, 34, 54), DARK_INK, DARK),
    ]
    glyphs = meta["glyphs"]
    colw = sum(s + 12 for s in sizes) + 20
    W = 160 + colw * len(columns)
    rowh = max(sizes) + 16
    H = 60 + rowh * len(glyphs)
    img = Image.new("RGB", (W, H), (216, 214, 209))
    d = ImageDraw.Draw(img)
    d.text((10, 10), "Graven icon file: RGB the ground (magenta transparent, override keys), A the ink's distance; each cell a whole button (outlined). 16, 26, 32, 64, 96, 128 px.", fill=(40, 40, 40))
    x = 160
    for title, *_ in columns:
        d.text((x, 36), title, fill=(40, 40, 40))
        x += colw
    for r, g in enumerate(glyphs):
        y = 60 + r * rowh
        d.text((10, y + rowh // 2 - 6), g["icon"], fill=(40, 40, 40))
        x = 160
        for _, ground, ink, rec in columns:
            d.rectangle([x - 6, y - 4, x + colw - 20, y + rowh - 8], fill=ground)
            for s in sizes:
                tile = render(atlas, meta, g, s, ground, ink, rec)
                ty = y + (max(sizes) - s) // 2
                img.paste(Image.fromarray(tile), (x, ty))
                # The button the cell covers.
                d.rectangle([x - 1, ty - 1, x + s, ty + s], outline=(150, 146, 140))
                x += s + 12
            x += 20
    img.save(out_path)
    print(f"sheet into {out_path}")


def ribbon(json_path, out_path):
    """The icons as the ribbon draws them, at the owner's screen's device
    pixels: 64 px buttons at a 64 px pitch, the raised-key shade (A3) as
    each cell's ground, the key in a fade across the bottom. Rows: the fade
    as now (a 32 px band, 55 %), with Alt held (92 %), and a shorter band
    (24 px) to compare."""
    import numpy as np
    from PIL import Image, ImageDraw, ImageFont

    meta = json.load(open(json_path))
    atlas = np.array(Image.open(os.path.join(os.path.dirname(json_path), "graven.png")).convert("RGBA"))
    keys = {"add-panel": "P", "add-rows": "R", "add-columns": "\u21e7R", "add-track": "T", "fit-to-tiles": "F", "construction-line": "G", "layers": "L",
            "zoom-to-context": "0", "select-boundaries": "B", "select-area": "A", "new-sketch": "N", "add-shape": "S", "constrain": "K"}
    font = ImageFont.truetype(os.path.join(HERE, "..", "apps", "gui", "uifont", "DejaVuSans-Bold.ttf"), 20)
    label = ImageFont.truetype(os.path.join(HERE, "..", "apps", "gui", "uifont", "DejaVuSans.ttf"), 22)
    B = 64
    fade_ink = np.array([0x2c, 0x20, 0x3a], dtype=float)  # oklch(0.26 0.07 305)
    rows = [("as now: 32 px band, 55 %", 32, 0.55), ("Alt held: 92 %", 32, 0.92), ("a 24 px band, 55 %", 24, 0.55)]
    glyphs = meta["glyphs"]
    W = 40 + len(glyphs) * B + 40
    H = 30 + len(rows) * (B + 70)
    img = Image.new("RGB", (W, H), (0xf0, 0xee, 0xea))
    d = ImageDraw.Draw(img)
    t = np.linspace(0, 1, B)[:, None, None]
    shade = np.array([0xfb, 0xfa, 0xf8]) * (1 - t) + np.array([0xe6, 0xe4, 0xdf]) * t
    shade = np.broadcast_to(shade, (B, B, 3))
    for r, (title, band, alpha) in enumerate(rows):
        y = 30 + r * (B + 70)
        d.text((40, y - 4), title, font=label, fill=(60, 56, 64))
        y += 30
        for i, g in enumerate(glyphs):
            x = 40 + i * B
            tile = render(atlas, meta, g, B, shade).astype(float)
            # Lines between neighbours: light at the left, dark at the right (2 px).
            tile[:, 0:2] = 255
            tile[:, B - 2:B] *= 0.78
            # The fade.
            inset = 2
            top, y1 = B - band - inset, B - inset
            ramp = np.zeros(B)
            ramp[top:y1] = np.linspace(0, alpha, y1 - top)
            a = ramp[:, None, None]
            tile[:, inset:B - inset] = tile[:, inset:B - inset] * (1 - a) + fade_ink * a
            im = Image.fromarray(tile.clip(0, 255).astype(np.uint8))
            dd = ImageDraw.Draw(im)
            k = keys.get(g["icon"], "?")
            l, tp, rr, bt = dd.textbbox((0, 0), k, font=font)
            dd.text(((B - (rr - l)) / 2 - l, B - KEY_MARGIN - bt), k, font=font, fill=(255, 255, 255))
            img.paste(im, (x, y))
    img.save(out_path)
    print(f"ribbon into {out_path}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "svg"
    if cmd == "svg":
        write_svgs()
    elif cmd == "build":
        write_svgs()
        build()
    elif cmd == "ribbon":
        ribbon(sys.argv[2], sys.argv[3])
    elif cmd == "sheet":
        sheet(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
