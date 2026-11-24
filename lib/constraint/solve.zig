//! Solving a system of constraints, and analysing what holds it.
//!
//! The caller owns the unknowns (`Problem.vars`, each fixed or free) and
//! says what its constraints are by making their residual rows at the
//! current values (`ctx.rows(*Rows)`): each row a dual number whose
//! derivatives give its exact Jacobian row. A sketch's points and circles,
//! a layout's boxes and lines: the solver knows none of them.
//!
//! `solve` takes damped least-squares steps of least (weighted) size,
//! dx = -G J^T (J G J^T + λD)^-1 r, G the unknowns' give, so where the
//! constraints leave freedom nothing moves that need not, and an unknown
//! that gives less (a size, against a position) moves less.
//!
//! `analyse` orthogonalises J's rows in order. A row that adds nothing new
//! is dependent on earlier rows: its constraint is redundant when the system
//! solves, and conflicting (with the constraints it depends on) when it
//! does not. The rank gives the degrees of freedom left; an unknown whose
//! direction is not wholly in the row space is free.

const std = @import("std");
const dual = @import("dual.zig");

const Allocator = std.mem.Allocator;

/// Whose a residual row is: the caller's own tag. Kind 0 is a geometry's
/// own equation (an arc keeping its radius), never reported as redundant
/// or conflicting; other kinds are constraints, reported by `index`.
pub const Owner = struct {
    kind: u8 = 1,
    index: u32,

    pub const internal: u8 = 0;

    pub fn eql(a: Owner, b: Owner) bool {
        return a.kind == b.kind and a.index == b.index;
    }
};

/// The unknowns: plain numbers, each fixed (a constant) or free.
pub const Problem = struct {
    vars: []f64,
    fixed: []const bool,
    /// How readily each unknown gives, relative to the others (null: all
    /// alike). A step moves each in proportion to its give, so of two ways
    /// to meet a constraint the one through readier unknowns is taken.
    give: ?[]const f64 = null,
};

pub const Result = struct {
    solved: bool,
    /// The largest residual left (mm, or radians for angles).
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
    redundant: []const Owner,
    /// Constraints that cannot all hold together.
    conflicting: []const Owner,
    /// Per unknown: free (not held by the constraints). Fixed ones: false.
    free: []const bool,
};

/// The rows of a system at its current values, as the caller makes them.
pub const Rows = struct {
    a: Allocator,
    /// Column of each var, or null for a fixed one.
    col: []const ?u32,
    n: usize,
    owners: std.ArrayList(Owner) = .empty,
    r: std.ArrayList(f64) = .empty,
    /// Row-major, `n` per row.
    j: std.ArrayList(f64) = .empty,

    /// A residual row: `d`'s value, and its derivatives with respect to
    /// the vars `ids` (`d.d[k]` for `ids[k]`; a fixed var's is ignored).
    pub fn add(rows: *Rows, owner: Owner, d: dual.D, ids: []const u32) Allocator.Error!void {
        try rows.owners.append(rows.a, owner);
        try rows.r.append(rows.a, d.v);
        const start = rows.j.items.len;
        try rows.j.appendNTimes(rows.a, 0, rows.n);
        for (ids, 0..) |id, k| if (rows.col[id]) |c| {
            rows.j.items[start + c] += d.d[k];
        };
    }

    fn m(rows: Rows) usize {
        return rows.r.items.len;
    }

    fn row(rows: Rows, i: usize) []f64 {
        return rows.j.items[i * rows.n .. (i + 1) * rows.n];
    }
};

/// Picks out the free unknowns of a dual's local set: a var as a dual,
/// seeded when free, constant when fixed. At most `dual.n` per row.
pub const Local = struct {
    vars: []const f64,
    fixed: []const bool,
    ids: [dual.n]u32 = undefined,
    count: usize = 0,

    pub fn get(l: *Local, id: u32) dual.D {
        const v = l.vars[id];
        if (l.fixed[id]) return dual.D.c(v);
        for (l.ids[0..l.count], 0..) |x, i| if (x == id) return dual.D.seed(v, i);
        std.debug.assert(l.count < dual.n);
        l.ids[l.count] = id;
        l.count += 1;
        return dual.D.seed(v, l.count - 1);
    }

    pub fn used(l: *const Local) []const u32 {
        return l.ids[0..l.count];
    }
};

const tol = 1e-9;

const System = struct {
    rows: Rows,
    /// The var of each column.
    vars: []u32,
};

