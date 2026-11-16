//! Test fonts with known glyphs and areas, made by tools/make-test-fonts.py.

/// TrueType outlines (quadratic).
pub const truetype = @embedFile("GravenTest-TT.ttf");
/// CFF outlines (cubic), the same shapes.
pub const cff = @embedFile("GravenTest-CFF.otf");
/// Glyphs the others lack (x), at cap height 500, for fallback tests.
pub const fallback = @embedFile("GravenTest-Fallback.ttf");

/// The TrueType and CFF fonts in the web containers, made by
/// tools/make-woff-fixtures.py: WOFF (zlib per table), WOFF2 (Brotli; the
/// TrueType one with glyf, loca and hmtx transformed), and a WOFF2
/// collection of the TrueType and fallback fonts.
pub const truetype_woff = @embedFile("GravenTest-TT.woff");
pub const cff_woff = @embedFile("GravenTest-CFF.woff");
pub const truetype_woff2 = @embedFile("GravenTest-TT.woff2");
pub const cff_woff2 = @embedFile("GravenTest-CFF.woff2");
pub const collection_woff2 = @embedFile("GravenTest-TTC.woff2");
