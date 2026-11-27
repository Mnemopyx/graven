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
//!
//! The history is bounded: past a number of steps or a memory budget, the
//! oldest steps are folded into the checkpoint (`Limits`) and can no
//! longer be undone.

const std = @import("std");
const model = @import("model.zig");
const native = @import("native.zig");
const constrain = @import("constrain.zig");
const legacy = @import("legacy.zig");
const Model = model.Model;
const Allocator = std.mem.Allocator;

/// The `Model` functions that change a model, which the op log records.
pub const actions = [_][:0]const u8{
    "startCanvas",       "setCanvasUnits",     "addFrame",            "setFrameBound",      "markFrameNameDefault",
    "setSheet",          "setMargins",         "setRulerOrigin",      "setUnits",           "nameWorksheet",
    "placePanel",        "movePanel",          "removePanel",         "setPanelMargins",    "setPanelLayer",
    "releasePanel",       "addArt",              "moveArt",            "removeArt",
    "setArtWrap",        "setArtWrapsTracks",  "setArtCutout",        "setArtCorner",       "addTracks",
    "insertTile",        "insertBlank",        "insertRun",           "insertBreak",        "removeAt",
    "removeTile",        "setTileSize",        "setTilePrototype",    "setRunContent",
    "setBind",             "setTrackFlow",       "setSegmentLength",
    "moveSegment",       "trimSegments",       "addStyle",            "setCapHeight",       "addPrototype",
    "duplicatePrototype", "removePrototype",   "setPrototype",        "setPrototypeArt",    "setLayerPaint",
    "makeGroup",
    "ungroup",           "moveGroup",          "moveToSpace",         "copyToSpace",        "addView",
    "moveView",          "setViewScale",       "removeView",          "addLayer",           "setLayer",
    "moveLayer",         "removeLayer",        "addImage",            "setImage",           "removeImage",
    "renameStyle",       "setStyleBase",       "setStyleFace",        "setStyleRule",
    "addParagraphStyle",  "setParagraphStyle",   "insertParagraph",    "setParagraphAt",
    "setEmSize",         "addConstraint",      "setConstraintValue",  "setConstraintPlace",  "setConstraintDriving", "removeConstraint",   "setObjectOrigin", "addEqualSet", "removeConstraintMember",
    "addControlPoint",   "bendPath",           "moveControlPoint",    "removeControlPoint", "joinTracks", "unjoinTrack", "threadTracks", "placeObjects", "insertText", "insertMarkup", "deleteRange", "setEmphasis", "changeCase", "breakAt", "insertEquation",
    "addSketch", "addSketchSpace", "homeSpace", "removeSketch", "removeSpace", "addSketchView", "moveSketchView", "removeSketchView", "renameSketch", "editSketch", "editSketchDraft", "acceptSketch", "discardSketchDraft", "setInkDraft", "setFillDraft", "inkPiecesDraft", "fillPiecesDraft", "addDrawing", "setSketchDrawing", "setPanelDrawing", "makeSketchPanel", "insertSketchPanel", "setPanelIslands", "applySketch", "setPrototypeSketchOffset", "removePrototypeSketch", "setTileParam",
    "addGrid", "addArray", "addCaption", "addStrokeStyle", "setStrokeStyle", "setConnectorStyle", "setConnectorKind", "setConnectorLevel", "addConnection", "setConnectorShape", "setCurrentStroke", "setInk", "addFillStyle", "setFillStyle", "setCurrentFill", "setFill", "addLinkedGrid", "setGridShape", "moveGrid", "removeGrid", "addStamp", "setStamp", "removeStamp", "addInstance", "fillGrid", "placeInstance", "setInstanceSpan", "bindInstance", "removeInstance",
    "addPrototypeTrack", "setPrototypeTrack", "removePrototypeTrack", "setTileTrackText", "setTrackText", "addShapeSketch", "setPanelFab",
    "addFlow", "renameFlow", "assignTrack", "detachTrack", "removeFlow", "addFlowSource", "placeInFlow", "insertBreakIn", "setParagraphAtIn", "addSheet", "makeSheet", "makeTextSheet", "setSheetShown", "setSheetCell", "addSheetRow", "removeSheetRow", "addSheetColumn", "removeSheetColumn", "renameSheet", "removeSheet", "renameTile", "addSheetSource", "setPanelSize", "moveRegion", "setRegionSize", "setLeading", "copyStyle", "copyParagraphStyle", "addStyleTemplate", "renameStyleTemplate", "deriveStyle", "setTemplateLeading", "addCase", "setCaseKey", "splitAt", "setFlowStyle", "setLinePitch", "setItemGap", "renameRegion", "nameKeysInOrder", "renamePanel", "addProcess", "setProcess", "removeProcess", "setPanelProcess", "addMaterial", "setMaterial", "removeMaterial", "addPlan", "setPlan", "removePlan", "setActivePlan",
    "removeRegion", "setOrientation", "splitIntoTracks",
    "addGuide", "setGuide", "removeGuide",
    "nameKeysInPanel", "setOverlay", "setGridSpacing",
    "addFigure", "placeFigure", "placeFigureOnPanel", "setFigureArtWidth", "replaceFigure", "setPlaceBorder", "setArtBorder", "setFigurePlace", "removeFigurePlace", "renameFigure", "removeFigure",
    "setMeasureUnit",
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
    @setEvalBranchQuota(100_000);
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

// Logs written before workspaces held containers directly (segment version
// 2 and older; 2026-11-24): a content layout's or a grid's parent was a
// panel's index (a workspace's own panel among them), and Make panel took
// loose line art. Such a log is read with these types and replayed by
// `applyLegacy` (see `legacy.zig`).

const legacy_actions = actions ++ [_][:0]const u8{"makePanel"};

fn LegacyArgs(comptime name: []const u8) type {
    if (std.mem.eql(u8, name, "makePanel")) return struct { usize, usize };
    const A = Args(name);
    const fields = @typeInfo(A).@"struct".field_types;
    var types: [fields.len]type = undefined;
    for (fields, &types) |f, *t| t.* = if (f == model.Parent) usize else f;
    return @Tuple(&types);
}

pub const LegacyOp = blk: {
    @setEvalBranchQuota(200_000);
    var names: [legacy_actions.len + 1][]const u8 = undefined;
    var types: [legacy_actions.len + 1]type = undefined;
    for (legacy_actions, 0..) |a, i| {
        names[i] = a;
        types[i] = LegacyArgs(a);
    }
    names[legacy_actions.len] = "snapshot";
    types[legacy_actions.len] = []const u8;
    const Tags = @Enum(u16, .exhaustive, &names, &std.simd.iota(u16, names.len));
    break :blk @Union(.auto, Tags, &names, &types, &@splat(.{}));
};

const LegacyEntry = struct {
    op: LegacyOp,
    step: u32,
    size: u32 = 0,
};

const LegacySegment = struct {
    writer: [16]u8 = @splat(0),
    device: []const u8 = "",
    time: i64 = 0,
    tool: []const u8 = "",
    first: u64 = 0,
    entries: []const LegacyEntry = &.{},
    views: []const u8 = &.{},
};

/// Applies an op of an older log to a model read with its workspaces' own
/// panels kept (see `legacy.zig`), then solves its constraints.
fn applyLegacy(m: *Model, op: LegacyOp) Error!void {
    switch (op) {
        .snapshot => |bytes| {
            const next = try native.decodeKeepingRoots(m.arena.child_allocator, bytes);
            const rev = m.revision;
            m.deinit();
            m.* = next;
            m.revision = rev + 1;
        },
        .startCanvas => |args| _ = try legacy.startCanvas(m, args[0]),
        .addFrame => |args| _ = try legacy.addFrame(m, args[0], args[1]),
        .makePanel => |args| _ = try legacy.makePanel(m, args[0], args[1]),
        .releasePanel => |args| _ = try legacy.releasePanel(m, args[0]),
        inline else => |args, tag| {
            @setEvalBranchQuota(100_000);
            const A = Args(@tagName(tag));
            var conv: A = undefined;
            inline for (0..args.len) |k| {
                conv[k] = if (@TypeOf(conv[k]) == model.Parent) .{ .panel = args[k] } else args[k];
            }
            try applyOnly(m, @unionInit(Op, @tagName(tag), conv));
        },
    }
    try m.syncSheets();
    try constrain.solve(m, m.arena.child_allocator, null);
}

/// Applies op `op` to `m`, then solves its constraints, so what they
/// constrain follows (see `constrain`).
pub fn apply(m: *Model, op: Op) Error!void {
    try applyOnly(m, op);
    // The keys show their sheets, whatever the op changed.
    try m.syncSheets();
    try constrain.solve(m, m.arena.child_allocator, null);
}

fn applyOnly(m: *Model, op: Op) Error!void {
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

/// `op` with its arguments copied into `a`.
fn copyOp(a: Allocator, op: Op) Error!Op {
    var buf: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer buf.deinit();
    const bytes = try native.encodeValue(buf.allocator(), Op, op);
    return native.decodeValue(a, Op, bytes);
}

pub const Entry = struct {
    op: Op,
    /// Ops of one step share it.
    step: u32,
    /// The op's encoded size: what it costs to keep, for the limits.
    size: u32 = 0,
};

/// How much history is kept. Past either limit the oldest steps are folded
/// into the checkpoint, down to three quarters of it, so folding is
/// occasional rather than on every step.
pub const Limits = struct {
    /// Steps that can be undone.
    steps: usize = 2000,
    /// Bytes the logged ops may take (the checkpoint aside, which folding
    /// cannot shrink).
    bytes: usize = 64 << 20,
};

pub const History = struct {
    gpa: Allocator,
    /// Holds the logged ops' arguments.
    arena: std.heap.ArenaAllocator,
    /// The model the log runs from, as native-format bytes.
    checkpoint: []u8 = &.{},
    /// The app's views of the document, written with each segment (see
    /// `Segment.views`); the app sets it before writing. Not owned.
    views: []const u8 = &.{},
    log: std.ArrayList(Entry) = .empty,
    /// Undone steps, the most recently undone last.
    redo: std.ArrayList(Entry) = .empty,
    next_step: u32 = 1,
    /// The last step's merge key, while ops with it may still join it.
    merge_key: ?u64 = null,
    /// The next joined op starts a new step instead (`beginStep`).
    fresh: bool = false,
    /// Where the log stood when last saved; null when never saved.
    saved: ?Mark = null,
    /// The saved state was folded into the checkpoint, or undone and
    /// replaced: no undo or redo reaches it again.
    saved_lost: bool = false,
    limits: Limits = .{},
    /// The file this history was last written to or opened from, as it
    /// was then; null when there is none.
    file: ?FileState = null,
    /// The log's first `stable` entries are as they were when the file was
    /// last written (undo lowers it).
    stable: usize = 0,

    const Mark = struct { len: usize, last: u32 };

    fn mark(h: *const History) Mark {
        const items = h.log.items;
        return .{ .len = items.len, .last = if (items.len > 0) items[items.len - 1].step else 0 };
    }

    /// Whether there are changes since the last save (or, never saved,
    /// any changes at all). Undoing back to where a save left the log
    /// counts as saved.
    pub fn isDirty(h: *const History) bool {
        if (h.saved_lost) return true;
        const now = h.mark();
        if (h.saved) |s| return !(s.len == now.len and s.last == now.last);
        return now.len != 0;
    }

    /// Records that the log as it stands has been saved.
    pub fn markSaved(h: *History) void {
        h.saved = h.mark();
        h.saved_lost = false;
    }

    /// Whether the saved state is the log's first entries: the checkpoint
    /// with them replayed is the document as saved.
    fn savedInLog(h: *const History) ?usize {
        if (h.saved_lost) return null;
        const s = h.saved orelse return null;
        if (s.len > h.log.items.len) return null;
        const last: u32 = if (s.len > 0) h.log.items[s.len - 1].step else 0;
        return if (last == s.last) s.len else null;
    }

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
        h.saved = null;
        h.saved_lost = false;
        h.file = null;
        h.stable = 0;
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

    /// Makes the next op a new step even when it is joined, so that a
    /// sequence of joined ops (written to join whatever step is current)
    /// can be one step of its own when a person asks for it.
    pub fn beginStep(h: *History) void {
        h.fresh = true;
    }

    const Mode = union(enum) { new, merge: u64, join };

    fn doIn(h: *History, m: *Model, comptime tag: Tag, args: Args(@tagName(tag)), mode: Mode) Error!Result(@tagName(tag)) {
        const f = @field(Model, @tagName(tag));
        const R = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
        const result = if (@typeInfo(R) == .error_union) try @call(.auto, f, .{m} ++ args) else @call(.auto, f, .{m} ++ args);
        // The keys show their sheets, and what constraints hold follows,
        // as replaying the op does.
        try m.syncSheets();
        try constrain.solve(m, h.gpa, null);
        // The arguments, copied: what the caller passed may not outlive it.
        const bytes = try native.encodeValue(h.gpa, Args(@tagName(tag)), args);
        defer h.gpa.free(bytes);
        const copy = try native.decodeValue(h.arena.allocator(), Args(@tagName(tag)), bytes);
        try h.record(@unionInit(Op, @tagName(tag), copy), @intCast(bytes.len), mode);
        return result;
    }

    /// Logs the model as it is now, after a change made outside any single
    /// action, as a new step.
    pub fn snapshot(h: *History, m: *const Model) Error!void {
        const bytes = try native.encode(h.arena.allocator(), m);
        try h.record(.{ .snapshot = bytes }, @intCast(bytes.len), .new);
    }

    fn record(h: *History, op: Op, size: u32, mode_in: Mode) Error!void {
        const mode: Mode = if (h.fresh) .new else mode_in;
        h.fresh = false;
        if (mode == .join and h.log.items.len == 0) {
            // Nothing to join: it becomes part of the checkpoint, which the
            // caller's model already shows. (Rebuilt lazily by the caller's
            // next reset; replay applies it again from the log otherwise.)
            try h.log.append(h.gpa, .{ .op = op, .step = 0, .size = size });
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
        try h.log.append(h.gpa, .{ .op = op, .step = step, .size = size });
        if (mode != .join) try h.keepToLimits();
    }

    /// Steps in the log that can be undone (not those joined to the
    /// checkpoint).
    pub fn stepCount(h: *const History) usize {
        var n: usize = 0;
        var last: u32 = 0;
        for (h.log.items) |e| {
            if (e.step != 0 and e.step != last) n += 1;
            last = e.step;
        }
        return n;
    }

    /// What the logged and undone ops take, in their encoded size.
    pub fn logBytes(h: *const History) usize {
        var n: usize = 0;
        for (h.log.items) |e| n += e.size;
        for (h.redo.items) |e| n += e.size;
        return n;
    }

    /// Folds the oldest steps into the checkpoint while either limit is
    /// passed, down to three quarters of it; the last step always stays.
    fn keepToLimits(h: *History) Error!void {
        var steps = h.stepCount();
        var bytes = h.logBytes();
        if (steps <= h.limits.steps and bytes <= h.limits.bytes) return;
        const keep_steps = h.limits.steps * 3 / 4;
        const keep_bytes = h.limits.bytes * 3 / 4;
        const items = h.log.items;
        var n: usize = 0;
        while (n < items.len) {
            const step = items[n].step;
            var end = n;
            var run: usize = 0;
            while (end < items.len and items[end].step == step) : (end += 1) run += items[end].size;
            if (end == items.len) break;
            if (step != 0 and steps <= keep_steps and bytes <= keep_bytes) break;
            n = end;
            if (step != 0) steps -= 1;
            bytes -= run;
        }
        if (n > 0) try h.fold(n);
    }

    /// Folds the log's first `n` entries into the checkpoint: they can no
    /// longer be undone. The file must then be written whole.
    pub fn fold(h: *History, n: usize) Error!void {
        var m = try native.decode(h.gpa, h.checkpoint);
        defer m.deinit();
        for (h.log.items[0..n]) |e| try apply(&m, e.op);
        const bytes = try native.encode(h.gpa, &m);
        h.gpa.free(h.checkpoint);
        h.checkpoint = bytes;
        if (h.saved) |*s| {
            if (s.len >= n) {
                s.len -= n;
                if (s.len == 0) s.last = 0;
            } else {
                h.saved = null;
                h.saved_lost = true;
            }
        }
        // What stays, copied into a fresh arena, so what was folded is
        // freed.
        var arena: std.heap.ArenaAllocator = .init(h.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        for (h.log.items[n..]) |*e| e.op = try copyOp(a, e.op);
        for (h.redo.items) |*e| e.op = try copyOp(a, e.op);
        h.arena.deinit();
        h.arena = arena;
        std.mem.copyForwards(Entry, h.log.items, h.log.items[n..]);
        h.log.shrinkRetainingCapacity(h.log.items.len - n);
        h.stable = 0;
        if (h.file) |*f| f.appendable = false;
    }

    /// Folds the whole log into the checkpoint and drops the redo: the
    /// document as it is, with no history.
    pub fn compact(h: *History) Error!void {
        if (h.log.items.len > 0) try h.fold(h.log.items.len);
        h.redo.clearRetainingCapacity();
        h.merge_key = null;
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
        h.stable = @min(h.stable, first);
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
    _ = try m.startCanvas(.mm);
    const c = try m.addPanel("Panel", 200, 200);
    var h: History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    const li = try h.do(&m, .addArt, .{ c, .{ .name = "A", .at = .{ .x = 1, .y = 2 }, .shapes = &.{} } });
    try h.do(&m, .moveArt, .{ c, li, .{ .x = 3, .y = 3 } });
    try testing.expectEqual(3, m.panels.items[c].art.items[0].at.x);
    // Undo the move, then the art.
    try testing.expect(try h.undo(&m));
    try testing.expectEqual(1, m.panels.items[c].art.items[0].at.x);
    try testing.expect(try h.undo(&m));
    try testing.expectEqual(0, m.panels.items[c].art.items.len);
    try testing.expect(!try h.undo(&m));
    // Redo both, IDs and all.
    try testing.expect(try h.redoStep(&m));
    try testing.expect(try h.redoStep(&m));
    try testing.expectEqual(3, m.panels.items[c].art.items[0].at.x);
    // Undo once, then a new edit: the redo is gone.
    _ = try h.undo(&m);
    try h.do(&m, .moveArt, .{ c, 0, .{ .x = 5, .y = 5 } });
    try testing.expect(!h.canRedo());
    try testing.expectEqual(5, m.panels.items[c].art.items[0].at.x);
}

test "a sketch is drawn and constrained through the history, and saves and reopens" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    const c: model.Parent = .{ .space = try m.startCanvas(.mm) };
    _ = c;
    var h: History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    const si = try h.do(&m, .addSketch, .{ 0, "Sketch 1", .{ .x = 10, .y = 20 } });
    const seg = try h.do(&m, .editSketch, .{ si, .{ .segment = .{ .a = .{ .x = 0.2, .y = 0.1 }, .b = .{ .x = 9, .y = 1 } } } });
    _ = try h.do(&m, .editSketch, .{ si, .{ .constrain = .{ .kind = .{ .coincident = .{ .{ .geom = seg, .role = .start }, .{ .geom = model.sketch_.origin } } } } } });
    _ = try h.do(&m, .editSketch, .{ si, .{ .constrain = .{ .kind = .{ .horizontal = .{ .geom = seg } } } } });
    _ = try h.do(&m, .editSketch, .{ si, .{ .constrain = .{ .kind = .{ .distance = .{ .a = .{ .geom = seg, .role = .start }, .b = .{ .geom = seg, .role = .end }, .value = 12 } }, .name = "len" } } });
    const sk = &m.sketches.items[0].sketch;
    try testing.expectApproxEqAbs(@as(f64, 12), (try sk.point(.{ .geom = seg, .role = .end })).x, 1e-9);
    // Undo the length: the segment keeps its solved place, and redo sets it.
    try testing.expect(try h.undo(&m));
    try testing.expectEqual(@as(usize, 2), m.sketches.items[0].sketch.constraints.items.len);
    try testing.expect(try h.redoStep(&m));
    try testing.expectEqual(@as(usize, 3), m.sketches.items[0].sketch.constraints.items.len);
    // Saved and read back: the same sketch, which solves the same.
    const bytes = try native.encode(gpa, &m);
    defer gpa.free(bytes);
    var back = try native.decode(gpa, bytes);
    defer back.deinit();
    const bk = &back.sketches.items[0];
    try testing.expectEqualStrings("Sketch 1", bk.name);
    try testing.expectEqual(@as(f64, 10), back.spaces.items[0].sketch_views.items[0].at.x);
    try testing.expectEqualStrings("len", bk.sketch.constraints.items[2].name);
    _ = try back.editSketch(0, .{ .value = .{ .c = 2, .value = 15 } });
    try testing.expectApproxEqAbs(@as(f64, 15), (try bk.sketch.point(.{ .geom = seg, .role = .end })).x, 1e-9);
    // A parameter drives the length by expression, through the history,
    // and both reload.
    _ = try h.do(&m, .editSketch, .{ si, .{ .param = .{ .name = "w", .expr = "20" } } });
    _ = try h.do(&m, .editSketch, .{ si, .{ .expr = .{ .c = 2, .text = "w / 2" } } });
    try testing.expectApproxEqAbs(@as(f64, 10), (try m.sketches.items[0].sketch.point(.{ .geom = seg, .role = .end })).x, 1e-9);
    const bytes2 = try native.encode(gpa, &m);
    defer gpa.free(bytes2);
    var back2 = try native.decode(gpa, bytes2);
    defer back2.deinit();
    try testing.expectEqualStrings("w / 2", back2.sketches.items[0].sketch.constraints.items[2].expr);
    try testing.expectEqualStrings("w", back2.sketches.items[0].sketch.params.items[0].name);
    try testing.expect(try h.undo(&m));
    try testing.expectEqual(@as(usize, 0), m.sketches.items[0].sketch.constraints.items[2].expr.len);
}

test "ops with one merge key make one step; joined ops undo with their step; snapshots replay" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const c = try m.addPanel("Panel", 200, 200);
    var h: History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    _ = try h.do(&m, .addArt, .{ c, .{ .name = "N", .at = .{ .x = 0, .y = 0 }, .shapes = &.{} } });
    // Five nudges of one piece of art: one step.
    for (1..6) |i| try h.doMerged(&m, 42, .moveArt, .{ c, 0, .{ .x = @floatFromInt(i), .y = 0 } });
    try testing.expectEqual(5, m.panels.items[c].art.items[0].at.x);
    _ = try h.undo(&m);
    try testing.expectEqual(0, m.panels.items[c].art.items[0].at.x);
    // A joined op goes with the step before.
    try h.do(&m, .moveArt, .{ c, 0, .{ .x = 9, .y = 0 } });
    try h.join(&m, .setArtWrap, .{ c, 0, .none, 0 });
    _ = try h.undo(&m);
    try testing.expectEqual(0, m.panels.items[c].art.items[0].at.x);
    try testing.expectEqual(model.Wrap.ink, m.panels.items[c].art.items[0].wrap);
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

test "a keypad grid: holes, legends and keys bound to its points, keys on a part that follows it" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    var h: History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    const plate = try h.do(&m, .placePanel, .{model.Panel{ .name = "Plate", .space = m.spaces.items[0].id, .origin = .{ .x = 0, .y = 0 }, .w = 140, .h = 60 }});
    const keys = try h.do(&m, .placePanel, .{model.Panel{ .name = "Keys", .space = m.spaces.items[0].id, .origin = .{ .x = 0, .y = 100 }, .w = 140, .h = 60 }});
    const key_proto = try h.do(&m, .addPrototype, .{model.TilePrototype{ .name = "Key", .tracks = &.{.{ .name = "top", .alignment = .centre }} }});
    const legend_proto = try h.do(&m, .addPrototype, .{model.TilePrototype{ .name = "Legend", .tracks = &.{.{ .name = "f", .alignment = .centre }} }});
    // 10 columns by 4 rows, 13 mm apart across and 12 down.
    const g = try h.do(&m, .addGrid, .{ .{ .panel = plate }, .{ .x = 10, .y = 50 }, model.GridShape{ .cols = 10, .rows = 4, .pitch_x = 13, .pitch_y = 12 } });
    const holes = try h.do(&m, .addStamp, .{ .{ .panel = plate }, g, model.Stamp{ .name = "Holes", .prototype = key_proto, .role = .hole, .w = 10, .h = 8 } });
    const legends = try h.do(&m, .addStamp, .{ .{ .panel = plate }, g, model.Stamp{ .name = "Legends", .prototype = legend_proto, .role = .legend, .w = 11, .h = 3, .offset = .{ .x = 0, .y = 6 } } });
    // A prototype a stamp uses stays, even with no instances made yet; the
    // stamp keeps naming it, not whatever comes to sit where it was.
    const early = try h.do(&m, .addPrototype, .{model.TilePrototype{ .name = "Early" }});
    const spare = try h.do(&m, .addPrototype, .{model.TilePrototype{ .name = "Spare" }});
    const empty = try h.do(&m, .addStamp, .{ .{ .panel = plate }, g, model.Stamp{ .name = "Empty", .prototype = spare, .w = 5, .h = 5 } });
    try testing.expectError(error.PrototypeInUse, m.removePrototype(spare));
    try h.do(&m, .removePrototype, .{early});
    try testing.expectEqual(spare, m.panels.items[plate].grids.items[g].stamps.items[empty].prototype);
    try testing.expectEqualStrings("Spare", m.proto(spare).name);
    try h.do(&m, .removeStamp, .{ .{ .panel = plate }, g, empty });
    try testing.expectEqual(@as(usize, 40), try h.do(&m, .fillGrid, .{ .{ .panel = plate }, g, holes }));
    try testing.expectEqual(@as(usize, 40), try h.do(&m, .fillGrid, .{ .{ .panel = plate }, g, legends }));
    // The keys: a part whose grid follows the plate's.
    const plate_grid = m.panels.items[plate].grids.items[g].id;
    const kg = try h.do(&m, .addLinkedGrid, .{ .{ .panel = keys }, .{ .x = 10, .y = 50 }, plate_grid });
    const caps = try h.do(&m, .addStamp, .{ .{ .panel = keys }, kg, model.Stamp{ .name = "Keys", .prototype = key_proto, .w = 9, .h = 7 } });
    _ = try h.do(&m, .fillGrid, .{ .{ .panel = keys }, kg, caps });
    // ENTER: column 5, rows 2 and 3, on both grids.
    const enter_hole = m.instanceAt(.{ .panel = plate }, g, m.panels.items[plate].grids.items[g].stamps.items[holes].id, 5, 2).?;
    try h.do(&m, .setInstanceSpan, .{ .{ .panel = plate }, g, enter_hole, 1, 2 });
    const enter_key = m.instanceAt(.{ .panel = keys }, kg, m.panels.items[keys].grids.items[kg].stamps.items[caps].id, 5, 2).?;
    try h.do(&m, .setInstanceSpan, .{ .{ .panel = keys }, kg, enter_key, 1, 2 });
    try testing.expectEqual(@as(usize, 79), m.panels.items[plate].grids.items[g].instances.items.len);
    const eb = m.instanceBox(.{ .panel = plate }, g, m.instanceAt(.{ .panel = plate }, g, m.panels.items[plate].grids.items[g].stamps.items[holes].id, 5, 3).?).?;
    try testing.expectApproxEqAbs(@as(f64, 8 + 12), eb.height(), 1e-9);
    // Its centre is between rows 2 and 3.
    try testing.expectApproxEqAbs(@as(f64, 50 - 2.5 * 12), (eb.y0 + eb.y1) / 2, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10 + 5 * 13), (eb.x0 + eb.x1) / 2, 1e-9);

    // Dragged over points: one instance spanning them, keeping the labels
    // of the first that lay there.
    const k00 = m.panels.items[keys].grids.items[kg].instances.items[0].tile;
    try m.setTrackText(k00, "top", "ON");
    const before = m.panels.items[keys].grids.items[kg].instances.items.len;
    const wide = try h.do(&m, .placeInstance, .{ .{ .panel = keys }, kg, caps, 0, 0, 2, 1 });
    try testing.expectEqual(k00, wide);
    try testing.expectEqual(before - 1, m.panels.items[keys].grids.items[kg].instances.items.len);
    try testing.expect(try h.undo(&m));
    try testing.expectEqual(before, m.panels.items[keys].grids.items[kg].instances.items.len);

    // Stretching the plate's grid moves the holes, the legends and the
    // keys on the other part together.
    try h.do(&m, .setGridShape, .{ .{ .panel = plate }, g, model.GridShape{ .cols = 10, .rows = 4, .pitch_x = 13, .pitch_y = 12, .stretch_x = 1.1 }, .leave });
    const hole9 = m.instanceAt(.{ .panel = plate }, g, m.panels.items[plate].grids.items[g].stamps.items[holes].id, 9, 0).?;
    const key9 = m.instanceAt(.{ .panel = keys }, kg, m.panels.items[keys].grids.items[kg].stamps.items[caps].id, 9, 0).?;
    const hb = m.instanceBox(.{ .panel = plate }, g, hole9).?;
    const kb = m.instanceBox(.{ .panel = keys }, kg, key9).?;
    try testing.expectApproxEqAbs(@as(f64, 10 + 9 * 13 * 1.1), (hb.x0 + hb.x1) / 2, 1e-9);
    try testing.expectApproxEqAbs((hb.x0 + hb.x1) / 2, (kb.x0 + kb.x1) / 2, 1e-9);
    // A legend sits above its hole, in line with it.
    const leg9 = m.instanceBox(.{ .panel = plate }, g, m.instanceAt(.{ .panel = plate }, g, m.panels.items[plate].grids.items[g].stamps.items[legends].id, 9, 0).?).?;
    try testing.expectApproxEqAbs((hb.x0 + hb.x1) / 2, (leg9.x0 + leg9.x1) / 2, 1e-9);
    try testing.expect(leg9.y0 > hb.y1);

    // One column fewer: left in place, the last column's holes keep their
    // places, unbound; the keys' grid follows and its keys are left too.
    try h.do(&m, .setGridShape, .{ .{ .panel = plate }, g, model.GridShape{ .cols = 9, .rows = 4, .pitch_x = 13, .pitch_y = 12, .stretch_x = 1.1 }, .leave });
    const left = m.panels.items[plate].grids.items[g].instances.items[hole9];
    try testing.expect(left.loose != null);
    try testing.expectApproxEqAbs((hb.x0 + hb.x1) / 2, left.loose.?.x, 1e-9);
    try testing.expect(m.panels.items[keys].grids.items[kg].instances.items[key9].loose != null);
    try testing.expectEqual(@as(u32, 9), m.gridShape(.{ .panel = keys }, kg).cols);
    // Undone, and done again removing them instead.
    try testing.expect(try h.undo(&m));
    try testing.expectEqual(@as(u32, 10), m.gridShape(.{ .panel = keys }, kg).cols);
    try h.do(&m, .setGridShape, .{ .{ .panel = plate }, g, model.GridShape{ .cols = 9, .rows = 4, .pitch_x = 13, .pitch_y = 12, .stretch_x = 1.1 }, .remove });
    try testing.expectEqual(@as(usize, 79 - 8), m.panels.items[plate].grids.items[g].instances.items.len);
    try testing.expectEqual(@as(usize, 39 - 4), m.panels.items[keys].grids.items[kg].instances.items.len);

    // Placed: the holes are cut through the plate's outline; legends have
    // no shapes; key labels sit on the keys.
    const key0 = m.panels.items[keys].grids.items[kg].instances.items[0].tile;
    try m.setTrackText(key0, "top", "x");
    const place = @import("place.zig");
    var labels: place.Labels = .init(gpa, &.{});
    defer labels.deinit();
    var placed = try place.solve(gpa, &m, .{ .panel = plate }, &labels);
    defer placed.deinit();
    try testing.expect(placed.edge != null);
    var cut: usize = 0;
    for (placed.tiles) |t| {
        if (t.grid == .hole) cut += 1;
        if (t.grid == .legend) try testing.expectEqual(@as(usize, 0), t.shapes.len);
    }
    try testing.expectEqual(@as(usize, 4 * 9 - 1), cut);

    // Saved and read back.
    const bytes = try native.encode(gpa, &m);
    defer gpa.free(bytes);
    var back = try native.decode(gpa, bytes);
    defer back.deinit();
    try testing.expectEqual(plate_grid, back.panels.items[keys].grids.items[kg].link);
    const back_enter = back.instanceAt(.{ .panel = plate }, g, back.panels.items[plate].grids.items[g].stamps.items[holes].id, 5, 3).?;
    try testing.expectEqual(@as(u32, 2), back.panels.items[plate].grids.items[g].instances.items[back_enter].rows);
    try testing.expectEqual(model.GridRole.legend, back.panels.items[plate].grids.items[g].stamps.items[legends].role);
}

test "every op encodes and decodes, as the file's log will hold them" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const op: Op = .{ .moveArt = .{ 3, 1, .{ .x = 0.1, .y = -2.5 } } };
    const bytes = try native.encodeValue(gpa, Op, op);
    defer gpa.free(bytes);
    const back = try native.decodeValue(arena.allocator(), Op, bytes);
    try testing.expectEqual(3, back.moveArt[0]);
    try testing.expectEqual(-2.5, back.moveArt[2].y);
}

// The document file ------------------------------------------------------------
//
// A document file is the checkpoint (a native file: magic and model block),
// then the op log in segments. Each segment is a block saying who wrote it
// (the app run's random ID, the device, the time, the tool's version) and
// where in the log its entries go: they replace the log from that entry on,
// so a segment written after an undo shortens the log as well as extending
// it. A trailer block follows each segment: its offset, length and
// checksum, the checksum of the trailer before it (so the segments form a
// chain), the log's length after it, whether it marks a save, and the
// writer's ID.
//
// A segment counts only once its trailer is intact: a torn tail, from a
// crash or a partial sync, is dropped and reported, and the rest opens.
// Segments after the last save are unsaved work (periodic appends, from a
// run that ended before saving); the one opening the file chooses to keep
// or discard them.
//
// Writing appends a segment while the file is as this history last left it
// and the checkpoint has not moved; otherwise it writes the whole file
// afresh. Neither moves the checkpoint (only the limits do), so undo
// reaches back past a save, after reopening too.

pub const segment_block = "OPSG".*;
pub const trailer_block = "TRLR".*;
/// 3: parents are workspaces or panels (2026-11-24); older segments are
/// read as `LegacySegment`.
const segment_version: u16 = 3;

/// Who writes: one run of an app. A new run is a new writer, so a crashed
/// run's unsaved segments count as someone else's.
pub const Writer = struct {
    /// Random (version 4 UUID), fresh for each run.
    id: [16]u8,
    device: []const u8 = "",
    tool: []const u8 = "",
};

/// The tool and version segments record.
pub const tool_version = "Graven 0.0.0";

/// A writer ID from 16 random bytes: a version 4 UUID.
pub fn writerId(random: [16]u8) [16]u8 {
    var id = random;
    id[6] = (id[6] & 0x0f) | 0x40;
    id[8] = (id[8] & 0x3f) | 0x80;
    return id;
}

/// A segment's block.
pub const Segment = struct {
    writer: [16]u8 = @splat(0),
    device: []const u8 = "",
    /// When it was written, in seconds since 1970 (UTC).
    time: i64 = 0,
    tool: []const u8 = "",
    /// The log entry its entries start at; those from there on are
    /// replaced.
    first: u64 = 0,
    entries: []const Entry = &.{},
    /// The app's views of the document as they were when written (the
    /// app's own encoding; empty when it gave none). Opening takes the
    /// last intact segment's.
    views: []const u8 = &.{},
};

const Trailer = struct {
    segment_at: u64,
    segment_len: u64,
    segment_crc: u32,
    previous: u32,
    /// The log's length after this segment.
    log_len: u64,
    /// The log as it stands after this segment is the document as saved.
    saved: bool,
    writer: [16]u8 = @splat(0),
};

const trailer_len = 52;

fn trailerBytes(t: Trailer) [trailer_len]u8 {
    var b: [trailer_len]u8 = undefined;
    std.mem.writeInt(u64, b[0..8], t.segment_at, .little);
    std.mem.writeInt(u64, b[8..16], t.segment_len, .little);
    std.mem.writeInt(u32, b[16..20], t.segment_crc, .little);
    std.mem.writeInt(u32, b[20..24], t.previous, .little);
    std.mem.writeInt(u64, b[24..32], t.log_len, .little);
    std.mem.writeInt(u32, b[32..36], @intFromBool(t.saved), .little);
    b[36..52].* = t.writer;
    return b;
}

fn readTrailer(version: u16, p: []const u8) ?Trailer {
    if (p.len < 32) return null;
    var t: Trailer = .{
        .segment_at = std.mem.readInt(u64, p[0..8], .little),
        .segment_len = std.mem.readInt(u64, p[8..16], .little),
        .segment_crc = std.mem.readInt(u32, p[16..20], .little),
        .previous = std.mem.readInt(u32, p[20..24], .little),
        .log_len = std.mem.readInt(u64, p[24..32], .little),
        // Version 1 wrote only saves.
        .saved = true,
    };
    if (version >= 2) {
        if (p.len < trailer_len) return null;
        t.saved = std.mem.readInt(u32, p[32..36], .little) & 1 != 0;
        t.writer = p[36..52].*;
    }
    return t;
}

/// A file as this history last wrote or opened it, to append to it and to
/// notice when someone else has.
pub const FileState = struct {
    len: u64,
    /// Where its last trailer block starts, and that trailer's checksum.
    trailer_at: u64 = 0,
    trailer_crc: u32 = 0,
    /// The log's length it holds.
    entries: usize = 0,
    /// False after folding (the checkpoint moved) or a damaged tail: the
    /// next write is the whole file.
    appendable: bool = true,
    /// It holds steps after its last save (autosaved, or from a run that
    /// never saved them).
    unsaved: bool = false,
};

/// Bytes to write, from `History.prepareWrite`.
pub const Write = struct {
    bytes: []u8,
    /// Append at this offset of the file as it is; null: write the whole
    /// file afresh.
    at: ?u64,
    next: FileState,
    save: bool,

    pub fn deinit(w: *Write, gpa: Allocator) void {
        gpa.free(w.bytes);
        w.* = undefined;
    }
};

pub const WriteKind = enum {
    /// The document as it is becomes the saved one.
    save,
    /// The steps since the last write are kept in the file as unsaved
    /// work, recoverable after a crash.
    autosave,
};

pub const WriteError = Error || error{
    /// An autosave would have to write the whole file, and the saved state
    /// is no longer in the history to write it: only a save can.
    SavedStateLost,
};

fn appendSegment(gpa: Allocator, out: *std.ArrayList(u8), base: u64, previous: u32, who: Writer, now: i64, first: usize, entries: []const Entry, log_len: usize, saved: bool, views: []const u8) Allocator.Error!struct { at: u64, crc: u32 } {
    const at = out.items.len;
    const seg: Segment = .{ .writer = who.id, .device = who.device, .time = now, .tool = who.tool, .first = first, .entries = entries, .views = views };
    const payload = try native.encodeValue(gpa, Segment, seg);
    defer gpa.free(payload);
    try native.appendBlock(gpa, out, segment_block, segment_version, payload);
    const block = out.items[at..];
    const t = trailerBytes(.{
        .segment_at = base + at,
        .segment_len = block.len,
        .segment_crc = native.checksum(block),
        .previous = previous,
        .log_len = log_len,
        .saved = saved,
        .writer = who.id,
    });
    const t_at = out.items.len;
    try native.appendBlock(gpa, out, trailer_block, segment_version, &t);
    return .{ .at = base + t_at, .crc = native.checksum(&t) };
}

/// What to write to keep the file up to date: a segment to append when the
/// file is as this history last left it, else the whole file. `fresh`
/// asks for the whole file whatever the state (Save As, or a file someone
/// else changed). Hand the result to `wrote` once it is written.
pub fn prepareWrite(h: *const History, gpa: Allocator, who: Writer, now: i64, kind: WriteKind, fresh: bool) WriteError!Write {
    const save = kind == .save;
    const log = h.log.items;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (!fresh) if (h.file) |f| if (f.appendable) {
        const first = @min(h.stable, f.entries);
        const t = try appendSegment(gpa, &out, f.len, f.trailer_crc, who, now, first, log[first..], log.len, save, h.views);
        const len = f.len + out.items.len;
        return .{
            .bytes = try out.toOwnedSlice(gpa),
            .at = f.len,
            .next = .{ .len = len, .trailer_at = t.at, .trailer_crc = t.crc, .entries = log.len, .unsaved = !save },
            .save = save,
        };
    };
    // The whole file: the checkpoint, then the saved log, then (for an
    // autosave) the unsaved steps after it.
    const saved_len: usize = if (save) log.len else h.savedInLog() orelse return error.SavedStateLost;
    try out.appendSlice(gpa, h.checkpoint);
    var t = try appendSegment(gpa, &out, 0, 0, who, now, 0, log[0..saved_len], saved_len, true, h.views);
    if (saved_len < log.len) t = try appendSegment(gpa, &out, 0, t.crc, who, now, saved_len, log[saved_len..], log.len, false, h.views);
    const len = out.items.len;
    return .{
        .bytes = try out.toOwnedSlice(gpa),
        .at = null,
        .next = .{ .len = len, .trailer_at = t.at, .trailer_crc = t.crc, .entries = log.len, .unsaved = saved_len < log.len },
        .save = save,
    };
}

/// What to write to drop the unsaved steps a file holds (the user chose
/// not to save them): a segment putting the log back as saved, marked as
/// the save. Null when the file holds none. The history itself is left as
/// it is; hand the result to `wroteDiscard` once it is written.
pub fn prepareDiscard(h: *const History, gpa: Allocator, who: Writer, now: i64) WriteError!?Write {
    const f = h.file orelse return null;
    if (!f.unsaved) return null;
    const saved_len = h.savedInLog() orelse return error.SavedStateLost;
    const log = h.log.items;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var at: ?u64 = null;
    var t: @TypeOf(try appendSegment(gpa, &out, 0, 0, who, now, 0, &.{}, 0, true, h.views)) = undefined;
    if (f.appendable) {
        const first = @min(h.stable, f.entries, saved_len);
        t = try appendSegment(gpa, &out, f.len, f.trailer_crc, who, now, first, log[first..saved_len], saved_len, true, h.views);
        at = f.len;
    } else {
        try out.appendSlice(gpa, h.checkpoint);
        t = try appendSegment(gpa, &out, 0, 0, who, now, 0, log[0..saved_len], saved_len, true, h.views);
    }
    const len = (at orelse 0) + out.items.len;
    return .{
        .bytes = try out.toOwnedSlice(gpa),
        .at = at,
        .next = .{ .len = len, .trailer_at = t.at, .trailer_crc = t.crc, .entries = saved_len },
        .save = false,
    };
}

/// Records that `w`, from `prepareDiscard`, was written.
pub fn wroteDiscard(h: *History, w: *const Write) void {
    h.file = w.next;
    h.stable = @min(h.stable, w.next.entries);
}

/// Whether the log has changed since the file was last written.
pub fn changedSinceWrite(h: *const History) bool {
    const f = h.file orelse return h.log.items.len > 0;
    return h.stable != h.log.items.len or f.entries != h.log.items.len;
}

/// Records that `w` was written.
pub fn wrote(h: *History, w: *const Write) void {
    h.file = w.next;
    h.stable = h.log.items.len;
    if (w.save) h.markSaved();
}

/// Whether the file's bytes are as this history last wrote or opened them:
/// false when another run (or anything else) has written to it since.
pub fn fileIsAsLeft(h: *const History, bytes: []const u8) bool {
    const f = h.file orelse return false;
    if (bytes.len != f.len) return false;
    if (f.trailer_at == 0) return true;
    const b = native.readBlock(bytes, @intCast(f.trailer_at)) catch return false;
    return std.mem.eql(u8, &b.kind, &trailer_block) and b.end == bytes.len and native.checksum(b.payload) == f.trailer_crc;
}

/// The document as a whole file, saved: the checkpoint and the whole log.
/// Allocated from `gpa`.
pub fn fileBytes(h: *const History, gpa: Allocator, who: Writer, now: i64) WriteError![]u8 {
    const w = try prepareWrite(h, gpa, who, now, .save, true);
    return w.bytes;
}

/// Unsaved work found on opening: the segments after the last save.
pub const Unsaved = struct {
    /// Entries they hold.
    entries: usize,
    /// Who wrote the first of them, and when.
    writer: [16]u8,
    device: []const u8,
    time: i64,
};

/// A document file opened: its model (the checkpoint with the log
/// replayed), its history, and what had to be dropped or decided.
pub const Opened = struct {
    model: Model,
    history: History,
    /// The end of the file was damaged and dropped: what it held is lost,
    /// everything before it is here.
    damaged: bool = false,
    /// Steps after the last save, which the model includes. `discardUnsaved`
    /// goes back to the save.
    unsaved: ?Unsaved = null,
    /// The log as saved.
    saved_log: []const Entry = &.{},
    /// The app's views as the last intact segment kept them (empty when
    /// none did). In the history's arena.
    views: []const u8 = &.{},

    /// Back to the document as last saved: the unsaved steps are dropped.
    /// The file still holds them, so the next write is the whole file.
    pub fn discardUnsaved(o: *Opened) Error!void {
        if (o.unsaved == null) return;
        const h = &o.history;
        h.log.clearRetainingCapacity();
        try h.log.appendSlice(h.gpa, o.saved_log);
        h.redo.clearRetainingCapacity();
        try h.rebuild(&o.model);
        h.markSaved();
        h.stable = 0;
        if (h.file) |*f| f.appendable = false;
        o.unsaved = null;
    }
};

/// Opens a document file. The checkpoint must be intact; a damaged tail
/// of the log is dropped (see `Opened.damaged`).
pub fn openFile(gpa: Allocator, bytes: []const u8) Error!Opened {
    if (bytes.len < native.magic.len or !std.mem.eql(u8, bytes[0..native.magic.len], native.magic)) return error.BadFile;
    var i: usize = native.magic.len;
    // Up to and including the model block: the checkpoint.
    while (true) {
        const b = try native.readBlock(bytes, i);
        i = b.end;
        if (std.mem.eql(u8, &b.kind, &native.model_block)) break;
    }
    var h: History = .init(gpa);
    errdefer h.deinit();
    const a = h.arena.allocator();
    h.checkpoint = try gpa.dupe(u8, bytes[0..i]);
    var damaged = false;
    var pending: ?Segment = null;
    var pending_at: usize = 0;
    var previous: u32 = 0;
    var file: FileState = .{ .len = i, .appendable = false };
    var saved_log: []const Entry = &.{};
    var unsaved: ?Unsaved = null;
    var views: []const u8 = &.{};
    // An older log (see `LegacyOp`), replayed as it was written.
    var old_log: std.ArrayList(LegacyEntry) = .empty;
    defer old_log.deinit(gpa);
    var old_pending: ?LegacySegment = null;
    var is_old = false;
    while (i < bytes.len) {
        const b = native.readBlock(bytes, i) catch {
            damaged = true;
            break;
        };
        if (std.mem.eql(u8, &b.kind, &segment_block)) {
            if (b.version < segment_version) {
                // Older segments only before newer ones: a file is written
                // whole again once read.
                if (h.log.items.len > 0) {
                    damaged = true;
                    break;
                }
                is_old = true;
                old_pending = if (b.version < 2)
                    .{ .entries = native.decodeValue(a, []const LegacyEntry, b.payload) catch {
                        damaged = true;
                        break;
                    } }
                else
                    native.decodeValue(a, LegacySegment, b.payload) catch {
                        damaged = true;
                        break;
                    };
                const os = old_pending.?;
                pending = .{ .writer = os.writer, .device = os.device, .time = os.time, .tool = os.tool, .first = os.first, .views = os.views };
            } else {
                if (is_old) {
                    damaged = true;
                    break;
                }
                pending = native.decodeValue(a, Segment, b.payload) catch {
                    damaged = true;
                    break;
                };
            }
            pending_at = i;
        } else if (std.mem.eql(u8, &b.kind, &trailer_block)) {
            const t = readTrailer(b.version, b.payload) orelse {
                damaged = true;
                break;
            };
            const seg = pending orelse {
                damaged = true;
                break;
            };
            const n_entries = if (old_pending) |os| os.entries.len else seg.entries.len;
            const log_len = if (is_old) old_log.items.len else h.log.items.len;
            const fits = t.segment_at == pending_at and t.previous == previous and seg.first <= log_len and
                t.log_len == seg.first + n_entries and t.segment_at + t.segment_len <= bytes.len and
                native.checksum(bytes[@intCast(t.segment_at)..@intCast(t.segment_at + t.segment_len)]) == t.segment_crc;
            if (!fits) {
                damaged = true;
                break;
            }
            if (old_pending) |os| {
                old_log.shrinkRetainingCapacity(@intCast(seg.first));
                try old_log.appendSlice(gpa, os.entries);
                old_pending = null;
            } else {
                h.log.shrinkRetainingCapacity(@intCast(seg.first));
                try h.log.appendSlice(gpa, seg.entries);
            }
            if (seg.views.len > 0) views = seg.views;
            pending = null;
            previous = native.checksum(b.payload);
            if (t.saved) {
                saved_log = try a.dupe(Entry, h.log.items);
                unsaved = null;
            } else if (unsaved) |*u| {
                u.entries += n_entries;
            } else {
                unsaved = .{ .entries = n_entries, .writer = seg.writer, .device = seg.device, .time = seg.time };
            }
            file = .{ .len = b.end, .trailer_at = i, .trailer_crc = previous, .appendable = true };
        }
        i = b.end;
    }
    // A segment with no trailer after it never finished being written.
    if (pending != null) damaged = true;
    if (damaged) file.appendable = false;
    file.entries = h.log.items.len;
    file.unsaved = unsaved != null;
    if (is_old) {
        // The older log replayed as written, then the workspaces' own
        // panels taken away. What was read becomes the checkpoint: undo
        // starts from here, and the next write is the whole file.
        var m = try native.decodeKeepingRoots(gpa, h.checkpoint);
        errdefer m.deinit();
        for (old_log.items) |e| applyLegacy(&m, e.op) catch {
            damaged = true;
            break;
        };
        try m.upgradeRoots();
        m.revision = 1;
        const fresh = try native.encode(gpa, &m);
        gpa.free(h.checkpoint);
        h.checkpoint = fresh;
        h.log.clearRetainingCapacity();
        h.next_step = 1;
        h.saved = .{ .len = 0, .last = 0 };
        h.file = .{ .len = 0, .appendable = false };
        h.stable = 0;
        return .{ .model = m, .history = h, .damaged = damaged, .views = views };
    }
    var m = try native.decode(gpa, h.checkpoint);
    errdefer m.deinit();
    var max_step: u32 = 0;
    for (h.log.items) |e| {
        try apply(&m, e.op);
        max_step = @max(max_step, e.step);
    }
    m.revision = 1;
    h.next_step = max_step + 1;
    h.saved = .{ .len = saved_log.len, .last = if (saved_log.len > 0) saved_log[saved_log.len - 1].step else 0 };
    h.file = file;
    h.stable = h.log.items.len;
    return .{ .model = m, .history = h, .damaged = damaged, .unsaved = unsaved, .saved_log = saved_log, .views = views };
}

const test_writer: Writer = .{ .id = @splat(7), .device = "test", .tool = "test" };
const other_writer: Writer = .{ .id = @splat(9), .device = "elsewhere", .tool = "test" };

/// Writes `w` into `file` as an app would: appended, or the whole file.
fn testWrite(gpa: Allocator, file: *std.ArrayList(u8), w: *const Write) !void {
    if (w.at) |at| {
        try testing.expectEqual(file.items.len, at);
        try file.appendSlice(gpa, w.bytes);
    } else {
        file.clearRetainingCapacity();
        try file.appendSlice(gpa, w.bytes);
    }
}

test "a saved document reopens with its history: undo reaches back past the save" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const c = try m.addPanel("Panel", 200, 200);
    var h: History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    try testing.expect(!h.isDirty());
    _ = try h.do(&m, .addArt, .{ c, .{ .name = "first", .at = .{ .x = 1, .y = 2 }, .shapes = &.{} } });
    try h.do(&m, .moveArt, .{ c, 0, .{ .x = 2, .y = 2 } });
    try testing.expect(h.isDirty());
    var w = try prepareWrite(&h, gpa, test_writer, 1, .save, false);
    defer w.deinit(gpa);
    try testing.expectEqual(null, w.at);
    wrote(&h, &w);
    try testing.expect(!h.isDirty());
    // Undoing below the save point is unsaved; redoing back to it is not.
    _ = try h.undo(&m);
    try testing.expect(h.isDirty());
    _ = try h.redoStep(&m);
    try testing.expect(!h.isDirty());

    var o = try openFile(gpa, w.bytes);
    defer o.model.deinit();
    defer o.history.deinit();
    try testing.expect(!o.damaged);
    try testing.expectEqual(null, o.unsaved);
    try testing.expect(!o.history.isDirty());
    try testing.expectEqual(2, o.model.panels.items[c].art.items[0].at.x);
    // Undo after reopening reaches back past the save, to the checkpoint.
    try testing.expect(try o.history.undo(&o.model));
    try testing.expectEqual(1, o.model.panels.items[c].art.items[0].at.x);
    try testing.expect(try o.history.undo(&o.model));
    try testing.expectEqual(0, o.model.panels.items[c].art.items.len);
    // New steps after reopening carry on numbering.
    _ = try o.history.redoStep(&o.model);
    _ = try o.history.do(&o.model, .addArt, .{ c, .{ .name = "third", .at = .{ .x = 0, .y = 0 }, .shapes = &.{} } });
    try testing.expect(o.history.log.items[o.history.log.items.len - 1].step > o.history.log.items[0].step);
}

