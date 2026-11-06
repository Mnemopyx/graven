//! SVG now; the OCCT bridge handoff, Gerber and mirrored output later.

const std = @import("std");
const engine = @import("graven_engine");
const place = @import("place.zig");

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
    body: []const u8 = "#e8e6e1",
    face: []const u8 = "#f7f6f3",
    edge: []const u8 = "#9a978f",
    ink: []const u8 = "#1d1d1b",
    /// Corner radius of tile bodies and faces, mm.
    radius: f64 = 1,
};

/// A placed panel for display: tile bodies and faces as rounded rectangles,
/// labels as their exact outlines (Q and C kept). Display output only;
/// production geometry goes through union and DRC.
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
    for (placed.tiles) |t| {
        try rect(w, t.body, opts.radius, opts.body, opts.edge);
        try rect(w, t.face, opts.radius, opts.face, null);
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

fn rect(w: *std.Io.Writer, b: geom.Box, r: f64, fill: []const u8, stroke: ?[]const u8) !void {
    try w.print("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"{d}\" fill=\"{s}\"", .{ b.x0, b.y0, b.width(), b.height(), r, fill });
    if (stroke) |s| try w.print(" stroke=\"{s}\" stroke-width=\"0.2\"", .{s});
    try w.writeAll("/>\n");
}

fn path(w: *std.Io.Writer, o: geom.Outline) !void {
    if (o.contours.len == 0) return;
    try w.writeAll("<path d=\"");
    for (o.contours) |c| {
        const s0 = c.segments[0].start();
        try w.print("M{d} {d}", .{ s0.x, s0.y });
        for (c.segments) |s| switch (s) {
            .line => |p| try w.print("L{d} {d}", .{ p[1].x, p[1].y }),
            .quad => |p| try w.print("Q{d} {d} {d} {d}", .{ p[1].x, p[1].y, p[2].x, p[2].y }),
            .cubic => |p| try w.print("C{d} {d} {d} {d} {d} {d}", .{ p[1].x, p[1].y, p[2].x, p[2].y, p[3].x, p[3].y }),
        };
        try w.writeAll("Z");
    }
    try w.writeAll("\"/>\n");
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
