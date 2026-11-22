#!/usr/bin/env bash
# Prunes the project's Zig build cache (.zig-cache) down to what the next
# build needs.
#
#   scripts/zig-cache-prune.sh [--force] [--quiet] [step ...]
#
# Zig never deletes old cache entries: every edit to a source file leaves its
# old outputs behind (a cloud session's disk allowance filled at 26 GB of
# cache, 2026-11-22). A cache folder's name cannot be worked out from the
# manifests for most kinds of step (scripts/zig-cache-prune.sh's notes in
# docs/status.md), so this watches instead: it runs each build step under
# strace (a no-change build: everything comes from the cache) and keeps every
# o/ and h/ entry the build opened, deleting the rest. The next build after an
# edit then rebuilds only what the edit feeds.
#
# It does nothing while the cache is under GRAVEN_CACHE_LIMIT_GB (default 10)
# unless --force, nor while another `zig build` is running, nor if a traced
# build fails (it might not have touched everything it needs). Steps default
# to GRAVEN_CACHE_STEPS or "install gui-build"; a step not traced is rebuilt
# from scratch the next time it is built.
#
# Zig is $ZIG, else `zig` on PATH, else the cloud sessions' pip copy
# (CLAUDE.md, "Toolchain"). Run automatically after build commands by a
# Claude Code hook (.claude/settings.json).

set -u
force=0
quiet=0
steps=()
for a in "$@"; do
	case "$a" in
	--force) force=1 ;;
	--quiet) quiet=1 ;;
	*) steps+=("$a") ;;
	esac
done
[ ${#steps[@]} -eq 0 ] && read -r -a steps <<<"${GRAVEN_CACHE_STEPS:-install gui-build}"

say() { [ "$quiet" = 1 ] || echo "zig-cache-prune: $*" >&2; }

root="$(cd "$(dirname "$0")/.." && pwd)"
cache="$root/.zig-cache"
[ -d "$cache/o" ] || exit 0

limit_gb="${GRAVEN_CACHE_LIMIT_GB:-10}"
size_kb=$(du -sk "$cache" 2>/dev/null | cut -f1)
if [ "$force" = 0 ] && [ "$size_kb" -lt $((limit_gb * 1024 * 1024)) ]; then
	exit 0
fi

if pgrep -f "zig build" >/dev/null 2>&1; then
	say "a zig build is running; not pruning now."
	exit 0
fi

zig="${ZIG:-}"
[ -z "$zig" ] && zig="$(command -v zig 2>/dev/null || true)"
if [ -z "$zig" ]; then
	for z in /tmp/claude-*/*/*/scratchpad/zig17/ziglang/zig; do
		[ -x "$z" ] && zig="$z" && break
	done
fi
if [ -z "$zig" ] || ! command -v strace >/dev/null 2>&1; then
	say "needs zig and strace; not pruning."
	exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
say "cache $((size_kb / 1024)) MB over ${limit_gb} GB: tracing ${steps[*]} to see what it uses."
cd "$root"
for step in "${steps[@]}"; do
	if ! strace -f -qq -e trace=openat,open,mkdirat,newfstatat,statx,stat,lstat,access,faccessat,faccessat2,readlinkat,renameat,renameat2 \
		-o "$work/trace.$step" "$zig" build "$step" >"$work/build.$step" 2>&1; then
		say "zig build $step failed under the trace; not pruning (see its output below)."
		[ "$quiet" = 1 ] || tail -20 "$work/build.$step" >&2
		exit 0
	fi
done
cat "$work"/trace.* | grep -o '[0-9a-f]\{32\}' | sort -u >"$work/keep"

removed=0
for kind in o h; do
	for d in "$cache/$kind"/*; do
		name="$(basename "$d")"
		if ! grep -qx "$name" "$work/keep"; then
			rm -rf "$d"
			removed=$((removed + 1))
		fi
	done
done
rm -rf "$cache/tmp"/* 2>/dev/null
after_kb=$(du -sk "$cache" 2>/dev/null | cut -f1)
say "removed $removed entries: $((size_kb / 1024)) MB -> $((after_kb / 1024)) MB."
# For a hook: a line Claude Code shows the person.
[ "$quiet" = 1 ] && echo "{\"systemMessage\": \"Zig cache pruned: $((size_kb / 1024)) MB -> $((after_kb / 1024)) MB ($removed entries).\"}"
exit 0
