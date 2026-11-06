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
  plus   (U+002B) bars (250,100)-(350,500) and (100,250)-(500,350): a binary operator
  equal  (U+003D) bars (100,200)-(500,280) and (100,420)-(500,500): a relation
  circumflex  (U+02C6, spacing) rectangle (100,0)-(500,100), advance 600: drawn accents
  uni0302     (U+0302, combining) rectangle (-450,750)-(-150,850), advance 0: marks

OS/2 sCapHeight is deliberately wrong (650, not 700), so tests can check that
cap height is measured from outlines rather than read from OS/2.

GravenTest-Fallback.ttf has what the others lack, at a different cap height,
so tests can check fallback and cap-height matching:
  space  advance 250
  H      rectangle (50,0)-(450,500): cap height 500
  x      rectangle (50,0)-(350,300)                      area 90000
"""

import sys
from pathlib import Path

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.reverseContourPen import ReverseContourPen
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.pens.ttGlyphPen import TTGlyphPen

UPEM = 1000
# A fixed head.created/modified, so the fonts are byte-identical on every run.
TIMESTAMP = 0x80000000
ORDER = [".notdef", "space", "H", "O", "D", "A", "plus", "equal", "circumflex", "uni0302"]
CMAP = {0x20: "space", ord("H"): "H", ord("O"): "O", ord("D"): "D", ord("A"): "A",
        ord("+"): "plus", ord("="): "equal", 0x02C6: "circumflex", 0x0302: "uni0302"}
ADVANCE = {".notdef": 500, "space": 250, "H": 600, "O": 600, "D": 700, "A": 600,
           "plus": 600, "equal": 600, "circumflex": 600, "uni0302": 0}
LSB = {".notdef": 0, "space": 0, "H": 50, "O": 50, "D": 50, "A": 50,
       "plus": 100, "equal": 100, "circumflex": 100, "uni0302": -450}


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
    elif name == "plus":
        rect(pen, 250, 100, 350, 500)
        rect(pen, 100, 250, 500, 350)
    elif name == "equal":
        rect(pen, 100, 200, 500, 280)
        rect(pen, 100, 420, 500, 500)
    elif name == "circumflex":
        rect(pen, 100, 0, 500, 100)
    elif name == "uni0302":
        rect(pen, -450, 750, -150, 850)


def common(fb, family):
    fb.setupGlyphOrder(ORDER)
    fb.setupCharacterMap(CMAP)
    fb.setupHorizontalMetrics({g: (ADVANCE[g], LSB[g]) for g in ORDER})
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({"familyName": family, "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200,
                sCapHeight=650, sxHeight=500, fsType=0)
    fb.setupPost()
    fb.updateHead(created=TIMESTAMP, modified=TIMESTAMP)


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


def fallback(path):
    order = [".notdef", "space", "H", "x"]
    advance = {".notdef": 500, "space": 250, "H": 500, "x": 400}
    fb = FontBuilder(UPEM, isTTF=True)
    glyphs = {}
    for g in order:
        pen = TTGlyphPen(None)
        rev = ReverseContourPen(pen)
        if g == "H":
            rect(rev, 50, 0, 450, 500)
        elif g == "x":
            rect(rev, 50, 0, 350, 300)
        glyphs[g] = pen.glyph()
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap({0x20: "space", ord("H"): "H", ord("x"): "x"})
    fb.setupHorizontalMetrics({g: (advance[g], 50 if g in ("H", "x") else 0) for g in order})
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({"familyName": "Graven Test Fallback", "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200,
                sCapHeight=500, sxHeight=300, fsType=0)
    fb.setupPost()
    fb.updateHead(created=TIMESTAMP, modified=TIMESTAMP)
    fb.setupGlyf(glyphs)
    fb.save(str(path))


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "lib/engine/testdata")
    out.mkdir(parents=True, exist_ok=True)
    truetype(out / "GravenTest-TT.ttf")
    cff(out / "GravenTest-CFF.otf")
    fallback(out / "GravenTest-Fallback.ttf")


if __name__ == "__main__":
    main()
