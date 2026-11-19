//! The manufacture stage's checks: a panel's fabrication plan measured
//! against its process profile's limits (process.zig), each finding pass,
//! marginal or fail. The design is never changed by them (decided
//! 2026-11-16): they say where it is out of the process's reach.
//!
//! Strokes and gaps are judged as a slicer lays walls (OrcaSlicer's, after
//! PrusaSlicer and Cura): face by face, as polygons. A face is one outer
//! contour and its holes: a glyph, a hole, a part. Its outer wall's
//! centreline is the face offset inward by half a bead; the bead is that
//! centreline grown back by half a bead. What of the face no bead covers
//! is lost: a stroke too thin to print. Done at the line width (below it,
//! marginal) and at the narrowest bead the process can lay (below it,
//! fail). Space is judged the other way round: a face closed by half a
//! bead (grown, then offset back in) fills its narrow holes and notches,
//! a counter or an aperture that would close up.
//!
//! Between faces, what matters is what lies between: two marks on a part
//! (inlaid legends, holes) with the part's material between them, a mark
//! too near its part's edge, two parts with empty space between. Each
//! pair is measured by polygon distance first, and only pairs nearer than
//! a bead are cut.
//!
//! A face's own results depend only on its shape, so they are cached by
//! shape (wherever it sits): a glyph repeated across a panel is measured
//! once, and, with a cache kept between runs, once a session.
//!
//! What each band applies to:
//! - a part's material, an inlay's strokes, the material between marks
//!   or between a mark and its part's edge, a hole's notches: stroke;
//! - a cut's own width, a part's notches and the space between parts:
//!   gap.
//!
//! Opening rounds a convex corner off however wide the stroke (a square
//! corner loses r²(1 − π/4)), so a finding smaller than half a square of
//! the bead's width is not reported: a corner, not a thin part.

const std = @import("std");
const geom = @import("graven_geom");
const font = @import("graven_font");
const model = @import("model.zig");
const place = @import("place.zig");
const fab = @import("fab.zig");
const process = @import("process.zig");
const manufacture = @import("manufacture.zig");

const Allocator = std.mem.Allocator;
const Outline = geom.Outline;
const Contour = geom.Contour;
const Segment = geom.Segment;
const Point = geom.Point;
const Box = geom.Box;

pub const Verdict = process.Band.Verdict;

pub const Kind = enum {
    stroke,
    gap,
    cap,
    depth,
    colours,
    size,

    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .stroke => "Stroke",
            .gap => "Gap",
            .cap => "Cap height",
            .depth => "Depths",
            .colours => "Colours",
            .size => "Size",
        };
    }
};

/// One place, or one setting, out of the process's reach.
pub const Finding = struct {
    kind: Kind,
    verdict: Verdict,
    /// Where, mm in the panel frame (the whole part for colours and size).
    box: Box,
    /// The area itself, for stroke and gap: what no bead covers, or what
    /// closes up.
    area: ?Outline = null,
    /// The heights it spans.
    z: [2]f64 = .{ 0, 0 },
    /// The fabrication layer it is about, and the label (cap: its index in
    /// the placed labels).
    layer: ?usize = null,
    label: ?usize = null,
    /// The colour whose material is thin (stroke), when it is one's own.
    colour: ?[]const u8 = null,
    /// What was measured: a cap height or a depth (mm), a colour count.
    value: f64 = 0,
    /// For size: the part's extent (across, deep, high).
    extent: [3]f64 = .{ 0, 0, 0 },
};

/// One simulated path: a bead's centreline, closed, laid this wide in this
/// colour (FDM: a wall, mm in the panel frame).
pub const Path = struct {
    points: []const Point,
    width: f64,
    colour: model.FabColour,
    z: [2]f64,
};

pub const Report = struct {
    /// Null when the panel names no process: nothing to check against.
    profile: ?process.Profile,
    findings: []const Finding,
    /// The process simulated, where Graven can (FDM: its walls): what a
    /// slicer would lay, to compare with the design.
    paths: []const Path = &.{},
    /// Each check's worst verdict.
    worst: std.EnumArray(Kind, Verdict),
    /// What the part measures: its colours and extent.
    colours: usize = 0,
    extent: [3]f64 = .{ 0, 0, 0 },
    /// How many faces were measured, and how many came from the cache.
    faces: usize = 0,
    cached: usize = 0,
    /// Measures that could not be made (a boolean that did not join).
    unmeasured: usize = 0,

    pub fn count(r: Report, kind: Kind, verdict: Verdict) usize {
        var n: usize = 0;
        for (r.findings) |f| {
            if (f.kind == kind and f.verdict == verdict) n += 1;
        }
        return n;
    }

    /// The worst verdict of all.
    pub fn overall(r: Report) Verdict {
        var w: Verdict = .pass;
        for (std.enums.values(Kind)) |k| w = worse(w, r.worst.get(k));
        return w;
    }
};

fn worse(a: Verdict, b: Verdict) Verdict {
    return if (@intFromEnum(b) > @intFromEnum(a)) b else a;
}

