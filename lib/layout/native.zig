//! Graven's native file format: the model as machine-independent binary.
//!
//! A file is a magic header and a run of blocks. Each block is its type
//! (four bytes), its own version (u16), reserved flags (u16), its payload's
//! length (u64), the payload, and a CRC-32C of everything before it in the
//! block. A reader skips block types it does not know, and refuses a block
//! whose checksum fails.
//!
//! The model block ("MODL") holds the model written by reflection, so the
//! format keeps step with the model's types without a hand-kept list, and
//! tolerates their change:
//!
//! * A struct is its field count, then each field as the 32-bit FNV-1a
//!   hash of its name, the length of its value, and the value. A reader
//!   takes the fields it knows by name, skips the rest, and gives a field
//!   the file lacks its default (or zero, empty or null): a field added to
//!   a type does not break older files, nor a removed one newer files.
//! * An enum is its tag's name, so tags may be reordered or added; an
//!   enum with unnamed values (an ID) is its integer.
//! * A tagged union is its tag's name and its payload, length-prefixed.
//! * Integers are fixed-width little-endian (usize as u64); floats are
//!   their raw IEEE 754 bits, so values reload bit for bit; a bool is a
//!   byte; an optional is a presence byte and the value; a slice or list
//!   is its count (u32) and its items, bytes as they are.
//!
//! Nothing depends on the machine: no struct layout, padding or pointer is
//! written.

const std = @import("std");
const model = @import("model.zig");
const Allocator = std.mem.Allocator;

pub const magic = "GRAVEN\x00\x01";

/// The model block's type and the version written.
pub const model_block = "MODL".*;
/// 2: text styles became glyphic contexts (2026-11-16); version 1 files
/// are not read (no migration was wanted).
pub const model_version: u16 = 2;

pub const Error = Allocator.Error || error{ BadFile, BadChecksum, Truncated, UnknownTag, NoModel, TooNew, TooOld };

fn crc(bytes: []const u8) u32 {
    return std.hash.crc.@"CRC-32/ISCSI".hash(bytes);
}

fn nameHash(name: []const u8) u32 {
    return std.hash.Fnv1a_32.hash(name);
}

// Writing --------------------------------------------------------------------

const Writer = struct {
    out: std.ArrayList(u8) = .empty,
    gpa: Allocator,

    fn bytes(w: *Writer, b: []const u8) Allocator.Error!void {
        try w.out.appendSlice(w.gpa, b);
    }

    fn int(w: *Writer, comptime T: type, v: T) Allocator.Error!void {
        // Its width in bytes, not its size in memory (a u24 takes four).
        var buf: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(T, &buf, v, .little);
        try w.bytes(&buf);
    }

    /// Room for a u32 length, filled by `endLength`.
    fn beginLength(w: *Writer) Allocator.Error!usize {
        const at = w.out.items.len;
        try w.int(u32, 0);
        return at;
    }

    fn endLength(w: *Writer, at: usize) void {
        const len: u32 = @intCast(w.out.items.len - at - 4);
        std.mem.writeInt(u32, w.out.items[at..][0..4], len, .little);
    }

    fn name(w: *Writer, s: []const u8) Allocator.Error!void {
        try w.int(u16, @intCast(s.len));
        try w.bytes(s);
    }

    fn value(w: *Writer, comptime T: type, v: T) Allocator.Error!void {
        switch (@typeInfo(T)) {
            .void => {},
            .bool => try w.int(u8, @intFromBool(v)),
            .int => |i| {
                if (T == usize or T == isize) {
                    try w.int(if (i.signedness == .signed) i64 else u64, v);
                } else {
                    const Bits = @Int(i.signedness, std.mem.alignForward(u16, i.bits, 8));
                    try w.int(Bits, v);
                }
            },
            .float => |f| {
                const U = @Int(.unsigned, f.bits);
                try w.int(U, @bitCast(v));
            },
            .@"enum" => |e| if (e.mode == .exhaustive) {
                try w.name(@tagName(v));
            } else {
                try w.value(e.tag_type, @intFromEnum(v));
            },
            .optional => |o| if (v) |x| {
                try w.int(u8, 1);
                try w.value(o.child, x);
            } else try w.int(u8, 0),
            .array => |arr| for (v) |x| try w.value(arr.child, x),
            .pointer => |p| {
                if (p.size != .slice) @compileError("only slices are written: " ++ @typeName(T));
                try w.int(u32, @intCast(v.len));
                if (p.child == u8) try w.bytes(v) else for (v) |x| try w.value(p.child, x);
            },
            .@"union" => |u| {
                if (u.tag_type == null) @compileError("only tagged unions are written: " ++ @typeName(T));
                try w.name(@tagName(v));
                const at = try w.beginLength();
                switch (v) {
                    inline else => |payload| try w.value(@TypeOf(payload), payload),
                }
                w.endLength(at);
            },
            .@"struct" => |s| {
                if (comptime isList(T)) return w.value(@TypeOf(v.items), v.items);
                var n: u32 = 0;
                inline for (s.field_names) |fname| {
                    if (comptime !skipped(T, fname)) n += 1;
                }
                try w.int(u32, n);
                inline for (s.field_names, s.field_types) |fname, ftype| {
                    if (comptime skipped(T, fname)) continue;
                    try w.int(u32, comptime nameHash(fname));
                    const at = try w.beginLength();
                    try w.value(ftype, @field(v, fname));
                    w.endLength(at);
                }
            },
            else => @compileError("cannot write " ++ @typeName(T)),
        }
    }
};

