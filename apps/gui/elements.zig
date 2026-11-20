//! The interface's elements, named (decided 2026-11-20): every field,
//! button, choice, toggle and shown value has an id in a logical hierarchy
//! of groups (what it is about: the object's kind, then the aspect), never
//! the panes, sections or dialogs it happens to be drawn in. Moving an
//! element elsewhere does not rename it.
//!
//! Ids are dotted paths, each part kebab-case (`track.origin.across`,
//! `track.flow.show`), as action names are. A button's id is its action's
//! name: the button, the action's key, its menu item and a script share
//! one name.
//!
//! The registry is the discovery path: `children` walks it group by group
//! (`track` → `origin` → `across`); the app says which elements are on
//! screen now (main.zig, `testing_api.discover`). Drawing code places an
//! element by id (`main.zig`'s `…E` helpers) and takes its label from
//! here; it no longer coins names. Everything is checked when built: a
//! malformed or repeated id, an element whose group is not declared, a
//! button whose action does not exist, a lookup of an unknown id.

const std = @import("std");
const keymap = @import("keymap.zig");

pub const Kind = enum {
    /// Text or a number typed in, taken on accept.
    field,
    /// Runs its action.
    button,
    /// One of a list.
    choice,
    /// On or off.
    toggle,
    /// Shown, not edited.
    value,
};

pub const Element = struct {
    id: []const u8,
    kind: Kind,
    /// Its label (the default; a few say more when drawn: "Make tracks of
    /// its 6 rows").
    label: []const u8,
    /// A button's action (its id, unless given).
    action: ?[]const u8 = null,
};

pub const Group = struct {
    id: []const u8,
    /// What its elements are about.
    label: []const u8,
};

pub const groups = [_]Group{
    .{ .id = "track", .label = "A track or a region (rows or columns added as needed)" },
    .{ .id = "track.origin", .label = "Where it starts, mm in its panel" },
    .{ .id = "track.flow", .label = "The flow it holds or continues" },
    .{ .id = "flows", .label = "The document's flows" },
    .{ .id = "flow", .label = "A flow" },
    .{ .id = "panel", .label = "A panel" },
};

pub const all = [_]Element{
    // A track or region.
    .{ .id = "track.name", .kind = .field, .label = "Name" },
    .{ .id = "track.origin.across", .kind = .field, .label = "Origin across, mm" },
    .{ .id = "track.origin.up", .kind = .field, .label = "Origin up, mm" },
    .{ .id = "track.kind", .kind = .value, .label = "Kind" },
    .{ .id = "track.direction", .kind = .field, .label = "Direction, °" },
    .{ .id = "track.rotation", .kind = .field, .label = "Rotation, °" },
    .{ .id = "track.orientation-issue", .kind = .value, .label = "Issue" },
    .{ .id = "track.length", .kind = .field, .label = "Length, u" },
    .{ .id = "track.depth", .kind = .field, .label = "Depth, rows" },
    .{ .id = "track.size", .kind = .value, .label = "Size" },
    .{ .id = "track.pitch", .kind = .value, .label = "Pitch" },
    .{ .id = "track.rows", .kind = .value, .label = "Rows" },
    .{ .id = "track.items", .kind = .value, .label = "Items" },
    .{ .id = "track.key-prefix", .kind = .field, .label = "Key name prefix" },
    .{ .id = "track.name-keys", .kind = .button, .label = "Name keys in order" },
    .{ .id = "track.outside-issue", .kind = .value, .label = "Issue" },
    .{ .id = "track.prototype", .kind = .value, .label = "Prototype" },
    .{ .id = "track.style", .kind = .value, .label = "Sized to" },
    .{ .id = "track.make-tracks", .kind = .button, .label = "Make tracks of its rows" },
    .{ .id = "track.remove", .kind = .button, .label = "Remove track" },
    .{ .id = "track.content", .kind = .choice, .label = "Content" },
    .{ .id = "track.indent", .kind = .field, .label = "Indent, u" },
    .{ .id = "track.gap", .kind = .field, .label = "Row gap, u" },
    // Its flow.
    .{ .id = "track.flow.choice", .kind = .choice, .label = "Flow" },
    .{ .id = "track.flow.position", .kind = .value, .label = "In it" },
    .{ .id = "track.flow.show", .kind = .button, .label = "Show the flow" },
    .{ .id = "track.flow.before", .kind = .value, .label = "Continues" },
    .{ .id = "track.flow.after", .kind = .value, .label = "Goes on into" },
    .{ .id = "track.flow.join-after", .kind = .button, .label = "Join a track after this…" },
    .{ .id = "track.flow.take-out", .kind = .button, .label = "Take out of its flow" },
    // Flows, a flow, a panel.
    .{ .id = "flows.new", .kind = .button, .label = "New flow" },
    .{ .id = "flow.remove", .kind = .button, .label = "Remove flow" },
    .{ .id = "panel.edit", .kind = .button, .label = "Edit panel" },
    .{ .id = "panel.release", .kind = .button, .label = "Release panel" },
};

