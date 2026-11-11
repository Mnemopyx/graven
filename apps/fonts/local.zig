//! The local source: installed fonts, found in the system's font folders,
//! described once and kept in an index cache, so later scans describe only
//! files that are new or changed. Shared by graven-fonts and Graven.

const std = @import("std");
const builtin = @import("builtin");
const fs = @import("graven_fontsearch");
const font = @import("graven_font");

const Io = std.Io;
const Allocator = std.mem.Allocator;
pub const Record = fs.Record;

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

/// The system's font folders, user folders included.
pub fn fontDirs(a: Allocator) ![]const []const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    const home = env("HOME");
    switch (builtin.os.tag) {
        .windows => {
            try dirs.append(a, try std.fs.path.join(a, &.{ env("WINDIR") orelse "C:\\Windows", "Fonts" }));
            if (env("LOCALAPPDATA")) |l| try dirs.append(a, try std.fs.path.join(a, &.{ l, "Microsoft", "Windows", "Fonts" }));
        },
        .macos => {
            try dirs.append(a, "/System/Library/Fonts");
            try dirs.append(a, "/Library/Fonts");
            if (home) |h| try dirs.append(a, try std.fs.path.join(a, &.{ h, "Library", "Fonts" }));
        },
        else => {
            try dirs.append(a, "/usr/share/fonts");
            try dirs.append(a, "/usr/local/share/fonts");
            if (env("XDG_DATA_HOME")) |x| try dirs.append(a, try std.fs.path.join(a, &.{ x, "fonts" })) else if (home) |h| try dirs.append(a, try std.fs.path.join(a, &.{ h, ".local", "share", "fonts" }));
            if (home) |h| try dirs.append(a, try std.fs.path.join(a, &.{ h, ".fonts" }));
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

fn isFontFile(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    for ([_][]const u8{ ".ttf", ".otf", ".ttc", ".otc" }) |e| {
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

/// Finds installed fonts, describes what is new or changed since the
/// saved index, saves the index, and returns its records (from `a`).
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
    for (try fontDirs(a)) |root| {
        var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!isFontFile(entry.basename)) continue;
            const path = try std.fs.path.join(a, &.{ root, entry.path });
            const st = entry.dir.statFile(io, entry.basename, .{}) catch continue;
            const stamp: u64 = st.size ^ (@as(u64, @truncate(@as(u96, @bitCast(st.mtime.toNanoseconds())))) *% 0x9E3779B97F4A7C15);
            if (by_path.get(path)) |list| if (list.items.len > 0 and list.items[0].stamp == stamp) {
                try records.appendSlice(a, list.items);
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
                const r = fs.describe(a, face, "local", path, @intCast(k), stamp) catch {
                    rep.failed += 1;
                    continue;
                };
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