/// Fields that are not part of a document: the model's allocator, and its
/// revision counter (a session's change count).
fn skipped(comptime T: type, comptime field: []const u8) bool {
    if (T == model.Model) return std.mem.eql(u8, field, "arena") or std.mem.eql(u8, field, "revision");
    return false;
}

fn isList(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "items") and @hasField(T, "capacity") and @hasDecl(T, "Slice");
}

/// Appends a block of type `kind` holding `payload`.
fn block(w: *Writer, kind: [4]u8, version: u16, payload: []const u8) Allocator.Error!void {
    const start = w.out.items.len;
    try w.bytes(&kind);
    try w.int(u16, version);
    try w.int(u16, 0);
    try w.int(u64, payload.len);
    try w.bytes(payload);
    try w.int(u32, crc(w.out.items[start..]));
}

/// The model as a native file's bytes, allocated from `gpa`.
pub fn encode(gpa: Allocator, m: *const model.Model) Allocator.Error![]u8 {
    var body: Writer = .{ .gpa = gpa };
    defer body.out.deinit(gpa);
    try body.value(model.Model, m.*);
    var w: Writer = .{ .gpa = gpa };
    errdefer w.out.deinit(gpa);
    try w.bytes(magic);
    try block(&w, model_block, model_version, body.out.items);
    return w.out.toOwnedSlice(gpa);
}

/// Any value the codec writes (a model, an op's arguments), as bytes in
/// the same encoding, allocated from `gpa`.
pub fn encodeValue(gpa: Allocator, comptime T: type, v: T) Allocator.Error![]u8 {
    var w: Writer = .{ .gpa = gpa };
    errdefer w.out.deinit(gpa);
    try w.value(T, v);
    return w.out.toOwnedSlice(gpa);
}

/// A value read from `encodeValue`'s bytes, its strings and lists
/// allocated from `a` (an arena suits).
pub fn decodeValue(a: Allocator, comptime T: type, bytes: []const u8) Error!T {
    var r: Reader = .{ .in = bytes, .a = a };
    const v = try r.value(T);
    if (r.i != bytes.len) return error.BadFile;
    return v;
}

// Reading --------------------------------------------------------------------

