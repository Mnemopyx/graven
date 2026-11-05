//! Shaping one element (a run in one face) with HarfBuzz.

const std = @import("std");
const hb = @import("hb");
const font = @import("graven_font");

pub const Glyph = struct {
    gid: u32,
    /// Byte offset of the glyph's cluster in the shaped text.
    cluster: u32,
    x_advance: i32,
    y_advance: i32,
    x_offset: i32,
    y_offset: i32,
};

/// Shapes UTF-8 `text` in `face`, left to right for now (bidi comes with the
/// text stage). Positions are in font units.
pub fn shape(a: std.mem.Allocator, face: *font.Face, text: []const u8) ![]Glyph {
    const buf = hb.hb_buffer_create() orelse return error.OutOfMemory;
    defer hb.hb_buffer_destroy(buf);
    hb.hb_buffer_add_utf8(buf, text.ptr, @intCast(text.len), 0, @intCast(text.len));
    hb.hb_buffer_guess_segment_properties(buf);
    hb.hb_shape(face.font, buf, null, 0);
    if (hb.hb_buffer_allocation_successful(buf) == 0) return error.OutOfMemory;

    var n: c_uint = 0;
    const infos = hb.hb_buffer_get_glyph_infos(buf, &n);
    const positions = hb.hb_buffer_get_glyph_positions(buf, &n);
    const out = try a.alloc(Glyph, n);
    for (infos[0..n], positions[0..n], out) |info, pos, *g| {
        g.* = .{
            .gid = info.codepoint,
            .cluster = info.cluster,
            .x_advance = pos.x_advance,
            .y_advance = pos.y_advance,
            .x_offset = pos.x_offset,
            .y_offset = pos.y_offset,
        };
    }
    return out;
}
