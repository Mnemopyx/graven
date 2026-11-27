//! Panes: a container for the app's side and bottom panes.
//!
//! A pane is attached to one edge of the app window and has a tab along
//! that edge, as long as the pane. Decided 2026-11-21: panes lie over the
//! canvas and never move the views (no docking; the ghost mode, shown but
//! letting clicks through, confused the content under it, and is gone).
//!
//! * auto (auto-hide, the hot edge): out of sight, only its tab showing.
//!   Holding the pointer on the tab slides it in from its edge over the
//!   canvas, ready to use, slightly translucent; once the pointer has been
//!   away a moment (and none of its fields has the keyboard) it slides back
//!   out. A click on the tab pins it in (`pinned`: it stays when the
//!   pointer leaves), another unpins it.
//! * hidden: only the tab shows (a view that has no use for the pane: a
//!   sheet's has no tools; not chosen on the tab).
//!
//! Panes are dark (grey text on deep purple), apart from the canvas, a
//! light table whose layers are overlays. Clicks on the canvas never change
//! a pane's activation. Several panes may be in at once while their bounds
//! do not overlap.
//!
//! Immediate mode: the caller keeps a `Pane` per pane, calls `tab` while
//! laying out the window's edge strips, and `begin`/`Open.end` around the
//! content of a pane drawn over the canvas (`themePush`/`themePop` around
//! one), then `hotEdges` once a frame.

const std = @import("std");
const dvui = @import("dvui");
const display = @import("display.zig");
const iconfile = @import("iconfile.zig");
pub const dwell = @import("dwell.zig");

pub const Edge = enum { left, right, top, bottom };
pub const Mode = enum { auto, hidden };

/// How a pane looks: its hue (deep purple by default), and how opaque its
/// background is over the canvas.
pub const Look = struct {
    /// OKLCH hue, degrees.
    hue: f32 = pane_hue,
    /// The background's opacity: slightly translucent.
    fill_alpha: f32 = 0.93,
};

/// The panes' hue: deep purple.
pub const pane_hue: f32 = 305;

pub const Pane = struct {
    /// Its official name: in the config, and its label's message ID
    /// (`browser`, `tools`, `properties`, `expression-bar`).
    id: []const u8,
    name: []const u8,
    edge: Edge,
    /// Its size across its edge (a side pane's width, a bottom pane's
    /// height), logical pixels.
    size: f32,
    look: Look,
    mode: Mode = .auto,
    /// In, taking events.
    active: bool = false,
    /// Pinned in: it stays when the pointer leaves (a click on its tab).
    pinned: bool = false,
    hot: dwell.State = .{},
    /// Where it was drawn this frame, physical pixels; empty when it is not
    /// drawn over the canvas.
    rect_px: dvui.Rect.Physical = .{},
    tab_px: dvui.Rect.Physical = .{},
    /// Its floating window's subwindow, while it is drawn over the canvas.
    sub_id: ?dvui.Id = null,
    /// How far an auto-hide pane is in, 0 (out of sight) to 1.
    reveal: f32 = 0,
    /// The slide under way: where it started, toward where, and when
    /// (frame time, ns).
    slide_from: f32 = 0,
    slide_to: f32 = 0,
    slide_t0: i128 = 0,
    /// Its text and controls, against the interface's own size.
    text_scale: f32 = 1,
    /// The mode the user chose, while a narrow window has made it
    /// auto-hide; given back when the window widens.
    forced: ?Mode = null,
    /// The mode it had before the active view's kind hid it (a sheet view
    /// wants no tools); given back when a view that wants it is active.
    view_hidden: ?Mode = null,

    /// Whether it takes events within its bounds.
    pub fn interactive(p: *const Pane) bool {
        return p.mode == .auto and p.active;
    }

    /// Whether it is drawn over the canvas this frame: an auto-hide pane
    /// at all in.
    pub fn drawn(p: *const Pane) bool {
        return p.mode == .auto and p.reveal > 0;
    }

    /// Whether one of its fields (or any of its widgets) has the keyboard.
    pub fn hasFocus(p: *const Pane) bool {
        const id = p.sub_id orelse return false;
        return p.mode == .auto and dvui.focusedSubwindowId() == id;
    }

    /// The mode to keep in the settings: the user's own.
    pub fn chosen(p: *const Pane) Mode {
        return p.view_hidden orelse p.forced orelse p.mode;
    }

    /// `r`, where the pane is drawn in place, moved out past its edge by as
    /// much as it is not yet in (an auto-hide pane sliding).
    pub fn slid(p: *const Pane, r: dvui.Rect) dvui.Rect {
        if (p.mode != .auto) return r;
        // Eased: quick at first, settling into place.
        const t = 1 - p.reveal;
        const out = t * t * t;
        var q = r;
        switch (p.edge) {
            .left => q.x -= out * (r.w + r.x),
            .right => q.x += out * r.w,
            .top => q.y -= out * (r.h + r.y),
            .bottom => q.y += out * r.h,
        }
        return q;
    }
};

