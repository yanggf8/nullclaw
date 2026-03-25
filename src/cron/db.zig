//! DbCronBackend — CronBackend vtable implementation backed by SQLite.
//!
//! Each vtable method opens its own DB connection (WAL mode, 5 s busy timeout)
//! so it is safe to call from any thread without external locking.
//!
//! Ownership:
//! - Caller owns the DbCronBackend struct (heap or stack).
//! - Call backend.deinit() exactly once when done.
//! - All returned data (CronJob, CronJobOutput, DequeueResult) is allocated
//!   into the caller-supplied allocator. Caller frees.
const std = @import("std");
const build_options = @import("build_options");

const root = @import("root.zig");
const types = @import("types.zig");
const cron = @import("../cron.zig");

const sqlite_mod = if (build_options.enable_sqlite)
    @import("../memory/engines/sqlite.zig")
else
    @import("../memory/engines/sqlite_disabled.zig");
const c = sqlite_mod.c;
const SQLITE_STATIC = sqlite_mod.SQLITE_STATIC;

// ── Local SQLite helpers (duplicated from cron.zig; keep in sync) ───────────

fn colTextOpt(stmt: ?*c.sqlite3_stmt, col: c_int, allocator: std.mem.Allocator) !?[]const u8 {
    if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) return null;
    const raw = c.sqlite3_column_text(stmt, col);
    if (raw == null or raw[0] == 0) return null;
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    if (len == 0) return null;
    return try allocator.dupe(u8, raw[0..len]);
}

fn colText(stmt: ?*c.sqlite3_stmt, col: c_int, allocator: std.mem.Allocator) ![]const u8 {
    const raw = c.sqlite3_column_text(stmt, col);
    if (raw == null) return error.NullColumn;
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    if (len == 0) return error.EmptyColumn;
    return try allocator.dupe(u8, raw[0..len]);
}

// ── DbCronBackend ────────────────────────────────────────────────────────────

