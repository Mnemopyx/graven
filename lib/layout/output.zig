//! SVG now; the OCCT bridge handoff, Gerber and mirrored output later.

const std = @import("std");
const engine = @import("graven_engine");

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
