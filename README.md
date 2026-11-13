# Graven

Graven composes control-panel and keycap legends from Unicode glyphs and emits exact planar vector geometry, ready for manufacture.

Legends on a panel are recognised as pictures more than read, so Graven treats each label as an icon: spacing follows the ink, styles are inherited so many legends change at once, and production output passes design-rule checks (DRC) for the process that will make it.

- **First application:** HP-15C keypad legends.
- **Final goal:** aircraft control-panel legends, set and checked against specification.
- **Outputs:** SVG, and STEP (with colours and names) through an OCCT bridge.
- **Processes, in order:** colour FDM 3D printing, PCB legends, dye sublimation.

The full design is in the [Graven design blueprint](https://claude.ai/artifact/QGhg35uPYQE2q4crhg2uFQ).

## Status

Early, with a working editor. For the full inventory, what is agreed but not built, and the gaps against the goals above, see [docs/status.md](docs/status.md).

**Label engine.**
- KaTeX-style label markup (`graven parse`), rendered in a style context (`graven label`).
- HarfBuzz shaping and exact glyph outlines (lines, quadratics, cubics).
- Scripts, `\frac`, `\sqrt`, accents, and TeX atom-class spacing.
- Bold, italic and math-alphabet variants, plus underline and strikethrough.
- Neighbours and scripts placed by their ink.
- Line breaks at spaces, `\allowbreak` and soft hyphens. A word too long for its line is cut to wrap.

**Layout library.**
- **Canvas:** in mm, inches or mils, with frames, views, layers, images and groups.
- **Panels:** with margins and compliance checks, made from closed paths with cutouts.
- **Tiles:** made from tile prototypes.
- **Tracks:**
  - rows or columns along a path, with one flow each of tiles, text, equations, breaks and paragraphs;
  - tracks can be threaded so one flow runs through several, across panels too.
- **Constraints:** parametric constraints between object features, solved per axis.
- **RTF import:** RTF text can be imported into a flow.

**GUI editor (DVUI and SDL3).**
- Opens on a canvas, with overlay panes for the tree, tools and properties.
- Text and equations are edited in place in flows, like a word processor:
  - Ctrl+\ starts equation mode, which builds an equation in the expression line;
  - Tab steps through an equation's slots.
- **Selection and moving:** Ctrl-click selects. Moves and resizes stay within constraints.
- **Background reflow:** changes that spread across pages reflow on a worker thread.
- **Export:** File › Export SVG writes the canvas.

**Documents.**
- `.graven` files keep their undo history across saves.
- Unsaved work is autosaved and offered back after a crash.
- A file changed by another session is never written over without asking.
- `graven dump` prints a document as text, and `graven compact` drops its history.

**Fonts.**
- `graven-fonts` and the editor's Fonts window index, search and compare installed fonts and build composed fonts.

**Not yet built.**
- **STEP output:** the OCCT bridge is a tested shim that nothing calls yet.
- **Design-rule checks and per-process output:** not started.
- **Proof sheet:** not started.
- **HP-15C sample:** not started. The PC keyboard is the only sample, and its output is the regression check.

## Layout

| Path | What |
| --- | --- |
| `lib/geom` | Planar geometry: points, affine transforms, segments (line, quad, cubic), contours, exact areas and bounds; `spring`, the 1-D tension solver |
| `lib/font` | Font library: a thin Zig layer over HarfBuzz (faces from bytes, outlines in font units, measured metrics) |
| `lib/engine` | Label engine: renders content into placed items, with outlines expanded only on request |
| `lib/layout` | Layout library: `model` (panels, tracks and their flows, tile prototypes, tiles, slots, actions), `art` (tile art drawn at 1u and stretched), `place` (the flow pass, solve and label cache), `output` (SVG so far); `geometry` and `drc` to come |
| `apps/gui` | GUI editor on DVUI over SDL3 |
| `docs` | Project notes: [status.md](docs/status.md), what exists today and what is still to come |
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
