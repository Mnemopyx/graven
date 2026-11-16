//! The local source: the fonts on this machine, system and user, found in
//! the system's font folders, described once and kept in an index cache, so
//! later scans describe only files that are new or changed. Shared by
//! graven-fonts and Graven.
//!
//! System fonts are read only. User fonts live in the OS's per-user font
//! folder, where every application finds them; Graven installs font files
//! there (WOFF and WOFF2 converted to plain sfnt first) and removes them,
//! and keeps a provenance record for each file it installs in its own data
//! folder, so the font folder holds only fonts.

const std = @import("std");
const builtin = @import("builtin");
const fs = @import("graven_fontsearch");
const font = @import("graven_font");

const Io = std.Io;
const Allocator = std.mem.Allocator;
pub const Record = fs.Record;
pub const Scope = fs.Scope;

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

/// A font folder and whose fonts it holds.
pub const FontDir = struct { path: []const u8, scope: Scope };

/// The folder user fonts are installed in: the OS's per-user font folder.
pub fn userDir(a: Allocator) ![]const u8 {
    const home = env("HOME");
    return switch (builtin.os.tag) {
        .windows => std.fs.path.join(a, &.{ env("LOCALAPPDATA") orelse return error.NoHome, "Microsoft", "Windows", "Fonts" }),
        .macos => std.fs.path.join(a, &.{ home orelse return error.NoHome, "Library", "Fonts" }),
        else => if (env("XDG_DATA_HOME")) |x| std.fs.path.join(a, &.{ x, "fonts" }) else std.fs.path.join(a, &.{ home orelse return error.NoHome, ".local", "share", "fonts" }),
    };
}

/// The system's font folders, each with its scope; the user's own first.
pub fn fontDirs(a: Allocator) ![]const FontDir {
    var dirs: std.ArrayList(FontDir) = .empty;
    if (userDir(a)) |u| try dirs.append(a, .{ .path = u, .scope = .user }) else |_| {}
    const home = env("HOME");
    switch (builtin.os.tag) {
        .windows => try dirs.append(a, .{ .path = try std.fs.path.join(a, &.{ env("WINDIR") orelse "C:\\Windows", "Fonts" }), .scope = .system }),
        .macos => {
            try dirs.append(a, .{ .path = "/System/Library/Fonts", .scope = .system });
            try dirs.append(a, .{ .path = "/Library/Fonts", .scope = .system });
        },
        else => {
            // The older per-user folder, still read by fontconfig.
            if (home) |h| try dirs.append(a, .{ .path = try std.fs.path.join(a, &.{ h, ".fonts" }), .scope = .user });
            try dirs.append(a, .{ .path = "/usr/share/fonts", .scope = .system });
            try dirs.append(a, .{ .path = "/usr/local/share/fonts", .scope = .system });
        },
    }
    return dirs.items;
}

/// Where the index is kept ($GRAVEN_FONTS_INDEX overrides it).
pub fn indexPath(a: Allocator) ![]const u8 {
    if (env("GRAVEN_FONTS_INDEX")) |p| return p;
    return switch (builtin.os.tag) {
        .windows => std.fs.path.join(a, &.{ env("LOCALAPPDATA") orelse return error.NoHome, "Graven", "fonts-index.json" }),
        .macos => std.fs.path.join(a, &.{ env("HOME") orelse return error.NoHome, "Library", "Caches", "Graven", "fonts-index.json" }),
        else => if (env("XDG_CACHE_HOME")) |x|
            std.fs.path.join(a, &.{ x, "graven", "fonts-index.json" })
        else
            std.fs.path.join(a, &.{ env("HOME") orelse return error.NoHome, ".cache", "graven", "fonts-index.json" }),
    };
}

/// Where Graven keeps the provenance of the fonts it installed.
pub fn provenancePath(a: Allocator) ![]const u8 {
    return switch (builtin.os.tag) {
        .windows => std.fs.path.join(a, &.{ env("LOCALAPPDATA") orelse return error.NoHome, "Graven", "installed-fonts.json" }),
        .macos => std.fs.path.join(a, &.{ env("HOME") orelse return error.NoHome, "Library", "Application Support", "Graven", "installed-fonts.json" }),
        else => if (env("XDG_DATA_HOME")) |x|
            std.fs.path.join(a, &.{ x, "graven", "installed-fonts.json" })
        else
            std.fs.path.join(a, &.{ env("HOME") orelse return error.NoHome, ".local", "share", "graven", "installed-fonts.json" }),
    };
}

