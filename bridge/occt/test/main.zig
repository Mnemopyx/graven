const std = @import("std");
const c = @import("occt_shim");

fn line(x0: f64, y0: f64, x1: f64, y1: f64) c.os_segment {
    return .{ .kind = c.OS_LINE, .pts = .{ x0, y0, x1, y1, 0, 0, 0, 0 } };
}

fn check(rc: c_int) !void {
    if (rc != c.OS_OK) {
        std.debug.print("shim error: {s}\n", .{std.mem.span(c.os_last_error())});
        return error.Occt;
    }
}

fn addFace(doc: *c.os_doc, name: [*:0]const u8, rgb: [3]f64, contours: []const c.os_contour, expected: f64) !void {
    var area: f64 = 0;
    try check(c.os_doc_add_face(doc, name, &rgb, contours.ptr, contours.len, &area));
    std.debug.print("{s}: area {d:.9} (expected {d:.9}, diff {e})\n", .{ name, area, expected, area - expected });
    if (@abs(area - expected) > 1e-7) return error.AreaMismatch;
}

pub fn main() !void {
    var doc: ?*c.os_doc = null;
    try check(c.os_doc_new(&doc));
    defer c.os_doc_free(doc);
    const d = doc.?;

    // 10 x 10 square with a 4 x 4 hole; the hole runs the same direction on purpose.
    const outer = [_]c.os_segment{ line(0, 0, 10, 0), line(10, 0, 10, 10), line(10, 10, 0, 10), line(0, 10, 0, 0) };
    const hole = [_]c.os_segment{ line(3, 3, 7, 3), line(7, 3, 7, 7), line(7, 7, 3, 7), line(3, 7, 3, 3) };
    try addFace(d, "white: square with hole", .{ 1, 1, 1 }, &.{
        .{ .segs = &outer, .count = outer.len },
        .{ .segs = &hole, .count = hole.len },
    }, 84.0);

    // Cubic "D": exact area 48.
    const dshape = [_]c.os_segment{
        .{ .kind = c.OS_CUBIC, .pts = .{ 0, 0, 8, 0, 8, 10, 0, 10 } },
        line(0, 10, 0, 0),
    };
    try addFace(d, "gold: cubic D", .{ 0.85, 0.65, 0.13 }, &.{.{ .segs = &dshape, .count = dshape.len }}, 48.0);

    // Quadratic arch: exact area 100/3.
    const arch = [_]c.os_segment{
        .{ .kind = c.OS_QUAD, .pts = .{ 0, 0, 5, 10, 10, 0, 0, 0 } },
        line(10, 0, 0, 0),
    };
    try addFace(d, "blue: quadratic arch", .{ 0.2, 0.4, 0.8 }, &.{.{ .segs = &arch, .count = arch.len }}, 100.0 / 3.0);

    // Error path: a zero-length edge must come back as an error, not a crash.
    const bad = [_]c.os_segment{line(1, 1, 1, 1)};
    const rc = c.os_doc_add_face(d, "bad", &[3]f64{ 0, 0, 0 }, &[_]c.os_contour{.{ .segs = &bad, .count = 1 }}, 1, null);
    std.debug.print("degenerate input -> rc={d}, message: {s}\n", .{ rc, std.mem.span(c.os_last_error()) });
    if (rc == c.OS_OK) return error.ExpectedFailure;

    try check(c.os_doc_write_step(d, "legend_test.step"));
    std.debug.print("wrote legend_test.step\n", .{});
}
