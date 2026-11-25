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
  - **File:** New canvas… (Ctrl+N), Open… (Ctrl+O), Save (Ctrl+S), Save As… (Ctrl+Shift+S), Import text…, Place image…, Export SVG…, Open example: PC keyboard, Open example: HP-15C keypad (each opened as an untitled copy, from examples/ where Graven was started; unsaved work asked about first), Quit.
  - **Edit:** Undo (Ctrl+Z), Redo (Ctrl+Shift+Z).
  - **Text:** Fonts…
  - **View:** Zoom to context; Show text construction; each pane pinned or not.
- **Theme:** follows the desktop's.

## Scrolling (decided 2026-11-21)

- **Document space** (vector content: canvases, frames, manufacturing views' parts) pans and zooms; it has no scroll bars. Rulers show where the view is.
- **Interface content** (DVUI widgets, text set by FreeType: panes, properties, the Browser, legend sheets, pop-ups, dialogs) scrolls, with scroll bars where it overflows.

## Ribbon (2026-11-21, 2026-11-22)

- Under the menu bar, the window's width (34 px): the active view's tools (a canvas view's today; sheets and plans next). Every canvas tool shows, faint where it does not apply to the context yet, so the row does not change with the selection. Buttons are keys in a row (since 2026-11-22, the owner's "A3"): 32 px apart centre to centre (64 device pixels at 200 %, the owner's choice), a 26 px icon, neighbours touching, corners 2 px, each shaded slightly from top to bottom like a raised key, a dark line (22 %) and a light line between neighbours; a tool on is tinted; the ribbon 52 px; each carries its key in a fade across its bottom: the button's lower edge darkening into a band the key sits in, over the icon's lower part (the owner's choice among badges, a chip, a corner legend, a keycap button, a tab, a strip); stronger while Alt is held. Keys, from the keymap: K Constrain, N New sketch, S Add shape, R Add rows, ⇧R Add columns, T Add track, F Fit to tiles, B Select boundaries, G Construction line, A Select area, P Add panel, L Layers.
- A ▾ after a button with more: Add shape's ▾ the shapes, Add rows' the rows, columns or one track (pull-downs); **Layers** (L) a full-width drop panel under the ribbon: the whole stack (the document's layers and the view's own, eyes, grips to reorder, Add layer) and the chosen layer's settings beside it. A ▾ clicked, or the button's key held (300 ms), opens it; a tap still runs the button. No OK or Cancel: each change applies as made (undo takes it back); a drop goes on Esc, a press outside it, or once the pointer has been in it and leaves.

## Tab bar (2026-11-21)

- The tab bar runs the window's full width: the edges' strips (and their hot edges) and docked panes start below it. The first tab stays where it was, at the views' left edge.
- A window's shown tab is joined to its view in three sections: the top, holding the name; a wider middle band, a longer contact with the view; then the view. Each meets the next with fillets (the top's corners, each step's inner and outer corners, into the view), all filled with the colour the view's top has (the ruler's, for a canvas) and outlined thinly; no highlight colour, the shape ties it to its view. Other tabs are plain labels.

- A legend sheet view's ribbon (2026-11-22): Add a row, Remove this row | Name keys by grid position, Name keys by their first legend | Open it beside the canvas (no single keys: letters type into the cells). A manufacturing view's: Add an operation | Check this plan, Clear results | Export this plan (make it active); they act on the view's plan.

## View strips (2026-11-22)

- Each window's strip is 22 px (was 30): its tab shown (the folder tab joined to its view; italic while a preview), with a ▾ in it opening the window's list (Ctrl+E, or Ctrl+T): this window's tabs first (a click shows one, × takes it off), then a filter and the document's contexts (a click shows one here, as a new tab when it is not one already; Enter takes the first match). The window's other tabs follow faintly where there is room (a click shows one). The split button at the right. The + button and the tabs' own × are gone from the strip (in the list now).
- Pages: a context with ordered pages (a document of frames as pages, to come) is one tab; its page is kept per view (`View.page`), so two windows can show two pages of one document. A page control (‹ n / m ›) follows the tab when the context has pages; PgUp and PgDn flip, Home and End go to the first and last. No context has pages yet: the control does not show.

## Splits

- Each split's divider drags to resize. Its grip (⋮ in the tab strips' row when side by side, ⋯ at the middle when stacked) or a click on the divider shows its options: Swap sides, Even out, Stacked or Side by side. A double-click on the divider evens it out.

## Panes (`ghost.zig`)

Four panes on the window's edges, each with a tab. Panes lie over the canvas and never move the views (since 2026-11-21: no docking, no ghosts). Each is **auto-hide** (holding the pointer on its tab slides it in, ready to use and slightly translucent; it slides out when left) or **pinned** in (a click on its tab pins or unpins it; View lists the same). The expression bar is pinned by default. Panes are dark: grey text on deep purple, apart from the canvas, a light table whose layers are overlays. Fitting a view keeps clear of pinned panes. **Hidden** is left only for a view that has no use for a pane (a sheet's has no tools).

