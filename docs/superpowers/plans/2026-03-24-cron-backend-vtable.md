# Cron Backend Vtable Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the split-brain cron architecture with a single CronBackend vtable interface that owns all job mutation and state transitions, backed initially by DbCronBackend (SQLite) and MemoryCronBackend (in-process ArrayList).

**Architecture:** Define CronBackend (ptr + vtable) in src/cron/root.zig following the exact pattern used by Channel (src/channels/root.zig) and Provider (src/providers/root.zig). DbCronBackend in src/cron/db.zig implements the vtable over SQLite; MemoryCronBackend in src/cron/memory.zig wraps the existing CronScheduler. schedulerThread, all 8 HTTP handlers, and the run queue worker all talk exclusively to CronBackend — no concrete scheduler pointer crosses a subsystem boundary.

**Tech Stack:** Zig 0.15.2, SQLite WAL mode (build_options.enable_sqlite), existing CronScheduler struct (preserved for MemoryCronBackend and tests).

---

## Root Cause Being Fixed

Three threads currently mutate cron state through three different surfaces:
- schedulerThread -> cron.dbTickAndEnqueue (DB direct)
- Gateway HTTP handlers -> sched.* + cron.saveJobs (in-memory then bulk-save)
- Run queue worker -> sched.getMutableJob + cron.dbUpsertAndVerify (both!)

Additionally, delivery_best_effort and session_target are fields on CronJobSpec but are NOT persisted in the DB. dbLoadJobSpec hardcodes best_effort = false and session_target = .isolated (src/cron.zig:3332,3337). This means dequeue() cannot be the authoritative execution snapshot until the schema is fixed first.

---

## File Structure

```
src/cron/             <- new directory (replaces src/cron.zig)
  root.zig            <- CronBackend vtable interface + shared types re-exported
  types.zig           <- CronJob, CronRun, DeliveryMode, JobType, SessionTarget,
                         CronJobPatch, CronJobSpec, DequeueResult, CronJobOutput,
                         CronJobSummary, NewJobSpec -- pure domain, zero storage
  expr.zig            <- parseDuration, normalizeExpression, nextRunForCronExpression,
                         parseCronExpression, cronExpressionMatches -- pure functions
  exec.zig            <- runAgentJob, collectChildOutputWithTimeout, deliverResult
  db.zig              <- DbCronBackend: implements CronBackend.VTable over SQLite
  memory.zig          <- MemoryCronBackend: thin vtable wrapper over CronScheduler
  factory.zig         <- createBackend(config, allocator) -> CronBackend

src/cron.zig          <- DELETED or replaced by: pub usingnamespace @import("cron/root.zig")
src/daemon.zig        <- schedulerThread: receives CronBackend, calls backend.tick(now)
src/gateway.zig       <- All 8 handlers + runQueueWorker: receive CronBackend, no concrete sched
```

Ownership rule: Callers own the concrete backend struct. CronBackend is a fat pointer (value type). Backend owns its internal allocator, mutex (MemoryCronBackend), and db_path (DbCronBackend). backend.deinit() is always required.

---

## Task 1: Fix schema -- persist delivery_best_effort and session_target

**Files:**
- Modify: src/cron.zig:1608-1667 (CRON_TABLE_SQL + ensureCronTable)
- Modify: src/cron.zig:1670-1752 (dbSaveJob)
- Modify: src/cron.zig:3292-3338 (dbLoadJobSpec)

- [ ] **Step 1: Write the failing test**

Add to src/cron.zig test section:

```zig
test "dbLoadJobSpec persists and restores delivery_best_effort and session_target" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path_str = try std.fmt.allocPrint(allocator, "{s}/spec_persist.db", .{base});
    defer allocator.free(db_path_str);
    const db_path = try allocator.dupeZ(u8, db_path_str);
    defer allocator.free(db_path);

    var sched = CronScheduler.init(allocator, 8, true);
    sched.db_path = db_path;
    defer sched.deinit();

    const job_ptr = try sched.addJob("* * * * *", "echo hi");
    job_ptr.delivery.best_effort = true;
    job_ptr.session_target = .main;
    try saveJobs(&sched);

    const db = try openCronDbAtPath(db_path);
    defer closeCronDb(db);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const spec = try dbLoadJobSpec(db, arena.allocator(), job_ptr.id);
    try std.testing.expect(spec != null);
    try std.testing.expect(spec.?.delivery.best_effort == true);
    try std.testing.expectEqual(SessionTarget.main, spec.?.session_target);
}
```

