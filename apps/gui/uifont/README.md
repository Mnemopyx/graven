# Graven Sans: the interface's font for fields and cells

`GravenSans.ttf` is built into the GUI for text fields and table cells
(legend sheets, the expression line), where legends' characters must show
as they are typed: Greek, operators, relations, arrows, sets, number sets,
brackets, super- and subscripts, key symbols.

It is [Inter](https://github.com/rsms/inter) (variable: optical size and
weight; drawn for interfaces at small sizes) with the symbols Inter lacks
taken from [Noto Sans Math](https://github.com/notofonts/math), scaled to
Inter's units, made by `scripts/uifont.py` and renamed as the licence asks
of a modified font. The added symbols do not vary with weight. Licence:
`OFL.txt` (SIL Open Font License 1.1), free to bundle and redistribute
with Graven.

Inputs (google/fonts, `ofl/`), SHA-256:

- `inter/Inter[opsz,wght].ttf`: 29160a80ff49ddcab2c97711247e08b1fab27a484a329ce8b813d820dc559031
- `notosansmath/NotoSansMath-Regular.ttf`: 3f495fe933c06786e4d5f6d86b8ee70b6753a68ee3b9d87528726de0f6e2c47d

Rebuild: `python3 scripts/uifont.py Inter.ttf NotoSansMath-Regular.ttf apps/gui/uifont/GravenSans.ttf`.
