# Graven status

Taken on 13 November 2026, on branch `ui-dev`. This list comes from the commit history, the code layout and recent work. Not every feature was re-checked in the app for it.

Graven has about 32,000 lines of Zig and 209 tests. It has 127 commits since 4 November 2026, and 81 of them are on `ui-dev` and not yet on `main`.

## What exists

### Label engine (`lib/engine`, `lib/font`, `lib/geom`)

- **Shaping and outlines:** HarfBuzz shaping. Glyph outlines are kept exact (lines, quadratics and cubics), and cap height is measured from the outlines.
- **Markup:** KaTeX-style label markup with a strict parse and a lenient preview parse.
  - Superscripts and subscripts, `\frac`, `\sqrt`, accents and math spaces.
  - TeX atom-class spacing.
  - Variants: bold, italic and math alphabets.
  - Underline, strikethrough, and text superscripts and subscripts.
- **Spacing by ink:** neighbours and scripts are placed by their ink, using contact profiles.
- **Line breaking:** breaks within a box, at spaces, `\allowbreak` and soft hyphens, and forced cuts inside words that are too long for their line.
- **Spring-chain solver** for anchoring labels.

### Fonts (`lib/fontsearch`, `apps/fonts`)

- Composed fonts, with members and fallback.
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
- The OCCT bridge is a tested shim that writes STEP with names and colours. Neither the app nor the CLI uses it yet.

## Agreed but not built

1. Paragraph styles for headings (size, weight, rules above and below). This is the likely next item.
2. Grids, next steps: refining the HP-15C sample with real measurements, and a polar grid. Built: hole and part shapes from sketches: a stamp draws its instances from a sketch by ID, live, solved for each instance's box (its `w` and `h` set from the box, other parameters per stamp), with four ready-made, fully constrained sketches (circle, rectangle, rounded rectangle, slot) made in the document's sketches when first chosen. Not yet: a sketch that solves into an inverted shape (a corner radius over half the side) is not caught; overlapping holes cancel. Also built: a rough HP-15C keypad sample (11.43 mm across),  a panel editing mode that places and spans instances by clicking and dragging on a grid, Cartesian grids on panels with stamps (prototype instances as parts, holes or legends) bound to their points, grids that follow another part's grid, and panels from sketches: sketches have their own tree category, a sketch on a canvas or frame is a view of it, and an enclosed sketch view can be made a panel, cut by nesting.
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
