# Graven

Graven composes control-panel and keycap legends from Unicode glyphs and emits exact planar vector geometry, ready for manufacture.

Legends on a panel are recognised as pictures more than read, so Graven treats each label as an icon: spacing follows the ink, styles are inherited so many legends change at once, and production output passes design-rule checks (DRC) for the process that will make it.

- **First application:** HP-15C keypad legends.
- **Final goal:** aircraft control-panel legends, set and checked against specification.
- **Outputs:** SVG, and STEP (with colours and names) through an OCCT bridge.
- **Processes, in order:** colour FDM 3D printing, PCB legends, dye sublimation.

The full design is in the [Graven design blueprint](https://claude.ai/artifact/QGhg35uPYQE2q4crhg2uFQ).

## Status

Early. The label engine renders a plain run of text in one face: HarfBuzz shaping, glyph outlines (lines, native quadratics, cubics), cap height measured from outlines, the baseline anchor, and SVG output. The markup parser turns KaTeX-style label markup into a neutral tree (`graven parse`), and `graven label` renders it in a style context: upright and italic faces with a fallback chain matched by cap height, superscripts and subscripts (settings from the font's `MATH` table when it has one), accents (`\hat`, `\bar`, `\overline`), math spaces, and space between operators by TeX's atom classes with amounts from the style. Neighbours and scripts are placed by their ink, through contact profiles (`--advance` places them by the fonts' advances instead). Lines break at `\\` and, within a hard box width, at spaces and `\allowbreak` (never at `~`); each line is aligned by the anchor, the block is moved inside the box when it fits, and anything that cannot fit overflows with a diagnostic instead of shrinking. The layout library has a first tile model (panels, and tracks: one flow of tiles made from tile prototypes (blanks are tiles of a built-in spacer prototype), runs of text or equations and hard breaks, poured through rows or columns; slots on the tiles) changed through action functions, with labels rendered through a cache that identical legends share. A GUI editor on DVUI and SDL3 opens on a canvas in the units you choose (mm, inches or mils), with no sheet or panel needed: typing makes a label, tracks and line art are drawn straight onto it, and File › Export SVG writes what it holds. Documents save as `.graven` files that keep their undo history, so undo reaches back past a save after reopening; unsaved work is autosaved into the file every few minutes and offered back after a crash, and a file changed by another session is never written over without asking. `graven dump` prints a document as text (usable as git's text converter) and `graven compact` drops its history. A separate tool, `graven-fonts`, indexes installed fonts (measuring their proportions from outlines and reading their stated licence and embedding terms) and searches them: by name, by likeness to another font, by the characters they must cover, and by style, math support, embedding permission or licence. In the editor, Text › Fonts… opens the same search in a window of its own, with side-by-side and glyph-by-glyph overlay comparison, and builds the document's composed fonts from what is chosen there; the canvas renders with them. Panels, the sample PC keyboard, live legend editing and stepping through installed fonts work as before. Features are built in the order real workflows need them. The OCCT bridge is a tested starting point.

## Layout

| Path | What |
| --- | --- |
| `lib/geom` | Planar geometry: points, affine transforms, segments (line, quad, cubic), contours, exact areas and bounds; `spring`, the 1-D tension solver |
| `lib/font` | Font library: a thin Zig layer over HarfBuzz (faces from bytes, outlines in font units, measured metrics) |
| `lib/engine` | Label engine: renders content into placed items, with outlines expanded only on request |
| `lib/layout` | Layout library: `model` (panels, tracks and their flows, tile prototypes, tiles, slots, actions), `art` (tile art drawn at 1u and stretched), `place` (the flow pass, solve and label cache), `output` (SVG so far); `geometry` and `drc` to come |
| `apps/gui` | GUI editor on DVUI over SDL3 |
| `examples` | Inputs for trying Graven: an OFL-licensed legend font (see `examples/README.md`) |
| `apps/samples` | Sample models built through the library actions (PC keyboard) |
| `lib/testdata` | Test fonts with known glyph areas, made by `tools/make-test-fonts.py` |
| `apps/cli` | `graven` command-line tool |
| `bridge/occt` | Optional OCCT bridge: a C shim over OCCT that writes STEP with XDE names and colours |
| `scripts/build-occt.sh` | Builds a minimal static OCCT 8.0.1 with `zig c++` |

Planned application not yet started: the proof sheet. Libraries never touch the file system or console; applications do.

## Building

Requires Zig 0.17.0.

```sh
zig build            # builds the graven CLI
zig build test       # library tests
zig build run -- svg <font file> "<text>" <cap mm> out.svg   # one run of text as SVG
zig build run -- parse 'x_i^2'                                  # label markup as a tree
zig build run -- label <upright> <italic|-> <cap mm> 'x_i^2' out.svg [fallback ...]   # a rendered label
zig build run -- keyboard examples/fonts/Inter-Medium.otf out.svg                 # the sample PC keyboard
zig build gui        # builds and runs the GUI editor (fetches DVUI and SDL3 on first use)
zig build run -- label --width 12 --centre <upright> - 3 'CAPS LOCK' out.svg         # wrapped in a 12 mm box
```

HarfBuzz 15.1.0 is fetched by `zig build` (pinned in `build.zig.zon`) and built from its amalgamated source with `zig c++`, so no system HarfBuzz is needed.

The GUI needs an X11 or Wayland display. DVUI is pre-1.0, so it is pinned to a commit in `build.zig.zon` as a lazy dependency: plain `zig build` and `zig build test` never fetch it.

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