fn validPart(p: []const u8) bool {
    if (p.len == 0 or !std.ascii.isLower(p[0])) return false;
    var dash = false;
    for (p) |c| {
        if (c == '-') {
            if (dash) return false;
            dash = true;
        } else if (std.ascii.isLower(c) or std.ascii.isDigit(c)) {
            dash = false;
        } else return false;
    }
    return !dash;
}

fn validId(id: []const u8) bool {
    var it = std.mem.splitScalar(u8, id, '.');
    while (it.next()) |p| if (!validPart(p)) return false;
    return true;
}

fn groupDeclared(id: []const u8) bool {
    for (groups) |g| if (std.mem.eql(u8, g.id, id)) return true;
    return false;
}

comptime {
    @setEvalBranchQuota(1_000_000);
    for (groups) |g| {
        if (!validId(g.id)) @compileError("malformed group id: " ++ g.id);
        if (std.mem.lastIndexOfScalar(u8, g.id, '.')) |k| if (!groupDeclared(g.id[0..k])) @compileError("group " ++ g.id ++ " in an undeclared group");
    }
    for (all, 0..) |e, i| {
        if (!validId(e.id)) @compileError("malformed element id: " ++ e.id);
        const k = std.mem.lastIndexOfScalar(u8, e.id, '.') orelse @compileError("element " ++ e.id ++ " in no group");
        if (!groupDeclared(e.id[0..k])) @compileError("element " ++ e.id ++ " in an undeclared group");
        if (groupDeclared(e.id)) @compileError("element " ++ e.id ++ " is also a group");
        for (all[0..i]) |o| if (std.mem.eql(u8, o.id, e.id)) @compileError("element id twice: " ++ e.id);
        if (e.kind == .button) _ = keymap.act(e.action orelse e.id);
        if (e.kind != .button and e.action != null) @compileError("only a button has an action: " ++ e.id);
    }
}

/// The element `id` (checked when built).
pub fn get(comptime id: []const u8) Element {
    comptime {
        @setEvalBranchQuota(100_000);
        for (all) |e| if (std.mem.eql(u8, e.id, id)) return e;
        @compileError("no element \"" ++ id ++ "\"");
    }
}

/// The element `id` at run time, if there is one (a repeat's "#n" aside).
pub fn find(id: []const u8) ?Element {
    const base = if (std.mem.indexOfScalar(u8, id, '#')) |k| id[0..k] else id;
    for (all) |e| if (std.mem.eql(u8, e.id, base)) return e;
    return null;
}

/// The action a button stands for.
pub fn action(id: []const u8) ?keymap.ActionId {
    const e = find(id) orelse return null;
    if (e.kind != .button) return null;
    const name = e.action orelse e.id;
    for (0..keymap.R.action_count) |k| {
        const a: keymap.ActionId = @intCast(k);
        if (std.mem.eql(u8, keymap.R.actionName(a), name)) return a;
    }
    return null;
}

/// One step down the discovery path: a group's member, a group itself or
/// an element.
pub const Child = struct {
    /// Its full id.
    id: []const u8,
    /// Its last part.
    name: []const u8,
    group: bool,
    kind: ?Kind = null,
    label: []const u8,
};

/// The groups and elements directly in group `parent` ("" for the top),
/// in the registry's order, into `out`.
pub fn children(parent: []const u8, out: []Child) []Child {
    var n: usize = 0;
    for (groups) |g| {
        if (n == out.len) break;
        if (!directlyIn(g.id, parent)) continue;
        out[n] = .{ .id = g.id, .name = lastPart(g.id), .group = true, .label = g.label };
        n += 1;
    }
    for (all) |e| {
        if (n == out.len) break;
        if (!directlyIn(e.id, parent)) continue;
        out[n] = .{ .id = e.id, .name = lastPart(e.id), .group = false, .kind = e.kind, .label = e.label };
        n += 1;
    }
    return out[0..n];
}

fn lastPart(id: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, id, '.')) |k| id[k + 1 ..] else id;
}

fn directlyIn(id: []const u8, parent: []const u8) bool {
    if (parent.len == 0) return std.mem.indexOfScalar(u8, id, '.') == null;
    return id.len > parent.len + 1 and std.mem.startsWith(u8, id, parent) and id[parent.len] == '.' and std.mem.indexOfScalar(u8, id[parent.len + 1 ..], '.') == null;
}

const testing = std.testing;

test "the discovery path walks the groups: track, its origin, its fields" {
    var buf: [64]Child = undefined;
    const top = children("", &buf);
    var has_track = false;
    for (top) |c| has_track = has_track or (c.group and std.mem.eql(u8, c.id, "track"));
    try testing.expect(has_track);
    const origin = children("track.origin", &buf);
    try testing.expectEqual(2, origin.len);
    try testing.expectEqualStrings("across", origin[0].name);
    try testing.expectEqual(Kind.field, origin[1].kind.?);
    try testing.expect(find("track.make-tracks#2") != null);
    try testing.expect(find("paragraph.showTheFlow") == null);
}

test "ids: dotted kebab-case parts" {
    try testing.expect(validId("track.flow.join-after"));
    try testing.expect(!validId("track.flow.joinAfter"));
    try testing.expect(!validId("track..name"));
    try testing.expect(!validId("track.-name"));
}