/// How long an auto-hide pane takes to slide in or out, s.
pub const slide_s: f32 = 0.16;
/// How long the pointer must stay on an auto-hide pane's tab to bring it
/// in, ns.
pub const auto_delay_ns: i128 = 250 * std.time.ns_per_ms;

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

/// Whether a pane's colours take a share of the most chroma their hue can
/// show at each lightness (an experiment, chosen in View), rather than the
/// fixed, muted chromas.
pub var vivid = false;

/// Whether OKLCH `l`, `c`, `h` lies within sRGB.
fn inGamut(l: f32, c: f32, h: f32) bool {
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
    for (lin) |x| if (x < -0.0001 or x > 1.0001) return false;
    return true;
}

/// The most chroma hue `h` can show at lightness `l` within sRGB.
pub fn maxChroma(l: f32, h: f32) f32 {
    var lo: f32 = 0;
    var hi: f32 = 0.4;
    for (0..20) |_| {
        const mid = (lo + hi) / 2;
        if (inGamut(l, mid, h)) lo = mid else hi = mid;
    }
    return lo;
}

/// A role's chroma: `fixed`, or when vivid, `share` of the most its hue
/// can show at lightness `l`.
fn chroma(l: f32, h: f32, fixed: f32, share: f32) f32 {
    return if (vivid) share * maxChroma(l, h) else fixed;
}

/// Lightness levels for a pane's content, light and dark.
const Levels = struct { text: f32, muted: f32, fill: f32, control: f32, hover: f32, press: f32, border: f32, focus: f32, highlight: f32 };
const light: Levels = .{ .text = 0.30, .muted = 0.45, .fill = 0.97, .control = 0.91, .hover = 0.87, .press = 0.82, .border = 0.72, .focus = 0.55, .highlight = 0.86 };
const dark: Levels = .{ .text = 0.90, .muted = 0.75, .fill = 0.24, .control = 0.32, .hover = 0.37, .press = 0.42, .border = 0.48, .focus = 0.72, .highlight = 0.40 };

/// `base` with its colours drawn from the pane's hue, through the display
/// correction.
pub fn theme(look: Look, base: dvui.Theme) dvui.Theme {
    var t = rawTheme(look, base);
    fixDerived(&t);
    return t;
}

/// The colours `rawTheme` sets, through the display correction (the rest
/// came from `base`, already corrected).
fn fixDerived(t: *dvui.Theme) void {
    t.text = display.fix(t.text);
    t.text_hover = display.fixOpt(t.text_hover);
    t.text_press = display.fixOpt(t.text_press);
    t.fill = display.fix(t.fill);
    t.border = display.fix(t.border);
    t.focus = display.fix(t.focus);
    t.text_select = display.fixOpt(t.text_select);
    display.fixAll(dvui.Color, &t.control);
    display.fixAll(dvui.Color, &t.window);
    display.fixAll(dvui.Color, &t.highlight);
}