const Reader = struct {
    in: []const u8,
    i: usize = 0,
    a: Allocator,

    fn take(r: *Reader, n: usize) Error![]const u8 {
        if (r.in.len - r.i < n) return error.Truncated;
        defer r.i += n;
        return r.in[r.i..][0..n];
    }

    fn int(r: *Reader, comptime T: type) Error!T {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        return std.mem.readInt(T, (try r.take(n))[0..n], .little);
    }

    fn name(r: *Reader) Error![]const u8 {
        return r.take(try r.int(u16));
    }

    fn value(r: *Reader, comptime T: type) Error!T {
        switch (@typeInfo(T)) {
            .void => return {},
            .bool => return (try r.int(u8)) != 0,
            .int => |i| {
                if (T == usize or T == isize) {
                    const v = try r.int(if (i.signedness == .signed) i64 else u64);
                    return std.math.cast(T, v) orelse error.BadFile;
                }
                const Bits = @Int(i.signedness, std.mem.alignForward(u16, i.bits, 8));
                return std.math.cast(T, try r.int(Bits)) orelse error.BadFile;
            },
            .float => |f| {
                const U = @Int(.unsigned, f.bits);
                return @bitCast(try r.int(U));
            },
            .@"enum" => |e| if (e.mode == .exhaustive) {
                const n = try r.name();
                inline for (e.field_names, e.field_values) |fname, fvalue| {
                    if (std.mem.eql(u8, n, fname)) return @enumFromInt(fvalue);
                }
                return error.UnknownTag;
            } else {
                return @enumFromInt(try r.value(e.tag_type));
            },
            .optional => |o| return if ((try r.int(u8)) != 0) try r.value(o.child) else null,
            .array => |arr| {
                var out: T = undefined;
                for (&out) |*x| x.* = try r.value(arr.child);
                return out;
            },
            .pointer => |p| {
                if (p.size != .slice) @compileError("only slices are read: " ++ @typeName(T));
                const n = try r.int(u32);
                if (p.child == u8) {
                    const src = try r.take(n);
                    const out = try r.a.alloc(u8, n);
                    @memcpy(out, src);
                    return out;
                }
                // A count larger than what is left cannot be right.
                if (n > r.in.len - r.i) return error.Truncated;
                const out = try r.a.alloc(p.child, n);
                for (out) |*x| x.* = try r.value(p.child);
                return out;
            },
            .@"union" => |u| {
                const n = try r.name();
                const len = try r.int(u32);
                const end = r.i + len;
                if (end > r.in.len) return error.Truncated;
                inline for (u.field_names, u.field_types) |fname, ftype| {
                    if (std.mem.eql(u8, n, fname)) {
                        const payload = try r.value(ftype);
                        if (r.i != end) return error.BadFile;
                        return @unionInit(T, fname, payload);
                    }
                }
                return error.UnknownTag;
            },
            .@"struct" => |s| {
                if (comptime isList(T)) {
                    const Item = @typeInfo(@FieldType(T, "items")).pointer.child;
                    const items = try r.value([]Item);
                    var list: T = .empty;
                    list.items = items;
                    list.capacity = items.len;
                    return list;
                }
                var out: T = defaultOf(T);
                const n = try r.int(u32);
                for (0..n) |_| {
                    const h = try r.int(u32);
                    const len = try r.int(u32);
                    const end = r.i + len;
                    if (end > r.in.len) return error.Truncated;
                    inline for (s.field_names, s.field_types) |fname, ftype| {
                        if (comptime skipped(T, fname)) continue;
                        if (h == comptime nameHash(fname)) {
                            @field(out, fname) = try r.value(ftype);
                            if (r.i != end) return error.BadFile;
                        }
                    }
                    // A field this reader does not know: skipped.
                    r.i = end;
                }
                return out;
            },
            else => @compileError("cannot read " ++ @typeName(T)),
        }
    }
};

/// What a field the file lacks takes: its default, else zero, false, the
/// first tag, null or empty.
fn defaultOf(comptime T: type) T {
    switch (@typeInfo(T)) {
        .void => return {},
        .bool => return false,
        .int, .float => return 0,
        .@"enum" => |e| return if (e.mode == .exhaustive) @enumFromInt(e.field_values[0]) else @enumFromInt(0),
        .optional => return null,
        .array => |arr| return @splat(defaultOf(arr.child)),
        .pointer => return &.{},
        .@"union" => |u| return @unionInit(T, u.field_names[0], defaultOf(u.field_types[0])),
        .@"struct" => |s| {
            if (comptime isList(T)) return .empty;
            var out: T = undefined;
            inline for (s.field_names, s.field_types, s.field_attrs) |fname, ftype, fattrs| {
                if (comptime fattrs.defaultValue(ftype)) |d| {
                    @field(out, fname) = d;
                } else if (comptime skipped(T, fname)) {
                    // Set by the caller.
                } else {
                    @field(out, fname) = defaultOf(ftype);
                }
            }
            return out;
        },
        else => @compileError("no default for " ++ @typeName(T)),
    }
}

