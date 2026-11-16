//! Where an expression may break between segments. Only the expression's
//! top row breaks: structures (fractions, scripts with their base, fences,
//! radicals, limits) and groups are never broken inside, so each piece is
//! whole and lays out on its own segment's ground. The flow's line breaker
//! chooses among these candidates as it does among a paragraph's.
//!
//! A break before an object follows its break mark: forbidden, allowed or
//! preferred at a cost, forced, or (auto) as its neighbours' kinds decide:
//! after a relation (cheapest) or a binary operator, never before
//! punctuation or an ellipsis, nowhere else.

const std = @import("std");
const param = @import("param.zig");
const ex = @import("expr.zig");
const cascade = @import("cascade.zig");

const Allocator = std.mem.Allocator;
const Id = ex.Id;
const Resolver = cascade.Resolver;

pub const Candidate = struct {
    /// The break falls before the top row's object at this index.
    index: usize,
    before: Id,
    /// What breaking here costs (lower is better).
    cost: f32,
    /// A break that must be taken.
    forced: bool = false,
    /// Objects dropped at the break (a space between words): the next
    /// line starts after them.
    skip: u8 = 0,
    /// The line ends with a hyphen (a break at a soft hyphen, which is the
    /// object before `index`).
    hyphen: bool = false,
};

/// What a break after `left` costs as the kinds decide, or null where they
/// allow none.
fn byKinds(r: *const Resolver, left: Id, right: Id) ?f32 {
    const l = r.e.node(left);
    const rk = r.e.node(right).kind;
    if (rk == .punct or rk == .ellipsis) return null;
    if (l.kind == .relation) return r.get(left, .relation_break_cost).number;
    if (l.kind == .operator and l.role == .binary) return r.get(left, .binary_break_cost).number;
    return null;
}

/// Every place the expression may break, in order.
pub fn candidates(gpa: Allocator, r: *const Resolver) Allocator.Error![]Candidate {
    var out: std.ArrayList(Candidate) = .empty;
    errdefer out.deinit(gpa);
    const items = r.e.node(r.e.root).items.items;
    for (1..items.len) |k| {
        const left = items[k - 1];
        const right = items[k];
        // Text: at a space (dropped there), after a soft hyphen (drawn).
        if (r.e.node(right).kind == .space) {
            try out.append(gpa, .{ .index = k, .before = right, .cost = r.get(right, .space_break_cost).number, .skip = 1 });
            continue;
        }
        if (r.e.node(left).kind == .soft_hyphen) {
            try out.append(gpa, .{ .index = k, .before = right, .cost = r.get(left, .hyphen_break_cost).number, .hyphen = true });
            continue;
        }
        const auto = byKinds(r, left, right);
        const c: ?Candidate = switch (param.as(param.BreakMark, r.get(right, .break_before))) {
            .auto => if (auto) |cost| .{ .index = k, .before = right, .cost = cost } else null,
            .forbid => null,
            // Allowed where the kinds would not: at a binary operator's cost.
            .allow => .{ .index = k, .before = right, .cost = auto orelse r.get(left, .binary_break_cost).number },
            .prefer => .{ .index = k, .before = right, .cost = 0 },
            .force => .{ .index = k, .before = right, .cost = 0, .forced = true },
        };
        if (c) |cc| try out.append(gpa, cc);
    }
    return out.toOwnedSlice(gpa);
}
