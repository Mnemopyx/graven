//! Graven font library: a thin Zig layer over HarfBuzz.
//!
//! Planned contents (see the design blueprint, Modules and integration):
//! - owns font bytes; HarfBuzz is the only font parser
//! - glyph outlines as line, quadratic and cubic segments, in font units
//! - metrics measured from glyphs (x-height, cap height, stem widths)
//! - glyph-ID lookups shared with shaping
//!
//! Libraries never touch the file system or the console: callers pass bytes in.

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
