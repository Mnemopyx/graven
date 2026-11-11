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
///
/// What takes events has the visual focus. An active (or docked) pane is
/// clearly in front: the canvas still shows through, but takes effort to
/// make out. A ghost reverses that: the canvas leads, and the pane's
/// content is there to be read on purpose, not to catch the eye.
pub const Look = struct {
    /// OKLCH hue, degrees.
    hue: f32,
    /// The background's opacity while ghost, and the content's.
    ghost_fill: f32 = 0.12,
    ghost_content: f32 = 0.55,
    /// The background's opacity while active or docked.
    active_fill: f32 = 0.72,
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

// Ghost content styles -----------------------------------------------------
//
// One alpha for all of a ghost's content keeps each colour's share of its
// full contrast: what is dark and saturated stays strong, what is light
// and pale (control fills, highlights, borders) fades to nearly nothing
// against the paper. The other styles set each colour role's presence
// instead: how far (OKLab distance) it ends up from what it is seen
// against, the paper under the pane's own faint fill.

pub const Style = enum {
    /// Every colour at the pane's ghost alpha (`Look.ghost_content`).
    uniform,
    /// Each role its own alpha, to reach its presence.
    matched,
    /// As matched, with fills drawn as a deep, saturated tint of the hue
    /// at low alpha, which hides less of the canvas under it.
    tinted,
    /// As matched, with controls as outlines and no fill.
    outlined,
};

/// How a ghost's content is drawn (an experiment, chosen in View).
pub var style: Style = .uniform;
/// What a ghost is seen against: the canvas's paper.
pub var backdrop: dvui.Color = .{ .r = 0xfb, .g = 0xfa, .b = 0xf7 };

/// Each role's presence in a ghost: OKLab distance from the backdrop. At
/// full strength text is about 0.68 and a control fill 0.08; one alpha of
/// 0.55 makes those 0.36 and 0.04.
const Presence = struct {
    text: f32 = 0.34,
    muted: f32 = 0.26,
    focus: f32 = 0.24,
    border: f32 = 0.15,
    highlight: f32 = 0.12,
    press: f32 = 0.13,
    hover: f32 = 0.11,
    control: f32 = 0.09,
    /// Content backgrounds: next to nothing, the pane's fill already
    /// sets the pane apart.
    fill: f32 = 0.02,
};
const presence: Presence = .{};

fn toLab(c: dvui.Color) [3]f32 {
    var lin: [3]f32 = undefined;
    for ([3]u8{ c.r, c.g, c.b }, &lin) |x, *o| {
        const v = @as(f32, @floatFromInt(x)) / 255;
        o.* = if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
    }
    const l = std.math.cbrt(0.4122214708 * lin[0] + 0.5363325363 * lin[1] + 0.0514459929 * lin[2]);
    const m = std.math.cbrt(0.2119034982 * lin[0] + 0.6806995451 * lin[1] + 0.1073969566 * lin[2]);
    const s = std.math.cbrt(0.0883024619 * lin[0] + 0.2817188376 * lin[1] + 0.6299787005 * lin[2]);
    return .{
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    };
}

/// `c` drawn at alpha `a` over opaque `b`, as the renderer blends.
fn over(c: dvui.Color, a: f32, b: dvui.Color) dvui.Color {
    const mix = struct {
        fn f(x: u8, y: u8, t: f32) u8 {
            return @intFromFloat(@round(t * @as(f32, @floatFromInt(x)) + (1 - t) * @as(f32, @floatFromInt(y))));
        }
    }.f;
    return .{ .r = mix(c.r, b.r, a), .g = mix(c.g, b.g, a), .b = mix(c.b, b.b, a), .a = 255 };
}

fn distance(x: dvui.Color, y: dvui.Color) f32 {
    const p = toLab(x);
    const q = toLab(y);
    return @sqrt((p[0] - q[0]) * (p[0] - q[0]) + (p[1] - q[1]) * (p[1] - q[1]) + (p[2] - q[2]) * (p[2] - q[2]));
}

/// `c` with the alpha that puts it `target` from `b` (opaque when even
/// that falls short).
fn atPresence(c: dvui.Color, target: f32, b: dvui.Color) dvui.Color {
    if (distance(c, b) <= target) return c.opacity(1);
    var lo: f32 = 0;
    var hi: f32 = 1;
    for (0..14) |_| {
        const mid = (lo + hi) / 2;
        if (distance(over(c, mid, b), b) < target) lo = mid else hi = mid;
    }
    var out = c;
    out.a = @intFromFloat(@round(hi * 255));
    return out;
}

/// The theme of a ghost's content in style `st`.
pub fn ghostTheme(look: Look, base: dvui.Theme, st: Style) dvui.Theme {
    var t = theme(look, base);
    if (st == .uniform) return t;
    const h = look.hue;
    const b = over(t.window.fill.?, look.ghost_fill, backdrop);
    const pr = presence;
    // Text roles keep their colours.
    t.text = atPresence(t.text, pr.text, b);
    t.text_hover = t.text;
    t.text_press = t.text;
    t.focus = atPresence(t.focus, pr.focus, b);
    // Fills: their own colours, or a deep tint of the hue.
    const tint = oklch(0.50, 0.14, h, 1);
    const f = struct {
        fn of(own: dvui.Color, tinted: bool, deep: dvui.Color, target: f32, back: dvui.Color) dvui.Color {
            return atPresence(if (tinted) deep else own, target, back);
        }
    }.of;
    const tinted = st == .tinted;
    t.fill = f(t.fill, tinted, tint, pr.fill, b);
    if (t.text_select) |sel| t.text_select = f(sel, tinted, tint, pr.highlight, b);
    const border = atPresence(t.border, if (st == .outlined) pr.muted else pr.border, b);
    t.border = border;
    t.control = .{
        .fill = if (st == .outlined) t.control.fill.?.opacity(0) else f(t.control.fill.?, tinted, tint, pr.control, b),
        .fill_hover = f(t.control.fill_hover.?, tinted, tint, pr.hover, b),
        .fill_press = f(t.control.fill_press.?, tinted, tint, pr.press, b),
        .text = t.text,
        .border = border,
    };
    t.window = .{ .fill = f(t.window.fill.?, tinted, tint, pr.fill, b), .text = t.text, .border = border };
    t.highlight = .{
        .fill = f(t.highlight.fill.?, tinted, tint, pr.highlight, b),
        .fill_hover = f(t.highlight.fill_hover.?, tinted, tint, pr.hover, b),
        .fill_press = f(t.highlight.fill_press.?, tinted, tint, pr.press, b),
        .text = t.text,
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
        .color_border = .{ .color = t.border.opacity(if (p.active) 0.9 else 0.15) },
        .corners = .all(0),
        .box_shadow = null,
    });
    const id = fw.data().id;
    p.sub_id = id;
    p.rect_px = fw.data().borderRectScale().r;
    // A ghost lets the pointer through to what lies under it.
    if (dvui.currentWindow().subwindows.get(id)) |sw| sw.mouse_events = p.active;
    // An inactive ghost's content: one alpha for all of it, or each colour
    // at its own presence.
    if (!p.active and style != .uniform) dvui.themeSet(ghostTheme(p.look, prev_theme, style));
    const prev_alpha = if (p.active or style != .uniform) dvui.alpha(1) else dvui.alpha(p.look.ghost_content);
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
