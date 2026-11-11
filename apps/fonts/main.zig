//! graven-fonts: find, compare and choose fonts. A separate tool on the font
//! search library; Graven opens it, and it runs on its own.
//!
//! This is the local source: installed fonts, found in the system's font
//! folders, described once and kept in an index cache, so later runs only
//! describe files that are new or changed. Remote repositories come as
//! addons through the same `Source` interface.

const std = @import("std");
const builtin = @import("builtin");
const fs = @import("graven_fontsearch");
const font = @import("graven_font");

const Record = fs.Record;

const usage =
    \\usage: graven-fonts index
    \\         Finds installed fonts, describes new and changed ones, and saves the index.
    \\       graven-fonts search [words] [options]
    \\         Lists fonts whose family or style holds every word, best first.
    \\         --like "Family" [--style "Style"]  rank by likeness to that font
    \\         --covers TEXT        must have every character of TEXT
    \\         --some               ... or let fonts lacking some through, ranked by how many
    \\         --math | --italic | --upright | --mono | --serif | --sans | --variable
    \\         --weight MIN-MAX     e.g. 300-500
    \\         --embed installable|editable|print   at least this embedding permission
    \\         --licence ofl|apache|ufl|gpl|other|unstated   (repeatable)
    \\         --limit N            (default 25)
    \\       graven-fonts show "Family" [--style "Style"]
    \\         Everything known about a font, with where each fact came from.
    \\
    \\Licence terms are shown as each font states them. Graven does not set
    \\them, and does not judge what your own licence allows.
    \\
;

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

/// The system's font folders, user folders included.
fn fontDirs(a: std.mem.Allocator) ![]const []const u8 {
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

/// Where the index is kept.
fn indexPath(a: std.mem.Allocator) ![]const u8 {
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

/// The index, as saved; empty when there is none yet.
fn loadIndex(init: std.process.Init, a: std.mem.Allocator) ![]Record {
    const path = try indexPath(a);
    const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .limited(1 << 30)) catch return &.{};
    return fs.loadIndex(a, bytes) orelse &.{};
}

/// Finds installed fonts, describes what is new or changed, saves the
/// index, and returns its records.
fn buildIndex(init: std.process.Init, a: std.mem.Allocator, quiet: bool) ![]Record {
    const io = init.io;
    const gpa = init.gpa;
    const old = try loadIndex(init, a);
    // Old records by location, to keep those whose file has not changed.
    var by_path: std.StringHashMapUnmanaged(std.ArrayList(Record)) = .empty;
    for (old) |r| {
        const e = try by_path.getOrPut(a, r.location);
        if (!e.found_existing) e.value_ptr.* = .empty;
        try e.value_ptr.append(a, r);
    }
    var records: std.ArrayList(Record) = .empty;
    var described: usize = 0;
    var kept: usize = 0;
    var failed: usize = 0;
    const t0: std.Io.Timestamp = .now(io, .awake);
    for (try fontDirs(a)) |root| {
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
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
                kept += list.items.len;
                continue;
            };
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20)) catch {
                failed += 1;
                continue;
            };
            defer gpa.free(bytes);
            const n = font.faceCount(bytes);
            for (0..n) |k| {
                const face = font.Face.init(gpa, bytes, @intCast(k)) catch {
                    failed += 1;
                    continue;
                };
                defer face.deinit();
                const r = fs.describe(a, face, "local", path, @intCast(k), stamp) catch {
                    failed += 1;
                    continue;
                };
                try records.append(a, r);
                described += 1;
            }
        }
    }
    const index_path = try indexPath(a);
    if (std.fs.path.dirname(index_path)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
    const out = try fs.saveIndex(gpa, records.items);
    defer gpa.free(out);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = out });
    if (!quiet) {
        const ms = @as(f64, @floatFromInt(t0.untilNow(io, .awake).toNanoseconds())) / 1e6;
        std.debug.print("{d} faces: {d} described, {d} unchanged, {d} unreadable, in {d:.0} ms\nindex: {s}\n", .{ records.items.len, described, kept, failed, ms, index_path });
    }
    return records.items;
}

/// The index, built first if there is none.
fn indexedRecords(init: std.process.Init, a: std.mem.Allocator) ![]Record {
    const r = try loadIndex(init, a);
    if (r.len > 0) return r;
    std.debug.print("No font index yet: building it.\n", .{});
    return buildIndex(init, a, false);
}

fn utf8Codepoints(a: std.mem.Allocator, s: []const u8) ![]u21 {
    var out: std.ArrayList(u21) = .empty;
    var it = (std.unicode.Utf8View.init(s) catch return error.BadText).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == ' ') continue;
        if (std.mem.indexOfScalar(u21, out.items, cp) == null) try out.append(a, cp);
    }
    return out.items;
}

