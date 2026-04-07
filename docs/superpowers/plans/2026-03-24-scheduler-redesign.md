# Scheduler Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the legacy in-memory scheduler tick path entirely — the DB is the single source of truth, the scheduler thread only calls `dbTickAndEnqueue`, and the worker thread only reads from `cron_run_queue`.

**Architecture:** `schedulerThread` in `daemon.zig` calls `dbTickAndEnqueue` every poll cycle (no `tick()`, no `reloadJobs`, no `SchedulerGuard`). `runQueueWorker` in `gateway.zig` dequeues from `cron_run_queue`, loads the job spec from DB, executes, delivers, and writes results back — no in-memory scheduler pointer ever touched. All HTTP handlers open their own DB connection per request.

**Tech Stack:** Zig 0.15.2, SQLite WAL mode, condvar for worker wake-up only.

---

## Root Cause Summary

The scheduler panics with `switch on corrupt value` because:
1. `handleCronAdd` stored `delivery_channel` as a raw pointer into the request's JSON parse arena (freed after the handler returns). The DB row ends up with garbage bytes. *(Fix already landed — dupe into sched.allocator)*
2. `reloadJobs()` loads those garbage bytes back into the in-memory `CronJob.delivery.mode` field as a raw integer, not a valid enum tag.
3. `tick()` calls `switch (job.delivery.mode)` → panic.

The real fix: **delete the legacy path**. No in-memory scheduler in the daemon loop, no `tick()` call, no `reloadJobs` in the hot path. The DB path already works correctly.

---

## What Gets Deleted

| Symbol | File | Why |
|--------|------|-----|
| `g_shared_scheduler` | gateway.zig:5536 | replaced by DB-direct handlers |
| `g_shared_scheduler_mutex` | gateway.zig:5539 | same |
| `setSharedScheduler` | gateway.zig:5551 | same |
| `clearSharedScheduler` | gateway.zig:5565 | same |
| `acquireSchedulerGuard` / `SchedulerGuard` | gateway.zig | handlers don't need scheduler pointer |
| `lockRequestScheduler` / `unlockRequestScheduler` | gateway.zig:2494 | same |
| `GatewayState.scheduler` | gateway.zig:491 | no longer held in state |
| `GatewayState.scheduler_mutex` | gateway.zig:492 | same |
| `GatewayState.run_queue` ArrayList | gateway.zig | replaced by DB table |
| `collectDueJobs` | cron.zig | replaced by `dbTickAndEnqueue` |
| `enqueueScheduledJob` | gateway.zig | same |
| `mergeSchedulerTickChangesAndSave` / `buildSchedulerSnapshot` | daemon.zig | legacy tick helpers |
| Legacy in-memory `tick()` call path in `schedulerThread` | daemon.zig | replaced |
| Legacy in-memory worker branch in `runQueueWorker` | gateway.zig | replaced |

## What Stays / Gets Simplified

| Symbol | File | Change |
|--------|------|--------|
| `dbTickAndEnqueue` | cron.zig | stays, becomes only tick path |
| `signalRunQueueWorker` | gateway.zig | stays, uses `run_queue_cond` |
| `run_queue_mutex` / `run_queue_cond` | gateway.zig | stays, worker wake only |
| `GatewayState.cron_db_path` | gateway.zig | stays |
| `dbDequeueNextJob` / `dbLoadJobSpec` / `dbCompleteJob` | cron.zig | stays |
| `dbListJobsJson` / `dbGetJobOutputJson` | cron.zig | stays |
| All HTTP handlers | gateway.zig | DB-direct only, remove legacy branch |
| `CronScheduler` struct | cron.zig | still used by tests; not used in daemon |

---

## Files Modified

- **`src/daemon.zig`** — `schedulerThread`: remove legacy branch + snapshot/merge helpers, only DB-direct loop
- **`src/gateway.zig`** — remove globals, `SchedulerGuard`, `lockRequestScheduler`; simplify all 8 handlers to DB-direct only; simplify `runQueueWorker` to DB-direct only; remove `GatewayState.scheduler` + `scheduler_mutex` + `run_queue` ArrayList
- **`src/cron.zig`** — no functional changes; a few tests that exercised the global wiring may need update

