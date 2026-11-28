//! SVG now; the OCCT bridge handoff, Gerber and mirrored output later.

const std = @import("std");
const font = @import("graven_font");
const place = @import("place.zig");
const art = @import("art.zig");
const figure = @import("figure.zig");

const geom = @import("graven_geom");

pub const SvgOptions = struct {
    /// Margin around `box`, mm.
    margin: f64 = 1,
    fill: []const u8 = "#000",
    /// Drawn as lines in this colour, not filled (a cutter's paths).
    stroke: ?[]const u8 = null,
    stroke_width: f64 = 0.01,
};

/// Outlines (mm, y up) as one SVG path per outline, filled nonzero, with
/// the page sized to `box` plus a margin. Quadratics are written as Q,
/// cubics as C: nothing is flattened.
pub fn svg(gpa: std.mem.Allocator, outlines: []const geom.Outline, box: geom.Box, opts: SvgOptions) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    const x0 = box.x0 - opts.margin;
    const y1 = box.y1 + opts.margin;
    const width = box.width() + 2 * opts.margin;
    const height = box.height() + 2 * opts.margin;
    try w.print(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}mm\" height=\"{d}mm\" viewBox=\"0 0 {d} {d}\">\n",
        .{ width, height, width, height },
    );
    // Flip y: SVG's y points down.
    if (opts.stroke) |st|
        try w.print("<g transform=\"matrix(1 0 0 -1 {d} {d})\" fill=\"none\" stroke=\"{s}\" stroke-width=\"{d}\">\n", .{ -x0, y1, st, opts.stroke_width })
    else
        try w.print("<g transform=\"matrix(1 0 0 -1 {d} {d})\" fill=\"{s}\" fill-rule=\"nonzero\">\n", .{ -x0, y1, opts.fill });
    for (outlines) |o| {
        if (o.contours.len == 0) continue;
        try w.writeAll("<path d=\"");
        for (o.contours) |c| {
            const s0 = c.segments[0].start();
            try w.print("M{d} {d}", .{ s0.x, s0.y });
            for (c.segments) |s| switch (s) {
                .line => |p| try w.print("L{d} {d}", .{ p[1].x, p[1].y }),
                .quad => |p| try w.print("Q{d} {d} {d} {d}", .{ p[1].x, p[1].y, p[2].x, p[2].y }),
                .cubic => |p| try w.print("C{d} {d} {d} {d} {d} {d}", .{ p[1].x, p[1].y, p[2].x, p[2].y, p[3].x, p[3].y }),
                .conic => |k| try conicData(w, k),
            };
            try w.writeAll("Z");
        }
        try w.writeAll("\"/>\n");
    }
    try w.writeAll("</g>\n</svg>\n");
    return out.toOwnedSlice();
}

pub const PanelSvgOptions = struct {
    margin: f64 = 2,
    ink: []const u8 = "#1d1d1b",
    /// A panel with an outline of its own (see `Placed.edge`): its body,
    /// holes cut through, and its edge.
    body: []const u8 = "#f2efe8",
    edge: []const u8 = "#333333",
    edge_width: f64 = 0.2,
    /// Draw the placed labels (v1's renders).
    labels: bool = true,
    /// Further outlines drawn in the ink, mm in the panel frame (engine
    /// v2's legends, set in place of v1's).
    extra: []const geom.Outline = &.{},
};

