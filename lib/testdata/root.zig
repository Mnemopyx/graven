//! Test fonts with known glyphs and areas, made by tools/make-test-fonts.py.

/// TrueType outlines (quadratic).
pub const truetype = @embedFile("GravenTest-TT.ttf");
/// CFF outlines (cubic), the same shapes.
pub const cff = @embedFile("GravenTest-CFF.otf");