pub fn isFontFile(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    for ([_][]const u8{ ".ttf", ".otf", ".ttc", ".otc", ".woff", ".woff2" }) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

/// The index as saved, its strings from `a`; empty when there is none yet
/// (or it is of another version).
pub fn load(io: Io, a: Allocator) []Record {
    const path = indexPath(a) catch return &.{};
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 30)) catch return &.{};
    return fs.loadIndex(a, bytes) orelse &.{};
}

/// What a scan did.
pub const Report = struct {
    described: usize = 0,
    kept: usize = 0,
    failed: usize = 0,
    path: []const u8 = "",
};

/// Finds the system's and the user's fonts, describes what is new or
/// changed since the saved index, saves the index, and returns its records
/// (from `a`).
pub fn build(io: Io, gpa: Allocator, a: Allocator, report: ?*Report) ![]Record {
    const old = load(io, a);
    // Old records by location, to keep those whose file has not changed.
    var by_path: std.StringHashMapUnmanaged(std.ArrayList(Record)) = .empty;
    for (old) |r| {
        const e = try by_path.getOrPut(a, r.location);
        if (!e.found_existing) e.value_ptr.* = .empty;
        try e.value_ptr.append(a, r);
    }
    var rep: Report = .{};
    var records: std.ArrayList(Record) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (try fontDirs(a)) |root| {
        var dir = Io.Dir.cwd().openDir(io, root.path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!isFontFile(entry.basename)) continue;
            const path = try std.fs.path.join(a, &.{ root.path, entry.path });
            // A folder inside another (XDG_DATA_HOME under /usr/share) once.
            if ((try seen.getOrPut(a, path)).found_existing) continue;
            const st = entry.dir.statFile(io, entry.basename, .{}) catch continue;
            const stamp: u64 = st.size ^ (@as(u64, @truncate(@as(u96, @bitCast(st.mtime.toNanoseconds())))) *% 0x9E3779B97F4A7C15);
            if (by_path.get(path)) |list| if (list.items.len > 0 and list.items[0].stamp == stamp) {
                for (list.items) |r| {
                    var k = r;
                    k.scope = root.scope;
                    try records.append(a, k);
                }
                rep.kept += list.items.len;
                continue;
            };
            const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20)) catch {
                rep.failed += 1;
                continue;
            };
            defer gpa.free(bytes);
            const n = font.faceCount(bytes);
            for (0..n) |k| {
                const face = font.Face.init(gpa, bytes, @intCast(k)) catch {
                    rep.failed += 1;
                    continue;
                };
                defer face.deinit();
                var r = fs.describe(a, face, "local", path, @intCast(k), stamp) catch {
                    rep.failed += 1;
                    continue;
                };
                r.scope = root.scope;
                try records.append(a, r);
                rep.described += 1;
            }
        }
    }
    rep.path = try indexPath(a);
    if (std.fs.path.dirname(rep.path)) |d| Io.Dir.cwd().createDirPath(io, d) catch {};
    const out = try fs.saveIndex(gpa, records.items);
    defer gpa.free(out);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rep.path, .data = out });
    if (report) |r| r.* = rep;
    return records.items;
}

/// The bytes of the file a local record describes, from `gpa`.
pub fn read(io: Io, gpa: Allocator, r: *const Record) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, r.location, gpa, .limited(256 << 20));
}

// Provenance ---------------------------------------------------------------------

/// Where an installed file came from.
pub const Provenance = struct {
    /// The installed file's SHA-256, in hex.
    sha256: []const u8,
    /// The installed file's path.
    file: []const u8,
    /// Where it was installed from: a path, or a URL.
    from: []const u8,
    /// The container it came in (truetype, cff, collection, woff, woff2).
    container: []const u8,
    /// The SHA-256 of what came in, when it was converted.
    original_sha256: []const u8 = "",
    /// The day it was installed, YYYY-MM-DD.
    installed: []const u8,
    family: []const u8,
    style: []const u8,
    /// The licence as the font states it (name IDs 13 and 14).
    licence_text: []const u8 = "",
    licence_url: []const u8 = "",
};