/// A placed panel for display: each tile drawn from its prototype's art as
/// placement stretched it (gradients as SVG gradients), labels as their
/// exact outlines (Q and C kept). Display output only; production geometry
/// goes through union and DRC.
pub fn panelSvg(gpa: std.mem.Allocator, placed: *const place.Placed, faces: []const *font.Face, opts: PanelSvgOptions) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    // A panel's drawing is the panel: its content is clipped to its edge
    // (below), so the edge bounds it.
    const box = if (placed.edge) |e| e.bounds() else placed.bounds;
    const x0 = box.x0 - opts.margin;
    const y1 = box.y1 + opts.margin;
    const width = box.width() + 2 * opts.margin;
    const height = box.height() + 2 * opts.margin;
    try w.print(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}mm\" height=\"{d}mm\" viewBox=\"0 0 {d} {d}\">\n",
        .{ width, height, width, height },
    );
    try w.print("<g transform=\"matrix(1 0 0 -1 {d} {d})\">\n", .{ -x0, y1 });
    var gradients: usize = 0;
    // The panel's body: its outline with the cutouts and holes cut out of
    // it, exactly (a hole across the edge leaves a notch, overlapping holes
    // cut their union).
    if (placed.edge) |e| {
        try w.print("<path fill=\"{s}\" fill-rule=\"evenodd\" stroke=\"{s}\" stroke-width=\"{d}\" d=\"", .{ opts.body, opts.edge, opts.edge_width });
        try pathData(w, placed.body orelse e);
        try w.writeAll("\"/>\n");
    }
    // Cutouts with no panel around them (loose, on a canvas): outlined.
    if (placed.edge == null) for (placed.art) |pa| if (pa.cutout) for (pa.shapes) |s| {
        try w.print("<path fill=\"none\" stroke=\"{s}\" stroke-width=\"{d}\" d=\"", .{ opts.edge, opts.edge_width });
        try pathData(w, s.outline);
        try w.writeAll("\"/>\n");
    };
    // Tiles, then the panel's line art over them.
    var shapes: std.ArrayList(art.Shape) = .empty;
    for (placed.tiles) |t| if (t.grid != .hole) try shapes.appendSlice(a, t.shapes);
    for (placed.art) |pa| if (!pa.cutout) try shapes.appendSlice(a, pa.shapes);
    // Paragraph rules, in their pens' colours.
    for (placed.rules) |r| try shapes.appendSlice(a, r.shapes);
    // Whatever lies over a panel is clipped to its edge, as made (fab.zig):
    // fills and glyphs exactly (geom.boolean.clip), a stroke reaching the
    // edge by the panel's outline as a clip path.
    var clip_written = false;
    for (shapes.items) |s0| {
        var s = s0;
        if (placed.edge) |e| {
            const kept = try geom.boolean.clip(a, &.{s.outline}, e);
            s.outline = if (kept.len > 0) kept[0] else continue;
        }
        if (s.outline.contours.len == 0) continue;
        var fill_buf: [32]u8 = undefined;
        const fill: []const u8 = switch (s.paint.fill) {
            .none => "none",
            .solid => |c| try colour(&fill_buf, c),
            .linear => |l| blk: {
                // In user space, so it sits where placement put it.
                var b0: [16]u8 = undefined;
                var b1: [16]u8 = undefined;
                try w.print("<linearGradient id=\"g{d}\" gradientUnits=\"userSpaceOnUse\" x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\">", .{ gradients, l.from.x, l.from.y, l.to.x, l.to.y });
                try w.print("<stop offset=\"0\" stop-color=\"{s}\"/><stop offset=\"1\" stop-color=\"{s}\"/></linearGradient>\n", .{ try colour(&b0, l.start), try colour(&b1, l.end) });
                gradients += 1;
                break :blk try std.fmt.bufPrint(&fill_buf, "url(#g{d})", .{gradients - 1});
            },
        };
        // A stroke reaching the edge: clipped by the panel's outline.
        const clipped = if (placed.edge) |pe| blk: {
            if (s.paint.edge == null) break :blk false;
            const hw = s.paint.edge_width / 2;
            const ob = s.outline.bounds();
            if (!geom.boolean.touches(pe, .{ .x0 = ob.x0 - hw, .y0 = ob.y0 - hw, .x1 = ob.x1 + hw, .y1 = ob.y1 + hw })) break :blk false;
            if (!clip_written) {
                try w.writeAll("<clipPath id=\"panel-edge\"><path d=\"");
                try pathData(w, pe);
                try w.writeAll("\"/></clipPath>\n");
                clip_written = true;
            }
            break :blk true;
        } else false;
        try w.print("<path fill=\"{s}\"", .{fill});
        if (clipped) try w.writeAll(" clip-path=\"url(#panel-edge)\"");
        if (s.paint.edge) |e| {
            var b: [16]u8 = undefined;
            try w.print(" stroke=\"{s}\" stroke-width=\"{d}\"", .{ try colour(&b, e), s.paint.edge_width });
        }
        try w.writeAll(" d=\"");
        try pathData(w, s.outline);
        try w.writeAll("\"/>\n");
    }
    try w.print("<g fill=\"{s}\" fill-rule=\"nonzero\">\n", .{opts.ink});
    for (opts.extra) |o| try path(w, o);
    if (opts.labels) for (placed.labels) |l| {
        const outlines = try l.render.outlines(a, faces);
        for (outlines) |o| {
            const moved = try o.transformed(a, l.frame());
            if (placed.edge) |e| {
                for (try geom.boolean.clip(a, &.{moved}, e)) |k| try path(w, k);
            } else try path(w, moved);
        }
    };
    try w.writeAll("</g>\n</g>\n</svg>\n");
    return out.toOwnedSlice();
}

