# The GUI as it stands

An inventory of the editor's surfaces, written as the starting point for UI design work. The GUI grew stage by stage, each feature placed where it was easiest at the time; no consistent principles have been applied yet. This describes what is there, then lists the inconsistencies seen so far. It is not a design.

The editor is `apps/gui` (DVUI on SDL3, about 15,500 lines; `main.zig` is most of it).

## Window

- **Title bar:** drawn by the app (`GRAVEN_NATIVE_FRAME` gives the system's). It shows the file name, a • when unsaved, and the context (Canvas, mm; New canvas).
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
- **Properties** (right, lower): the context's fields and its actions as buttons. Many commands live only here (see below).
- **Bottom bar:** the expression line and the status bar.
  - **Expression line:** edits the markup of the selected text or tile, with brace pairing, command completion and a live preview.
  - **Status bar:** pointer position, counts (panels, tiles, text pieces, missing glyphs, overflows, in margins), the current tool's hint, the font, zoom, solve time, average frame time (30 s).

## Canvas

- Rulers in the document's units, a sheet or an open canvas, frames, views, layers, images, groups.
- Panels, tiles, tracks with their flows of text and equations, art, sketches as views.
- **Text editing** happens in place in a track's flow: a character cursor, Shift to select, typing, Backspace and Delete, cut, copy and paste, Enter for a paragraph, Shift+Enter for a line break, Ctrl+\\ for equation mode, Tab through an equation's slots.
- **Selection:** a click makes something the context; Ctrl-click selects; Tab hunts for the next-nearest object; drag moves, handles resize, within constraints. The pointer shows a hand or a lock.
- **Text display:** glyphs come from a distance-field atlas (`glyphs.zig`): crisp on the pixel grid, gamma 2.2. Show text construction draws outlines and construction instead.

## Modes

The canvas has sub-modes entered from the properties pane, each with its own way out:

- **Panel editing:** placing and spanning grid instances by clicking and dragging. Entered with Edit panel; left with Leave panel editing.
- **Sketch mode:** drawing and constraining a sketch, with its own toolbar of geometry and constraint tools, dimensions, parameters and expressions. Entered with Edit sketch, Edit its sketch or New sketch; left with Finish sketch… (Enter), Accept and leave, or Back to sketching.
- **Manufacture mode:** agreed, not built (each part's layer stack; design-rule checks).

## Separate windows and prompts

- **Fonts window** (Text › Fonts…): a window of its own (not a pane). It searches, compares and composes fonts and applies them to styles.
- **New canvas prompt:** in the canvas, for units.
- **Unsaved changes:** Save, Don't save, Cancel.
- **Recovered work:** Keep them, Discard them, Not now.
- **A file changed by another session:** Load theirs, Overwrite with mine, Save mine as…

## Keys

| Keys | Action |
|---|---|
| Ctrl+N, Ctrl+O, Ctrl+S, Ctrl+Shift+S | New canvas, Open, Save, Save As |
| Ctrl+Z, Ctrl+Shift+Z (Ctrl+Y) | Undo, Redo |
| Ctrl+C, Ctrl+X, Ctrl+V, Ctrl+A | Copy, cut, paste, select all (in text) |
| Ctrl+\\ | Equation mode in a flow |
| Ctrl-click | Select |
| Tab | Next slot in an equation; next-nearest object when selecting |
| Enter, Shift+Enter | New paragraph, line break; Enter also finishes a sketch |
| Esc | Cancel the tool or mode in progress |
| Delete, Backspace | Delete in text; delete the selection |

The owner prefers single keys with no modifiers for commands. Today nearly every command needs a modifier or a pointer.

## Inconsistencies seen so far

These are observations to start the discussion from, not decisions.

1. **Where commands live:** some are menu items, some are tools, most are buttons in the properties pane (about 70 distinct buttons, among them Add grid, Add track, Add layer, Make panel, Release panel, Group, Ungroup, Edit sketch, Apply sketch to this prototype, Fit frame to its contents). There is no rule for which is which, and no command list or palette.
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

## Things to decide in the UI discussion

- A command model: what is a tool, what is a command, what is a property; where each is found; a command palette.
- Keys: single-key commands (and how they coexist with typing in flows), a consistent Esc and Enter.
- Modes: one way in and out of every mode; how a mode shows itself.
- Selection, context and cursor: one model and one way of showing it.
- Panes and windows: what belongs in a pane, what in a window, what on the canvas.
- Words: a glossary the UI and the docs share.
- How the text layers (text, arrangement, glyphic; see the blueprint's Engine v2 section) show up in the UI.
