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

- **STEP export:** the bridge exists but nothing calls it.
- **Design-rule checks and per-process output:** the README lists `geometry` and `drc` modules as "to come". Gerber and mirrored output for the manufacturing processes are not started.
- **Proof sheet:** not started.
- **HP-15C sample:** the first target application has no sample yet. The only sample is the PC keyboard.

## Housekeeping

- **Known limitations:**
  - an unsaved-change log written before free labels were removed has not been tested for recovery;
  - the drawn hyphen ignores the word's bold or italic;
  - forced wraps and hyphen breaks work in rows only, not in columns;
  - copying text keeps no formatting.
- **`ui-dev` is 81 commits ahead of `main`.**

## Display: MSDF glyphs (in progress)

`geom.msdf` makes a glyph's multi-channel signed distance field: overlaps resolved first, corners found and edges coloured, signed pseudo-distances per channel, signs checked against the true inside. Drawn back at any size its area is within 1 % of the outline's, corners stay sharp, and growing is a shifted threshold (the outline grown with round corners, as `geom.grow`). About 1.5 ms a glyph at 32 texels per cap height, made once per glyph. `graven msdf` draws a sheet of glyphs at several sizes, plain and grown. Next: a per-glyph cache and atlas in the GUI, drawing every text item through it; then the error-correction pass (faint specks where grown strokes merge).

## Planned: engine v2

A glyphic styling and positioning engine, written beside the v1 engine (`lib/engine`, which stays in use until v2 replaces it whole). Legends are stored as conceptual objects with typed parameters resolved through a cascade (font, package, style, element kind, legend, object), laid out in situ against the ground beneath them (track paths, segments, flows, process limits). KaTeX is a translation layer against it; objects carry tags for export. See the blueprint's "Engine v2" section for the stages.
