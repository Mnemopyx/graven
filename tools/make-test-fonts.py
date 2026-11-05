#!/usr/bin/env python3
"""Generate the engine's test fonts: GravenTest-TT.ttf (quadratic) and
GravenTest-CFF.otf (cubic), with the same glyphs and exact, known areas.

Needs fontTools (pip install fonttools). Run from the repo root:
    tools/make-test-fonts.py lib/engine/testdata

Glyphs, in font units (1000 per em):
  space  advance 250, no outline
  H      rectangle (50,0)-(550,700)                      area 350000, top 700
  O      H's rectangle with a hole (150,100)-(450,600)   area 200000
  D      base (50,0)-(650,0), one quadratic arch, control (350,600)
                                                         area 120000
  A      two overlapping rectangles (50..350, 250..550) x (0..700)
                                                         union 350000, raw sum 420000

OS/2 sCapHeight is deliberately wrong (650, not 700), so tests can check that
cap height is measured from outlines rather than read from OS/2.
"""

import sys
from pathlib import Path

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.reverseContourPen import ReverseContourPen
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.pens.ttGlyphPen import TTGlyphPen

UPEM = 1000
ORDER = [".notdef", "space", "H", "O", "D", "A"]
CMAP = {0x20: "space", ord("H"): "H", ord("O"): "O", ord("D"): "D", ord("A"): "A"}
ADVANCE = {".notdef": 500, "space": 250, "H": 600, "O": 600, "D": 700, "A": 600}
LSB = {".notdef": 0, "space": 0, "H": 50, "O": 50, "D": 50, "A": 50}


def rect(pen, x0, y0, x1, y1, ccw=True):
    pts = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    if not ccw:
        pts.reverse()
    pen.moveTo(pts[0])
    for p in pts[1:]:
        pen.lineTo(p)
    pen.closePath()


def draw(name, pen, cubic):
    """Every outer contour counter-clockwise; holes clockwise."""
    if name == "H":
        rect(pen, 50, 0, 550, 700)
    elif name == "O":
        rect(pen, 50, 0, 550, 700)
        rect(pen, 150, 100, 450, 600, ccw=False)
    elif name == "D":
        pen.moveTo((50, 0))
        pen.lineTo((650, 0))
        if cubic:
            # The same arch, raised exactly to a cubic: controls at 2/3.
            pen.curveTo((450, 400), (250, 400), (50, 0))
        else:
            pen.qCurveTo((350, 600), (50, 0))
        pen.closePath()
    elif name == "A":
        rect(pen, 50, 0, 350, 700)
        rect(pen, 250, 0, 550, 700)


def common(fb, family):
    fb.setupGlyphOrder(ORDER)
    fb.setupCharacterMap(CMAP)
    fb.setupHorizontalMetrics({g: (ADVANCE[g], LSB[g]) for g in ORDER})
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({"familyName": family, "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200,
                sCapHeight=650, sxHeight=500, fsType=0)
    fb.setupPost()


def truetype(path):
    fb = FontBuilder(UPEM, isTTF=True)
    glyphs = {}
    for g in ORDER:
        pen = TTGlyphPen(None)
        # TrueType winds outer contours clockwise: reverse ours.
        draw(g, ReverseContourPen(pen), cubic=False)
        glyphs[g] = pen.glyph()
    common(fb, "Graven Test TT")
    fb.setupGlyf(glyphs)
    fb.save(str(path))


def cff(path):
    fb = FontBuilder(UPEM, isTTF=False)
    charstrings = {}
    for g in ORDER:
        pen = T2CharStringPen(ADVANCE[g], None)
        draw(g, pen, cubic=True)
        charstrings[g] = pen.getCharString()
    common(fb, "Graven Test CFF")
    fb.setupCFF("GravenTestCFF-Regular", {"FullName": "Graven Test CFF"}, charstrings, {})
    fb.save(str(path))


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "lib/engine/testdata")
    out.mkdir(parents=True, exist_ok=True)
    truetype(out / "GravenTest-TT.ttf")
    cff(out / "GravenTest-CFF.otf")


if __name__ == "__main__":
    main()