pub const DbCronBackend = struct {
    db_path: [:0]u8, // owned, freed in deinit
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, db_path: [:0]const u8) !DbCronBackend {
        return .{
            .db_path = try allocator.dupeZ(u8, db_path),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DbCronBackend) void {
        self.allocator.free(self.db_path);
    }

    /// Open the DB, ensure the cron schema exists, return handle.
    /// Caller must call cron.closeCronDb on the returned handle.
    fn openDb(self: *const DbCronBackend) !*c.sqlite3 {
        if (!build_options.enable_sqlite) return error.SqliteDisabled;
        const db = try cron.openCronDbAtPath(self.db_path);
        try cron.ensureCronTable(db);
        return db;
    }

    // ── VTable function implementations ─────────────────────────────────────

    fn vtableDeinit(ptr: *anyopaque) void {
        const self: *DbCronBackend = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn vtableTick(ptr: *anyopaque, now: i64) anyerror!usize {
        const self: *DbCronBackend = @ptrCast(@alignCast(ptr));
        return cron.dbTickAndEnqueue(self.db_path, self.allocator, now);
    }

    fn vtableAdd(ptr: *anyopaque, allocator: std.mem.Allocator, spec: types.NewJobSpec) anyerror!types.CronJob {
        const self: *DbCronBackend = @ptrCast(@alignCast(ptr));
        const db = try self.openDb();
        defer cron.closeCronDb(db);

        // Generate a random UUID-style hex ID (same format as CronScheduler.allocateJobId).
        var raw_id: [16]u8 = undefined;
        std.crypto.random.bytes(&raw_id);
        raw_id[6] = (raw_id[6] & 0x0f) | 0x40; // version 4
        raw_id[8] = (raw_id[8] & 0x3f) | 0x80; // variant
        var id_buf: [80]u8 = undefined;
        const id_hex = std.fmt.bufPrint(&id_buf, "job-{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}", .{
            std.mem.readInt(u32, raw_id[0..4], .big),
            std.mem.readInt(u16, raw_id[4..6], .big),
            std.mem.readInt(u16, raw_id[6..8], .big),
            std.mem.readInt(u16, raw_id[8..10], .big),
            std.mem.readInt(u48, raw_id[10..16], .big),
        }) catch unreachable;
        const id = try allocator.dupe(u8, id_hex);
        errdefer allocator.free(id);

        const now = std.time.timestamp();
        const next_run = if (spec.next_run_secs_override != 0)
            spec.next_run_secs_override
        else
            cron.nextRunForCronExpression(spec.expression, now) catch now + 60;
        const created_at = if (spec.created_at_s != 0) spec.created_at_s else now;

        const job = types.CronJob{
            .id = id,
            .expression = try allocator.dupe(u8, spec.expression),
            .command = try allocator.dupe(u8, spec.command),
            .prompt = if (spec.prompt) |p| try allocator.dupe(u8, p) else null,
            .name = if (spec.name) |n| try allocator.dupe(u8, n) else null,
            .model = if (spec.model) |m| try allocator.dupe(u8, m) else null,
            .skill_name = if (spec.skill_name) |sn| try allocator.dupe(u8, sn) else null,
            .skill_args = if (spec.skill_args) |sa| try allocator.dupe(u8, sa) else null,
            .job_type = spec.job_type,
            .session_target = spec.session_target,
            .one_shot = spec.one_shot,
            .delete_after_run = spec.delete_after_run,
            .enabled = spec.enabled,
            .timeout_secs = spec.timeout_secs,
            .delivery = spec.delivery,
            .next_run_secs = next_run,
            .created_at_s = created_at,
        };

        // Convert types.CronJob -> cron.CronJob for dbSaveJob (same shape, different namespace).
        const legacy = cron.CronJob{
            .id = job.id,
            .expression = job.expression,
            .command = job.command,
            .prompt = job.prompt,
            .name = job.name,
            .model = job.model,
            .skill_name = job.skill_name,
            .skill_args = job.skill_args,
            .job_type = @enumFromInt(@intFromEnum(job.job_type)),
            .session_target = @enumFromInt(@intFromEnum(job.session_target)),
            .one_shot = job.one_shot,
            .delete_after_run = job.delete_after_run,
            .enabled = job.enabled,
            .timeout_secs = job.timeout_secs,
            .delivery = legacyDelivery(job.delivery),
            .next_run_secs = job.next_run_secs,
            .created_at_s = job.created_at_s,
        };
        try dbSaveJobDirect(db, &legacy);
        return job;
    }

    fn vtableRemove(ptr: *anyopaque, id: []const u8) anyerror!bool {
        const self: *DbCronBackend = @ptrCast(@alignCast(ptr));
        const db = try self.openDb();
        defer cron.closeCronDb(db);
        if (c.sqlite3_exec(db, "BEGIN IMMEDIATE", null, null, null) != c.SQLITE_OK) {
            return error.TransactionBeginFailed;
        }
        var tx_open = true;
        errdefer {
            if (tx_open) _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);
        }
        // Delete pending/in_progress queue rows first so the worker never
        // dequeues a job_id that no longer has a cron_jobs row.
        const del_queue_sql = "DELETE FROM cron_run_queue WHERE job_id=?1";
        var qstmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, del_queue_sql, -1, &qstmt, null) == c.SQLITE_OK) {
            _ = c.sqlite3_bind_text(qstmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);
            _ = c.sqlite3_step(qstmt);
            _ = c.sqlite3_finalize(qstmt);
        }
        const removed = try dbSetField(db, id, null, null, null);
        if (c.sqlite3_exec(db, "COMMIT", null, null, null) != c.SQLITE_OK) {
            return error.TransactionCommitFailed;
        }
        tx_open = false;
        return removed;
    }

    fn vtablePause(ptr: *anyopaque, id: []const u8) anyerror!bool {
        const self: *DbCronBackend = @ptrCast(@alignCast(ptr));
        const db = try self.openDb();
        defer cron.closeCronDb(db);
        if (!try dbJobExistsDirect(db, id)) return false;
        const sql = "UPDATE cron_jobs SET paused=1 WHERE id=?1";
        return dbExecOneId(db, sql, id);
    }

    fn vtableResumeJob(ptr: *anyopaque, id: []const u8) anyerror!bool {
        const self: *DbCronBackend = @ptrCast(@alignCast(ptr));
        const db = try self.openDb();
        defer cron.closeCronDb(db);
        if (!try dbJobExistsDirect(db, id)) return false;
        const sql = "UPDATE cron_jobs SET paused=0 WHERE id=?1";
        return dbExecOneId(db, sql, id);
    }

    fn vtableUpdate(ptr: *anyopaque, id: []const u8, patch: types.CronJobPatch) anyerror!bool {
        const self: *DbCronBackend = @ptrCast(@alignCast(ptr));
        const db = try self.openDb();
        defer cron.closeCronDb(db);
        if (!try dbJobExistsDirect(db, id)) return false;
        try dbApplyPatch(db, id, patch);
        return true;
    }

    fn vtableGet(ptr: *anyopaque, allocator: std.mem.Allocator, id: []const u8) anyerror!?types.CronJob {
        const self: *DbCronBackend = @ptrCast(@alignCast(ptr));
        const db = try self.openDb();
        defer cron.closeCronDb(db);
        return dbLoadJobFull(db, allocator, id);
    }

    fn vtableListRows(ptr: *anyopaque, allocator: std.mem.Allocator, visitor: root.CronBackend.RowVisitor) anyerror!void {
        const self: *DbCronBackend = @ptrCast(@alignCast(ptr));
        const db = try self.openDb();
        defer cron.closeCronDb(db);
        try dbStreamSummaries(db, allocator, visitor);
    }

    fn vtableGetOutput(ptr: *anyopaque, allocator: std.mem.Allocator, id: []const u8) anyerror!?types.CronJobOutput {
        const self: *DbCronBackend = @ptrCast(@alignCast(ptr));
        const db = try self.openDb();
        defer cron.closeCronDb(db);
        return dbLoadOutput(db, allocator, id);
    }

    fn vtableEnqueue(ptr: *anyopaque, id: []const u8, now: i64) anyerror!void {
        const self: *DbCronBackend = @ptrCast(@alignCast(ptr));
        const db = try self.openDb();
        defer cron.closeCronDb(db);
        try cron.dbEnqueueJob(db, id, now);
    }

    fn vtableDequeue(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?types.DequeueResult {
        const self: *DbCronBackend = @ptrCast(@alignCast(ptr));
        const db = try self.openDb();
        defer cron.closeCronDb(db);
        return dbAtomicDequeue(db, allocator);
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
        const self: *DbCronBackend = @ptrCast(@alignCast(ptr));
        const db = try self.openDb();
        defer cron.closeCronDb(db);

        // We need delete_after_run to decide the completion path.
        // Load it cheaply from the DB.
        const dar = try dbGetDeleteAfterRun(db, id);
        try cron.dbCompleteJob(db, id, row_id, now, status, output, dar);
    }

    fn vtableResetInProgress(ptr: *anyopaque) anyerror!void {
        const self: *DbCronBackend = @ptrCast(@alignCast(ptr));
        const db = try self.openDb();
        defer cron.closeCronDb(db);
        try cron.dbResetInProgressJobs(db);
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

    /// Package this backend as a CronBackend fat pointer.
    pub fn backend(self: *DbCronBackend) root.CronBackend {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

// ── Private DB helpers ───────────────────────────────────────────────────────

/// Return true if a job with the given id exists.
fn dbJobExistsDirect(db: *c.sqlite3, id: []const u8) !bool {
    const sql = "SELECT 1 FROM cron_jobs WHERE id=?1 LIMIT 1";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

/// Execute a single-parameter UPDATE/DELETE returning true if ≥1 row was changed.
fn dbExecOneId(db: *c.sqlite3, sql: [*:0]const u8, id: []const u8) !bool {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.StepFailed;
    return c.sqlite3_changes(db) > 0;
}

/// DELETE a job — vtableRemove delegates here.
/// Returns false if no row was deleted (not found).
fn dbSetField(db: *c.sqlite3, id: []const u8, _: ?void, _: ?void, _: ?void) !bool {
    const sql = "DELETE FROM cron_jobs WHERE id=?1";
    return dbExecOneId(db, sql, id);
}

/// Fetch delete_after_run for a job (needed by vtableComplete).
fn dbGetDeleteAfterRun(db: *c.sqlite3, id: []const u8) !bool {
    const sql = "SELECT delete_after_run FROM cron_jobs WHERE id=?1 LIMIT 1";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return false;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return false;
    return c.sqlite3_column_int(stmt, 0) != 0;
}

/// Apply a CronJobPatch to an existing job row. Skips null fields.
fn dbApplyPatch(db: *c.sqlite3, id: []const u8, patch: types.CronJobPatch) !void {
    if (patch.expression) |expr| {
        const sql = "UPDATE cron_jobs SET expression=?1 WHERE id=?2";
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &s, null) == c.SQLITE_OK) {
            _ = c.sqlite3_bind_text(s, 1, expr.ptr, @intCast(expr.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_text(s, 2, id.ptr, @intCast(id.len), SQLITE_STATIC);
            _ = c.sqlite3_step(s);
            _ = c.sqlite3_finalize(s);
        }
    }
    if (patch.command) |cmd| {
        const sql = "UPDATE cron_jobs SET command=?1 WHERE id=?2";
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &s, null) == c.SQLITE_OK) {
            _ = c.sqlite3_bind_text(s, 1, cmd.ptr, @intCast(cmd.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_text(s, 2, id.ptr, @intCast(id.len), SQLITE_STATIC);
            _ = c.sqlite3_step(s);
            _ = c.sqlite3_finalize(s);
        }
    }
    if (patch.prompt) |p| {
        const sql = "UPDATE cron_jobs SET prompt=?1 WHERE id=?2";
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &s, null) == c.SQLITE_OK) {
            _ = c.sqlite3_bind_text(s, 1, p.ptr, @intCast(p.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_text(s, 2, id.ptr, @intCast(id.len), SQLITE_STATIC);
            _ = c.sqlite3_step(s);
            _ = c.sqlite3_finalize(s);
        }
    }
    if (patch.name) |n| {
        const sql = "UPDATE cron_jobs SET name=?1 WHERE id=?2";
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &s, null) == c.SQLITE_OK) {
            _ = c.sqlite3_bind_text(s, 1, n.ptr, @intCast(n.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_text(s, 2, id.ptr, @intCast(id.len), SQLITE_STATIC);
            _ = c.sqlite3_step(s);
            _ = c.sqlite3_finalize(s);
        }
    }
    if (patch.enabled) |en| {
        const sql = "UPDATE cron_jobs SET enabled=?1 WHERE id=?2";
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &s, null) == c.SQLITE_OK) {
            _ = c.sqlite3_bind_int(s, 1, if (en) 1 else 0);
            _ = c.sqlite3_bind_text(s, 2, id.ptr, @intCast(id.len), SQLITE_STATIC);
            _ = c.sqlite3_step(s);
            _ = c.sqlite3_finalize(s);
        }
    }
    if (patch.model) |m| {
        const sql = "UPDATE cron_jobs SET model=?1 WHERE id=?2";
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &s, null) == c.SQLITE_OK) {
            _ = c.sqlite3_bind_text(s, 1, m.ptr, @intCast(m.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_text(s, 2, id.ptr, @intCast(id.len), SQLITE_STATIC);
            _ = c.sqlite3_step(s);
            _ = c.sqlite3_finalize(s);
        }
    }
    if (patch.delete_after_run) |d| {
        const sql = "UPDATE cron_jobs SET delete_after_run=?1 WHERE id=?2";
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &s, null) == c.SQLITE_OK) {
            _ = c.sqlite3_bind_int(s, 1, if (d) 1 else 0);
            _ = c.sqlite3_bind_text(s, 2, id.ptr, @intCast(id.len), SQLITE_STATIC);
            _ = c.sqlite3_step(s);
            _ = c.sqlite3_finalize(s);
        }
    }
    if (patch.delivery_channel) |ch| {
        const sql = "UPDATE cron_jobs SET delivery_channel=?1 WHERE id=?2";
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &s, null) == c.SQLITE_OK) {
            _ = c.sqlite3_bind_text(s, 1, ch.ptr, @intCast(ch.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_text(s, 2, id.ptr, @intCast(id.len), SQLITE_STATIC);
            _ = c.sqlite3_step(s);
            _ = c.sqlite3_finalize(s);
        }
    }
    if (patch.delivery_to) |t| {
        const sql = "UPDATE cron_jobs SET delivery_to=?1 WHERE id=?2";
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &s, null) == c.SQLITE_OK) {
            _ = c.sqlite3_bind_text(s, 1, t.ptr, @intCast(t.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_text(s, 2, id.ptr, @intCast(id.len), SQLITE_STATIC);
            _ = c.sqlite3_step(s);
            _ = c.sqlite3_finalize(s);
        }
    }
    if (patch.delivery_mode) |dm| {
        const sql = "UPDATE cron_jobs SET delivery_mode=?1 WHERE id=?2";
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &s, null) == c.SQLITE_OK) {
            _ = c.sqlite3_bind_text(s, 1, dm.ptr, @intCast(dm.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_text(s, 2, id.ptr, @intCast(id.len), SQLITE_STATIC);
            _ = c.sqlite3_step(s);
            _ = c.sqlite3_finalize(s);
        }
    }
    if (patch.delivery_account_id) |aid| {
        const sql = "UPDATE cron_jobs SET delivery_account_id=?1 WHERE id=?2";
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &s, null) == c.SQLITE_OK) {
            _ = c.sqlite3_bind_text(s, 1, aid.ptr, @intCast(aid.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_text(s, 2, id.ptr, @intCast(id.len), SQLITE_STATIC);
            _ = c.sqlite3_step(s);
            _ = c.sqlite3_finalize(s);
        }
    }
    if (patch.timeout_secs) |t| {
        const sql = "UPDATE cron_jobs SET timeout_secs=?1 WHERE id=?2";
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &s, null) == c.SQLITE_OK) {
            _ = c.sqlite3_bind_int(s, 1, @intCast(t));
            _ = c.sqlite3_bind_text(s, 2, id.ptr, @intCast(id.len), SQLITE_STATIC);
            _ = c.sqlite3_step(s);
            _ = c.sqlite3_finalize(s);
        }
    }
    if (patch.next_run_secs) |nrs| {
        const sql = "UPDATE cron_jobs SET next_run_secs=?1 WHERE id=?2";
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &s, null) == c.SQLITE_OK) {
            _ = c.sqlite3_bind_int64(s, 1, nrs);
            _ = c.sqlite3_bind_text(s, 2, id.ptr, @intCast(id.len), SQLITE_STATIC);
            _ = c.sqlite3_step(s);
            _ = c.sqlite3_finalize(s);
        }
    }
    if (patch.skill_name) |sn| {
        const sql = "UPDATE cron_jobs SET skill_name=?1 WHERE id=?2";
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &s, null) == c.SQLITE_OK) {
            _ = c.sqlite3_bind_text(s, 1, sn.ptr, @intCast(sn.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_text(s, 2, id.ptr, @intCast(id.len), SQLITE_STATIC);
            _ = c.sqlite3_step(s);
            _ = c.sqlite3_finalize(s);
        }
    }
    if (patch.skill_args) |sa| {
        const sql = "UPDATE cron_jobs SET skill_args=?1 WHERE id=?2";
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &s, null) == c.SQLITE_OK) {
            _ = c.sqlite3_bind_text(s, 1, sa.ptr, @intCast(sa.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_text(s, 2, id.ptr, @intCast(id.len), SQLITE_STATIC);
            _ = c.sqlite3_step(s);
            _ = c.sqlite3_finalize(s);
        }
    }
}