- **Tree** (left): the document as a component tree. Canvas, panels, grids, tile prototypes, sketches, layers. Selecting a node makes it the context.
- **Tools:** retired 2026-11-22: its tools are the ribbon's, its Layers palette the ribbon's Layers panel. The right edge holds Properties alone.
- **Properties** (right, lower): the context's fields and its actions as buttons. Fields change nothing while typed (since 2026-11-20): Enter or leaving the field accepts a valid value, one undo step; anything else, or Esc, goes back. Many commands live only here (see below). For a tile or a track with a flow, two sections at the end (since 2026-11-16): **Expression object** (the object at the expression line's cursor; for math, every parameter an element may override, italic when it is its style's, an x to clear; a change is written into the source as `\set(…){…}`) and **Text style** (size, base, faces, and its rules: kind, parameter and value dropdowns or entries, a bin, Add a rule).
- **Bottom bar:** the expression line and the status bar. The expression line edits the source (LaTeX legends, or math for an equation run); completions come from glyphic's symbols; Tab and Shift+Tab go to the next and previous stop in the expression's field order.
  - **Expression line:** edits the markup of the selected text or tile, with brace pairing, command completion and a live preview.
  - **Status bar:** pointer position, counts (panels, tiles, text pieces, missing glyphs, overflows, in margins), the current tool's hint, the font, zoom, solve time, average frame time (30 s).

## Canvas

