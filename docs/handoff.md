# Handoff: open threads (2026-11-15)

Where each line of work stood at the end of the session that built math mode, the math font packages, drawn arrows, the MSDF text display and the 3MF export. Each thread names its next step. The blueprint has the full reasoning; `docs/status.md` has the inventory.

## 1. UI design (next session)

The GUI is inconsistent: no principles have been applied across it. [docs/ui-inventory.md](ui-inventory.md) lists its surfaces, the inconsistencies seen, and the questions to settle. Start there.

## 2. Engine v2: a glyphic styling and positioning engine (decided, not started)

- **Decided:** a rewrite beside v1 (`lib/engine` stays in use until v2 replaces it whole). Legends are stored as conceptual objects with typed parameters resolved through a cascade (font, package, style, element kind, legend, object). KaTeX is a translation layer with tags on objects for export. Layout happens in situ against the ground (track paths, segments, flows, process limits).
- **Agreed to test against use cases:** three layers of text (text, arrangement, glyphic), and glyphic text live by default.
- **Stages:** 1 object model and parameters; 2 the ground; 3 layout and output (HP-15C through v2, compared with v1); 4 KaTeX translation; 5 curved tracks and threads; 6 GUI picking and inspection; 7 drawn glyphs as sketches, text design-rule checks.
- **Next:** stage 1, once the object and parameter list is reviewed.

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

## 7. Font management (stages 1 and 2 of 5 built)

- **Built:** WOFF/WOFF2 read and converted to .ttf/.otf; system and user fonts scanned with their scope; families; `graven-fonts families`, `install`, `remove`, `convert`.
- **Next:** stage 3, remote search and fetch through plugins and access methods on URLs, fetched fonts installable as user fonts. Then the repositories (Fontsource first) and the Fonts window by family with Install and Remove.
- **Open:** the Windows registry entry for per-user fonts.

## 8. Manufacture

- **Built:** colour FDM: layer stacks, exact 2D slabs, 3MF (per colour or per band, either bed side), STEP through OCCT.
- **Open:** Manufacture mode in the GUI; nozzle-width and other design-rule checks; slicer filament assignment.