test "a torn end of the file is dropped, and the checkpoint still opens" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const c = try m.addPanel("Panel", 200, 200);
    var h: History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    _ = try h.do(&m, .addArt, .{ c, .{ .name = "lost", .at = .{ .x = 1, .y = 2 }, .shapes = &.{} } });
    const bytes = try fileBytes(&h, gpa, test_writer, 1);
    defer gpa.free(bytes);
    // Cut in the trailer: the segment never counted.
    var o = try openFile(gpa, bytes[0 .. bytes.len - 10]);
    defer o.model.deinit();
    defer o.history.deinit();
    try testing.expect(o.damaged);
    try testing.expect(!o.history.file.?.appendable);
    try testing.expectEqual(0, o.model.panels.items[c].art.items.len);
    // A damaged checkpoint cannot open at all.
    const bad = try gpa.dupe(u8, bytes);
    defer gpa.free(bad);
    bad[native.magic.len + 20] ^= 1;
    try testing.expectError(error.BadChecksum, openFile(gpa, bad));
}

test "autosaves append unsaved steps; undo then edit appends a segment that replaces the log's tail" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const c = try m.addPanel("Panel", 200, 200);
    var h: History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);

    _ = try h.do(&m, .addArt, .{ c, .{ .name = "a", .at = .{ .x = 1, .y = 2 }, .shapes = &.{} } });
    {
        var w = try prepareWrite(&h, gpa, test_writer, 1, .save, false);
        defer w.deinit(gpa);
        try testWrite(gpa, &file, &w);
        wrote(&h, &w);
    }
    _ = try h.do(&m, .addArt, .{ c, .{ .name = "b", .at = .{ .x = 3, .y = 4 }, .shapes = &.{} } });
    _ = try h.do(&m, .addArt, .{ c, .{ .name = "c", .at = .{ .x = 5, .y = 6 }, .shapes = &.{} } });
    {
        var w = try prepareWrite(&h, gpa, test_writer, 2, .autosave, false);
        defer w.deinit(gpa);
        try testing.expect(w.at != null);
        try testWrite(gpa, &file, &w);
        wrote(&h, &w);
    }
    try testing.expect(h.isDirty());
    try testing.expect(fileIsAsLeft(&h, file.items));
    // Undo "c" and add "d" instead: the next segment starts at "c".
    _ = try h.undo(&m);
    _ = try h.do(&m, .addArt, .{ c, .{ .name = "d", .at = .{ .x = 7, .y = 8 }, .shapes = &.{} } });
    {
        var w = try prepareWrite(&h, gpa, test_writer, 3, .autosave, false);
        defer w.deinit(gpa);
        try testing.expect(w.at != null);
        try testWrite(gpa, &file, &w);
        wrote(&h, &w);
    }

    // Opened elsewhere (a crash, say): the unsaved steps come back, and can
    // be discarded back to the save.
    var o = try openFile(gpa, file.items);
    defer o.model.deinit();
    defer o.history.deinit();
    try testing.expect(!o.damaged);
    const art = o.model.panels.items[c].art.items;
    try testing.expectEqual(3, art.len);
    try testing.expectEqualStrings("d", art[2].name);
    try testing.expect(o.unsaved != null);
    try testing.expectEqualStrings("test", o.unsaved.?.device);
    try testing.expect(o.history.isDirty());
    try o.discardUnsaved();
    try testing.expectEqual(1, o.model.panels.items[c].art.items.len);
    try testing.expect(!o.history.isDirty());
    // The file still holds the discarded steps: the next write is whole.
    var w = try prepareWrite(&o.history, gpa, other_writer, 4, .autosave, false);
    defer w.deinit(gpa);
    try testing.expectEqual(null, w.at);
}