- [ ] **Step 2: Run test to confirm it fails**

```bash
cd ~/nullclaw && zig build test --summary all 2>&1 | grep "dbLoadJobSpec persists"
```

Expected: FAIL (best_effort hardcoded false, session_target hardcoded .isolated)

- [ ] **Step 3: Add columns to CRON_TABLE_SQL in src/cron.zig:1630**

Append two columns before the closing paren:

```
  delivery_best_effort INTEGER NOT NULL DEFAULT 0,
  session_target      TEXT NOT NULL DEFAULT 'isolated'
```

- [ ] **Step 4: Add ALTER TABLE migrations in ensureCronTable (~line 1665)**

```zig
_ = c.sqlite3_exec(db, "ALTER TABLE cron_jobs ADD COLUMN delivery_best_effort INTEGER NOT NULL DEFAULT 0", null, null, null);
_ = c.sqlite3_exec(db, "ALTER TABLE cron_jobs ADD COLUMN session_target TEXT NOT NULL DEFAULT 'isolated'", null, null, null);
```

Pattern: same as existing last_output and timeout_secs migrations on lines 1663-1665. Error ignored = idempotent.

- [ ] **Step 5: Update dbSaveJob INSERT to include delivery_best_effort (?22) and session_target (?23)**

Update the SQL string at line 1672 to include both columns. Add bindings after the existing ?21 (timeout_secs):

```zig
_ = c.sqlite3_bind_int(stmt, 22, if (job.delivery.best_effort) 1 else 0);
const st_str = job.session_target.asStr();
_ = c.sqlite3_bind_text(stmt, 23, st_str.ptr, @intCast(st_str.len), SQLITE_STATIC);
```

- [ ] **Step 6: Update dbLoadJobSpec SELECT to include columns 11 and 12**

Update SQL at line 3293 to add delivery_best_effort, session_target to the SELECT.
Replace hardcoded lines 3332 and 3337:

```zig
.best_effort = c.sqlite3_column_int(stmt, 11) != 0,
// ...
.session_target = blk: {
    const raw = try dbColumnTextOpt(stmt, 12, arena);
    break :blk if (raw) |s| SessionTarget.parse(s) else .isolated;
},
```

- [ ] **Step 7: Run the failing test -- confirm it now passes**

```bash
cd ~/nullclaw && zig build test --summary all 2>&1 | grep "dbLoadJobSpec persists"
```

Expected: PASS

- [ ] **Step 8: Run full test suite**

```bash
zig build test --summary all 2>&1 | tail -5
```

Expected: same or better pass count, 0 new failures.

- [ ] **Step 9: Commit**

```bash
git add src/cron.zig
git commit -m "fix(cron): persist delivery_best_effort and session_target in DB schema"
```

---

## Task 2: Extract pure domain types to src/cron/types.zig

**Files:**
- Create: src/cron/types.zig

Copy (not delete yet -- deletion in Task 10) the following from src/cron.zig:
JobType, SessionTarget, ScheduleKind, Schedule, DeliveryMode, DeliveryConfig, CronRun, CronJobPatch, CronJob.
Add new types: CronJobSpec (update existing), DequeueResult, CronJobOutput, CronJobSummary, NewJobSpec.

- [ ] **Step 1: Create src/cron/types.zig with all domain types**

