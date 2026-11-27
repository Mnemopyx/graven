# Graven for Windows: test build

Thank you for testing. This is the first Windows build of Graven. It was cross-built on Linux and has been run under Wine, never yet on real Windows, so anything odd you see is worth reporting.

## What is in the folder

| File | What it is |
|---|---|
| `graven-gui.exe` | the editor |
| `graven-gui-log.bat` | starts the editor and writes everything it prints to `graven-log.txt` beside it |
| `graven.exe` | the command line tool (export to SVG and 3MF) |
| `graven-fonts.exe` | the font search tool |
| `fonts\` | the fonts Graven uses for text and math (keep it beside the .exe files) |
| `examples\` | two example documents, with their own fonts |

Nothing is installed: unzip anywhere (not inside `Program Files`) and run. Windows 10 or 11, 64-bit. SmartScreen may warn that the program is unrecognised (it is not signed yet): choose "More info", then "Run anyway".

## Running it

Double-click `graven-gui-log.bat` (best for testing), or `graven-gui.exe`. A console window opens beside the editor; please leave it open. Started from the .bat, Graven's messages go to `graven-log.txt`; started from the .exe, they show in the console.

To open an example: File, Open, then `examples\hp15c.graven` or `examples\pc-keyboard.graven`. Or drag a `.graven` file onto the .bat or the .exe.

From a command prompt in the folder:

```
graven-gui.exe examples\hp15c.graven
graven.exe export examples\hp15c.graven hp15c.svg
graven.exe export examples\pc-keyboard.graven keyboard.3mf
```

## What to try

1. Start-up: the start screen, a new canvas in millimetres and in inches.
2. Open both examples. Do the legends look right (no empty boxes for missing glyphs, the math on the HP-15C keys set properly)?
3. Type: click into a track's text, type, use arrows, Home/End, Backspace, Ctrl+B and Ctrl+I, undo (Ctrl+Z) and redo.
4. Save a document, close Graven, open it again. Try a folder and file name with spaces and non-English letters (for example `Документы\café.graven`).
5. Export from the editor and with `graven.exe`: SVG (open it in a browser) and 3MF (open it in a slicer such as Bambu Studio or PrusaSlicer).
6. Screens: a high-DPI laptop screen at 150 % or 200 % scaling, and moving the window between two screens with different scaling. Is the text sharp, and is everything the right size?
7. Keyboard layouts other than US, if you have them: do keys and shortcuts still do what they say?
8. Resize, maximise and restore the window; dock and undock panes.

## Reporting

For each problem: what you did, what you expected, what happened, a screenshot, and `graven-log.txt` (if you started from the .bat) or a copy of the console window's text. If Graven closes suddenly, the console shows where it stopped: please copy all of it.

Graven keeps its settings in `%APPDATA%\Graven` and its caches and font index in `%LOCALAPPDATA%\Graven`. Deleting those folders resets it.

## Known gaps in this build

- No STEP export and no 3D manufacturing views: these need OCCT, which is not yet built for Windows. The views say so.
- Fonts installed only for your user (rather than for all users) may not be found yet.
- The program is not signed, and there is no installer, Start menu entry or file association.
- The console window opens with the editor; a later build will hide it.
- Speed: please tell us if anything feels slow (typing, zooming, panning). The bottom-right corner shows the time each frame takes.
