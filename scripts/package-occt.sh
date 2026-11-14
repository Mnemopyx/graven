#!/bin/sh
# Package an OCCT install made by scripts/build-occt.sh as a release archive,
# so a first Graven build can fetch it instead of building OCCT (about 17
# minutes).
#
# Usage: scripts/package-occt.sh <install-prefix> <occt-source-dir> <out-dir>
#
# Writes to <out-dir>:
#   occt-<version>-<target>-zig<zig version>-<recipe>.tar.xz
#   the same name with .sha256 (sha256sum's format)
# and prints the archive's Zig package hash, for build.zig.zon.
#
# The libraries are stripped of debug information (about 85% of their size;
# a local build keeps it). The archive holds lib/*.a, include/, MANIFEST and
# OCCT's licence (LGPL 2.1 with its exception) with a note of where the
# source and our one patch are. The tar is made reproducibly: sorted names,
# fixed times and owners, single-threaded xz.
#
# Needs strip (binutils), tar, xz and sha256sum; zig for the package hash
# (ZIG, default: zig).
set -eu

prefix=${1:?usage: package-occt.sh <install-prefix> <occt-source-dir> <out-dir>}
src=${2:?usage: package-occt.sh <install-prefix> <occt-source-dir> <out-dir>}
out=${3:?usage: package-occt.sh <install-prefix> <occt-source-dir> <out-dir>}
zig=${ZIG:-zig}

manifest="$prefix/MANIFEST"
if [ ! -f "$manifest" ]; then
    echo "package-occt.sh: $manifest not found; build with scripts/build-occt.sh" >&2
    exit 1
fi
field() { sed -n "s/^$1=//p" "$manifest"; }
occt=$(field occt)
zig_version=$(field zig)
target=$(field target)
cpu=$(field cpu)
recipe=$(field recipe | cut -c1-8)
if [ "$cpu" != baseline ]; then
    echo "package-occt.sh: built for cpu \"$cpu\"; a release needs CPU=baseline" >&2
    exit 1
fi
version=$(echo "$occt" | sed 's/^V//; s/_/./g')
name="occt-$version-$target-zig$zig_version-$recipe"

mkdir -p "$out"
out=$(cd "$out" && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
root="$stage/$name"
mkdir -p "$root/lib"
cp -R "$prefix/include" "$root/include"
for lib in "$prefix"/lib/*.a; do
    cp "$lib" "$root/lib/"
    strip --strip-debug "$root/lib/$(basename "$lib")"
done
cp "$manifest" "$root/MANIFEST"
cp "$src/LICENSE_LGPL_21.txt" "$src/OCCT_LGPL_EXCEPTION.txt" "$root/"
cat > "$root/SOURCE" <<EOF
Open CASCADE Technology $version, built as static libraries with zig c++
$zig_version for $target (cpu: baseline), stripped of debug information.

Source: https://github.com/Open-Cascade-SAS/occt, tag $occt.
Built by scripts/build-occt.sh in Graven (recipe SHA-256 in MANIFEST),
which makes one change to the source: in adm/cmake/occt_csf.cmake,
  set (CSF_ThreadLibs  "pthread rt stdc++")
becomes
  set (CSF_ThreadLibs  "pthread rt")
so that GCC's libstdc++ is not linked beside Zig's libc++.

OCCT is licensed under the GNU LGPL 2.1 with the Open CASCADE exception:
see LICENSE_LGPL_21.txt and OCCT_LGPL_EXCEPTION.txt.
EOF

archive="$out/$name.tar.xz"
# The files at the archive's root, with no folder around them: Zig's package
# hash is then the same however the archive is fetched. Unpack it into a
# directory of its own (tar -xJf <archive> -C <dir>).
(cd "$root" && tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    -cf - .) | xz -T1 -6 > "$archive"
(cd "$out" && sha256sum "$name.tar.xz" > "$name.tar.xz.sha256")

echo "archive: $archive ($(du -h "$archive" | cut -f1))"
echo "sha256:  $(cut -d' ' -f1 "$archive.sha256")"
echo "zig package hash: $("$zig" fetch "$archive")"
