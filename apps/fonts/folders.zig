//! Font folders a document's fonts are found in before the installed ones:
//! a `fonts` folder beside the document (the examples' `examples/fonts`),
//! then `$GRAVEN_FONTS`, else a `fonts` folder in the working folder (the
//! math packages' fonts, from scripts/fetch-fonts.py). The GUI and the CLI
//! both look there first, so a document sets the same in either.
//!
//! Every font in those folders is loaded and named by family and style
//! (as the font search describes it): a catalog for `fonts.resolve`, alone
//! or joined before the installed fonts' (`fonts.join`).

const std = @import("std");
const platform = @import("graven_platform");
const layout = @import("graven_layout");
const fontsearch = @import("graven_fontsearch");

const Allocator = std.mem.Allocator;

/// The folders for the document at `doc_path` (null: no document), in
/// order, without repeats; allocated from `a`.
pub fn dirsFor(a: Allocator, doc_path: ?[]const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (doc_path) |p| try out.append(a, try std.fs.path.join(a, &.{ std.fs.path.dirname(p) orelse ".", "fonts" }));
    const set = platform.env("GRAVEN_FONTS") orelse "";
    const shared: []const u8 = if (set.len > 0) set else "fonts";
    for (out.items) |o| {
        if (std.mem.eql(u8, o, shared) or (std.mem.eql(u8, o, "./fonts") and std.mem.eql(u8, shared, "fonts"))) break;
    } else try out.append(a, shared);
    return out.items;
}

/// Fonts loaded and named: every font in some folders, or font files.
pub const Folders = struct {
    arena: std.heap.ArenaAllocator,
    faces: std.ArrayList(*layout.Face) = .empty,
    bytes: std.ArrayList([]u8) = .empty,
    names: std.ArrayList(layout.model.FontName) = .empty,

    pub fn init(gpa: Allocator) Folders {
        return .{ .arena = .init(gpa) };
    }

    /// Adds every .ttf and .otf in folder `path` (none when it is not
    /// there), in name order, so the result does not depend on the order
    /// the file system lists them in.
    pub fn addDir(d: *Folders, gpa: Allocator, io: std.Io, path: []const u8) !void {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
        defer dir.close(io);
        const a = d.arena.allocator();
        var files: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            const ext = std.fs.path.extension(entry.name);
            if (!std.ascii.eqlIgnoreCase(ext, ".ttf") and !std.ascii.eqlIgnoreCase(ext, ".otf")) continue;
            try files.append(a, try a.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, files.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lt);
        for (files.items) |name| {
            const bytes = try dir.readFileAlloc(io, name, gpa, .limited(64 << 20));
            d.add(gpa, bytes, name) catch continue;
        }
    }

    /// Adds the font file at `path`; one that cannot be read is an error.
    pub fn addFile(d: *Folders, gpa: Allocator, io: std.Io, path: []const u8) !void {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
        try d.add(gpa, bytes, std.fs.path.basename(path));
    }

    fn add(d: *Folders, gpa: Allocator, bytes: []u8, file: []const u8) !void {
        const a = d.arena.allocator();
        const face = layout.Face.init(gpa, bytes, 0) catch |err| {
            gpa.free(bytes);
            return err;
        };
        const r = try fontsearch.describe(a, face, "", file, 0, 0);
        try d.faces.append(a, face);
        try d.bytes.append(a, bytes);
        try d.names.append(a, .{ .family = r.family, .style = r.style });
    }

    pub fn catalog(d: *Folders) layout.fonts.Catalog {
        return .{ .names = d.names.items, .ctx = d, .load = struct {
            fn f(ctx: *anyopaque, index: usize) ?*layout.Face {
                const self: *Folders = @ptrCast(@alignCast(ctx));
                return self.faces.items[index];
            }
        }.f };
    }

    pub fn deinit(d: *Folders, gpa: Allocator) void {
        for (d.faces.items) |f| f.deinit();
        for (d.bytes.items) |b| gpa.free(b);
        d.arena.deinit();
    }
};

test "a document's folders: beside it, then the shared one, once each" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (platform.env("GRAVEN_FONTS") != null) return;
    const dirs = try dirsFor(a, "examples/hp15c.graven");
    try std.testing.expectEqual(@as(usize, 2), dirs.len);
    try std.testing.expectEqualStrings("examples/fonts", dirs[0]);
    try std.testing.expectEqualStrings("fonts", dirs[1]);
    try std.testing.expectEqual(@as(usize, 1), (try dirsFor(a, "doc.graven")).len);
    try std.testing.expectEqual(@as(usize, 1), (try dirsFor(a, null)).len);
}