```zig
const std = @import("std");

// Copy JobType, SessionTarget, ScheduleKind, Schedule, DeliveryMode,
// DeliveryConfig, CronRun, CronJobPatch, CronJob verbatim from src/cron.zig.

pub const CronJobSpec = struct {
    id: []const u8,
    job_type: JobType,
    command: []const u8,
    prompt: ?[]const u8,
    model: ?[]const u8,
    one_shot: bool,
    delete_after_run: bool,
    timeout_secs: ?u32,
    delivery: DeliveryConfig,   // best_effort field now correctly loaded from DB
    session_target: SessionTarget,
};

pub const DequeueResult = struct {
    queue_row_id: i64,
    spec: CronJobSpec,          // full snapshot, claimed atomically
};

pub const CronJobOutput = struct {
    status: []const u8,         // "ok" | "error" | ""
    output: []const u8,         // raw bytes, no JSON
    last_run_secs: ?i64,
};

// Summary for list path -- excludes last_output to avoid large-column copy.
pub const CronJobSummary = struct {
    id: []const u8,
    expression: []const u8,
    name: ?[]const u8,
    job_type: JobType,
    next_run_secs: i64,
    last_run_secs: ?i64,
    last_status: ?[]const u8,
    paused: bool,
    enabled: bool,
    one_shot: bool,
    delete_after_run: bool,
    delivery_mode: DeliveryMode,
    delivery_channel: ?[]const u8,
    delivery_to: ?[]const u8,
    created_at_s: i64,
    timeout_secs: ?u32,
};

pub const NewJobSpec = struct {
    expression: []const u8,
    job_type: JobType = .shell,
    command: []const u8 = "",
    prompt: ?[]const u8 = null,
    name: ?[]const u8 = null,
    model: ?[]const u8 = null,
    one_shot: bool = false,
    delete_after_run: bool = false,
    enabled: bool = true,
    timeout_secs: ?u32 = null,
    delivery: DeliveryConfig = .{},
    session_target: SessionTarget = .isolated,
    created_at_s: i64 = 0,
};
```

- [ ] **Step 2: Build to confirm no syntax errors**

```bash
cd ~/nullclaw && zig build 2>&1 | grep "cron/types"
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add src/cron/types.zig
git commit -m "feat(cron): add src/cron/types.zig with pure domain types"
```

---

## Task 3: Define CronBackend vtable interface in src/cron/root.zig

**Files:**
- Create: src/cron/root.zig

Follow the exact pattern from src/channels/root.zig:88-244.
Key pattern: ptr + vtable struct, forwarding methods, RowVisitor for listRows.

- [ ] **Step 1: Create src/cron/root.zig**

```zig
const std = @import("std");
pub const types = @import("types.zig");
pub usingnamespace types;

pub const CronBackend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit:         *const fn (ptr: *anyopaque) void,
        tick:           *const fn (ptr: *anyopaque, now: i64) anyerror!usize,
        add:            *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, spec: types.NewJobSpec) anyerror!types.CronJob,
        remove:         *const fn (ptr: *anyopaque, id: []const u8) anyerror!bool,
        pause:          *const fn (ptr: *anyopaque, id: []const u8) anyerror!bool,
        resumeJob:      *const fn (ptr: *anyopaque, id: []const u8) anyerror!bool,
        update:         *const fn (ptr: *anyopaque, id: []const u8, patch: types.CronJobPatch) anyerror!bool,
        get:            *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, id: []const u8) anyerror!?types.CronJob,
        listRows:       *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, visitor: RowVisitor) anyerror!void,
        getOutput:      *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, id: []const u8) anyerror!?types.CronJobOutput,
        enqueue:        *const fn (ptr: *anyopaque, id: []const u8, now: i64) anyerror!void,
        dequeue:        *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?types.DequeueResult,
        complete:       *const fn (ptr: *anyopaque, id: []const u8, row_id: i64, now: i64, status: []const u8, output: ?[]const u8, delivered: bool) anyerror!void,
        resetInProgress: *const fn (ptr: *anyopaque) anyerror!void,
    };

    // Visitor for listRows -- backend calls visit() once per row with a temporary summary.
    // Strings in CronJobSummary are valid only during the visit() call.
    pub const RowVisitor = struct {
        ptr: *anyopaque,
        visit: *const fn (ptr: *anyopaque, row: types.CronJobSummary) anyerror!void,
    };

    pub fn deinit(self: CronBackend) void { self.vtable.deinit(self.ptr); }
    pub fn tick(self: CronBackend, now: i64) !usize { return self.vtable.tick(self.ptr, now); }
    pub fn add(self: CronBackend, a: std.mem.Allocator, spec: types.NewJobSpec) !types.CronJob { return self.vtable.add(self.ptr, a, spec); }
    pub fn remove(self: CronBackend, id: []const u8) !bool { return self.vtable.remove(self.ptr, id); }
    pub fn pause(self: CronBackend, id: []const u8) !bool { return self.vtable.pause(self.ptr, id); }
    pub fn resumeJob(self: CronBackend, id: []const u8) !bool { return self.vtable.resumeJob(self.ptr, id); }
    pub fn update(self: CronBackend, id: []const u8, patch: types.CronJobPatch) !bool { return self.vtable.update(self.ptr, id, patch); }
    pub fn get(self: CronBackend, a: std.mem.Allocator, id: []const u8) !?types.CronJob { return self.vtable.get(self.ptr, a, id); }
    pub fn listRows(self: CronBackend, a: std.mem.Allocator, v: RowVisitor) !void { return self.vtable.listRows(self.ptr, a, v); }
    pub fn getOutput(self: CronBackend, a: std.mem.Allocator, id: []const u8) !?types.CronJobOutput { return self.vtable.getOutput(self.ptr, a, id); }
    pub fn enqueue(self: CronBackend, id: []const u8, now: i64) !void { return self.vtable.enqueue(self.ptr, id, now); }
    pub fn dequeue(self: CronBackend, a: std.mem.Allocator) !?types.DequeueResult { return self.vtable.dequeue(self.ptr, a); }
    pub fn complete(self: CronBackend, id: []const u8, row_id: i64, now: i64, status: []const u8, output: ?[]const u8, delivered: bool) !void {
        return self.vtable.complete(self.ptr, id, row_id, now, status, output, delivered);
    }
    pub fn resetInProgress(self: CronBackend) !void { return self.vtable.resetInProgress(self.ptr); }
};

test "CronBackend.VTable fields are complete" {
    const vt: CronBackend.VTable = undefined;
    _ = vt.deinit; _ = vt.tick; _ = vt.add; _ = vt.remove;
    _ = vt.pause; _ = vt.resumeJob; _ = vt.update; _ = vt.get;
    _ = vt.listRows; _ = vt.getOutput; _ = vt.enqueue;
    _ = vt.dequeue; _ = vt.complete; _ = vt.resetInProgress;
}
```

