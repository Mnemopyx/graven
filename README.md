# Graven

Graven composes control-panel and keycap legends from Unicode glyphs and emits exact planar vector geometry, ready for manufacture.

Legends on a panel are recognised as pictures more than read, so Graven treats each label as an icon: spacing follows the ink, styles are inherited so many legends change at once, and production output passes design-rule checks (DRC) for the process that will make it.

- **First application:** HP-15C keypad legends.
- **Final goal:** aircraft control-panel legends, set and checked against specification.
- **Outputs:** SVG, and STEP (with colours and names) through an OCCT bridge.
- **Processes, in order:** colour FDM 3D printing, PCB legends, dye sublimation.

The full design is in the [Graven design blueprint](https://claude.ai/artifact/QGhg35uPYQE2q4crhg2uFQ).

## Status

Early. The label engine renders a plain run of text in one face: HarfBuzz shaping, glyph outlines (lines, native quadratics, cubics), cap height measured from outlines, the baseline anchor, and SVG output. The markup parser turns KaTeX-style label markup into a neutral tree (`graven parse`), and `graven label` renders it in a style context: upright and italic faces with a fallback chain matched by cap height, superscripts and subscripts (settings from the font's `MATH` table when it has one), accents (`\hat`, `\bar`, `\overline`), math spaces, and space between operators by TeX's atom classes with amounts from the style. Breaks, contact profiles and the hard box come next. The OCCT bridge is a tested starting point.

## Layout

| Path | What |
| --- | --- |
| `lib/geom` | Planar geometry: points, affine transforms, segments (line, quad, cubic), contours, exact areas and bounds |
| `lib/font` | Font library: a thin Zig layer over HarfBuzz (faces from bytes, outlines in font units, measured metrics) |
| `lib/engine` | Label engine: renders content into placed items, with outlines expanded only on request |
| `lib/layout` | Layout library: `layout`, `geometry`, `drc`, `output` (SVG so far) |
| `lib/testdata` | Test fonts with known glyph areas, made by `tools/make-test-fonts.py` |
| `apps/cli` | `graven` command-line tool |
| `bridge/occt` | Optional OCCT bridge: a C shim over OCCT that writes STEP with XDE names and colours |
| `scripts/build-occt.sh` | Builds a minimal static OCCT 8.0.1 with `zig c++` |

Planned applications not yet started: the GUI editor and the proof sheet. Libraries never touch the file system or console; applications do.

## Building

Requires Zig 0.17.0.

```sh
zig build            # builds the graven CLI
zig build test       # library tests
zig build run -- svg <font file> "<text>" <cap mm> out.svg   # one run of text as SVG
zig build run -- parse 'x_i^2'                                  # label markup as a tree
zig build run -- label <upright> <italic|-> <cap mm> 'x_i^2' out.svg [fallback ...]   # a rendered label
```

HarfBuzz 15.1.0 is fetched by `zig build` (pinned in `build.zig.zon`) and built from its amalgamated source with `zig c++`, so no system HarfBuzz is needed.

### OCCT bridge (optional)

The bridge needs OCCT built with the same C++ runtime as Zig (libc++), so build it with `zig c++`:

```sh
scripts/build-occt.sh /opt/occt-8.0.1-zig     # about 17 minutes on 4 cores
zig build occt-test -Docct=/opt/occt-8.0.1-zig
```

The script needs git, cmake and ninja. It applies one patch to OCCT: removing `stdc++` from `CSF_ThreadLibs` in `adm/cmake/occt_csf.cmake`, so GCC's libstdc++ is not linked beside libc++.

The bridge test builds planar faces from line, quadratic and cubic edges (one with a hole), checks their areas against exact values, checks that a zero-length edge is rejected, and writes `legend_test.step`.

Notes for bridge code:

- Zig 0.17 has no `@cImport`; `build.zig` translates the shim header with `addTranslateC`.
- Every shim function catches OCCT and C++ exceptions and returns an error code.
- Write the shim in OCCT 8 style (`NCollection_Array1<gp_Pnt>`, `true`/`false`); deprecated typedefs fail under Zig's default flags.
- XDE stores colours as 32-bit floats.
