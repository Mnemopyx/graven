#!/bin/bash
# Graven's cloud-environment setup: run as root from the folder holding the
# checkout (graven/), when a cloud session's machine is made. It installs Zig
# 0.17 and xdotool (Xvfb and ImageMagick are on the image), puts every Zig
# package the build needs into the Zig cache (Zig cannot fetch through the
# proxy: scripts/zig-prefetch.py), fetches the fonts and builds the GUI once,
# so a session starts able to build, test and run the GUI under Xvfb.
# The prefetcher and build.zig.zon are taken from origin/ui-dev, the
# development branch, whatever branch the session was cloned on.
set -u
[ -d graven ] || exit 0
log() { echo "graven-setup: $*"; }

if [ ! -x /opt/zig17/ziglang/zig ]; then
  pip install -q --target /opt/zig17 ziglang==0.17.0 || { log "zig install failed"; exit 1; }
fi
ln -sf /opt/zig17/ziglang/zig /usr/local/bin/zig
command -v xdotool >/dev/null || { apt-get update -q && apt-get install -y -q xdotool; } >/dev/null 2>&1 \
  || log "xdotool not installed"

cd graven
W=$(mktemp -d)
mkdir -p "$W/dev" "$W/here"
if git fetch -q origin ui-dev && git show FETCH_HEAD:scripts/zig-prefetch.py >"$W/prefetch.py"; then
  git show FETCH_HEAD:build.zig.zon >"$W/dev/build.zig.zon"
else
  log "could not read origin/ui-dev; using this checkout"
  cp scripts/zig-prefetch.py "$W/prefetch.py" 2>/dev/null || { log "no prefetcher"; exit 0; }
fi
cp build.zig.zon "$W/here/"
for root in "$W/dev" "$W/here"; do
  [ -f "$root/build.zig.zon" ] || continue
  python3 -I "$W/prefetch.py" --zig /usr/local/bin/zig --root "$root" || log "prefetch reported failures"
done
rm -rf "$W"

python3 scripts/fetch-fonts.py >/dev/null || log "fonts not fetched"
# One build now, so the session's first build reuses SDL3 and the rest (about 3 minutes).
zig build gui-build >/dev/null 2>&1 && log "GUI built" || log "warm GUI build failed (the session will see why)"
exit 0
