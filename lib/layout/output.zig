//! SVG now; the OCCT bridge handoff, Gerber and mirrored output later.

const std = @import("std");
const engine = @import("graven_engine");
const place = @import("place.zig");
const art = @import("art.zig");

const geom = engine.geom;

pub const SvgOptions = struct {
    /// Margin around `box`, mm.
    margin: f64 = 1,
    fill: []const u8 = "#000",
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
};

/// A placed panel for display: each tile drawn from its prototype's art as
/// placement stretched it (gradients as SVG gradients), labels as their
/// exact outlines (Q and C kept). Display output only; production geometry
/// goes through union and DRC.
pub fn panelSvg(gpa: std.mem.Allocator, placed: *const place.Placed, faces: []const *engine.Face, opts: PanelSvgOptions) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    const box = placed.bounds;
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
    // The panel's body: its outline with the cutouts as holes, even-odd so
    // a hole is a hole whichever way it winds.
    if (placed.edge) |e| {
        try w.print("<path fill=\"{s}\" fill-rule=\"evenodd\" stroke=\"{s}\" stroke-width=\"{d}\" d=\"", .{ opts.body, opts.edge, opts.edge_width });
        try pathData(w, e);
        for (placed.art) |pa| if (pa.cutout) for (pa.shapes) |s| try pathData(w, s.outline);
        for (placed.tiles) |t| if (t.grid == .hole) for (t.shapes) |s| try pathData(w, s.outline);
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
    for (shapes.items) |s| {
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
        try w.print("<path fill=\"{s}\"", .{fill});
        if (s.paint.edge) |e| {
            var b: [16]u8 = undefined;
            try w.print(" stroke=\"{s}\" stroke-width=\"{d}\"", .{ try colour(&b, e), s.paint.edge_width });
        }
        try w.writeAll(" d=\"");
        try pathData(w, s.outline);
        try w.writeAll("\"/>\n");
    }
    try w.print("<g fill=\"{s}\" fill-rule=\"nonzero\">\n", .{opts.ink});
    for (placed.labels) |l| {
        const outlines = try l.render.outlines(a, faces);
        for (outlines) |o| {
            const moved = try o.transformed(a, .translate(l.origin.x, l.origin.y));
            try path(w, moved);
        }
    }
    try w.writeAll("</g>\n</g>\n</svg>\n");
    return out.toOwnedSlice();
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