/// Flattening tolerance, mm: a tenth of the narrowest half-bead (0.1 mm
/// beads, with a 0.2 mm nozzle).
pub const tolerance = 0.005;

/// A face's own results, by shape: kept between runs by whoever runs the
/// checks (the GUI, for a session), or made for one run.
pub const Cache = struct {
    arena: std.heap.ArenaAllocator,
    map: std.AutoHashMapUnmanaged(u64, []const Lost) = .empty,
    /// Pieces resolved, by shape: loops relative to the box corner.
    shapes: std.AutoHashMapUnmanaged(u64, []const Poly) = .empty,
    /// Walls laid, by shape and role: centrelines relative to the corner.
    walls: std.AutoHashMapUnmanaged(u64, []const Poly) = .empty,

    pub fn init(gpa: Allocator) Cache {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(c: *Cache) void {
        c.arena.deinit();
        c.* = undefined;
    }
};

/// A thin area, relative to its face's box corner.
const Lost = struct { kind: Kind, verdict: Verdict, contour: []const Point };

/// A polygon: its points, the closing one not repeated; the filled side
/// on its left (outer counter-clockwise, holes clockwise).
const Poly = []const Point;

/// A piece (a glyph, a hole, a part) resolved: its contours' nonzero
/// region as simple loops (overlapping contours, as fonts have, joined),
/// outer ones counter-clockwise, holes clockwise; `shape` names it
/// wherever it sits.
const Face = struct {
    polys: []const Poly,
    box: Box,
    shape: u64,
};

const Role = enum {
    /// A part's material (an added layer that is not an inlay).
    body,
    /// Material inlaid in a body: a legend.
    inlay,
    /// A hole or cut in a body.
    void,
};

const Feature = struct {
    face: Face,
    role: Role,
    z: [2]f64,
    colour: ?[]const u8,
    /// For a mark, the body it is in (its index among the features).
    body: ?usize = null,
    /// Its stackup layer (its index in the panel's fabrication).
    layer: usize = 0,
};

/// What a run checks: against which profile, and, for an operation of a
/// manufacturing plan, only the stackup layers it makes (its targets on
/// this panel), each in the colour it gives.
pub const Scope = struct {
    profile: process.Profile,
    targets: ?[]const manufacture.Target = null,
};

/// The checks of panel `panel` as `placed` lays it out (`faces`: the
/// faces its labels were set in), with `cache` (null: one for this run).
/// Allocated from `a` (an arena suits).
pub fn run(a: Allocator, m: *const model.Model, panel: usize, placed: *const place.Placed, faces: []const *font.Face, cache: ?*Cache) !Report {
    const profile = (m.processOf(panel) orelse return .{ .profile = null, .findings = &.{}, .worst = .initFill(.pass) }).*;
    return runWith(a, m, panel, placed, faces, cache, .{ .profile = profile });
}

/// Whether `scope` takes stackup layer `name` of panel `panel`, and the
/// colour it gives there.
fn inScope(m: *const model.Model, scope: Scope, panel: usize, name: []const u8) struct { yes: bool, colour: ?model.FabColour = null } {
    const ts = scope.targets orelse return .{ .yes = true };
    const id = m.panels.items[panel].id;
    for (ts) |t| if (t.panel == id and std.mem.eql(u8, t.layer, name)) return .{ .yes = true, .colour = t.colour };
    return .{ .yes = false };
}

/// As `run`, within `scope`: an operation's checks against its own
/// process, on the layers it makes, and its simulation (FDM's walls; a
/// cutter's kerf path, outside a part's edge and inside its holes; an
/// engraver's passes, a spot apart, until the mark is filled).
pub fn runWith(a: Allocator, m: *const model.Model, panel: usize, placed: *const place.Placed, faces: []const *font.Face, cache: ?*Cache, scope: Scope) !Report {
    var report: Report = .{ .profile = null, .findings = &.{}, .worst = .initFill(.pass) };
    const profile = scope.profile;
    report.profile = profile;
    const lim = profile.limits();
    const pf = m.panels.items[panel].fab;
    var out: std.ArrayList(Finding) = .empty;
    var own_cache: Cache = .init(a);
    const c = cache orelse &own_cache;

    const plan = try fab.plan(a, m, panel, placed, faces);

    // The features: every piece's faces, an inlay's once.
    var feats: std.ArrayList(Feature) = .empty;
    var colours: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < plan.steps.len) : (i += 1) {
        const st = plan.steps[i];
        if (!inScope(m, scope, panel, pf.layers[st.layer].name).yes) {
            // Not this operation's: an inlay's two steps passed together.
            const next = if (i + 1 < plan.steps.len) plan.steps[i + 1] else null;
            if (st.op == .subtract and next != null and next.?.layer == st.layer) i += 1;
            continue;
        }
        var role: Role = .body;
        var colour: ?[]const u8 = null;
        switch (st.op) {
            .subtract => {
                const next = if (i + 1 < plan.steps.len) plan.steps[i + 1] else null;
                if (next != null and next.?.layer == st.layer and next.?.op == .add and next.?.pieces.ptr == st.pieces.ptr) {
                    // An inlay: its add, next, makes the marks.
                    i += 1;
                    role = .inlay;
                    colour = next.?.op.add.name;
                } else role = .void;
            },
            .add => |col| colour = col.name,
        }
        if (colour) |name| {
            for (colours.items) |have| {
                if (std.mem.eql(u8, have, name)) break;
            } else try colours.append(a, name);
        }
        for (st.pieces) |pc| {
            const fc = (try pieceOf(a, c, pc)) orelse continue;
            try feats.append(a, .{ .face = fc, .role = role, .z = .{ st.z0, st.z1 }, .colour = colour, .layer = st.layer });
        }
    }

    // Colours and size.
    var whole = Box.empty;
    var z0: f64 = std.math.inf(f64);
    var z1: f64 = -std.math.inf(f64);
    for (feats.items) |ft| if (ft.role != .void) {
        whole = whole.join(ft.face.box);
        z0 = @min(z0, ft.z[0]);
        z1 = @max(z1, ft.z[1]);
    };
    report.colours = colours.items.len;
    if (!whole.isEmpty()) report.extent = .{ whole.width(), whole.height(), z1 - z0 };
    if (profile.class() == .additive and colours.items.len > lim.colours) try out.append(a, .{ .kind = .colours, .verdict = .fail, .box = whole, .value = @floatFromInt(colours.items.len) });
    if (!whole.isEmpty()) {
        const e = report.extent;
        const b = lim.build;
        const flat = (e[0] <= b[0] and e[1] <= b[1]) or (e[0] <= b[1] and e[1] <= b[0]);
        if (!flat or e[2] > b[2]) try out.append(a, .{ .kind = .size, .verdict = .fail, .box = whole, .extent = e });
    }

    // Depths in whole layers.
    if (lim.layer) |lh| for (pf.layers, 0..) |l, li| {
        if (!inScope(m, scope, panel, l.name).yes) continue;
        const d = l.depth orelse continue;
        const n = d / lh;
        const whole_layers = @round(n);
        const v: Verdict = if (whole_layers < 1) .fail else if (@abs(n - whole_layers) > 1e-6 or whole_layers < @as(f64, @floatFromInt(lim.min_layers))) .marginal else .pass;
        if (v != .pass) try out.append(a, .{ .kind = .depth, .verdict = v, .box = whole, .layer = li, .value = d });
    };

    // Cap heights of the legends the layers take.
    for (placed.labels, 0..) |pl, li| {
        const taken = for (pf.layers) |l| switch (l.source) {
            .text => |track| if (inScope(m, scope, panel, l.name).yes and fab.takes(m, track, pl)) break true,
            else => {},
        } else false;
        if (!taken) continue;
        const cap = m.textStyle(pl.style).cap_height;
        const v = lim.cap.judge(cap);
        if (v != .pass) try out.append(a, .{ .kind = .cap, .verdict = v, .box = pl.box, .label = li, .value = cap });
    }

    // Each face on its own: its strokes (opening), its holes and notches
    // (closing); cached by shape.
    for (feats.items) |ft| {
        const own: process.Band, const space: process.Band, const space_kind: Kind = switch (ft.role) {
            .body => .{ lim.stroke, lim.gap, .gap },
            .inlay => .{ lim.stroke, lim.stroke, .stroke },
            .void => .{ lim.gap, lim.stroke, .stroke },
        };
        const own_kind: Kind = if (ft.role == .void) .gap else .stroke;
        const key = judgedKey(ft.face.shape, ft.role, own, space);
        report.faces += 1;
        const lost = if (c.map.get(key)) |l| blk: {
            report.cached += 1;
            break :blk l;
        } else blk: {
            const ca = c.arena.allocator();
            var list: std.ArrayList(Lost) = .empty;
            faceLost(a, ca, &list, ft.face, own_kind, own, space_kind, space) catch |e| switch (e) {
                error.Unjoined => report.unmeasured += 1,
                else => return e,
            };
            try c.map.put(ca, key, list.items);
            break :blk list.items;
        };
        for (lost) |l| {
            const pts = try a.alloc(Point, l.contour.len);
            for (l.contour, pts) |p, *q| q.* = .{ .x = p.x + ft.face.box.x0, .y = p.y + ft.face.box.y0 };
            try out.append(a, try finding(a, l.kind, l.verdict, pts, ft.z, if (l.kind == .stroke and ft.role != .void) ft.colour else null));
        }
    }

    // Each mark's body: the smallest body face round its middle, at its
    // heights.
    for (feats.items) |*ft| {
        if (ft.role == .body) continue;
        const mid: Point = .{ .x = (ft.face.box.x0 + ft.face.box.x1) / 2, .y = (ft.face.box.y0 + ft.face.box.y1) / 2 };
        var best: ?usize = null;
        var best_area: f64 = std.math.inf(f64);
        for (feats.items, 0..) |bd, bi| {
            if (bd.role != .body or !overlaps(bd.z, ft.z) or !inBox(bd.face.box, mid)) continue;
            if (!insideAll(bd.face.polys, mid)) continue;
            const ar = bd.face.box.width() * bd.face.box.height();
            if (ar < best_area) {
                best_area = ar;
                best = bi;
            }
        }
        ft.body = best;
    }

    // Between faces: in order across, each with those after it whose box
    // comes within a bead.
    const reach = @max(lim.stroke.pass, lim.gap.pass);
    const order = try a.alloc(usize, feats.items.len);
    for (order, 0..) |*o, k| o.* = k;
    std.mem.sort(usize, order, feats.items, struct {
        fn lt(fs: []const Feature, x: usize, y: usize) bool {
            return fs[x].face.box.x0 < fs[y].face.box.x0;
        }
    }.lt);
    for (order, 0..) |ia, k| {
        const fa = feats.items[ia];
        for (order[k + 1 ..]) |ib| {
            const fb = feats.items[ib];
            if (fb.face.box.x0 > fa.face.box.x1 + reach) break;
            if (fb.face.box.y0 > fa.face.box.y1 + reach or fa.face.box.y0 > fb.face.box.y1 + reach) continue;
            if (!overlaps(fa.z, fb.z)) continue;
            // Two marks in one body: its material between. Two bodies:
            // space between. A body and a mark: the edge test below.
            const band: process.Band, const kind: Kind = if (fa.role == .body and fb.role == .body)
                .{ lim.gap, .gap }
            else if (fa.role != .body and fb.role != .body and fa.body != null and fa.body == fb.body)
                .{ lim.stroke, .stroke }
            else
                continue;
            between(a, &out, fa, fb, band, kind) catch |e| switch (e) {
                error.Unjoined => report.unmeasured += 1,
                else => return e,
            };
        }
    }
    // A mark near its body's edge.
    for (feats.items) |ft| {
        const bi = ft.body orelse continue;
        nearEdge(a, &out, ft, feats.items[bi], lim.stroke) catch |e| switch (e) {
            error.Unjoined => report.unmeasured += 1,
            else => return e,
        };
    }

    // The process simulated: what it lays or cuts, path by path.
    const sim: struct { w: f64, kind: process.Kind } = switch (profile.params) {
        .fdm => |f| .{ .w = f.line_width, .kind = .fdm },
        .laser_cut => |l| .{ .w = l.kerf, .kind = .laser_cut },
        .waterjet => |w| .{ .w = w.kerf, .kind = .waterjet },
        .laser_engrave => |l| .{ .w = l.spot, .kind = .laser_engrave },
    };
    {
        var paths: std.ArrayList(Path) = .empty;
        const grey: model.FabColour = .{ .name = "", .color = .{ .r = 128, .g = 128, .b = 128 } };
        const kerf: model.FabColour = .{ .name = "kerf", .color = .{ .r = 0xff, .g = 0x6a, .b = 0x00 } };
        for (feats.items) |ft| {
            const given = inScope(m, scope, panel, pf.layers[ft.layer].name).colour;
            const colour = if (sim.kind.cuts()) kerf else given orelse colourOf(plan, ft) orelse if (ft.body) |bi| colourOf(plan, feats.items[bi]) orelse grey else grey;
            // How the process goes round it: a slicer's walls (two in a
            // part, inlays filled, two round a hole); a cut once, outside
            // a part, inside a hole; an engraving's passes until filled.
            const outward, const most: usize = switch (sim.kind) {
                .fdm => .{ ft.role == .void, if (ft.role == .inlay) 64 else 2 },
                .laser_cut, .waterjet => .{ ft.role == .body, 1 },
                .laser_engrave => .{ false, if (ft.role == .body) 3 else 64 },
            };
            var h: std.hash.Wyhash = .init(3);
            h.update(std.mem.asBytes(&ft.face.shape));
            h.update(std.mem.asBytes(&outward));
            h.update(std.mem.asBytes(&most));
            h.update(std.mem.asBytes(&sim.w));
            const key = h.final();
            const rel = c.walls.get(key) orelse blk: {
                const ca = c.arena.allocator();
                const loops = try walls(a, ca, ft.face, outward, most, sim.w);
                try c.walls.put(ca, key, loops);
                break :blk loops;
            };
            for (rel) |l| {
                const pts = try a.alloc(Point, l.len);
                for (l, pts) |q, *r| r.* = .{ .x = q.x + ft.face.box.x0, .y = q.y + ft.face.box.y0 };
                try paths.append(a, .{ .points = pts, .width = sim.w, .colour = colour, .z = ft.z });
            }
        }
        report.paths = paths.items;
    }

    report.findings = out.items;
    for (out.items) |fd| report.worst.set(fd.kind, worse(report.worst.get(fd.kind), fd.verdict));
    return report;
}

