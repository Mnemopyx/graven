//! graven command-line tool: batch runs, stage dumps and production jobs.
//! Applications own files and console output; the libraries never do.

const std = @import("std");
const graven = @import("graven_layout");

pub fn main() void {
    _ = graven;
    std.debug.print("graven 0.0.0: nothing to do yet\n", .{});
}