/// Load a full CronJob by ID (includes all columns + last_output).
/// Returns null if not found. All strings allocated into `allocator`.
fn dbLoadJobFull(db: *c.sqlite3, allocator: std.mem.Allocator, id: []const u8) !?types.CronJob {
    const sql =
        "SELECT id, expression, job_type, command, prompt, name, model, " ++
        "next_run_secs, last_run_secs, last_status, paused, one_shot, " ++
        "delete_after_run, enabled, delivery_mode, delivery_channel, " ++
        "delivery_account_id, delivery_to, created_at_s, last_output, timeout_secs, " ++
        "delivery_best_effort, session_target, skill_name, skill_args " ++
        "FROM cron_jobs WHERE id=?1";

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);

    const rc = c.sqlite3_step(stmt);
    if (rc == c.SQLITE_DONE) return null;
    if (rc != c.SQLITE_ROW) return error.StepFailed;

    const job_type_raw = try colTextOpt(stmt, 2, allocator);
    defer if (job_type_raw) |s| allocator.free(s);
    const dm_raw = try colTextOpt(stmt, 14, allocator);
    defer if (dm_raw) |s| allocator.free(s);
    const st_raw = try colTextOpt(stmt, 22, allocator);
    defer if (st_raw) |s| allocator.free(s);

    return types.CronJob{
        .id = try colText(stmt, 0, allocator),
        .expression = try colText(stmt, 1, allocator),
        .job_type = if (job_type_raw) |s| types.JobType.parse(s) else .shell,
        .command = (try colTextOpt(stmt, 3, allocator)) orelse try allocator.dupe(u8, ""),
        .prompt = try colTextOpt(stmt, 4, allocator),
        .name = try colTextOpt(stmt, 5, allocator),
        .model = try colTextOpt(stmt, 6, allocator),
        .next_run_secs = c.sqlite3_column_int64(stmt, 7),
        .last_run_secs = blk: {
            if (c.sqlite3_column_type(stmt, 8) == c.SQLITE_NULL) break :blk null;
            break :blk c.sqlite3_column_int64(stmt, 8);
        },
        .last_status = try colTextOpt(stmt, 9, allocator),
        .paused = c.sqlite3_column_int(stmt, 10) != 0,
        .one_shot = c.sqlite3_column_int(stmt, 11) != 0,
        .delete_after_run = c.sqlite3_column_int(stmt, 12) != 0,
        .enabled = c.sqlite3_column_int(stmt, 13) != 0,
        .delivery = .{
            .mode = if (dm_raw) |s| types.DeliveryMode.parse(s) else .none,
            .channel = try colTextOpt(stmt, 15, allocator),
            .account_id = try colTextOpt(stmt, 16, allocator),
            .to = try colTextOpt(stmt, 17, allocator),
            .best_effort = c.sqlite3_column_int(stmt, 21) != 0,
        },
        .created_at_s = c.sqlite3_column_int64(stmt, 18),
        .last_output = try colTextOpt(stmt, 19, allocator),
        .timeout_secs = blk: {
            if (c.sqlite3_column_type(stmt, 20) == c.SQLITE_NULL) break :blk null;
            const v = c.sqlite3_column_int(stmt, 20);
            if (v <= 0) break :blk null;
            break :blk @intCast(v);
        },
        .session_target = if (st_raw) |s| types.SessionTarget.parse(s) else .isolated,
        .skill_name = try colTextOpt(stmt, 23, allocator),
        .skill_args = try colTextOpt(stmt, 24, allocator),
    };
}

