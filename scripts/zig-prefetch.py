#!/usr/bin/env python3
"""Put every Zig package Graven's build needs into the Zig cache, without Zig's own fetch.

Behind a cloud session's agent proxy, `zig build` cannot fetch: its git client
fails (ReadFailed) and its HTTP downloads are reset. This walks build.zig.zon,
and each package's own build.zig.zon in turn, and gets each package itself:
a git dependency is checked out into a folder, an archive is downloaded with
curl (a GitHub archive, refused by the proxy, is made with `git archive`
instead), and `zig fetch` hashes and caches it; the hash must be the one
declared. Zig 0.17 caches a local archive with its top folder kept, which the
build then rejects, so those cache entries are packed again without it.

  python3 scripts/zig-prefetch.py [--zig ZIG] [--root DIR] [--all]

--all also fetches DVUI's lazy backends Graven does not build (raylib, wio …).
Packages already in the cache (~/.cache/zig/p/<hash>.tar.gz) are skipped, so a
second run is quick. A lazy package that cannot be cached is a warning (some
never are asked for; the build says if one is); any other failure, exit status 1.
scripts/cloud-setup.sh runs this when a cloud session's machine is made.
"""
import argparse, os, re, shutil, subprocess, sys, tarfile, tempfile, zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

# DVUI's lazy dependencies that Graven's build never asks for (it uses the SDL3 backend).
SKIP = {"raylib", "raylib_zig", "wio", "opengl", "vulkan", "raygui", "win32", "zigwin32",
        "accesskit", "zglfw", "zgl", "pugl", "web", "dx11"}

DEP = re.compile(r'\.(@"[^"]+"|[A-Za-z_][\w]*)\s*=\s*\.\{([^{}]*)\}', re.S)


def field(body, name):
    m = re.search(r'\.' + name + r'\s*=\s*"([^"]*)"', body)
    return m.group(1) if m else None


def deps_of(zon_text):
    """(name, url, hash, lazy) for each remote dependency in a build.zig.zon."""
    zon_text = re.sub(r'"(?:\\.|[^"\\])*"|//[^\n]*',
                      lambda m: m.group(0) if m.group(0)[0] == '"' else '', zon_text)
    m = re.search(r'\.dependencies\s*=\s*\.\{', zon_text)
    if not m:
        return []
    out = []
    for d in DEP.finditer(zon_text, m.end()):
        url, h = field(d.group(2), "url"), field(d.group(2), "hash")
        if url and h:
            lazy = re.search(r'\.lazy\s*=\s*true', d.group(2)) is not None
            out.append((d.group(1).strip('@"'), url, h, lazy))
    return out


def run(*cmd, cwd=None):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"{' '.join(map(str, cmd))}: {r.stderr.strip()[-400:]}")
    return r.stdout


def git_fetch(repo, rev, g):
    """Commit (or tag) `rev` of `repo` into a new bare repository g, as FETCH_HEAD."""
    run("git", "init", "-q", "--bare", g)
    try:
        run("git", "--git-dir", g, "fetch", "-q", "--depth", "1", repo, rev)
    except RuntimeError:  # a tag name rather than a commit
        run("git", "--git-dir", g, "fetch", "-q", "--depth", "1", repo, f"refs/tags/{rev}")


def git_tree(repo, rev, dest):
    """The tree of `rev` in `repo`, checked out into dest, as Zig's own git fetch has it."""
    g = dest.parent / (dest.name + ".git")
    git_fetch(repo, rev, g)
    dest.mkdir()
    run("git", "--git-dir", g, "--work-tree", dest, "checkout", "-q", "FETCH_HEAD", "--", ".")
    shutil.rmtree(g)


GITHUB_ARCHIVE = re.compile(
    r'https://github\.com/([^/]+/[^/]+)/archive/(?:refs/(?:tags|heads)/)?(.+?)\.(tar\.gz|tgz|zip)$')


def archive_ext(url):
    for ext in (".tar.gz", ".tgz", ".tar.xz", ".tar.zst", ".tar", ".zip"):
        if url.split("?")[0].endswith(ext):
            return ext
    return ".tar.gz"


def get(url, dest):
    """The package at url: a plain folder at dest (git), or an archive file (returned)."""
    if url.startswith("git+"):
        repo, _, rev = url[4:].partition("#")
        git_tree(repo.split("?")[0], rev, dest)
        return None
    ext = archive_ext(url)
    archive = dest.parent / (dest.name + ext)
    m = GITHUB_ARCHIVE.match(url)
    if m:  # GitHub's archive downloads are refused through the proxy; git is not
        g = dest.parent / (dest.name + ".git")
        git_fetch(f"https://github.com/{m.group(1)}", m.group(2), g)
        fmt = "zip" if ext == ".zip" else "tar.gz"
        run("git", "--git-dir", g, "archive", f"--format={fmt}", "--prefix=pkg/", "-o", archive, "FETCH_HEAD")
        shutil.rmtree(g)
    else:
        run("curl", "-fsSL", "--retry", "4", "--retry-all-errors", "-o", archive, url)
    return archive