/// Reads a native file into a new model, its strings and lists in the
/// model's own arena.
/// One block of a native file, read and checked.
pub const Block = struct {
    kind: [4]u8,
    version: u16,
    payload: []const u8,
    /// Where the next block starts.
    end: usize,
};

pub const block_header = 4 + 2 + 2 + 8;

/// The block starting at `i`, its checksum verified.
pub fn readBlock(bytes: []const u8, i: usize) Error!Block {
    if (bytes.len < i or bytes.len - i < block_header + 4) return error.Truncated;
    const kind = bytes[i..][0..4].*;
    const version = std.mem.readInt(u16, bytes[i + 4 ..][0..2], .little);
    const len64 = std.mem.readInt(u64, bytes[i + 8 ..][0..8], .little);
    if (len64 > bytes.len - i - block_header - 4) return error.Truncated;
    const len: usize = @intCast(len64);
    const stored = std.mem.readInt(u32, bytes[i + block_header + len ..][0..4], .little);
    if (crc(bytes[i .. i + block_header + len]) != stored) return error.BadChecksum;
    return .{ .kind = kind, .version = version, .payload = bytes[i + block_header ..][0..len], .end = i + block_header + len + 4 };
}

/// Appends a block of type `kind` holding `payload` to `out`.
pub fn appendBlock(gpa: Allocator, out: *std.ArrayList(u8), kind: [4]u8, version: u16, payload: []const u8) Allocator.Error!void {
    var w: Writer = .{ .gpa = gpa, .out = out.* };
    defer out.* = w.out;
    try block(&w, kind, version, payload);
}

/// The CRC-32C files use.
pub fn checksum(bytes: []const u8) u32 {
    return crc(bytes);
}

/// The model held in a model block's payload, in a new model's arena.
pub fn decodeModelBlock(gpa: Allocator, b: Block) Error!model.Model {
    if (b.version > model_version) return error.TooNew;
    if (b.version < model_version) return error.TooOld;
    var m: model.Model = .init(gpa);
    errdefer m.deinit();
    var r: Reader = .{ .in = b.payload, .a = m.arena.allocator() };
    const read = try r.value(model.Model);
    const arena = m.arena;
    m = read;
    m.arena = arena;
    m.revision = 0;
    return m;
}

/// Reads a native file into a new model, its strings and lists in the
/// model's own arena. Every block up to the model must be intact.
pub fn decode(gpa: Allocator, bytes: []const u8) Error!model.Model {
    if (bytes.len < magic.len or !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.BadFile;
    var i: usize = magic.len;
    while (i < bytes.len) {
        const b = try readBlock(bytes, i);
        i = b.end;
        if (std.mem.eql(u8, &b.kind, &model_block)) return decodeModelBlock(gpa, b);
    }
    return error.NoModel;
}

// Text dump --------------------------------------------------------------------

/// `v` as readable text, a field a line, nested by indentation: for reading
/// a document, and for comparing two versions of one (graven dump, as
/// git's text converter). Written by the same reflection as the format, so
/// it keeps step with the model. Not read back.
pub fn dump(w: *std.Io.Writer, comptime T: type, v: T) std.Io.Writer.Error!void {
    // A struct's fields start at the first line, not after a label.
    if (comptime @typeInfo(T) == .@"struct" and !isList(T) and !scalar(T)) {
        var first = true;
        inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |fname, ftype| {
            if (comptime skipped(T, fname)) continue;
            if (!first) try w.writeByte('\n');
            first = false;
            try w.writeAll(fname);
            try w.writeByte(':');
            if (comptime scalar(ftype)) try w.writeByte(' ');
            try dumpValue(w, ftype, @field(v, fname), 2);
        }
    } else {
        try dumpValue(w, T, v, 0);
    }
    try w.writeByte('\n');
}

/// Whether a value of `T` is written on its field's own line.
fn scalar(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .void, .bool, .int, .float, .@"enum" => true,
        .optional => |o| scalar(o.child),
        .pointer => |p| p.child == u8,
        .array => |arr| arr.child == u8,
        .@"struct" => |st| !isList(T) and st.field_names.len == 0,
        else => false,
    };
}

fn newline(w: *std.Io.Writer, indent: usize) std.Io.Writer.Error!void {
    try w.writeByte('\n');
    try w.splatByteAll(' ', indent);
}