---

## Task 1: Simplify `schedulerThread` in daemon.zig

**Files:** Modify `src/daemon.zig` lines ~403–525

The goal: `schedulerThread` should only do the DB-direct loop. Delete the legacy `else` branch (lines ~459–524) and all snapshot/merge helpers it depends on.

- [ ] **Step 1: Read `schedulerThread` and identify the legacy branch**

```bash
grep -n "Legacy in-memory\|collectDueJobs\|buildSchedulerSnapshot\|mergeSchedulerTick\|enqueueScheduledJob\|scheduler.tick\|SchedulerJobSnapshot" src/daemon.zig
```

Expected: several hits pointing to the legacy `else` branch inside the `while` loop.

- [ ] **Step 2: Delete the legacy `else` branch from `schedulerThread`**

Replace the entire `while (!isShutdownRequested())` body so it only contains the DB-direct block:

```zig
while (!isShutdownRequested()) {
    if (db_path) |path| {
        const now = std.time.timestamp();
        const enqueued = cron.dbTickAndEnqueue(path, allocator, now) catch |err| blk: {
            log.warn("dbTickAndEnqueue failed: {s}", .{@errorName(err)});
            state.markError("scheduler", @errorName(err));
            health.markComponentError("scheduler", @errorName(err));
            break :blk 0;
        };
        if (enqueued > 0) {
            gateway_mod.signalRunQueueWorker();
            log.info("scheduler: enqueued {d} job(s)", .{enqueued});
        }
    } else {
        log.err("scheduler: no db_path available, cannot tick", .{});
        state.markError("scheduler", "no db_path");
    }
    std.time.sleep(poll_secs * std.time.ns_per_s);
}
```

- [ ] **Step 3: Remove `reloadJobs` call and `SchedulerGuard` usage from the loop**

The DB-direct branch currently still calls `reloadJobs()` under a `SchedulerGuard` (for HTTP handler benefit). Remove that block entirely — HTTP handlers will read from DB directly (done in later tasks).

- [ ] **Step 4: Remove `SchedulerJobSnapshot`, `buildSchedulerSnapshot`, `mergeSchedulerTickChangesAndSave`, `clearSchedulerSnapshot` from daemon.zig**

Search:
```bash
grep -n "SchedulerJobSnapshot\|buildSchedulerSnapshot\|mergeSchedulerTick\|clearSchedulerSnapshot" src/daemon.zig
```
Delete all those functions and the type definition.

- [ ] **Step 5: Remove `setSharedScheduler` / `clearSharedScheduler` calls from `schedulerThread`**

The thread no longer registers a shared pointer. Delete:
```zig
gateway_mod.setSharedScheduler(&scheduler);   // remove
defer gateway_mod.clearSharedScheduler();      // remove
```

Also remove the `var scheduler = CronScheduler.init(...)` block and `cron.loadJobs(...)` call — the daemon thread no longer needs an in-memory scheduler at all.

- [ ] **Step 6: Build and fix compile errors**

```bash
cd ~/nullclaw && zig build 2>&1 | grep error
```

Fix any missing symbol errors from removed functions.

- [ ] **Step 7: Run tests**

```bash
zig build test --summary all 2>&1 | tail -5
```

Expected: same pass count (6077+/6088), 0 new failures.

- [ ] **Step 8: Commit**

```bash
git add src/daemon.zig && git commit -m "refactor(scheduler): remove legacy in-memory tick path from schedulerThread"
```

---

## Task 2: Remove global scheduler pointer from gateway.zig

**Files:** Modify `src/gateway.zig`

Remove `g_shared_scheduler`, `g_shared_scheduler_mutex`, `setSharedScheduler`, `clearSharedScheduler`, `acquireSchedulerGuard`, `SchedulerGuard`, `lockRequestScheduler`, `unlockRequestScheduler`, and `GatewayState.scheduler` + `GatewayState.scheduler_mutex`.

