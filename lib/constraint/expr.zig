//! Expressions for dimensions and parameters: numbers, parameter names,
//! + - * / and ^, parentheses, unary minus, and the functions sqrt, abs,
//! min, max, sin, cos, tan (degrees). Lengths are mm and angles degrees,
//! as the sketch keeps them.

const std = @import("std");

pub const Error = error{ Syntax, UnknownName, Cycle, Domain };

/// Looks a name up: its value, or null when there is none.
pub const Lookup = struct {
    ctx: *const anyopaque,
    get: *const fn (ctx: *const anyopaque, name: []const u8, depth: u8) Error!?f64,
    depth: u8 = 0,
};

pub fn eval(text: []const u8, lookup: Lookup) Error!f64 {
    var p: Parser = .{ .s = text, .lookup = lookup };
    const v = try p.sum();
    p.space();
    if (p.i != p.s.len) return error.Syntax;
    if (!std.math.isFinite(v)) return error.Domain;
    return v;
}

/// Whether `text` is a plain number (no names or operators but a sign).
pub fn isNumber(text: []const u8) bool {
    _ = std.fmt.parseFloat(f64, std.mem.trim(u8, text, " ")) catch return false;
    return true;
}

/// Whether `name` is a valid parameter name: a letter or underscore, then
/// letters, digits or underscores; not a function's name.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    for (functions) |f| if (std.mem.eql(u8, f, name)) return false;
    return true;
}

const functions = [_][]const u8{ "sqrt", "abs", "min", "max", "sin", "cos", "tan" };

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    lookup: Lookup,

    fn space(p: *Parser) void {
        while (p.i < p.s.len and p.s[p.i] == ' ') p.i += 1;
    }

    fn eat(p: *Parser, c: u8) bool {
        p.space();
        if (p.i < p.s.len and p.s[p.i] == c) {
            p.i += 1;
            return true;
        }
        return false;
    }

    fn sum(p: *Parser) Error!f64 {
        var v = try p.product();
        while (true) {
            if (p.eat('+')) {
                v += try p.product();
            } else if (p.eat('-')) {
                v -= try p.product();
            } else return v;
        }
    }

    fn product(p: *Parser) Error!f64 {
        var v = try p.power();
        while (true) {
            if (p.eat('*')) {
                v *= try p.power();
            } else if (p.eat('/')) {
                const d = try p.power();
                if (d == 0) return error.Domain;
                v /= d;
            } else return v;
        }
    }

    fn power(p: *Parser) Error!f64 {
        const b = try p.unary();
        if (p.eat('^')) return std.math.pow(f64, b, try p.power());
        return b;
    }

    fn unary(p: *Parser) Error!f64 {
        if (p.eat('-')) return -(try p.unary());
        if (p.eat('+')) return p.unary();
        return p.atom();
    }

    fn atom(p: *Parser) Error!f64 {
        p.space();
        if (p.eat('(')) {
            const v = try p.sum();
            if (!p.eat(')')) return error.Syntax;
            return v;
        }
        if (p.i >= p.s.len) return error.Syntax;
        const c = p.s[p.i];
        if (std.ascii.isDigit(c) or c == '.') {
            const start = p.i;
            while (p.i < p.s.len and (std.ascii.isDigit(p.s[p.i]) or p.s[p.i] == '.')) p.i += 1;
            if (p.i < p.s.len and (p.s[p.i] == 'e' or p.s[p.i] == 'E')) {
                p.i += 1;
                if (p.i < p.s.len and (p.s[p.i] == '-' or p.s[p.i] == '+')) p.i += 1;
                while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
            }
            return std.fmt.parseFloat(f64, p.s[start..p.i]) catch error.Syntax;
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = p.i;
            while (p.i < p.s.len and (std.ascii.isAlphanumeric(p.s[p.i]) or p.s[p.i] == '_')) p.i += 1;
            const name = p.s[start..p.i];
            if (p.eat('(')) return p.call(name);
            return (try p.lookup.get(p.lookup.ctx, name, p.lookup.depth)) orelse error.UnknownName;
        }
        return error.Syntax;
    }

    fn call(p: *Parser, name: []const u8) Error!f64 {
        var args: [2]f64 = undefined;
        var n: usize = 0;
        if (!p.eat(')')) {
            while (true) {
                if (n >= 2) return error.Syntax;
                args[n] = try p.sum();
                n += 1;
                if (p.eat(')')) break;
                if (!p.eat(',')) return error.Syntax;
            }
        }
        const deg = std.math.pi / 180.0;
        const one = n == 1;
        if (std.mem.eql(u8, name, "sqrt") and one) return if (args[0] < 0) error.Domain else @sqrt(args[0]);
        if (std.mem.eql(u8, name, "abs") and one) return @abs(args[0]);
        if (std.mem.eql(u8, name, "sin") and one) return @sin(args[0] * deg);
        if (std.mem.eql(u8, name, "cos") and one) return @cos(args[0] * deg);
        if (std.mem.eql(u8, name, "tan") and one) return @tan(args[0] * deg);
        if (std.mem.eql(u8, name, "min") and n == 2) return @min(args[0], args[1]);
        if (std.mem.eql(u8, name, "max") and n == 2) return @max(args[0], args[1]);
        return error.UnknownName;
    }
};

test "expressions evaluate with names, precedence and functions" {
    const Ctx = struct {
        fn get(_: *const anyopaque, name: []const u8, _: u8) Error!?f64 {
            if (std.mem.eql(u8, name, "w")) return 19.05;
            if (std.mem.eql(u8, name, "r")) return 1;
            return null;
        }
    };
    const l: Lookup = .{ .ctx = undefined, .get = Ctx.get };
    try std.testing.expectApproxEqAbs(@as(f64, 19.05 / 2.0 - 2.0), try eval("w / 2 - 2*r", l), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -7), try eval("-(3 + 4)", l), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), try eval("sin(30)", l), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 512), try eval("2^3^2", l), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3), try eval("max(r, 3)", l), 1e-12);
    try std.testing.expectError(error.UnknownName, eval("h + 1", l));
    try std.testing.expectError(error.Syntax, eval("w +", l));
    try std.testing.expectError(error.Domain, eval("w / 0", l));
    try std.testing.expect(validName("key_width2"));
    try std.testing.expect(!validName("2w"));
    try std.testing.expect(!validName("sqrt"));
}