pub const FigureSvgOptions = struct {
    /// Margin round the drawing, mm.
    margin: f64 = 1,
    /// Strokes written as the outlines of the area their pens cover
    /// (`figure.ink`: caps, joins and dashes made into filled shapes), for
    /// a cutter or a tool that ignores stroke attributes; off, as their
    /// centrelines with SVG stroke attributes.
    outline_strokes: bool = false,
    /// How closely flattened curves follow the true ones when outlining,
    /// mm.
    tol: f64 = 0.002,
};

/// A drawing (a figure, mm, y up) as SVG: only its ink, back to front, in
/// a page sized to it. By default each stroked path is its centreline,
/// exact (lines, Q, C, arcs as A), with the stroke's colour, width, cap,
/// join, miter limit and dashes as SVG attributes; fills are filled paths
/// (even-odd as kept). With `outline_strokes`, every mark is a filled
/// outline instead, made by the shared stroker (`figure.ink`).
pub fn figureSvg(gpa: std.mem.Allocator, f: figure.Figure, opts: FigureSvgOptions) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    const shapes: []const art.Shape = if (opts.outline_strokes) try figure.ink(a, f, opts.tol) else &.{};
    var box: geom.Box = .empty;
    if (opts.outline_strokes) {
        for (shapes) |s| box = box.join(s.outline.bounds());
    } else box = f.bounds();
    if (box.isEmpty()) box = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
    const x0 = box.x0 - opts.margin;
    const y1 = box.y1 + opts.margin;
    const width = box.width() + 2 * opts.margin;
    const height = box.height() + 2 * opts.margin;
    try w.print(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}mm\" height=\"{d}mm\" viewBox=\"0 0 {d} {d}\">\n",
        .{ width, height, width, height },
    );
    try w.writeAll("<title>");
    try xmlText(w, f.name);
    try w.writeAll("</title>\n");
    // Flip y: SVG's y points down.
    try w.print("<g transform=\"matrix(1 0 0 -1 {d} {d})\">\n", .{ -x0, y1 });
    var b0: [32]u8 = undefined;
    if (opts.outline_strokes) {
        for (shapes) |s| {
            if (s.outline.contours.len == 0) continue;
            const c = switch (s.paint.fill) {
                .solid => |c| c,
                else => continue,
            };
            try w.print("<path fill=\"{s}\" fill-rule=\"nonzero\" d=\"", .{try colour(&b0, c)});
            try pathData(w, s.outline);
            try w.writeAll("\"/>\n");
        }
    } else for (f.paths) |p| {
        if (p.fill) |c| {
            try w.print("<path fill=\"{s}\" fill-rule=\"{s}\" d=\"", .{ try colour(&b0, c), @tagName(p.fill_rule) });
            try subpathsData(w, p.subpaths, true);
            try w.writeAll("\"/>\n");
        }
        if (p.stroke) |st| {
            if (!(st.width > 0)) continue;
            try w.print("<path fill=\"none\" stroke=\"{s}\" stroke-width=\"{d}\" stroke-linecap=\"{s}\" stroke-linejoin=\"{s}\"", .{ try colour(&b0, st.color), st.width, @tagName(st.cap), @tagName(st.join) });
            if (st.join == .miter) try w.print(" stroke-miterlimit=\"{d}\"", .{st.miter_limit});
            if (st.dash.len > 0) {
                try w.writeAll(" stroke-dasharray=\"");
                for (st.dash, 0..) |d, i| try w.print("{s}{d}", .{ if (i == 0) "" else " ", @max(0, d) });
                try w.writeAll("\"");
                if (st.dash_offset != 0) try w.print(" stroke-dashoffset=\"{d}\"", .{st.dash_offset});
            }
            try w.writeAll(" d=\"");
            try subpathsData(w, p.subpaths, false);
            try w.writeAll("\"/>\n");
        }
    }
    try w.writeAll("</g>\n</svg>\n");
    return out.toOwnedSlice();
}