/// The colour a feature's material is, from its step in the plan: null
/// for a cut.
fn colourOf(plan: fab.Plan, ft: Feature) ?model.FabColour {
    const name = ft.colour orelse return null;
    for (plan.steps) |st| switch (st.op) {
        .add => |col| if (std.mem.eql(u8, col.name, name)) return col,
        .subtract => {},
    };
    return null;
}

/// Path centrelines `w` wide round a face, at most `most` of them, a path
/// apart: inward from its edge (walls, passes), or outward (round a hole,
/// or a cut outside a part). Relative to the face's box corner, in `ca`.
fn walls(a: Allocator, ca: Allocator, fc: Face, outward: bool, most: usize, w: f64) ![]const Poly {
    const o = try outlineOf(a, fc.polys);
    var out: std.ArrayList(Poly) = .empty;
    for (0..most) |k| {
        const r = w / 2 + @as(f64, @floatFromInt(k)) * w;
        const ring = if (outward) try geom.grow.grow(a, o, r, tolerance) else try erode(a, o, r);
        if (ring.contours.len == 0) break;
        for (ring.contours) |cn| {
            const pts = try geom.grow.flatten(a, cn, tolerance);
            if (pts.len < 2) continue;
            const rel = try ca.alloc(Point, pts.len);
            for (pts, rel) |q, *d| d.* = .{ .x = q.x - fc.box.x0, .y = q.y - fc.box.y0 };
            try out.append(ca, rel);
        }
    }
    return out.items;
}

