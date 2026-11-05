//! Graven font library: a thin Zig layer over HarfBuzz.
//!
//! HarfBuzz is the only font parser. Font bytes are owned here; glyph
//! outlines come in font units, as lines, native quadratics and cubics;
//! metrics such as cap height are measured from glyphs, not read from OS/2.
//! Libraries never touch the file system or the console: callers pass bytes in.

const face = @import("face.zig");

pub const Face = face.Face;
pub const Error = face.Error;

test {
    @import("std").testing.refAllDecls(@This());
    _ = face;
}