- [ ] **Step 2: Build**

```bash
cd ~/nullclaw && zig build 2>&1 | grep "cron/root"
```

- [ ] **Step 3: Run tests**

```bash
zig build test --summary all 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add src/cron/root.zig src/cron/types.zig
git commit -m "feat(cron): define CronBackend vtable interface in src/cron/root.zig"
```

---

## Task 4: Implement DbCronBackend in src/cron/db.zig

**Files:**
- Create: src/cron/db.zig

DbCronBackend owns db_path (heap-duped) and allocator. No mutex -- each vtable method opens its own SQLite connection (proven safe by existing dbTickAndEnqueue). Mutations requiring atomicity use BEGIN IMMEDIATE / COMMIT.

- [ ] **Step 1: Write failing tests**

```zig
test "DbCronBackend.tick enqueues due jobs" { ... }
test "DbCronBackend.dequeue returns atomic spec snapshot with best_effort and session_target" { ... }
test "DbCronBackend.add then get round-trips all fields" { ... }
test "DbCronBackend.remove returns false for missing id" { ... }
test "DbCronBackend.pause and resumeJob toggle paused" { ... }
test "DbCronBackend.complete removes queue row" { ... }
test "DbCronBackend.resetInProgress resets stuck rows" { ... }
test "DbCronBackend.listRows visits all jobs without last_output" { ... }
test "DbCronBackend.getOutput returns null before first run" { ... }
```

- [ ] **Step 2: Run -- confirm all fail**

```bash
cd ~/nullclaw && zig build test --summary all 2>&1 | grep "DbCronBackend"
```

- [ ] **Step 3: Implement DbCronBackend**

