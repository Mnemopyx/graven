# The interface's fonts

DejaVu Sans and DejaVu Sans Mono 2.37 (unmodified, from the release archive
`dejavu-fonts-ttf-2.37.tar.bz2`, SHA-256
`fa9ca4d13871dd122f61258a80d01751d603b4d3ee14095d65453b4e846e17d7`) are built
into the GUI as its fonts throughout (since 2026-11-21), in place of DVUI's
Bitstream Vera: `DejaVuSans.ttf`, `-Bold`, `-Oblique`, `-BoldOblique`, and
`DejaVuSansMono.ttf`, `-Bold` (`main.zig`, `ui_fonts`).

DejaVu is Bitstream Vera extended: the same shapes, hinted for screens and
readable at small sizes, with the characters legends use, so a key's name or
a legend shows wherever the interface writes it (the Browser, properties,
tabs, fields, legend sheets). It covers Greek, mathematical operators and
relations, arrows, sets, number sets, brackets, super- and subscripts and key
symbols, and carries an OpenType MATH table.

Licence: `DejaVu-LICENSE.txt` (Bitstream Vera and Arev terms; DejaVu's
changes are in the public domain): free to bundle and redistribute with
software, its notices kept with it.

Chosen 2026-11-18 (for fields and cells) over Inter (49 of 173 tested
symbols missing), Source Sans 3 (51), IBM Plex Sans (70) and Noto Sans Math
alone (35 missing, ² among them).