/// Stream CronJobSummary rows via visitor. Low-allocation — no last_output.
fn dbStreamSummaries(db: *c.sqlite3, allocator: std.mem.Allocator, visitor: root.CronBackend.RowVisitor) !void {
    const sql =
        "SELECT id, expression, name, job_type, next_run_secs, last_run_secs, last_status, " ++
        "paused, enabled, one_shot, delete_after_run, delivery_mode, delivery_channel, " ++
        "delivery_to, created_at_s, timeout_secs, skill_name, skill_args " ++
        "FROM cron_jobs ORDER BY rowid ASC";

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);

    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.StepFailed;

        // Build summary from statement memory — strings are only valid this iteration.
        const id_ptr = c.sqlite3_column_text(stmt, 0);
        const expr_ptr = c.sqlite3_column_text(stmt, 1);
        if (id_ptr == null or expr_ptr == null) continue;

        const id_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        const expr_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));

        var name_slice: ?[]const u8 = null;
        var name_buf: [256]u8 = undefined;
        if (c.sqlite3_column_type(stmt, 2) != c.SQLITE_NULL) {
            const np = c.sqlite3_column_text(stmt, 2);
            if (np != null) {
                const nlen: usize = @intCast(c.sqlite3_column_bytes(stmt, 2));
                const copy_len = @min(nlen, name_buf.len);
                @memcpy(name_buf[0..copy_len], np[0..copy_len]);
                name_slice = name_buf[0..copy_len];
            }
        }

        const jt_ptr = c.sqlite3_column_text(stmt, 3);
        const jt_raw = if (jt_ptr != null) blk: {
            const jl: usize = @intCast(c.sqlite3_column_bytes(stmt, 3));
            break :blk jt_ptr[0..jl];
        } else "";

        var dm_buf: [32]u8 = undefined;
        var dm_slice: []const u8 = "none";
        if (c.sqlite3_column_type(stmt, 11) != c.SQLITE_NULL) {
            const dp = c.sqlite3_column_text(stmt, 11);
            if (dp != null) {
                const dl: usize = @intCast(c.sqlite3_column_bytes(stmt, 11));
                const copy_len = @min(dl, dm_buf.len);
                @memcpy(dm_buf[0..copy_len], dp[0..copy_len]);
                dm_slice = dm_buf[0..copy_len];
            }
        }

        const ch_opt = try colTextOpt(stmt, 12, allocator);
        defer if (ch_opt) |s| allocator.free(s);
        const to_opt = try colTextOpt(stmt, 13, allocator);
        defer if (to_opt) |s| allocator.free(s);
        const ls_opt = try colTextOpt(stmt, 6, allocator);
        defer if (ls_opt) |s| allocator.free(s);
        const sn_opt = try colTextOpt(stmt, 16, allocator);
        defer if (sn_opt) |s| allocator.free(s);
        const sa_opt = try colTextOpt(stmt, 17, allocator);
        defer if (sa_opt) |s| allocator.free(s);

        const summary = types.CronJobSummary{
            .id = id_ptr[0..id_len],
            .expression = expr_ptr[0..expr_len],
            .name = name_slice,
            .job_type = types.JobType.parse(jt_raw),
            .next_run_secs = c.sqlite3_column_int64(stmt, 4),
            .last_run_secs = blk: {
                if (c.sqlite3_column_type(stmt, 5) == c.SQLITE_NULL) break :blk null;
                break :blk c.sqlite3_column_int64(stmt, 5);
            },
            .last_status = ls_opt,
            .paused = c.sqlite3_column_int(stmt, 7) != 0,
            .enabled = c.sqlite3_column_int(stmt, 8) != 0,
            .one_shot = c.sqlite3_column_int(stmt, 9) != 0,
            .delete_after_run = c.sqlite3_column_int(stmt, 10) != 0,
            .delivery_mode = types.DeliveryMode.parse(dm_slice),
            .delivery_channel = ch_opt,
            .delivery_to = to_opt,
            .created_at_s = c.sqlite3_column_int64(stmt, 14),
            .timeout_secs = blk: {
                if (c.sqlite3_column_type(stmt, 15) == c.SQLITE_NULL) break :blk null;
                const v = c.sqlite3_column_int(stmt, 15);
                if (v <= 0) break :blk null;
                break :blk @intCast(v);
            },
            .skill_name = sn_opt,
            .skill_args = sa_opt,
        };
        try visitor.visit(visitor.ptr, summary);
    }
}