- Rulers in the document's units, a sheet or an open canvas, frames, views, layers, images, groups.
- **Background grid** (since 2026-11-17; `grid.zig`; inches in fractions since the same day): graph paper across the whole canvas area, under everything (panels draw no grid of their own; translucent ones show it through). Adaptive, as Fusion 360's sketch grid: decades of the document's unit, each decade's contrast set by its spacing on screen (none at 6 px, full at 200 px, eased), a line taking its coarsest decade's, so the coarser decade is always the darker and zooming fades levels in and out without popping. Lines one device pixel wide on the pixel grid, a cool neutral ink at low opacity; or dots at the crossings (stronger, as dots need it). View › Grid: lines (default), dots, none; remembered as `view.grid`.
- Panels, tiles, tracks with their flows of text and equations, art, sketches as views.
- **Text editing** happens in place in a track's flow: a character cursor, Shift to select, typing, Backspace and Delete, cut, copy and paste, Enter for a paragraph, Shift+Enter for a line break, Ctrl+\\ to edit the equation at the cursor (or a new one), the inline math the cursor is in, or a selected tile's text, on the canvas itself (since 2026-11-16): a caret in it, typing into its source, Left and Right, Backspace and Delete, Tab and Shift+Tab through its heads and fields; a head is boxed, and single keys style it (= and - scale, arrows nudge, [ and ] turn, 0 clears, i the root's index, u and b the upper and lower slots); Esc, Enter or Ctrl+\\ leave. The expression line shows the same source meanwhile. Meanwhile (since 2026-11-20) every layout object's box is outlined and the slot's baseline drawn; the chosen object (the head's structure, or the object at the caret) is boxed strongly with its own baseline, its neighbours a little stronger; a click on an object chooses it, as does Up while typing (the object at the caret); with one chosen, Tab and Shift+Tab go through the objects, o steps out to what holds it, the arrows nudge it (Left and Right from the object before it, what follows moving along; Up and Down from the baseline; 0.02 cap a press), = - [ ] scale and turn it, 0 clears it, Esc goes back to typing. Plain words on keys can be chosen and nudged too. The properties pane starts with the expression's section for a tile's slot and a run alike: what is edited, the chosen object's gaps to its neighbours, its baseline's height and its box, then its parameters and style; the tile's or track's own properties follow.
- **Engagement points** (since 2026-11-17; the origin since 2026-11-18): near a container's origin (its grab point: moves it), corner, edge midpoint, edge or centre, a highlight and an annunciator; Tab locks on (scintillating), a drag moves that point exactly. Points standing in for the pointer scintillate everywhere (sketch locks too).
- **Nudges** (since 2026-11-17): arrows move the selection (or the context) by the grid's minor unit, Shift+arrow by its major unit; inches in fractions (1/16 in …), as the grid now divides them; a lone track by its own step.
- **Track extents** (since 2026-11-17): every track region's full extent (the area its rows or columns expand into) shows as a dashed outline whether selected or not: faint, stronger for the context's track. Before, only the context's showed, so after an undo or redo (which leaves nothing selected) a track seemed to shrink to its first row.
- **One selection** (since 2026-11-17): click selects (with handles), again for what holds it; Shift-click adds or removes; drag moves a selected or grabbed container; drag on empty canvas selects an area; Space-drag or middle-drag pans. (The entry below is from before.)
- **Pointing** (since 2026-11-20): near a container's outline (5 px) the pointer outlines the container, and a press selects it (a key, a track, a panel); inside a key, away from its outline, it highlights the slot's text nearest the pointer (an I-beam), and a press edits that slot on the canvas with the caret between the glyphs nearest the press, whichever slot it is (a key's g and f legends included); in a slot being edited, near an object's box the object is outlined and a press chooses it (for nudging), inside it a press puts the caret. Selected containers' handles and edges (moving and sizing) come first; Shift- and Ctrl-clicks keep their meaning.
- **Selection:** a click makes something the context; Ctrl-click selects; Tab hunts for the next-nearest object; drag moves, handles resize, within constraints. The pointer shows a hand or a lock. A constraint's dimension (its line or its value) is hovered, dragged to place it, or clicked to pick the constraint (shown in the properties; Delete removes it). Dimension values and constraint marks, on the canvas and in sketches, are drawn in the stroke font: along their line, upright; a sketch radius on a leader from the centre. Drags snap to the grid (finest lines showing), with guides; Alt held lets go; View › Snap to grid (%).
- **Tracks and regions** (since 2026-11-20): a region (column of rows, row of columns) shows its rows in the Browser; a track (one line, set in advance) its keys straight under it. Properties: Kind, Direction and Rotation in degrees (rows 0 and 0, columns −90 and 90; other angles kept and flagged), no depth for a track; a region's **Make tracks of its N rows** (one track a row, where each is, the flow running through them); **Remove track** or **Remove region** (also Delete with it chosen): its flow goes on in its other tracks. The heading says Track or Region.
- **Flows:** the Browser lists them under Flows, each with its tracks in order, unplaced ones marked. A flow's properties: name, tracks, words held, Remove. A track's properties: its Flow (a picker), its place in it, Show the flow, Join a track after this…, Take out of its flow. File › Import text… (RTF or plain) goes in at the flow cursor, else at the end of the flow chosen in the Browser, else into a new unplaced flow; a flow's properties list its sources.
- **Navigation:** Space+drag pans (Shift: one axis); Z+drag zooms; Z tapped zooms in a level at the pointer, Shift+Z out. Scrolling: View › Scrolling (trackpad pans and wheel zooms, or always zooms, or always pans); Ctrl+scroll zooms; pinch zooms.
- **Views:** the central region holds windows (splits), each with its tabs: a quick-view of contexts recently shown there, not every context of the document. Each tab names its canvas, frame, sheet or plan (numbered when two show one): click activates, a double-click fills the region, × takes it off the window's tabs (the window's last: the window closes). After the tabs a + (Ctrl+T) opens a pop-up: a filter, then the contexts by group, those in the window marked •; at the strip's right a split button (Ctrl+Shift+\\; Alt+click stacked). A context opened from the Browser or beside comes as a preview tab (italic), which the next one opened in its window replaces; work in it or a double-click keeps it. View › New view side by side / stacked, Fill the window with this view, Next view (Ctrl+Tab), Close this view. An inactive view only shows; a press activates it. A double-click on the canvas or a frame in the Browser fills the window with its view.
- **Sheet view:** a legend sheet as a table, edited cell by cell where it is (the keys beside it change as it is typed). Up and Down, Enter, Tab and Shift+Tab move; the selected row's key is the context, and a key clicked on a canvas selects its row. Problem rows and columns are marked. Properties: row, key, slot, naming helpers, add or remove a row. The Tools pane hides while it is active.
- **File › Export legend sheet (CSV)…:** the sheet shown or chosen, as CSV, offered as its name `.csv` beside the document.
- **File › Import legend sheet (CSV)…:** into the sheet shown or chosen (rows matched by name), or a new sheet over the grid, track or panel chosen, opened beside the canvas.
- **Legend sheets:** Make a legend sheet on a grid's properties; Legend sheets in the Browser; a sheet's summary (columns, rows, problems, Remove), its keys highlighted. Cells cannot be edited there yet; an edit on a key goes to its cell.
- **Choosing files** (since 2026-11-23): Open, Save As, Import text, Import legend sheet, Import figure, Export legend sheet, Export 3MF and Place image open the system's file dialog at once (tinyfiledialogs: Windows' and macOS's own; zenity, kdialog, qarma, matedialog or yad on Linux), filtered to the types each reads or writes; a path can be pasted into it (GTK: type / or Ctrl+L; Windows: the File name box; macOS: Cmd+Shift+G). Graven's own prompt for a typed name is the fallback where there is no such dialog (and under the GUI's tests).
- **Figures** (since 2026-11-23): the Browser's Figures node, always shown, lists the document's figures (line art kept as prototypes). Figures' properties: their count and Import SVG…; File › Import figure (SVG)… does the same (a file prompt); an import names the figure after the file and makes it the context, its skipped parts in the status line. A figure's properties: Name (editable), From (the file), Size (its ink's), Paths (how many stroked), a drawing of its ink fitted to the pane, Remove figure. Insert figure (ribbon, I; applies with a figure chosen in the Browser) drags out a placement in the canvas or frame shown, proportions locked (a click: the figure's own size); a placement is moved and resized like other containers (proportions kept), its boundary 1 mm round its ink; its properties: Figure, Layer, Place, Width, Height, Margin, Remove figure.
- **Fabrication** (since 2026-11-18): the end of a panel's properties: its Process (since 2026-11-19: a dropdown of none, the document's profiles, then the built-ins it lacks, marked "(built in)"; one of those chosen is added and used in one step), thickness; its layers in order (from, makes, colour, start, direction, depth), moved, removed, added. File › Export panel as 3MF… writes them.
- **Manufacturing view** (since 2026-11-19): a tab "Making: <plan>" from a plan's Open in a manufacturing view. It shows the plan's parts from above, its operations as layers drawn as made (cutting first, as the stock), with a caption saying so; the wheel zooms, a drag pans. While it is active the properties are its plan's editor, unless plans or materials were chosen in the Browser. C there checks its plan; the results draw under each operation's layer (simulated paths, then findings). "Max error, mm" (the plan's tolerance, 0.05 by default: meshes, drawing, 3MF, checks no coarser than a tenth of the narrowest band). "Shown as" (in the plan's properties, while its view is active): From above, or 3D through OCCT (a build with OCCT; else marked "not in this build"); in 3D a caption says what was built and how long it took, or "building it through OCCT…"; a drag turns, Shift-drag moves, the wheel zooms about the pointer.
- **Manufacturing plans and Materials** (since 2026-11-19): Browser nodes. A plan's properties: Open in a manufacturing view; Plan (name, Export this plan); Checks (Check this plan, then Findings and Simulation checkboxes, Clear results; "out of date" after an edit); each operation's Checked counts; Parts (a material dropdown per panel, Add a part); Operations (Add an operation; each: Shown, Earlier, Later, Remove, Name, Process, Passes, a checkbox per part layer with a colour dropdown); warnings in the overflow colour; Remove this plan. A material's: Name, then read-only kind, form, surface, colours, under it, thicknesses; Used by; Remove this material.
- **Fabrication checks** (since 2026-11-19): run only by hand: C on the canvas, File › Check fabrication (the context's panel if it can be checked, else every panel with a process profile and fabrication layers), or Check this panel at the top of a panel's Fabrication (which then lists that panel's last results, check by check, and its size and colours). Results are layers above the document's, in a space's Layers under Results (out of date after any change): Check: strokes, Check: gaps, Check: cap height, depths, colours, size, Simulation: FDM walls; each a checkbox with its counts; Check again, Clear results. Findings fill in magenta (marginal) or red (fail); boxes for the rest; walls as beads in their filament's colour.
- **Processes** (since 2026-11-19): a Browser node always listed, the document's process profiles under it. Its properties: how many, and Add a profile, a button per built-in (a name already taken gets a number). A profile's: Name; Class and Process (read-only); its process's settings (FDM: nozzle, line width, layer height, first layer, filament slots, build volume); Limits: Set by (the process's settings, or this profile in part), each band's two ends typed (stroke, gap, cap height: passes at, fails below; typing one makes it the profile's own), depths and colours read-only, Use the limits its settings give; Used by (the panels, as buttons), and Remove this profile while none uses it.
- **Content palette** (since 2026-11-18): with the flow cursor in a track, a strip at the top centre of the window, below the ruler: in a track of tiles, the key sizes to scale and blanks; then text or equation, join or part, next kind of tile (Tab), line break, new paragraph. A click inserts at the cursor. No keys on its buttons (letters and digits type).
- **Digraphs** (since 2026-11-18): Ctrl+K and two characters, wherever text is typed (canvas text and fields alike), type the character they stand for (`->` →, `e'` é, `SH` ⇧). A hint by the caret or field lists the pairs the first character starts; Esc cancels, Backspace steps back. Users add or remove pairs in the config's `[digraphs]`.
- **Text display:** glyphs come from a distance-field atlas (`glyphs.zig`): crisp on the pixel grid, gamma 2.2. Show text construction draws outlines and construction instead.
- **Display correction** (since 2026-11-17; `display.zig`): a small opaque window from View › Display correction… or D on the start screen (a row there too). Midtones (gamma, 0.6 to 2.4) and Brightest (white level, 0.5 to 1), in steps of 0.05, live; a grey ramp in tenths and a 50 % gauge (fine black and white lines around a solid sRGB 50 % grey) to judge by; Reset, Close, Esc. Every interface colour goes through it; kept per machine. Not reached: the pixels of placed images (only dimmed) and the canvas's diagnostic construction colours. Its Screen size… button opens the next.
- **Screen size** (since 2026-11-17): View › Calibrate screen size…. An opaque window placed once when opened (so the card's corner stays put); a bank-card outline with centimetre ticks, its width dragged with the pointer or Left/Right (Shift: 10 device px); the scale in px/mm and dpi, against the 96 dpi estimate; Use estimate, Cancel (Esc), Save (Enter). Kept per machine.
- **Zoom readout** (status bar, after the pointer position): the zoom as a percentage of actual size, `*` while the screen is not measured; a click (or View › Actual size) zooms to 100 %.
- **View keys** (since 2026-11-17): Ctrl+0 zoom to context, Ctrl+Alt+0 to everything, Ctrl+1 actual size, Ctrl+2 200 %, Ctrl+= and Ctrl+- in and out through levels of actual size; 0, 1, 2, = and - alone too, except where text is typed. In the View menu with their shortcuts.
- **Pane layouts** (since 2026-11-17): View › Pane layout: standard, compact, large-text and any saved; Next layout, Save layout as…, Reset this layout. The tree pane is now called the Browser.
- **Pane modes** (since 2026-11-21): auto-hide or pinned, by a click on the tab or View. Auto-hide panes slide in on a rest on the tab and out when left; narrow windows (under 1000 px) make the side panes auto-hide. Hot corners (bottom right by default: all auto-hide panes in or out), set per corner in the config.
- **Frame the edit** (since 2026-11-17): Ctrl+9 (9 alone where nothing is typed), View › Frame the edit: the edit shown legible with as much round it as fits; status line says what was framed.
- **Menus show shortcuts** at the right of each item, from the keymap (File, Edit, View so far); the rest of the menu items have none yet.

## Modes

The canvas has sub-modes entered from the properties pane, each with its own way out:

- **Panel editing:** placing and spanning grid instances by clicking and dragging. Entered with Edit panel; left with Leave panel editing.
- **Sketch mode:** drawing and constraining a sketch, with its own toolbar of geometry and constraint tools, dimensions, parameters and expressions. Entered with Edit sketch, Edit its sketch or New sketch; left with Finish sketch… (Enter), Accept and leave, or Back to sketching. Planned (2026-11-25, design in the blueprint's "Drawing in sketches"): the sketch's tools move from this button row into the ribbon, in groups: Geometry, Constrain, Ink (Ink selection I, Fill F, Pick area, Select path, Select by style, the current styles) and Show (construction, ink only). One editor, not separate sketch and ink modes.
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
| Ctrl+< / Ctrl+> | A level out / in (the keys < and > are on, Shift or not: Ctrl+, and Ctrl+. on a US layout): an object chosen in an expression, the expression typed in, a track's content (the flow cursor), the container (tile, track, grid, line art: its size and place), its panel, the canvas. In goes back the way out came, else to the first thing inside (a track: its content; the flow cursor: the item after it; a tile: its text; text: the object at the caret; an object: its first part). Panel editing: out leaves it |
| Ctrl+\\ | Edit on the canvas: the equation or inline math at the cursor, or a selected tile's text (again to leave); then Up chooses the object at the caret, Tab steps through objects, o steps out, arrows nudge, Esc back to typing |
| = - [ ] 0 i u b, arrows | On an equation's head: scale, turn, clear, index, upper and lower slots, nudge |
| Ctrl-click | Select |
| Tab, Shift+Tab | Next or previous stop (head or field) in an equation; next-nearest object when selecting |
| Enter, Shift+Enter | New paragraph, line break; Enter also finishes a sketch |
| Esc | Cancel the tool or mode in progress |
| Delete, Backspace | Delete in text; delete the selection |

The owner prefers single keys with no modifiers for commands. Today nearly every command needs a modifier or a pointer.

## Element ids (since 2026-11-20)

Every property row, button, dropdown, checkbox, tool and palette button has an id in a logical group (`apps/gui/elements.zig`, 505 entries): what it is about, not where it is drawn (`panel.fab.thickness`, `plan.operation.2.process`, `track.flow.show`, `dialog.export.…`). Every button is an action of the same name. Menu items are `menu.<action>`. `testing_api.discover(group)` walks the registry and says what is shown. Objects are reached by name path (`Model.resolve`). Every button is a virtual key: pressed, it queues its action, and a handler (`button_handlers` in main.zig) acts on the context it was pressed in; dialogs' Cancel and OK are `dialog.cancel` and `dialog.confirm` (as Esc and Enter); the content palette is `palette.key.1-25u` …, the move arrows `move.up` …. Chrome acting where drawn, outside the registry: a Browser node's chevron, a view tab's close.

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
10. **Pane appearance settled (2026-11-21):** the ghost mode and its style experiments (one alpha, matched, tinted, outlined, haloed; deep background; hot edges as an option) are gone; panes are dark purple, docked or auto-hide.
11. **Text entry:** the expression line and in-place flow editing both edit text, with overlapping roles.
12. **Development switches are environment variables only:** sample loading, the view, text display settings and frame logging have no UI.

- The Expression object section shows the object at the expression line's cursor, but nothing on the canvas marks which object that is.
- A rule's kind or parameter changed in the style section moves the rule to the end of the list (it is removed and added again).
- Number entries in the inspector write on every keystroke, so typing 1.5 sets 1 first (one undo step, as they merge).

- On-canvas equation editing has no visible mode marker but its caret and the status line; a click elsewhere leaves it.
- Arrow keys on a head nudge it, while elsewhere in the equation they move the caret: the same keys, two meanings, by where the caret is.

- The start screen's choices are not reachable by Tab or arrows yet, only by pointer and their single keys; and Mils, which the old new-canvas prompt offered, is no longer offered for a new canvas.
- The start screen's menus (Edit, Text, View) offer commands that need a document.
- Result layers sit in Layers with the document's but are not layers of the document: no properties, not saved, not undone; their rows are labels, not buttons.
- Operations are ordered with Earlier and Later buttons, fabrication layers with arrow icons: two ways to order a list.
- The manufacturing view's 2D and 3D modes move differently: 2D, a drag pans; 3D, a drag turns and Shift-drag pans; the canvas pans with Space-drag or the middle button.
- A property row's label column is only as wide as the default; a longer label ("Build volume across, mm", "Origin across, mm") pushes its field right, so fields in one section start at different places.
- Read-only rows are of two kinds: plain text, and the italic, dimmed "derived" value (Limits' Set by); which one is used is not consistent.

## Things to decide in the UI discussion

- A command model: what is a tool, what is a command, what is a property; where each is found; a command palette.
- Keys: single-key commands (and how they coexist with typing in flows), a consistent Esc and Enter.
- Modes: one way in and out of every mode; how a mode shows itself.
- Selection, context and cursor: one model and one way of showing it.
- Panes and windows: what belongs in a pane, what in a window, what on the canvas.
- Words: a glossary the UI and the docs share.
- How the text layers (text, arrangement, glyphic; see the blueprint's Engine v2 section) show up in the UI.

- **Outlines of layout regions** (2026-11-21, the owner: dashes did not look good): tracks and regions, a selected key's slots, tiles without a body (the plate's legend places), the sketch frame and picked objects are outlined with thin solid lines in their usual colours (`guideBox`, `guideOutline`), not dashed. Construction geometry inside a sketch stays dashed (a drafting convention).

- **Select boundaries** (2026-11-21): a persistent mode, toggled by its tool-palette button or B (Esc does not end it; kept in the shared settings as `view.boundary_mode`). With the select tool, the container whose boundary is nearest the pointer (keys, tracks whole and their rows that hold content, grids, line art, panels, construction lines; each by its boundary path, `geom.path`; within 40 px or with the pointer inside) is highlighted, the nearest point on it ringed, and a click selects it, never its content: a track, panel or line art becomes the selection, its drag points (move and resize handles) drawn with a halo. With no boundary in reach, a click is a plain one: on empty canvas or frame it chooses the canvas or frame (since 2026-11-23). **Boundary highlights** (this mode, and the select tool's outline zone) are a halo: a 3 px core stroke and a translucent glow either side whose opacity falls off as the inverse square of the distance from the stroke, a(t) = 0.5 / (1 + (t / 3 px)²) for boundaries (`haloBox`, `haloSegment`), 0.7 / (1 + (t / 5 px)²) for drag points (`haloPoint`).

- **Halos by state** (decided 2026-11-21, the owner: halos set selectable and selected things apart from the drawing): with nothing selected, the boundary a click would select is haloed (any container under the pointer's reach: in Select boundaries the nearest, else by its outline zone); with a selection, its drag points are haloed (the grips, and the engagement point under the pointer; whole edges are no longer engaged), and nothing else is; while content is edited (a slot's caret, a track's flow cursor), nothing is haloed and the caret is drawn as **laser speckle**: red grains along a faint core line, their brightness negative-exponential as laser speckle's is, peaked across the bar, re-drawn 25 times a second so it boils. Drag points (engagement) are offered on the selection only: a container is selected first (a click by its outline), then dragged by its points.

- **Construction lines** (2026-11-21; tool palette on a canvas or frame, or G; Esc ends the tool): infinite guide lines, never output. Made from two points: a drag from the first to the second, or a click (released within 3 px of the press) at the first and a click at the second, a preview through the first point and the pointer between; Shift turns by 15°; points snap to the grid as drags do. On a canvas a line runs on without end (drawn where it crosses the view); in a frame it ends at the frame's boundary. Thin violet lines; the chosen one heavier. A click near one (5 px) chooses it (with nothing selected, it is haloed under the pointer); its properties: Name (Guide1 …), Through across and up (a point on it), Angle (editable while free), Held (free, its angle, horizontal, vertical), Remove; Delete removes it. Not yet: dragging a line, drags snapping to lines, containers attached to them.

