//! Sample models built through the libraries' actions, shared by the CLI
//! and the GUI.

pub const pc_keyboard = @import("pc_keyboard.zig");
pub const hp15c = @import("hp15c.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