fn dumpBytes(w: *std.Io.Writer, b: []const u8) std.Io.Writer.Error!void {
    if (std.unicode.utf8ValidateSlice(b) and std.mem.indexOfScalar(u8, b, 0) == null) {
        try w.printStringEscaped(b);
    } else {
        try w.print("<{d} bytes>", .{b.len});
    }
}

fn dumpList(w: *std.Io.Writer, comptime T: type, items: []const T, indent: usize) std.Io.Writer.Error!void {
    if (items.len == 0) return w.writeAll(" []");
    for (items) |x| {
        try newline(w, indent);
        try w.writeByte('-');
        if (comptime scalar(T)) {
            try w.writeByte(' ');
            try dumpValue(w, T, x, indent + 2);
        } else {
            try dumpValue(w, T, x, indent + 2);
        }
    }
}

/// Writes `v`: a scalar after its label, anything else on the lines after
/// it at `indent`.
fn dumpValue(w: *std.Io.Writer, comptime T: type, v: T, indent: usize) std.Io.Writer.Error!void {
    switch (@typeInfo(T)) {
        .void => try w.writeAll("-"),
        .bool => try w.writeAll(if (v) "true" else "false"),
        .int => try w.print("{d}", .{v}),
        .float => try w.print("{d}", .{v}),
        .@"enum" => |e| if (e.mode == .exhaustive) try w.writeAll(@tagName(v)) else try w.print("{d}", .{@intFromEnum(v)}),
        .optional => |o| if (v) |x| {
            try dumpValue(w, o.child, x, indent);
        } else try w.writeAll(if (comptime scalar(o.child)) "none" else " none"),
        .array => |arr| if (arr.child == u8) {
            for (v) |b| try w.print("{x:0>2}", .{b});
        } else try dumpList(w, arr.child, &v, indent),
        .pointer => |p| if (p.child == u8) try dumpBytes(w, v) else try dumpList(w, p.child, v, indent),
        .@"union" => |u| {
            _ = u;
            switch (v) {
                inline else => |payload| {
                    const P = @TypeOf(payload);
                    if (comptime scalar(P)) {
                        try w.writeAll(" ");
                        try w.writeAll(@tagName(v));
                        if (P != void) {
                            try w.writeByte(' ');
                            try dumpValue(w, P, payload, indent);
                        }
                    } else {
                        try newline(w, indent);
                        try w.writeAll(@tagName(v));
                        try w.writeByte(':');
                        try dumpValue(w, P, payload, indent + 2);
                    }
                },
            }
        },
        .@"struct" => |st| {
            if (comptime isList(T)) return dumpList(w, @typeInfo(@TypeOf(v.items)).pointer.child, v.items, indent);
            if (st.field_names.len == 0) return w.writeAll("{}");
            inline for (st.field_names, st.field_types) |fname, ftype| {
                if (comptime skipped(T, fname)) continue;
                try newline(w, indent);
                try w.writeAll(fname);
                try w.writeByte(':');
                if (comptime scalar(ftype)) try w.writeByte(' ');
                try dumpValue(w, ftype, @field(v, fname), indent + 2);
            }
        },
        else => @compileError("cannot dump " ++ @typeName(T)),
    }
}

const testing = std.testing;

