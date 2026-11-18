#!/usr/bin/env python3
"""Builds Graven Sans, the interface's font for text fields and table cells.

    pip install fonttools
    python3 scripts/uifont.py Inter.ttf NotoSansMath-Regular.ttf apps/gui/uifont/GravenSans.ttf

Inter (variable: optical size and weight; designed for interfaces at small
sizes) with the symbols it lacks that legends use (operators, relations,
arrows, sets, number sets, brackets) taken from Noto Sans Math, scaled to
Inter's units. The added glyphs do not vary with weight. Both fonts are
under the SIL Open Font License 1.1, and so is the result; it is renamed,
as the licence asks of a modified font.

Inputs (google/fonts, ofl/): `inter/Inter[opsz,wght].ttf` and
`notosansmath/NotoSansMath-Regular.ttf`; their SHA-256 are printed, for
the record in apps/gui/uifont/README.md.
"""
import hashlib
import sys

from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont

FAMILY = "Graven Sans"
PS_NAME = "GravenSans"


def wanted():
    """The codepoints fields should show: Greek, the operators, relations,
    arrows, sets and brackets legends use, super- and subscripts, and the
    blocks they come from."""
    cps = set()
    for lo, hi in [(0x0391, 0x03A9), (0x03B1, 0x03C9), (0x2070, 0x209F), (0x2100, 0x214F),
                   (0x2190, 0x21FF), (0x2200, 0x22FF), (0x2300, 0x23FF), (0x27E8, 0x27EB), (0x25A0, 0x25FF)]:
        cps.update(range(lo, hi + 1))
    return cps


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    inter_path, math_path, out_path = sys.argv[1:]
    for p in (inter_path, math_path):
        print(hashlib.sha256(open(p, "rb").read()).hexdigest(), p)
    f = TTFont(inter_path)
    # Every table read now, before the glyph count changes.
    f.ensureDecompiled()
    m = TTFont(math_path)
    fcm = f.getBestCmap()
    mcm = m.getBestCmap()
    scale = f["head"].unitsPerEm / m["head"].unitsPerEm
    mglyphs = m.getGlyphSet()
    order = list(f.getGlyphOrder())
    glyf = f["glyf"]
    hmtx = f["hmtx"]
    added = {}
    for cp in sorted(wanted()):
        if cp in fcm or cp not in mcm:
            continue
        name = "gs.uni%04X" % cp
        pen = TTGlyphPen(None)
        # Decomposed and scaled into Inter's units.
        rec = DecomposingRecordingPen(mglyphs)
        mglyphs[mcm[cp]].draw(rec)
        rec.replay(TransformPen(pen, (scale, 0, 0, scale, 0, 0)))
        g = pen.glyph()
        g.recalcBounds(glyf)
        glyf[name] = g
        adv = round(m["hmtx"][mcm[cp]][0] * scale)
        hmtx[name] = (adv, getattr(g, "xMin", 0))
        order.append(name)
        added[cp] = name
    f.setGlyphOrder(order)
    glyf.glyphOrder = order
    # The new glyphs do not vary: no deltas in gvar; HVAR maps advances by
    # glyph index and has none for them, so it goes (advances then come
    # from gvar's phantom points).
    if "gvar" in f:
        for name in added.values():
            f["gvar"].variations[name] = []
    for t in ("HVAR", "VVAR"):
        if t in f:
            del f[t]
    for sub in f["cmap"].tables:
        if sub.isUnicode():
            for cp, name in added.items():
                if sub.format == 4 and cp > 0xFFFF:
                    continue
                sub.cmap[cp] = name
    # Renamed, as the OFL asks of a modified font; its notices kept.
    name = f["name"]
    old_family = name.getDebugName(16) or name.getDebugName(1)
    for rec in list(name.names):
        if rec.nameID in (1, 16):
            rec.string = FAMILY
        elif rec.nameID == 4:
            rec.string = str(rec.toUnicode()).replace(old_family, FAMILY)
        elif rec.nameID == 6 or rec.nameID == 25:
            rec.string = str(rec.toUnicode()).replace(old_family.replace(" ", ""), PS_NAME)
        elif rec.nameID == 3:
            rec.string = PS_NAME + ";" + str(rec.toUnicode())
        elif rec.nameID == 0:
            rec.string = str(rec.toUnicode()) + " Mathematical symbols from Noto Sans Math, copyright 2022 The Noto Project Authors."
    if "CFF " in f:
        sys.exit("expected TrueType outlines")
    f.save(out_path)
    print(f"{len(added)} glyphs added from {math_path}; written {out_path}")


if __name__ == "__main__":
    main()
