//! Dual numbers with a short gradient: a value and its derivatives with
//! respect to up to `n` local variables. A constraint's residual computed
//! with them gives its exact Jacobian row (forward mode).

const std = @import("std");

pub const n = 8;

pub const D = struct {
    v: f64,
    d: [n]f64 = @splat(0),

    pub fn c(v: f64) D {
        return .{ .v = v };
    }

    /// Variable `i` of the local set, at value `v`.
    pub fn seed(v: f64, i: usize) D {
        var x: D = .{ .v = v };
        x.d[i] = 1;
        return x;
    }

    pub fn add(a: D, b: D) D {
        var r: D = .{ .v = a.v + b.v };
        for (&r.d, a.d, b.d) |*o, x, y| o.* = x + y;
        return r;
    }

    pub fn sub(a: D, b: D) D {
        var r: D = .{ .v = a.v - b.v };
        for (&r.d, a.d, b.d) |*o, x, y| o.* = x - y;
        return r;
    }

    pub fn mul(a: D, b: D) D {
        var r: D = .{ .v = a.v * b.v };
        for (&r.d, a.d, b.d) |*o, x, y| o.* = x * b.v + a.v * y;
        return r;
    }

    pub fn div(a: D, b: D) D {
        var r: D = .{ .v = a.v / b.v };
        for (&r.d, a.d, b.d) |*o, x, y| o.* = (x * b.v - a.v * y) / (b.v * b.v);
        return r;
    }

    pub fn scale(a: D, k: f64) D {
        var r: D = .{ .v = a.v * k };
        for (&r.d, a.d) |*o, x| o.* = x * k;
        return r;
    }

    pub fn sqrt(a: D) D {
        const v = @sqrt(@max(a.v, 0));
        var r: D = .{ .v = v };
        if (v > 0) for (&r.d, a.d) |*o, x| {
            o.* = x / (2 * v);
        };
        return r;
    }

    pub fn sin(a: D) D {
        var r: D = .{ .v = @sin(a.v) };
        const k = @cos(a.v);
        for (&r.d, a.d) |*o, x| o.* = x * k;
        return r;
    }

    pub fn cos(a: D) D {
        var r: D = .{ .v = @cos(a.v) };
        const k = -@sin(a.v);
        for (&r.d, a.d) |*o, x| o.* = x * k;
        return r;
    }
};

/// A 2D vector of duals.
pub const V = struct {
    x: D,
    y: D,

    pub fn sub(a: V, b: V) V {
        return .{ .x = a.x.sub(b.x), .y = a.y.sub(b.y) };
    }

    pub fn dot(a: V, b: V) D {
        return a.x.mul(b.x).add(a.y.mul(b.y));
    }

    pub fn cross(a: V, b: V) D {
        return a.x.mul(b.y).sub(a.y.mul(b.x));
    }

    pub fn len(a: V) D {
        return a.dot(a).sqrt();
    }

    pub fn unit(a: V) V {
        const l = a.len();
        return .{ .x = a.x.div(l), .y = a.y.div(l) };
    }
};

test "derivatives are exact" {
    // f(x, y) = sqrt(x^2 + y^2) at (3, 4): 5, with gradient (0.6, 0.8).
    const x = D.seed(3, 0);
    const y = D.seed(4, 1);
    const f = (V{ .x = x, .y = y }).len();
    try std.testing.expectEqual(@as(f64, 5), f.v);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), f.d[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), f.d[1], 1e-15);
    const g = x.sin().mul(y);
    try std.testing.expectApproxEqAbs(4 * @cos(@as(f64, 3)), g.d[0], 1e-15);
}
