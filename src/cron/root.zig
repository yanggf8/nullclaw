//! CronBackend vtable interface — the sole mutation boundary for all cron state.
//!
//! Follows the ptr+vtable pattern used by Channel (src/channels/root.zig),
//! Provider (src/providers/root.zig), and Memory (src/memory/root.zig).
//!
//! Ownership rules:
//! - Caller owns the concrete backend struct (heap or stack).
//! - CronBackend is a fat-pointer value type — copy freely, do not free.
//! - Call backend.deinit() exactly once when done.
//! - Methods that return data allocate into the caller-provided allocator.
//!   Caller is responsible for freeing returned slices/structs.
//! - CronJobSummary strings in listRows visitor are valid only during the call.
const std = @import("std");

pub const types = @import("types.zig");

// Re-export all domain types so callers can use @import("cron/root.zig").CronJob etc.
pub usingnamespace types;

pub const CronBackend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Free all resources owned by this backend. Always call on shutdown.
        deinit: *const fn (ptr: *anyopaque) void,

        /// Atomic tick: scan due jobs, insert cron_run_queue rows, update next_run_secs.
        /// Returns number of rows enqueued. Caller signals worker condvar if > 0.
        tick: *const fn (ptr: *anyopaque, now: i64) anyerror!usize,

        /// Add a new job. Returns an owned CronJob allocated into caller's allocator.
        add: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, spec: types.NewJobSpec) anyerror!types.CronJob,

        /// Remove a job by id. Returns false if not found.
        remove: *const fn (ptr: *anyopaque, id: []const u8) anyerror!bool,

        /// Pause a job. Returns false if not found.
        pause: *const fn (ptr: *anyopaque, id: []const u8) anyerror!bool,

        /// Resume a paused job. Returns false if not found.
        resumeJob: *const fn (ptr: *anyopaque, id: []const u8) anyerror!bool,

        /// Apply a patch to an existing job. Returns false if not found.
        update: *const fn (ptr: *anyopaque, id: []const u8, patch: types.CronJobPatch) anyerror!bool,

        /// Load a single job by id. Returns null if not found.
        /// Returned CronJob is allocated into caller's allocator.
        get: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, id: []const u8) anyerror!?types.CronJob,

        /// Stream job summaries to a visitor. Low-allocation — no intermediate []CronJob.
        /// Visitor.visit() is called once per job; summary strings are temporary (stack/stmt).
        listRows: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, visitor: RowVisitor) anyerror!void,

        /// Load raw output for a job. Returns null if not found or no output recorded yet.
        /// Caller owns returned CronJobOutput fields via the provided allocator.
        getOutput: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, id: []const u8) anyerror!?types.CronJobOutput,

        /// Insert a job into the run queue. Atomic INSERT.
        enqueue: *const fn (ptr: *anyopaque, id: []const u8, now: i64) anyerror!void,

        /// Atomically claim the oldest pending queue row AND snapshot the full job spec.
        /// Single transaction: claim + load. Returns null if queue is empty.
        /// All strings in DequeueResult are allocated into the provided allocator.
        dequeue: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?types.DequeueResult,

        /// Write completion back: update last_run_secs/status/output in cron_jobs,
        /// delete the queue row (or delete the job if delete_after_run). Single transaction.
        complete: *const fn (
            ptr: *anyopaque,
            id: []const u8,
            row_id: i64,
            now: i64,
            status: []const u8,
            output: ?[]const u8,
            delivered: bool,
        ) anyerror!void,

        /// Reset any rows stuck in 'in_progress' status (process crash recovery).
        resetInProgress: *const fn (ptr: *anyopaque) anyerror!void,
    };

    /// Visitor passed to listRows. visit() receives a summary valid only during the call.
    /// Strings in CronJobSummary point into statement memory — do not store without copying.
    pub const RowVisitor = struct {
        ptr: *anyopaque,
        visit: *const fn (ptr: *anyopaque, row: types.CronJobSummary) anyerror!void,
    };

    // ── Forwarding methods ───────────────────────────────────────────────────

    pub fn deinit(self: CronBackend) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn tick(self: CronBackend, now: i64) !usize {
        return self.vtable.tick(self.ptr, now);
    }

    pub fn add(self: CronBackend, allocator: std.mem.Allocator, spec: types.NewJobSpec) !types.CronJob {
        return self.vtable.add(self.ptr, allocator, spec);
    }

    pub fn remove(self: CronBackend, id: []const u8) !bool {
        return self.vtable.remove(self.ptr, id);
    }

    pub fn pause(self: CronBackend, id: []const u8) !bool {
        return self.vtable.pause(self.ptr, id);
    }

    pub fn resumeJob(self: CronBackend, id: []const u8) !bool {
        return self.vtable.resumeJob(self.ptr, id);
    }

    pub fn update(self: CronBackend, id: []const u8, patch: types.CronJobPatch) !bool {
        return self.vtable.update(self.ptr, id, patch);
    }

    pub fn get(self: CronBackend, allocator: std.mem.Allocator, id: []const u8) !?types.CronJob {
        return self.vtable.get(self.ptr, allocator, id);
    }

    pub fn listRows(self: CronBackend, allocator: std.mem.Allocator, visitor: RowVisitor) !void {
        return self.vtable.listRows(self.ptr, allocator, visitor);
    }

    pub fn getOutput(self: CronBackend, allocator: std.mem.Allocator, id: []const u8) !?types.CronJobOutput {
        return self.vtable.getOutput(self.ptr, allocator, id);
    }

    pub fn enqueue(self: CronBackend, id: []const u8, now: i64) !void {
        return self.vtable.enqueue(self.ptr, id, now);
    }

    pub fn dequeue(self: CronBackend, allocator: std.mem.Allocator) !?types.DequeueResult {
        return self.vtable.dequeue(self.ptr, allocator);
    }

    pub fn complete(
        self: CronBackend,
        id: []const u8,
        row_id: i64,
        now: i64,
        status: []const u8,
        output: ?[]const u8,
        delivered: bool,
    ) !void {
        return self.vtable.complete(self.ptr, id, row_id, now, status, output, delivered);
    }

    pub fn resetInProgress(self: CronBackend) !void {
        return self.vtable.resetInProgress(self.ptr);
    }
};

test "CronBackend.VTable fields are complete" {
    // Compile-time verification that all forwarding methods match the VTable shape.
    // Catches method/signature drift at compile time.
    const vt: CronBackend.VTable = undefined;
    _ = vt.deinit;
    _ = vt.tick;
    _ = vt.add;
    _ = vt.remove;
    _ = vt.pause;
    _ = vt.resumeJob;
    _ = vt.update;
    _ = vt.get;
    _ = vt.listRows;
    _ = vt.getOutput;
    _ = vt.enqueue;
    _ = vt.dequeue;
    _ = vt.complete;
    _ = vt.resetInProgress;
}