/// A finding for a lost or closing area `pts`.
fn finding(a: Allocator, kind: Kind, verdict: Verdict, pts: []const Point, z: [2]f64, colour: ?[]const u8) !Finding {
    const cs = try a.alloc(Contour, 1);
    cs[0] = try contourOf(a, pts);
    var b = Box.empty;
    for (pts) |p| b = b.addPoint(p);
    return .{ .kind = kind, .verdict = verdict, .box = b, .area = .{ .contours = cs }, .z = z, .colour = colour };
}

/// A face's own losses, relative to its box corner, into `list` (in `ca`):
/// strokes (or a cut's width) no bead covers, and holes and notches that
/// close up.
fn faceLost(a: Allocator, ca: Allocator, list: *std.ArrayList(Lost), fc: Face, own_kind: Kind, own: process.Band, space_kind: Kind, space: process.Band) !void {
    const o = try outlineOf(a, fc.polys);
    const area = outlineArea(o);
    // Material: opened at the passing width first; only a face losing
    // more there than its corners account for is cut, and judged at the
    // failing width (which loses less).
    for ([_]struct { w: f64, v: Verdict }{ .{ .w = own.pass, .v = .marginal }, .{ .w = own.fail, .v = .fail } }) |lv| {
        if (!(lv.w > 0)) continue;
        const r = lv.w / 2;
        const eroded = try erode(a, o, r);
        const opened = try geom.grow.grow(a, eroded, r, tolerance);
        if (area - outlineArea(opened) - cornerLoss(fc.polys, r, .convex) < 0.5 * lv.w * lv.w) break;
        const covered = try geom.grow.grow(a, eroded, r + 4 * tolerance, tolerance);
        try keep(a, ca, list, try geom.boolean.cut(a, o, &.{covered}), own_kind, lv.v, lv.w, fc.box);
    }
    // Space: closed likewise, holes and notches filling.
    for ([_]struct { w: f64, v: Verdict }{ .{ .w = space.pass, .v = .marginal }, .{ .w = space.fail, .v = .fail } }) |lv| {
        if (!(lv.w > 0)) continue;
        const r = lv.w / 2;
        const grown = try geom.grow.grow(a, o, r, tolerance);
        const closed = try erode(a, grown, r);
        if (outlineArea(closed) - area - cornerLoss(fc.polys, r, .concave) < 0.5 * lv.w * lv.w) break;
        const inner = try erode(a, grown, r + 4 * tolerance);
        try keep(a, ca, list, try geom.boolean.cut(a, inner, &.{o}), space_kind, lv.v, lv.w, fc.box);
    }
}