/// Load last_status, last_output, last_run_secs for a job.
fn dbLoadOutput(db: *c.sqlite3, allocator: std.mem.Allocator, id: []const u8) !?types.CronJobOutput {
    const sql =
        "SELECT last_status, last_output, last_run_secs FROM cron_jobs WHERE id=?1";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);

    const rc = c.sqlite3_step(stmt);
    if (rc == c.SQLITE_DONE) return null;
    if (rc != c.SQLITE_ROW) return error.StepFailed;

    const status = (try colTextOpt(stmt, 0, allocator)) orelse try allocator.dupe(u8, "");
    const output = (try colTextOpt(stmt, 1, allocator)) orelse try allocator.dupe(u8, "");
    const last_run: ?i64 = if (c.sqlite3_column_type(stmt, 2) == c.SQLITE_NULL)
        null
    else
        c.sqlite3_column_int64(stmt, 2);

    return types.CronJobOutput{
        .status = status,
        .output = output,
        .last_run_secs = last_run,
    };
}

/// Atomically claim the oldest pending queue row AND load the full job spec.
/// Single BEGIN IMMEDIATE transaction — no claim/load race.
fn dbAtomicDequeue(db: *c.sqlite3, allocator: std.mem.Allocator) !?types.DequeueResult {
    _ = c.sqlite3_exec(db, "BEGIN IMMEDIATE", null, null, null);
    errdefer _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);

    // Find oldest pending row.
    const sel_sql =
        "SELECT id, job_id FROM cron_run_queue WHERE status='pending' " ++
        "ORDER BY enqueued_at ASC LIMIT 1";
    var sel: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sel_sql, -1, &sel, null) != c.SQLITE_OK) {
        _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(sel);

    const sel_rc = c.sqlite3_step(sel);
    if (sel_rc == c.SQLITE_DONE) {
        _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);
        return null;
    }
    if (sel_rc != c.SQLITE_ROW) {
        _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);
        return error.StepFailed;
    }

    const queue_row_id = c.sqlite3_column_int64(sel, 0);
    const job_id_raw = c.sqlite3_column_text(sel, 1);
    if (job_id_raw == null) {
        _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);
        return null;
    }
    const job_id_len: usize = @intCast(c.sqlite3_column_bytes(sel, 1));
    const job_id = try allocator.dupe(u8, job_id_raw[0..job_id_len]);
    errdefer allocator.free(job_id);

    // Mark in_progress.
    const upd_sql = "UPDATE cron_run_queue SET status='in_progress', started_at=?1 WHERE id=?2";
    var upd: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, upd_sql, -1, &upd, null) == c.SQLITE_OK) {
        _ = c.sqlite3_bind_int64(upd, 1, std.time.timestamp());
        _ = c.sqlite3_bind_int64(upd, 2, queue_row_id);
        _ = c.sqlite3_step(upd);
        _ = c.sqlite3_finalize(upd);
    }

    // Load full job spec within same transaction.
    const spec_opt = try cron.dbLoadJobSpec(db, allocator, job_id);
    allocator.free(job_id); // spec.id is already duped inside dbLoadJobSpec

    if (spec_opt == null) {
        _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);
        return null;
    }
    const legacy_spec = spec_opt.?;

    _ = c.sqlite3_exec(db, "COMMIT", null, null, null);

    // Convert cron.CronJobSpec -> types.CronJobSpec.
    return types.DequeueResult{
        .queue_row_id = queue_row_id,
        .spec = types.CronJobSpec{
            .id = legacy_spec.id,
            .job_type = @enumFromInt(@intFromEnum(legacy_spec.job_type)),
            .command = legacy_spec.command,
            .prompt = legacy_spec.prompt,
            .model = legacy_spec.model,
            .skill_name = legacy_spec.skill_name,
            .skill_args = legacy_spec.skill_args,
            .one_shot = legacy_spec.one_shot,
            .delete_after_run = legacy_spec.delete_after_run,
            .timeout_secs = legacy_spec.timeout_secs,
            .delivery = typesDelivery(legacy_spec.delivery),
            .session_target = @enumFromInt(@intFromEnum(legacy_spec.session_target)),
        },
    };
}

