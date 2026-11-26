//! Graven font library: a thin Zig layer over HarfBuzz.
//!
//! HarfBuzz is the only font parser. Font bytes are owned here; glyph
//! outlines come in font units, as lines, native quadratics and cubics;
//! metrics such as cap height are measured from glyphs, not read from OS/2.
//! Libraries never touch the file system or the console: callers pass bytes in.

const face = @import("face.zig");
/// Containers: sfnt kinds and outlines, WOFF and WOFF2 unwrapped.
pub const container = @import("container.zig");
/// Grapheme clusters: what a reader takes for one character.
pub const graphemes = @import("graphemes.zig");

pub const Face = face.Face;
pub const faceCount = face.faceCount;
const std = @import("std");
pub const Error = face.Error;

test {
    @import("std").testing.refAllDecls(@This());
    _ = face;
    _ = container;
    _ = graphemes;
}

test "x-height is measured from x's outline" {
    const testdata = @import("graven_testdata");
    const fallback = try Face.init(std.testing.allocator, testdata.fallback, 0);
    defer fallback.deinit();
    try std.testing.expectEqual(@as(?f64, 300), try fallback.xHeight());
    const main = try Face.init(std.testing.allocator, testdata.truetype, 0);
    defer main.deinit();
    try std.testing.expectEqual(@as(?f64, null), try main.xHeight());
}
