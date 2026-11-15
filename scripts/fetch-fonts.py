#!/usr/bin/env python3
"""Fetch the pinned fonts of Graven's math font packages.

Downloads each file or archive from its official distribution, checks its
SHA-256 against the value pinned here, and unpacks the fonts it names into
the fonts directory: $GRAVEN_FONTS if set, else fonts/ at the top of the
repository (which git ignores). Files already present with the right
contents are left alone.

  Package "STIX Two" (lib/layout/fonts.zig, `stix_two`):
    Geist Sans 1.9.0                  Vercel's npm package "geist" (.ttf, the
                                      static weights; SIL OFL)
    STIX Two Math 2.12                CTAN (.otf; SIL OFL): the math face
    STIX Two Text Bold, SemiBold 2.12 CTAN (.otf; SIL OFL): upright Greek
    TeX Gyre Schola Bold Italic 2.005 CTAN (.otf; GUST Font License):
                                      variables
  Package "Libertinus" (`libertinus`):
    Geist Sans 1.9.0                  as above: the text
    Libertinus Math 7.051             CTAN (.otf; SIL OFL): operators, arrows,
                                      bold Greek, italic variables, the
                                      math constants
  with each family's licence.

The STIX Two sources, versions and hashes are those pinned by EverCalc's
legend tool (tools/legend/fetch_fonts.py), where those choices were made.

Usage: scripts/fetch-fonts.py [--dest DIR]
Standard library only.
"""

import argparse
import hashlib
import io
import os
import sys
import tarfile
import urllib.request
from pathlib import Path

# A fixed CTAN mirror: the mirrors.ctan.org redirector can land on mirrors
# whose certificates do not verify. The hashes pin the content either way.
CTAN = "https://ctan.math.illinois.edu"

PINNED = [
    {
        "name": "Geist Sans 1.9.0 (npm geist, 2026-10-30)",
        "url": "https://registry.npmjs.org/geist/-/geist-1.9.0.tgz",
        "sha256": "80c7cd136d43444d26a3d6aa425e0b957d1962993e76d97716731e7dc32f14c6",
        "folder": "package/dist/fonts/geist-sans/",
        "suffixes": (".ttf",),
        "skip": ("Variable", "[wght]"),
        "license": ("package/LICENSE.txt", "Geist-LICENSE.txt"),
    },
    {
        "name": "STIX Two Math 2.12 (CTAN)",
        "url": f"{CTAN}/fonts/stix2-otf/STIXTwoMath-Regular.otf",
        "sha256": "95bc2729e41faf93b0bcae9e96c4dc4da45855067fd0581e621e30734fe8d90b",
        "file": "STIXTwoMath-Regular.otf",
    },
    {
        "name": "STIX Two Text Bold 2.12 (CTAN)",
        "url": f"{CTAN}/fonts/stix2-otf/STIXTwoText-Bold.otf",
        "sha256": "3465fca932b801fec1b241cc9561ac082d22d86e400b68fd2395636316781133",
        "file": "STIXTwoText-Bold.otf",
    },
    {
        "name": "STIX Two Text SemiBold 2.12 (CTAN)",
        "url": f"{CTAN}/fonts/stix2-otf/STIXTwoText-SemiBold.otf",
        "sha256": "1682cfa1e2e60e3bc3c63655c9020ba398d45b61e16fe5d863f2cd43909beb66",
        "file": "STIXTwoText-SemiBold.otf",
    },
    {
        "name": "STIX Two licence (SIL OFL 1.1)",
        "url": f"{CTAN}/fonts/stix2-otf/OFL.txt",
        "sha256": "bec17cee6412788db45fd2644b301afbc99cc5d372ddd3345dc4a7bfdefb9f04",
        "file": "STIXTwo-OFL.txt",
    },
    {
        "name": "TeX Gyre Schola Bold Italic 2.005 (CTAN)",
        "url": f"{CTAN}/fonts/tex-gyre/opentype/texgyreschola-bolditalic.otf",
        "sha256": "95f085da44c04817771f2a3a754b6eeb442b9a79e79f51dc3b0612e3cc0d75cc",
        "file": "texgyreschola-bolditalic.otf",
    },
    {
        "name": "TeX Gyre licence (GUST Font License)",
        "url": f"{CTAN}/fonts/tex-gyre/doc/GUST-FONT-LICENSE.txt",
        "sha256": "2bd69affc3da00715116f713f57eab9707e96daf3562ad0215987b15b9c16f73",
        "file": "TeXGyre-GUST-FONT-LICENSE.txt",
    },
    {
        "name": "Libertinus Math 7.051 (CTAN)",
        "url": f"{CTAN}/fonts/libertinus-fonts/otf/LibertinusMath-Regular.otf",
        "sha256": "e81bd44acbb7119c8f00128b36fecc5d980e10d2450a226ba52402ccf4da9d32",
        "file": "LibertinusMath-Regular.otf",
    },
    {
        "name": "Libertinus licence (SIL OFL 1.1)",
        "url": f"{CTAN}/fonts/libertinus-fonts/OFL.txt",
        "sha256": "9aeecc8107c489ec1ec0068b0313e531a760edf3493705b32ab8ab8215a8794e",
        "file": "Libertinus-OFL.txt",
    },
]


def fonts_dir() -> Path:
    env = os.environ.get("GRAVEN_FONTS")
    return Path(env) if env else Path(__file__).resolve().parent.parent / "fonts"


def download(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()


def write(dest: Path, name: str, body: bytes) -> bool:
    out = dest / name
    if out.exists() and out.read_bytes() == body:
        return False
    out.write_bytes(body)
    return True


def fetch(entry: dict, dest: Path) -> int:
    print(f"{entry['name']}: {entry['url']}")
    data = download(entry["url"])
    digest = hashlib.sha256(data).hexdigest()
    if digest != entry["sha256"]:
        raise SystemExit(f"  SHA-256 mismatch:\n    expected {entry['sha256']}\n    got      {digest}")
    if "file" in entry:  # a single file, not an archive
        written = write(dest, entry["file"], data)
        print(f"  {entry['file']}, {int(written)} written")
        return int(entry["file"].endswith((".otf", ".ttf")))
    t = tarfile.open(fileobj=io.BytesIO(data), mode="r:gz")
    files = {m.name: m for m in t.getmembers() if m.isfile()}
    fonts = [n for n in files
             if n.startswith(entry["folder"]) and n.endswith(entry["suffixes"])
             and not any(s in Path(n).name for s in entry.get("skip", ()))]
    if not fonts:
        raise SystemExit(f"  no fonts found under {entry['folder']}")
    written = sum(write(dest, Path(n).name, t.extractfile(files[n]).read()) for n in fonts)
    if "license" in entry:
        src, name = entry["license"]
        written += write(dest, name, t.extractfile(files[src]).read())
    print(f"  {len(fonts)} fonts, {written} files written")
    return len(fonts)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--dest", type=Path, help="fonts directory (default: $GRAVEN_FONTS or fonts/)")
    args = p.parse_args(argv)
    dest = args.dest or fonts_dir()
    dest.mkdir(parents=True, exist_ok=True)
    total = sum(fetch(e, dest) for e in PINNED)
    print(f"{total} fonts in {dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
