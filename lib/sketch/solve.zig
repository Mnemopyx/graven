//! Solving a sketch and analysing what holds it.
//!
//! The unknowns x are every var that is not fixed; the residuals r(x) are
//! each arc's own equation, then each constraint's, in order. `solve` takes
//! damped least-squares steps of least size, dx = -J^T (J J^T + λI)^-1 r,
//! so where the constraints leave freedom nothing moves that need not:
//! geometry left free stays where it was drawn.
//!
//! `analyse` orthogonalises J's rows in order. A row that adds nothing new
//! is dependent on earlier rows: its constraint is redundant when the sketch
//! solves, and conflicting (with the constraints it depends on) when it
//! does not. The rank gives the degrees of freedom left; an unknown whose
//! direction is not wholly in the row space is free, and so is any
//! geometry it belongs to.

const std = @import("std");
const root = @import("root.zig");
const dual = @import("dual.zig");

const Allocator = std.mem.Allocator;
const Sketch = root.Sketch;
const GeomId = root.GeomId;
const ConstraintId = root.ConstraintId;

pub const Result = struct {
    solved: bool,
    /// The largest residual left, mm (or radians, for angles).
    residual: f64,
    iterations: usize,
};

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

/// Whose a residual row is: an arc's own equation, or a constraint's.
const Owner = union(enum) { arc: GeomId, constraint: ConstraintId };

const tol = 1e-9;

/// Residuals and Jacobian at the sketch's current values.
const System = struct {
    /// Column of each var, or null for a fixed one.
    col: []?u32,
    /// The var of each column.
    vars: []u32,
    owners: []Owner,
    r: []f64,
    /// m rows of n.
    j: []f64,

    fn n(sys: System) usize {
        return sys.vars.len;
    }

    fn m(sys: System) usize {
        return sys.r.len;
    }

    fn row(sys: System, i: usize) []f64 {
        return sys.j[i * sys.n() .. (i + 1) * sys.n()];
    }
};

fn build(s: *Sketch, a: Allocator) root.Error!System {
    const col = try a.alloc(?u32, s.vars.items.len);
    var vars: std.ArrayList(u32) = .empty;
    for (s.fixed.items, col, 0..) |f, *c, i| {
        c.* = if (f) null else @intCast(vars.items.len);
        if (!f) try vars.append(a, @intCast(i));
    }
    var owners: std.ArrayList(Owner) = .empty;
    var res: std.ArrayList(f64) = .empty;
    var jac: std.ArrayList(f64) = .empty;
    const n = vars.items.len;
    const addRow = struct {
        fn f(al: Allocator, o: *std.ArrayList(Owner), rs: *std.ArrayList(f64), jj: *std.ArrayList(f64), cl: []const ?u32, nn: usize, l: *const root.Local, d: dual.D, owner: Owner) !void {
            try o.append(al, owner);
            try rs.append(al, d.v);
            const start = jj.items.len;
            try jj.appendNTimes(al, 0, nn);
            for (l.ids[0..l.count], 0..) |id, k| if (cl[id]) |c| {
                jj.items[start + c] += d.d[k];
            };
        }
    }.f;
    for (s.geometry.items, 0..) |g, gi| switch (g.kind) {
        .arc => |ar| {
            var l: root.Local = .{ .s = s };
            const d = l.arcResidual(ar);
            try addRow(a, &owners, &res, &jac, col, n, &l, d, .{ .arc = @intCast(gi) });
        },
        else => {},
    };
    for (s.constraints.items, 0..) |c, ci| {
        var l: root.Local = .{ .s = s };
        var out: [2]dual.D = undefined;
        const k = try l.residuals(c, &out);
        for (out[0..k]) |d| try addRow(a, &owners, &res, &jac, col, n, &l, d, .{ .constraint = @intCast(ci) });
    }
    return .{ .col = col, .vars = vars.items, .owners = owners.items, .r = res.items, .j = jac.items };
}

fn maxAbs(xs: []const f64) f64 {
    var x: f64 = 0;
    for (xs) |v| x = @max(x, @abs(v));
    return x;
}

fn sumSq(xs: []const f64) f64 {
    var x: f64 = 0;
    for (xs) |v| x += v * v;
    return x;
}