- [ ] **Step 1: Find all uses of the globals**

```bash
grep -n "g_shared_scheduler\|setSharedScheduler\|clearSharedScheduler\|acquireSchedulerGuard\|SchedulerGuard\|lockRequestScheduler\|unlockRequestScheduler\|state\.scheduler\b\|scheduler_mutex" src/gateway.zig | grep -v "run_queue\|cron_db_path"
```

- [ ] **Step 2: Remove `GatewayState.scheduler` and `GatewayState.scheduler_mutex` fields**

In `GatewayState` (around line 488–492), remove:
```zig
scheduler: ?*cron_mod.CronScheduler = null,   // remove
scheduler_mutex: std.Thread.Mutex = .{},       // remove
```

- [ ] **Step 3: Remove `GatewayState.run_queue` ArrayList and its deinit**

```zig
run_queue: std.ArrayListUnmanaged([]const u8) = .empty,  // remove
```
And in `GatewayState.deinit()`, remove the loop that frees `run_queue` items.

- [ ] **Step 4: Delete the global variables and all four global functions**

Delete:
```zig
var g_shared_scheduler: ?*cron_mod.CronScheduler = null;
var g_shared_scheduler_mutex: std.Thread.Mutex = .{};
pub fn setSharedScheduler(...) void { ... }
pub fn clearSharedScheduler() void { ... }
pub fn acquireSchedulerGuard() SchedulerGuard { ... }
const SchedulerGuard = struct { ... };
pub fn lockRequestScheduler(...) ?*cron_mod.CronScheduler { ... }
fn unlockRequestScheduler(...) void { ... }
```

- [ ] **Step 5: Remove the `scheduler_mutex` drain barrier in `gateway.run()`**

Find and remove the post-accept-loop block that acquires/releases `state.scheduler_mutex` to drain the guard. It's no longer needed.

- [ ] **Step 6: Build and fix compile errors**

```bash
zig build 2>&1 | grep error
```

All references to the deleted symbols will show as errors — fix each one (mostly in HTTP handlers and `runQueueWorker`, addressed in Tasks 3 and 4).

- [ ] **Step 7: Run tests**

```bash
zig build test --summary all 2>&1 | tail -5
```

- [ ] **Step 8: Commit**

```bash
git add src/gateway.zig && git commit -m "refactor(scheduler): remove global scheduler pointer and scheduler_mutex from GatewayState"
```

---

## Task 3: Simplify `runQueueWorker` to DB-direct only

**Files:** Modify `src/gateway.zig` — `runQueueWorker` function (~line 3278)

The worker currently has a DB-direct branch and a legacy in-memory branch. Delete the legacy branch entirely.

- [ ] **Step 1: Identify the legacy branch**

```bash
grep -n "Legacy in-memory\|run_queue\.items\|pop\|scheduler_mutex\|sched\.getJob\|dbUpsertAndVerify" src/gateway.zig | grep -v "cron_db_path\|DB-direct" | head -30
```

- [ ] **Step 2: Rewrite `runQueueWorker` — DB-direct only**

The new function body:

