//! Undo, redo and the op log.
//!
//! Every change to a model goes through an action: a `Model` function,
//! named in `actions`, called with its arguments. `History.do` calls it and
//! logs it as an `Op` (the action's name and a copy of its arguments). The
//! log runs from a checkpoint, the model as it was at some point, kept as
//! native-format bytes.
//!
//! Undo restores the checkpoint and replays every logged step but the
//! last; redo applies undone steps again; a new step after an undo drops
//! what could have been redone. Replay is exact because actions are pure:
//! the same model and arguments give the same result, IDs included.
//!
//! A step is one or more ops undone together. Ops given the same merge key
//! one after another join one step (a run of arrow-key nudges, typing into
//! one label); `join` adds an op to the step before it (a clean-up the app
//! makes after an edit). What no single action expresses (loading a
//! sample) is logged as a snapshot of the model after it.

const std = @import("std");
const model = @import("model.zig");
const native = @import("native.zig");
const Model = model.Model;
const Allocator = std.mem.Allocator;

/// The `Model` functions that change a model, which the op log records.
pub const actions = [_][:0]const u8{
    "startCanvas",       "setCanvasUnits",     "addFrame",            "setFrameBound",      "markFrameNameDefault",
    "setSheet",          "setMargins",         "setRulerOrigin",      "setUnits",           "nameWorksheet",
    "placePanel",        "movePanel",          "removePanel",         "setPanelMargins",    "setPanelLayer",
    "makePanel",         "releasePanel",       "addLabel",            "setLabelContent",    "moveLabel",
    "alignLabel",        "removeLabel",        "addArt",              "moveArt",            "removeArt",
    "setArtWrap",        "setArtWrapsTracks",  "setArtCutout",        "setArtCorner",       "addTracks",
    "insertTile",        "insertBlank",        "insertRun",           "insertBreak",        "removeAt",
    "removeTile",        "setTileSize",        "setTilePrototype",    "setContent",         "setRunContent",
    "setSlotPlace",      "setSlotStyle",       "setBind",             "setTrackFlow",       "setSegmentLength",
    "moveSegment",       "trimSegments",       "addStyle",            "setCapHeight",       "addPrototype",
    "duplicatePrototype", "removePrototype",   "setPrototype",        "setPrototypeArt",    "setLayerPaint",
    "addPrototypeSlot",  "setPrototypeSlot",   "renamePrototypeSlot", "removePrototypeSlot", "makeGroup",
    "ungroup",           "moveGroup",          "moveToSpace",         "copyToSpace",        "addView",
    "moveView",          "setViewScale",       "removeView",          "addLayer",           "setLayer",
    "moveLayer",         "removeLayer",        "addImage",            "setImage",           "removeImage",
};

fn Fn(comptime name: []const u8) type {
    return @TypeOf(@field(Model, name));
}

/// An action's arguments after the model, as a tuple.
pub fn Args(comptime name: []const u8) type {
    const params = @typeInfo(Fn(name)).@"fn".param_types;
    var types: [params.len - 1]type = undefined;
    for (params[1..], &types) |p, *t| t.* = p.?;
    return @Tuple(&types);
}

/// What an action returns, its error set aside.
pub fn Result(comptime name: []const u8) type {
    const R = @typeInfo(Fn(name)).@"fn".return_type.?;
    return switch (@typeInfo(R)) {
        .error_union => |e| e.payload,
        else => R,
    };
}

/// Which action an op is, or a snapshot.
pub const Tag = blk: {
    var names: [actions.len + 1][]const u8 = undefined;
    for (actions, 0..) |a, i| names[i] = a;
    names[actions.len] = "snapshot";
    break :blk @Enum(u16, .exhaustive, &names, &std.simd.iota(u16, names.len));
};

/// One logged change: an action and its arguments, or the whole model
/// after a change no single action expresses (native-format bytes).
pub const Op = blk: {
    var names: [actions.len + 1][]const u8 = undefined;
    var types: [actions.len + 1]type = undefined;
    for (actions, 0..) |a, i| {
        names[i] = a;
        types[i] = Args(a);
    }
    names[actions.len] = "snapshot";
    types[actions.len] = []const u8;
    break :blk @Union(.auto, Tag, &names, &types, &@splat(.{}));
};

pub const Error = Model.Error || native.Error;

/// Applies op `op` to `m`.
pub fn apply(m: *Model, op: Op) Error!void {
    switch (op) {
        .snapshot => |bytes| {
            const next = try native.decode(m.arena.child_allocator, bytes);
            const rev = m.revision;
            m.deinit();
            m.* = next;
            m.revision = rev + 1;
        },
        inline else => |args, tag| {
            const f = @field(Model, @tagName(tag));
            const R = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
            if (@typeInfo(R) == .error_union) {
                _ = try @call(.auto, f, .{m} ++ args);
            } else {
                _ = @call(.auto, f, .{m} ++ args);
            }
        },
    }
}

