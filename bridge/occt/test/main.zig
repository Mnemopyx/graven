const std = @import("std");
const c = @import("occt_shim");

fn line(x0: f64, y0: f64, x1: f64, y1: f64) c.os_segment {
    return .{ .kind = c.OS_LINE, .pts = .{ x0, y0, x1, y1, 0, 0, 0, 0 }, .w = 0 };
}

/// A square from (x0, y0), `side` across, counter-clockwise.
fn square(x0: f64, y0: f64, side: f64) [4]c.os_segment {
    const x1 = x0 + side;
    const y1 = y0 + side;
    return .{ line(x0, y0, x1, y0), line(x1, y0, x1, y1), line(x1, y1, x0, y1), line(x0, y1, x0, y0) };
}

/// A circle as four exact conic quarter arcs.
fn circle(cx: f64, cy: f64, r: f64) [4]c.os_segment {
    const w = @sqrt(0.5); // cos 45 degrees: a quarter turn
    const p = [5][2]f64{ .{ cx + r, cy }, .{ cx, cy + r }, .{ cx - r, cy }, .{ cx, cy - r }, .{ cx + r, cy } };
    const k = [4][2]f64{ .{ cx + r, cy + r }, .{ cx - r, cy + r }, .{ cx - r, cy - r }, .{ cx + r, cy - r } };
    var out: [4]c.os_segment = undefined;
    for (0..4) |i| out[i] = .{ .kind = c.OS_CONIC, .pts = .{ p[i][0], p[i][1], k[i][0], k[i][1], p[i + 1][0], p[i + 1][1], 0, 0 }, .w = w };
    return out;
}

fn contour(segs: []const c.os_segment) c.os_contour {
    return .{ .segs = segs.ptr, .count = segs.len };
}

fn extrude(contours: []const c.os_contour, z0: f64, z1: f64) !*c.os_solid {
    var s: ?*c.os_solid = null;
    try check(c.os_solid_extrude(contours.ptr, contours.len, z0, z1, &s));
    return s.?;
}

/// Its volume, checked against `expected` and for validity.
fn expectSolid(name: []const u8, s: *const c.os_solid, expected: f64) !void {
    var v: f64 = 0;
    var valid: c_int = 0;
    try check(c.os_solid_props(s, &v, &valid));
    std.debug.print("{s}: volume {d:.9} (expected {d:.9}, diff {e}), valid {d}\n", .{ name, v, expected, v - expected, valid });
    if (@abs(v - expected) > 1e-6) return error.VolumeMismatch;
    if (valid != 1) return error.InvalidSolid;
}

/// Colour FDM in miniature: a plate with an exact round hole, and an "O"
/// legend inlaid in its top, cut out of the plate, so the two solids fill
/// the part exactly and do not overlap; and even-odd nesting three deep.
fn solids(d: *c.os_doc) !void {
    const pi = std.math.pi;
    // The plate: 20 x 10 x 2 with a hole of radius 2.
    const plate = [_]c.os_segment{ line(0, 0, 20, 0), line(20, 0, 20, 10), line(20, 10, 0, 10), line(0, 10, 0, 0) };
    const hole = circle(5, 5, 2);
    const body = try extrude(&.{ contour(&plate), contour(&hole) }, 0, 2);
    defer c.os_solid_free(body);
    const body_v = (200 - pi * 4) * 2;
    try expectSolid("plate", body, body_v);

    // The legend: an "O", a 4 mm square with a 2 mm counter, 0.6 mm deep.
    const o_out = square(12, 3, 4);
    const o_in = square(13, 4, 2);
    const legend = try extrude(&.{ contour(&o_out), contour(&o_in) }, 1.4, 2);
    defer c.os_solid_free(legend);
    try expectSolid("legend", legend, 12 * 0.6);

    // The plate with the legend cut out: together they are the plate.
    var cut: ?*c.os_solid = null;
    try check(c.os_solid_cut(body, legend, &cut));
    defer c.os_solid_free(cut);
    try expectSolid("plate less legend", cut.?, body_v - 12 * 0.6);
    var overlap: ?*c.os_solid = null;
    try check(c.os_solid_common(cut.?, legend, &overlap));
    defer c.os_solid_free(overlap);
    var ov: f64 = 0;
    try check(c.os_solid_props(overlap.?, &ov, null));
    std.debug.print("overlap: volume {e}\n", .{ov});
    if (@abs(ov) > 1e-9) return error.SolidsOverlap;

    // Three deep: an outline, a hole in it, an island in the hole.
    const a = square(0, 20, 10);
    const b = square(2, 22, 6);
    const isl = square(4, 24, 2);
    const nested = try extrude(&.{ contour(&isl), contour(&a), contour(&b) }, 0, 1);
    defer c.os_solid_free(nested);
    try expectSolid("outline, hole, island", nested, 100 - 36 + 4);

    // Bad sweep: refused.
    if (c.os_solid_extrude(&[_]c.os_contour{contour(&plate)}, 1, 2, 2, null) == c.OS_OK) return error.ExpectedFailure;

    try check(c.os_doc_add_solid(d, "plate (white)", &[3]f64{ 1, 1, 1 }, cut.?));
    try check(c.os_doc_add_solid(d, "legend (gold)", &[3]f64{ 0.85, 0.65, 0.13 }, legend));
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
        .{ .kind = c.OS_CUBIC, .pts = .{ 0, 0, 8, 0, 8, 10, 0, 10 }, .w = 0 },
        line(0, 10, 0, 0),
    };
    try addFace(d, "gold: cubic D", .{ 0.85, 0.65, 0.13 }, &.{.{ .segs = &dshape, .count = dshape.len }}, 48.0);

    // Quadratic arch: exact area 100/3.
    const arch = [_]c.os_segment{
        .{ .kind = c.OS_QUAD, .pts = .{ 0, 0, 5, 10, 10, 0, 0, 0 }, .w = 0 },
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

    // Solids, in a document of their own.
    var sdoc: ?*c.os_doc = null;
    try check(c.os_doc_new(&sdoc));
    defer c.os_doc_free(sdoc);
    try solids(sdoc.?);
    try check(c.os_doc_write_step(sdoc.?, "fdm_test.step"));
    std.debug.print("wrote fdm_test.step\n", .{});
}