fn outlineArea(o: Outline) f64 {
    var s: f64 = 0;
    for (o.contours) |cn| s += cn.signedArea();
    return s;
}

/// What opening (convex corners) or closing (concave ones) by `r` takes or
/// fills at the polygons' corners, however wide the strokes: at a corner
/// turning by the exterior angle φ, r²(tan(φ/2) − φ/2) (a square corner:
/// r²(1 − π/4)). Flattened curves turn a little at each point and add
/// next to nothing.
fn cornerLoss(polys: []const Poly, r: f64, which: enum { convex, concave }) f64 {
    var s: f64 = 0;
    for (polys) |p| for (p, 0..) |q, k| {
        const prev = p[(k + p.len - 1) % p.len];
        const next = p[(k + 1) % p.len];
        const ax = q.x - prev.x;
        const ay = q.y - prev.y;
        const bx = next.x - q.x;
        const by = next.y - q.y;
        // Left turns are convex (the filled side on the left).
        const turn = std.math.atan2(ax * by - ay * bx, ax * bx + ay * by);
        const phi = if (which == .convex) turn else -turn;
        if (phi <= 0 or phi >= std.math.pi - 1e-6) continue;
        s += r * r * (@tan(phi / 2) - phi / 2);
    };
    return s;
}

/// The contours of `lost` big enough to be more than a corner, flattened,
/// relative to `box`'s corner.
fn keep(a: Allocator, ca: Allocator, list: *std.ArrayList(Lost), lost: Outline, kind: Kind, v: Verdict, w: f64, box: Box) !void {
    for (lost.contours) |cn| {
        if (cn.signedArea() < 0.5 * w * w) continue;
        const pts = try geom.grow.flatten(a, cn, tolerance);
        const rel = try ca.alloc(Point, pts.len);
        for (pts, rel) |p, *q| q.* = .{ .x = p.x - box.x0, .y = p.y - box.y0 };
        try list.append(ca, .{ .kind = kind, .verdict = v, .contour = rel });
    }
}