fn search(init: std.process.Init, a: std.mem.Allocator, args: []const []const u8) !void {
    var q: fs.Query = .{ .limit = 25 };
    var words: std.ArrayList(u8) = .empty;
    var like_family: ?[]const u8 = null;
    var like_style: ?[]const u8 = null;
    var licences: std.ArrayList(fs.Licence) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const next = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, arg, "--like")) {
            like_family = next;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--style")) {
            like_style = next;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--covers")) {
            q.covers = try utf8Codepoints(a, next);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--some")) {
            q.allow_missing = true;
        } else if (std.mem.eql(u8, arg, "--math")) {
            q.math = true;
        } else if (std.mem.eql(u8, arg, "--italic")) {
            q.italic = true;
        } else if (std.mem.eql(u8, arg, "--upright")) {
            q.italic = false;
        } else if (std.mem.eql(u8, arg, "--mono")) {
            q.monospace = true;
        } else if (std.mem.eql(u8, arg, "--serif")) {
            q.serif = true;
        } else if (std.mem.eql(u8, arg, "--sans")) {
            q.serif = false;
        } else if (std.mem.eql(u8, arg, "--variable")) {
            q.variable = true;
        } else if (std.mem.eql(u8, arg, "--weight")) {
            const dash = std.mem.indexOfScalar(u8, next, '-') orelse return error.BadWeight;
            q.weight = .{ try std.fmt.parseFloat(f32, next[0..dash]), try std.fmt.parseFloat(f32, next[dash + 1 ..]) };
            i += 1;
        } else if (std.mem.eql(u8, arg, "--embed")) {
            q.embedding = if (std.mem.eql(u8, next, "print")) .preview_print else std.meta.stringToEnum(fs.Embedding, next) orelse return error.BadEmbedding;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--licence") or std.mem.eql(u8, arg, "--license")) {
            try licences.append(a, std.meta.stringToEnum(fs.Licence, next) orelse return error.BadLicence);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            q.limit = try std.fmt.parseInt(usize, next, 10);
            i += 1;
        } else {
            if (words.items.len > 0) try words.append(a, ' ');
            try words.appendSlice(a, arg);
        }
    }
    q.words = words.items;
    q.licences = licences.items;
    const all = try indexedRecords(init, a);
    if (like_family) |fam| {
        const k = fs.find(all, fam, like_style) orelse {
            std.debug.print("No installed font is called \"{s}\"{s}{s}.\n", .{ fam, if (like_style != null) " " else "", like_style orelse "" });
            std.process.exit(1);
        };
        q.like = &all[k];
        std.debug.print("Like {s} {s}:\n", .{ all[k].family, all[k].style });
    }
    const hits = try fs.search(a, all, q);
    if (hits.len == 0) {
        std.debug.print("No fonts match.\n", .{});
        return;
    }
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const w = &out.interface;
    for (hits) |h| {
        const r = &all[h.index];
        var label_buf: [160]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "{s} {s}", .{ r.family, r.style }) catch r.family;
        try w.print("{s:<44}", .{label});
        if (h.distance) |d| try w.print("  {d:>5.2}", .{d});
        if (q.covers.len > 0 and h.missing > 0) try w.print("  missing {d}", .{h.missing});
        try w.print("  {s}{s}{s}{s}  {s}, embed {s}\n", .{
            if (r.measures.serif) |s| (if (s) "serif" else "sans") else "?",
            if (r.monospace) " mono" else "",
            if (r.math) " math" else "",
            if (r.variable) " variable" else "",
            @tagName(r.licence),
            @tagName(r.embedding),
        });
    }
    try w.flush();
}

fn show(init: std.process.Init, a: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) return error.Usage;
    var style: ?[]const u8 = null;
    if (args.len >= 3 and std.mem.eql(u8, args[1], "--style")) style = args[2];
    const all = try indexedRecords(init, a);
    const k = fs.find(all, args[0], style) orelse {
        std.debug.print("No installed font is called \"{s}\".\n", .{args[0]});
        std.process.exit(1);
    };
    const r = &all[k];
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const w = &out.interface;
    try w.print("{s} {s}  ({s})\n", .{ r.family, r.style, r.full_name });
    try w.print("  source: {s}, {s} (face {d})\n", .{ r.source, r.location, r.index });
    try w.print("  weight {d:.0}, width {d:.0}%, {s}, slant {d:.1}°{s}{s}{s}\n", .{ r.weight, r.width, if (r.italic) "italic" else "upright", r.slant, if (r.monospace) ", monospaced" else "", if (r.variable) ", variable" else "", if (r.math) ", MATH table" else "" });
    try w.print("  {d} glyphs, {d} codepoint ranges, units per em {d}\n", .{ r.glyphs, r.coverage.len, r.upem });
    const m = r.measures;
    try w.writeAll("  measured from outlines:");
    if (m.cap) |v| try w.print(" cap/em {d:.3}", .{v});
    if (m.x) |v| try w.print(", x/cap {d:.3}", .{v});
    if (m.stem) |v| try w.print(", stem/cap {d:.3}", .{v});
    if (m.contrast) |v| try w.print(", contrast {d:.2}", .{v});
    if (m.width) |v| try w.print(", width/cap {d:.3}", .{v});
    if (m.round) |v| try w.print(", o w/h {d:.3}", .{v});
    if (m.serif) |v| try w.print(", {s}", .{if (v) "serifs" else "no serifs"});
    try w.writeAll("\n");
    try w.print("  embedding (the font's OS/2 fsType): {s}{s}{s}\n", .{ @tagName(r.embedding), if (r.no_subsetting) ", no subsetting" else "", if (r.bitmap_only) ", bitmap only" else "" });
    try w.print("  licence (the font's name table): {s}\n", .{@tagName(r.licence)});
    if (r.licence_text.len > 0) try w.print("    \"{s}\"\n", .{r.licence_text});
    if (r.licence_url.len > 0) try w.print("    {s}\n", .{r.licence_url});
    try w.writeAll("  These are the terms as the font states them. Graven does not set them,\n  and does not judge what your own licence allows.\n");
    try w.flush();
}

pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len >= 2) {
        const cmd = args[1];
        const rest = args[2..];
        if (std.mem.eql(u8, cmd, "index") and rest.len == 0) {
            _ = try buildIndex(init, a, false);
            return;
        }
        if (std.mem.eql(u8, cmd, "search")) return search(init, a, rest);
        if (std.mem.eql(u8, cmd, "show") and rest.len >= 1) return show(init, a, rest);
    }
    std.debug.print("{s}", .{usage});
    std.process.exit(2);
}