/// Convert cron.DeliveryConfig -> types.DeliveryConfig.
fn typesDelivery(d: cron.DeliveryConfig) types.DeliveryConfig {
    return .{
        .mode = @enumFromInt(@intFromEnum(d.mode)),
        .channel = d.channel,
        .account_id = d.account_id,
        .to = d.to,
        .best_effort = d.best_effort,
        .channel_owned = d.channel_owned,
        .account_id_owned = d.account_id_owned,
        .to_owned = d.to_owned,
    };
}

/// Convert types.DeliveryConfig -> cron.DeliveryConfig.
fn legacyDelivery(d: types.DeliveryConfig) cron.DeliveryConfig {
    return .{
        .mode = @enumFromInt(@intFromEnum(d.mode)),
        .channel = d.channel,
        .account_id = d.account_id,
        .to = d.to,
        .best_effort = d.best_effort,
        .channel_owned = d.channel_owned,
        .account_id_owned = d.account_id_owned,
        .to_owned = d.to_owned,
    };
}

/// Write a CronJob directly via SQL (bypasses cron.dbSaveJob which requires cron.CronJob).
/// This is a local INSERT OR REPLACE that works with cron.CronJob.
fn dbSaveJobDirect(db: *c.sqlite3, job: *const cron.CronJob) !void {
    const sql =
        "INSERT OR REPLACE INTO cron_jobs " ++
        "(id, expression, job_type, command, prompt, name, model, " ++
        "next_run_secs, last_run_secs, last_status, paused, one_shot, " ++
        "delete_after_run, enabled, delivery_mode, delivery_channel, " ++
        "delivery_account_id, delivery_to, created_at_s, last_output, timeout_secs, " ++
        "delivery_best_effort, session_target, skill_name, skill_args) " ++
        "VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25)";
    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, sql, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_text(stmt, 1, job.id.ptr, @intCast(job.id.len), SQLITE_STATIC);
    _ = c.sqlite3_bind_text(stmt, 2, job.expression.ptr, @intCast(job.expression.len), SQLITE_STATIC);
    const jt = job.job_type.asStr();
    _ = c.sqlite3_bind_text(stmt, 3, jt.ptr, @intCast(jt.len), SQLITE_STATIC);
    _ = c.sqlite3_bind_text(stmt, 4, job.command.ptr, @intCast(job.command.len), SQLITE_STATIC);
    if (job.prompt) |p| _ = c.sqlite3_bind_text(stmt, 5, p.ptr, @intCast(p.len), SQLITE_STATIC) else _ = c.sqlite3_bind_null(stmt, 5);
    if (job.name) |n| _ = c.sqlite3_bind_text(stmt, 6, n.ptr, @intCast(n.len), SQLITE_STATIC) else _ = c.sqlite3_bind_null(stmt, 6);
    if (job.model) |m| _ = c.sqlite3_bind_text(stmt, 7, m.ptr, @intCast(m.len), SQLITE_STATIC) else _ = c.sqlite3_bind_null(stmt, 7);
    _ = c.sqlite3_bind_int64(stmt, 8, job.next_run_secs);
    if (job.last_run_secs) |lrs| _ = c.sqlite3_bind_int64(stmt, 9, lrs) else _ = c.sqlite3_bind_null(stmt, 9);
    if (job.last_status) |ls| _ = c.sqlite3_bind_text(stmt, 10, ls.ptr, @intCast(ls.len), SQLITE_STATIC) else _ = c.sqlite3_bind_null(stmt, 10);
    _ = c.sqlite3_bind_int(stmt, 11, if (job.paused) 1 else 0);
    _ = c.sqlite3_bind_int(stmt, 12, if (job.one_shot) 1 else 0);
    _ = c.sqlite3_bind_int(stmt, 13, if (job.delete_after_run) 1 else 0);
    _ = c.sqlite3_bind_int(stmt, 14, if (job.enabled) 1 else 0);
    const dm = job.delivery.mode.asStr();
    _ = c.sqlite3_bind_text(stmt, 15, dm.ptr, @intCast(dm.len), SQLITE_STATIC);
    if (job.delivery.channel) |ch| _ = c.sqlite3_bind_text(stmt, 16, ch.ptr, @intCast(ch.len), SQLITE_STATIC) else _ = c.sqlite3_bind_null(stmt, 16);
    if (job.delivery.account_id) |aid| _ = c.sqlite3_bind_text(stmt, 17, aid.ptr, @intCast(aid.len), SQLITE_STATIC) else _ = c.sqlite3_bind_null(stmt, 17);
    if (job.delivery.to) |t| _ = c.sqlite3_bind_text(stmt, 18, t.ptr, @intCast(t.len), SQLITE_STATIC) else _ = c.sqlite3_bind_null(stmt, 18);
    _ = c.sqlite3_bind_int64(stmt, 19, job.created_at_s);
    if (job.last_output) |lo| _ = c.sqlite3_bind_text(stmt, 20, lo.ptr, @intCast(lo.len), SQLITE_STATIC) else _ = c.sqlite3_bind_null(stmt, 20);
    if (job.timeout_secs) |t| _ = c.sqlite3_bind_int(stmt, 21, @intCast(t)) else _ = c.sqlite3_bind_null(stmt, 21);
    _ = c.sqlite3_bind_int(stmt, 22, if (job.delivery.best_effort) 1 else 0);
    const st = job.session_target.asStr();
    _ = c.sqlite3_bind_text(stmt, 23, st.ptr, @intCast(st.len), SQLITE_STATIC);
    if (job.skill_name) |sn| _ = c.sqlite3_bind_text(stmt, 24, sn.ptr, @intCast(sn.len), SQLITE_STATIC) else _ = c.sqlite3_bind_null(stmt, 24);
    if (job.skill_args) |sa| _ = c.sqlite3_bind_text(stmt, 25, sa.ptr, @intCast(sa.len), SQLITE_STATIC) else _ = c.sqlite3_bind_null(stmt, 25);

    rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) return error.StepFailed;
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "DbCronBackend add and get" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path_str = try std.fmt.allocPrint(allocator, "{s}/add_get.db", .{base});
    defer allocator.free(db_path_str);
    const db_path_z = try allocator.dupeZ(u8, db_path_str);
    defer allocator.free(db_path_z);

    var backend = try DbCronBackend.init(allocator, db_path_z);
    defer backend.deinit();
    const be = backend.backend();

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

