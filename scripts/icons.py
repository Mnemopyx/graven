#!/usr/bin/env python3
"""Graven's own icons, drawn from shared style rules (2026-11-22).

Writes apps/gui/icons/graven/<name>.svg. The rules, as the owner chose
them (blueprint, "Icon style and ribbon keys"):

- Outlined: one ink, a thin stroke (STROKE on a 24-unit grid), on a light
  ground.
- Regions filled in one solid colour by the kind of thing they show
  (KIND below).
- A dashed outline: the container a tool works inside (what it makes is
  drawn solid). Dashes are cut into segments here: TinyVG, which the GUI
  draws, has none.
- A ringed + at lower right: the tool adds.
- The lowest band (y > LIGHT_BELOW) is left light: the key's fade lies
  there.

Run: python3 scripts/icons.py
"""
import math, os

STROKE = 1.2
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
OUT = os.path.join(os.path.dirname(__file__), "..", "apps", "gui", "icons", "graven")


def stroke(extra=""):
    return f'stroke="{INK}" stroke-width="{STROKE}" stroke-linecap="round" stroke-linejoin="round"{extra}'


def rect(x, y, w, h, kind, r=1.2):
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{KIND[kind]}" {stroke()}/>'


def dashes(points, on=2.0, off=1.5):
    """A dashed polyline (closed when the last point is the first) as
    separate short lines: dash k covers [k * period, k * period + on] of
    the polyline's length, cut where it turns a corner."""
    segs = []
    at = 0.0
    for (x1, y1), (x2, y2) in zip(points, points[1:]):
        n = math.hypot(x2 - x1, y2 - y1)
        segs.append((at, n, x1, y1, x2, y2))
        at += n
    total = at
    out = []
    period = on + off
    k = 0
    while k * period < total:
        d0 = k * period
        d1 = min(d0 + on, total)
        for (s0, n, x1, y1, x2, y2) in segs:
            lo = max(d0, s0)
            hi = min(d1, s0 + n)
            if hi - lo > 1e-6:
                a0 = (lo - s0) / n
                a1 = (hi - s0) / n
                out.append(f'<line x1="{x1 + (x2 - x1) * a0:.2f}" y1="{y1 + (y2 - y1) * a0:.2f}" x2="{x1 + (x2 - x1) * a1:.2f}" y2="{y1 + (y2 - y1) * a1:.2f}" {stroke()}/>')
        k += 1
    return "".join(out)


def container(x, y, w, h, kind="container"):
    """The container a tool works inside: filled, its outline dashed."""
    fill = f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="{KIND[kind]}"/>'
    return fill + dashes([(x, y), (x + w, y), (x + w, y + h), (x, y + h), (x, y)])


def line(x1, y1, x2, y2):
    return f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" {stroke()}/>'


def arrow(x1, y1, x2, y2, head=3.0):
    a = math.atan2(y2 - y1, x2 - x1)
    p1 = (x2 - head * math.cos(a - 0.55), y2 - head * math.sin(a - 0.55))
    p2 = (x2 - head * math.cos(a + 0.55), y2 - head * math.sin(a + 0.55))
    return line(x1, y1, x2, y2) + f'<polyline points="{p1[0]:.2f},{p1[1]:.2f} {x2},{y2} {p2[0]:.2f},{p2[1]:.2f}" fill="none" {stroke()}/>'


def circle(cx, cy, r, kind):
    return f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{KIND[kind]}" {stroke()}/>'


def adds(x=19, y=14.5):
    """The ringed + of a tool that adds."""
    return circle(x, y, 3.8, "paper") + line(x - 2, y, x + 2, y) + line(x, y - 2, x, y + 2)


def path(d, kind=None):
    fill = KIND[kind] if kind else "none"
    return f'<path d="{d}" fill="{fill}" {stroke()}/>'


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
    "layers": path("M12 2 L21 6.5 L12 11 L3 6.5 Z", "layer") + path("M3 10 L12 14.5 L21 10") + path("M3 13.5 L12 18 L21 13.5"),
}


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, body in ICONS.items():
        svg = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">{body}</svg>\n'
        with open(os.path.join(OUT, name + ".svg"), "w") as f:
            f.write(svg)
    print(f"{len(ICONS)} icons into {os.path.normpath(OUT)}")


if __name__ == "__main__":
    main()