```zig
pub const DbCronBackend = struct {
    db_path: [:0]u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: [:0]const u8) !DbCronBackend {
        return .{ .db_path = try allocator.dupeZ(u8, path), .allocator = allocator };
    }

    pub fn deinit(self: *DbCronBackend) void { self.allocator.free(self.db_path); }

    fn vtableDeinit(ptr: *anyopaque) void {
        const self: *DbCronBackend = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn vtableDequeue(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?types.DequeueResult {
        const self: *DbCronBackend = @ptrCast(@alignCast(ptr));
        const db = try openCronDbAtPath(self.db_path);
        defer closeCronDb(db);
        // BEGIN IMMEDIATE transaction:
        //   1. SELECT oldest pending queue row
        //   2. UPDATE status='in_progress', started_at=now WHERE id=row_id
        //   3. SELECT full job spec (all columns including delivery_best_effort, session_target)
        // Return DequeueResult or null.
        // This replaces the two-step dbDequeueNextJob + dbLoadJobSpec.
    }

    fn vtableListRows(ptr: *anyopaque, allocator: std.mem.Allocator, visitor: root.CronBackend.RowVisitor) anyerror!void {
        const self: *DbCronBackend = @ptrCast(@alignCast(ptr));
        const db = try openCronDbAtPath(self.db_path);
        defer closeCronDb(db);
        // SELECT id, expression, name, job_type, next_run_secs, last_run_secs, last_status,
        //        paused, enabled, one_shot, delete_after_run, delivery_mode, delivery_channel,
        //        delivery_to, created_at_s, timeout_secs
        // FROM cron_jobs ORDER BY rowid ASC
        // -- NOTE: no last_output in this query (avoids large-column copy on list)
        // For each row: build CronJobSummary on stack, call visitor.visit()
        _ = allocator; // only needed for string duplication if visitor needs stable ptrs
    }

    // ... remaining vtable fns ...

    pub const vtable = root.CronBackend.VTable{
        .deinit = &vtableDeinit,
        .tick = &vtableTick,
        // ...
    };

    pub fn backend(self: *DbCronBackend) root.CronBackend {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};
```

- [ ] **Step 4: Run tests -- confirm they pass**

```bash
cd ~/nullclaw && zig build test --summary all 2>&1 | grep "DbCronBackend"
```

- [ ] **Step 5: Full suite**

```bash
zig build test --summary all 2>&1 | tail -5
```

- [ ] **Step 6: Commit**

```bash
git add src/cron/db.zig
git commit -m "feat(cron): implement DbCronBackend vtable over SQLite"
```

---

## Task 5: Implement MemoryCronBackend in src/cron/memory.zig

**Files:**
- Create: src/cron/memory.zig (absorbs CronScheduler from src/cron.zig)

Wraps CronScheduler with a Mutex. Each vtable method locks, delegates, unlocks. Owns an in-process run queue (replaces GatewayState.run_queue ArrayList).

- [ ] **Step 1: Write failing tests**

```zig
test "MemoryCronBackend.tick enqueues due jobs" { ... }
test "MemoryCronBackend.add and get round-trips fields" { ... }
test "MemoryCronBackend.dequeue returns spec snapshot" { ... }
test "MemoryCronBackend.complete clears queue row" { ... }
test "MemoryCronBackend.listRows visits all jobs" { ... }
```

- [ ] **Step 2: Run -- confirm fail**

```bash
cd ~/nullclaw && zig build test --summary all 2>&1 | grep "MemoryCronBackend"
```

- [ ] **Step 3: Implement MemoryCronBackend**

```zig
pub const MemoryCronBackend = struct {
    scheduler: CronScheduler,
    mutex: std.Thread.Mutex = .{},
    queue: std.ArrayListUnmanaged(QueueRow) = .empty,
    next_row_id: i64 = 1,
    allocator: std.mem.Allocator,

    const QueueRow = struct {
        id: i64,
        job_id: []const u8,  // owned
        status: enum { pending, in_progress },
    };

    pub fn init(allocator: std.mem.Allocator, max_tasks: usize) MemoryCronBackend { ... }
    pub fn deinit(self: *MemoryCronBackend) void { ... }

    // vtableDequeue: under mutex, find oldest pending row,
    // mark in_progress, load spec from scheduler, return DequeueResult.

    pub fn backend(self: *MemoryCronBackend) root.CronBackend {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};
```

- [ ] **Step 4: Run tests -- confirm pass**

```bash
cd ~/nullclaw && zig build test --summary all 2>&1 | grep "MemoryCronBackend"
```

- [ ] **Step 5: Full suite**

```bash
zig build test --summary all 2>&1 | tail -5
```

- [ ] **Step 6: Commit**

