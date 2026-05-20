//! MemoryCronBackend — CronBackend vtable implementation backed by CronScheduler.
//!
//! All state is in-process (ArrayList). No SQLite dependency.
//! Thread-safe via an internal Mutex.
//!
//! Intended for:
//! - Tests that don't need persistence
//! - Environments without SQLite (build_options.enable_sqlite = false)
//! - Embedded use where a filesystem is unavailable
//!
//! Ownership:
//! - Caller owns the MemoryCronBackend struct (heap or stack).
//! - Call backend.deinit() exactly once when done.
//! - All returned data is allocated into the caller-supplied allocator.
const std = @import("std");
const std_compat = @import("compat");

const root = @import("root.zig");
const types = @import("types.zig");
const cron = @import("../cron.zig");

// ── Queue entry ──────────────────────────────────────────────────────────────

const QueueEntry = struct {
    id: i64, // synthetic row id
    job_id: []const u8, // owned by this entry
    status: enum { pending, in_progress },
    enqueued_at: i64,
};

// ── MemoryCronBackend ────────────────────────────────────────────────────────

pub const MemoryCronBackend = struct {
    mu: std_compat.sync.Mutex = .{},
    sched: cron.CronScheduler,
    queue: std.ArrayListUnmanaged(QueueEntry) = .empty,
    next_queue_id: i64 = 1,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MemoryCronBackend {
        return .{
            .sched = cron.CronScheduler.init(allocator, 1024, true),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MemoryCronBackend) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.queue.items) |entry| self.allocator.free(entry.job_id);
        self.queue.deinit(self.allocator);
        self.sched.deinit();
    }

    // ── VTable implementations ───────────────────────────────────────────────

    fn vtableDeinit(ptr: *anyopaque) void {
        const self: *MemoryCronBackend = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn vtableTick(ptr: *anyopaque, now: i64) anyerror!usize {
        const self: *MemoryCronBackend = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();

        var enqueued: usize = 0;
        for (self.sched.jobs.items) |*job| {
            if (!job.enabled or job.paused) continue;
            if (job.next_run_secs > now) continue;

            // Enqueue.
            const job_id_copy = try self.allocator.dupe(u8, job.id);
            errdefer self.allocator.free(job_id_copy);
            try self.queue.append(self.allocator, .{
                .id = self.next_queue_id,
                .job_id = job_id_copy,
                .status = .pending,
                .enqueued_at = now,
            });
            self.next_queue_id += 1;
            enqueued += 1;

            // Advance next_run or pause one-shot.
            if (job.one_shot) {
                job.next_run_secs = 0;
                job.paused = true;
            } else {
                job.next_run_secs = cron.nextRunForCronExpressionTz(job.expression, now, job.tz_offset_s) catch now + 60;
            }
        }
        return enqueued;
    }

    fn vtableAdd(ptr: *anyopaque, allocator: std.mem.Allocator, spec: types.NewJobSpec) anyerror!types.CronJob {
        const self: *MemoryCronBackend = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();

        const job_ptr = try self.sched.addJob(spec.expression, spec.command);
        job_ptr.job_type = @enumFromInt(@intFromEnum(spec.job_type));
        job_ptr.session_target = @enumFromInt(@intFromEnum(spec.session_target));
        job_ptr.one_shot = spec.one_shot;
        job_ptr.delete_after_run = spec.delete_after_run;
        job_ptr.enabled = spec.enabled;
        job_ptr.timeout_secs = spec.timeout_secs;
        if (spec.prompt) |p| job_ptr.prompt = try self.allocator.dupe(u8, p);
        if (spec.name) |n| job_ptr.name = try self.allocator.dupe(u8, n);
        if (spec.model) |m| job_ptr.model = try self.allocator.dupe(u8, m);
        if (spec.skill_name) |sn| job_ptr.skill_name = try self.allocator.dupe(u8, sn);
        if (spec.skill_args) |sa| job_ptr.skill_args = try self.allocator.dupe(u8, sa);
        job_ptr.delivery = cron.DeliveryConfig{
            .mode = @enumFromInt(@intFromEnum(spec.delivery.mode)),
            .channel = if (spec.delivery.channel) |ch| try self.allocator.dupe(u8, ch) else null,
            .account_id = if (spec.delivery.account_id) |aid| try self.allocator.dupe(u8, aid) else null,
            .to = if (spec.delivery.to) |t| try self.allocator.dupe(u8, t) else null,
            .best_effort = spec.delivery.best_effort,
            .channel_owned = spec.delivery.channel != null,
            .account_id_owned = spec.delivery.account_id != null,
            .to_owned = spec.delivery.to != null,
        };
        if (spec.created_at_s != 0) job_ptr.created_at_s = spec.created_at_s;
        job_ptr.tz_offset_s = spec.tz_offset_s;

        return copyJobToTypes(allocator, job_ptr.*);
    }

    fn vtableRemove(ptr: *anyopaque, id: []const u8) anyerror!bool {
        const self: *MemoryCronBackend = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();
        return self.sched.removeJob(id);
    }

    fn vtablePause(ptr: *anyopaque, id: []const u8) anyerror!bool {
        const self: *MemoryCronBackend = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();
        return self.sched.pauseJob(id);
    }

    fn vtableResumeJob(ptr: *anyopaque, id: []const u8) anyerror!bool {
        const self: *MemoryCronBackend = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();
        return self.sched.resumeJob(id);
    }

    fn vtableUpdate(ptr: *anyopaque, id: []const u8, patch: types.CronJobPatch) anyerror!bool {
        const self: *MemoryCronBackend = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();
        const legacy_patch = cron.CronJobPatch{
            .expression = patch.expression,
            .command = patch.command,
            .prompt = patch.prompt,
            .name = patch.name,
            .enabled = patch.enabled,
            .model = patch.model,
            .skill_name = patch.skill_name,
            .skill_args = patch.skill_args,
            .delete_after_run = patch.delete_after_run,
            .delivery_channel = patch.delivery_channel,
            .delivery_to = patch.delivery_to,
            .delivery_mode = patch.delivery_mode,
            .delivery_account_id = patch.delivery_account_id,
            .timeout_secs = patch.timeout_secs,
            .next_run_secs = patch.next_run_secs,
            .tz_offset_s = patch.tz_offset_s,
            .session_target = if (patch.session_target) |st| @as(cron.SessionTarget, @enumFromInt(@intFromEnum(st))) else null,
        };
        return self.sched.updateJob(self.allocator, id, legacy_patch);
    }

    fn vtableGet(ptr: *anyopaque, allocator: std.mem.Allocator, id: []const u8) anyerror!?types.CronJob {
        const self: *MemoryCronBackend = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();
        const job = self.sched.getJob(id) orelse return null;
        return try copyJobToTypes(allocator, job.*);
    }

    fn vtableListRows(ptr: *anyopaque, allocator: std.mem.Allocator, visitor: root.CronBackend.RowVisitor) anyerror!void {
        const self: *MemoryCronBackend = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();
        for (self.sched.jobs.items) |*job| {
            const summary = types.CronJobSummary{
                .id = job.id,
                .expression = job.expression,
                .name = job.name,
                .job_type = @enumFromInt(@intFromEnum(job.job_type)),
                .next_run_secs = job.next_run_secs,
                .last_run_secs = job.last_run_secs,
                .last_status = job.last_status,
                .paused = job.paused,
                .enabled = job.enabled,
                .one_shot = job.one_shot,
                .delete_after_run = job.delete_after_run,
                .delivery_mode = @enumFromInt(@intFromEnum(job.delivery.mode)),
                .delivery_channel = job.delivery.channel,
                .delivery_to = job.delivery.to,
                .created_at_s = job.created_at_s,
                .timeout_secs = job.timeout_secs,
                .skill_name = job.skill_name,
                .skill_args = job.skill_args,
                .tz_offset_s = job.tz_offset_s,
            };
            _ = allocator; // visitor owns any copies it needs
            try visitor.visit(visitor.ptr, summary);
        }
    }

    fn vtableGetOutput(ptr: *anyopaque, allocator: std.mem.Allocator, id: []const u8) anyerror!?types.CronJobOutput {
        const self: *MemoryCronBackend = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();
        const job = self.sched.getJob(id) orelse return null;
        const status = try allocator.dupe(u8, job.last_status orelse "");
        const output = try allocator.dupe(u8, job.last_output orelse "");
        return types.CronJobOutput{
            .status = status,
            .output = output,
            .last_run_secs = job.last_run_secs,
        };
    }

    fn vtableEnqueue(ptr: *anyopaque, id: []const u8, now: i64) anyerror!void {
        const self: *MemoryCronBackend = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();
        const job_id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(job_id_copy);
        try self.queue.append(self.allocator, .{
            .id = self.next_queue_id,
            .job_id = job_id_copy,
            .status = .pending,
            .enqueued_at = now,
        });
        self.next_queue_id += 1;
    }

    fn vtableDequeue(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?types.DequeueResult {
        const self: *MemoryCronBackend = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();

        // Find oldest pending entry.
        var oldest_idx: ?usize = null;
        var oldest_at: i64 = std.math.maxInt(i64);
        for (self.queue.items, 0..) |entry, i| {
            if (entry.status == .pending and entry.enqueued_at < oldest_at) {
                oldest_at = entry.enqueued_at;
                oldest_idx = i;
            }
        }
        const idx = oldest_idx orelse return null;

        // Mark in_progress.
        self.queue.items[idx].status = .in_progress;
        const entry = self.queue.items[idx];

        // Load full spec from scheduler.
        const job = self.sched.getJob(entry.job_id) orelse return null;

        const spec = types.CronJobSpec{
            .id = try allocator.dupe(u8, job.id),
            .job_type = @enumFromInt(@intFromEnum(job.job_type)),
            .command = try allocator.dupe(u8, job.command),
            .prompt = if (job.prompt) |p| try allocator.dupe(u8, p) else null,
            .model = if (job.model) |m| try allocator.dupe(u8, m) else null,
            .skill_name = if (job.skill_name) |sn| try allocator.dupe(u8, sn) else null,
            .skill_args = if (job.skill_args) |sa| try allocator.dupe(u8, sa) else null,
            .one_shot = job.one_shot,
            .delete_after_run = job.delete_after_run,
            .timeout_secs = job.timeout_secs,
            .delivery = types.DeliveryConfig{
                .mode = @enumFromInt(@intFromEnum(job.delivery.mode)),
                .channel = if (job.delivery.channel) |ch| try allocator.dupe(u8, ch) else null,
                .account_id = if (job.delivery.account_id) |aid| try allocator.dupe(u8, aid) else null,
                .to = if (job.delivery.to) |t| try allocator.dupe(u8, t) else null,
                .best_effort = job.delivery.best_effort,
            },
            .session_target = @enumFromInt(@intFromEnum(job.session_target)),
        };

        return types.DequeueResult{
            .queue_row_id = entry.id,
            .spec = spec,
        };
    }

    fn vtableComplete(
        ptr: *anyopaque,
        id: []const u8,
        row_id: i64,
        now: i64,
        status: []const u8,
        output: ?[]const u8,
        delivered: bool,
    ) anyerror!void {
        _ = delivered;
        const self: *MemoryCronBackend = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();

        // Remove queue row.
        for (self.queue.items, 0..) |entry, i| {
            if (entry.id == row_id) {
                self.allocator.free(entry.job_id);
                _ = self.queue.orderedRemove(i);
                break;
            }
        }

        // Update or remove job.
        const job = self.sched.getMutableJob(id) orelse return;
        if (job.delete_after_run) {
            _ = self.sched.removeJob(id);
            return;
        }
        job.last_run_secs = now;
        const new_status = try self.allocator.dupe(u8, status);
        if (job.last_status) |old| self.allocator.free(old);
        job.last_status = new_status;
        if (output) |o| {
            const new_out = try self.allocator.dupe(u8, o);
            if (job.last_output) |old| self.allocator.free(old);
            job.last_output = new_out;
        }
    }

    fn vtableResetInProgress(ptr: *anyopaque) anyerror!void {
        const self: *MemoryCronBackend = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();
        for (self.queue.items) |*entry| {
            if (entry.status == .in_progress) entry.status = .pending;
        }
    }

    // ── Static vtable ────────────────────────────────────────────────────────

    pub const vtable = root.CronBackend.VTable{
        .deinit = vtableDeinit,
        .tick = vtableTick,
        .add = vtableAdd,
        .remove = vtableRemove,
        .pause = vtablePause,
        .resumeJob = vtableResumeJob,
        .update = vtableUpdate,
        .get = vtableGet,
        .listRows = vtableListRows,
        .getOutput = vtableGetOutput,
        .enqueue = vtableEnqueue,
        .dequeue = vtableDequeue,
        .complete = vtableComplete,
        .resetInProgress = vtableResetInProgress,
    };

    pub fn backend(self: *MemoryCronBackend) root.CronBackend {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Copy a cron.CronJob into a types.CronJob, allocating strings into `allocator`.
fn copyJobToTypes(allocator: std.mem.Allocator, job: cron.CronJob) !types.CronJob {
    return types.CronJob{
        .id = try allocator.dupe(u8, job.id),
        .expression = try allocator.dupe(u8, job.expression),
        .command = try allocator.dupe(u8, job.command),
        .prompt = if (job.prompt) |p| try allocator.dupe(u8, p) else null,
        .name = if (job.name) |n| try allocator.dupe(u8, n) else null,
        .model = if (job.model) |m| try allocator.dupe(u8, m) else null,
        .skill_name = if (job.skill_name) |sn| try allocator.dupe(u8, sn) else null,
        .skill_args = if (job.skill_args) |sa| try allocator.dupe(u8, sa) else null,
        .job_type = @enumFromInt(@intFromEnum(job.job_type)),
        .session_target = @enumFromInt(@intFromEnum(job.session_target)),
        .one_shot = job.one_shot,
        .delete_after_run = job.delete_after_run,
        .enabled = job.enabled,
        .paused = job.paused,
        .timeout_secs = job.timeout_secs,
        .delivery = types.DeliveryConfig{
            .mode = @enumFromInt(@intFromEnum(job.delivery.mode)),
            .channel = if (job.delivery.channel) |ch| try allocator.dupe(u8, ch) else null,
            .account_id = if (job.delivery.account_id) |aid| try allocator.dupe(u8, aid) else null,
            .to = if (job.delivery.to) |t| try allocator.dupe(u8, t) else null,
            .best_effort = job.delivery.best_effort,
            .channel_owned = false,
            .account_id_owned = false,
            .to_owned = false,
        },
        .next_run_secs = job.next_run_secs,
        .last_run_secs = job.last_run_secs,
        .last_status = if (job.last_status) |s| try allocator.dupe(u8, s) else null,
        .last_output = if (job.last_output) |o| try allocator.dupe(u8, o) else null,
        .last_stderr = if (job.last_stderr) |e| try allocator.dupe(u8, e) else null,
        .created_at_s = job.created_at_s,
        .tz_offset_s = job.tz_offset_s,
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "MemoryCronBackend add and get" {
    const allocator = std.testing.allocator;
    var mem_be = MemoryCronBackend.init(allocator);
    defer mem_be.deinit();
    const be = mem_be.backend();

    const job = try be.add(allocator, .{ .expression = "* * * * *", .command = "echo hi" });
    defer {
        allocator.free(job.id);
        allocator.free(job.expression);
        allocator.free(job.command);
    }

    const loaded = try be.get(allocator, job.id);
    defer if (loaded) |j| {
        allocator.free(j.id);
        allocator.free(j.expression);
        allocator.free(j.command);
    };
    try std.testing.expect(loaded != null);
    try std.testing.expectEqualStrings("echo hi", loaded.?.command);
}

test "MemoryCronBackend remove returns false for missing" {
    const allocator = std.testing.allocator;
    var mem_be = MemoryCronBackend.init(allocator);
    defer mem_be.deinit();
    const be = mem_be.backend();

    try std.testing.expect(!try be.remove("nonexistent"));
}

test "MemoryCronBackend pause and resumeJob" {
    const allocator = std.testing.allocator;
    var mem_be = MemoryCronBackend.init(allocator);
    defer mem_be.deinit();
    const be = mem_be.backend();

    const job = try be.add(allocator, .{ .expression = "* * * * *", .command = "echo" });
    defer {
        allocator.free(job.id);
        allocator.free(job.expression);
        allocator.free(job.command);
    }

    try std.testing.expect(try be.pause(job.id));
    const paused = (try be.get(allocator, job.id)).?;
    defer {
        allocator.free(paused.id);
        allocator.free(paused.expression);
        allocator.free(paused.command);
    }
    try std.testing.expect(paused.paused);

    try std.testing.expect(try be.resumeJob(job.id));
    const resumed = (try be.get(allocator, job.id)).?;
    defer {
        allocator.free(resumed.id);
        allocator.free(resumed.expression);
        allocator.free(resumed.command);
    }
    try std.testing.expect(!resumed.paused);
}

test "MemoryCronBackend enqueue and dequeue" {
    const allocator = std.testing.allocator;
    var mem_be = MemoryCronBackend.init(allocator);
    defer mem_be.deinit();
    const be = mem_be.backend();

    const job = try be.add(allocator, .{ .expression = "* * * * *", .command = "echo test" });
    defer {
        allocator.free(job.id);
        allocator.free(job.expression);
        allocator.free(job.command);
    }

    try be.enqueue(job.id, std_compat.time.timestamp());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const result = try be.dequeue(arena.allocator());
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(job.id, result.?.spec.id);

    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    try std.testing.expect(try be.dequeue(arena2.allocator()) == null);
}

test "MemoryCronBackend tick enqueues due jobs" {
    const allocator = std.testing.allocator;
    var mem_be = MemoryCronBackend.init(allocator);
    defer mem_be.deinit();
    const be = mem_be.backend();

    const job = try be.add(allocator, .{ .expression = "* * * * *", .command = "echo" });
    defer {
        allocator.free(job.id);
        allocator.free(job.expression);
        allocator.free(job.command);
    }
    _ = try be.update(job.id, .{ .next_run_secs = 1 });

    const enqueued = try be.tick(std_compat.time.timestamp());
    try std.testing.expect(enqueued >= 1);
}

test "MemoryCronBackend resetInProgress" {
    const allocator = std.testing.allocator;
    var mem_be = MemoryCronBackend.init(allocator);
    defer mem_be.deinit();
    const be = mem_be.backend();
    try be.resetInProgress();
}

test "MemoryCronBackend listRows visitor" {
    const allocator = std.testing.allocator;
    var mem_be = MemoryCronBackend.init(allocator);
    defer mem_be.deinit();
    const be = mem_be.backend();

    const j1 = try be.add(allocator, .{ .expression = "* * * * *", .command = "a" });
    defer {
        allocator.free(j1.id);
        allocator.free(j1.expression);
        allocator.free(j1.command);
    }
    const j2 = try be.add(allocator, .{ .expression = "* * * * *", .command = "b" });
    defer {
        allocator.free(j2.id);
        allocator.free(j2.expression);
        allocator.free(j2.command);
    }

    var count: usize = 0;
    const visitor = root.CronBackend.RowVisitor{
        .ptr = &count,
        .visit = struct {
            fn f(ptr: *anyopaque, _: types.CronJobSummary) anyerror!void {
                const c_ptr: *usize = @ptrCast(@alignCast(ptr));
                c_ptr.* += 1;
            }
        }.f,
    };
    try be.listRows(allocator, visitor);
    try std.testing.expectEqual(@as(usize, 2), count);
}