const ProvenanceFile = struct { version: u32 = 1, fonts: []const Provenance };

/// The provenance records, from `a`; empty when there are none.
pub fn loadProvenance(io: Io, a: Allocator) []Provenance {
    const path = provenancePath(a) catch return &.{};
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 << 20)) catch return &.{};
    const f = std.json.parseFromSliceLeaky(ProvenanceFile, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return &.{};
    return @constCast(f.fonts);
}

fn saveProvenance(io: Io, gpa: Allocator, a: Allocator, list: []const Provenance) !void {
    const path = try provenancePath(a);
    if (std.fs.path.dirname(path)) |d| try Io.Dir.cwd().createDirPath(io, d);
    const out = try std.json.Stringify.valueAlloc(gpa, ProvenanceFile{ .fonts = list }, .{ .whitespace = .indent_2 });
    defer gpa.free(out);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out });
}

/// The provenance of an installed file, when Graven installed it.
pub fn provenanceOf(list: []const Provenance, file: []const u8) ?*const Provenance {
    for (list) |*p| if (std.mem.eql(u8, p.file, file)) return p;
    return null;
}

fn sha256Hex(a: Allocator, bytes: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.allocPrint(a, "{x}", .{&digest});
}

fn today(io: Io, a: Allocator) ![]const u8 {
    const secs = Io.Timestamp.now(io, .real).toSeconds();
    const day = (std.time.epoch.EpochSeconds{ .secs = @intCast(@max(secs, 0)) }).getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 });
}

// Installing and removing ----------------------------------------------------------

/// A file name for a font: its family and style, with what file systems
/// refuse (and spaces) left out; a variable font's axes in brackets after
/// its family, as variable fonts are named ("Geist[wght].ttf").
fn fileName(a: Allocator, family: []const u8, style: ?[]const u8, axes: []const [4]u8, ext: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (axes.len > 0) {
        try appendClean(a, &out, family);
        if (out.items.len == 0) try out.appendSlice(a, "font");
        try out.append(a, '[');
        for (axes, 0..) |t, k| {
            if (k > 0) try out.append(a, ',');
            try appendClean(a, &out, std.mem.trimEnd(u8, &t, " "));
        }
        try out.append(a, ']');
        try out.appendSlice(a, ext);
        return out.items;
    }
    for ([_]?[]const u8{ family, style }, 0..) |part, k| {
        const p = part orelse continue;
        if (p.len == 0) continue;
        if (k > 0 and out.items.len > 0) try out.append(a, '-');
        for (p) |c| switch (c) {
            ' ', '/', '\\', ':', '*', '?', '"', '<', '>', '|' => {},
            else => if (c >= 0x20 and c != 0x7F) try out.append(a, c),
        };
    }
    if (out.items.len == 0) try out.appendSlice(a, "font");
    try out.appendSlice(a, ext);
    return out.items;
}

fn appendClean(a: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        ' ', '/', '\\', ':', '*', '?', '"', '<', '>', '|' => {},
        else => if (c >= 0x20 and c != 0x7F) try out.append(a, c),
    };
}

pub const InstallOptions = struct {
    /// Where the font came from, for its provenance (a path or a URL).
    from: []const u8,
    /// Install over a user font of the same family and style.
    replace: bool = false,
};

pub const Installed = struct {
    outcome: enum { installed, already_installed, replaced },
    file: []const u8,
    family: []const u8,
    /// The first face's style; `styles` has every face's.
    style: []const u8,
    faces: u32,
    styles: []const []const u8 = &.{},
    /// A variable font's axes ("wght"…); empty for a static one.
    axes: []const [4]u8 = &.{},
    container: font.container.Kind,
    /// User fonts it replaced (their files, now removed).
    replaced: []const []const u8 = &.{},
    /// A system font with the same family and style: applications may take
    /// either.
    shadows_system: bool = false,
};

