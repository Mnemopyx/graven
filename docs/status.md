# Graven status

Taken on 13 November 2026, on branch `ui-dev`. This list comes from the commit history, the code layout and recent work. Not every feature was re-checked in the app for it.

Graven has about 32,000 lines of Zig and 209 tests. It has 127 commits since 4 November 2026, and 81 of them are on `ui-dev` and not yet on `main`.

## What exists

### Label engine (`lib/engine`, `lib/font`, `lib/geom`)

- **Shaping and outlines:** HarfBuzz shaping. Glyph outlines are kept exact (lines, quadratics and cubics), and cap height is measured from the outlines.
- **Markup:** KaTeX-style label markup with a strict parse and a lenient preview parse. Text in a track with `$…$` is text with math between the dollars, as in KaTeX: math's letters are variables (italic; from a math font package's face for variables), words in it `\mathrm`; scripts belong in math. Track text without dollars is all one markup, as before.
- **Math font packages:** `stix-two` (Geist SemiBold text, STIX Two Math for constants and symbols, STIX Two Text Bold Greek, TeX Gyre Schola Bold Italic variables), fetched by `scripts/fetch-fonts.py`; `graven hp15c stix-two …` sets the keypad in it.
- **Member weight:** a composed font's member can be drawn heavier: `.match` (its stem of I, relative to cap height as drawn, grown to the main face's), a stroke increase in thousandths of cap height, or none. Its glyphs are grown outward by half the increase all round (`geom.grow`: the region's Minkowski sum with a disc, convex corners rounded, counters shrinking) and spaced by it. The STIX Two package matches STIX Two Math's symbols to Geist SemiBold (0.138 to 0.183 of cap height).
- **Libertinus package:** `libertinus` (chosen for the HP-15C keypad): Geist SemiBold text; Libertinus Math 7.051 for operators and arrows (+ < = > ± × ÷ −, the Arrows and Mathematical Operators blocks), bold Greek from the mathematical bold block (a composed font's `greek` setting maps Δ Σ π to U+1D6A8..), math-italic variables (U+1D434..; with no member for variables, math's letters become those), and the MATH constants. `graven hp15c libertinus …`.
- **Matching by stroke:** a member's weight match names a reference stroke: an I's stem for letters, the minus sign's bar for operators (math fonts draw operators thinner than their letters), the member's own bold or italic I for those letters. Growth follows the member that set each character, so one face can carry several. Bold Greek is left as drawn: growing it fills the acute corners where Libertinus's hairlines meet its thick strokes.
- **Drawn arrows:** a style's `arrows` draws → ← ↑ ↓ and ⇄ instead of taking them from a face, as on the HP keypad: a solid triangular head pointed well under a right angle (0.45 cap long, 0.5 wide), a short shaft as heavy as the text's stem of I. ⇄ is two heads alone, right over left, each notched at the back where a shaft would go in. The HP-15C sample turns them on.
  - Superscripts and subscripts, `\frac`, `\sqrt`, accents and math spaces.
  - TeX atom-class spacing.
  - Variants: bold, italic and math alphabets.
  - Underline, strikethrough, and text superscripts and subscripts.
- **Spacing by ink:** neighbours and scripts are placed by their ink, using contact profiles.
- **Line breaking:** breaks within a box, at spaces, `\allowbreak` and soft hyphens, and forced cuts inside words that are too long for their line.
- **Spring-chain solver** for anchoring labels.

### Fonts (`lib/fontsearch`, `apps/fonts`)

- Composed fonts, with members and fallback, a math face for the MATH constants, and members for variables. Math font packages (first: STIX Two, fetched by `scripts/fetch-fonts.py`) make them; `graven hp15c stix-two` sets the keypad in it.
- Font search with the `graven-fonts` tool, by name, likeness, character coverage, style, math support, embedding permission and licence.
- The Fonts window: search, side-by-side and overlay comparison, and composition.
- Style sizes are given in points.
- **Web containers:** WOFF and WOFF2 are read wherever a font is (`lib/font/container.zig`; `Face.init` unwraps them, so indexing and labels take them too). WOFF is unwrapped table by table (zlib); WOFF2 decoded (Brotli 1.1.0's C decoder, pinned; the `glyf`/`loca` and `hmtx` transforms reversed; collections, shared tables once). `graven-fonts convert FILE... [--to FOLDER]` stores a font as a plain `.ttf`, `.otf`, `.ttc` or `.otc`, named by its outlines (never converted between kinds). Checked against fontTools on 33 fonts (system fonts and the math packages): every WOFF came back byte-identical, every WOFF2 with the same tables and all 51,786 glyphs point for point. Graven does not write WOFF or WOFF2.

### Layout model (`lib/layout`)

- **Canvas:** units of mm, inches or mils, with an optional sheet.
- **Spaces and frames:** frames are spaces of their own. Views place one space inside another.
- **Structure:** layers, images, groups, and object IDs that last.
- **Panels:** margins and compliance checks. Panels can be made from closed paths and can have cutouts.
- **Tiles:** tile prototypes with tracks on their faces (rows, or columns set a character at a time), sizing rules, art drawn at 1u and stretched, and their own unit.
- **Tracks:**
  - rows or columns along a path with control points, where segments step by pitch and are bound to the path at their centre;
  - the path and segment length define the track's boundary;
  - threaded tracks, where one flow runs through joined tracks, including across panels.
- **Flows:**
  - tiles, blanks, text and equations in one stream;
  - hard breaks and paragraphs with paragraph styles (spacing, alignment, indents);
  - groups that break as one;
  - flowing around line art and tall tiles.
- **Constraints:** object origins and features, solved per axis. Constraints can apply to track path control points. Moving and resizing only use the freedom constraints leave.
- **Line art** on panels.
- **RTF import** into a flow.

### Documents and undo

- The native `.graven` format: a checkpoint codec plus an operation log. Undo history is kept in the file, so undo works after reopening.
- Autosave, crash recovery, and protection when another session has written the file.
- History limits, plus the `graven dump` and `graven compact` commands.

### GUI editor (`apps/gui`, about 12,000 lines)

- **Window and panes:** a DVUI/SDL3 app with its own title bar. The tree, tools and properties are see-through overlay panes. It matches the desktop theme.
- **Canvas:** rulers in the document's units.
- **Expression line:** brace pairing, command completion, a live preview and a cursor drawn in the rendered label.
- **Flow editing like a word processor:**
  - a character cursor moved with dvui's text-field keys, and Shift to select;
  - typing, Backspace and Delete, cut, copy and paste;
  - Enter for a new paragraph, Shift+Enter for a line break;
  - equation mode with Ctrl+\\, and Tab through an equation's slots;
  - soft-hyphen breaks and forced wraps, with faint marks while editing.
- **Selection and moving:** Ctrl-click selection with Tab to hunt for the next-nearest object. Drag to move, with handles to resize. The pointer shows a hand or a lock. Objects can be moved or copied into frames.
- **Constraint editor:** the Constrain tool, glyphs and an origin picker.
- **Background reflow:** changes that spread across pages reflow on a worker thread, in batches.
- **Settings:** shared and local TOML config, and locale detection for language and measurement system.

### Output and command line

- SVG export from the GUI, and from the `graven` CLI: `svg`, `label`, `parse`, `keyboard`, `rtf`, `dump`, `compact`.
- The PC keyboard sample. Its output is the regression check run after each change.
- Colour 3D printing: a part's stack of layer operations (Panel.fab: add, subtract, inlay; from the base's surfaces, up or down) is resolved into slabs of exact 2D colour regions (layout.fab), then written as 3MF (`graven 3mf hp15c`, under a second for both HP-15C parts: closed meshes, one per colour (the union of its bands) or per colour and band, standing on the part's bottom or turned over onto its top; earcut faces, colours as materials) or, through OCCT, as STEP (`graven-fab`, slower: exact text is about a million STEP entities per part). Not yet: Manufacture mode in the GUI, manufacturing rules beyond the layer-height flag, slicer-specific filament assignment.

## Agreed but not built

1. Paragraph styles for headings (size, weight, rules above and below). This is the likely next item.
2. Grids, next steps: refining the HP-15C sample with real measurements, and a polar grid. Built: hole and part shapes from sketches: a stamp draws its instances from a sketch by ID, live, solved for each instance's box (its `w` and `h` set from the box, other parameters per stamp), with four ready-made, fully constrained sketches (circle, rectangle, rounded rectangle, slot) made in the document's sketches when first chosen. A panel's body (placement's `Placed.body`, drawn on the canvas and exported) is its edge with its cutouts and holes cut out exactly (lib/geom/boolean.zig, arcs kept as arcs): a hole across the edge leaves a notch (not flagged; notches are normal), overlapping holes cut their union. Not yet: a sketch that solves into an inverted shape (a corner radius over half the side) is not caught; Also built: a rough HP-15C keypad sample (11.43 mm across; its holes the rounded-rectangle sketch, r 1 mm),  a panel editing mode that places and spans instances by clicking and dragging on a grid, Cartesian grids on panels with stamps (prototype instances as parts, holes or legends) bound to their points, grids that follow another part's grid, and panels from sketches: sketches have their own tree category, a sketch on a canvas or frame is a view of it, and an enclosed sketch view can be made a panel, cut by nesting.
3. Moves into frames that drop constraints to the original frame and to objects left behind.
4. The discussion of text and tile entry principles.
5. Compose-key and digraph Unicode entry.
6. The tile palette returning together with the Unicode character palettes.
7. Dictionary hyphenation.

## Gaps against the project's stated goals

The README sets the goals: HP-15C keypad legends first, aircraft panels last, SVG and STEP output, and checked production output.

- **Design-rule checks and per-process output:** beyond margins and the layer-height flag, not started. Gerber and mirrored output for other processes are not started.
- **Manufacture mode in the GUI:** not started; 3MF and STEP come from the command line.
- **Proof sheet:** not started.
- **HP-15C sample:** a rough keypad exists (from memory and guesses; key size given); real measurements and EverCalc's legend list are still to come.

## Housekeeping

- **Known limitations:**
  - an unsaved-change log written before free labels were removed has not been tested for recovery;
  - the drawn hyphen ignores the word's bold or italic;
  - forced wraps and hyphen breaks work in rows only, not in columns;
  - copying text keeps no formatting.
- **`main` was fast-forwarded to `ui-dev` on 2026-11-15** (at `65a8dca`); fast-forward it again when the owner asks.
- **Open threads and next steps:** [handoff.md](handoff.md). **The GUI as it stands:** [ui-inventory.md](ui-inventory.md).

## Display: MSDF glyphs (in progress)

`geom.msdf` makes a glyph's multi-channel signed distance field: overlaps resolved first, corners found and edges coloured, signed pseudo-distances per channel, signs checked against the true inside. Drawn back at any size its area is within 1 % of the outline's, corners stay sharp, and growing is a shifted threshold (the outline grown with round corners, as `geom.grow`). About 1.5 ms a glyph at 32 texels per cap height, made once per glyph. `graven msdf` draws a sheet of glyphs at several sizes, plain and grown. The GUI draws text from it (`apps/gui/glyphs.zig`): a field per face and glyph, sampled into coverage rasters by quarter octave of size and eighth of a pixel of growth, packed into 1024 px atlas pages (8, then the atlas starts again), each glyph a textured quad with its own transform; rules and drawn marks stay outlines, as does everything while construction is shown or when a glyph would raster past 256 px. Upright glyphs are rastered on the pixel grid at their exact size (64ths of an octave, horizontal phase in quarter pixels, baseline and cap height on pixel rows) and drawn texel for pixel; coverage takes a gamma of 2.2 (stem darkening, up to a set number of pixels fading out by 32 px cap height, is off by default) (`GRAVEN_TEXT_GAMMA`, `GRAVEN_TEXT_DARKEN`). `GRAVEN_EXACT_TEXT=1` draws text from its outlines instead, to compare; `GRAVEN_SAMPLE=hp15c|keyboard` and `GRAVEN_VIEW=cx,cy,ppm` open the app on a sample at a view. Next: the error-correction pass (faint specks where grown strokes merge), fields made off the drawing thread, least-recently-used eviction.

Fields come at three resolutions, chosen by the size a glyph is drawn: 32 texels per cap height up to a 64 px cap, 64 to 128 px, 128 past that (at least a texel for every two pixels; the range doubles with them, staying an eighth of the cap height). A gap a grown stroke nearly closes, drawn broken from a coarse field, is whole at the finer ones and matches the exact outline. Glyphs off the canvas are skipped before any field or raster is made. Release-build field times: about 4, 20 and 100 ms a glyph at the three levels.

Fields are made off the drawing thread, by up to 4 worker threads (one fewer than the processors): the drawing thread asks for a field, keeps drawing the glyph from the finest coarser field it has (or the label from its outlines), and takes the finished fields in at the start of a frame; the workers wake it when some are done. Release build, HP-15C keypad, worst frame on opening: 139 to 205 ms with fields made inline, 22 to 56 ms now. `GRAVEN_FIELDS_INLINE=1` makes them inline, to compare.

### Text display: to do

- Round the cap height up (when more than about 0.3 px past a whole pixel) rather than to the nearest pixel, so capitals' tops are not trimmed.
- Fit vertical stems to pixel columns (stem detection and a per-size outline distortion, in the manner of FreeType's autohinter).
- Least-recently-used eviction in the atlas, in place of starting again when its 8 pages are full.
- Frame timing on a dense document.

The status bar shows the average frame time over the last 30 s (building and drawing the UI, from the start of the frame to its end); `GRAVEN_FRAME_LOG=1` prints each frame's.

## Font management (stages 1 and 2 of 5 built)

Decided 2026-11-15, revised 2026-11-16 to the owner's model (blueprint, "Font management"): system fonts and user fonts are scanned into one index, each face marked system or user, and the local interface groups faces by typeface family. Font files are installed as user fonts, in the OS's per-user font folder where every application finds them (no separate Graven library); system fonts are never written. Remote search and fetch go through plugins or access methods on URLs, and fetched fonts may be installed for the user. Everything installed is plain sfnt, with a provenance record in Graven's data folder.

- **Built, stage 1 (containers):** WOFF/WOFF2 to sfnt, `graven-fonts convert`.
- **Built, stage 2 (local fonts):** `Record.scope` (system, user, remote; index version 6); `fontsearch.families` (faces by typographic family, ordered by width, weight and slope, counted by scope); the local source scans the user's folder (Linux `$XDG_DATA_HOME/fonts` or `~/.local/share/fonts`, and `~/.fonts`; macOS `~/Library/Fonts`; Windows `%LOCALAPPDATA%\Microsoft\Windows\Fonts`) as user fonts. `graven-fonts families [words] [--user|--system]`, `install FILE... [--replace]` (converted, named Family-Style.ext, a same-content repeat does nothing, a different user font of the same family and style kept unless `--replace`, a system font of the same name noted), `remove "Family" [--style S]` (user fonts only); `show` gives scope and provenance (`installed-fonts.json` in `$XDG_DATA_HOME/graven`, `~/Library/Application Support/Graven` or `%LOCALAPPDATA%\Graven`: SHA-256 of the file and of what came in, from, container, date, family, style, licence as stated).
- **Not yet:** Windows per-user fonts also need a registry entry (HKCU `...\Windows NT\CurrentVersion\Fonts`) for applications to see them; not written, and not tested on Windows or macOS. The Fonts window still lists faces one per row and has no Install or Remove (stage 5).
- **Next stages:** 3 remote search and fetch (plugins, access methods on URLs, catalogue cache, unmeasured records); 4 repositories (Fontsource, Google Fonts, GitHub releases, CTAN, URL manifests); 5 the Fonts window (families, scope, Install and Remove, remote sources, provenance).

## Planned: engine v2

A glyphic styling and positioning engine, written beside the v1 engine (`lib/engine`, which stays in use until v2 replaces it whole). Legends are stored as conceptual objects with typed parameters resolved through a cascade (font, package, style, element kind, legend, object), laid out in situ against the ground beneath them (track paths, segments, flows, process limits). KaTeX is a translation layer against it; objects carry tags for export. See the blueprint's "Engine v2" section for the stages.
