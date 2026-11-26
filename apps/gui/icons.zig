//! Graven's interface icons: Phosphor's duotone set (MIT; see
//! icons/phosphor), drawn as two layers. Each icon is a tone (Phosphor's
//! paths at 20% opacity) under its line art; the tone takes an accent
//! colour (by default the theme's focus colour, so a pane's own hue), the
//! lines the text colour.
//!
//! The SVGs are embedded; each is split into its tone and its lines and
//! converted to TinyVG once, on first use.

const std = @import("std");
const dvui = @import("dvui");

pub const Icon = enum {
    push_pin,
    push_pin_slash,
    x,
    x_circle,
    arrows_clockwise,
    stack,
    rows,
    caret_up,
    caret_down,
    trash,
    plus_circle,
    text_aa,
    list_plus,
    selection_plus,
    paint_brush,
    magnet,
    arrow_square_in,
    magic_wand,
    hand,
    hand_grabbing,
    lock,
    download_simple,
    caret_right,
    folder_open,
    file_plus,
    file,
    clock_counter_clockwise,
    megaphone,
    monitor,
    plus,
    square_split_horizontal,
    square_split_vertical,
    toolbox,
    eye,
    eye_slash,
    dots_six_vertical,

    /// The SVG, as Phosphor ships it ("push-pin-duotone.svg").
    fn svg(comptime i: Icon) []const u8 {
        const name = comptime blk: {
            var buf: [@tagName(i).len]u8 = @tagName(i)[0..].*;
            std.mem.replaceScalar(u8, &buf, '_', '-');
            const out = buf;
            break :blk out;
        };
        return @embedFile("icons/phosphor/" ++ name ++ "-duotone.svg");
    }
};

/// Graven's own icons (scripts/icons.py writes them from the style rules:
/// outlined, regions filled by kind of thing, a dashed outline for the
/// container a tool works inside). Drawn in their own colours.
pub const GIcon = enum {
    add_panel,
    add_rows,
    add_columns,
    add_track,
    fit_to_tiles,
    construction_line,
    layers,
    zoom_to_context,
    select_boundaries,
    select_area,
    new_sketch,
    add_shape,
    constrain,
    text_style,
    geo_point,
    geo_segment,
    geo_circle,
    geo_arc,
    geo_line,
    geo_ray,
    geo_edge,
    con_coincident,
    con_horizontal,
    con_vertical,
    con_on_object,
    con_locked,
    con_distance,
    con_distance_x,
    con_distance_y,
    con_line_distance,
    con_radius,
    con_diameter,
    con_angle,
    con_parallel,
    con_perpendicular,
    con_tangent,
    con_equal,
    con_equal_distance,
    con_symmetric,

    fn svg(comptime g: GIcon) []const u8 {
        const name = comptime blk: {
            var buf: [@tagName(g).len]u8 = @tagName(g)[0..].*;
            std.mem.replaceScalar(u8, &buf, '_', '-');
            const out = buf;
            break :blk out;
        };
        return @embedFile("icons/graven/" ++ name ++ ".svg");
    }
};

var gcache: [@typeInfo(GIcon).@"enum".field_names.len]?[]const u8 = @splat(null);

/// Graven icon `g` as TinyVG (converted once), or null if it would not.
pub fn graven(comptime g: GIcon) ?[]const u8 {
    const k = @intFromEnum(g);
    if (gcache[k]) |t| return t;
    const t = dvui.svgToTvg(dvui.currentWindow().gpa, g.svg()) catch return null;
    gcache[k] = t;
    return t;
}

/// `graven` for an icon chosen at run time.
pub fn gravenAny(g: GIcon) ?[]const u8 {
    return switch (g) {
        inline else => |c| graven(c),
    };
}

