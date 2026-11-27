#!/bin/sh
# Cross-builds Graven for 64-bit Windows and packages it for testers:
# the editor and CLI tools, fonts/, the examples with their fonts, and the
# tester notes (packaging/windows). Needs fonts/ (scripts/fetch-fonts.py).
#   scripts/package-windows.sh [out-dir]   -> <out-dir>/Graven-<version>-win64-<commit>.zip
set -eu
cd "$(dirname "$0")/.."
Z=${ZIG:-zig}
out=${1:-zig-out/package}
ver=$(sed -n 's/^ *\.version *= *"\([^"]*\)".*/\1/p' build.zig.zon | head -1)
rev=$(git rev-parse --short HEAD)
name="Graven-$ver-win64-$rev"
pre=$(mktemp -d)
trap 'rm -rf "$pre"' EXIT
"$Z" build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe --prefix "$pre/inst"
"$Z" build gui-build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe --prefix "$pre/inst"
ls fonts/*.otf fonts/*.ttf >/dev/null 2>&1 || { echo "no fonts in fonts/: run scripts/fetch-fonts.py" >&2; exit 1; }
d="$pre/$name"
mkdir -p "$d/examples"
cp "$pre"/inst/bin/*.exe "$d/"
cp -r fonts "$d/fonts"
cp examples/*.graven "$d/examples/"
cp -r examples/fonts examples/figures "$d/examples/"
cp packaging/windows/TESTING.md packaging/windows/*.bat "$d/"
mkdir -p "$out"
rm -f "$out/$name.zip"
(cd "$pre" && zip -qr - "$name") > "$out/$name.zip"
# Symbols for reading crash traces (llvm-symbolizer --obj=graven-gui.exe <address>).
(cd "$pre/inst/bin" && zip -qr - *.pdb) > "$out/$name-symbols.zip"
echo "$out/$name.zip"