fn rawTheme(look: Look, base: dvui.Theme) dvui.Theme {
    const lv = if (base.dark) dark else light;
    const h = look.hue;
    var t = base;
    // Grey text on a dark pane; tinted on a light one.
    const text = oklch(lv.text, if (base.dark) 0.012 else chroma(lv.text, h, 0.09, 0.9), h, 1);
    const border = oklch(lv.border, chroma(lv.border, h, 0.06, 0.8), h, 1);
    t.text = text;
    t.text_hover = text;
    t.text_press = text;
    t.fill = oklch(lv.fill, chroma(lv.fill, h, if (base.dark) 0.075 else 0.025, 0.6), h, 1);
    t.fill_hover = null;
    t.fill_press = null;
    t.border = border;
    t.focus = oklch(lv.focus, chroma(lv.focus, h, 0.15, 0.95), h, 1);
    t.text_select = oklch(lv.highlight, chroma(lv.highlight, h, 0.08, 0.85), h, 1);
    t.control = .{
        .fill = oklch(lv.control, chroma(lv.control, h, 0.04, 0.85), h, 1),
        .fill_hover = oklch(lv.hover, chroma(lv.hover, h, 0.05, 0.85), h, 1),
        .fill_press = oklch(lv.press, chroma(lv.press, h, 0.06, 0.85), h, 1),
        .text = text,
        .border = border,
    };
    t.window = .{ .fill = oklch(lv.fill, chroma(lv.fill, h, if (base.dark) 0.08 else 0.03, 0.6), h, 1), .text = text, .border = border };
    t.highlight = .{
        .fill = oklch(lv.highlight, chroma(lv.highlight, h, 0.08, 0.85), h, 1),
        .fill_hover = oklch(lv.hover, chroma(lv.hover, h, 0.08, 0.85), h, 1),
        .fill_press = oklch(lv.press, chroma(lv.press, h, 0.09, 0.85), h, 1),
        .text = text,
        .border = border,
    };
    return t;
}

/// The theme a pane's colours derive from: dark, whatever the app's.
fn paneBase(base: dvui.Theme) dvui.Theme {
    var b = base;
    b.dark = true;
    return b;
}

/// The pane's background colour: its theme's, slightly translucent.
pub fn fill(p: *const Pane) dvui.Color {
    const t = theme(p.look, paneBase(dvui.themeGet()));
    return t.window.fill.?.opacity(p.look.fill_alpha);
}

/// The family text fields and table cells are set in (one with legends'
/// characters, which the interface's font lacks), or "" for the theme's.
pub var field_family: []const u8 = "";

/// Text fields' font, following the theme in use: its body size, in
/// `field_family`.
pub fn fieldFont() dvui.Font {
    const f = dvui.Font.theme(.body);
    return if (field_family.len > 0) f.withFamily(field_family) else f;
}

/// Every text field drawn from now takes `fieldFont`, at the theme's size.
pub fn fieldsFollowTheme() void {
    if (field_family.len == 0) return;
    dvui.TextEntryWidget.defaults.font = fieldFont();
}

/// The panes' dark theme, for what is drawn as they are (the ribbon's drop
/// panels).
pub fn darkTheme(base: dvui.Theme) dvui.Theme {
    return theme(.{}, paneBase(base));
}

/// Sets the pane's theme for content drawn until `themePop`.
pub fn themePush(p: *const Pane) dvui.Theme {
    const prev = dvui.themeGet();
    dvui.themeSet(scaled(theme(p.look, paneBase(prev)), p.text_scale));
    fieldsFollowTheme();
    return prev;
}

/// Theme `t` with its fonts `k` times their size.
pub fn scaled(t: dvui.Theme, k: f32) dvui.Theme {
    if (k == 1) return t;
    var out = t;
    out.font_body.size *= k;
    out.font_heading.size *= k;
    out.font_title.size *= k;
    out.font_mono.size *= k;
    return out;
}

