//! Solving a sketch and analysing what holds it, on the generic constraint
//! library (`graven_constraint`): the sketch's vars are its unknowns, each
//! arc's own equation and each driving constraint's residuals its rows.
//! Solved, points held together by coincident constraints are given exactly
//! the same coordinates (a fixed one's, if any), so what they join closes
//! exactly.

const std = @import("std");
const root = @import("root.zig");
const cs = @import("graven_constraint");

const Allocator = std.mem.Allocator;
const Sketch = root.Sketch;
const GeomId = root.GeomId;
const ConstraintId = root.ConstraintId;

pub const Result = cs.solve.Result;

pub const Analysis = struct {
    /// Degrees of freedom left.
    dof: usize,
    solved: bool,
    /// Solved, with nothing free and nothing conflicting.
    fully_constrained: bool,
    /// Constraints that add nothing (all or part of them) to those before.
    redundant: []const ConstraintId,
    /// Constraints that cannot all hold together.
    conflicting: []const ConstraintId,
    /// Geometry with any freedom left.
    free: []const GeomId,
};

/// The sketch's rows: each arc's own equation, then each driving
/// constraint's residuals, in order.
const Rows = struct {
    s: *Sketch,

    pub fn rows(ctx: Rows, out: *cs.solve.Rows) !void {
        try ctx.s.store().rows(ctx.s.constraints.items, out);
    }
};

fn problem(s: *Sketch) cs.solve.Problem {
    return .{ .vars = s.vars.items, .fixed = s.fixed.items };
}

/// Solves the sketch: changes its unknowns the least it can to make every
/// residual zero. Not solved (with the least residual it found) when the
/// constraints cannot all hold.
pub fn solve(s: *Sketch, gpa: Allocator) root.Error!Result {
    const res = cs.solve.solve(gpa, problem(s), Rows{ .s = s }) catch |e| return @as(root.Error, @errorCast(e));
    if (res.solved) try joinCoincident(s, gpa);
    return res;
}

fn joinCoincident(s: *Sketch, gpa: Allocator) root.Error!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // Union-find over points, by their x var.
    const parent = try a.alloc(u32, s.vars.items.len);
    for (parent, 0..) |*p, i| p.* = @intCast(i);
    const ys = try a.alloc(u32, s.vars.items.len);
    const find = struct {
        fn f(par: []u32, i: u32) u32 {
            var r = i;
            while (par[r] != r) r = par[r];
            return r;
        }
    }.f;
    var any = false;
    for (s.constraints.items) |c| switch (c.kind) {
        .coincident => |ps| {
            // A bind point (no unknowns of its own) is not joined.
            const p = s.pointOf(ps[0]) catch continue;
            const q = s.pointOf(ps[1]) catch continue;
            ys[p.x] = p.y;
            ys[q.x] = q.y;
            var rp = find(parent, p.x);
            var rq = find(parent, q.x);
            if (rp == rq) continue;
            // A fixed point leads its group.
            if (s.fixed.items[rq]) std.mem.swap(u32, &rp, &rq);
            parent[rq] = rp;
            any = true;
        },
        else => {},
    };
    if (!any) return;
    for (s.constraints.items) |c| switch (c.kind) {
        .coincident => |ps| for (ps) |r| {
            const p = s.pointOf(r) catch continue;
            const lead = find(parent, p.x);
            if (lead == p.x or s.fixed.items[p.x]) continue;
            s.vars.items[p.x] = s.vars.items[lead];
            s.vars.items[p.y] = s.vars.items[ys[lead]];
        },
        else => {},
    };
}

/// What holds the sketch as it stands (solve it first): degrees of
/// freedom, redundant and conflicting constraints, free geometry.
/// Allocated from `out`.
pub fn analyse(s: *Sketch, gpa: Allocator, out: Allocator) root.Error!Analysis {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const an = cs.solve.analyse(gpa, arena.allocator(), problem(s), Rows{ .s = s }) catch |e| return @as(root.Error, @errorCast(e));
    const ids = struct {
        fn f(al: Allocator, os: []const cs.solve.Owner) ![]ConstraintId {
            const r = try al.alloc(ConstraintId, os.len);
            for (os, r) |o, *x| x.* = o.index;
            return r;
        }
    }.f;
    const free_var = an.free;
    var free: std.ArrayList(GeomId) = .empty;
    for (s.geometry.items, 0..) |g, gi| {
        if (g.reference or g.removed) continue;
        const any = switch (g.kind) {
            .point => |p| free_var[p.x] or free_var[p.y],
            .affine => false,
            .segment => |sg| free_var[sg.a.x] or free_var[sg.a.y] or free_var[sg.b.x] or free_var[sg.b.y],
            .circle => |ci| free_var[ci.c.x] or free_var[ci.c.y] or free_var[ci.r],
            .arc => |ar| free_var[ar.c.x] or free_var[ar.c.y] or free_var[ar.a.x] or free_var[ar.a.y] or free_var[ar.b.x] or free_var[ar.b.y],
            .line => |ln| free_var[ln.theta] or free_var[ln.rho],
            .ray => |ry| free_var[ry.o.x] or free_var[ry.o.y] or free_var[ry.angle],
            .polar_grid => |pg| for (pg.unknowns()) |v| {
                if (free_var[v]) break true;
            } else false,
        };
        if (any) try free.append(out, @intCast(gi));
    }
    return .{
        .dof = an.dof,
        .solved = an.solved,
        .fully_constrained = an.fully_constrained,
        .redundant = try ids(out, an.redundant),
        .conflicting = try ids(out, an.conflicting),
        .free = free.items,
    };
}