/// Two faces nearer than `band` passes: the room between them, where it
/// is narrower than a bead (within half a bead of both, in neither).
fn between(a: Allocator, out: *std.ArrayList(Finding), fa: Feature, fb: Feature, band: process.Band, kind: Kind) !void {
    const d = distance(fa.face.polys, fb.face.polys, band.pass);
    if (d >= band.pass) return;
    const oa = try outlineOf(a, fa.face.polys);
    const ob = try outlineOf(a, fb.face.polys);
    const z: [2]f64 = .{ @max(fa.z[0], fb.z[0]), @min(fa.z[1], fb.z[1]) };
    for ([_]struct { w: f64, v: Verdict }{ .{ .w = band.pass, .v = .marginal }, .{ .w = band.fail, .v = .fail } }) |lv| {
        if (!(d < lv.w)) continue;
        const r = lv.w / 2;
        const neck = try geom.boolean.combine(a, &.{ try geom.grow.grow(a, oa, r, tolerance), try geom.grow.grow(a, ob, r, tolerance), oa, ob }, .{ .ctx = undefined, .inside = struct {
            fn f(_: *const anyopaque, in: []const bool) bool {
                return in[0] and in[1] and !in[2] and !in[3];
            }
        }.f });
        try reportArea(a, out, neck, kind, lv.v, z, null);
    }
}

/// A mark nearer its body's edge than a bead: the body's material between,
/// where it is narrower.
fn nearEdge(a: Allocator, out: *std.ArrayList(Finding), mark: Feature, body: Feature, band: process.Band) !void {
    const d = distance(mark.face.polys, body.face.polys, band.pass);
    if (d >= band.pass) return;
    const om = try outlineOf(a, mark.face.polys);
    const ob = try outlineOf(a, body.face.polys);
    const z: [2]f64 = .{ @max(mark.z[0], body.z[0]), @min(mark.z[1], body.z[1]) };
    for ([_]struct { w: f64, v: Verdict }{ .{ .w = band.pass, .v = .marginal }, .{ .w = band.fail, .v = .fail } }) |lv| {
        if (!(d < lv.w)) continue;
        const r = lv.w / 2;
        // Within half a bead of the mark and of the body's edge, in the
        // body, outside the mark.
        const neck = try geom.boolean.combine(a, &.{ try geom.grow.grow(a, om, r, tolerance), ob, try erode(a, ob, r), om }, .{ .ctx = undefined, .inside = struct {
            fn f(_: *const anyopaque, in: []const bool) bool {
                return in[0] and in[1] and !in[2] and !in[3];
            }
        }.f });
        try reportArea(a, out, neck, .stroke, lv.v, z, body.colour);
    }
}

fn reportArea(a: Allocator, out: *std.ArrayList(Finding), area: Outline, kind: Kind, v: Verdict, z: [2]f64, colour: ?[]const u8) !void {
    // Necks are reported at any size: they are not corners.
    for (area.contours) |cn| {
        if (cn.signedArea() <= 0) continue;
        try out.append(a, try finding(a, kind, v, try geom.grow.flatten(a, cn, tolerance), z, colour));
    }
}

// Faces and polygons ------------------------------------------------------------

/// Piece `o` resolved (see `Face`), from `c` when a piece of its shape
/// has been; null when it has no area.
fn pieceOf(a: Allocator, c: *Cache, o: Outline) !?Face {
    var raw: std.ArrayList([]Point) = .empty;
    var total: f64 = 0;
    var box = Box.empty;
    for (o.contours) |cn| {
        const p = try geom.grow.flatten(a, cn, tolerance);
        if (p.len < 3) continue;
        total += polyArea(p);
        for (p) |q| box = box.addPoint(q);
        try raw.append(a, p);
    }
    if (raw.items.len == 0 or total == 0) return null;
    if (total < 0) for (raw.items) |p| std.mem.reverse(Point, p);
    var h: std.hash.Wyhash = .init(1);
    for (raw.items) |p| {
        h.update(std.mem.asBytes(&p.len));
        for (p) |q| {
            const qx: i64 = @intFromFloat(@round((q.x - box.x0) * 1e6));
            const qy: i64 = @intFromFloat(@round((q.y - box.y0) * 1e6));
            h.update(std.mem.asBytes(&qx));
            h.update(std.mem.asBytes(&qy));
        }
    }
    const shape = h.final();
    const rel = c.shapes.get(shape) orelse blk: {
        const ca = c.arena.allocator();
        const region = try geom.fill.nonzero(a, @ptrCast(raw.items), tolerance * 1e-3);
        const loops = try ca.alloc(Poly, region.loops.len);
        for (region.loops, loops) |l, *d| {
            const pts = try ca.alloc(Point, l.len);
            for (l, pts) |q, *r| r.* = .{ .x = q.x - box.x0, .y = q.y - box.y0 };
            d.* = pts;
        }
        try c.shapes.put(ca, shape, loops);
        break :blk loops;
    };
    if (rel.len == 0) return null;
    const polys = try a.alloc(Poly, rel.len);
    for (rel, polys) |l, *d| {
        const pts = try a.alloc(Point, l.len);
        for (l, pts) |q, *r| r.* = .{ .x = q.x + box.x0, .y = q.y + box.y0 };
        d.* = pts;
    }
    return .{ .polys = polys, .box = box, .shape = shape };
}

