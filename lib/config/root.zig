//! Graven's configuration: TOML files, one shared (preferences that may
//! follow the user between machines) and one local (this machine: its
//! screen, its window layout). Where both set a key, the local file wins.

const std = @import("std");
pub const toml = @import("toml.zig");

/// Which file a setting belongs in when it is first written.
pub const Home = enum { shared, local };

/// The two files, read: a key is looked up in the local file first.
pub const Layered = struct {
    shared: toml.Doc,
    local: toml.Doc,

    pub fn init(gpa: std.mem.Allocator) Layered {
        return .{ .shared = .init(gpa), .local = .init(gpa) };
    }

    pub fn deinit(l: *Layered) void {
        l.shared.deinit();
        l.local.deinit();
    }

    /// The value in force: the local file's, else the shared file's.
    pub fn get(l: *const Layered, key: []const u8) ?toml.Value {
        return l.local.get(key) orelse l.shared.get(key);
    }

    /// Records a setting: where the local file already holds the key, it
    /// changes there (the override stays an override); otherwise in the
    /// setting's home file.
    pub fn put(l: *Layered, key: []const u8, value: toml.Value, home: Home) std.mem.Allocator.Error!void {
        if (l.local.has(key) or home == .local) return l.local.set(key, value);
        return l.shared.set(key, value);
    }
};

test "the local file overrides the shared one, and keeps its overrides" {
    const gpa = std.testing.allocator;
    var l: Layered = .{
        .shared = try toml.parse(gpa, "[canvas]\nunits = \"inch\"\n[panes]\nhot_edges = true\n", null),
        .local = try toml.parse(gpa, "[canvas]\nunits = \"mm\"\n", null),
    };
    defer l.deinit();
    try std.testing.expectEqualStrings("mm", l.get("canvas.units").?.string);
    try std.testing.expect(l.get("panes.hot_edges").?.boolean);
    try std.testing.expectEqual(null, l.get("panes.none"));
    // A shared setting changed while the local file overrides it: the
    // local file changes, the shared one is left as it was.
    try l.put("canvas.units", .{ .string = "mil" }, .shared);
    try std.testing.expectEqualStrings("mil", l.local.get("canvas.units").?.string);
    try std.testing.expectEqualStrings("inch", l.shared.get("canvas.units").?.string);
    // Otherwise each goes to its home.
    try l.put("panes.hot_edges", .{ .boolean = false }, .shared);
    try l.put("panes.tools_height", .{ .float = 140 }, .local);
    try std.testing.expect(!l.shared.get("panes.hot_edges").?.boolean);
    try std.testing.expectEqual(140, l.local.get("panes.tools_height").?.float);
}

test {
    _ = toml;
}
