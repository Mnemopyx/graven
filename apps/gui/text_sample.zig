//! A sample of text with math between dollars and an equation in it: one track of three rows on a
//! space's canvas, for trying editing in a flow and on the canvas.

const std = @import("std");
const layout = @import("graven_layout");

const Model = layout.Model;
const StyleId = layout.model.StyleId;

/// Adds the track to `parent` (a workspace, or a panel) at `origin`, its
/// rows 60 mm long, in style `style`; returns the track's index.
pub fn build(m: *Model, parent: layout.model.Parent, style: StyleId, origin: layout.geom.Point) !usize {
    const panel = parent;
    const pitch = 6;
    const r = try m.addTracks(panel, .{ .name = "Text", .origin = origin, .style = style, .count = 3, .length = 60.0 / pitch, .pitch = pitch });
    try m.insertRun(panel, r, 0, .{ .style = style, .content = "A circle of diameter $d$ has area " });
    try m.insertRun(panel, r, 1, .{ .style = style, .content = "A = \\frac{\\pi d^2}{4}", .equation = true });
    try m.insertRun(panel, r, 2, .{ .style = style, .content = " in $\\mathrm{mm}^2$." });
    return r;
}

/// The typography sample (GRAVEN_SAMPLE=typography): the same words in two
/// text styles in STIX Two Text, ligatures off (the default) and on, with
/// letters carrying combining accents (one character each to the caret).
/// Returns the two tracks' indices.
pub fn buildTypography(m: *Model, parent: layout.model.Parent, origin: layout.geom.Point) ![2]usize {
    const words = "office affluent fjord: cafe\u{301}, nai\u{308}ve, re\u{301}sume\u{301}";
    var out: [2]usize = undefined;
    for ([_]bool{ false, true }, 0..) |on, k| {
        const st = try m.addStyle(if (on) "Ligatures on" else "Ligatures off", .{ .cap_height = 4 });
        try m.setStyleFace(st, "text", .{ .family = "STIX Two Text", .style = "SemiBold" });
        if (on) try m.setStyleRule(st, null, .ligatures, .{ .flag = true });
        const at: layout.geom.Point = .{ .x = origin.x, .y = origin.y + @as(f64, @floatFromInt(k)) * 16 };
        const r = try m.addTracks(parent, .{ .name = if (on) "Ligatures on" else "Ligatures off", .origin = at, .style = st, .count = 1, .length = 140.0 / 8.0, .pitch = 8 });
        try m.insertRun(parent, r, 0, .{ .style = st, .content = words });
        out[k] = r;
    }
    return out;
}

test "the text sample: a track with text, an equation, and text" {
    var m: Model = .init(std.testing.allocator);
    defer m.deinit();
    const c: layout.model.Parent = .{ .space = try m.startCanvas(.mm) };
    const st = try m.addStyle("Label", .{ .cap_height = 3 });
    const r = try build(&m, c, st, .{ .x = 0, .y = 0 });
    const items = m.flowItems(c, r);
    try std.testing.expectEqual(3, items.len);
    try std.testing.expect(items[1].what.run.equation);
}