test "a model writes and reads back to the same bytes, with its content" {
    const gpa = testing.allocator;
    var m: model.Model = .init(gpa);
    defer m.deinit();
    const c = try m.startCanvas(.inch);
    const style = try m.addStyle("Label", .{ .cap_height = 3 });
    try m.setStyleFace(style, "math", .{ .family = "Libertinus Math" });
    try m.setStyleRule(style, .variable, .scale, .{ .number = 1.2 });
    const key = try m.addPrototype(.{ .name = "key", .unit = 19.05 });
    const r = try m.addTracks(c, .{ .name = "keys", .origin = .{ .x = 10, .y = 50 }, .prototype = key, .count = 2, .length = 4, .pitch = 19.05 });
    _ = try m.insertTile(c, r, 0, key, 1);
    try m.insertRun(c, r, 1, .{ .style = style, .content = "V = \\frac{1}{2}", .equation = true });
    const f = try m.addFrame("Front", .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 50 });
    _ = try m.addView(0, f, .{ .x = 200, .y = 0 }, 0.5);
    _ = try m.addLayer(0, "Background");
    _ = try m.addImage(0, "photo.png", "\x89PNG...", 40, 20, .{ .x = 0, .y = 0 }, 10, .none);
    const p = try m.placePanel(.{ .name = "Panel 1", .origin = .{ .x = 5, .y = 5 }, .w = 60, .h = 0.1 + 0.2 });

    const bytes = try encode(gpa, &m);
    defer gpa.free(bytes);
    var back = try decode(gpa, bytes);
    defer back.deinit();
    // Read back, it writes the very same bytes: every value bit for bit.
    const again = try encode(gpa, &back);
    defer gpa.free(again);
    try testing.expectEqualSlices(u8, bytes, again);
    // And it is the same document.
    try testing.expectEqual(.inch, back.units);
    try testing.expectEqualStrings("V = \\frac{1}{2}", back.panels.items[c].regions.items[r].items.items[1].what.run.content);
    try testing.expect(back.panels.items[c].regions.items[r].items.items[1].what.run.equation);
    try testing.expectEqualStrings("Libertinus Math", back.textStyle(style).face("math").?.family);
    try testing.expectEqual(1.2, back.textStyle(style).rules.items[0].value.number);
    try testing.expectEqual(0.1 + 0.2, back.panels.items[p].h);
    try testing.expectEqual(2, back.spaces.items.len);
    try testing.expectEqual(1, back.spaces.items[0].views.items.len);
    try testing.expectEqualStrings("\x89PNG...", back.spaces.items[0].images.items[0].data);
    try testing.expectEqual(m.next_id, back.next_id);
    // It goes on being edited like any model.
    try back.insertRun(c, r, 0, .{ .style = style, .content = "more" });
}

test "a damaged file is refused, and unknown blocks are skipped" {
    const gpa = testing.allocator;
    var m: model.Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const bytes = try encode(gpa, &m);
    defer gpa.free(bytes);
    // One flipped bit: the checksum catches it.
    const bad = try gpa.dupe(u8, bytes);
    defer gpa.free(bad);
    bad[bad.len / 2] ^= 0x10;
    try testing.expectError(error.BadChecksum, decode(gpa, bad));
    // Cut short.
    try testing.expectError(error.Truncated, decode(gpa, bytes[0 .. bytes.len - 3]));
    // Not a native file.
    try testing.expectError(error.BadFile, decode(gpa, "PNG and such"));
    // A block of a type this reader does not know, before the model: skipped.
    var w: Writer = .{ .gpa = gpa };
    defer w.out.deinit(gpa);
    try w.bytes(magic);
    try block(&w, "XTRA".*, 3, "from a newer Graven");
    try w.bytes(bytes[magic.len..]);
    var back = try decode(gpa, w.out.items);
    back.deinit();
}

test "fields a reader does not know are skipped, and fields a file lacks take their defaults" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const Old = struct { a: u32, gone: []const u8, b: f64 };
    const New = struct { b: f64, a: u32, added: u16 = 7, maybe: ?bool = null };
    var w: Writer = .{ .gpa = gpa };
    defer w.out.deinit(gpa);
    try w.value(Old, .{ .a = 5, .gone = "dropped", .b = 2.5 });
    var r: Reader = .{ .in = w.out.items, .a = arena.allocator() };
    const n = try r.value(New);
    try testing.expectEqual(5, n.a);
    try testing.expectEqual(2.5, n.b);
    try testing.expectEqual(7, n.added);
    try testing.expectEqual(null, n.maybe);
}

test "a model dumps as text, a field a line" {
    const gpa = testing.allocator;
    var m: model.Model = .init(gpa);
    defer m.deinit();
    const c = try m.startCanvas(.mm);
    const style = try m.addStyle("Body", .{ .cap_height = 3 });
    const r = try m.addTracks(c, .{ .name = "text", .origin = .{ .x = 1.5, .y = 2 }, .style = style, .count = 1, .length = 40, .pitch = 5 });
    try m.insertRun(c, r, 0, .{ .style = style, .content = "Hello \"you\"" });
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try dump(&out.writer, model.Model, m);
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "content: \"Hello \\\"you\\\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "units: mm") != null);
    try testing.expect(std.mem.indexOf(u8, text, "arena") == null);
}