pub fn themePop(prev: dvui.Theme) void {
    dvui.themeSet(prev);
    fieldsFollowTheme();
}

/// A pane drawn over the canvas, open for its content; `end` closes it.
pub const Open = struct {
    fw: *dvui.FloatingWindowWidget,
    prev_theme: dvui.Theme,
    /// A bottom or top pane's row (its heading at the left), and the column
    /// its content goes in (below the heading in a side pane).
    row: ?*dvui.BoxWidget = null,
    col: ?*dvui.BoxWidget = null,

    pub fn end(o: *Open) void {
        if (o.col) |b| b.deinit();
        if (o.row) |b| b.deinit();
        o.fw.deinit();
        dvui.themeSet(o.prev_theme);
        fieldsFollowTheme();
    }
};

/// Opens pane `p` over the canvas at `r` (logical pixels, window
/// coordinates) for its content.
pub fn begin(p: *Pane, r: dvui.Rect, id_extra: usize) Open {
    var rect = r;
    const prev_theme = themePush(p);
    const t = dvui.themeGet();
    const had_focus = dvui.focusedSubwindowId();
    const fw = dvui.floatingWindow(@src(), .{ .rect = &rect, .resize = .none }, .{
        .id_extra = id_extra,
        .background = true,
        .color_fill = .{ .color = fill(p) },
        .border = .all(1),
        .color_border = .{ .color = t.border.opacity(0.9) },
        .corners = .all(0),
        .box_shadow = null,
    });
    const id = fw.data().id;
    // A floating window takes the keyboard when it first appears; a pane
    // appearing (sliding in) gives it back.
    if (dvui.firstFrame(id) and had_focus != id) dvui.focusSubwindow(had_focus, null);
    p.sub_id = id;
    p.rect_px = fw.data().borderRectScale().r;
    // Sliding out, it lets the pointer through.
    if (dvui.currentWindow().subwindows.get(id)) |sw| sw.mouse_events = p.interactive();
    var o: Open = .{ .fw = fw, .prev_theme = prev_theme };
    // Its heading: its icon and name, so it is known at a glance wherever
    // it lies. Across the top of a side pane; at the left of a bottom or
    // top one, its content beside it.
    switch (p.edge) {
        .left, .right => {
            // A floating window lays its children over each other: a box
            // stacks the heading and the content.
            o.col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
            heading(p, false);
        },
        .top, .bottom => {
            o.row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
            heading(p, true);
            o.col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        },
    }
    return o;
}

/// A pane's icon in the icon files: "pane-" and its official name.
pub fn iconName(p: *const Pane, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "pane-{s}", .{p.id}) catch "";
}

/// The heading's icon's side, logical pixels (before the pane's text scale).
pub const heading_icon: f32 = 20;

/// Draws pane `p`'s icon (from the icon files) filling `r`: on the dark
/// pane (`on_dark`) light ink and dark fills, on its lighter tab the
/// file's own colours; nothing if no file has it.
pub fn drawIcon(p: *const Pane, r: dvui.Rect.Physical, on_dark: bool) void {
    var buf: [64]u8 = undefined;
    const name = iconName(p, &buf);
    const white = display.fix(dvui.Color.white);
    if (on_dark) {
        _ = iconfile.drawIn(name, r, display.fix(oklch(dark.text, 0.012, p.look.hue, 1)), white, .dark);
    } else if (iconfile.get(name)) |c| {
        _ = iconfile.drawIn(name, r, display.fix(iconfile.inkOf(c)), white, .own);
    }
}