test "another writer's append is noticed before writing" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const c = try m.addPanel("Panel", 200, 200);
    var h: History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    var w = try prepareWrite(&h, gpa, test_writer, 1, .save, false);
    try testWrite(gpa, &file, &w);
    wrote(&h, &w);
    w.deinit(gpa);
    try testing.expect(fileIsAsLeft(&h, file.items));

    // The other run opens it, edits and saves.
    var o = try openFile(gpa, file.items);
    defer o.model.deinit();
    defer o.history.deinit();
    _ = try o.history.do(&o.model, .addArt, .{ c, .{ .name = "theirs", .at = .{ .x = 0, .y = 0 }, .shapes = &.{} } });
    var w2 = try prepareWrite(&o.history, gpa, other_writer, 2, .save, false);
    defer w2.deinit(gpa);
    try testing.expect(w2.at != null);
    try testWrite(gpa, &file, &w2);
    try testing.expect(!fileIsAsLeft(&h, file.items));
}

test "past the limits the oldest steps fold into the checkpoint" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const c = try m.addPanel("Panel", 200, 200);
    var h: History = .init(gpa);
    defer h.deinit();
    h.limits = .{ .steps = 4 };
    try h.reset(&m);
    _ = try h.do(&m, .addArt, .{ c, .{ .name = "0", .at = .{ .x = 0, .y = 0 }, .shapes = &.{} } });
    h.markSaved();
    var buf: [4]u8 = undefined;
    _ = &buf;
    for (1..10) |k| try h.do(&m, .moveArt, .{ c, 0, .{ .x = @floatFromInt(k), .y = 0 } });
    try testing.expect(h.stepCount() <= 4);
    // The save was folded away: still unsaved, whatever is undone.
    try testing.expect(h.saved_lost);
    // Undo goes back as far as is kept, and no further.
    var undone: usize = 0;
    while (try h.undo(&m)) undone += 1;
    try testing.expectEqual(h.redo.items.len, undone);
    try testing.expect(h.isDirty());
    const first = m.panels.items[c].art.items[0].at.x;
    try testing.expect(first != 0);
    // Redo all: the model is as it was.
    while (try h.redoStep(&m)) {}
    try testing.expectEqual(9, m.panels.items[c].art.items[0].at.x);
    // Compacting folds the rest.
    try h.compact();
    try testing.expectEqual(0, h.log.items.len);
    var back = try native.decode(gpa, h.checkpoint);
    defer back.deinit();
    try testing.expectEqual(9, back.panels.items[c].art.items[0].at.x);
}