test "DbCronBackend remove returns false for missing" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path_str = try std.fmt.allocPrint(allocator, "{s}/remove.db", .{base});
    defer allocator.free(db_path_str);
    const db_path_z = try allocator.dupeZ(u8, db_path_str);
    defer allocator.free(db_path_z);

    var backend = try DbCronBackend.init(allocator, db_path_z);
    defer backend.deinit();
    const be = backend.backend();

    const found = try be.remove("nonexistent");
    try std.testing.expect(!found);
}

test "DbCronBackend pause and resumeJob" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path_str = try std.fmt.allocPrint(allocator, "{s}/pause.db", .{base});
    defer allocator.free(db_path_str);
    const db_path_z = try allocator.dupeZ(u8, db_path_str);
    defer allocator.free(db_path_z);

    var backend = try DbCronBackend.init(allocator, db_path_z);
    defer backend.deinit();
    const be = backend.backend();

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

test "DbCronBackend enqueue and dequeue" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path_str = try std.fmt.allocPrint(allocator, "{s}/deq.db", .{base});
    defer allocator.free(db_path_str);
    const db_path_z = try allocator.dupeZ(u8, db_path_str);
    defer allocator.free(db_path_z);

    var backend = try DbCronBackend.init(allocator, db_path_z);
    defer backend.deinit();
    const be = backend.backend();

    const job = try be.add(allocator, .{ .expression = "* * * * *", .command = "echo test" });
    defer {
        allocator.free(job.id);
        allocator.free(job.expression);
        allocator.free(job.command);
    }

    const now = std.time.timestamp();
    try be.enqueue(job.id, now);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const result = try be.dequeue(arena.allocator());
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(job.id, result.?.spec.id);
    try std.testing.expectEqualStrings("echo test", result.?.spec.command);

    // Second dequeue should be null (queue empty).
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const result2 = try be.dequeue(arena2.allocator());
    try std.testing.expect(result2 == null);
}

test "DbCronBackend dequeue preserves delivery_best_effort and session_target" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path_str = try std.fmt.allocPrint(allocator, "{s}/deq_spec.db", .{base});
    defer allocator.free(db_path_str);
    const db_path_z = try allocator.dupeZ(u8, db_path_str);
    defer allocator.free(db_path_z);

    var backend = try DbCronBackend.init(allocator, db_path_z);
    defer backend.deinit();
    const be = backend.backend();

    const job = try be.add(allocator, .{
        .expression = "* * * * *",
        .command = "echo",
        .session_target = .main,
        .delivery = .{ .best_effort = true, .mode = .always },
    });
    defer {
        allocator.free(job.id);
        allocator.free(job.expression);
        allocator.free(job.command);
    }

    try be.enqueue(job.id, std.time.timestamp());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const result = try be.dequeue(arena.allocator());
    try std.testing.expect(result != null);
    try std.testing.expectEqual(types.SessionTarget.main, result.?.spec.session_target);
    try std.testing.expect(result.?.spec.delivery.best_effort);
}

