//! Pane layouts: named arrangements of the panes, switched between.
//!
//! Every pane has an official name, used in the config and (as a message
//! ID) for its label: `browser` (the document's tree), `tools`,
//! `properties`, `expression-bar` (the expression line and the status
//! line). A layout gives each its mode, its size and its text scale:
//!
//!     [panes]
//!     layout = "compact"              # the one in use (local.toml)
//!
//!     [panes.layouts.compact.browser]
//!     mode = "auto"                   # auto, docked, hidden
//!     size = 220                      # its width, logical pixels
//!     text_scale = 0.9                # its text and controls
//!
//!     [panes.layouts.compact.properties]
//!     size = 300                      # the right column's width
//!
//!     [panes.layouts.compact.tools]
//!     height = 120                    # its share of the right column
//!
//! Layouts live in the shared file; the local file may override any of
//! their keys for this machine (and does, when a pane is changed by hand).
//! Three are built in (`standard`, `compact`, `large-text`); a layout in
//! the config with a built-in's name starts from it, any other from
//! `standard`, and takes what its keys set.
//!
//! Window-free, so it is tested on its own; the GUI applies a layout to
//! its panes and writes them back.

const std = @import("std");

pub const PaneId = enum {
    browser,
    tools,
    properties,
    @"expression-bar",

    pub fn name(p: PaneId) []const u8 {
        return @tagName(p);
    }
};

pub const pane_count = @typeInfo(PaneId).@"enum".field_names.len;

/// As ghost.zig's `Mode`, by name.
pub const Mode = enum {
    auto,
    docked,
    hidden,

    /// A mode by name; "ghost" (gone since 2026-11-21) is auto-hide.
    pub fn parse(name: []const u8) ?Mode {
        if (std.mem.eql(u8, name, "ghost")) return .auto;
        return std.meta.stringToEnum(Mode, name);
    }
};

pub const PaneSet = struct {
    mode: Mode,
    /// Across its edge: a side pane's width (the properties' is the right
    /// column's, the tools' too); 0 where the pane sizes itself (the
    /// expression bar).
    size: f32 = 0,
    text_scale: f32 = 1,
};

pub const Layout = struct {
    panes: [pane_count]PaneSet,
    /// The tools pane's height in the right column.
    tools_height: f32 = 120,

    pub fn pane(l: *const Layout, id: PaneId) PaneSet {
        return l.panes[@intFromEnum(id)];
    }
};

pub const size_min: f32 = 160;
pub const size_max: f32 = 900;
pub const scale_min: f32 = 0.6;
pub const scale_max: f32 = 2;
pub const height_min: f32 = 48;
pub const height_max: f32 = 900;

pub const Builtin = struct { name: []const u8, layout: Layout };

pub const builtins = [_]Builtin{
    // As Graven opens: the side panes auto-hide, the bar docked.
    .{ .name = "standard", .layout = .{ .panes = .{
        .{ .mode = .auto, .size = 240 },
        .{ .mode = .auto, .size = 320 },
        .{ .mode = .auto, .size = 320 },
        .{ .mode = .docked },
    } } },
    // For a small window: the side panes out of the way until wanted,
    // narrower, their text a little smaller.
    .{ .name = "compact", .layout = .{ .panes = .{
        .{ .mode = .auto, .size = 220, .text_scale = 0.9 },
        .{ .mode = .auto, .size = 290, .text_scale = 0.9 },
        .{ .mode = .auto, .size = 290, .text_scale = 0.9 },
        .{ .mode = .docked, .text_scale = 0.9 },
    }, .tools_height = 110 } },
    // Larger text and controls throughout, the panes widened to match.
    .{ .name = "large-text", .layout = .{ .panes = .{
        .{ .mode = .auto, .size = 300, .text_scale = 1.25 },
        .{ .mode = .auto, .size = 400, .text_scale = 1.25 },
        .{ .mode = .auto, .size = 400, .text_scale = 1.25 },
        .{ .mode = .docked, .text_scale = 1.25 },
    }, .tools_height = 150 } },
};

pub fn builtin(name: []const u8) ?Layout {
    for (builtins) |b| if (std.mem.eql(u8, b.name, name)) return b.layout;
    return null;
}

/// A layout's name may hold letters, digits, `-` and `_` (it is a bare
/// TOML key), 1 to 40 of them.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 40) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}

/// `name` made valid: spaces to `-`, anything else not allowed dropped.
pub fn cleanName(buf: []u8, name: []const u8) []const u8 {
    var n: usize = 0;
    for (std.mem.trim(u8, name, " ")) |c| {
        if (n >= buf.len or n >= 40) break;
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') {
            buf[n] = c;
            n += 1;
        } else if (c == ' ' and n > 0 and buf[n - 1] != '-') {
            buf[n] = '-';
            n += 1;
        }
    }
    return buf[0..n];
}

/// The key of field `field` of pane `pane` in layout `name`
/// (`panes.layouts.<name>.<pane>.<field>`).
pub fn key(buf: []u8, name: []const u8, pane: PaneId, field: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "panes.layouts.{s}.{s}.{s}", .{ name, pane.name(), field }) catch "";
}

