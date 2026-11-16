#!/usr/bin/env python3
"""Make the web-container test fixtures from the test fonts: each font as
WOFF (zlib) and WOFF2 (Brotli), so lib/font's container decoding can be
checked against the sfnt it came from.

Needs fontTools and brotli (pip install fonttools brotli). Run from the
repo root:
    tools/make-woff-fixtures.py lib/testdata

Made:
  GravenTest-TT.woff         TrueType outlines in WOFF 1.0
  GravenTest-CFF.woff        CFF outlines in WOFF 1.0
  GravenTest-TT.woff2        glyf/loca and hmtx transformed (WOFF2's own
                             glyph encoding and the reconstructed side
                             bearings both exercised)
  GravenTest-CFF.woff2       CFF, no transform
  GravenTest-TTC.woff2       a collection of GravenTest-TT and
                             GravenTest-Fallback (given the first's OS/2),
                             tables shared where equal
"""

import struct
import sys
from pathlib import Path

import brotli
from fontTools.ttLib import TTFont
from fontTools.ttLib.woff2 import compress as woff2_compress

out = Path(sys.argv[1] if len(sys.argv) > 1 else "lib/testdata")
tt = out / "GravenTest-TT.ttf"
cff = out / "GravenTest-CFF.otf"
fallback = out / "GravenTest-Fallback.ttf"


def woff1(src: Path, dst: Path) -> None:
    f = TTFont(src, recalcTimestamp=False, recalcBBoxes=False)
    f.flavor = "woff"
    f.save(dst, reorderTables=False)


woff1(tt, out / "GravenTest-TT.woff")
woff1(cff, out / "GravenTest-CFF.woff")
woff2_compress(str(tt), str(out / "GravenTest-TT.woff2"), transform_tables={"glyf", "loca", "hmtx"})
woff2_compress(str(cff), str(out / "GravenTest-CFF.woff2"))



# fontTools does not write WOFF2 collections: written here by the spec, every
# table untransformed (glyf and loca as transform version 3), a table two
# fonts hold byte for byte stored once.
def base128(n: int) -> bytes:
    out = [n & 0x7F]
    n >>= 7
    while n:
        out.append(0x80 | (n & 0x7F))
        n >>= 7
    return bytes(reversed(out))


def u255(n: int) -> bytes:
    assert n < 253
    return bytes([n])


def raw_tables(path: Path) -> dict:
    data = path.read_bytes()
    num = struct.unpack(">H", data[4:6])[0]
    tables = {}
    for i in range(num):
        tag, _, off, length = struct.unpack(">4sIII", data[12 + 16 * i : 28 + 16 * i])
        tables[tag] = data[off : off + length]
    return tables


fonts = [raw_tables(tt), raw_tables(fallback)]
# The two share no table as made; the second takes the first's OS/2 (metrics
# only, outlines untouched), so the collection has a table to share.
fonts[1][b"OS/2"] = fonts[0][b"OS/2"]
entries = []  # (tag, data), in stream order
index = {}  # (tag, data) -> entry number
per_font = []
for f in fonts:
    ids = []
    for tag in sorted(f):
        key = (tag, f[tag])
        if key not in index:
            index[key] = len(entries)
            entries.append(key)
        ids.append(index[key])
    per_font.append(ids)
directory = b""
for tag, data in entries:
    version = 3 if tag in (b"glyf", b"loca") else 0
    directory += bytes([63 | (version << 6)]) + tag + base128(len(data))
coll_dir = struct.pack(">I", 0x00020000) + u255(len(fonts))
for ids in per_font:
    coll_dir += u255(len(ids)) + struct.pack(">I", 0x00010000) + b"".join(u255(i) for i in ids)
stream = brotli.compress(b"".join(d for _, d in entries))
header_len = 48
total = header_len + len(directory) + len(coll_dir) + len(stream)
total += -total % 4
sfnt_size = 12 + 16 * sum(len(i) for i in per_font) + sum((len(d) + 3) & ~3 for _, d in entries)
header = struct.pack(
    ">4sIIHHIIHHIIIII", b"wOF2", 0x74746366, total, len(entries), 0, sfnt_size, len(stream), 1, 0, 0, 0, 0, 0, 0
)
woff2 = header + directory + coll_dir + stream
woff2 += b"\0" * (total - len(woff2))
(out / "GravenTest-TTC.woff2").write_bytes(woff2)