/// Solves A y = b in place for symmetric positive definite A (k × k);
/// false when it is not positive definite.
fn cholesky(a: []f64, b: []f64, k: usize) bool {
    for (0..k) |i| {
        for (0..i + 1) |jj| {
            var sum = a[i * k + jj];
            for (0..jj) |p| sum -= a[i * k + p] * a[jj * k + p];
            if (i == jj) {
                if (!(sum > 0)) return false;
                a[i * k + i] = @sqrt(sum);
            } else a[i * k + jj] = sum / a[jj * k + jj];
        }
    }
    for (0..k) |i| {
        var sum = b[i];
        for (0..i) |p| sum -= a[i * k + p] * b[p];
        b[i] = sum / a[i * k + i];
    }
    var i = k;
    while (i > 0) {
        i -= 1;
        var sum = b[i];
        for (i + 1..k) |p| sum -= a[p * k + i] * b[p];
        b[i] = sum / a[i * k + i];
    }
    return true;
}

/// Solves the sketch: changes its unknowns the least it can to make every
/// residual zero. Not solved (with the least residual it found) when the
/// constraints cannot all hold. Solved, points held together by coincident
/// constraints are given exactly the same coordinates (a fixed one's, if
/// any), so what they join closes exactly.
pub fn solve(s: *Sketch) root.Error!Result {
    const res = try iterate(s);
    if (res.solved) try joinCoincident(s);
    return res;
}

fn joinCoincident(s: *Sketch) root.Error!void {
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
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
            const p = try s.pointOf(ps[0]);
            const q = try s.pointOf(ps[1]);
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
            const p = try s.pointOf(r);
            const lead = find(parent, p.x);
            if (lead == p.x or s.fixed.items[p.x]) continue;
            s.vars.items[p.x] = s.vars.items[lead];
            s.vars.items[p.y] = s.vars.items[ys[lead]];
        },
        else => {},
    };
}

fn iterate(s: *Sketch) root.Error!Result {
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    var lambda: f64 = 1e-10;
    var iterations: usize = 0;
    var last = std.math.inf(f64);
    while (iterations < 200) : (iterations += 1) {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const sys = try build(s, a);
        const m = sys.m();
        const n = sys.n();
        const worst = maxAbs(sys.r);
        // Refined to the limit of precision; solved within `tol`.
        if (worst < 1e-14 or m == 0 or n == 0) return .{ .solved = worst < tol, .residual = worst, .iterations = iterations };
        const norm = sumSq(sys.r);
        // Stalled: no further progress to make.
        if (norm >= last * (1 - 1e-12) and lambda > 1e6) return .{ .solved = worst < tol, .residual = worst, .iterations = iterations };
        last = norm;
        // J J^T.
        const jjt = try a.alloc(f64, m * m);
        for (0..m) |i| for (0..i + 1) |k| {
            var sum: f64 = 0;
            for (sys.row(i), sys.row(k)) |x, y| sum += x * y;
            jjt[i * m + k] = sum;
            jjt[k * m + i] = sum;
        };
        const saved = try a.dupe(f64, s.vars.items);
        const work = try a.alloc(f64, m * m);
        const y = try a.alloc(f64, m);
        var improved = false;
        while (lambda < 1e12) {
            @memcpy(work, jjt);
            for (0..m) |i| work[i * m + i] += lambda * (1 + jjt[i * m + i]);
            @memcpy(y, sys.r);
            if (cholesky(work, y, m)) {
                // dx = -J^T y.
                for (sys.vars, 0..) |v, c| {
                    var d: f64 = 0;
                    for (0..m) |i| d += sys.j[i * n + c] * y[i];
                    s.vars.items[v] = saved[v] - d;
                }
                var trial_arena: std.heap.ArenaAllocator = .init(s.gpa);
                defer trial_arena.deinit();
                const trial = try build(s, trial_arena.allocator());
                if (sumSq(trial.r) < norm) {
                    improved = true;
                    lambda = @max(lambda / 10, 1e-14);
                    break;
                }
            }
            @memcpy(s.vars.items, saved);
            lambda *= 10;
        }
        if (!improved) return .{ .solved = worst < tol, .residual = worst, .iterations = iterations };
    }
    var arena2: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena2.deinit();
    const final = try build(s, arena2.allocator());
    const worst = maxAbs(final.r);
    return .{ .solved = worst < tol, .residual = worst, .iterations = iterations };
}

fn dot(a: []const f64, b: []const f64) f64 {
    var sum: f64 = 0;
    for (a, b) |x, y| sum += x * y;
    return sum;
}