test "not saving drops the autosaved steps from the file" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const c = try m.addPanel("Panel", 200, 200);
    var h: History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    _ = try h.do(&m, .addArt, .{ c, .{ .name = "kept", .at = .{ .x = 1, .y = 2 }, .shapes = &.{} } });
    var w = try prepareWrite(&h, gpa, test_writer, 1, .save, false);
    try testWrite(gpa, &file, &w);
    wrote(&h, &w);
    w.deinit(gpa);
    try testing.expectEqual(null, try prepareDiscard(&h, gpa, test_writer, 2));
    _ = try h.do(&m, .addArt, .{ c, .{ .name = "dropped", .at = .{ .x = 3, .y = 4 }, .shapes = &.{} } });
    w = try prepareWrite(&h, gpa, test_writer, 2, .autosave, false);
    try testWrite(gpa, &file, &w);
    wrote(&h, &w);
    w.deinit(gpa);
    try testing.expect(!changedSinceWrite(&h));
    var d = (try prepareDiscard(&h, gpa, test_writer, 3)).?;
    defer d.deinit(gpa);
    try testWrite(gpa, &file, &d);
    wroteDiscard(&h, &d);
    try testing.expect(fileIsAsLeft(&h, file.items));
    var o = try openFile(gpa, file.items);
    defer o.model.deinit();
    defer o.history.deinit();
    try testing.expectEqual(null, o.unsaved);
    try testing.expectEqual(1, o.model.panels.items[c].art.items.len);
}

