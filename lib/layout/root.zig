//! Graven layout library: worksheets, panels, slots and reflow, union per
//! colour, DRC and output. Labels themselves are rendered by the engine.
//!
//! Modules depend one way only. Each stage's result is a plain data
//! structure that can be dumped, diffed and tested.

pub const layout = @import("layout.zig");
pub const geometry = @import("geometry.zig");
pub const drc = @import("drc.zig");
pub const output = @import("output.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
