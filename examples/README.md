# Examples

Inputs for trying Graven from the repository root.

| Path | What |
| --- | --- |
| `fonts/Inter-Medium.otf` | Inter Medium, the default legend font for the PC keyboard sample. SIL Open Font License 1.1: see `fonts/OFL.txt` |

```sh
zig build run -- keyboard examples/fonts/Inter-Medium.otf kb.svg
zig build run -- label examples/fonts/Inter-Medium.otf - 3 'CAPS LOCK' caps.svg
zig build gui      # opens with an installed Inter Medium, else this example font
```

The keyboard layout itself is not a file yet: it is built in code by `apps/samples/pc_keyboard.zig` until the native file format exists.