/// Whether `pt` is inside the region of simple loops `polys` (even-odd).
fn insideAll(polys: []const Poly, pt: Point) bool {
    var in = false;
    for (polys) |p| {
        if (inside(p, pt)) in = !in;
    }
    return in;
}

fn polyArea(p: []const Point) f64 {
    var s: f64 = 0;
    for (p, 0..) |q, k| {
        const r = p[(k + 1) % p.len];
        s += q.x * r.y - r.x * q.y;
    }
    return s / 2;
}

/// Whether `pt` is inside polygon `p` (even-odd).
fn inside(p: []const Point, pt: Point) bool {
    var in = false;
    var j = p.len - 1;
    for (p, 0..) |q, k| {
        const r = p[j];
        if ((q.y > pt.y) != (r.y > pt.y) and pt.x < (r.x - q.x) * (pt.y - q.y) / (r.y - q.y) + q.x) in = !in;
        j = k;
    }
    return in;
}

fn inBox(b: Box, p: Point) bool {
    return p.x >= b.x0 and p.x <= b.x1 and p.y >= b.y0 and p.y <= b.y1;
}

fn overlaps(x: [2]f64, y: [2]f64) bool {
    return x[0] < y[1] - 1e-9 and y[0] < x[1] - 1e-9;
}

fn contourOf(a: Allocator, p: []const Point) !Contour {
    const s = try a.alloc(Segment, p.len);
    for (p, 0..) |q, k| s[k] = .{ .line = .{ q, p[(k + 1) % p.len] } };
    return .{ .segments = s };
}

fn outlineOf(a: Allocator, polys: []const Poly) !Outline {
    const cs = try a.alloc(Contour, polys.len);
    for (polys, cs) |p, *cn| cn.* = try contourOf(a, p);
    return .{ .contours = cs };
}

/// The least distance between two sets of polygons' edges, or `limit`
/// when it is no less (edges whose boxes are that far apart are skipped).
fn distance(pa: []const Poly, pb: []const Poly, limit: f64) f64 {
    var best = limit;
    for (pa) |p| for (p, 0..) |a0, i| {
        const a1 = p[(i + 1) % p.len];
        const ax0 = @min(a0.x, a1.x) - best;
        const ax1 = @max(a0.x, a1.x) + best;
        const ay0 = @min(a0.y, a1.y) - best;
        const ay1 = @max(a0.y, a1.y) + best;
        for (pb) |q| for (q, 0..) |b0, j| {
            const b1 = q[(j + 1) % q.len];
            if (@max(b0.x, b1.x) < ax0 or @min(b0.x, b1.x) > ax1 or @max(b0.y, b1.y) < ay0 or @min(b0.y, b1.y) > ay1) continue;
            best = @min(best, segDist(a0, a1, b0, b1));
        };
    };
    return best;
}

fn segDist(a0: Point, a1: Point, b0: Point, b1: Point) f64 {
    const ca = orient(a0, a1, b0) * orient(a0, a1, b1);
    const cb = orient(b0, b1, a0) * orient(b0, b1, a1);
    if (ca < 0 and cb < 0) return 0;
    return @min(@min(ptSeg(a0, b0, b1), ptSeg(a1, b0, b1)), @min(ptSeg(b0, a0, a1), ptSeg(b1, a0, a1)));
}

fn orient(p: Point, q: Point, r: Point) f64 {
    return (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x);
}

fn ptSeg(p: Point, s0: Point, s1: Point) f64 {
    const dx = s1.x - s0.x;
    const dy = s1.y - s0.y;
    const l2 = dx * dx + dy * dy;
    const t = if (l2 > 0) std.math.clamp(((p.x - s0.x) * dx + (p.y - s0.y) * dy) / l2, 0, 1) else 0;
    return std.math.hypot(p.x - (s0.x + t * dx), p.y - (s0.y + t * dy));
}

