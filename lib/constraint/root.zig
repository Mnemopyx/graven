//! Constraints, generic: unknowns, residual rows, a least-change solver
//! and its analysis, dimensions and their drafting geometry, typed units
//! and expressions. It knows nothing of what is constrained: sketches
//! (`graven_sketch`) and the document's containers (`graven_layout`) both
//! build on it (decided 2026-11-24, the owner: "generic geometry library
//! code").

pub const dual = @import("dual.zig");
pub const solve = @import("solve.zig");
pub const expr = @import("expr.zig");
pub const units = @import("units.zig");
pub const dimension = @import("dimension.zig");

test {
    _ = dual;
    _ = solve;
    _ = expr;
    _ = units;
    _ = dimension;
}