/// What an install brought, in words: "Geist Bold", "Geist (2 faces:
/// Black, ExtraBold)", "Geist, variable (wght; default Regular)".
pub fn describeInstalled(buf: []u8, r: Installed) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    if (r.axes.len > 0) {
        w.print("{s}, variable (", .{r.family}) catch {};
        for (r.axes, 0..) |t, k| w.print("{s}{s}", .{ if (k > 0) ", " else "", std.mem.trimEnd(u8, &t, " ") }) catch {};
        w.print("; default {s})", .{r.style}) catch {};
    } else if (r.faces > 1) {
        w.print("{s} ({d} faces: ", .{ r.family, r.faces }) catch {};
        for (r.styles, 0..) |st, k| w.print("{s}{s}", .{ if (k > 0) ", " else "", st }) catch {};
        w.writeAll(")") catch {};
    } else w.print("{s} {s}", .{ r.family, r.style }) catch {};
    return w.buffered();
}

pub const InstallError = error{
    /// Not a font Graven can read.
    NotAFont,
    /// A user font of the same family and style is installed, with other
    /// contents; `InstallOptions.replace` installs over it.
    Conflict,
};

/// Installs a font's bytes as a user font: converted to plain sfnt, named
/// by family and style, written into the user's font folder, and its
/// provenance recorded. `records` is the current index (for conflicts).
/// Strings from `a`. The index is not rebuilt here.
pub fn install(io: Io, gpa: Allocator, a: Allocator, bytes: []const u8, records: []const Record, opts: InstallOptions) !Installed {
    const kind = font.container.kindOf(bytes);
    const sfnt = font.container.toSfnt(a, bytes) catch return InstallError.NotAFont;
    const faces = font.container.faceCount(sfnt);
    if (faces == 0) return InstallError.NotAFont;
    const face = font.Face.init(gpa, sfnt, 0) catch return InstallError.NotAFont;
    defer face.deinit();
    const desc = try fs.describe(a, face, "local", "", 0, 0);
    const ext = font.container.extension(sfnt).?;
    const dir = try userDir(a);
    const axes = try face.axisTags(a);
    const name = try fileName(a, desc.family, if (faces == 1) desc.style else null, axes, ext);
    // Every face's style, for saying what came in.
    const styles = try a.alloc([]const u8, faces);
    styles[0] = desc.style;
    for (1..faces) |k| {
        const fk = font.Face.init(gpa, sfnt, @intCast(k)) catch return InstallError.NotAFont;
        defer fk.deinit();
        styles[k] = (try fs.describe(a, fk, "local", "", @intCast(k), 0)).style;
    }
    const file = try std.fs.path.join(a, &.{ dir, name });
    const sha = try sha256Hex(a, sfnt);

    var result: Installed = .{ .outcome = .installed, .file = file, .family = desc.family, .style = desc.style, .faces = faces, .styles = styles, .axes = axes, .container = kind };
    // The same file already there: nothing to do but record where it came from.
    const existing: ?[]u8 = Io.Dir.cwd().readFileAlloc(io, file, a, .limited(256 << 20)) catch null;
    if (existing) |e| if (std.mem.eql(u8, try sha256Hex(a, e), sha)) {
        result.outcome = .already_installed;
    };
    // Other user fonts of the same family and style, and system ones.
    var others: std.ArrayList([]const u8) = .empty;
    for (records) |r| {
        if (!std.ascii.eqlIgnoreCase(r.family, desc.family) or !std.ascii.eqlIgnoreCase(r.style, desc.style)) continue;
        switch (r.scope) {
            .system => result.shadows_system = true,
            .user => if (!std.mem.eql(u8, r.location, file)) try others.append(a, r.location),
            .remote => {},
        }
    }
    if (result.outcome != .already_installed and (others.items.len > 0 or existing != null)) {
        if (!opts.replace) return InstallError.Conflict;
        result.outcome = .replaced;
    }
    if (result.outcome != .already_installed) {
        try Io.Dir.cwd().createDirPath(io, dir);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = sfnt });
        for (others.items) |o| Io.Dir.cwd().deleteFile(io, o) catch {};
        result.replaced = others.items;
    }

    // Provenance: this file's record replaces any earlier one, and those of
    // the files it replaced go.
    var list: std.ArrayList(Provenance) = .empty;
    for (loadProvenance(io, a)) |p| {
        if (std.mem.eql(u8, p.file, file)) continue;
        const gone = for (others.items) |o| {
            if (std.mem.eql(u8, p.file, o)) break true;
        } else false;
        if (!gone) try list.append(a, p);
    }
    const converted = kind.isWeb();
    try list.append(a, .{
        .sha256 = sha,
        .file = file,
        .from = opts.from,
        .container = @tagName(kind),
        .original_sha256 = if (converted) try sha256Hex(a, bytes) else "",
        .installed = try today(io, a),
        .family = desc.family,
        .style = desc.style,
        .licence_text = desc.licence_text,
        .licence_url = desc.licence_url,
    });
    try saveProvenance(io, gpa, a, list.items);
    return result;
}