/// What holds the sketch as it stands (solve it first): degrees of
/// freedom, redundant and conflicting constraints, free geometry.
/// Allocated from `out`.
pub fn analyse(s: *Sketch, out: Allocator) root.Error!Analysis {
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const sys = try build(s, a);
    const m = sys.m();
    const n = sys.n();
    const solved = maxAbs(sys.r) < 1e-8;

    // Gram-Schmidt over the normalised rows, in order, keeping each basis
    // vector's make-up in terms of the rows.
    var basis: std.ArrayList([]f64) = .empty;
    var makeup: std.ArrayList([]f64) = .empty;
    const dependent = try a.alloc(bool, m);
    @memset(dependent, false);
    const support = try a.alloc([]f64, m);
    for (0..m) |i| {
        const v = try a.dupe(f64, sys.row(i));
        const nv = @sqrt(dot(v, v));
        const c = try a.alloc(f64, m);
        @memset(c, 0);
        if (nv < 1e-12) {
            // Touches no unknown: adds nothing.
            dependent[i] = true;
            support[i] = c;
            continue;
        }
        for (v) |*x| x.* /= nv;
        c[i] = 1;
        const w = try a.dupe(f64, v);
        const combo = try a.alloc(f64, m);
        @memset(combo, 0);
        // Twice, for accuracy.
        for (0..2) |_| for (basis.items, makeup.items) |q, mk| {
            const k = dot(q, w);
            for (w, q) |*x, qq| x.* -= k * qq;
            for (combo, mk) |*x, mm| x.* += k * mm;
        };
        const nw = @sqrt(dot(w, w));
        if (nw < 1e-8) {
            dependent[i] = true;
            support[i] = combo;
            continue;
        }
        for (w) |*x| x.* /= nw;
        for (c, combo) |*x, y_| x.* = (x.* - y_) / nw;
        try basis.append(a, w);
        try makeup.append(a, c);
    }
    const rank = basis.items.len;

    var redundant: std.AutoArrayHashMapUnmanaged(ConstraintId, void) = .empty;
    var conflicting: std.AutoArrayHashMapUnmanaged(ConstraintId, void) = .empty;
    for (0..m) |i| {
        if (!dependent[i]) continue;
        const own = sys.owners[i];
        if (solved) {
            if (own == .constraint) try redundant.put(a, own.constraint, {});
            continue;
        }
        // Not solved: this row and those it depends on conflict.
        if (own == .constraint) try conflicting.put(a, own.constraint, {});
        for (support[i], 0..) |k, r| if (@abs(k) > 1e-9) {
            if (sys.owners[r] == .constraint) try conflicting.put(a, sys.owners[r].constraint, {});
        };
    }
    if (!solved and conflicting.count() == 0) {
        // Independent but out of reach (a distance longer than can be
        // spanned): those left unmet.
        for (sys.r, sys.owners) |res, own| if (@abs(res) >= 1e-8 and own == .constraint) {
            try conflicting.put(a, own.constraint, {});
        };
    }
    for (conflicting.keys()) |k| _ = redundant.swapRemove(k);

    // Free unknowns: not wholly within the row space.
    const free_var = try a.alloc(bool, s.vars.items.len);
    @memset(free_var, false);
    for (sys.vars, 0..) |v, c| {
        var sum: f64 = 0;
        for (basis.items) |q| sum += q[c] * q[c];
        if (sum < 1 - 1e-6) free_var[v] = true;
    }
    var free: std.ArrayList(GeomId) = .empty;
    for (s.geometry.items, 0..) |g, gi| {
        if (g.reference) continue;
        const any = switch (g.kind) {
            .point => |p| free_var[p.x] or free_var[p.y],
            .segment => |sg| free_var[sg.a.x] or free_var[sg.a.y] or free_var[sg.b.x] or free_var[sg.b.y],
            .circle => |ci| free_var[ci.c.x] or free_var[ci.c.y] or free_var[ci.r],
            .arc => |ar| free_var[ar.c.x] or free_var[ar.c.y] or free_var[ar.a.x] or free_var[ar.a.y] or free_var[ar.b.x] or free_var[ar.b.y],
            .line => |ln| free_var[ln.theta] or free_var[ln.rho],
            .ray => |ry| free_var[ry.o.x] or free_var[ry.o.y] or free_var[ry.angle],
        };
        if (any) try free.append(out, @intCast(gi));
    }
    const dof = n - rank;
    return .{
        .dof = dof,
        .solved = solved,
        .fully_constrained = solved and dof == 0 and conflicting.count() == 0,
        .redundant = try out.dupe(ConstraintId, redundant.keys()),
        .conflicting = try out.dupe(ConstraintId, conflicting.keys()),
        .free = free.items,
    };
}
