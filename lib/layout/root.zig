//! Graven layout library: from parsed legends to output geometry.
//!
//! Modules depend one way only, in this order. Each stage's result is a plain
//! data structure that can be dumped, diffed and tested.

pub const core = @import("core.zig");
pub const text = @import("text.zig");
pub const layout = @import("layout.zig");
pub const geometry = @import("geometry.zig");
pub const drc = @import("drc.zig");
pub const output = @import("output.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
