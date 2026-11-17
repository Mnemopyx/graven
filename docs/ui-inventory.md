# The GUI as it stands

An inventory of the editor's surfaces, written as the starting point for UI design work. The GUI grew stage by stage, each feature placed where it was easiest at the time; no consistent principles have been applied yet. This describes what is there, then lists the inconsistencies seen so far. It is not a design.

The editor is `apps/gui` (DVUI on SDL3, about 15,500 lines; `main.zig` is most of it).

## Start screen (since 2026-11-17)

What the app opens on, before there is a document: none of the canvas's interface (no rulers, tree, tools, properties or bottom bar; the menus stay in the title bar).

- **Splash**, centred on the desk: Graven's mark (a keycap with G and √x on it), the name, a line on what it does, the version, the licence ("not yet chosen": there is no licence file).
- **News** pane, left: the message of the day for this version (`motd/<version>.md` in the repository, fetched at most daily on a thread of its own and cached; a built-in welcome until then), a note at the foot on where it came from.
- **Start** pane, right: New canvas, millimetres (M); New canvas, inches (I); Open file… (O); then Recent: up to nine files opened or saved, latest first, each with its folder (shortened from the left) and its key (1 to 9); one no longer there is faint, and dropped when chosen.
- Choosing a canvas, opening a file, or a `GRAVEN_SAMPLE` launches the main interface; File › New canvas (after asking about unsaved changes) comes back here.

## Window

