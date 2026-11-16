//! Expressions built through the object API, for tests and, later, for
//! layout: the examples the object model was worked out from.

const std = @import("std");
const ex = @import("expr.zig");

const Expr = ex.Expr;
const Id = ex.Id;

/// The Leibniz series, π/4 = Σ_{n=0}^{∞} (−1)ⁿ/(2n+1) = 1 − 1/3 + 1/5 − 1/7 + ⋯,
/// as LaTeX `\frac{\pi}{4} = \sum_{n=0}^{\infty} \frac{(-1)^n}{2n+1} = 1 - \frac{1}{3} + \frac{1}{5} - \frac{1}{7} + \cdots`
/// would make it. The objects tests look at:
pub const Leibniz = struct {
    pi_over_4: Id,
    pi: Id,
    four: Id,
    first_eq: Id,
    sigma: Id,
    /// n in the lower limit, in the exponent, in the denominator.
    n_limit: Id,
    n_exponent: Id,
    n_den: Id,
    summand: Id,
    exponent: Id,
    fence: Id,
    unary_minus: Id,
    second_eq: Id,
    /// The tail's operators, −, +, −, +.
    tail_ops: [4]Id,
    /// The tail's fractions, 1/3, 1/5, 1/7.
    tail_fracs: [3]Id,
    ellipsis: Id,
};

fn fraction(e: *Expr, num: []const Id, den: []const Id) !Id {
    const f = try e.structure(.fraction, "", "");
    e.node(f).tags = .{ .source = "\\frac", .syntax = .latex };
    for (num) |x| try e.append(e.slot(f, .num), x);
    for (den) |x| try e.append(e.slot(f, .den), x);
    return f;
}

pub fn leibniz(e: *Expr) !Leibniz {
    var l: Leibniz = undefined;
    const top = e.root;

    l.pi = try e.leaf(.constant, "π");
    e.node(l.pi).tags = .{ .source = "\\pi", .atom = .ord, .syntax = .latex };
    l.four = try e.leaf(.number, "4");
    l.pi_over_4 = try fraction(e, &.{l.pi}, &.{l.four});
    try e.append(top, l.pi_over_4);

    l.first_eq = try e.leaf(.relation, "=");
    try e.append(top, l.first_eq);

    // Σ with limits n=0 and ∞.
    l.sigma = try e.structure(.large_op, "∑", "");
    e.node(l.sigma).tags = .{ .source = "\\sum", .atom = .op, .syntax = .latex };
    const lower = try e.openSlot(l.sigma, .sub);
    l.n_limit = try e.leaf(.variable, "n");
    try e.append(lower, l.n_limit);
    try e.append(lower, try e.leaf(.relation, "="));
    try e.append(lower, try e.leaf(.number, "0"));
    try e.append(try e.openSlot(l.sigma, .sup), try e.leaf(.symbol, "∞"));
    try e.append(top, l.sigma);

    // (−1)ⁿ / (2n+1)
    l.fence = try e.structure(.fence, "(", ")");
    l.unary_minus = try e.operator("−", .unary);
    try e.append(e.slot(l.fence, .body), l.unary_minus);
    try e.append(e.slot(l.fence, .body), try e.leaf(.number, "1"));
    l.exponent = try e.structure(.scripts, "", "");
    try e.append(e.slot(l.exponent, .base), l.fence);
    l.n_exponent = try e.leaf(.variable, "n");
    try e.append(try e.openSlot(l.exponent, .sup), l.n_exponent);
    l.n_den = try e.leaf(.variable, "n");
    l.summand = try fraction(e, &.{l.exponent}, &.{ try e.leaf(.number, "2"), l.n_den, try e.operator("+", .binary), try e.leaf(.number, "1") });
    try e.append(top, l.summand);

    l.second_eq = try e.leaf(.relation, "=");
    try e.append(top, l.second_eq);

    // 1 − 1/3 + 1/5 − 1/7 + ⋯
    try e.append(top, try e.leaf(.number, "1"));
    const ops = [_][]const u8{ "−", "+", "−", "+" };
    const dens = [_][]const u8{ "3", "5", "7" };
    for (ops, 0..) |op, k| {
        l.tail_ops[k] = try e.operator(op, .binary);
        try e.append(top, l.tail_ops[k]);
        if (k < dens.len) {
            l.tail_fracs[k] = try fraction(e, &.{try e.leaf(.number, "1")}, &.{try e.leaf(.number, dens[k])});
            try e.append(top, l.tail_fracs[k]);
        }
    }
    l.ellipsis = try e.leaf(.ellipsis, "⋯");
    try e.append(top, l.ellipsis);
    return l;
}