```bash
git add src/cron/memory.zig
git commit -m "feat(cron): implement MemoryCronBackend vtable over in-memory CronScheduler"
```

---

## Task 6: Add factory and wire into module system

**Files:**
- Create: src/cron/factory.zig
- Modify: src/root.zig (or equivalent module registry)

- [ ] **Step 1: Create src/cron/factory.zig**

```zig
const std = @import("std");
const build_options = @import("build_options");
const root = @import("root.zig");
const Config = @import("../config.zig").Config;

pub fn createBackend(allocator: std.mem.Allocator, config: *const Config) !root.CronBackend {
    if (build_options.enable_sqlite) {
        const db_mod = @import("db.zig");
        const cron_old = @import("../cron.zig");
        const db_path = try cron_old.getCronDbPathZ(allocator);
        defer allocator.free(db_path);
        const impl = try allocator.create(db_mod.DbCronBackend);
        impl.* = try db_mod.DbCronBackend.init(allocator, db_path);
        return impl.backend();
    } else {
        const mem_mod = @import("memory.zig");
        const impl = try allocator.create(mem_mod.MemoryCronBackend);
        impl.* = mem_mod.MemoryCronBackend.init(allocator, config.scheduler.max_tasks);
        return impl.backend();
    }
}
```

- [ ] **Step 2: Check and update src/root.zig exports**

```bash
grep -n "cron\|CronScheduler" ~/nullclaw/src/root.zig | head -20
```

Add export: `pub const cron_backend = @import("cron/root.zig");`

- [ ] **Step 3: Build**

```bash
cd ~/nullclaw && zig build 2>&1 | grep error | head -20
```

- [ ] **Step 4: Run tests**

```bash
zig build test --summary all 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add src/cron/factory.zig src/root.zig
git commit -m "feat(cron): add CronBackend factory, wire into module system"
```

---

## Task 7: Wire CronBackend into daemon.zig schedulerThread

**Files:**
- Modify: src/daemon.zig

- [ ] **Step 1: Update schedulerThread signature and body**

Add parameter `backend: cron_root.CronBackend` to schedulerThread.
Replace the entire loop body with:

```zig
while (!isShutdownRequested()) {
    const enqueued = backend.tick(std.time.timestamp()) catch |err| blk: {
        log.warn("backend.tick failed: {s}", .{@errorName(err)});
        state.markError("scheduler", @errorName(err));
        health.markComponentError("scheduler", @errorName(err));
        break :blk 0;
    };
    if (enqueued > 0) {
        gateway_mod.signalRunQueueWorker();
        log.info("scheduler: enqueued {d} job(s)", .{enqueued});
    }
    state.markRunning("scheduler");
    health.markComponentOk("scheduler");
    var slept: u64 = 0;
    while (slept < poll_secs and !isShutdownRequested()) : (slept += 1)
        std.Thread.sleep(std.time.ns_per_s);
}
```

Remove: CronScheduler init, loadJobs, setSharedScheduler, clearSharedScheduler, getCronDbPathZ, acquireSchedulerGuard, reloadJobs calls.

- [ ] **Step 2: Create backend in daemon.run() and pass to spawn**

```zig
var cron_backend = try cron_factory.createBackend(allocator, config);
defer cron_backend.deinit();
// Pass cron_backend to std.Thread.spawn for schedulerThread
```

- [ ] **Step 3: Build**

```bash
cd ~/nullclaw && zig build 2>&1 | grep error | head -20
```

- [ ] **Step 4: Run tests**

```bash
zig build test --summary all 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add src/daemon.zig
git commit -m "refactor(daemon): schedulerThread uses CronBackend.tick, remove direct DB call"
```

---

## Task 8: Wire CronBackend into gateway -- HTTP handlers

**Files:**
- Modify: src/gateway.zig -- GatewayState + all 8 cron handlers

- [ ] **Step 1: Replace GatewayState scheduler fields**

Remove: `scheduler`, `scheduler_mutex`, `run_queue` ArrayList.
Add: `cron_backend: ?cron_root.CronBackend = null`

Update GatewayState.deinit() to call `if (self.cron_backend) |b| b.deinit()`.

- [ ] **Step 2: Convert handleCronList**

