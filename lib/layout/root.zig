//! Graven layout library: worksheets, panels, slots and reflow, union per
//! colour, DRC and output. Legends are set by glyphic (legend.zig) into
//! render.zig's geometry.
//!
//! Modules depend one way only. Each stage's result is a plain data
//! structure that can be dumped, diffed and tested.

pub const model = @import("model.zig");
pub const units = @import("units.zig");
pub const names = @import("names.zig");
pub const place = @import("place.zig");
pub const art = @import("art.zig");
pub const figure = @import("figure.zig");
pub const svg = @import("svg.zig");
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
pub const check = @import("check.zig");
pub const threemf = @import("threemf.zig");
pub const ground = @import("ground.zig");
pub const legend = @import("legend.zig");
pub const render = @import("render.zig");
pub const Render = render.Render;
pub const font = @import("graven_font");
pub const geom = @import("graven_geom");
pub const Face = font.Face;

/// Graven's version, recorded with the files it writes.
pub const version = "0.0.0";

pub const Model = model.Model;
pub const TileId = model.TileId;
pub const Labels = place.Labels;
pub const solve = place.solve;

test {
    _ = @import("glyph_fill_test.zig");
    @import("std").testing.refAllDecls(@This());
}