```zig
fn runQueueWorker(state: *GatewayState) void {
    const db_path = state.cron_db_path orelse {
        log.err("runQueueWorker: no cron_db_path, worker inactive", .{});
        return;
    };

    // Reset any jobs that were in-progress when the process last crashed.
    {
        const db = cron_mod.openCronDbAtPath(db_path) catch |err| {
            log.err("worker: could not open DB for reset: {s}", .{@errorName(err)});
            return;
        };
        defer cron_mod.closeCronDb(db);
        cron_mod.dbResetInProgressJobs(db) catch |err|
            log.warn("worker: reset in-progress failed: {s}", .{@errorName(err)});
    }

    while (true) {
        // Wait for signal or poll every 1s.
        {
            state.run_queue_mutex.lock();
            defer state.run_queue_mutex.unlock();
            if (state.run_queue_stop) return;
            _ = state.run_queue_cond.timedWait(&state.run_queue_mutex, std.time.ns_per_s) catch {};
            if (state.run_queue_stop) return;
        }

        // Drain all pending rows before sleeping again.
        while (true) {
            const db = cron_mod.openCronDbAtPath(db_path) catch |err| {
                log.err("worker: could not open DB: {s}", .{@errorName(err)});
                break;
            };
            defer cron_mod.closeCronDb(db);
            cron_mod.ensureRunQueueTable(db) catch {};

            const dequeued = cron_mod.dbDequeueNextJob(db, state.allocator) catch |err| {
                log.err("worker: dbDequeueNextJob failed: {s}", .{@errorName(err)});
                break;
            };
            const item = dequeued orelse break; // queue empty
            defer state.allocator.free(item.job_id);

            var job_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer job_arena.deinit();

            const spec = cron_mod.dbLoadJobSpec(db, job_arena.allocator(), item.job_id) catch |err| {
                log.err("[{s}] dbLoadJobSpec failed: {s}", .{ item.job_id, @errorName(err) });
                cron_mod.dbCompleteJob(db, item.job_id, item.queue_row_id, std.time.timestamp(), "error", null, false) catch {};
                continue;
            } orelse {
                log.warn("[{s}] job not found in DB, removing queue row", .{item.job_id});
                cron_mod.dbCompleteJob(db, item.job_id, item.queue_row_id, std.time.timestamp(), "error", null, false) catch {};
                continue;
            };

            log.info("running queued job '{s}'", .{item.job_id});
            // ... execute shell/agent, deliver, dbCompleteJob (keep existing execution code)
        }
    }
}
```

Key changes from the current implementation:
- Remove the `if (state.cron_db_path) |db_path|` branch wrapper — it's always DB-direct
- Remove legacy `else` branch (ArrayList pop, `sched.getJob`, `dbUpsertAndVerify` calls)
- Remove `state.run_queue_stop and state.run_queue.items.len == 0` stop check (replace with `state.run_queue_stop` only)
- Inner drain loop: keep calling `dbDequeueNextJob` until it returns null (drains all pending rows before sleeping)

- [ ] **Step 3: Build**

```bash
zig build 2>&1 | grep error
```

- [ ] **Step 4: Run tests**

```bash
zig build test --summary all 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add src/gateway.zig && git commit -m "refactor(scheduler): remove legacy in-memory branch from runQueueWorker"
```

---

## Task 4: Convert all HTTP handlers to DB-direct only

**Files:** Modify `src/gateway.zig` — all 8 cron handlers

Each handler currently has a DB-direct branch and a legacy fallback. Remove the legacy fallback from each.

### handleCronList (~line 2586)

- [ ] Remove the `used_db` flag, the `if (!used_db)` legacy block, keep only the DB-direct branch. If `cron_db_path` is null, return 503.

### handleCronAdd (~line 2643)

- [ ] Remove `lockRequestScheduler` / `unlockRequestScheduler` calls. Remove `sched.addJob` / `sched.addAgentJob` in-memory calls. Remove `saveJobs(sched)`.

Replace with a DB-direct add: parse fields, build a `CronJob` struct on the stack (or use a local arena), call `dbSaveJob` directly, return the job as JSON.

```zig
// After parsing all fields:
const db = cron_mod.openCronDbAtPath(db_path) catch {
    ctx.response_status = "500 Internal Server Error";
    ctx.response_body = "{\"error\":\"db unavailable\"}";
    return;
};
defer cron_mod.closeCronDb(db);
cron_mod.ensureCronTable(db) catch {};

// Build job directly:
const id = cron_mod.allocateJobId(ctx.req_allocator, job_type_prefix) catch { ... };
defer ctx.req_allocator.free(id);
const next_run = cron_mod.nextRunForCronExpression(expression, std.time.timestamp()) catch { ... };

var job = cron_mod.CronJob{
    .id = id,
    .expression = expression,
    .command = command_opt orelse "",
    .next_run_secs = next_run,
    .job_type = parsed_job_type,
    .delivery = delivery,  // already parsed from request
    // ... other fields
};
try cron_mod.dbSaveJobDirect(db, &job); // new pub fn wrapping dbSaveJob
// Return job JSON via dbGetJobOutputJson or inline serialisation
```