- **Title bar:** drawn by the app (`GRAVEN_NATIVE_FRAME` gives the system's). It shows the file name, a • when unsaved, and the context (Canvas, mm); on the start screen, Graven — Start.
- **Menus:** four, in the title bar.
  - **File:** New canvas… (Ctrl+N), Open… (Ctrl+O), Save (Ctrl+S), Save As… (Ctrl+Shift+S), Import text…, Place image…, Export SVG…, Add sample: PC keyboard, Add sample: HP-15C keypad, Quit.
  - **Edit:** Undo (Ctrl+Z), Redo (Ctrl+Shift+Z).
  - **Text:** Fonts…
  - **View:** Zoom to context; Show text construction; pane appearance options (ghost style, deep background, vivid colour, halo, hot edges).
- **Theme:** follows the desktop's.

## Panes (`ghost.zig`)

Four panes on the window's edges, each with a tab and three modes: **ghost** (see-through over the canvas), **docked** (beside it), **hidden**. Each has its own hue. With hot edges, holding the pointer on a tab opens its pane.

- **Tree** (left): the document as a component tree. Canvas, panels, grids, tile prototypes, sketches, layers. Selecting a node makes it the context.
- **Tools** (right, upper): the canvas tools. Select, Add panel, Add tracks, Add shape (art), Select area, Constrain, Join, New sketch. Some tools have options here (shape kind; what new tracks are sized to and which way they run).
- **Properties** (right, lower): the context's fields and its actions as buttons. Many commands live only here (see below). For a tile or a track with a flow, two sections at the end (since 2026-11-16): **Expression object** (the object at the expression line's cursor; for math, every parameter an element may override, italic when it is its style's, an x to clear; a change is written into the source as `\set(…){…}`) and **Text style** (size, base, faces, and its rules: kind, parameter and value dropdowns or entries, a bin, Add a rule).
- **Bottom bar:** the expression line and the status bar. The expression line edits the source (LaTeX legends, or math for an equation run); completions come from glyphic's symbols; Tab and Shift+Tab go to the next and previous stop in the expression's field order.
  - **Expression line:** edits the markup of the selected text or tile, with brace pairing, command completion and a live preview.
  - **Status bar:** pointer position, counts (panels, tiles, text pieces, missing glyphs, overflows, in margins), the current tool's hint, the font, zoom, solve time, average frame time (30 s).

## Canvas

- Rulers in the document's units, a sheet or an open canvas, frames, views, layers, images, groups.
- **Background grid** (since 2026-11-17; `grid.zig`): graph paper across the whole canvas area, under everything (panels draw no grid of their own; translucent ones show it through). Adaptive, as Fusion 360's sketch grid: decades of the document's unit, each decade's contrast set by its spacing on screen (none at 6 px, full at 200 px, eased), a line taking its coarsest decade's, so the coarser decade is always the darker and zooming fades levels in and out without popping. Lines one device pixel wide on the pixel grid, a cool neutral ink at low opacity; or dots at the crossings (stronger, as dots need it). View › Grid: lines (default), dots, none; remembered as `view.grid`.
- Panels, tiles, tracks with their flows of text and equations, art, sketches as views.
- **Text editing** happens in place in a track's flow: a character cursor, Shift to select, typing, Backspace and Delete, cut, copy and paste, Enter for a paragraph, Shift+Enter for a line break, Ctrl+\\ to edit the equation at the cursor (or a new one), the inline math the cursor is in, or a selected tile's text, on the canvas itself (since 2026-11-16): a caret in it, typing into its source, Left and Right, Backspace and Delete, Tab and Shift+Tab through its heads and fields; a head is boxed, and single keys style it (= and - scale, arrows nudge, [ and ] turn, 0 clears, i the root's index, u and b the upper and lower slots); Esc, Enter or Ctrl+\\ leave. The expression line shows the same source meanwhile.
- **Selection:** a click makes something the context; Ctrl-click selects; Tab hunts for the next-nearest object; drag moves, handles resize, within constraints. The pointer shows a hand or a lock.
- **Text display:** glyphs come from a distance-field atlas (`glyphs.zig`): crisp on the pixel grid, gamma 2.2. Show text construction draws outlines and construction instead.
- **Display correction** (since 2026-11-17; `display.zig`): a small opaque window from View › Display correction… or D on the start screen (a row there too). Midtones (gamma, 0.6 to 2.4) and Brightest (white level, 0.5 to 1), in steps of 0.05, live; a grey ramp in tenths and a 50 % gauge (fine black and white lines around a solid sRGB 50 % grey) to judge by; Reset, Close, Esc. Every interface colour goes through it; kept per machine. Not reached: the pixels of placed images (only dimmed) and the canvas's diagnostic construction colours. Its Screen size… button opens the next.
- **Screen size** (since 2026-11-17): View › Calibrate screen size…. An opaque window placed once when opened (so the card's corner stays put); a bank-card outline with centimetre ticks, its width dragged with the pointer or Left/Right (Shift: 10 device px); the scale in px/mm and dpi, against the 96 dpi estimate; Use estimate, Cancel (Esc), Save (Enter). Kept per machine.
- **Zoom readout** (status bar, after the pointer position): the zoom as a percentage of actual size, `*` while the screen is not measured; a click (or View › Actual size) zooms to 100 %. No single key yet: the canvas's letter keys go to text in flows.

## Modes

The canvas has sub-modes entered from the properties pane, each with its own way out:

- **Panel editing:** placing and spanning grid instances by clicking and dragging. Entered with Edit panel; left with Leave panel editing.
- **Sketch mode:** drawing and constraining a sketch, with its own toolbar of geometry and constraint tools, dimensions, parameters and expressions. Entered with Edit sketch, Edit its sketch or New sketch; left with Finish sketch… (Enter), Accept and leave, or Back to sketching.
- **Manufacture mode:** agreed, not built (each part's layer stack; design-rule checks).

## Separate windows and prompts

- **Fonts window** (Text › Fonts…): a window of its own (not a pane). It searches, compares and composes fonts and applies them to styles. Everything is visible at once:
  - **Search** across the top, in three groups: Search (words, characters it must have, Like), Style (serif or sans, upright or italic, mono, math, variable), Licence terms.
  - **Results** below on the left, as a tree: one line per family, with its style icons (Regular, Bold, Italic, Bold Italic: the letter a drawn in that face, empty where the family has none), each slant's pair followed by its weights in small boxes (VF for a variable font), and how many faces in how many files, whose. The italic groups line up in a column; a family too wide for the row puts its italic group on a line under. A click on an icon or weight box selects that face; a click elsewhere on the line opens or closes the family. An open family shows one line per file: pin, the style icon and weight box of each face it holds, the file name, what it is (whose, variable ranges or collection, serif or sans, licence, embedding) and, for a user font, Remove. Faces the search left out are faint.
  - **Compare** beside the results, **Style faces** to its right (since 2026-11-16: a style's text, italic, bold, bold italic and math faces, each set from the selected font or cleared; its family's italic and bolds in one click; fallbacks added and removed; the base it inherits from named). The pane redraws only on the next event after a change (seen driving it under Xvfb).
  - The top bar has the status, Install (font files or folders as user fonts), Rescan and Close. Remove first lists every face and weight the file takes with it and the document's styles that use them. Install and Remove prompts sit inside the window.
- **Unsaved changes:** Save, Don't save, Cancel.
- **Recovered work:** Keep them, Discard them, Not now.
- **A file changed by another session:** Load theirs, Overwrite with mine, Save mine as…

## Keys

| Keys | Action |
|---|---|
| Ctrl+N, Ctrl+O, Ctrl+S, Ctrl+Shift+S | New canvas, Open, Save, Save As |
| Ctrl+Z, Ctrl+Shift+Z (Ctrl+Y) | Undo, Redo |
| Ctrl+C, Ctrl+X, Ctrl+V, Ctrl+A | Copy, cut, paste, select all (in text) |
| Ctrl+\\ | Edit on the canvas: the equation or inline math at the cursor, or a selected tile's text (again to leave) |
| = - [ ] 0 i u b, arrows | On an equation's head: scale, turn, clear, index, upper and lower slots, nudge |
| Ctrl-click | Select |
| Tab, Shift+Tab | Next or previous stop (head or field) in an equation; next-nearest object when selecting |
| Enter, Shift+Enter | New paragraph, line break; Enter also finishes a sketch |
| Esc | Cancel the tool or mode in progress |
| Delete, Backspace | Delete in text; delete the selection |

The owner prefers single keys with no modifiers for commands. Today nearly every command needs a modifier or a pointer.

## Inconsistencies seen so far

These are observations to start the discussion from, not decisions.

1. **Where commands live:** some are menu items, some are tools, most are buttons in the properties pane (about 70 distinct buttons, among them Add grid, Add track, Add layer, Make panel, Release panel, Group, Ungroup, Edit sketch, Apply sketch to this prototype, Fit frame to its contents). There is no rule for which is which, and no command list or palette. (Keys, since 2026-11-17, are named actions in modes, `keymap.zig`: the ground for menus, a palette and the buttons to share.)
2. **Menus are thin:** Edit has only Undo and Redo; Text only Fonts…; samples sit in File.
3. **Modes are entered and left in different ways:** Edit panel / Leave panel editing; Edit sketch / Finish sketch… / Accept and leave / Back to sketching. Esc and Enter do not mean the same thing in every mode.
4. **Selection:** Ctrl-click selects, a plain click sets the context, and Select area is a separate tool. The context, the selection and the flow cursor are three separate ideas, shown in different ways.
5. **Keyboard:** commands mostly need modifiers or the pointer, against the owner's stated preference for single keys.
6. **Dialog wording varies:** Don't save / Discard them / Not now / Keep them / Load theirs / Overwrite with mine. Buttons name actions inconsistently.
7. **One window is not a pane:** the Fonts window is a separate OS window, where everything else is a pane.
8. **Terminology:** the code says label, track, region, slot, stamp, prototype; the UI uses some of these and other words. There is no glossary.
9. **The status bar mixes kinds of thing:** document counts, the tool hint, fonts and performance figures, all on one line.
10. **Pane appearance is still experimental:** several View menu options exist only to compare looks (ghost style, halo, vivid colour).
11. **Text entry:** the expression line and in-place flow editing both edit text, with overlapping roles.
12. **Development switches are environment variables only:** sample loading, the view, text display settings and frame logging have no UI.

- The Expression object section shows the object at the expression line's cursor, but nothing on the canvas marks which object that is.
- A rule's kind or parameter changed in the style section moves the rule to the end of the list (it is removed and added again).
- Number entries in the inspector write on every keystroke, so typing 1.5 sets 1 first (one undo step, as they merge).

- On-canvas equation editing has no visible mode marker but its caret and the status line; a click elsewhere leaves it.
- Arrow keys on a head nudge it, while elsewhere in the equation they move the caret: the same keys, two meanings, by where the caret is.

- The start screen's choices are not reachable by Tab or arrows yet, only by pointer and their single keys; and Mils, which the old new-canvas prompt offered, is no longer offered for a new canvas.
- The start screen's menus (Edit, Text, View) offer commands that need a document.

## Things to decide in the UI discussion

- A command model: what is a tool, what is a command, what is a property; where each is found; a command palette.
- Keys: single-key commands (and how they coexist with typing in flows), a consistent Esc and Enter.
- Modes: one way in and out of every mode; how a mode shows itself.
- Selection, context and cursor: one model and one way of showing it.
- Panes and windows: what belongs in a pane, what in a window, what on the canvas.
- Words: a glossary the UI and the docs share.
- How the text layers (text, arrangement, glyphic; see the blueprint's Engine v2 section) show up in the UI.