test "style edits undo and redo, and survive saving and reopening" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    var h: History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    const style = try h.do(&m, .addStyle, .{ "Label", .{ .cap_height = 3 } });
    try h.do(&m, .setStyleFace, .{ style, "text", @as(?model.FontName, .{ .family = "Inter" }) });
    try h.do(&m, .setStyleRule, .{ style, @as(?@import("graven_glyphic").Kind, .variable), .scale, @as(?@import("graven_glyphic").Value, .{ .number = 1.1 }) });
    // Undo the rule; redo it.
    _ = try h.undo(&m);
    try testing.expectEqual(0, m.textStyle(style).rules.items.len);
    _ = try h.redoStep(&m);
    try testing.expectEqual(1.1, m.textStyle(style).rules.items[0].value.number);

    const bytes = try fileBytes(&h, gpa, test_writer, 1);
    defer gpa.free(bytes);
    var o = try openFile(gpa, bytes);
    defer o.model.deinit();
    defer o.history.deinit();
    const back = o.model.textStyle(style);
    try testing.expectEqualStrings("Label", back.name);
    try testing.expectEqualStrings("Inter", back.face("text").?.family);
    try testing.expectEqual(.variable, back.rules.items[0].kind.?);
}

test "a thread of tracks is kept in the file, and its join is a step undo takes back" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("page", 200, 100);
    const key = try m.addPrototype(.{ .name = "key" });
    const a = try m.addTracks(.{ .panel = p }, .{ .name = "A", .origin = .{ .x = 10, .y = 90 }, .prototype = key, .count = 1, .length = 3, .pitch = 10 });
    const b = try m.addTracks(.{ .panel = p }, .{ .name = "B", .origin = .{ .x = 60, .y = 90 }, .prototype = key, .count = 1, .length = 3, .pitch = 10 });
    var h: History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    _ = try h.do(&m, .joinTracks, .{ .{ .panel = p }, a, b });
    const bytes = try fileBytes(&h, gpa, test_writer, 1);
    defer gpa.free(bytes);
    var o = try openFile(gpa, bytes);
    defer o.model.deinit();
    defer o.history.deinit();
    try testing.expectEqual(b, o.model.threadAfter(.{ .panel = p }, a).?.region);
    try testing.expect(try o.history.undo(&o.model));
    try testing.expect(o.model.threadAfter(.{ .panel = p }, a) == null);
}