### handleCronRemove, handleCronPause, handleCronResume (~lines 2832, 2882, 2932)

- [ ] Remove `lockRequestScheduler`, `sched.removeJob` / `sched.pauseJob` / `sched.resumeJob`, `saveJobs`. Replace each with a direct SQL UPDATE/DELETE via a new thin DB helper or inline `sqlite3_exec`.

### handleCronUpdate (~line 2982)

- [ ] Remove `lockRequestScheduler`, `CronJobPatch`, `sched.updateJob`, `saveJobs`. Replace with direct SQL UPDATE of the changed columns.

### handleCronRun (~line 3070)

- [ ] Remove legacy `enqueueScheduledJob` path. Keep only the DB-direct insert into `cron_run_queue` + `signalRunQueueWorker`.

### handleCronOutput (~line 3151)

- [ ] Already DB-direct. Remove legacy fallback block.

- [ ] **After all handlers converted: build**

```bash
zig build 2>&1 | grep error
```

- [ ] **Run tests**

```bash
zig build test --summary all 2>&1 | tail -5
```

- [ ] **Commit**

```bash
git add src/gateway.zig && git commit -m "refactor(scheduler): all HTTP handlers now DB-direct, remove lockRequestScheduler"
```

---

## Task 5: Add missing DB helper functions to cron.zig

**Files:** Modify `src/cron.zig`

Task 4 needs a few thin pub functions that currently don't exist or are private.

- [ ] **Step 1: Make `dbSaveJob` pub** (currently `fn dbSaveJob` — just change to `pub fn`)

- [ ] **Step 2: Add `pub fn allocateJobId`** — extracts the ID generation logic out of `CronScheduler.allocateJobId` so handlers can call it without a scheduler:

```zig
pub fn allocateJobId(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    var rand_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    return std.fmt.allocPrint(allocator,
        "{s}-{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}", .{
        prefix,
        std.mem.readInt(u32, rand_bytes[0..4], .big),
        std.mem.readInt(u16, rand_bytes[4..6], .big),
        std.mem.readInt(u16, rand_bytes[6..8], .big),
        std.mem.readInt(u16, rand_bytes[8..10], .big),
        std.mem.readInt(u48, rand_bytes[10..16], .big),
    });
}
```

- [ ] **Step 3: Add `pub fn dbRemoveJob`, `pub fn dbPauseJob`, `pub fn dbResumeJob`**

Thin wrappers around direct SQL:

```zig
pub fn dbRemoveJob(db: *c.sqlite3, id: []const u8) !bool {
    // DELETE FROM cron_jobs WHERE id=?1
    // returns true if a row was deleted (sqlite3_changes > 0)
}

pub fn dbPauseJob(db: *c.sqlite3, id: []const u8) !bool {
    // UPDATE cron_jobs SET paused=1 WHERE id=?1
}

pub fn dbResumeJob(db: *c.sqlite3, id: []const u8) !bool {
    // UPDATE cron_jobs SET paused=0, enabled=1 WHERE id=?1
}
```

- [ ] **Step 4: Add `pub fn dbUpdateJob`** — applies a patch directly in SQL:

```zig
pub fn dbUpdateJob(db: *c.sqlite3, id: []const u8, patch: CronJobPatch) !bool {
    // Build dynamic UPDATE SET clause from non-null patch fields
    // Returns false if no rows matched (job not found)
}
```

- [ ] **Step 5: Add `pub fn dbGetJobJson`** — returns a single job as JSON for the add/update response:

```zig
pub fn dbGetJobJson(db: *c.sqlite3, id: []const u8, buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !bool {
    // SELECT same columns as dbListJobsJson but WHERE id=?1
    // Returns false if not found
}
```

- [ ] **Step 6: Write tests for each new function**

