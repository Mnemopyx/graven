//! Builds a part's fabrication slabs (graven_layout's fab.slabs) as solids
//! through OCCT: each slab's colour regions, exact 2D regions worked out
//! beforehand, swept straight up as faces. No 3D booleans: the colours
//! cannot overlap, and a part takes a fraction of a second.

const std = @import("std");
const c = @import("occt_shim");
const layout = @import("graven_layout");
const geom = @import("graven_engine").geom;
const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{Occt};

pub const Part = struct {
    colour: layout.model.FabColour,
    solid: *c.os_solid,
    /// As OCCT measures it, and as the 2D areas and heights give it, mm³.
    volume: f64 = 0,
    expected: f64 = 0,
    valid: bool = false,
};

pub const Result = struct {
    parts: []Part,
    /// Faces OCCT would not sweep: "z0-z1 colour: reason", skipped.
    skipped: []const []const u8,

    pub fn deinit(r: Result, gpa: Allocator) void {
        for (r.parts) |p| c.os_solid_free(p.solid);
        gpa.free(r.parts);
    }

    /// Adds every part to `doc`, named by its colour.
    pub fn addTo(r: Result, doc: *c.os_doc, prefix: []const u8, a: Allocator) Error!void {
        for (r.parts) |p| {
            const name = try std.fmt.allocPrintSentinel(a, "{s} ({s})", .{ prefix, p.colour.name }, 0);
            const rgb = [3]f64{
                @as(f64, @floatFromInt(p.colour.color.r)) / 255,
                @as(f64, @floatFromInt(p.colour.color.g)) / 255,
                @as(f64, @floatFromInt(p.colour.color.b)) / 255,
            };
            try check(c.os_doc_add_solid(doc, name.ptr, &rgb, p.solid));
        }
    }
};

/// The shim's last error, for messages.
pub fn lastError() []const u8 {
    return std.mem.span(c.os_last_error());
}

fn check(rc: c_int) Error!void {
    if (rc != c.OS_OK) return error.Occt;
}

/// Builds `slabs`: one solid (a compound of swept faces) per colour. `a`
/// holds temporary geometry and the messages; the parts are allocated from
/// `gpa` (free with `Result.deinit`).
pub fn build(gpa: Allocator, a: Allocator, slabs: []const layout.fab.Slab, opts: struct { trace: bool = false, check: bool = false }) Error!Result {
    const Acc = struct { colour: layout.model.FabColour, solids: std.ArrayList(*c.os_solid) = .empty, expected: f64 = 0 };
    var accs: std.ArrayList(Acc) = .empty;
    defer for (accs.items) |*acc| for (acc.solids.items) |sd| c.os_solid_free(sd);
    var skipped: std.ArrayList([]const u8) = .empty;
    var clock = Clock.start();
    var faces_n: usize = 0;
    for (slabs) |slab| for (slab.regions) |reg| {
        const acc = for (accs.items) |*acc| {
            if (std.mem.eql(u8, acc.colour.name, reg.colour.name)) break acc;
        } else blk: {
            try accs.append(a, .{ .colour = reg.colour });
            break :blk &accs.items[accs.items.len - 1];
        };
        acc.expected += reg.outline.signedArea() * (slab.z1 - slab.z0);
        for (try facesOf(a, reg.outline)) |face| {
            const contours = try contoursOf(a, face);
            if (contours.len == 0) continue;
            var sd: ?*c.os_solid = null;
            if (c.os_solid_extrude_face(contours.ptr, contours.len, slab.z0, slab.z1, &sd) != c.OS_OK) {
                try skipped.append(a, try std.fmt.allocPrint(a, "{d}-{d} {s}: {s}", .{ slab.z0, slab.z1, reg.colour.name, lastError() }));
                continue;
            }
            try acc.solids.append(a, sd.?);
            faces_n += 1;
        }
    };
    const t_sweep = clock.lap();
    var parts: std.ArrayList(Part) = .empty;
    errdefer {
        for (parts.items) |p| c.os_solid_free(p.solid);
        parts.deinit(gpa);
    }
    for (accs.items) |*acc| {
        var out: ?*c.os_solid = null;
        try check(c.os_solid_compound(@ptrCast(acc.solids.items.ptr), acc.solids.items.len, &out));
        // OCCT's own measure and checker, on request (they take longer
        // than everything else); otherwise the volume is the 2D one.
        var v: f64 = acc.expected;
        var ok: c_int = 1;
        if (opts.check) try check(c.os_solid_props(out.?, &v, &ok));
        try parts.append(gpa, .{ .colour = acc.colour, .solid = out.?, .volume = v, .expected = acc.expected, .valid = ok == 1 });
    }
    const trace = opts.trace;
    if (trace) std.debug.print("    {d} slabs, {d} faces swept in {d:.0} ms, checked in {d:.0} ms\n", .{ slabs.len, faces_n, t_sweep, clock.lap() });
    return .{ .parts = try parts.toOwnedSlice(gpa), .skipped = skipped.items };
}