test "a sheet's edits are steps undo takes back, and the sheet is kept in the file" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const p = try m.addPanel("Keys", 60, 30);
    const key = try m.addPrototype(.{ .name = "key", .tracks = &.{.{ .name = "top" }} });
    const g = try m.addGrid(.{ .panel = p }, .{ .x = 10, .y = 20 }, .{ .cols = 1, .rows = 1, .pitch_x = 12, .pitch_y = 12 });
    const st = try m.addStamp(.{ .panel = p }, g, .{ .name = "Keys", .prototype = key, .w = 8, .h = 8 });
    const k = try m.addInstance(.{ .panel = p }, g, st, 0, 0);
    var h: History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    const sheet = try h.do(&m, .makeSheet, .{ "Legends", m.panels.items[p].grids.items[g].id });
    _ = try h.do(&m, .setSheetCell, .{ sheet, 0, 1, "ENTER" });
    const bytes = try fileBytes(&h, gpa, test_writer, 1);
    defer gpa.free(bytes);
    var o = try openFile(gpa, bytes);
    defer o.model.deinit();
    defer o.history.deinit();
    const top = o.model.tileTrackNamed(k, "top").?;
    var text = try o.model.tileTrackText(gpa, k, top);
    try testing.expectEqualStrings("ENTER", text);
    gpa.free(text);
    try testing.expect(try o.history.undo(&o.model));
    text = try o.model.tileTrackText(gpa, k, top);
    defer gpa.free(text);
    try testing.expectEqualStrings("", text);
    try testing.expectEqualStrings("", o.model.sheets.items[0].rows.items[0].cells.items[0]);
}