Replace DB-direct + legacy fallback with:
```zig
const backend = ctx.state.cron_backend orelse { return 503; };
var buf: std.ArrayListUnmanaged(u8) = .empty;
defer buf.deinit(ctx.req_allocator);
// RowVisitor that calls appendJobSummaryJson into buf
try buf.appendSlice(ctx.req_allocator, "[");
try backend.listRows(ctx.req_allocator, visitor);
try buf.appendSlice(ctx.req_allocator, "]");
ctx.response_body = buf.items;
```

Add private fn `appendJobSummaryJson(buf, allocator, row: CronJobSummary)` -- extracted from existing dbListJobsJson JSON rendering.

- [ ] **Step 3: Convert handleCronAdd**

Replace lockRequestScheduler + sched.addJob/addAgentJob + saveJobs with:
```zig
const job = try backend.add(ctx.req_allocator, parsed_spec);
defer cron_root.freeCronJob(ctx.req_allocator, job);
// serialize job to JSON response
```

- [ ] **Step 4: Convert handleCronRemove, handleCronPause, handleCronResume**

Each becomes:
```zig
const found = try backend.remove(id);  // or .pause / .resumeJob
if (!found) { return 404; }
ctx.response_body = "{\"ok\":true}";
```

- [ ] **Step 5: Convert handleCronUpdate**

```zig
const found = try backend.update(id, patch);
if (!found) { return 404; }
const job = (try backend.get(ctx.req_allocator, id)) orelse { return 404; };
defer cron_root.freeCronJob(ctx.req_allocator, job);
// serialize to JSON
```

- [ ] **Step 6: Convert handleCronRun**

```zig
try backend.enqueue(id, std.time.timestamp());
gateway_mod.signalRunQueueWorker();  // condvar stays outside backend
ctx.response_body = "{\"ok\":true}";
```

- [ ] **Step 7: Convert handleCronOutput**

```zig
const out = try backend.getOutput(ctx.req_allocator, id) orelse { return 404; };
defer { ctx.req_allocator.free(out.status); ctx.req_allocator.free(out.output); }
// serialize CronJobOutput (status, output, last_run_secs) to JSON
```

- [ ] **Step 8: Delete g_shared_scheduler, SchedulerGuard, lockRequestScheduler, unlockRequestScheduler, setSharedScheduler, clearSharedScheduler, enqueueScheduledJob**

```bash
grep -n "g_shared_scheduler\|SchedulerGuard\|lockRequestScheduler\|setSharedScheduler\|enqueueScheduledJob" src/gateway.zig
```

Delete each symbol and all references.

- [ ] **Step 9: Build**

```bash
cd ~/nullclaw && zig build 2>&1 | grep error | head -20
```

- [ ] **Step 10: Run tests**

```bash
zig build test --summary all 2>&1 | tail -5
```

- [ ] **Step 11: Commit**

```bash
git add src/gateway.zig
git commit -m "refactor(gateway): all cron HTTP handlers use CronBackend, remove SchedulerGuard"
```

---

## Task 9: Wire CronBackend into the run queue worker

**Files:**
- Modify: src/gateway.zig -- runQueueWorker

- [ ] **Step 1: Rewrite runQueueWorker**

Replace split DB-direct/legacy-memory branching:

```zig
fn runQueueWorker(state: *GatewayState) void {
    const backend = state.cron_backend orelse { return; };

    backend.resetInProgress() catch |err|
        log.warn("worker: resetInProgress: {s}", .{@errorName(err)});

    while (true) {
        {
            state.run_queue_mutex.lock();
            defer state.run_queue_mutex.unlock();
            if (state.run_queue_stop) return;
            _ = state.run_queue_cond.timedWait(&state.run_queue_mutex, std.time.ns_per_s) catch {};
            if (state.run_queue_stop) return;
        }
        while (true) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const item = backend.dequeue(arena.allocator()) catch |err| {
                log.err("worker: dequeue failed: {s}", .{@errorName(err)});
                break;
            } orelse break;  // queue empty

            executeAndComplete(state, backend, &item, arena.allocator()) catch |err|
                log.err("[{s}] execute failed: {s}", .{item.spec.id, @errorName(err)});
        }
    }
}
```

