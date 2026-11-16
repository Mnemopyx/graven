//! graven-fonts: find, compare and choose fonts, and manage the user's own:
//! install font files as user fonts, remove them. A separate tool on the
//! font search library; Graven opens it, and it runs on its own.
//!
//! This is the local source: installed fonts, found in the system's font
//! folders, described once and kept in an index cache, so later runs only
//! describe files that are new or changed. Remote repositories come as
//! addons through the same `Source` interface.

const std = @import("std");
const fs = @import("graven_fontsearch");
const font = @import("graven_font");
const local = @import("local.zig");

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
    \\       graven-fonts families [words] [--user | --system]
    \\         Lists typeface families (whose name holds every word), each with
    \\         its faces by width, weight and slope, and whether they are
    \\         system or user fonts.
    \\       graven-fonts install FILE... [--replace]
    \\         Installs font files as user fonts, in the user's font folder where
    \\         every application finds them. WOFF and WOFF2 are converted to
    \\         .ttf or .otf; files are named by family and style; where each
    \\         came from is recorded. A user font of the same family and style
    \\         is kept unless --replace.
    \\       graven-fonts remove "Family" [--style "Style"]
    \\         Removes user fonts (system fonts are never touched).
    \\       graven-fonts convert FILE... [--to FOLDER]
    \\         Writes each font as a plain sfnt: WOFF and WOFF2 unwrapped, named
    \\         .ttf (TrueType outlines), .otf (CFF), .ttc or .otc (collections).
    \\         Outlines are never converted between kinds. Beside each input
    \\         unless --to is given; an existing file is not written over.
    \\
    \\Licence terms are shown as each font states them. Graven does not set
    \\them, and does not judge what your own licence allows.
    \\
;

/// Scans and saves the index, saying what it did unless `quiet`.
fn buildIndex(init: std.process.Init, a: std.mem.Allocator, quiet: bool) ![]Record {
    const t0: std.Io.Timestamp = .now(init.io, .awake);
    var rep: local.Report = .{};
    const recs = try local.build(init.io, init.gpa, a, &rep);
    if (!quiet) {
        const ms = @as(f64, @floatFromInt(t0.untilNow(init.io, .awake).toNanoseconds())) / 1e6;
        std.debug.print("{d} faces: {d} described, {d} unchanged, {d} unreadable, in {d:.0} ms\nindex: {s}\n", .{ recs.len, rep.described, rep.kept, rep.failed, ms, rep.path });
    }
    return recs;
}

/// The index, built first if there is none.
fn indexedRecords(init: std.process.Init, a: std.mem.Allocator) ![]Record {
    const r = local.load(init.io, a);
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
        try w.print("{s:<44}{s}", .{ label, if (r.scope == .user) " user" else "     " });
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
    try w.print("  {s} font: {s} (face {d})\n", .{ @tagName(r.scope), r.location, r.index });
    if (r.scope == .user) {
        if (local.provenanceOf(local.loadProvenance(init.io, a), r.location)) |p| {
            try w.print("  installed by Graven on {s}, from {s} ({s})\n", .{ p.installed, p.from, p.container });
            try w.print("    sha-256 {s}\n", .{p.sha256});
        }
    }
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

fn families(init: std.process.Init, a: std.mem.Allocator, args: []const []const u8) !void {
    var scope: ?fs.Scope = null;
    var words: std.ArrayList([]const u8) = .empty;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--user")) scope = .user else if (std.mem.eql(u8, arg, "--system")) scope = .system else try words.append(a, arg);
    }
    const all = try indexedRecords(init, a);
    var subset: std.ArrayList(usize) = .empty;
    for (all, 0..) |r, i| {
        if (scope) |sc| if (r.scope != sc) continue;
        const ok = for (words.items) |word| {
            if (std.ascii.findIgnoreCase(r.family, word) == null) break false;
        } else true;
        if (ok) try subset.append(a, i);
    }
    const fams = try fs.families(a, all, subset.items, .name);
    if (fams.len == 0) {
        std.debug.print("No families match.\n", .{});
        return;
    }
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const w = &out.interface;
    var faces: usize = 0;
    for (fams) |f| {
        const where: []const u8 = if (f.user > 0 and f.system > 0) "system and user" else if (f.user > 0) "user" else "system";
        try w.print("{s}  ({d} face{s}, {s})\n", .{ f.name, f.faces.len, if (f.faces.len == 1) "" else "s", where });
        for (f.faces) |i| {
            const r = &all[i];
            try w.print("    {s:<28} weight {d:>4.0}", .{ r.style, r.weight });
            if (r.width != 100) try w.print(", width {d:.0}%", .{r.width});
            try w.print("{s}\n", .{if (r.scope == .user and f.system > 0) "  (user)" else ""});
        }
        faces += f.faces.len;
    }
    try w.print("{d} famil{s}, {d} face{s}\n", .{ fams.len, if (fams.len == 1) "y" else "ies", faces, if (faces == 1) "" else "s" });
    try w.flush();
}

