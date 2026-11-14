#!/bin/sh
# Build a minimal static OCCT 8.0.1 with zig c++ for the Graven OCCT bridge.
#
# Usage: scripts/build-occt.sh <install-prefix> [work-dir]
#   ZIG   zig executable (default: zig)
#   JOBS  parallel jobs (default: ninja's choice)
#   CPU   zig -mcpu value (default: baseline, so the libraries run on any
#         machine of this architecture; "native" tunes for this one only)
#
# Needs git, cmake and ninja. Takes about 17 minutes on 4 cores.
# Then: zig build occt-test -Docct=<install-prefix>
#
# Writes <install-prefix>/MANIFEST: the OCCT tag, the zig version and target
# that built it, the CPU, and this script's SHA-256 (the recipe). A build is
# only usable with the zig version that made it (its libc++), which
# build.zig checks. scripts/package-occt.sh makes a release archive of it.
set -eu

prefix=${1:?usage: build-occt.sh <install-prefix> [work-dir]}
work=${2:-$PWD/occt-work}
zig=${ZIG:-zig}
cpu=${CPU:-baseline}
tag=V8_0_1
recipe=$(sha256sum "$0" | cut -d' ' -f1)

mkdir -p "$work"
src="$work/occt"
build="$work/build"
wrap="$work/zig-wrappers"

if [ ! -d "$src/.git" ]; then
    git clone --depth 1 --branch "$tag" https://github.com/Open-Cascade-SAS/occt "$src"
fi

# OCCT adds GCC's libstdc++ to its Linux thread libraries. Zig links libc++,
# and mixing the two C++ runtimes breaks at link or run time, so drop it.
csf="$src/adm/cmake/occt_csf.cmake"
if grep -q 'set (CSF_ThreadLibs  "pthread rt stdc++")' "$csf"; then
    sed -i 's/set (CSF_ThreadLibs  "pthread rt stdc++")/set (CSF_ThreadLibs  "pthread rt")/' "$csf"
elif ! grep -q 'set (CSF_ThreadLibs  "pthread rt")' "$csf"; then
    echo "build-occt.sh: CSF_ThreadLibs line not found in $csf; check the patch for this OCCT version" >&2
    exit 1
fi

# CMake will not take a compiler command with arguments, so wrap each zig tool.
mkdir -p "$wrap"
for t in cc c++ ar ranlib; do
    case $t in
        cc | c++) flags="-mcpu=$cpu" ;;
        *) flags= ;;
    esac
    printf '#!/bin/sh\nexec "%s" %s %s "$@"\n' "$zig" "$t" "$flags" > "$wrap/zig-$t"
    chmod +x "$wrap/zig-$t"
done

# All modules off; name only the toolkits needed. OCCT adds their dependencies.
# XDE (TKXCAF) pulls in TKV3d and TKService, which build without FreeType, X11 or OpenGL.
cmake -S "$src" -B "$build" -G Ninja \
    -DCMAKE_C_COMPILER="$wrap/zig-cc" -DCMAKE_CXX_COMPILER="$wrap/zig-c++" \
    -DCMAKE_AR="$wrap/zig-ar" -DCMAKE_RANLIB="$wrap/zig-ranlib" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_LIBRARY_TYPE=Static \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DBUILD_MODULE_FoundationClasses=OFF -DBUILD_MODULE_ModelingData=OFF \
    -DBUILD_MODULE_ModelingAlgorithms=OFF -DBUILD_MODULE_Visualization=OFF \
    -DBUILD_MODULE_ApplicationFramework=OFF -DBUILD_MODULE_DataExchange=OFF \
    -DBUILD_MODULE_Draw=OFF \
    -DBUILD_ADDITIONAL_TOOLKITS="TKDESTEP;TKBO;TKPrim" \
    -DUSE_FREETYPE=OFF -DUSE_TK=OFF -DUSE_XLIB=OFF -DUSE_OPENGL=OFF \
    -DUSE_GLES2=OFF -DUSE_FREEIMAGE=OFF -DUSE_TBB=OFF

if [ -n "${JOBS:-}" ]; then
    ninja -C "$build" -j "$JOBS" install
else
    ninja -C "$build" install
fi

# What built it, for build.zig's check and for the release archive's name.
zig_version=$("$zig" version)
target=$("$zig" env | sed -n 's/^ *\.target = "\([^-.]*\)-\([^-.]*\)[^-]*-\([a-z]*\).*/\1-\2-\3/p')
cat > "$prefix/MANIFEST" <<EOF
occt=$tag
zig=$zig_version
target=$target
cpu=$cpu
recipe=$recipe
EOF

echo "OCCT $tag installed to $prefix ($target, cpu $cpu, zig $zig_version)"