pub const Entry = struct {
    op: Op,
    /// Ops of one step share it.
    step: u32,
};

pub const History = struct {
    gpa: Allocator,
    /// Holds the logged ops' arguments.
    arena: std.heap.ArenaAllocator,
    /// The model the log runs from, as native-format bytes.
    checkpoint: []u8 = &.{},
    log: std.ArrayList(Entry) = .empty,
    /// Undone steps, the most recently undone last.
    redo: std.ArrayList(Entry) = .empty,
    next_step: u32 = 1,
    /// The last step's merge key, while ops with it may still join it.
    merge_key: ?u64 = null,

    pub fn init(gpa: Allocator) History {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(h: *History) void {
        h.gpa.free(h.checkpoint);
        h.log.deinit(h.gpa);
        h.redo.deinit(h.gpa);
        h.arena.deinit();
        h.* = undefined;
    }

    /// Starts afresh from `m` as it is now: no undo, no redo.
    pub fn reset(h: *History, m: *const Model) Allocator.Error!void {
        const bytes = try native.encode(h.gpa, m);
        h.gpa.free(h.checkpoint);
        h.checkpoint = bytes;
        h.log.clearRetainingCapacity();
        h.redo.clearRetainingCapacity();
        _ = h.arena.reset(.retain_capacity);
        h.merge_key = null;
    }

    pub fn canUndo(h: *const History) bool {
        return h.log.items.len > 0;
    }

    pub fn canRedo(h: *const History) bool {
        return h.redo.items.len > 0;
    }

    /// Does action `tag` on `m` with `args`, as a new step, and logs it.
    pub fn do(h: *History, m: *Model, comptime tag: Tag, args: Args(@tagName(tag))) Error!Result(@tagName(tag)) {
        return h.doIn(m, tag, args, .new);
    }

    /// As `do`, joining the step before when it was given the same `key`
    /// (and nothing came between).
    pub fn doMerged(h: *History, m: *Model, key: u64, comptime tag: Tag, args: Args(@tagName(tag))) Error!Result(@tagName(tag)) {
        return h.doIn(m, tag, args, .{ .merge = key });
    }

    /// As `do`, as part of the step before (or of the checkpoint, when
    /// there is none): a consequence of the last edit, not an edit itself.
    pub fn join(h: *History, m: *Model, comptime tag: Tag, args: Args(@tagName(tag))) Error!Result(@tagName(tag)) {
        return h.doIn(m, tag, args, .join);
    }

    /// Lets ops given `key` next join the last step, as if it had been
    /// done with that key: a new label, then typing into it, are one step.
    pub fn mergeAs(h: *History, key: u64) void {
        if (h.log.items.len > 0 and h.redo.items.len == 0) h.merge_key = key;
    }

    const Mode = union(enum) { new, merge: u64, join };

    fn doIn(h: *History, m: *Model, comptime tag: Tag, args: Args(@tagName(tag)), mode: Mode) Error!Result(@tagName(tag)) {
        const f = @field(Model, @tagName(tag));
        const R = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
        const result = if (@typeInfo(R) == .error_union) try @call(.auto, f, .{m} ++ args) else @call(.auto, f, .{m} ++ args);
        // The arguments, copied: what the caller passed may not outlive it.
        const bytes = try native.encodeValue(h.gpa, Args(@tagName(tag)), args);
        defer h.gpa.free(bytes);
        const copy = try native.decodeValue(h.arena.allocator(), Args(@tagName(tag)), bytes);
        try h.record(@unionInit(Op, @tagName(tag), copy), mode);
        return result;
    }

    /// Logs the model as it is now, after a change made outside any single
    /// action, as a new step.
    pub fn snapshot(h: *History, m: *const Model) Error!void {
        const bytes = try native.encode(h.arena.allocator(), m);
        try h.record(.{ .snapshot = bytes }, .new);
    }

    fn record(h: *History, op: Op, mode: Mode) Allocator.Error!void {
        if (mode == .join and h.log.items.len == 0) {
            // Nothing to join: it becomes part of the checkpoint, which the
            // caller's model already shows. (Rebuilt lazily by the caller's
            // next reset; replay applies it again from the log otherwise.)
            try h.log.append(h.gpa, .{ .op = op, .step = 0 });
            return;
        }
        const step = switch (mode) {
            .join => h.log.items[h.log.items.len - 1].step,
            .merge => |key| if (h.merge_key == key and h.log.items.len > 0 and h.redo.items.len == 0) h.log.items[h.log.items.len - 1].step else h.newStep(),
            .new => h.newStep(),
        };
        if (mode != .join) {
            h.redo.clearRetainingCapacity();
            h.merge_key = if (mode == .merge) mode.merge else null;
        }
        try h.log.append(h.gpa, .{ .op = op, .step = step });
    }

    fn newStep(h: *History) u32 {
        defer h.next_step += 1;
        return h.next_step;
    }

    /// Undoes the last step: `m` becomes the checkpoint with every step
    /// before it replayed. Returns false when there is nothing to undo.
    pub fn undo(h: *History, m: *Model) Error!bool {
        const items = h.log.items;
        if (items.len == 0) return false;
        const step = items[items.len - 1].step;
        // Step 0 (joined to the checkpoint) is never undone on its own.
        if (step == 0) return false;
        var first = items.len;
        while (first > 0 and items[first - 1].step == step) first -= 1;
        try h.redo.appendSlice(h.gpa, items[first..]);
        h.log.shrinkRetainingCapacity(first);
        h.merge_key = null;
        try h.rebuild(m);
        return true;
    }

    /// Redoes the step undone last. Returns false when there is none.
    pub fn redoStep(h: *History, m: *Model) Error!bool {
        const items = h.redo.items;
        if (items.len == 0) return false;
        const step = items[items.len - 1].step;
        var first = items.len;
        while (first > 0 and items[first - 1].step == step) first -= 1;
        for (items[first..]) |e| try apply(m, e.op);
        try h.log.appendSlice(h.gpa, items[first..]);
        h.redo.shrinkRetainingCapacity(first);
        h.merge_key = null;
        return true;
    }

    /// `m` rebuilt: the checkpoint, then the log replayed.
    fn rebuild(h: *History, m: *Model) Error!void {
        const rev = m.revision;
        var next = try native.decode(m.arena.child_allocator, h.checkpoint);
        errdefer next.deinit();
        for (h.log.items) |e| try apply(&next, e.op);
        m.deinit();
        m.* = next;
        // A new revision, so whatever caches the model's layout redoes it.
        m.revision = rev + 1;
    }
};

const testing = std.testing;

test "undo restores, redo reapplies, and a new step drops the redo" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    const c = try m.startCanvas(.mm);
    var h: History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    const li = try h.do(&m, .addLabel, .{ c, .{ .at = .{ .x = 1, .y = 2 }, .content = "A" } });
    try h.do(&m, .setLabelContent, .{ c, li, "AB" });
    try testing.expectEqualStrings("AB", m.panels.items[c].labels.items[0].content);
    // Undo the content, then the label.
    try testing.expect(try h.undo(&m));
    try testing.expectEqualStrings("A", m.panels.items[c].labels.items[0].content);
    try testing.expect(try h.undo(&m));
    try testing.expectEqual(0, m.panels.items[c].labels.items.len);
    try testing.expect(!try h.undo(&m));
    // Redo both, IDs and all.
    try testing.expect(try h.redoStep(&m));
    try testing.expect(try h.redoStep(&m));
    try testing.expectEqualStrings("AB", m.panels.items[c].labels.items[0].content);
    // Undo once, then a new edit: the redo is gone.
    _ = try h.undo(&m);
    try h.do(&m, .moveLabel, .{ c, 0, .{ .x = 5, .y = 5 } });
    try testing.expect(!h.canRedo());
    try testing.expectEqual(5, m.panels.items[c].labels.items[0].at.x);
}

