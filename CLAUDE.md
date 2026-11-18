# Graven: notes for working sessions

Graven composes control-panel and keycap legends from Unicode glyphs and emits exact vector geometry for manufacture (SVG, 3MF, STEP). Text and symbols are treated as graphics whose legibility and look matter, not as typeset prose.

## Where things are written down

- **Design blueprint** (the record of every decision and every built stage): Claude Doc in project `bc736950-0461-4874-ab75-1255551cc7eb`, node `1d9e376a-fcde`, https://claude.ai/artifact/QGhg35uPYQE2q4crhg2uFQ. New sections go at the end; record decisions as they are made and stages as they are built.
- **[docs/status.md](docs/status.md):** what exists, what is agreed but not built, gaps, to-do lists, housekeeping.
- **[docs/ui-inventory.md](docs/ui-inventory.md):** the GUI as it stands, surface by surface, with the inconsistencies seen so far: the starting point for UI design work.
- **[docs/handoff.md](docs/handoff.md):** the state of every open thread at the last session's end, and what each next step is.
- **README.md:** the project in brief.

## Working with the owner

- Pick sensible defaults, say what they are, and build; do not ask question after question.
- Flag problems rather than refuse.
- Single keys with no modifiers are preferred for commands.
- Near-real-time performance is expected; measure (release build) before claiming speed.
- Record decisions and built stages in the blueprint and `docs/status.md` as you go.
- Show work visually: render, screenshot, compare against exact outlines.

## Toolchain

Zig 0.17.0 (the build needs it: `minimum_zig_version`). In a cloud session without it:

```sh
pip install --target "$SCRATCH/zig17" ziglang==0.17.0
Z="$SCRATCH/zig17/ziglang/zig"
```

Fonts for the math packages are not in git: `python3 scripts/fetch-fonts.py` puts them in `fonts/` (pinned by SHA-256; or `$GRAVEN_FONTS`).

## Building and checking

```sh
$Z build test                 # all library tests; silent means pass (long after a cache loss: allow ~10 min)
$Z build                      # CLI tools into zig-out/bin
$Z build gui-build            # the GUI (graven-gui)
$Z build gui-build -Doptimize=ReleaseFast --prefix /tmp/rel   # for timing
$Z build fab -Docct-prebuilt  # graven-fab, with the OCCT bridge (prebuilt release archive)
```

Regression check after any engine or layout change: the PC keyboard sample's SVG must not change. (Its baseline was renewed on 2026-11-16, when placement moved onto engine v2, and on 2026-11-18, when a shifted pair's base symbol moved into a slot of its own.)

```sh
./zig-out/bin/graven keyboard /usr/share/fonts/truetype/crosextra/Caladea-Bold.ttf kb.svg
cmp kb.svg kb_before.svg   # keep a copy from before the change
```

Samples to look at: `graven hp15c libertinus plate.svg keys.svg` (or `stix-two`), `graven 3mf hp15c libertinus plate.3mf keys.3mf`, `graven msdf <font> <text> <texels per cap> out.pgm`, `graven v2 fonts/Geist-SemiBold.ttf fonts/LibertinusMath-Regular.otf v2.svg` (engine v2: the Leibniz series on a row, broken rows and a dial). An SVG becomes a PNG to look at with Playwright's Chromium (load it in a page sized to its viewBox and screenshot).

## The GUI without a person at it

Run it under Xvfb (`Xvfb :91 -screen 0 1600x1000x24 &`, then `DISPLAY=:91`), screenshot with `import -window root`. The window lands at (50, 90) on a 1600 x 1000 screen. Environment switches:

| Switch | Effect |
|---|---|
| `GRAVEN_SAMPLE=hp15c`, `keyboard` or `text` | opens on a new canvas with that sample (`text`: a track with text and an equation, the cursor in it) |
| `GRAVEN_VIEW=cx,cy,ppm` | view centre (mm) and zoom (px/mm) |
| `GRAVEN_EXACT_TEXT=1` | text from outlines instead of the glyph atlas |
| `GRAVEN_TEXT_GAMMA`, `GRAVEN_TEXT_DARKEN` | display gamma (2.2), stem darkening (0) |
| `GRAVEN_FIELDS_INLINE=1` | glyph fields made on the drawing thread |
| `GRAVEN_FRAME_LOG=1` | each frame's time printed |
| `GRAVEN_DUMP_OUTLINES=file.svg` | exact glyph outlines in window pixels, for `scripts/text-overlay.py` |
| `GRAVEN_FONTS_WINDOW=1` | the Fonts window opens at start |
| `GRAVEN_DISPLAY=gamma,white` | display correction for the run (e.g. `1.5,0.85`) |
| `GRAVEN_KEY_LOG=1` | each action a key asks for printed, with the active modes |
| `GRAVEN_DRAWN_SPARK=1` | a point standing in for the pointer is drawn on the canvas (25 frames a second), not made the animated cursor |

`graven-gui file.graven` opens a document. `scripts/xclick.py x,y [x,y …]` clicks at screen points (XTest), to drive it.

## Git

- Work and commit directly on `ui-dev` (the sessions working for the owner are the only committers); `main` may be fast-forwarded from it (the owner has allowed this).
- If another session pushed to `ui-dev` first, merge its work in (fetch, then merge or rebase your local commits onto it); never force-push.
- After a push: `git fetch -q origin +refs/heads/ui-dev:refs/remotes/origin/ui-dev`.
- Never put model identifiers in commits or files.

## Code map

- `lib/geom`: points, segments, exact booleans (`boolean.zig`), overlap removal (`fill.zig`), earcut, outline growth (`grow.zig`), MSDF fields (`msdf.zig`), the stroke font for annotations (`strokefont.zig`; its glyphs `strokefont_data.zig` from `scripts/strokefont.py`).
- `lib/font`: faces (HarfBuzz), outlines, measures (cap height, stems).
- `lib/glyphic`: the legend engine (v2; v1's `lib/engine` was deleted 2026-11-16): expression objects, parameters and style contexts, LaTeX/Typst entry, layout, ground and setting.
- `lib/layout`: the document model (text styles are stored glyphic contexts; content is in flows, `Model.flows`, each running through its tracks in order), history and undo, placement (`place.zig`; legends set by glyphic in `legend.zig` into `render.zig`'s geometry; `edit.zig` edits a run's source in place), styles' fonts and math packages (`fonts.zig`), fabrication (`fab.zig`, `threemf.zig`), output.
- `lib/sketch`: parametric sketches and their solver.
- `apps/cli`: `graven`. `apps/gui`: the editor (`main.zig` is most of it; `glyphs.zig` the text display path; `ghost.zig` the panes; `layouts.zig` the named pane layouts and the panes' official names; `views.zig` the document's views, tabbed in splits; `cursor.zig` the scintillating spark's frames, for the animated cursor; `digraphs.zig` Ctrl+K digraphs (table `digraph_data.zig` from `scripts/digraphs.py`; the user's in the config's `[digraphs]`); `actions.zig` the action/mode/keymap registry and `keymap.zig` Graven's actions, modes and default keys: a key is matched there, never by code inline). `apps/samples`: PC keyboard, HP-15C. `apps/fab`, `bridge/occt`: STEP through OCCT.
