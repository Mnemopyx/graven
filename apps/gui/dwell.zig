//! Hot edges: when holding the pointer on a ghost pane's tab activates it,
//! and when moving away returns it to ghost. Pure logic, stepped once a
//! frame, so it can be tested without a window.

const std = @import("std");

/// How long the pointer must stay on a tab, or away from a pane, ns.
pub const delay_ns: i128 = 400 * std.time.ns_per_ms;

pub const State = struct {
    /// When the pointer arrived on the tab, while the pane is not active.
    on_since: ?i128 = null,
    /// When the pointer left the pane and its tab, while it is active.
    off_since: ?i128 = null,
    /// The pane was activated by holding the pointer on its tab: only then
    /// does moving away return it to ghost.
    by_hover: bool = false,

    /// A click on the tab took over: the pane is the user's to close.
    pub fn clicked(s: *State) void {
        s.* = .{};
    }
};

pub const Input = struct {
    now: i128,
    active: bool,
    on_tab: bool,
    on_pane: bool,
    /// One of the pane's fields has the keyboard.
    editing: bool,
};

pub const Action = enum { none, activate, deactivate };

/// One frame: what to do, if anything.
pub fn step(s: *State, in: Input) Action {
    if (!in.active) {
        s.off_since = null;
        s.by_hover = false;
        if (!in.on_tab) {
            s.on_since = null;
            return .none;
        }
        const since = s.on_since orelse in.now;
        s.on_since = since;
        if (in.now - since < delay_ns) return .none;
        s.on_since = null;
        s.by_hover = true;
        return .activate;
    }
    s.on_since = null;
    if (!s.by_hover) return .none;
    if (in.on_tab or in.on_pane or in.editing) {
        s.off_since = null;
        return .none;
    }
    const since = s.off_since orelse in.now;
    s.off_since = since;
    if (in.now - since < delay_ns) return .none;
    s.* = .{};
    return .deactivate;
}

/// How long until `step` could act, ns, if it is waiting on the clock.
pub fn wait(s: State, now: i128) ?i128 {
    const since = s.on_since orelse s.off_since orelse return null;
    return @max(0, since + delay_ns - now);
}

const testing = std.testing;
const ms = std.time.ns_per_ms;

test "holding the pointer on a tab activates its pane after the delay" {
    var s: State = .{};
    try testing.expectEqual(.none, step(&s, .{ .now = 0, .active = false, .on_tab = true, .on_pane = false, .editing = false }));
    try testing.expectEqual(@as(?i128, 400 * ms), wait(s, 0));
    try testing.expectEqual(.none, step(&s, .{ .now = 399 * ms, .active = false, .on_tab = true, .on_pane = false, .editing = false }));
    try testing.expectEqual(.activate, step(&s, .{ .now = 400 * ms, .active = false, .on_tab = true, .on_pane = false, .editing = false }));
    try testing.expect(s.by_hover);
}

test "passing over a tab does not activate" {
    var s: State = .{};
    _ = step(&s, .{ .now = 0, .active = false, .on_tab = true, .on_pane = false, .editing = false });
    try testing.expectEqual(.none, step(&s, .{ .now = 200 * ms, .active = false, .on_tab = false, .on_pane = false, .editing = false }));
    try testing.expectEqual(.none, step(&s, .{ .now = 300 * ms, .active = false, .on_tab = true, .on_pane = false, .editing = false }));
    try testing.expectEqual(.none, step(&s, .{ .now = 600 * ms, .active = false, .on_tab = true, .on_pane = false, .editing = false }));
    try testing.expectEqual(.activate, step(&s, .{ .now = 700 * ms, .active = false, .on_tab = true, .on_pane = false, .editing = false }));
}

test "a hover-activated pane returns to ghost once the pointer has been away, but not while editing" {
    var s: State = .{ .by_hover = true };
    const base: Input = .{ .now = 0, .active = true, .on_tab = false, .on_pane = true, .editing = false };
    try testing.expectEqual(.none, step(&s, base));
    var away = base;
    away.on_pane = false;
    away.now = 1000 * ms;
    try testing.expectEqual(.none, step(&s, away));
    away.now = 1300 * ms;
    away.editing = true;
    try testing.expectEqual(.none, step(&s, away));
    away.editing = false;
    away.now = 1400 * ms;
    try testing.expectEqual(.none, step(&s, away));
    away.now = 1800 * ms;
    try testing.expectEqual(.deactivate, step(&s, away));
}

test "a pane activated by a click stays active when the pointer leaves" {
    var s: State = .{};
    s.clicked();
    try testing.expectEqual(.none, step(&s, .{ .now = 0, .active = true, .on_tab = false, .on_pane = false, .editing = false }));
    try testing.expectEqual(.none, step(&s, .{ .now = 5000 * ms, .active = true, .on_tab = false, .on_pane = false, .editing = false }));
}