/// Subpaths as path data, exactly; a closed one (or, with `close_all`,
/// every one: a fill closes an open one with a line) ends in Z.
fn subpathsData(w: *std.Io.Writer, subs: []const figure.Subpath, close_all: bool) !void {
    for (subs) |sp| {
        if (sp.segments.len == 0) continue;
        try segmentsData(w, sp.segments);
        if (sp.closed or close_all) try w.writeAll("Z");
    }
}

fn segmentsData(w: *std.Io.Writer, segs: []const geom.Segment) !void {
    const s0 = segs[0].start();
    try w.print("M{d} {d}", .{ s0.x, s0.y });
    for (segs) |s| switch (s) {
        .line => |p| try w.print("L{d} {d}", .{ p[1].x, p[1].y }),
        .quad => |p| try w.print("Q{d} {d} {d} {d}", .{ p[1].x, p[1].y, p[2].x, p[2].y }),
        .cubic => |p| try w.print("C{d} {d} {d} {d} {d} {d}", .{ p[1].x, p[1].y, p[2].x, p[2].y, p[3].x, p[3].y }),
        .conic => |k| try conicData(w, k),
    };
}

fn xmlText(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        else => try w.writeByte(ch),
    };
}

/// "#rrggbb", with "rgba(…)" only for a translucent colour.
fn colour(buf: []u8, c: art.Color) ![]const u8 {
    if (c.a == 255) return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b });
    return std.fmt.bufPrint(buf, "rgba({d},{d},{d},{d:.3})", .{ c.r, c.g, c.b, @as(f64, @floatFromInt(c.a)) / 255 });
}

/// A conic as SVG path data, exactly: an elliptical arc (A) for one of
/// weight below 1, a quadratic (Q) for weight 1. The arc's radii and
/// rotation come from its conjugate semi-diameters (the singular values of
/// the map from the unit circle); it is never more than half a turn, and
/// its sweep follows the way it turns in the path's own (y-up) frame.
fn conicData(w: *std.Io.Writer, k: geom.Conic) !void {
    const p = k.p;
    if (@abs(k.w - 1) < 1e-12 or k.w >= 1 or k.w <= 0) {
        // Not an ellipse: a parabola is a quadratic; others (never made by
        // Graven) are written as their parabola, flagged by nothing.
        return w.print("Q{d} {d} {d} {d}", .{ p[1].x, p[1].y, p[2].x, p[2].y });
    }
    const e = k.ellipse();
    // M = [a b] (columns); M = U S V^T, with U a rotation by phi.
    const m00 = e.a.x;
    const m01 = e.b.x;
    const m10 = e.a.y;
    const m11 = e.b.y;
    const E = (m00 + m11) / 2;
    const F = (m00 - m11) / 2;
    const G = (m10 + m01) / 2;
    const H = (m10 - m01) / 2;
    const Q = @sqrt(E * E + H * H);
    const R = @sqrt(F * F + G * G);
    const rx = Q + R;
    const ry = @abs(Q - R);
    const phi = (std.math.atan2(H, E) + std.math.atan2(G, F)) / 2;
    const turn = (p[1].x - p[0].x) * (p[2].y - p[1].y) - (p[1].y - p[0].y) * (p[2].x - p[1].x);
    const sweep: u8 = if (turn > 0) 1 else 0;
    try w.print("A{d} {d} {d} 0 {d} {d} {d}", .{ rx, ry, phi * 180 / std.math.pi, sweep, p[2].x, p[2].y });
}

fn path(w: *std.Io.Writer, o: geom.Outline) !void {
    if (o.contours.len == 0) return;
    try w.writeAll("<path d=\"");
    try pathData(w, o);
    try w.writeAll("\"/>\n");
}

