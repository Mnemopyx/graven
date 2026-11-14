//! Runs a part's fabrication plan (graven_layout's fab.Plan) through OCCT:
//! one solid per colour, none overlapping. Each step's pieces are swept
//! separately and joined; a subtract cuts its volume from every solid so
//! far; an add cuts its volume from the other colours' solids and joins
//! its own colour's.

const std = @import("std");
const c = @import("occt_shim");
const layout = @import("graven_layout");
const geom = @import("graven_engine").geom;
const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{Occt};

pub const Part = struct {
    colour: layout.model.FabColour,
    solid: *c.os_solid,
    volume: f64 = 0,
    valid: bool = false,
};

pub const Result = struct {
    parts: []Part,
    /// The volume colours share (should be 0), mm³.
    overlap: f64,
    /// Pieces OCCT would not sweep: "layer: reason", skipped.
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

/// Builds `steps`. `a` holds temporary geometry and the messages; the
/// parts are allocated from `gpa` (free with `Result.deinit`).
pub fn build(gpa: Allocator, a: Allocator, steps: []const layout.fab.Step, layer_names: []const []const u8, trace: bool) Error!Result {
    var parts: std.ArrayList(Part) = .empty;
    errdefer {
        for (parts.items) |p| c.os_solid_free(p.solid);
        parts.deinit(gpa);
    }
    var skipped: std.ArrayList([]const u8) = .empty;
    var clock = Clock.start();
    for (steps, 0..) |st, si| {
        _ = clock.lap();
        const swept = (try sweep(a, st, layer_names, &skipped, trace)) orelse continue;
        defer c.os_solid_free(swept);
        const t_sweep = clock.lap();
        defer if (trace) std.debug.print("    step {d} ({s}, {s}, {d} pieces): sweep+join {d:.0} ms, apply {d:.0} ms\n", .{ si, layer_names[st.layer], @tagName(st.op), st.pieces.len, t_sweep, clock.lap() });
        switch (st.op) {
            .subtract => for (parts.items) |*p| try replace(p, cutOf(p.solid, swept)),
            .add => |col| {
                var own: ?*Part = null;
                for (parts.items) |*p| {
                    if (std.mem.eql(u8, p.colour.name, col.name)) {
                        own = p;
                    } else try replace(p, cutOf(p.solid, swept));
                }
                if (own) |p| {
                    var out: ?*c.os_solid = null;
                    const both = [_]*const c.os_solid{ p.solid, swept };
                    try check(c.os_solid_fuse(&both, 2, &out));
                    c.os_solid_free(p.solid);
                    p.solid = out.?;
                } else {
                    var copy: ?*c.os_solid = null;
                    const one = [_]*const c.os_solid{swept};
                    try check(c.os_solid_fuse(&one, 1, &copy));
                    try parts.append(gpa, .{ .colour = col, .solid = copy.? });
                }
            },
        }
    }
    // Volumes, validity, and what colours share.
    _ = clock.lap();
    defer if (trace) std.debug.print("    checks {d:.0} ms\n", .{clock.lap()});
    var overlap: f64 = 0;
    for (parts.items, 0..) |*p, i| {
        var v: f64 = 0;
        var ok: c_int = 0;
        try check(c.os_solid_props(p.solid, &v, &ok));
        p.volume = v;
        p.valid = ok == 1;
        for (parts.items[i + 1 ..]) |q| {
            var common: ?*c.os_solid = null;
            try check(c.os_solid_common(p.solid, q.solid, &common));
            defer c.os_solid_free(common);
            var cv: f64 = 0;
            try check(c.os_solid_props(common.?, &cv, null));
            overlap += @abs(cv);
        }
    }
    return .{ .parts = try parts.toOwnedSlice(gpa), .overlap = overlap, .skipped = skipped.items };
}

fn cutOf(a: *const c.os_solid, b: *const c.os_solid) Error!*c.os_solid {
    var out: ?*c.os_solid = null;
    try check(c.os_solid_cut(a, b, &out));
    return out.?;
}

fn replace(p: *Part, next: Error!*c.os_solid) Error!void {
    const s = try next;
    c.os_solid_free(p.solid);
    p.solid = s;
}

/// A step's pieces swept and joined; null when none sweeps.
fn sweep(a: Allocator, st: layout.fab.Step, layer_names: []const []const u8, skipped: *std.ArrayList([]const u8), trace: bool) Error!?*c.os_solid {
    var clock = Clock.start();
    var solids: std.ArrayList(*c.os_solid) = .empty;
    defer for (solids.items) |s| c.os_solid_free(s);
    for (st.pieces, 0..) |piece, pi| {
        const contours = try contoursOf(a, piece);
        if (contours.len == 0) continue;
        var s: ?*c.os_solid = null;
        if (c.os_solid_extrude(contours.ptr, contours.len, st.z0, st.z1, &s) != c.OS_OK) {
            const name = if (st.layer < layer_names.len) layer_names[st.layer] else "?";
            try skipped.append(a, try std.fmt.allocPrint(a, "{s}, piece {d}: {s}", .{ name, pi, lastError() }));
            continue;
        }
        try solids.append(a, s.?);
    }
    if (solids.items.len == 0) return null;
    const t_extrude = clock.lap();
    var out: ?*c.os_solid = null;
    try check(c.os_solid_fuse(@ptrCast(solids.items.ptr), solids.items.len, &out));
    if (trace) std.debug.print("      extrude {d} pieces {d:.0} ms, join {d:.0} ms\n", .{ solids.items.len, t_extrude, clock.lap() });
    return out.?;
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
const Clock = struct {
    last: i128,

    fn now() i128 {
        var ts: std.posix.timespec = undefined;
        _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
        return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    }

    fn start() Clock {
        return .{ .last = now() };
    }

    fn lap(cl: *Clock) f64 {
        const t = now();
        defer cl.last = t;
        return @as(f64, @floatFromInt(t - cl.last)) / 1e6;
    }
};
