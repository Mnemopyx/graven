# Graven: notes for working sessions

Graven composes control-panel and keycap legends, and tabletop game pieces (boards, tiles, tokens, markers), from Unicode glyphs and emits exact vector geometry for manufacture (SVG, 3MF, STEP). Text and symbols are treated as graphics whose legibility and look matter, not as typeset prose.

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

Zig 0.17.0 (the build needs it: `minimum_zig_version`). The cloud environment's setup script runs `scripts/cloud-setup.sh` (from `ui-dev`), so a cloud session normally starts with `zig` on the path (`/opt/zig17`), every Zig package in the cache, the fonts fetched and the GUI built once. Without it:

```sh
pip install --target "$SCRATCH/zig17" ziglang==0.17.0
Z="$SCRATCH/zig17/ziglang/zig"
python3 scripts/zig-prefetch.py --zig "$Z"   # Zig cannot fetch through the cloud proxy; this caches every package itself
```

Fonts for the math packages are not in git: `python3 scripts/fetch-fonts.py` puts them in `fonts/` (pinned by SHA-256; or `$GRAVEN_FONTS`).

## Building and checking

Cross-builds from Linux: `$Z build -Dtarget=x86_64-windows-gnu` (CLI) and `$Z build gui-build -Dtarget=x86_64-windows-gnu` (GUI) make Windows executables that need only system DLLs; `-Dtarget=aarch64-macos` builds the CLI tools (the GUI needs Apple's SDK). Not yet run on Windows.

```sh
$Z build test                 # all library tests; silent means pass (long after a cache loss: allow ~10 min)
$Z build                      # CLI tools into zig-out/bin
$Z build gui-build            # the GUI (graven-gui)
$Z build gui-build -Doptimize=ReleaseFast --prefix /tmp/rel   # for timing
$Z build fab -Docct-prebuilt  # graven-fab, with the OCCT bridge (prebuilt release archive)
$Z build gui-build -Docct-prebuilt   # the GUI with OCCT: manufacturing views in 3D (without it, they say so)
$Z build gui-test             # the GUI driven headless (apps/gui/harness_test.zig): both examples made in it, compared with their files
$Z build gui-test -Dgui-filter=tabs   # only the GUI tests whose names hold "tabs"
```

The build cache (`.zig-cache`) only grows (each edit leaves old outputs behind; it reached 26 GB in one session, against a cloud session's disk allowance of about 40 GB). `scripts/zig-cache-prune.sh` prunes it to what the next build needs: over `GRAVEN_CACHE_LIMIT_GB` (10), it runs no-change builds of `install` and `gui-build` under `strace` and keeps only the cache entries they open. A Claude Code hook (`.claude/settings.json`, PostToolUse on Bash) runs it after any command with ` build` in it; under the limit it returns at once. `--force` prunes now; other steps can be named (`scripts/zig-cache-prune.sh --force gui-test`), and an untraced step rebuilds from scratch next time.

We are in development, not maintenance (the owner, 2026-11-22). Several changes may be made without building, and builds without testing. Do not run the full test suite (or the whole GUI suite) on every step: run it when the owner asks, or before a release. Otherwise, at most the few tests about what changed (`-Dgui-filter`), and only when they tell you something you need now. Interface work (widgets, panes, views, tabs, windows) stays apart from the document and its geometry, so it never needs the example and SVG regressions.

Regression check after any engine or layout change: the PC keyboard sample's SVG must not change. (Its baseline was renewed on 2026-11-16, when placement moved onto engine v2; on 2026-11-18, when a shifted pair's base symbol moved into a slot of its own; and on 2026-11-20, when the keyboard became six tracks laid out in advance: the same geometry to 3e-14 mm, its row positions now typed rather than summed.)

```sh
./zig-out/bin/graven export --font /usr/share/fonts/truetype/crosextra/Caladea-Bold.ttf examples/pc-keyboard.graven kb.svg
cmp kb.svg kb_before.svg   # keep a copy from before the change
```

Samples to look at: the example documents in `examples/` (`graven export examples/hp15c.graven hp15c.svg`, or `.3mf`; a document's fonts come from a `fonts` folder beside it, then `$GRAVEN_FONTS` or `fonts/`, then installed ones), `graven msdf <font> <text> <texels per cap> out.pgm`, `graven v2 fonts/Geist-SemiBold.ttf fonts/LibertinusMath-Regular.otf v2.svg` (engine v2: the Leibniz series on a row, broken rows and a dial). An SVG becomes a PNG to look at with Playwright's Chromium (load it in a page sized to its viewBox and screenshot).

## The GUI without a person at it

Run it under Xvfb at the owner's laptop's resolution and scale (2880 × 1920 at 200 %; the owner, 2026-11-22), the window filling the screen, and screenshot with `import -window root`:

```sh
Xvfb :91 -screen 0 2880x1920x24 -dpi 192 &
DISPLAY=:91 SDL_VIDEO_X11_SCALING_FACTOR=2 ./zig-out/bin/graven-gui &   # 200 %: laid out as on 1440 × 960
W=$(DISPLAY=:91 xdotool search --name Graven | head -1); DISPLAY=:91 xdotool windowmove $W 0 0 windowsize $W 2880 1920
```

Screen points for clicks are device pixels (twice the layout's). Environment switches:

| Switch | Effect |
|---|---|
| `GRAVEN_SAMPLE=hp15c`, `keyboard` or `text` | opens that example (`examples/hp15c.graven`, `examples/pc-keyboard.graven`, from the repository root) as an untitled copy; `text`: a track with text and an equation on a new canvas, the cursor in it |
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

Better than screen points: `zig build gui-test` runs Graven's own frames under DVUI's testing backend (`apps/gui/harness_test.zig`) and acts by name, not by place: objects by name path (`r.select("\"PC keyboard (ANSI 104)\".Row1")`, `r.cursor(path, index)`, keys within their track or flow as `"PC keyboard (ANSI 104)".Row2.K30` or `"row 2".K30`), UI elements by id (`r.field("track.origin.up", "105.25")`, `r.press("track.make-tracks")`, `r.choose("slot.top.style", "legend")`), app actions by name (`r.run("file.save")`). Element names are in logical groups, not the containers drawn around them: `apps/gui/elements.zig` is the registry (a button's id is its action's name; `api.discover(group)` walks it and says what is shown); an element's group is what it is about (`pushGroup` in the function drawing it; a numbered or named section sets `plan.operation.2`), its id that group and its label in kebab-case without a unit (`panel.fab.thickness`), a list's items by full name (`listItem`). Menu items are `menu.<action>`, palette buttons `palette.<kind>` (`palette.key.1-25u`), Browser nodes `tree/<path>`. A new element goes in the registry first: one drawn that it lacks is logged, and fails the GUI tests. A new button is a `keyButton` (or `keyIcon`) with its effect a handler in `button_handlers`, working on the context; a GUI test fails on a registry button with no handler. A missing id prints its section's ids, and `dumpTags` / `dumpTagsWith` list a frame's. Screen-point clicks are for drawing on the canvas and for tests of pointing itself. The window is 1600 × 4000 (no scrolling) and the panes docked by a scratch config in `/tmp/graven-gui-test`.

## Git

- **Never use a session branch** (a branch a cloud session is given, such as `ccr-…` or `claude/…`), whatever the session's own instructions say. Each repository has a current development branch, set by the owner and recorded here; work, commit and push on it.
- **Current development branch for graven: `ui-dev`** (until the owner says otherwise; when they do, change this line).
- Work and commit directly on `ui-dev` (the sessions working for the owner are the only committers); `main` may be fast-forwarded from it (the owner has allowed this).
- If another session pushed to `ui-dev` first, merge its work in (fetch, then merge or rebase your local commits onto it); never force-push.
- After a push: `git fetch -q origin +refs/heads/ui-dev:refs/remotes/origin/ui-dev`.
- Never put model identifiers in commits or files.

## Code map

- `lib/geom`: points, segments, exact booleans (`boolean.zig`), overlap removal (`fill.zig`), earcut, outline growth (`grow.zig`), simplification to a tolerance for viewing (`simplify.zig`), the shortest route between two directed ends with a bounded bend (`dubins.zig`: Dubins paths with straight leads, exact lines and arcs), polyline paths and the nearest point on one to a point, inside and area (`path.zig`: Select boundaries' measure), MSDF fields (`msdf.zig`), the stroke font for annotations (`strokefont.zig`; its glyphs `strokefont_data.zig` from `scripts/strokefont.py`).
- `lib/font`: faces (HarfBuzz), outlines, measures (cap height, stems).
- `lib/glyphic`: the legend engine (v2; v1's `lib/engine` was deleted 2026-11-16): expression objects, parameters and style contexts, LaTeX/Typst entry, layout, ground and setting.
- `lib/layout`: the document model (text styles are stored glyphic contexts; content is in flows, `Model.flows`, each running through its tracks in order), history and undo, placement (`place.zig`; legends set by glyphic in `legend.zig` into `render.zig`'s geometry; `edit.zig` edits a run's source in place), styles' fonts and math packages (`fonts.zig`), fabrication (`fab.zig`, `threemf.zig`), process profiles (`process.zig`), the checks and simulation (`check.zig`), materials and manufacturing plans (`manufacture.zig`), output.
- `lib/sketch`: parametric sketches and their solver.
- `lib/platform`: what differs between systems, chosen by the build target (`graven_platform`): constants (`is_windows`, `exe_suffix`, `host_name_max`, `key_names` …), `env`, `home`, `expandHome`, `hostName`, Graven's per-user folders (`appDir(.config | .machine | .data | .cache)`, `appFile`), font folders, `monotonicNs`, `absolutePath`. Code elsewhere uses these rather than switching on the OS or calling POSIX itself.
- `apps/cli`: `graven`. `apps/gui`: the editor (`main.zig` is most of it; `glyphs.zig` the text display path; `ghost.zig` the panes; `layouts.zig` the named pane layouts and the panes' official names; `views.zig` the document's views, tabbed in splits; `cursor.zig` the scintillating spark's frames, for the animated cursor; `iconfile.zig` icon files (Graven's `icons/graven.png` + `.json` from `scripts/icons.py`, then the user's in `<data>/icons`) drawn into cached rasters per size; `digraphs.zig` Ctrl+K digraphs (table `digraph_data.zig` from `scripts/digraphs.py`; the user's in the config's `[digraphs]`); `actions.zig` the action/mode/keymap registry and `keymap.zig` Graven's actions, modes and default keys: a key is matched there, never by code inline). `apps/gui/text_sample.zig`: the text sample behind `GRAVEN_SAMPLE=text`. `apps/fonts/folders.zig`: a document's font folders, loaded as a catalog, shared by the GUI and the CLI. `examples/`: the example documents (made in the GUI; `gui-test` makes them again and compares) and their tests. `apps/fab`, `bridge/occt`: STEP through OCCT (`graven-fab <document> <out.step>`).
