//! Ghost panes: a container for the app's side and bottom panes.
//!
//! A pane is attached to one edge of the app window and has a tab along
//! that edge, as long as the pane. Its mode, chosen by icons on the tab:
//!
//! * ghost: drawn translucently over the canvas, which keeps the pointer
//!   (the pane's subwindow takes no mouse events). Clicking the tab makes
//!   it active: less translucent, taking the pointer and keyboard within
//!   its bounds. Clicking the tab again returns it to ghost.
//! * docked: always takes events within its bounds; the caller lays the
//!   canvas out beside it.
//! * hidden: only the tab shows.
//!
//! Each pane's content is drawn in one hue at several lightness levels
//! (its theme), so it reads apart from the canvas showing through. Clicks
//! on the canvas never change a pane's activation. Several panes may be
//! active at once while their bounds do not overlap.
//!
//! Immediate mode: the caller keeps a `Pane` per pane, calls `tab` while
//! laying out the window's edge strips, and `begin`/`Open.end` around the
//! content of a ghost pane (or `themePush`/`themePop` around a docked
//! one), then `hotEdges` once a frame.

const std = @import("std");
const dvui = @import("dvui");
pub const dwell = @import("dwell.zig");

pub const Edge = enum { left, right, top, bottom };
pub const Mode = enum { ghost, docked, hidden };

/// How a pane looks: its dominant hue, and how opaque it is.
pub const Look = struct {
    /// OKLCH hue, degrees.
    hue: f32,
    /// The background's opacity while ghost, and the content's.
    ghost_fill: f32 = 0.28,
    ghost_content: f32 = 0.78,
    /// The background's opacity while active or docked.
    active_fill: f32 = 0.93,
};

pub const Pane = struct {
    name: []const u8,
    edge: Edge,
    /// Its size across its edge (a side pane's width, a bottom pane's
    /// height), logical pixels.
    size: f32,
    look: Look,
    mode: Mode = .ghost,
    /// A ghost pane taking events.
    active: bool = false,
    hot: dwell.State = .{},
    /// Where it was drawn this frame, physical pixels; empty when it is not
    /// drawn as a ghost.
    rect_px: dvui.Rect.Physical = .{},
    tab_px: dvui.Rect.Physical = .{},
    /// Its floating window's subwindow, while it is a ghost.
    sub_id: ?dvui.Id = null,

    /// Whether it takes events within its bounds.
    pub fn interactive(p: *const Pane) bool {
        return p.mode == .docked or (p.mode == .ghost and p.active);
    }

    /// Whether one of its fields (or any of its widgets) has the keyboard.
    pub fn hasFocus(p: *const Pane) bool {
        const id = p.sub_id orelse return false;
        return p.mode == .ghost and dvui.focusedSubwindowId() == id;
    }
};

/// A colour from OKLCH (perceptual lightness `l` 0..1, chroma `c`, hue
/// `h` degrees), clipped into sRGB.
pub fn oklch(l: f32, c: f32, h: f32, alpha: f32) dvui.Color {
    const hr = h * std.math.pi / 180;
    const a = c * @cos(hr);
    const b = c * @sin(hr);
    const l_ = l + 0.3963377774 * a + 0.2158037573 * b;
    const m_ = l - 0.1055613458 * a - 0.0638541728 * b;
    const s_ = l - 0.0894841775 * a - 1.2914855480 * b;
    const lc = l_ * l_ * l_;
    const mc = m_ * m_ * m_;
    const sc = s_ * s_ * s_;
    const lin = [3]f32{
        4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc,
        -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc,
        -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc,
    };
    var out: [3]u8 = undefined;
    for (lin, &out) |x, *o| {
        const v = std.math.clamp(x, 0, 1);
        const g = if (v <= 0.0031308) 12.92 * v else 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
        o.* = @intFromFloat(@round(std.math.clamp(g, 0, 1) * 255));
    }
    return .{ .r = out[0], .g = out[1], .b = out[2], .a = @intFromFloat(@round(std.math.clamp(alpha, 0, 1) * 255)) };
}

/// Lightness levels for a pane's content, light and dark.
const Levels = struct { text: f32, muted: f32, fill: f32, control: f32, hover: f32, press: f32, border: f32, focus: f32, highlight: f32 };
const light: Levels = .{ .text = 0.30, .muted = 0.45, .fill = 0.97, .control = 0.91, .hover = 0.87, .press = 0.82, .border = 0.72, .focus = 0.55, .highlight = 0.86 };
const dark: Levels = .{ .text = 0.90, .muted = 0.75, .fill = 0.24, .control = 0.32, .hover = 0.37, .press = 0.42, .border = 0.48, .focus = 0.72, .highlight = 0.40 };