```zig
test "dbRemoveJob removes existing job" { ... }
test "dbRemoveJob returns false for missing job" { ... }
test "dbPauseJob sets paused=1" { ... }
test "dbResumeJob clears paused" { ... }
test "dbUpdateJob applies delivery_channel patch" { ... }
test "dbGetJobJson returns valid JSON for existing job" { ... }
```

- [ ] **Step 7: Build + test**

```bash
zig build test --summary all 2>&1 | tail -5
```

- [ ] **Step 8: Commit**

```bash
git add src/cron.zig && git commit -m "feat(cron): add dbRemoveJob, dbPauseJob, dbResumeJob, dbUpdateJob, dbGetJobJson, pub allocateJobId"
```

---

## Task 6: Remove remaining dead code and fix tests

**Files:** `src/cron.zig`, `src/gateway.zig`, `src/daemon.zig`

- [ ] **Step 1: Find dead symbols**

```bash
zig build 2>&1 | grep "unused\|never referenced"
grep -n "collectDueJobs\|SchedulerJobSnapshot\|buildSchedulerSnapshot\|mergeSchedulerTick\|enqueueScheduledJob" src/cron.zig src/daemon.zig src/gateway.zig
```

- [ ] **Step 2: Delete `collectDueJobs` from cron.zig** — it is the in-memory tick that caused the panic. Verify no tests call it:

```bash
grep -rn "collectDueJobs" src/
```

Delete the function and any tests referencing it.

- [ ] **Step 3: Delete `pub fn tick` from `CronScheduler`** if it has no remaining callers. Verify:

```bash
grep -rn "\.tick(" src/
```

If only test references remain, update those tests to use `dbTickAndEnqueue` instead.

- [ ] **Step 4: Update/remove tests that exercised old global wiring**

Search for tests that use `setSharedScheduler`, `g_shared_scheduler`, `lockRequestScheduler`, or `acquireSchedulerGuard`:

```bash
grep -n "setSharedScheduler\|g_shared_scheduler\|lockRequest\|acquireScheduler" src/
```

Delete or rewrite them.

- [ ] **Step 5: Final build + full test run**

```bash
zig build test --summary all 2>&1 | tail -5
```

Target: 0 new failures vs baseline (6077/6088 passed, 11 skipped).

- [ ] **Step 6: Final commit**

```bash
git add src/ && git commit -m "refactor(scheduler): remove dead legacy scheduler code (collectDueJobs, tick, SchedulerGuard)"
```

---

## Task 7: E2E verification

- [ ] **Step 1: Build release binary and bounce gateway**

```bash
zig build && bash ~/.nullclaw/bounce.sh && bash ~/.nullclaw/restore-seed.sh
```

- [ ] **Step 2: Run the delivery E2E test**

```bash
bash ~/.nullclaw/test-cron-delivery.sh
```

Expected: 5/5 PASS, Telegram message received.

- [ ] **Step 3: Check scheduler is ticking cleanly**

```bash
grep "scheduler\|cron_queue\|enqueued\|panic\|corrupt" ~/.nullclaw/gateway.log | tail -20
```

Expected: `scheduler: enqueued N job(s)` lines, zero panics.

- [ ] **Step 4: Verify cron_run_queue stays empty after drain**

```bash
python3 -c "
import sqlite3
db = sqlite3.connect('/home/yanggf/.nullclaw/cron.db')
print('queue rows:', db.execute('SELECT COUNT(*) FROM cron_run_queue').fetchone()[0])
"
```

Expected: 0 (all jobs drained after execution).

---

## Validation Checklist

Before declaring done:

- [ ] `zig build test --summary all` — same or better pass rate as baseline
- [ ] No `panic`, `corrupt`, `switch on corrupt` in gateway.log
- [ ] `scheduler: enqueued` appears in log each minute
- [ ] `test-cron-delivery.sh` passes 5/5
- [ ] Telegram message received during E2E test
- [ ] `cron_run_queue` empties after each tick cycle
- [ ] `restore-seed.sh` restores all 9 jobs with correct delivery config
- [ ] No reference to `g_shared_scheduler`, `lockRequestScheduler`, `SchedulerGuard`, `collectDueJobs` remains in production code paths
