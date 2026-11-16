//! Graven layout library: worksheets, panels, slots and reflow, union per
//! colour, DRC and output. Labels themselves are rendered by the engine.
//!
//! Modules depend one way only. Each stage's result is a plain data
//! structure that can be dumped, diffed and tested.

pub const model = @import("model.zig");
pub const place = @import("place.zig");
pub const art = @import("art.zig");
pub const layout = @import("layout.zig");
pub const geometry = @import("geometry.zig");
pub const drc = @import("drc.zig");
pub const output = @import("output.zig");
pub const native = @import("native.zig");
pub const history = @import("history.zig");
pub const fonts = @import("fonts.zig");
pub const import = @import("import.zig");
pub const constrain = @import("constrain.zig");
pub const edit = @import("edit.zig");
pub const fab = @import("fab.zig");
pub const threemf = @import("threemf.zig");
pub const ground = @import("ground.zig");
pub const legend = @import("legend.zig");

pub const Model = model.Model;
pub const TileId = model.TileId;
pub const Labels = place.Labels;
pub const solve = place.solve;

test {
    @import("std").testing.refAllDecls(@This());
}