test "ops with one merge key make one step; joined ops undo with their step; snapshots replay" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    const c = try m.startCanvas(.mm);
    var h: History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    _ = try h.do(&m, .addLabel, .{ c, .{ .at = .{ .x = 0, .y = 0 }, .content = "N" } });
    // Five nudges of one label: one step.
    for (1..6) |i| try h.doMerged(&m, 42, .moveLabel, .{ c, 0, .{ .x = @floatFromInt(i), .y = 0 } });
    try testing.expectEqual(5, m.panels.items[c].labels.items[0].at.x);
    _ = try h.undo(&m);
    try testing.expectEqual(0, m.panels.items[c].labels.items[0].at.x);
    // A joined op goes with the step before.
    try h.do(&m, .setLabelContent, .{ c, 0, "X" });
    try h.join(&m, .alignLabel, .{ c, 0, .centre });
    _ = try h.undo(&m);
    try testing.expectEqualStrings("N", m.panels.items[c].labels.items[0].content);
    try testing.expectEqual(.start, m.panels.items[c].labels.items[0].alignment);
    // A change made directly, logged as a snapshot: undone and redone.
    _ = try m.addFrame("Direct", null);
    try h.snapshot(&m);
    try testing.expectEqual(2, m.spaces.items.len);
    _ = try h.undo(&m);
    try testing.expectEqual(1, m.spaces.items.len);
    _ = try h.redoStep(&m);
    try testing.expectEqual(2, m.spaces.items.len);
}

test "every action named has a model function" {
    inline for (actions) |a| _ = @field(Model, a);
}

test "every op encodes and decodes, as the file's log will hold them" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const op: Op = .{ .moveLabel = .{ 3, 1, .{ .x = 0.1, .y = -2.5 } } };
    const bytes = try native.encodeValue(gpa, Op, op);
    defer gpa.free(bytes);
    const back = try native.decodeValue(arena.allocator(), Op, bytes);
    try testing.expectEqual(3, back.moveLabel[0]);
    try testing.expectEqual(-2.5, back.moveLabel[2].y);
}