test "the app's views go with each segment, and the last intact one's come back" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    var h: History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    _ = try h.do(&m, .startCanvas, .{.mm});
    h.views = "first";
    var w = try prepareWrite(&h, gpa, test_writer, 1, .save, true);
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    try file.appendSlice(gpa, w.bytes);
    wrote(&h, &w);
    gpa.free(w.bytes);
    // An append with other views: they are the ones read back.
    _ = try h.do(&m, .setCanvasUnits, .{.inch});
    h.views = "second";
    w = try prepareWrite(&h, gpa, test_writer, 2, .autosave, false);
    try testing.expect(w.at != null);
    try file.appendSlice(gpa, w.bytes);
    wrote(&h, &w);
    gpa.free(w.bytes);
    var o = try openFile(gpa, file.items);
    defer o.model.deinit();
    defer o.history.deinit();
    try testing.expectEqualStrings("second", o.views);
}

test "the actions added for making the examples in the GUI save and reopen" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    var h: History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    const p = try h.do(&m, .placePanel, .{.{ .name = "Panel 1", .space = m.spaces.items[0].id, .origin = .{ .x = 0, .y = 0 }, .w = 50, .h = 30 }});
    try h.do(&m, .renamePanel, .{ p, "Plate" });
    try h.do(&m, .setPanelSize, .{ p, 128, 62 });
    const st = try h.do(&m, .addStyle, .{ "s", model.StyleSize{} });
    try h.do(&m, .setLinePitch, .{ st, @as(?f64, 1.5) });
    const key = try h.do(&m, .addPrototype, .{model.TilePrototype{ .name = "key", .unit = 19.05 }});
    const r = try h.do(&m, .addTracks, .{ .{ .panel = p }, Model.Tracks{ .name = "Tracks 1", .origin = .{ .x = 5, .y = 25 }, .prototype = key, .count = 1, .length = 4, .pitch = 19.05 } });
    try h.do(&m, .renameRegion, .{ .{ .panel = p }, r, "keys" });
    try h.do(&m, .moveRegion, .{ .{ .panel = p }, r, .{ .x = 10, .y = 20 } });
    try h.do(&m, .setRegionSize, .{ .{ .panel = p }, r, 4, 1 });
    _ = try h.do(&m, .insertTile, .{ .{ .panel = p }, r, 0, key, 1 });
    _ = try h.do(&m, .insertTile, .{ .{ .panel = p }, r, 1, key, 1 });
    try h.do(&m, .setItemGap, .{ .{ .panel = p }, r, 1, 0.25 });
    _ = try h.do(&m, .nameKeysInOrder, .{ .{ .panel = p }, r, "K" });
    try h.do(&m, .setPanelFab, .{ p, model.Fab{ .thickness = 2, .layers = &.{.{ .name = "Base", .source = .edge, .op = .{ .add = .{ .name = "black", .color = .hex("#1e1e1e") } } }} } });
    const bytes = try fileBytes(&h, gpa, test_writer, 1);
    defer gpa.free(bytes);
    var o = try openFile(gpa, bytes);
    defer o.model.deinit();
    defer o.history.deinit();
    try testing.expect(!o.damaged);
    try testing.expectEqualStrings("Plate", o.model.panels.items[p].name);
    try testing.expectEqualStrings("K2", o.model.tileConst(o.model.flowItems(.{ .panel = p }, r)[1].tileOf().?).designator);
}