/// Pane `p`'s heading: its icon and name, in a row across the pane's top
/// with a line below (`beside` false), or a cell at the pane's left with a
/// line at its right.
fn heading(p: *const Pane, beside: bool) void {
    const t = dvui.themeGet();
    const k = p.text_scale;
    const side = @round(heading_icon * k);
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = if (beside) .vertical else .horizontal,
            .padding = .{ .x = 6, .y = 3, .w = 8, .h = 3 },
            // Beside the content, centred across the pane; above it, at
            // the top (a centred child of a column takes its middle).
            .gravity_y = if (beside) 0.5 else 0,
        });
        defer row.deinit();
        var ic = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = side, .h = side }, .max_size_content = .size(.{ .w = side, .h = side }), .gravity_y = 0.5 });
        drawIcon(p, ic.data().contentRectScale().r, true);
        ic.deinit();
        var f = dvui.Font.theme(.heading);
        f.size = dvui.Font.theme(.body).size;
        dvui.labelNoFmt(@src(), p.name, .{}, .{ .font = f, .gravity_y = 0.5, .padding = .{ .x = 5 }, .color_text = .{ .color = t.text.opacity(0.85) } });
    }
    if (beside) {
        _ = dvui.separator(@src(), .{ .expand = .vertical, .min_size_content = .{ .w = 1 } });
    } else {
        _ = dvui.separator(@src(), .{ .expand = .horizontal });
    }
}

/// What a click on a tab asked for.
pub const TabResult = union(enum) { none, toggle, mode: Mode };

/// The pane's tab at `r` (logical pixels, relative to the current parent,
/// a strip along the window's edge): a click pins an auto-hide pane in (shown
/// over the canvas, staying when the pointer leaves) or unpins it. Tabs
/// always take events.
pub fn tab(p: *Pane, r: dvui.Rect, id_extra: usize) TabResult {
    const lv = if (dvui.themeGet().dark) dark else light;
    const body_l: f32 = if (p.interactive()) lv.focus else lv.border;
    const vertical = p.edge == .left or p.edge == .right;
    var tb = dvui.box(@src(), .{ .dir = if (vertical) .vertical else .horizontal }, .{
        .rect = r,
        .id_extra = id_extra,
        .background = true,
        .color_fill = .{ .color = display.fix(oklch(body_l, chroma(body_l, p.look.hue, 0.09, 0.9), p.look.hue, 1)) },
        .padding = .all(1),
    });
    defer tb.deinit();
    p.tab_px = tb.data().borderRectScale().r;
    {
        // Its icon at the tab's start, to know the pane by while it is out.
        const cr = tb.data().contentRectScale().r;
        const d = @min(cr.w, cr.h);
        if (d > 0) drawIcon(p, .{ .x = cr.x, .y = cr.y + (if (vertical) 2 * tb.data().contentRectScale().s else 0), .w = d, .h = d }, false);
    }
    var result: TabResult = .none;
    _ = dvui.spacer(@src(), .{ .expand = if (vertical) .vertical else .horizontal });
    // A click on the tab (the hot edge) pins the pane in, shown over the
    // canvas, or unpins it; the views are not moved. A pane the view hid
    // comes in.
    for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, tb.data())) continue;
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (me.action == .press and me.button.pointer()) {
            e.handle(@src(), tb.data());
            result = .toggle;
        } else if (me.action == .position) {
            dvui.cursorSet(.hand);
        }
    }
    return result;
}

/// Applies a tab's result to its pane: a toggle, or a new mode. Panes
/// that `p` would overlap once in go back out.
pub fn apply(panes: []const *Pane, p: *Pane, r: TabResult) void {
    switch (r) {
        .none => return,
        .toggle => {
            p.hot.clicked();
            switch (p.mode) {
                .auto => setPinned(panes, p, !p.pinned),
                .hidden => {
                    p.mode = .auto;
                    setPinned(panes, p, true);
                },
            }
        },
        .mode => |m| {
            p.hot.clicked();
            // The user's choice stands, narrow window or not, whatever
            // the view.
            p.forced = null;
            p.view_hidden = null;
            if (p.mode != .auto and m == .auto) p.reveal = 0;
            p.mode = m;
            deactivate(p);
        },
    }
}