fn pathData(w: *std.Io.Writer, o: geom.Outline) !void {
    for (o.contours) |c| {
        if (c.segments.len == 0) continue;
        try segmentsData(w, c.segments);
        try w.writeAll("Z");
    }
}

test "svg writes native quadratics and closes every contour" {
    const segs = [_]geom.Segment{
        .{ .line = .{ .{ .x = 0, .y = 0 }, .{ .x = 6, .y = 0 } } },
        .{ .quad = .{ .{ .x = 6, .y = 0 }, .{ .x = 3, .y = 6 }, .{ .x = 0, .y = 0 } } },
    };
    const contours = [_]geom.Contour{.{ .segments = &segs }};
    const outlines = [_]geom.Outline{.{ .contours = &contours }};
    const text = try svg(std.testing.allocator, &outlines, (geom.Outline{ .contours = &contours }).bounds(), .{});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "M0 0L6 0Q3 6 0 0Z") != null);
}

test "svg writes arcs exactly, as elliptical arcs" {
    const testing = std.testing;
    var buf: [4]geom.Segment = undefined;
    const circle = geom.arc(.{ .x = 0, .y = 0 }, 2, 0, 2 * std.math.pi, &buf);
    const o: geom.Outline = .{ .contours = &.{.{ .segments = circle }} };
    const text = try svg(testing.allocator, &.{o}, o.bounds(), .{});
    defer testing.allocator.free(text);
    // Four quarter arcs of radius 2, turning counter-clockwise.
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, text, "A"));
    var arcs = std.mem.splitScalar(u8, text, 'A');
    _ = arcs.next();
    while (arcs.next()) |rest| {
        var f = std.mem.tokenizeAny(u8, rest, " ");
        try testing.expectApproxEqAbs(@as(f64, 2), try std.fmt.parseFloat(f64, f.next().?), 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 2), try std.fmt.parseFloat(f64, f.next().?), 1e-9);
        _ = f.next();
        try testing.expectEqualStrings("0", f.next().?);
        try testing.expectEqualStrings("1", f.next().?);
    }
    // Stretched to an ellipse 4 by 1 and turned: the radii follow.
    const m: geom.Affine = .{ .a = 2 * @cos(0.3), .b = 2 * @sin(0.3), .c = -0.5 * @sin(0.3), .d = 0.5 * @cos(0.3) };
    var data: std.Io.Writer.Allocating = .init(testing.allocator);
    defer data.deinit();
    try conicData(&data.writer, circle[0].transformed(m).conic);
    var it = std.mem.tokenizeAny(u8, data.written()[1..], " ");
    const rx = try std.fmt.parseFloat(f64, it.next().?);
    const ry = try std.fmt.parseFloat(f64, it.next().?);
    try testing.expectApproxEqAbs(@as(f64, 4), rx, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), ry, 1e-9);
}

test "figureSvg: centrelines carry the pen; outlined, the pen's area" {
    const testing = std.testing;
    const segs = [_]geom.Segment{.{ .line = .{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 } } }};
    const subs = [_]figure.Subpath{.{ .segments = &segs }};
    const paths = [_]figure.Path{.{ .subpaths = &subs, .stroke = .{ .color = .{ .r = 255, .g = 0, .b = 0 }, .width = 0.5, .cap = .round, .dash = &.{ 2, 1 } } }};
    const f: figure.Figure = .{ .name = "a<b", .paths = &paths };
    const c = try figureSvg(testing.allocator, f, .{});
    defer testing.allocator.free(c);
    try testing.expect(std.mem.indexOf(u8, c, "stroke=\"#ff0000\" stroke-width=\"0.5\" stroke-linecap=\"round\"") != null);
    try testing.expect(std.mem.indexOf(u8, c, "stroke-dasharray=\"2 1\"") != null);
    try testing.expect(std.mem.indexOf(u8, c, "d=\"M0 0L10 0\"") != null);
    try testing.expect(std.mem.indexOf(u8, c, "<title>a&lt;b</title>") != null);
    const o = try figureSvg(testing.allocator, f, .{ .outline_strokes = true });
    defer testing.allocator.free(o);
    try testing.expect(std.mem.indexOf(u8, o, "stroke=") == null);
    // Four dashes, each its own filled outline, in one path.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, o, "<path fill=\"#ff0000\""));
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, o, "Z"));
}
