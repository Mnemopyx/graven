//! Reflow across panels, on a thread of its own, in batches.
//!
//! An edit reflows every panel at once, each with where threads entered it
//! last time (`entries`), so editing stays immediate. Where that moved
//! where a thread goes on into another panel, the panels downstream are
//! behind: the GUI submits a batch, a snapshot of the document as it is
//! then, and the worker works out where every thread now enters each
//! panel (`layout.place.handoffs`). A batch is never abandoned: what is
//! submitted while one runs waits as the next batch, a later submission
//! replacing an earlier one, so a burst of edits becomes a few batches.
//! When one completes, the GUI takes its handoffs and reflows the panels
//! with them.
//!
//! The worker has its own faces (a face's outline cache is not shared
//! safely) and its own copy of the document, so nothing it reads changes
//! under it.

const std = @import("std");
const layout = @import("graven_layout");
const engine = @import("graven_engine");

const Handoff = layout.place.Handoff;

/// A batch: the document as it was (encoded), its revision, faces for it,
/// and the handoffs known before (a first guess). Owned by the worker once
/// submitted.
pub const Job = struct {
    rev: u64,
    /// Which document it is of (the GUI counts them).
    generation: u64,
    doc: []u8,
    faces: []*engine.Face,
    start: []Handoff,

    fn deinit(j: *Job, gpa: std.mem.Allocator) void {
        gpa.free(j.doc);
        for (j.faces) |f| f.deinit();
        gpa.free(j.faces);
        gpa.free(j.start);
    }
};

/// A completed batch: where threads enter each panel, as of revision `rev`.
pub const Result = struct {
    rev: u64,
    generation: u64,
    entries: []Handoff,
};

pub const Worker = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    wake: *const fn () void,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    /// The next batch, collected while one runs.
    pending: ?Job = null,
    running: bool = false,
    result: ?Result = null,

    /// Hands the worker a batch; it runs after the one running, if any,
    /// replacing one already waiting.
    pub fn submit(w: *Worker, job: Job) void {
        w.mutex.lockUncancelable(w.io);
        defer w.mutex.unlock(w.io);
        if (w.pending) |*old| old.deinit(w.gpa);
        w.pending = job;
        if (w.thread == null) {
            w.thread = std.Thread.spawn(.{}, loop, .{w}) catch null;
            if (w.thread) |t| t.detach();
        }
        w.cond.signal(w.io);
    }

    /// A completed batch's handoffs, once (the caller owns them).
    pub fn take(w: *Worker) ?Result {
        w.mutex.lockUncancelable(w.io);
        defer w.mutex.unlock(w.io);
        const r = w.result;
        w.result = null;
        return r;
    }

    /// Whether a batch is running or waiting.
    pub fn busy(w: *Worker) bool {
        w.mutex.lockUncancelable(w.io);
        defer w.mutex.unlock(w.io);
        return w.running or w.pending != null;
    }

    fn loop(w: *Worker) void {
        while (true) {
            w.mutex.lockUncancelable(w.io);
            while (w.pending == null) w.cond.waitUncancelable(w.io, &w.mutex);
            var job = w.pending.?;
            w.pending = null;
            w.running = true;
            w.mutex.unlock(w.io);

            const entries = run(w.gpa, &job) catch null;
            const rev = job.rev;
            const generation = job.generation;
            job.deinit(w.gpa);

            w.mutex.lockUncancelable(w.io);
            w.running = false;
            if (entries) |e| {
                if (w.result) |old| w.gpa.free(old.entries);
                w.result = .{ .rev = rev, .generation = generation, .entries = e };
            }
            w.mutex.unlock(w.io);
            w.wake();
        }
    }

    fn run(gpa: std.mem.Allocator, job: *const Job) ![]Handoff {
        var m = try layout.native.decode(gpa, job.doc);
        defer m.deinit();
        var labels: layout.Labels = .init(gpa, job.faces);
        defer labels.deinit();
        return layout.place.handoffs(gpa, &m, &labels, job.start);
    }
};