/// Graven icon `g`'s name in the icon files ("add-panel").
pub fn gravenFileName(g: GIcon) []const u8 {
    const names = comptime blk: {
        const fields = @typeInfo(GIcon).@"enum".field_names;
        var out: [fields.len][]const u8 = undefined;
        for (fields, 0..) |f, i| {
            var buf: [f.len]u8 = f[0..].*;
            std.mem.replaceScalar(u8, &buf, '_', '-');
            const done = buf;
            out[i] = &done;
        }
        break :blk out;
    };
    return names[@intFromEnum(g)];
}

/// The icon-file name of `tvg` if it is one of Graven's own icons.
pub fn gravenNameOf(tvg: []const u8) ?[]const u8 {
    for (gcache, 0..) |c, i| if (c) |t| if (t.ptr == tvg.ptr) return gravenFileName(@enumFromInt(i));
    return null;
}

/// Whether `tvg` is one of Graven's own icons (drawn in its own colours).
pub fn isGraven(tvg: []const u8) bool {
    for (gcache) |c| if (c) |t| if (t.ptr == tvg.ptr) return true;
    return false;
}

const Layers = struct { tone: []const u8, line: []const u8 };

var cache: [@typeInfo(Icon).@"enum".field_names.len]?Layers = @splat(null);

/// An SVG holding only the paths of `svg` with an opacity (`tone`) or
/// only those without, opacity dropped and currentColor made black (the
/// colour is set when drawing).
fn part(a: std.mem.Allocator, svg: []const u8, tone: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const head_end = (std.mem.indexOf(u8, svg, ">") orelse return error.BadSvg) + 1;
    const head = try std.mem.replaceOwned(u8, a, svg[0..head_end], "currentColor", "#000000");
    try out.appendSlice(a, head);
    var i = head_end;
    while (std.mem.indexOfPos(u8, svg, i, "<path")) |start| {
        const end = (std.mem.indexOfPos(u8, svg, start, "/>") orelse break) + 2;
        const p = svg[start..end];
        const has_opacity = std.mem.indexOf(u8, p, "opacity=") != null;
        if (has_opacity == tone) {
            // Drop the opacity attribute: the layer's colour carries it.
            if (std.mem.indexOf(u8, p, " opacity=\"")) |o| {
                const close = std.mem.indexOfScalarPos(u8, p, o + 10, '"') orelse p.len - 1;
                try out.appendSlice(a, p[0..o]);
                try out.appendSlice(a, p[close + 1 ..]);
            } else try out.appendSlice(a, p);
        }
        i = end;
    }
    try out.appendSlice(a, "</svg>");
    return out.items;
}

fn layers(comptime i: Icon) ?Layers {
    const k = @intFromEnum(i);
    if (cache[k]) |l| return l;
    const gpa = dvui.currentWindow().gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const svg = i.svg();
    const tone = dvui.svgToTvg(gpa, part(arena.allocator(), svg, true) catch return null) catch return null;
    const line = dvui.svgToTvg(gpa, part(arena.allocator(), svg, false) catch return null) catch {
        gpa.free(tone);
        return null;
    };
    cache[k] = .{ .tone = tone, .line = line };
    return cache[k];
}

pub const ButtonOptions = struct {
    /// The tone's colour; null for the theme's focus colour, faded.
    tone: ?dvui.Color = null,
    /// Icon size, logical pixels.
    size: f32 = 18,
    id_extra: usize = 0,
    /// The button's look otherwise (margins, gravity).
    opts: dvui.Options = .{},
    /// Where it was drawn, natural pixels (for a pop-up hung from it).
    rect_out: ?*dvui.Rect.Natural = null,
};