test "DbCronBackend remove clears queued head job" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path_str = try std.fmt.allocPrint(allocator, "{s}/remove_queue.db", .{base});
    defer allocator.free(db_path_str);
    const db_path_z = try allocator.dupeZ(u8, db_path_str);
    defer allocator.free(db_path_z);

    var backend = try DbCronBackend.init(allocator, db_path_z);
    defer backend.deinit();
    const be = backend.backend();

    const first = try be.add(allocator, .{ .expression = "* * * * *", .command = "echo first" });
    defer {
        allocator.free(first.id);
        allocator.free(first.expression);
        allocator.free(first.command);
    }
    const second = try be.add(allocator, .{ .expression = "* * * * *", .command = "echo second" });
    defer {
        allocator.free(second.id);
        allocator.free(second.expression);
        allocator.free(second.command);
    }

    const now = std.time.timestamp();
    try be.enqueue(first.id, now);
    try be.enqueue(second.id, now + 1);
    try std.testing.expect(try be.remove(first.id));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const result = try be.dequeue(arena.allocator());
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(second.id, result.?.spec.id);
}

test "DbCronBackend tick enqueues due jobs" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path_str = try std.fmt.allocPrint(allocator, "{s}/tick.db", .{base});
    defer allocator.free(db_path_str);
    const db_path_z = try allocator.dupeZ(u8, db_path_str);
    defer allocator.free(db_path_z);

    var backend = try DbCronBackend.init(allocator, db_path_z);
    defer backend.deinit();
    const be = backend.backend();

    // Create a job with next_run_secs in the past.
    const job = try be.add(allocator, .{ .expression = "* * * * *", .command = "echo" });
    defer {
        allocator.free(job.id);
        allocator.free(job.expression);
        allocator.free(job.command);
    }
    // Force next_run_secs = 1 (well in the past).
    _ = try be.update(job.id, .{ .next_run_secs = 1 });

    const now = std.time.timestamp();
    const enqueued = try be.tick(now);
    try std.testing.expect(enqueued >= 1);
}

test "DbCronBackend resetInProgress" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path_str = try std.fmt.allocPrint(allocator, "{s}/reset.db", .{base});
    defer allocator.free(db_path_str);
    const db_path_z = try allocator.dupeZ(u8, db_path_str);
    defer allocator.free(db_path_z);

    var backend = try DbCronBackend.init(allocator, db_path_z);
    defer backend.deinit();
    const be = backend.backend();

    try be.resetInProgress();
    // No assertion needed — just verifies it doesn't error on empty DB.
}

test "DbCronBackend listRows visitor" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path_str = try std.fmt.allocPrint(allocator, "{s}/list.db", .{base});
    defer allocator.free(db_path_str);
    const db_path_z = try allocator.dupeZ(u8, db_path_str);
    defer allocator.free(db_path_z);

    var backend = try DbCronBackend.init(allocator, db_path_z);
    defer backend.deinit();
    const be = backend.backend();

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

test "DbCronBackend jobs survive bounce — add, reopen, remove, reopen" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path_str = try std.fmt.allocPrint(allocator, "{s}/bounce.db", .{base});
    defer allocator.free(db_path_str);
    const db_path_z = try allocator.dupeZ(u8, db_path_str);
    defer allocator.free(db_path_z);

    // Phase 1: seed 3 jobs, close the backend (simulate shutdown).
    var added_id: []const u8 = undefined;
    {
        var be1 = try DbCronBackend.init(allocator, db_path_z);
        defer be1.deinit();
        const iface1 = be1.backend();
        for ([_][]const u8{ "echo a", "echo b", "echo c" }) |cmd| {
            const j = try iface1.add(allocator, .{ .expression = "* * * * *", .command = cmd });
            allocator.free(j.id);
            allocator.free(j.expression);
            allocator.free(j.command);
        }
    }

    // Phase 2: reopen (bounce), verify 3 jobs survived, add 1 more.
    {
        var be2 = try DbCronBackend.init(allocator, db_path_z);
        defer be2.deinit();
        const iface2 = be2.backend();

        var count: usize = 0;
        const counter = root.CronBackend.RowVisitor{
            .ptr = &count,
            .visit = struct {
                fn f(ptr: *anyopaque, _: types.CronJobSummary) anyerror!void {
                    const c_ptr: *usize = @ptrCast(@alignCast(ptr));
                    c_ptr.* += 1;
                }
            }.f,
        };
        try iface2.listRows(allocator, counter);
        try std.testing.expectEqual(@as(usize, 3), count);

        const extra = try iface2.add(allocator, .{ .expression = "*/5 * * * *", .command = "echo test-bounce" });
        added_id = try allocator.dupe(u8, extra.id);
        allocator.free(extra.id);
        allocator.free(extra.expression);
        allocator.free(extra.command);
    }
    defer allocator.free(added_id);

    // Phase 3: reopen (bounce), verify 4 jobs, remove the added one.
    {
        var be3 = try DbCronBackend.init(allocator, db_path_z);
        defer be3.deinit();
        const iface3 = be3.backend();

        var count2: usize = 0;
        const counter2 = root.CronBackend.RowVisitor{
            .ptr = &count2,
            .visit = struct {
                fn f(ptr: *anyopaque, _: types.CronJobSummary) anyerror!void {
                    const c_ptr: *usize = @ptrCast(@alignCast(ptr));
                    c_ptr.* += 1;
                }
            }.f,
        };
        try iface3.listRows(allocator, counter2);
        try std.testing.expectEqual(@as(usize, 4), count2);

        try std.testing.expect(try iface3.remove(added_id));
    }

    // Phase 4: reopen (bounce), verify back to 3 jobs.
    {
        var be4 = try DbCronBackend.init(allocator, db_path_z);
        defer be4.deinit();
        const iface4 = be4.backend();

        var count3: usize = 0;
        const counter3 = root.CronBackend.RowVisitor{
            .ptr = &count3,
            .visit = struct {
                fn f(ptr: *anyopaque, _: types.CronJobSummary) anyerror!void {
                    const c_ptr: *usize = @ptrCast(@alignCast(ptr));
                    c_ptr.* += 1;
                }
            }.f,
        };
        try iface4.listRows(allocator, counter3);
        try std.testing.expectEqual(@as(usize, 3), count3);
    }
}