/// A region's faces: each outer contour (counter-clockwise, as
/// geom.boolean gives them) with the holes (clockwise) that lie in it, the
/// outer first.
fn facesOf(a: Allocator, o: geom.Outline) Allocator.Error![]const geom.Outline {
    const n = o.contours.len;
    const areas = try a.alloc(f64, n);
    const polys = try a.alloc([]const geom.Point, n);
    for (o.contours, areas, polys) |ct, *ar, *poly| {
        ar.* = ct.signedArea();
        var pts: std.ArrayList(geom.Point) = .empty;
        for (ct.segments) |sg| {
            const k: usize = if (sg == .line) 1 else 8;
            for (0..k) |i| try pts.append(a, sg.at(@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(k))));
        }
        poly.* = pts.items;
    }
    var groups = try a.alloc(std.ArrayList(geom.Contour), n);
    for (groups, o.contours, areas) |*g, ct, ar| {
        g.* = .empty;
        if (ar > 0) try g.append(a, ct);
    }
    for (o.contours, areas) |ct, ar| {
        if (ar > 0) continue;
        // The smallest outer around it.
        const p = ct.segments[0].at(0.5);
        var best: ?usize = null;
        for (polys, areas, 0..) |poly, oa, k| {
            if (oa <= 0 or !inPoly(poly, p)) continue;
            if (best == null or oa < areas[best.?]) best = k;
        }
        if (best) |k| try groups[k].append(a, ct);
    }
    var out: std.ArrayList(geom.Outline) = .empty;
    for (groups) |g| if (g.items.len > 0) try out.append(a, .{ .contours = g.items });
    return out.items;
}

fn inPoly(poly: []const geom.Point, p: geom.Point) bool {
    var inside = false;
    var j = poly.len - 1;
    for (poly, 0..) |q, i| {
        const r = poly[j];
        if ((q.y > p.y) != (r.y > p.y) and q.x + (p.y - q.y) * (r.x - q.x) / (r.y - q.y) > p.x) inside = !inside;
        j = i;
    }
    return inside;
}

/// An outline as the shim's contours, leaving out segments of no length.
fn contoursOf(a: Allocator, o: geom.Outline) Allocator.Error![]c.os_contour {
    var out: std.ArrayList(c.os_contour) = .empty;
    for (o.contours) |ct| {
        var segs: std.ArrayList(c.os_segment) = .empty;
        for (ct.segments) |sg| {
            if (degenerate(sg)) continue;
            var s: c.os_segment = .{ .kind = 0, .pts = @splat(0), .w = 0 };
            switch (sg) {
                .line => |p| {
                    s.kind = c.OS_LINE;
                    put(&s, &p);
                },
                .quad => |p| {
                    s.kind = c.OS_QUAD;
                    put(&s, &p);
                },
                .cubic => |p| {
                    s.kind = c.OS_CUBIC;
                    put(&s, &p);
                },
                .conic => |k| {
                    s.kind = c.OS_CONIC;
                    put(&s, &k.p);
                    s.w = k.w;
                },
            }
            try segs.append(a, s);
        }
        if (segs.items.len > 0) try out.append(a, .{ .segs = segs.items.ptr, .count = segs.items.len });
    }
    return out.items;
}

fn put(s: *c.os_segment, pts: []const geom.Point) void {
    for (pts, 0..) |p, i| {
        s.pts[2 * i] = p.x;
        s.pts[2 * i + 1] = p.y;
    }
}

fn degenerate(sg: geom.Segment) bool {
    const pts = sg.points();
    for (pts[1..]) |p| if (@abs(p.x - pts[0].x) > 1e-9 or @abs(p.y - pts[0].y) > 1e-9) return false;
    return true;
}

/// Milliseconds between laps (monotonic).
pub const Clock = struct {
    last: i128,

    fn now() i128 {
        var ts: std.posix.timespec = undefined;
        _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
        return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    }

    pub fn start() Clock {
        return .{ .last = now() };
    }

    pub fn lap(cl: *Clock) f64 {
        const t = now();
        defer cl.last = t;
        return @as(f64, @floatFromInt(t - cl.last)) / 1e6;
    }
};