Extract existing shell/agent execution logic into `fn executeAndComplete(state, backend, item, arena)`.
Replace `cron_mod.dbCompleteJob(...)` calls with `backend.complete(...)`.
`item.spec` is the authoritative snapshot -- no need to call getMutableJob or dbLoadJobSpec.

- [ ] **Step 2: Build**

```bash
cd ~/nullclaw && zig build 2>&1 | grep error | head -20
```

- [ ] **Step 3: Run tests**

```bash
zig build test --summary all 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add src/gateway.zig
git commit -m "refactor(worker): runQueueWorker uses CronBackend.dequeue/complete, remove legacy branch"
```

---

## Task 10: Clean up src/cron.zig and update all imports

**Files:**
- Modify: src/cron.zig -- convert to re-export shim or delete
- Modify: src/daemon.zig, src/gateway.zig, src/main.zig, any other callers

- [ ] **Step 1: Find all imports of cron.zig**

```bash
grep -rn "@import.*cron.zig\|@import.*\"cron\"" ~/nullclaw/src/ | grep -v "src/cron/"
```

- [ ] **Step 2: Update each to import from src/cron/root.zig**

Change `@import("cron.zig")` -> `@import("cron/root.zig")`.

- [ ] **Step 3: Convert src/cron.zig to a shim (preserves compatibility for any missed caller)**

```zig
pub usingnamespace @import("cron/root.zig");
```

Or delete if all callers are updated.

- [ ] **Step 4: Build -- zero errors**

```bash
cd ~/nullclaw && zig build 2>&1 | grep error
```

- [ ] **Step 5: Run full test suite**

```bash
zig build test --summary all 2>&1 | tail -5
```

Expected: same or better pass count vs baseline.

- [ ] **Step 6: Commit**

```bash
git add src/
git commit -m "refactor(cron): convert src/cron.zig to re-export shim, all callers use src/cron/"
```

---

## Task 11: E2E verification

- [ ] **Step 1: Build and bounce**

```bash
cd ~/nullclaw && zig build && bash ~/.nullclaw/bounce.sh && bash ~/.nullclaw/restore-seed.sh
```

- [ ] **Step 2: Confirm scheduler ticking via new backend**

```bash
grep "enqueued\|panic\|corrupt\|backend" ~/.nullclaw/gateway.log | tail -20
```

Expected: "scheduler: enqueued N job(s)" lines, zero panics.

- [ ] **Step 3: Run E2E delivery test**

```bash
bash ~/.nullclaw/test-cron-delivery.sh
```

Expected: 5/5 PASS, Telegram message received.

- [ ] **Step 4: Verify queue drains**

```bash
python3 -c "
import sqlite3
db = sqlite3.connect('/home/yanggf/.nullclaw/cron.db')
print('queue rows:', db.execute('SELECT COUNT(*) FROM cron_run_queue').fetchone()[0])
print('in_progress:', db.execute(\"SELECT COUNT(*) FROM cron_run_queue WHERE status='in_progress'\").fetchone()[0])
"
```

Expected: 0.

- [ ] **Step 5: Confirm no legacy symbols remain**

```bash
grep -rn "g_shared_scheduler\|lockRequestScheduler\|SchedulerGuard\|collectDueJobs\|saveJobs\b\|reloadJobs" ~/nullclaw/src/daemon.zig ~/nullclaw/src/gateway.zig
```

Expected: zero matches.

---

## Validation Checklist

- [ ] zig build test --summary all -- same or better pass rate as baseline
- [ ] No panic, corrupt, switch on corrupt in gateway.log
- [ ] "scheduler: enqueued" appears in log each minute
- [ ] test-cron-delivery.sh passes 5/5
- [ ] Telegram message received during E2E test
- [ ] cron_run_queue empties after each tick cycle
- [ ] restore-seed.sh restores all 9 jobs with correct delivery config
- [ ] No reference to g_shared_scheduler, lockRequestScheduler, SchedulerGuard, collectDueJobs, saveJobs, reloadJobs in daemon.zig or gateway.zig
- [ ] delivery_best_effort and session_target round-trip through DB
- [ ] CronBackend is the only mutation path for all cron state
- [ ] dequeue() returns DequeueResult with correct best_effort and session_target