/// A shape with what it is judged by.
fn judgedKey(shape: u64, role: Role, own: process.Band, space: process.Band) u64 {
    var h: std.hash.Wyhash = .init(2);
    h.update(std.mem.asBytes(&shape));
    h.update(std.mem.asBytes(&role));
    for ([_]f64{ own.pass, own.fail, space.pass, space.fail }) |x| h.update(std.mem.asBytes(&x));
    return h.final();
}

/// `region` eroded by `r` (its polygons' offset inward): the box round it,
/// less the region, grown by `r`; what that growth leaves of the box.
pub fn erode(a: Allocator, region: Outline, r: f64) !Outline {
    if (region.contours.len == 0) return region;
    const b = region.bounds();
    const m = 2 * r + 1;
    const cs = try a.alloc(Contour, region.contours.len + 1);
    cs[0] = try contourOf(a, &.{ .{ .x = b.x0 - m, .y = b.y0 - m }, .{ .x = b.x1 + m, .y = b.y0 - m }, .{ .x = b.x1 + m, .y = b.y1 + m }, .{ .x = b.x0 - m, .y = b.y1 + m } });
    for (region.contours, cs[1..]) |cn, *d| d.* = try reversed(a, cn);
    const grown = try geom.grow.grow(a, .{ .contours = cs }, r, tolerance);
    // Its outermost contour is the grown box; the rest, reversed, are the
    // eroded region.
    var outer: usize = 0;
    var most: f64 = -std.math.inf(f64);
    for (grown.contours, 0..) |cn, k| {
        const ar = cn.signedArea();
        if (ar > most) {
            most = ar;
            outer = k;
        }
    }
    var kept: std.ArrayList(Contour) = .empty;
    for (grown.contours, 0..) |cn, k| if (k != outer) try kept.append(a, try reversed(a, cn));
    return .{ .contours = kept.items };
}

fn reversed(a: Allocator, cn: Contour) !Contour {
    const s = try a.alloc(Segment, cn.segments.len);
    for (cn.segments, 0..) |seg, k| s[cn.segments.len - 1 - k] = seg.reversed();
    return .{ .segments = s };
}

const testing = std.testing;

fn squareFace(a: Allocator, x0: f64, y0: f64, x1: f64, y1: f64) !Face {
    const p = try a.dupe(Point, &.{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y0 }, .{ .x = x1, .y = y1 }, .{ .x = x0, .y = y1 } });
    const polys = try a.alloc(Poly, 1);
    polys[0] = p;
    return .{ .polys = polys, .box = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 }, .shape = 0 };
}

test "erosion: a 2 mm square eroded by 0.5 is a 1 mm square; a 0.4 mm bar vanishes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try erode(a, try outlineOf(a, (try squareFace(a, 0, 0, 2, 2)).polys), 0.5);
    try testing.expectEqual(1, e.contours.len);
    try testing.expectApproxEqAbs(1.0, e.contours[0].signedArea(), 1e-3);
    try testing.expectEqual(0, (try erode(a, try outlineOf(a, (try squareFace(a, 0, 0, 10, 0.4)).polys), 0.25)).contours.len);
}

test "a thin bar loses its stroke, a wide one does not; a narrow slot closes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const band: process.Band = .{ .pass = 0.42, .fail = 0.2 };
    var list: std.ArrayList(Lost) = .empty;
    // 0.3 mm wide: marginal along its length, not failing.
    try faceLost(a, a, &list, try squareFace(a, 0, 0, 10, 0.3), .stroke, band, .gap, band);
    try testing.expectEqual(1, list.items.len);
    try testing.expectEqual(Verdict.marginal, list.items[0].verdict);
    // 1 mm wide: nothing (its corners are not reported).
    list.clearRetainingCapacity();
    try faceLost(a, a, &list, try squareFace(a, 0, 0, 10, 1), .stroke, band, .gap, band);
    try testing.expectEqual(0, list.items.len);
    // A U whose slot is 0.1 mm wide: the slot closes up, failing.
    const u = try a.dupe(Point, &.{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 4 }, .{ .x = 2.05, .y = 4 }, .{ .x = 2.05, .y = 1 }, .{ .x = 1.95, .y = 1 }, .{ .x = 1.95, .y = 4 }, .{ .x = 0, .y = 4 } });
    const polys = try a.alloc(Poly, 1);
    polys[0] = u;
    list.clearRetainingCapacity();
    try faceLost(a, a, &list, .{ .polys = polys, .box = .{ .x0 = 0, .y0 = 0, .x1 = 4, .y1 = 4 }, .shape = 0 }, .stroke, band, .gap, band);
    var fails: usize = 0;
    for (list.items) |l| if (l.kind == .gap and l.verdict == .fail) {
        fails += 1;
    };
    try testing.expectEqual(1, fails);
}

test "polygon distance: two squares 0.1 mm apart; far ones at the limit" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x = try squareFace(a, 0, 0, 1, 1);
    const y = try squareFace(a, 1.1, 0, 2, 1);
    try testing.expectApproxEqAbs(0.1, distance(x.polys, y.polys, 1), 1e-12);
    try testing.expectEqual(0.5, distance(x.polys, (try squareFace(a, 5, 5, 6, 6)).polys, 0.5));
}