/// An icon button, its tooltip saying what it does (also its accessible
/// name). Returns whether it was clicked.
pub fn button(src: std.builtin.SourceLocation, comptime i: Icon, tip: []const u8, bo: ButtonOptions) bool {
    var bw: dvui.ButtonWidget = undefined;
    const defaults: dvui.Options = .{ .padding = .all(4), .label = .{ .text = tip }, .id_extra = bo.id_extra };
    bw.init(src, .{}, defaults.override(bo.opts));
    bw.processEvents();
    bw.drawBackground();
    const t = dvui.themeGet();
    const line_color = t.color(.control, .text);
    const tone_color = bo.tone orelse t.focus.opacity(0.35);
    const l = layers(i);
    {
        var ov = dvui.overlay(@src(), .{ .gravity_x = 0.5, .gravity_y = 0.5, .min_size_content = .{ .w = bo.size, .h = bo.size } });
        defer ov.deinit();
        if (l) |ly| {
            const icon_opts: dvui.Options = .{ .expand = .both, .role = .none };
            dvui.icon(@src(), "", ly.tone, .{ .fill_color = .{ .color = tone_color }, .stroke_color = .{ .color = tone_color } }, icon_opts);
            dvui.icon(@src(), "", ly.line, .{ .fill_color = .{ .color = line_color }, .stroke_color = .{ .color = line_color } }, icon_opts.override(.{ .id_extra = 1 }));
        } else {
            dvui.labelNoFmt(@src(), "?", .{}, .{});
        }
    }
    const clicked = bw.clicked();
    bw.drawFocus();
    const rect = bw.data().borderRectScale().r;
    if (bo.rect_out) |ro| ro.* = rect.toNatural();
    bw.deinit();
    // Its own ID: many icon buttons share one parent, and this source line.
    const tip_id = (@as(usize, src.line) *% 1_000_003) +% (@as(usize, src.column) *% 7919) +% bo.id_extra;
    dvui.tooltip(@src(), .{ .active_rect = rect }, "{s}", .{tip}, .{ .id_extra = tip_id });
    return clicked;
}

/// Icon `i` as a widget of its own, `size` logical pixels square: for a
/// row that is a button as a whole (an icon beside its label).
pub fn image(src: std.builtin.SourceLocation, comptime i: Icon, size: f32, id_extra: usize, tone: ?dvui.Color) void {
    const t = dvui.themeGet();
    const line_color = t.color(.control, .text);
    const tone_color = tone orelse t.focus.opacity(0.35);
    var ov = dvui.overlay(src, .{ .id_extra = id_extra, .gravity_y = 0.5, .min_size_content = .{ .w = size, .h = size }, .max_size_content = .{ .w = size, .h = size } });
    defer ov.deinit();
    const l = layers(i) orelse return;
    const icon_opts: dvui.Options = .{ .expand = .both, .role = .none };
    dvui.icon(@src(), "", l.tone, .{ .fill_color = .{ .color = tone_color }, .stroke_color = .{ .color = tone_color } }, icon_opts);
    dvui.icon(@src(), "", l.line, .{ .fill_color = .{ .color = line_color }, .stroke_color = .{ .color = line_color } }, icon_opts.override(.{ .id_extra = 1 }));
}

/// Draws icon `i` into `r` (physical pixels), its lines in `line` and
/// its tone in `tone`: for a mark drawn on the canvas, not a widget.
pub fn drawAt(comptime i: Icon, r: dvui.Rect.Physical, line: dvui.Color, tone: dvui.Color) void {
    const l = layers(i) orelse return;
    const rs: dvui.RectScale = .{ .r = r, .s = r.h / 256 };
    dvui.renderIcon(@tagName(i) ++ "-tone", l.tone, rs, .{}, .{ .fill_color = .{ .color = tone }, .stroke_color = .{ .color = tone } }) catch {};
    dvui.renderIcon(@tagName(i) ++ "-line", l.line, rs, .{}, .{ .fill_color = .{ .color = line }, .stroke_color = .{ .color = line } }) catch {};
}

/// Frees the converted icons (at exit).
pub fn deinit(gpa: std.mem.Allocator) void {
    for (&cache) |*c| if (c.*) |l| {
        gpa.free(l.tone);
        gpa.free(l.line);
        c.* = null;
    };
}