/// The prefix of every key of layout `name`.
pub fn prefix(buf: []u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "panes.layouts.{s}.", .{name}) catch "";
}

/// A number from a config value (an integer or a float).
fn number(v: anytype) ?f32 {
    return switch (v) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

/// Layout `name` as the config has it: the built-in of that name (else
/// `standard`) with what `cfg.get(key)` sets over it, each value in range.
/// `cfg` has `get(key) ?Value`, the config's value type.
pub fn read(cfg: anytype, name: []const u8) Layout {
    var l = builtin(name) orelse builtins[0].layout;
    var kb: [160]u8 = undefined;
    for (std.enums.values(PaneId)) |pid| {
        const set = &l.panes[@intFromEnum(pid)];
        if (cfg.get(key(&kb, name, pid, "mode"))) |v| if (v == .string) if (Mode.parse(v.string)) |m| {
            set.mode = m;
        };
        if (pid != .@"expression-bar") if (cfg.get(key(&kb, name, pid, "size"))) |v| if (number(v)) |f| {
            set.size = std.math.clamp(f, size_min, size_max);
        };
        if (cfg.get(key(&kb, name, pid, "text_scale"))) |v| if (number(v)) |f| {
            set.text_scale = std.math.clamp(f, scale_min, scale_max);
        };
    }
    if (cfg.get(key(&kb, name, .tools, "height"))) |v| if (number(v)) |f| {
        l.tools_height = std.math.clamp(f, height_min, height_max);
    };
    // The right column has one width: the properties' sets the tools'.
    l.panes[@intFromEnum(PaneId.tools)].size = l.panes[@intFromEnum(PaneId.properties)].size;
    return l;
}

/// Each name in `keys` (full config keys) of a layout: what follows
/// `panes.layouts.` up to the next dot, each once, after the built-ins.
pub fn names(a: std.mem.Allocator, keys: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (builtins) |b| try out.append(a, b.name);
    const head = "panes.layouts.";
    for (keys) |k| {
        if (!std.mem.startsWith(u8, k, head)) continue;
        const rest = k[head.len..];
        const n = rest[0 .. std.mem.indexOfScalar(u8, rest, '.') orelse continue];
        if (!validName(n)) continue;
        for (out.items) |have| {
            if (std.mem.eql(u8, have, n)) break;
        } else try out.append(a, n);
    }
    return out.toOwnedSlice(a);
}

const testing = std.testing;

const Value = union(enum) { string: []const u8, integer: i64, float: f64, boolean: bool };

const Fake = struct {
    keys: []const []const u8,
    vals: []const Value,

    fn get(f: Fake, k: []const u8) ?Value {
        for (f.keys, f.vals) |fk, v| if (std.mem.eql(u8, fk, k)) return v;
        return null;
    }
};

test "a built-in layout as it is, with nothing in the config" {
    const f: Fake = .{ .keys = &.{}, .vals = &.{} };
    const l = read(f, "compact");
    try testing.expectEqual(Mode.auto, l.pane(.browser).mode);
    try testing.expectEqual(0.9, l.pane(.properties).text_scale);
    // An unknown name starts from standard.
    try testing.expectEqual(Mode.auto, read(f, "mine").pane(.browser).mode);
}

test "config keys set over the built-in, in range, the column one width" {
    const f: Fake = .{
        .keys = &.{ "panes.layouts.mine.browser.mode", "panes.layouts.mine.browser.size", "panes.layouts.mine.properties.size", "panes.layouts.mine.tools.text_scale", "panes.layouts.mine.tools.height", "panes.layouts.mine.properties.mode" },
        .vals = &.{ .{ .string = "docked" }, .{ .integer = 5000 }, .{ .float = 280.5 }, .{ .float = 0.1 }, .{ .integer = 200 }, .{ .string = "nonsense" } },
    };
    const l = read(f, "mine");
    try testing.expectEqual(Mode.docked, l.pane(.browser).mode);
    try testing.expectEqual(size_max, l.pane(.browser).size);
    try testing.expectEqual(280.5, l.pane(.properties).size);
    try testing.expectEqual(280.5, l.pane(.tools).size);
    try testing.expectEqual(scale_min, l.pane(.tools).text_scale);
    try testing.expectEqual(200, l.tools_height);
    try testing.expectEqual(Mode.auto, l.pane(.properties).mode);
    // Ghost, gone, reads as auto-hide.
    try testing.expectEqual(Mode.auto, Mode.parse("ghost").?);
}

test "names: the built-ins, then each in the config once" {
    const keys = [_][]const u8{ "panes.layout", "panes.layouts.desk.browser.mode", "panes.layouts.desk.tools.height", "panes.layouts.compact.browser.size", "panes.layouts.bad name.x.y", "canvas.units" };
    const n = try names(testing.allocator, &keys);
    defer testing.allocator.free(n);
    try testing.expectEqual(builtins.len + 1, n.len);
    try testing.expectEqualStrings("desk", n[builtins.len]);
}

test "names are cleaned to bare keys" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("My-laptop_2", cleanName(&buf, "  My laptop_2!  "));
    try testing.expect(validName("large-text"));
    try testing.expect(!validName("a.b"));
    try testing.expect(!validName(""));
}
