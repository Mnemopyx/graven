# Handoff: open threads (2026-11-15)

Where each line of work stood at the end of the session that built math mode, the math font packages, drawn arrows, the MSDF text display and the 3MF export. Each thread names its next step. The blueprint has the full reasoning; `docs/status.md` has the inventory.

## 1. UI design (in progress)

Working through the UI in the order of the user's workflow. Built 2026-11-17: the start screen (splash, News pane with a per-version message of the day, Start pane with new canvas mm/in, Open, recent files). Open: the licence to name on the splash; the message fetch through an HTTP proxy (stalls in this cloud environment, see status); keyboard focus through the start screen's choices. Built since: the background grid (adaptive graph paper, lines/dots/none); display correction (gamma and white level for screens that show Graven washed out, View › Display correction… or D on the start screen; the owner should set it on the COSMIC machine and say whether the two knobs are enough or a black-level/contrast one is wanted too); screen size calibration with a bank card and View › Actual size (the owner should measure on each screen; a single key for actual size is still to be chosen, since letters type into flows). Next in the workflow: what the new canvas shows first.

Actions and key modes: step 1 built 2026-11-17 (the registry `actions.zig`, Graven's actions/modes/default keys `keymap.zig`, every key site matching through it, the active mode stack with text masking). Step 2 built the same day: the view keys (Ctrl+0, Ctrl+Alt+0, Ctrl+1, Ctrl+2 = 200 % as the owner chose, Ctrl+= / Ctrl+-, and unchorded 0 1 2 = - where no text is typed) and menus that run actions and show their shortcuts. Then Frame the edit (Ctrl+9), the owner's refinement of the follow viewport: legibility of the edit with its context is the aim (x-height 1.5 mm on screen), measured against the window as it is; on the key only for now (the owner's choice). Next, as agreed: prefixes and the next-key hint; user keymaps in the config; later, whether framing or following should ever happen by itself. Then auto-hide panes and hot corners (built the same day, at the owner's direction): a fourth pane mode that slides in from its edge on a rest on the tab and out when left; side panes auto-hide below 1000 px of window width; hot corners run configured actions (bottom right: all auto-hide panes in or out). The spark (scintillation) is now an animated cursor the compositor plays (no redraws), drawn only as a fallback. Moving and sizing containers (agreed plan, steps 1–2 built 2026-11-17): engagement points with hover highlight and annunciator, the Tab lock, zero-offset drags, and the scintillation policy for points standing in for the pointer. Step 3 built the same day (one selection: click selects with handles, click again for what holds it, Shift-click adds or removes, a drag moves or draws out an area, Space-drag pans). Step 4 built the same day (nudges: the finest grid step showing, Shift ×10, any selection; a lone track by its own step). Constraint dimensions are placed by dragging (line sideways, value along it; kept relative to the constrained object, saved, undone) and picked by a click (properties, Delete), built 2026-11-18; their values (and the sketch's) are now stroke text in `geom.strokefont` (Hershey Roman Simplex plus dimension symbols), turned along their lines, radius leaders in sketches. Step 5, grid part, built 2026-11-18 (drags snap to the finest grid lines showing, guides, Alt lets go, View › Snap to grid on %). Next: the rest of 5, snapping of the engaged point to grid lines and other containers' edges and centres, with guides (Alt off); 6 editable X/Y/W/H in properties. Then pane layouts (the owner's direction: configurable location and font/feature size, official names, shared with local override, several named and switched): names, layouts with mode/size/text scale, built-ins, View › Pane layout with save as and reset are built; placing panes on other edges is the next step there (the layout code fixes the browser left and the tools/properties column right). Open: no keyboard way to bring a pane in yet (an action per pane would do: Adobe's Tab, all panels, is a candidate where Tab is not taken); corners other than bottom right are unassigned; the slide threshold and delays are first guesses to tune by use. Seen while testing, pre-existing and not yet fixed: after Tab hunts a Ctrl-click selection, the keyboard focus leaves the canvas, so later arrows and Esc reach nothing.

Before that work began, the GUI was inconsistent: no principles have been applied across it. [docs/ui-inventory.md](ui-inventory.md) lists its surfaces, the inconsistencies seen, and the questions to settle. Start there.

## 2. Engine v2: a glyphic styling and positioning engine (decided, not started)

- **Decided:** a rewrite beside v1 (`lib/engine` stays in use until v2 replaces it whole). Legends are stored as conceptual objects with typed parameters resolved through a cascade (font, package, style, element kind, legend, object). KaTeX is a translation layer with tags on objects for export. Layout happens in situ against the ground (track paths, segments, flows, process limits).
- **Agreed to test against use cases:** three layers of text (text, arrangement, glyphic), and glyphic text live by default.
- **Stages:** 1 object model and parameters; 2 the ground; 3 layout and output (HP-15C through v2, compared with v1); 4 KaTeX translation; 5 curved tracks and threads; 6 GUI picking and inspection; 7 drawn glyphs as sketches, text design-rule checks.
- **Decided 2026-11-16:** two entry syntaxes over the same objects, LaTeX/KaTeX (default) and Typst-style; math only in math regions, so Typst's `/` is a fraction; Graven's own parameters in Typst's call form in both. Stage 4 becomes "entry syntaxes".
- **Built 2026-11-16: stage 1, the object model** (`lib/glyphic`): objects, typed parameters, the cascade with provenance, derived context, Tab's stops with head stops and slot toggles, break candidates; tested on the Leibniz series. The object model's design, worked out by example, is in the blueprint ("Engine v2: the object model by example").
- **Built 2026-11-16: stage 2, the ground** (`glyphic.ground`, `lib/layout/ground.zig`): pieces with baseline frames, open stretches, room, cap height and alignment (process limits are the manufacture stage's, not layout's); tracks give v1's own segments. Relative rotation is glyphic's and separate (owner's decision).
- **Built 2026-11-16: stage 3 in large part** (`faces.zig`, `layout.zig`, `setting.zig`; `graven v2` renders the Leibniz series on a row, broken rows and a dial). Not yet: HP-15C through v2 (needs the parser), ink spacing, MATH size variants, operators repeated at breaks.
- **Built 2026-11-16: stage 4, entry syntaxes** (`latex.zig`, `typst.zig`, `symbols.zig`, `entry.zig`, `reparse.zig`), and the HP-15C through v2 against v1 (`graven v2 hp15c <folder>`): all 111 legends parse and fit, column tracks included (built 2026-11-16: stacked pieces, a character at a time, upright); v2 lacks v1's weight matching, ink spacing, drawn arrows and bold Greek.
- **Built 2026-11-16: style contexts** (`styles.zig`, `glyphic.Engine`): apps configure contexts (faces, rules, bases) and apply them to elements or groups; elements override only relative scale, nudges, rotation and structural choices. No styles in the library.
- **Decided 2026-11-16: straight onto v2, no migration.** Steps 1 to 5 built, the route complete: `lib/engine` deleted 2026-11-16 (its `Render` container now `lib/layout/render.zig`, flow editing on glyphic's parse, `graven label` and `parse` on glyphic). Earlier steps (the GUI on v2: overrides saved in the source as `\set(…){…}`, completions from glyphic, Tab through stops, an inspector for the object at the expression cursor and for its style's rules; text breaks in glyphic; placement on v2: `lib/layout/legend.zig` sets every legend with glyphic into the `Render` container all consumers read; the model's text styles are stored glyphic contexts: faces by role, rules, a base; composed fonts gone; packages are presets; the Fonts window's Compose pane is now Style faces). Built since: editing equations on the canvas (Ctrl+\\: typing into the source, Tab through heads and fields, single keys on a head). inline math in text runs and tile tracks' text the same way. **Next:** selection inside an equation, a key for a large operator's limits; the display-bitmap cache of rigid elements; weight matching and the other v2 gaps. The v2 gaps against v1: weight matching, ink spacing, drawn arrows, math alphabets and the Greek mapping, MATH size variants, underline and strikethrough.

## 3. Sketch mode: constraining against external geometry (proposed, awaiting answers)

- **Proposal:** reference geometry in sketches, linked to sources (other sketches, panel edges and cutouts, later track paths and frames), refreshed live, flagged when broken, loops refused. Sketch curves as text paths, and closed profiles as wrap boundaries for flows.
- **Open questions:** resolve references through the sketch's first (home) view; first sources are other sketches and panel edges and cutouts. The owner said these will be settled through use cases.
- **Stages:** 1 sketch library reference geometry; 2 model links; 3 GUI picking; 4 wrap boundaries; 5 text paths (straight in v1, curved in v2).

## 4. Text display (MSDF), to do

Built: distance fields per glyph at three resolutions, error correction, an atlas of rasters, upright glyphs on the pixel grid, gamma 2.2, fields made off the drawing thread, culling. To do:

1. Round the cap height up rather than to the nearest pixel.
2. Fit vertical stems to pixel columns (autohinter-style).
3. Least-recently-used eviction in the atlas.
4. Time a dense document.

## 5. HP-15C legends

- **State:** `graven hp15c libertinus` (Geist SemiBold with Libertinus Math: operators, bold Greek, italic variables at 1.2×, π at 1.2×); drawn arrows (solid acute heads, short shafts; ⇄ as two notched heads); keys 8 × 7.2 mm at 11.43 × 12.7 mm pitch; legends: white 1.9 mm, blue 1.25 mm, gold 1.4 mm cap height; superscripts raised 0.5, subscripts dropped 0.24 of cap height.
- **Open:** ⇄ reads as chevrons at small sizes; ∫ with limits is cramped; gold and blue legend colours are not set; reconcile the legend list with EverCalc's (`tools/legend/hp15c.py` in the EverCalc repo); the GUI's HP-15C sample uses the default face, not the package.

## 6. Math fonts

- **Built:** math mode (`$…$`) in track text; packages `stix-two` and `libertinus` (`scripts/fetch-fonts.py`); member weights matched by a named stroke; per-member size, shift and weight.
- **Open:** a weight control in the Fonts window; glyphs composed from parts; real radicals and big operators from the MATH table.

## 7. Font management (local work done: stages 1, 2 and the Fonts window's local part)

- **Built:** WOFF/WOFF2 read and converted to .ttf/.otf; system and user fonts scanned with their scope; families; `graven-fonts families`, `install`, `remove`, `convert`. The Fonts window groups results by family and installs and removes user fonts; Remove is by file and says first which faces, weights and styles go with it, what stays of the family, and which styles use them.
- **Next:** stage 3, remote search and fetch through plugins and access methods on URLs, fetched fonts installable as user fonts; then the repositories (Fontsource first: its files are often WOFF2 only, which now converts).
- **Open:** the Windows registry entry for per-user fonts.

## 8. Manufacture

- **Built:** colour FDM: layer stacks, exact 2D slabs, 3MF (per colour or per band, either bed side), STEP through OCCT.
- **Open:** Manufacture mode in the GUI; nozzle-width and other design-rule checks; slicer filament assignment.