fn build(p: Problem, ctx: anytype, a: Allocator) !System {
    const col = try a.alloc(?u32, p.vars.len);
    var vars: std.ArrayList(u32) = .empty;
    for (p.fixed, col, 0..) |f, *c, i| {
        c.* = if (f) null else @intCast(vars.items.len);
        if (!f) try vars.append(a, @intCast(i));
    }
    var rows: Rows = .{ .a = a, .col = col, .n = vars.items.len };
    try ctx.rows(&rows);
    return .{ .rows = rows, .vars = vars.items };
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

fn dot(a: []const f64, b: []const f64) f64 {
    var sum: f64 = 0;
    for (a, b) |x, y| sum += x * y;
    return sum;
}

/// Solves A y = b in place for symmetric positive definite A (k × k);
/// false when it is not positive definite.
fn cholesky(a: []f64, b: []f64, k: usize) bool {
    for (0..k) |i| {
        for (0..i + 1) |jj| {
            var sum = a[i * k + jj];
            for (0..jj) |q| sum -= a[i * k + q] * a[jj * k + q];
            if (i == jj) {
                if (!(sum > 0)) return false;
                a[i * k + i] = @sqrt(sum);
            } else a[i * k + jj] = sum / a[jj * k + jj];
        }
    }
    for (0..k) |i| {
        var sum = b[i];
        for (0..i) |q| sum -= a[i * k + q] * b[q];
        b[i] = sum / a[i * k + i];
    }
    var i = k;
    while (i > 0) {
        i -= 1;
        var sum = b[i];
        for (i + 1..k) |q| sum -= a[q * k + i] * b[q];
        b[i] = sum / a[i * k + i];
    }
    return true;
}

/// Changes the free unknowns the least it can (weighted by their give) to
/// make every residual zero. Not solved (with the least residual it found)
/// when the constraints cannot all hold. `ctx.rows(*Rows)` makes the rows
/// at `p.vars` as they stand.
pub fn solve(gpa: Allocator, p: Problem, ctx: anytype) !Result {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var lambda: f64 = 1e-10;
    var iterations: usize = 0;
    var last = std.math.inf(f64);
    while (iterations < 200) : (iterations += 1) {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const sys = try build(p, ctx, a);
        const r = sys.rows.r.items;
        const m = r.len;
        const n = sys.vars.len;
        const worst = maxAbs(r);
        // Refined to the limit of precision; solved within `tol`.
        if (worst < 1e-14 or m == 0 or n == 0) return .{ .solved = worst < tol, .residual = worst, .iterations = iterations };
        const norm = sumSq(r);
        // Stalled: no further progress to make.
        if (norm >= last * (1 - 1e-12) and lambda > 1e6) return .{ .solved = worst < tol, .residual = worst, .iterations = iterations };
        last = norm;
        const g = try a.alloc(f64, n);
        for (sys.vars, g) |v, *x| x.* = if (p.give) |gv| gv[v] else 1;
        // J G J^T.
        const jgj = try a.alloc(f64, m * m);
        for (0..m) |i| for (0..i + 1) |k| {
            var sum: f64 = 0;
            for (sys.rows.row(i), sys.rows.row(k), g) |x, y, w| sum += x * w * y;
            jgj[i * m + k] = sum;
            jgj[k * m + i] = sum;
        };
        const saved = try a.dupe(f64, p.vars);
        const work = try a.alloc(f64, m * m);
        const y = try a.alloc(f64, m);
        var improved = false;
        while (lambda < 1e12) {
            @memcpy(work, jgj);
            for (0..m) |i| work[i * m + i] += lambda * (1 + jgj[i * m + i]);
            @memcpy(y, r);
            if (cholesky(work, y, m)) {
                // dx = -G J^T y.
                for (sys.vars, 0..) |v, c| {
                    var d: f64 = 0;
                    for (0..m) |i| d += sys.rows.j.items[i * n + c] * y[i];
                    p.vars[v] = saved[v] - g[c] * d;
                }
                var trial_arena: std.heap.ArenaAllocator = .init(gpa);
                defer trial_arena.deinit();
                const trial = try build(p, ctx, trial_arena.allocator());
                if (sumSq(trial.rows.r.items) < norm) {
                    improved = true;
                    lambda = @max(lambda / 10, 1e-14);
                    break;
                }
            }
            @memcpy(p.vars, saved);
            lambda *= 10;
        }
        if (!improved) return .{ .solved = worst < tol, .residual = worst, .iterations = iterations };
    }
    _ = arena.reset(.retain_capacity);
    const final = try build(p, ctx, arena.allocator());
    const worst = maxAbs(final.rows.r.items);
    return .{ .solved = worst < tol, .residual = worst, .iterations = iterations };
}

/// What holds the system as it stands (solve it first): degrees of
/// freedom, redundant and conflicting constraints, free unknowns.
/// Allocated from `out`.
pub fn analyse(gpa: Allocator, out: Allocator, p: Problem, ctx: anytype) !Analysis {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const sys = try build(p, ctx, a);
    const rows = sys.rows;
    const m = rows.m();
    const n = sys.vars.len;
    const owners = rows.owners.items;
    const solved = maxAbs(rows.r.items) < 1e-8;

    // Gram-Schmidt over the normalised rows, in order, keeping each basis
    // vector's make-up in terms of the rows.
    var basis: std.ArrayList([]f64) = .empty;
    var makeup: std.ArrayList([]f64) = .empty;
    const dependent = try a.alloc(bool, m);
    @memset(dependent, false);
    const support = try a.alloc([]f64, m);
    for (0..m) |i| {
        const v = try a.dupe(f64, rows.row(i));
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

    const Set = std.ArrayList(Owner);
    const put = struct {
        fn f(al: Allocator, set: *Set, o: Owner) !void {
            if (o.kind == Owner.internal) return;
            for (set.items) |x| if (x.eql(o)) return;
            try set.append(al, o);
        }
    }.f;
    var redundant: Set = .empty;
    var conflicting: Set = .empty;
    for (0..m) |i| {
        if (!dependent[i]) continue;
        if (solved) {
            try put(a, &redundant, owners[i]);
            continue;
        }
        // Not solved: this row and those it depends on conflict.
        try put(a, &conflicting, owners[i]);
        for (support[i], 0..) |k, r| if (@abs(k) > 1e-9) try put(a, &conflicting, owners[r]);
    }
    if (!solved and conflicting.items.len == 0) {
        // Independent but out of reach (a distance longer than can be
        // spanned): those left unmet.
        for (rows.r.items, owners) |res, own| if (@abs(res) >= 1e-8) try put(a, &conflicting, own);
    }
    var kept: Set = .empty;
    for (redundant.items) |o| {
        for (conflicting.items) |x| {
            if (x.eql(o)) break;
        } else try kept.append(a, o);
    }

    // Free unknowns: not wholly within the row space.
    const free = try out.alloc(bool, p.vars.len);
    @memset(free, false);
    for (sys.vars, 0..) |v, c| {
        var sum: f64 = 0;
        for (basis.items) |q| sum += q[c] * q[c];
        if (sum < 1 - 1e-6) free[v] = true;
    }
    const dof = n - rank;
    return .{
        .dof = dof,
        .solved = solved,
        .fully_constrained = solved and dof == 0 and conflicting.items.len == 0,
        .redundant = try out.dupe(Owner, kept.items),
        .conflicting = try out.dupe(Owner, conflicting.items),
        .free = free,
    };
}

const testing = std.testing;

test "a weighted least-change solve: the readier unknown gives" {
    // x + y = 10 from (0, 0): alike, each goes 5; x giving 4 times as
    // readily, it goes 8 and y 2.
    const Sum = struct {
        vars: []f64,
        fixed: []const bool,
        fn rows(s: @This(), r: *Rows) !void {
            var l: Local = .{ .vars = s.vars, .fixed = s.fixed };
            const d = l.get(0).add(l.get(1)).sub(dual.D.c(10));
            try r.add(.{ .index = 0 }, d, l.used());
        }
    };
    var vars = [_]f64{ 0, 0 };
    const fixed = [_]bool{ false, false };
    const ctx: Sum = .{ .vars = &vars, .fixed = &fixed };
    const res = try solve(testing.allocator, .{ .vars = &vars, .fixed = &fixed }, ctx);
    try testing.expect(res.solved);
    try testing.expectApproxEqAbs(@as(f64, 5), vars[0], 1e-9);
    vars = .{ 0, 0 };
    const give = [_]f64{ 4, 1 };
    _ = try solve(testing.allocator, .{ .vars = &vars, .fixed = &fixed, .give = &give }, ctx);
    try testing.expectApproxEqAbs(@as(f64, 8), vars[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2), vars[1], 1e-9);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const an = try analyse(testing.allocator, arena.allocator(), .{ .vars = &vars, .fixed = &fixed }, ctx);
    try testing.expectEqual(1, an.dof);
    try testing.expect(an.free[0] and an.free[1]);
}