/// Pins pane `p` in (`on`), or unpins it, sending it out.
pub fn setPinned(panes: []const *Pane, p: *Pane, on: bool) void {
    p.pinned = on;
    if (on) activate(panes, p) else deactivate(p);
}

/// Brings auto-hide pane `p` in, taking events; any pane in that it
/// overlaps (as last drawn) goes back out, unless pinned.
pub fn activate(panes: []const *Pane, p: *Pane) void {
    for (panes) |q| {
        if (q == p or !q.active or q.pinned or q.mode != .auto) continue;
        if (overlap(q.rect_px, p.rect_px)) deactivate(q);
    }
    p.active = true;
}

/// Sends auto-hide pane `p` back out. If it had the keyboard, the main
/// window takes it back.
pub fn deactivate(p: *Pane) void {
    if (p.hasFocus()) dvui.focusSubwindow(dvui.currentWindow().data().id, null);
    p.active = false;
}

fn overlap(a: dvui.Rect.Physical, b: dvui.Rect.Physical) bool {
    if (a.w <= 0 or a.h <= 0 or b.w <= 0 or b.h <= 0) return false;
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

/// Hot edges, once a frame: holding the pointer on an auto-hide pane's tab
/// brings it in; moving off a pane brought in that way sends it out.
/// Keeps a timer running while one is waiting.
pub fn hotEdges(panes: []const *Pane, timer_id: dvui.Id) void {
    const now = dvui.frameTimeNS();
    const mouse = dvui.currentWindow().mouse_pt;
    var soonest: ?i128 = null;
    for (panes) |p| {
        // Auto-hide panes answer the pointer on their tabs; a pinned one
        // stays in.
        if (p.mode != .auto or p.pinned) {
            p.hot = .{};
            continue;
        }
        const on_delay: i128 = auto_delay_ns;
        const action = dwell.step(&p.hot, .{
            .now = now,
            .active = p.active,
            .on_tab = p.tab_px.contains(mouse),
            .on_pane = p.rect_px.contains(mouse),
            // Typing in one of its fields keeps it in; a selection made in
            // it (a Browser node chosen) does not.
            .editing = p.hasFocus() and dvui.currentWindow().textInputRequested() != null,
            .on_delay = on_delay,
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
        if (dwell.wait(p.hot, now, on_delay)) |w| soonest = if (soonest) |s| @min(s, w) else w;
    }
    if (soonest) |w| {
        const us: i32 = @intCast(@min(@divTrunc(w, 1000) + 1, std.math.maxInt(i32)));
        dvui.timer(timer_id, us);
    }
}

test {
    _ = dwell;
}

/// Moves each auto-hide pane's slide on, toward in while it is active and
/// out while not; keeps frames coming while one moves.
///
/// Timed from when the slide began, not by the time since the last frame:
/// an idle window draws no frames, so the first frame of a slide can come
/// long after the one before it, and a step by that time would finish the
/// slide at once (the pane appearing or vanishing with no slide).
pub fn slide(panes: []const *Pane, timer_id: dvui.Id) void {
    const now = dvui.frameTimeNS();
    var moving = false;
    for (panes) |p| {
        if (p.mode != .auto) {
            p.reveal = 0;
            p.slide_to = 0;
            continue;
        }
        const target: f32 = if (p.active) 1 else 0;
        if (target != p.slide_to) {
            // A new slide (or a turn back mid-slide): from where it is now.
            p.slide_from = p.reveal;
            p.slide_to = target;
            p.slide_t0 = now;
        }
        if (p.reveal == target) continue;
        const t: f32 = @floatCast(@as(f64, @floatFromInt(now - p.slide_t0)) / std.time.ns_per_s);
        // The whole way takes `slide_s`; part of it, its share of that.
        const dist = @abs(target - p.slide_from);
        const done = if (dist > 0) @min(1, t / (slide_s * dist)) else 1;
        p.reveal = p.slide_from + (target - p.slide_from) * done;
        moving = true;
    }
    if (moving) dvui.refresh(null, @src(), timer_id);
}