fn install(init: std.process.Init, a: std.mem.Allocator, args: []const []const u8) !void {
    var replace = false;
    var files: std.ArrayList([]const u8) = .empty;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--replace")) replace = true else try files.append(a, arg);
    }
    if (files.items.len == 0) return error.Usage;
    const cwd = std.Io.Dir.cwd();
    var records = try indexedRecords(init, a);
    var failed = false;
    var changed = false;
    for (files.items) |path| {
        const bytes = cwd.readFileAlloc(init.io, path, a, .limited(256 << 20)) catch |e| {
            std.debug.print("{s}: cannot read ({s})\n", .{ path, @errorName(e) });
            failed = true;
            continue;
        };
        const from = cwd.realPathFileAlloc(init.io, path, a) catch path;
        const r = local.install(init.io, init.gpa, a, bytes, records, .{ .from = from, .replace = replace }) catch |e| {
            switch (e) {
                error.NotAFont => std.debug.print("{s}: not a font Graven can read\n", .{path}),
                error.Conflict => std.debug.print("{s}: a different user font of the same family and style is installed; --replace installs over it\n", .{path}),
                else => std.debug.print("{s}: not installed ({s})\n", .{ path, @errorName(e) }),
            }
            failed = true;
            continue;
        };
        const what: []const u8 = switch (r.outcome) {
            .installed => "installed as",
            .replaced => "installed over the earlier one, as",
            .already_installed => "already installed, as",
        };
        var desc_buf: [400]u8 = undefined;
        std.debug.print("{s}: {s} {s}{s}\n", .{ local.describeInstalled(&desc_buf, r), what, r.file, if (r.container.isWeb()) " (converted from web font)" else "" });
        if (r.shadows_system) std.debug.print("  note: a system font has the same family and style; applications may take either\n", .{});
        if (r.outcome != .already_installed) {
            changed = true;
            // Later files in this run see it.
            records = try buildIndex(init, a, true);
        }
    }
    if (changed) _ = try buildIndex(init, a, false);
    if (failed) std.process.exit(1);
}

fn remove(init: std.process.Init, a: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) return error.Usage;
    var style: ?[]const u8 = null;
    if (args.len >= 3 and std.mem.eql(u8, args[1], "--style")) style = args[2];
    const records = try indexedRecords(init, a);
    const files = local.remove(init.io, init.gpa, a, records, args[0], style) catch |e| {
        switch (e) {
            error.NotInstalled => std.debug.print("No user font is called \"{s}\"{s}{s}.\n", .{ args[0], if (style != null) " " else "", style orelse "" }),
            error.SystemFont => std.debug.print("\"{s}\" is a system font: Graven does not remove system fonts.\n", .{args[0]}),
            else => return e,
        }
        std.process.exit(1);
    };
    for (files) |f| std.debug.print("removed {s}\n", .{f});
    _ = try buildIndex(init, a, false);
}

fn convert(init: std.process.Init, a: std.mem.Allocator, args: []const []const u8) !void {
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    var files: std.ArrayList([]const u8) = .empty;
    var to: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--to") and i + 1 < args.len) {
            to = args[i + 1];
            i += 1;
        } else try files.append(a, args[i]);
    }
    if (files.items.len == 0) return error.Usage;
    if (to) |d| try cwd.createDirPath(io, d);
    var failed = false;
    for (files.items) |path| {
        const bytes = cwd.readFileAlloc(io, path, init.gpa, .limited(256 << 20)) catch |e| {
            std.debug.print("{s}: cannot read ({s})\n", .{ path, @errorName(e) });
            failed = true;
            continue;
        };
        defer init.gpa.free(bytes);
        const kind = font.container.kindOf(bytes);
        const sfnt = font.container.toSfnt(init.gpa, bytes) catch |e| {
            std.debug.print("{s}: not a font Graven can read ({s}, {s})\n", .{ path, @tagName(kind), @errorName(e) });
            failed = true;
            continue;
        };
        defer init.gpa.free(sfnt);
        const ext = font.container.extension(sfnt).?;
        const base = std.fs.path.basename(path);
        const stem = base[0 .. base.len - std.fs.path.extension(base).len];
        const dir = to orelse std.fs.path.dirname(path) orelse ".";
        const out = try std.fs.path.join(a, &.{ dir, try std.mem.concat(a, u8, &.{ stem, ext }) });
        if (std.mem.eql(u8, out, path)) {
            std.debug.print("{s}: already a plain {s}, nothing to do\n", .{ path, ext });
            continue;
        }
        if (cwd.statFile(io, out, .{})) |_| {
            std.debug.print("{s}: {s} exists, not written over\n", .{ path, out });
            failed = true;
            continue;
        } else |_| {}
        try cwd.writeFile(io, .{ .sub_path = out, .data = sfnt });
        const faces = font.container.faceCount(sfnt);
        std.debug.print("{s} ({s}) -> {s}: {s} outlines, {d} face{s}, {d} bytes\n", .{
            path,                                                @tagName(kind), out, @tagName(font.container.outlinesOf(sfnt, 0)),
            faces,                                               if (faces == 1) "" else "s",
            sfnt.len,
        });
    }
    if (failed) std.process.exit(1);
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
        if (std.mem.eql(u8, cmd, "convert") and rest.len >= 1) return convert(init, a, rest);
        if (std.mem.eql(u8, cmd, "families")) return families(init, a, rest);
        if (std.mem.eql(u8, cmd, "install") and rest.len >= 1) return install(init, a, rest);
        if (std.mem.eql(u8, cmd, "remove") and rest.len >= 1) return remove(init, a, rest);
    }
    std.debug.print("{s}", .{usage});
    std.process.exit(2);
}