/// `base` with its colours drawn from the pane's hue.
pub fn theme(look: Look, base: dvui.Theme) dvui.Theme {
    const lv = if (base.dark) dark else light;
    const h = look.hue;
    var t = base;
    const text = oklch(lv.text, 0.09, h, 1);
    const border = oklch(lv.border, 0.06, h, 1);
    t.text = text;
    t.text_hover = text;
    t.text_press = text;
    t.fill = oklch(lv.fill, 0.025, h, 1);
    t.fill_hover = null;
    t.fill_press = null;
    t.border = border;
    t.focus = oklch(lv.focus, 0.15, h, 1);
    t.text_select = oklch(lv.highlight, 0.08, h, 1);
    t.control = .{
        .fill = oklch(lv.control, 0.04, h, 1),
        .fill_hover = oklch(lv.hover, 0.05, h, 1),
        .fill_press = oklch(lv.press, 0.06, h, 1),
        .text = text,
        .border = border,
    };
    t.window = .{ .fill = oklch(lv.fill, 0.03, h, 1), .text = text, .border = border };
    t.highlight = .{
        .fill = oklch(lv.highlight, 0.08, h, 1),
        .fill_hover = oklch(lv.hover, 0.08, h, 1),
        .fill_press = oklch(lv.press, 0.09, h, 1),
        .text = text,
        .border = border,
    };
    return t;
}

/// The pane's background colour as drawn now.
pub fn fill(p: *const Pane) dvui.Color {
    const t = theme(p.look, dvui.themeGet());
    return t.window.fill.?.opacity(if (p.interactive()) p.look.active_fill else p.look.ghost_fill);
}

/// Sets the pane's theme for content drawn until `themePop`.
pub fn themePush(p: *const Pane) dvui.Theme {
    const prev = dvui.themeGet();
    dvui.themeSet(theme(p.look, prev));
    return prev;
}

pub fn themePop(prev: dvui.Theme) void {
    dvui.themeSet(prev);
}

/// A ghost pane open for its content; `end` closes it.
pub const Open = struct {
    fw: *dvui.FloatingWindowWidget,
    prev_theme: dvui.Theme,
    prev_alpha: f32,

    pub fn end(o: *Open) void {
        o.fw.deinit();
        dvui.alphaSet(o.prev_alpha);
        dvui.themeSet(o.prev_theme);
    }
};

/// Opens ghost pane `p` at `r` (logical pixels, window coordinates) for
/// its content.
pub fn begin(p: *Pane, r: dvui.Rect, id_extra: usize) Open {
    var rect = r;
    const prev_theme = themePush(p);
    const t = dvui.themeGet();
    const fw = dvui.floatingWindow(@src(), .{ .rect = &rect, .resize = .none }, .{
        .id_extra = id_extra,
        .background = true,
        .color_fill = .{ .color = fill(p) },
        .border = .all(1),
        .color_border = .{ .color = t.border.opacity(if (p.active) 0.9 else 0.35) },
        .corners = .all(0),
        .box_shadow = null,
    });
    const id = fw.data().id;
    p.sub_id = id;
    p.rect_px = fw.data().borderRectScale().r;
    // A ghost lets the pointer through to what lies under it.
    if (dvui.currentWindow().subwindows.get(id)) |sw| sw.mouse_events = p.active;
    const prev_alpha = if (p.active) dvui.alpha(1) else dvui.alpha(p.look.ghost_content);
    return .{ .fw = fw, .prev_theme = prev_theme, .prev_alpha = prev_alpha };
}

/// What a click on a tab asked for.
pub const TabResult = union(enum) { none, toggle, mode: Mode };