test "materials, plans and the active plan: saved with their steps, reopened, undone" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    var h: History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    const p = try h.do(&m, .placePanel, .{.{ .name = "Plate", .space = m.spaces.items[0].id, .origin = .{ .x = 0, .y = 0 }, .w = 50, .h = 30 }});
    const pid = m.panels.items[p].id;
    try h.do(&m, .setPanelFab, .{ p, model.Fab{ .thickness = 2, .layers = &.{ .{ .name = "Plate", .source = .edge, .op = .{ .add = .{ .name = "black", .color = .hex("#1e1e1e") } } }, .{ .name = "Legends", .source = .{ .text = "" }, .depth = 0.1, .op = .subtract } } } });
    const mat = try h.do(&m, .addMaterial, .{model.manufacture.libraryMaterial("Aluminium 5052, black anodised").?});
    const jet = try h.do(&m, .addProcess, .{model.process.builtin("Generic waterjet").?});
    const eng = try h.do(&m, .addProcess, .{model.process.builtin("Generic laser engraver").?});
    const plan = try h.do(&m, .addPlan, .{model.manufacture.Plan{
        .name = "Production",
        .parts = &.{.{ .panel = pid, .material = mat }},
        .operations = &.{
            .{ .name = "Engrave", .process = eng, .targets = &.{.{ .panel = pid, .layer = "Legends", .colour = .{ .name = "bare aluminium", .color = .hex("#c8ccd0") } }} },
            .{ .name = "Cut", .process = jet, .targets = &.{.{ .panel = pid, .layer = "Plate" }} },
        },
    }});
    const second = try h.do(&m, .addPlan, .{model.manufacture.Plan{ .name = "Prototype" }});
    try h.do(&m, .setActivePlan, .{second});
    const bytes = try fileBytes(&h, gpa, test_writer, 1);
    defer gpa.free(bytes);
    var o = try openFile(gpa, bytes);
    defer o.model.deinit();
    defer o.history.deinit();
    try testing.expect(!o.damaged);
    try testing.expectEqual(2, o.model.plans.items.len);
    try testing.expectEqual(second, o.model.active_plan);
    const back = o.model.plans.items[o.model.planIndex(plan).?];
    try testing.expectEqualStrings("Engrave", back.operations[0].name);
    try testing.expectEqualStrings("bare aluminium", back.operations[0].targets[0].colour.?.name);
    // Undone: the first plan active again, then the second gone.
    _ = try o.history.undo(&o.model);
    try testing.expectEqual(plan, o.model.active_plan);
    _ = try o.history.undo(&o.model);
    try testing.expectEqual(1, o.model.plans.items.len);
}

test "a sketch's Update is one step: undone, the draft is pending again, its ink with it" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    var h: History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    const si = try h.do(&m, .addSketch, .{ 0, "Sketch 1", .{ .x = 0, .y = 0 } });
    const seg = try h.do(&m, .editSketchDraft, .{ si, .{ .segment = .{ .a = .{ .x = 0, .y = 0 }, .b = .{ .x = 9, .y = 0 } } } });
    try h.do(&m, .setInkDraft, .{ si, seg, true });
    try h.do(&m, .acceptSketch, .{si});
    const fi = m.sketchFigure(m.sketches.items[si].id).?;
    try testing.expectEqual(1, m.figures.items[fi].inks.len);
    try testing.expect(m.sketches.items[si].accepted == null);
    try testing.expect(try h.undo(&m));
    try testing.expect(m.sketches.items[si].accepted != null);
    try testing.expectEqual(0, m.figures.items[fi].inks.len);
    try testing.expectEqual(1, m.figures.items[fi].pending.?.inks.len);
    // Saved mid-draft and read back: the draft and the accepted sketch both kept.
    const bytes = try native.encode(gpa, &m);
    defer gpa.free(bytes);
    var back = try native.decode(gpa, bytes);
    defer back.deinit();
    try testing.expect(back.sketches.items[si].accepted != null);
    try testing.expectEqual(1, back.figures.items[fi].pending.?.inks.len);
}

test "ink on a piece between crossings: a point made where they cross; undone, gone; saved, kept" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    var h: History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    const si = try h.do(&m, .addSketch, .{ 0, "Sketch 1", .{ .x = 0, .y = 0 } });
    const seg = try h.do(&m, .editSketchDraft, .{ si, .{ .segment = .{ .a = .{ .x = 0, .y = 0 }, .b = .{ .x = 10, .y = 0 } } } });
    _ = try h.do(&m, .editSketchDraft, .{ si, .{ .segment = .{ .a = .{ .x = 4, .y = -5 }, .b = .{ .x = 4, .y = 5 }, .construction = true } } });
    const pieces = model.sketch_.pieces;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const f = try pieces.pieceAt(&m.sketches.items[si].sketch, arena.allocator(), seg, .{ .x = 8, .y = 0 });
    const n = m.sketches.items[si].sketch.geometry.items.len;
    try h.do(&m, .inkPiecesDraft, .{ si, &[_]pieces.Found{f}, true });
    try testing.expectEqual(n + 1, m.sketches.items[si].sketch.geometry.items.len);
    try testing.expect(m.pieceInked(si, f));
    const fi = m.sketchFigure(m.sketches.items[si].id).?;
    try testing.expectEqual(1, m.figures.items[fi].pending.?.inks.len);
    try testing.expect(m.figures.items[fi].pending.?.inks[0].from != null);
    // Saved and read back.
    const bytes = try native.encode(gpa, &m);
    defer gpa.free(bytes);
    var back = try native.decode(gpa, bytes);
    defer back.deinit();
    try testing.expect(back.figures.items[fi].pending.?.inks[0].from != null);
    try testing.expect(try h.undo(&m));
    try testing.expectEqual(n, m.sketches.items[si].sketch.geometry.items.len);
    try testing.expect(!m.pieceInked(si, f));
}

test "an array grid shaped by typing replays the same" {
    const gpa = testing.allocator;
    var m: Model = .init(gpa);
    defer m.deinit();
    _ = try m.startCanvas(.mm);
    const c = try m.addPanel("Panel", 128, 62);
    var h: History = .init(gpa);
    defer h.deinit();
    try h.reset(&m);
    const P = @import("model.zig").Parent;
    const gi = try h.do(&m, .addArray, .{ P{ .panel = c }, @import("graven_geom").Point{ .x = 15, .y = 55 }, false, @as(u32, 10), @as(u32, 4), @import("graven_geom").Point{ .x = 100, .y = 40 }, @as(f64, 0) });
    var sh = m.gridShape(.{ .panel = c }, gi);
    sh.pitch_x = 11.43;
    try h.do(&m, .setGridShape, .{ P{ .panel = c }, gi, sh, .remove });
    try testing.expectApproxEqAbs(11.43, m.gridShape(.{ .panel = c }, gi).pitch_x, 1e-9);
    try h.rebuild(&m);
    try testing.expectApproxEqAbs(11.43, m.gridShape(.{ .panel = c }, gi).pitch_x, 1e-9);
}
