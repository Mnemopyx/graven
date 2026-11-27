# Examples

Documents and inputs for trying Graven from the repository root.

| Path | What |
| --- | --- |
| `pc-keyboard.graven` | A PC keyboard (ANSI, 104 keys) in one track of tiles: each key's legends one a slot (`top`, `bottom`, `words`), set in Inter Medium |
| `hp15c.graven` | The HP-15C keypad, from EverCalc's measurements and legend list: a plate with key holes, gold legends and CLEAR, and the keys with white and blue legends, on a rectangular array (a Cartesian grid object: the keys centred on its points) and a grid that follows it; legends in the STIX Two math package; fabrication layers for 3MF |
| `fonts/Inter-Medium.otf` | Inter Medium, the keyboard's legend font. SIL Open Font License 1.1: see `fonts/OFL.txt` |
| `examples_test.zig` | Checks that each document opens and lays out as it should (part of `zig build test`) |

A document's fonts are found first in a `fonts` folder beside it (here, `examples/fonts`), then in `$GRAVEN_FONTS` or `fonts/` in the working folder (the math packages' fonts: `python3 scripts/fetch-fonts.py`), then among the installed fonts. The GUI and the CLI look in the same places.

```sh
zig build run -- export examples/pc-keyboard.graven kb.svg
zig build run -- export examples/hp15c.graven hp15c.svg      # hp15c-HP-15C plate.svg, hp15c-HP-15C keys.svg
zig build run -- export examples/hp15c.graven hp15c.3mf      # the same, as 3MF for multi-colour printing
zig build gui -- examples/hp15c.graven                        # or GRAVEN_SAMPLE=hp15c, as an untitled copy
```

Both documents were made in Graven's GUI, step by step as a person would (`zig build gui-test` makes them again and checks that their SVG and 3MF are the same as these files', byte for byte), then compacted (`graven compact`). Each carries its legend sheet (`legends` as a CSV: File › Export legend sheet).
