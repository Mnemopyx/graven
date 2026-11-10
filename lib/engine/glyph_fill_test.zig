//! Glyph outlines through the canvas's overlap resolution: the boundary
//! loops must bound exactly what the triangles fill, at every zoom. (A
//! vertex a hair off its scanline level once cut loops short: a stray chord
//! across an O's counter, a diagonal through a Q.)

const std = @import("std");
const geom = @import("graven_geom");
const font = @import("graven_font");

fn sq(x: f64) f64 {
    return x * x;
}

fn flatten(a: std.mem.Allocator, pts: *std.ArrayList(geom.Point), s: geom.Segment, tol: f64) !void {
    switch (s) {
        .line => |p| try pts.append(a, p[1]),
        .quad => |p| {
            const dev = 0.25 * @sqrt(sq(p[0].x - 2 * p[1].x + p[2].x) + sq(p[0].y - 2 * p[1].y + p[2].y));
            const n: usize = @max(1, @as(usize, @intFromFloat(@ceil(@sqrt(dev / tol)))));
            for (1..n + 1) |i| {
                const t: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
                const u = 1 - t;
                try pts.append(a, .{ .x = u * u * p[0].x + 2 * u * t * p[1].x + t * t * p[2].x, .y = u * u * p[0].y + 2 * u * t * p[1].y + t * t * p[2].y });
            }
        },
        .cubic => |p| {
            const d1 = @sqrt(sq(p[0].x - 2 * p[1].x + p[2].x) + sq(p[0].y - 2 * p[1].y + p[2].y));
            const d2 = @sqrt(sq(p[1].x - 2 * p[2].x + p[3].x) + sq(p[1].y - 2 * p[2].y + p[3].y));
            const dev = 0.75 * @max(d1, d2);
            const n: usize = @max(1, @as(usize, @intFromFloat(@ceil(@sqrt(dev / tol)))));
            for (1..n + 1) |i| {
                const t: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
                const u = 1 - t;
                try pts.append(a, .{
                    .x = u * u * u * p[0].x + 3 * u * u * t * p[1].x + 3 * u * t * t * p[2].x + t * t * t * p[3].x,
                    .y = u * u * u * p[0].y + 3 * u * u * t * p[1].y + 3 * u * t * t * p[2].y + t * t * t * p[3].y,
                });
            }
        },
    }
}

fn signedArea(loop: []const geom.Point) f64 {
    var s: f64 = 0;
    for (loop, 0..) |p, i| {
        const q = loop[(i + 1) % loop.len];
        s += p.x * q.y - q.x * p.y;
    }
    return s / 2;
}

test "glyph outlines resolve to loops that bound exactly their fill, at every zoom" {
    const gpa = std.testing.allocator;
    const testdata = @import("graven_testdata");
    var bad: usize = 0;
    var runs: usize = 0;
    for ([_][]const u8{ testdata.truetype, testdata.cff }) |bytes| {
        const face = try font.Face.init(gpa, bytes, 0);
        defer face.deinit();
        const cap = (try face.capHeight()).?;
        const k = 3.0 / cap;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var ch: u21 = 33;
        while (ch < 127) : (ch += 1) {
            const gid = face.glyph(ch) orelse continue;
            const o = try face.outline(gid);
            if (o.contours.len == 0) continue;
            var ppm: f64 = 1.5;
            while (ppm < 200) : (ppm *= 1.04) {
                _ = arena.reset(.retain_capacity);
                const tol = 0.2 / ppm;
                const polys = try a.alloc([]const geom.Point, o.contours.len);
                for (o.contours, polys) |c, *poly| {
                    var pts: std.ArrayList(geom.Point) = .empty;
                    for (c.segments) |sg| try flatten(a, &pts, sg.transformed(geom.Affine.scale(k)), tol);
                    poly.* = pts.items;
                }
                const r = try geom.fill.nonzero(a, polys, tol * 0.1);
                var got: f64 = 0;
                for (r.loops) |l| got += signedArea(l);
                var tri: f64 = 0;
                for (r.triangles) |t| tri += @abs(signedArea(&t));
                runs += 1;
                if (@abs(got - tri) > 0.002 * tri + 1e-9) {
                    bad += 1;
                    if (bad < 10) std.debug.print("'{u}' at {d:.1} px/mm: loops {d:.4} mm², fill {d:.4} mm²\n", .{ ch, ppm, got, tri });
                }
            }
        }
    }
    try std.testing.expect(runs > 100);
    try std.testing.expectEqual(0, bad);
}