pub const RemoveError = error{
    /// No font of that name is installed.
    NotInstalled,
    /// Only system fonts have that name, or the file is not a user font:
    /// Graven does not remove system fonts.
    SystemFont,
};

/// The faces a font file holds, as indexes into `records` (by face index).
pub fn facesInFile(a: Allocator, records: []const Record, file: []const u8) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    for (records, 0..) |r, i| if (std.mem.eql(u8, r.location, file)) try out.append(a, i);
    std.mem.sort(usize, out.items, records, struct {
        fn f(recs: []const Record, x: usize, y: usize) bool {
            return recs[x].index < recs[y].index;
        }
    }.f);
    return out.items;
}

/// Removes one user font file, every face in it, and its provenance. A
/// file the index does not know as a user font is refused.
pub fn removeFile(io: Io, gpa: Allocator, a: Allocator, records: []const Record, file: []const u8) !void {
    const user = for (records) |r| {
        if (std.mem.eql(u8, r.location, file)) break r.scope == .user;
    } else return RemoveError.NotInstalled;
    if (!user) return RemoveError.SystemFont;
    try Io.Dir.cwd().deleteFile(io, file);
    var list: std.ArrayList(Provenance) = .empty;
    for (loadProvenance(io, a)) |p| {
        if (!std.mem.eql(u8, p.file, file)) try list.append(a, p);
    }
    try saveProvenance(io, gpa, a, list.items);
}

/// Removes the user fonts of `family` (and `style`, when given): their
/// files, and their provenance. A collection goes whole. Returns the files
/// removed (from `a`). The index is not rebuilt here.
pub fn remove(io: Io, gpa: Allocator, a: Allocator, records: []const Record, family: []const u8, style: ?[]const u8) ![]const []const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    var system = false;
    for (records) |r| {
        if (!std.ascii.eqlIgnoreCase(r.family, family)) continue;
        if (style) |s| if (!std.ascii.eqlIgnoreCase(r.style, s)) continue;
        if (r.scope != .user) {
            system = system or r.scope == .system;
            continue;
        }
        const dup = for (files.items) |f| {
            if (std.mem.eql(u8, f, r.location)) break true;
        } else false;
        if (!dup) try files.append(a, r.location);
    }
    if (files.items.len == 0) return if (system) RemoveError.SystemFont else RemoveError.NotInstalled;
    for (files.items) |f| try removeFile(io, gpa, a, records, f);
    return files.items;
}

test "file names come from family and style, without what file systems refuse" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("SourceSerif4-SemiboldItalic.otf", try fileName(a, "Source Serif 4", "Semibold Italic", &.{}, ".otf"));
    try std.testing.expectEqualStrings("NotoSans.ttc", try fileName(a, "Noto: Sans", null, &.{}, ".ttc"));
    try std.testing.expectEqualStrings("font.ttf", try fileName(a, "", "", &.{}, ".ttf"));
    try std.testing.expectEqualStrings("Ünïcode-Bold.ttf", try fileName(a, "Ünïcode", "Bold", &.{}, ".ttf"));
    try std.testing.expectEqualStrings("Geist[wght,ital].ttf", try fileName(a, "Geist", "Regular", &.{ "wght".*, "ital".* }, ".ttf"));
}