def zon_in_archive(archive):
    """The package's own build.zig.zon text, from an archive with one top folder."""
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as z:
            for n in z.namelist():
                if n.count("/") == 1 and n.endswith("/build.zig.zon"):
                    return z.read(n).decode()
        return None
    with tarfile.open(archive) as t:
        for m in t.getmembers():
            if m.name.lstrip("./").count("/") == 1 and m.name.endswith("/build.zig.zon"):
                return t.extractfile(m).read().decode()
    return None


def repack(cache, h):
    """Zig 0.17's `zig fetch <archive file>` prints the right hash but caches the archive's
    top folder too (p/<h>.tar.gz holding <h>/<top>/...), and the build then finds a hash
    mismatch. Re-pack it as <h>/... ."""
    p = cache / f"{h}.tar.gz"
    with tarfile.open(p) as t:
        names = t.getnames()
    tops = {n.split("/")[1] for n in names if n.count("/") >= 1 and n.split("/")[1]}
    if len(tops) != 1 or not any(n.count("/") >= 2 for n in names):
        return
    top = tops.pop()
    tmp = Path(tempfile.mkdtemp(prefix="zig-repack-", dir=cache.parent))
    try:
        with tarfile.open(p) as t:
            t.extractall(tmp, filter="tar")
        inner = tmp / h / top
        if not inner.is_dir():
            return
        (tmp / "x").mkdir()
        inner.rename(tmp / "x" / h)
        new = tmp / "new.tar.gz"
        run("tar", "-czf", new, "-C", tmp / "x", h)
        new.replace(p)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zig", default=shutil.which("zig") or "zig")
    ap.add_argument("--root", default=Path(__file__).resolve().parent.parent)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--jobs", type=int, default=6)
    a = ap.parse_args()

    cache = Path(os.environ.get("ZIG_GLOBAL_CACHE_DIR", Path.home() / ".cache/zig")) / "p"
    work = Path(tempfile.mkdtemp(prefix="zig-prefetch-"))
    seen, failed, fetched, lazy_missing = set(), [], 0, 0

    def one(dep):
        name, url, h, _ = dep
        dest = work / h
        try:
            archive = get(url, dest)
            if archive is None:
                zon = dest / "build.zig.zon"
                zon = zon.read_text() if zon.exists() else None
                got = run(a.zig, "fetch", dest).strip()
            else:
                zon = zon_in_archive(archive)
                got = run(a.zig, "fetch", archive).strip()
                archive.unlink()
            if got != h:
                shutil.rmtree(cache / got, ignore_errors=True)
                (cache / f"{got}.tar.gz").unlink(missing_ok=True)
                raise RuntimeError(f"hash {got}, declared {h}")
            if archive is not None:
                repack(cache, h)
            return dep, deps_of(zon) if zon else [], None
        except Exception as e:  # noqa: BLE001 - reported and counted
            return dep, [], str(e)
        finally:
            shutil.rmtree(dest, ignore_errors=True)

    def cached(h):
        return (cache / f"{h}.tar.gz").exists() or (cache / h).is_dir()

    def nested_of_cached(h):
        p = cache / f"{h}.tar.gz"
        if not p.exists():
            return []
        with tarfile.open(p) as t:
            for m in t.getmembers():
                if m.name.count("/") == 1 and m.name.endswith("/build.zig.zon") or m.name == "build.zig.zon":
                    return deps_of(t.extractfile(m).read().decode())
        return []

    todo = deps_of((Path(a.root) / "build.zig.zon").read_text())
    with ThreadPoolExecutor(a.jobs) as pool:
        while todo:
            batch = []
            for d in todo:
                if d[2] in seen or (not a.all and d[0] in SKIP):
                    continue
                seen.add(d[2])
                batch.append(d)
            todo = []
            fresh = [d for d in batch if not cached(d[2])]
            for d in batch:
                if cached(d[2]):
                    todo += nested_of_cached(d[2])
            for dep, sub, err in pool.map(one, fresh):
                if err and dep[3]:  # lazy: perhaps never asked for; the build will say
                    lazy_missing += 1
                    print(f"warning: lazy {dep[0]} ({dep[1]}) not cached: {err}", file=sys.stderr)
                elif err:
                    failed.append(dep[0])
                    print(f"FAILED {dep[0]} ({dep[1]}): {err}", file=sys.stderr)
                else:
                    fetched += 1
                    print(f"cached {dep[0]}")
                    todo += sub
    shutil.rmtree(work, ignore_errors=True)
    print(f"{len(seen)} packages: {fetched} fetched now, "
          f"{len(seen) - fetched - len(failed) - lazy_missing} already cached, "
          f"{lazy_missing} lazy ones not cached, {len(failed)} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
