//! A sample of text with math between dollars and an equation in it: one track of three rows on a
//! space's canvas, for trying editing in a flow and on the canvas.

const std = @import("std");
const layout = @import("graven_layout");

const Model = layout.Model;
const StyleId = layout.model.StyleId;

/// Adds the track to panel `panel` (a canvas) at `origin`, its rows 60 mm
/// long, in style `style`; returns the track's index.
pub fn build(m: *Model, panel: usize, style: StyleId, origin: layout.geom.Point) !usize {
    const pitch = 6;
    const r = try m.addTracks(panel, .{ .name = "Text", .origin = origin, .style = style, .count = 3, .length = 60.0 / pitch, .pitch = pitch });
    try m.insertRun(panel, r, 0, .{ .style = style, .content = "A circle of diameter $d$ has area " });
    try m.insertRun(panel, r, 1, .{ .style = style, .content = "A = \\frac{\\pi d^2}{4}", .equation = true });
    try m.insertRun(panel, r, 2, .{ .style = style, .content = " in $\\mathrm{mm}^2$." });
    return r;
}

test "the text sample: a track with text, an equation, and text" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const c = try m.startCanvas(.mm);
    const st = try m.addStyle("Label", .{ .cap_height = 3 });
    const r = try build(&m, c, st, .{ .x = 0, .y = 0 });
    const items = m.flowItems(c, r);
    try std.testing.expectEqual(3, items.len);
    try std.testing.expect(items[1].what.run.equation);
}
