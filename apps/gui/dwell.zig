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
    /// A click on the tab took over, and the pointer has not left the tab
    /// since: resting on it does not bring the pane in until it has left
    /// and come back (a click that sends a pane out must not have it slide
    /// straight back in under the still pointer).
    await_leave: bool = false,

    /// A click on the tab took over: the pane is the user's to close. The
    /// pointer, on the tab, must leave it before hovering counts again.
    pub fn clicked(s: *State) void {
        s.* = .{ .await_leave = true };
    }
};

pub const Input = struct {
    now: i128,
    active: bool,
    on_tab: bool,
    on_pane: bool,
    /// One of the pane's fields has the keyboard.
    editing: bool,
    /// How long the pointer must stay on the tab to activate (an
    /// auto-hide pane answers sooner than a ghost).
    on_delay: i128 = delay_ns,
};

pub const Action = enum { none, activate, deactivate };

/// One frame: what to do, if anything.
pub fn step(s: *State, in: Input) Action {
    if (!in.active) {
        s.off_since = null;
        s.by_hover = false;
        if (!in.on_tab) {
            s.on_since = null;
            s.await_leave = false;
            return .none;
        }
        if (s.await_leave) return .none;
        const since = s.on_since orelse in.now;
        s.on_since = since;
        if (in.now - since < in.on_delay) return .none;
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

/// How long until `step` could act, ns, if it is waiting on the clock
/// (`on_delay` as given to `step`).
pub fn wait(s: State, now: i128, on_delay: i128) ?i128 {
    if (s.on_since) |since| return @max(0, since + on_delay - now);
    const since = s.off_since orelse return null;
    return @max(0, since + delay_ns - now);
}

const testing = std.testing;
const ms = std.time.ns_per_ms;

test "holding the pointer on a tab activates its pane after the delay" {
    var s: State = .{};
    try testing.expectEqual(.none, step(&s, .{ .now = 0, .active = false, .on_tab = true, .on_pane = false, .editing = false }));
    try testing.expectEqual(@as(?i128, 400 * ms), wait(s, 0, delay_ns));
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

test "after a click sends a pane out, the pointer must leave the tab and come back" {
    var s: State = .{};
    s.clicked();
    const on: Input = .{ .now = 0, .active = false, .on_tab = true, .on_pane = false, .editing = false };
    try testing.expectEqual(.none, step(&s, on));
    var later = on;
    later.now = 5000 * ms;
    try testing.expectEqual(.none, step(&s, later));
    try testing.expectEqual(@as(?i128, null), wait(s, later.now, delay_ns));
    var off = on;
    off.on_tab = false;
    off.now = 5100 * ms;
    try testing.expectEqual(.none, step(&s, off));
    later.now = 5200 * ms;
    try testing.expectEqual(.none, step(&s, later));
    later.now = 5600 * ms;
    try testing.expectEqual(.activate, step(&s, later));
}

test "a shorter delay to activate, the same to return" {
    var s: State = .{};
    const fast: i128 = 250 * ms;
    try testing.expectEqual(.none, step(&s, .{ .now = 0, .active = false, .on_tab = true, .on_pane = false, .editing = false, .on_delay = fast }));
    try testing.expectEqual(@as(?i128, 250 * ms), wait(s, 0, fast));
    try testing.expectEqual(.activate, step(&s, .{ .now = 250 * ms, .active = false, .on_tab = true, .on_pane = false, .editing = false, .on_delay = fast }));
    try testing.expectEqual(.none, step(&s, .{ .now = 300 * ms, .active = true, .on_tab = false, .on_pane = false, .editing = false, .on_delay = fast }));
    try testing.expectEqual(.deactivate, step(&s, .{ .now = 700 * ms, .active = true, .on_tab = false, .on_pane = false, .editing = false, .on_delay = fast }));
}
