//! The symbols both entry syntaxes know, one table both ways: each with its
//! character, its LaTeX command, its Typst name (and shorthand), and the
//! kind of object it makes.

const std = @import("std");
const ex = @import("expr.zig");

const Kind = ex.Kind;

pub const Symbol = struct {
    char: []const u8,
    latex: []const u8 = "",
    /// Other LaTeX commands for it, read but not written.
    latex_also: []const u8 = "",
    typst: []const u8 = "",
    /// A Typst shorthand, read and written in place of the name.
    shorthand: []const u8 = "",
    kind: Kind,
};

pub const table = [_]Symbol{
    // Greek: variables by convention, π a constant.
    .{ .char = "α", .latex = "\\alpha", .typst = "alpha", .kind = .variable },
    .{ .char = "β", .latex = "\\beta", .typst = "beta", .kind = .variable },
    .{ .char = "γ", .latex = "\\gamma", .typst = "gamma", .kind = .variable },
    .{ .char = "δ", .latex = "\\delta", .typst = "delta", .kind = .variable },
    .{ .char = "ε", .latex = "\\varepsilon", .typst = "epsilon", .kind = .variable },
    .{ .char = "ζ", .latex = "\\zeta", .typst = "zeta", .kind = .variable },
    .{ .char = "η", .latex = "\\eta", .typst = "eta", .kind = .variable },
    .{ .char = "θ", .latex = "\\theta", .typst = "theta", .kind = .variable },
    .{ .char = "κ", .latex = "\\kappa", .typst = "kappa", .kind = .variable },
    .{ .char = "λ", .latex = "\\lambda", .typst = "lambda", .kind = .variable },
    .{ .char = "μ", .latex = "\\mu", .typst = "mu", .kind = .variable },
    .{ .char = "ν", .latex = "\\nu", .typst = "nu", .kind = .variable },
    .{ .char = "ξ", .latex = "\\xi", .typst = "xi", .kind = .variable },
    .{ .char = "π", .latex = "\\pi", .typst = "pi", .kind = .constant },
    .{ .char = "ρ", .latex = "\\rho", .typst = "rho", .kind = .variable },
    .{ .char = "σ", .latex = "\\sigma", .typst = "sigma", .kind = .variable },
    .{ .char = "τ", .latex = "\\tau", .typst = "tau", .kind = .variable },
    .{ .char = "φ", .latex = "\\varphi", .typst = "phi", .kind = .variable },
    .{ .char = "χ", .latex = "\\chi", .typst = "chi", .kind = .variable },
    .{ .char = "ψ", .latex = "\\psi", .typst = "psi", .kind = .variable },
    .{ .char = "ω", .latex = "\\omega", .typst = "omega", .kind = .variable },
    .{ .char = "Γ", .latex = "\\Gamma", .typst = "Gamma", .kind = .variable },
    .{ .char = "Δ", .latex = "\\Delta", .typst = "Delta", .kind = .variable },
    .{ .char = "Θ", .latex = "\\Theta", .typst = "Theta", .kind = .variable },
    .{ .char = "Λ", .latex = "\\Lambda", .typst = "Lambda", .kind = .variable },
    .{ .char = "Π", .latex = "\\Pi", .typst = "Pi", .kind = .variable },
    .{ .char = "Σ", .latex = "\\Sigma", .typst = "Sigma", .kind = .variable },
    .{ .char = "Φ", .latex = "\\Phi", .typst = "Phi", .kind = .variable },
    .{ .char = "Ψ", .latex = "\\Psi", .typst = "Psi", .kind = .variable },
    .{ .char = "Ω", .latex = "\\Omega", .typst = "Omega", .kind = .variable },
    // Large operators.
    .{ .char = "∑", .latex = "\\sum", .typst = "sum", .kind = .large_op },
    .{ .char = "∏", .latex = "\\prod", .typst = "product", .kind = .large_op },
    .{ .char = "∐", .latex = "\\coprod", .typst = "product.co", .kind = .large_op },
    .{ .char = "∫", .latex = "\\int", .typst = "integral", .kind = .large_op },
    .{ .char = "∬", .latex = "\\iint", .typst = "integral.double", .kind = .large_op },
    .{ .char = "∮", .latex = "\\oint", .typst = "integral.cont", .kind = .large_op },
    .{ .char = "⋃", .latex = "\\bigcup", .typst = "union.big", .kind = .large_op },
    .{ .char = "⋂", .latex = "\\bigcap", .typst = "sect.big", .kind = .large_op },
    // Binary operators.
    .{ .char = "+", .typst = "plus", .kind = .operator },
    .{ .char = "−", .typst = "minus", .kind = .operator },
    .{ .char = "±", .latex = "\\pm", .typst = "plus.minus", .kind = .operator },
    .{ .char = "∓", .latex = "\\mp", .typst = "minus.plus", .kind = .operator },
    .{ .char = "×", .latex = "\\times", .typst = "times", .kind = .operator },
    .{ .char = "÷", .latex = "\\div", .typst = "div", .kind = .operator },
    .{ .char = "⋅", .latex = "\\cdot", .typst = "dot.op", .kind = .operator },
    .{ .char = "∗", .latex = "\\ast", .typst = "ast", .shorthand = "*", .kind = .operator },
    .{ .char = "∘", .latex = "\\circ", .typst = "compose", .kind = .operator },
    .{ .char = "∪", .latex = "\\cup", .typst = "union", .kind = .operator },
    .{ .char = "∩", .latex = "\\cap", .typst = "sect", .kind = .operator },
    // Relations.
    .{ .char = "=", .typst = "eq", .kind = .relation },
    .{ .char = "<", .latex = "<", .typst = "lt", .kind = .relation },
    .{ .char = ">", .latex = ">", .typst = "gt", .kind = .relation },
    .{ .char = "≤", .latex = "\\le", .latex_also = "\\leq", .typst = "lt.eq", .shorthand = "<=", .kind = .relation },
    .{ .char = "≥", .latex = "\\ge", .latex_also = "\\geq", .typst = "gt.eq", .shorthand = ">=", .kind = .relation },
    .{ .char = "≠", .latex = "\\ne", .latex_also = "\\neq", .typst = "eq.not", .shorthand = "!=", .kind = .relation },
    .{ .char = "≈", .latex = "\\approx", .typst = "approx", .kind = .relation },
    .{ .char = "≡", .latex = "\\equiv", .typst = "equiv", .kind = .relation },
    .{ .char = "∼", .latex = "\\sim", .typst = "tilde.op", .kind = .relation },
    .{ .char = "∝", .latex = "\\propto", .typst = "prop", .kind = .relation },
    .{ .char = "∈", .latex = "\\in", .typst = "in", .kind = .relation },
    .{ .char = "∉", .latex = "\\notin", .typst = "in.not", .kind = .relation },
    .{ .char = "⊂", .latex = "\\subset", .typst = "subset", .kind = .relation },
    .{ .char = "⊆", .latex = "\\subseteq", .typst = "subset.eq", .kind = .relation },
    .{ .char = "→", .latex = "\\to", .latex_also = "\\rightarrow", .typst = "arrow.r", .shorthand = "->", .kind = .relation },
    .{ .char = "←", .latex = "\\leftarrow", .latex_also = "\\gets", .typst = "arrow.l", .shorthand = "<-", .kind = .relation },
    .{ .char = "↔", .latex = "\\leftrightarrow", .typst = "arrow.l.r", .shorthand = "<->", .kind = .relation },
    .{ .char = "⇒", .latex = "\\Rightarrow", .typst = "arrow.r.double", .shorthand = "=>", .kind = .relation },
    .{ .char = "⇐", .latex = "\\Leftarrow", .typst = "arrow.l.double", .kind = .relation },
    .{ .char = "⇔", .latex = "\\Leftrightarrow", .typst = "arrow.l.r.double", .shorthand = "<=>", .kind = .relation },
    .{ .char = "⇄", .latex = "\\rightleftarrows", .typst = "arrows.rl", .kind = .relation },
    .{ .char = "↑", .latex = "\\uparrow", .typst = "arrow.t", .kind = .relation },
    .{ .char = "↓", .latex = "\\downarrow", .typst = "arrow.b", .kind = .relation },
    .{ .char = "↦", .latex = "\\mapsto", .typst = "arrow.r.bar", .shorthand = "|->", .kind = .relation },
    // Ordinary symbols.
    .{ .char = "∞", .latex = "\\infty", .typst = "oo", .kind = .symbol },
    .{ .char = "∂", .latex = "\\partial", .typst = "diff", .kind = .symbol },
    .{ .char = "∇", .latex = "\\nabla", .typst = "nabla", .kind = .symbol },
    .{ .char = "∅", .latex = "\\emptyset", .typst = "nothing", .kind = .symbol },
    .{ .char = "′", .latex = "\\prime", .typst = "prime", .shorthand = "'", .kind = .symbol },
    .{ .char = "%", .latex = "\\%", .typst = "percent", .kind = .symbol },
    .{ .char = "ℓ", .latex = "\\ell", .typst = "ell", .kind = .symbol },
    .{ .char = "∀", .latex = "\\forall", .typst = "forall", .kind = .symbol },
    .{ .char = "∃", .latex = "\\exists", .typst = "exists", .kind = .symbol },
    .{ .char = "¬", .latex = "\\neg", .typst = "not", .kind = .symbol },
    .{ .char = "!", .typst = "excl", .kind = .symbol },
    .{ .char = "/", .typst = "slash", .kind = .symbol },
    // Ellipses.
    .{ .char = "⋯", .latex = "\\cdots", .typst = "dots.c", .kind = .ellipsis },
    .{ .char = "…", .latex = "\\ldots", .latex_also = "\\dots", .typst = "dots.h", .shorthand = "...", .kind = .ellipsis },
    .{ .char = "⋮", .latex = "\\vdots", .typst = "dots.v", .kind = .ellipsis },
    // Punctuation.
    .{ .char = ",", .typst = "comma", .kind = .punct },
    .{ .char = ";", .typst = "semi", .kind = .punct },
    .{ .char = ":", .typst = "colon", .kind = .punct },
};