/// The pane's tab at `r` (logical pixels, relative to the current parent,
/// a strip along the window's edge): its body toggles the pane between
/// ghost and active; its icons choose the mode. Tabs always take events.
pub fn tab(p: *Pane, r: dvui.Rect, id_extra: usize) TabResult {
    const t = theme(p.look, dvui.themeGet());
    const lv = if (dvui.themeGet().dark) dark else light;
    const body_l: f32 = if (p.interactive()) lv.focus else if (p.mode == .hidden) lv.border else lv.highlight;
    const vertical = p.edge == .left or p.edge == .right;
    var tb = dvui.box(@src(), .{ .dir = if (vertical) .vertical else .horizontal }, .{
        .rect = r,
        .id_extra = id_extra,
        .background = true,
        .color_fill = .{ .color = oklch(body_l, 0.09, p.look.hue, 1) },
        .padding = .all(1),
    });
    defer tb.deinit();
    p.tab_px = tb.data().borderRectScale().r;
    var result: TabResult = .none;
    _ = dvui.spacer(@src(), .{ .expand = if (vertical) .vertical else .horizontal });
    const icons = [_]struct { mode: Mode, name: []const u8, icon: []const u8, tip: []const u8 }{
        .{ .mode = .ghost, .name = "Ghost", .icon = dvui.entypo.layers, .tip = "Ghost: over the canvas, letting clicks through until its tab is clicked" },
        .{ .mode = .docked, .name = "Dock", .icon = dvui.entypo.pin, .tip = "Docked: beside the canvas, always taking clicks" },
        .{ .mode = .hidden, .name = "Hide", .icon = dvui.entypo.eye_with_line, .tip = "Hidden: only this tab shows" },
    };
    for (icons, 0..) |ic, i| {
        const on = p.mode == ic.mode;
        var wd: dvui.WidgetData = undefined;
        if (dvui.buttonIcon(@src(), ic.name, ic.icon, .{}, .{ .fill_color = .{ .color = if (on) t.text else t.text.opacity(0.45) }, .stroke_color = .{ .color = if (on) t.text else t.text.opacity(0.45) } }, .{
            .id_extra = i,
            .data_out = &wd,
            .min_size_content = .{ .w = 11, .h = 11 },
            .padding = .all(1),
            .margin = .all(1),
            .background = on,
            .color_fill = .{ .color = t.control.fill.? },
            .corners = .all(2),
        })) result = .{ .mode = ic.mode };
        dvui.tooltip(@src(), .{ .active_rect = wd.borderRectScale().r }, "{s}: {s}", .{ p.name, ic.tip }, .{ .id_extra = i });
    }
    // A click anywhere else on the tab.
    if (result == .none) for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, tb.data())) continue;
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (me.action == .press and me.button.pointer()) {
            e.handle(@src(), tb.data());
            result = .toggle;
        } else if (me.action == .position) {
            dvui.cursorSet(.hand);
        }
    };
    return result;
}

/// Applies a tab's result to its pane: a toggle, or a new mode. Panes
/// that `p` would overlap once active return to ghost.
pub fn apply(panes: []const *Pane, p: *Pane, r: TabResult) void {
    switch (r) {
        .none => return,
        .toggle => {
            p.hot.clicked();
            switch (p.mode) {
                .ghost => if (p.active) deactivate(p) else activate(panes, p),
                .hidden => {
                    p.mode = .ghost;
                    activate(panes, p);
                },
                .docked => {},
            }
        },
        .mode => |m| {
            p.hot.clicked();
            p.mode = m;
            if (m != .ghost) deactivate(p);
        },
    }
}

/// Makes ghost pane `p` take events; any active pane it overlaps (as last
/// drawn) returns to ghost.
pub fn activate(panes: []const *Pane, p: *Pane) void {
    for (panes) |q| {
        if (q == p or !q.active or q.mode != .ghost) continue;
        if (overlap(q.rect_px, p.rect_px)) deactivate(q);
    }
    p.active = true;
}

/// Returns ghost pane `p` to ghost. If it had the keyboard, the main
/// window takes it back.
pub fn deactivate(p: *Pane) void {
    if (p.hasFocus()) dvui.focusSubwindow(dvui.currentWindow().data().id, null);
    p.active = false;
}

fn overlap(a: dvui.Rect.Physical, b: dvui.Rect.Physical) bool {
    if (a.w <= 0 or a.h <= 0 or b.w <= 0 or b.h <= 0) return false;
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

/// Hot edges, once a frame: holding the pointer on a ghost pane's tab
/// activates it; moving off a pane activated that way returns it to ghost.
/// Keeps a timer running while one is waiting.
pub fn hotEdges(panes: []const *Pane, timer_id: dvui.Id) void {
    const now = dvui.frameTimeNS();
    const mouse = dvui.currentWindow().mouse_pt;
    var soonest: ?i128 = null;
    for (panes) |p| {
        if (p.mode != .ghost) {
            p.hot = .{};
            continue;
        }
        const action = dwell.step(&p.hot, .{
            .now = now,
            .active = p.active,
            .on_tab = p.tab_px.contains(mouse),
            .on_pane = p.rect_px.contains(mouse),
            .editing = p.hasFocus(),
        });
        switch (action) {
            .none => {},
            .activate => {
                activate(panes, p);
                p.hot.by_hover = true;
                dvui.refresh(null, @src(), timer_id);
            },
            .deactivate => {
                deactivate(p);
                dvui.refresh(null, @src(), timer_id);
            },
        }
        if (dwell.wait(p.hot, now)) |w| soonest = if (soonest) |s| @min(s, w) else w;
    }
    if (soonest) |w| {
        const us: i32 = @intCast(@min(@divTrunc(w, 1000) + 1, std.math.maxInt(i32)));
        dvui.timer(timer_id, us);
    }
}

test {
    _ = dwell;
}