/// Accents: the mark (a spacing character) and their names.
pub const Accent = struct { mark: []const u8, latex: []const u8, typst: []const u8 };

pub const accents = [_]Accent{
    .{ .mark = "ˆ", .latex = "\\hat", .typst = "hat" },
    .{ .mark = "¯", .latex = "\\bar", .typst = "macron" },
    .{ .mark = "˜", .latex = "\\tilde", .typst = "tilde" },
    .{ .mark = "→", .latex = "\\vec", .typst = "arrow" },
    .{ .mark = "˙", .latex = "\\dot", .typst = "dot" },
    .{ .mark = "¨", .latex = "\\ddot", .typst = "dot.double" },
};

pub fn byChar(c: []const u8) ?*const Symbol {
    for (&table) |*s| if (std.mem.eql(u8, s.char, c)) return s;
    return null;
}

pub fn byLatex(cmd: []const u8) ?*const Symbol {
    for (&table) |*s| if ((s.latex.len > 0 and std.mem.eql(u8, s.latex, cmd)) or (s.latex_also.len > 0 and std.mem.eql(u8, s.latex_also, cmd))) return s;
    return null;
}

pub fn byTypst(name: []const u8) ?*const Symbol {
    for (&table) |*s| if (s.typst.len > 0 and std.mem.eql(u8, s.typst, name)) return s;
    return null;
}

pub fn accentByLatex(cmd: []const u8) ?*const Accent {
    for (&accents) |*a| if (std.mem.eql(u8, a.latex, cmd)) return a;
    return null;
}

pub fn accentByTypst(name: []const u8) ?*const Accent {
    for (&accents) |*a| if (std.mem.eql(u8, a.typst, name)) return a;
    return null;
}

pub fn accentByMark(mark: []const u8) ?*const Accent {
    for (&accents) |*a| if (std.mem.eql(u8, a.mark, mark)) return a;
    return null;
}

/// The kind a lone character makes when the table does not name it.
pub fn kindOfChar(c: []const u8) Kind {
    if (byChar(c)) |s| return s.kind;
    if (c.len == 1 and std.ascii.isDigit(c[0])) return .number;
    if (c.len == 1 and std.ascii.isAlphabetic(c[0])) return .variable;
    return .symbol;
}
