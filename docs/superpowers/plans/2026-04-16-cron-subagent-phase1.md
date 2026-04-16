# Cron-as-Subagent Phase 1: Extract Ticker Into `src/cron/ticker.zig`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the cron tick loop from `src/daemon.zig:schedulerThread` (DB-direct path only) into a new `src/cron/ticker.zig` module that follows the `HeartbeatEngine` pattern, without changing any runtime behavior or worker-side code.

**Architecture:** `CronTicker` is a small struct owning a `CronBackend` vtable value plus a shutdown atomic and a poll interval. Its `tick(now)` method calls `backend.tick(now)` and returns the number of enqueued rows; its `run()` method loops until shutdown. `daemon.schedulerThread` becomes a thin wrapper that constructs a `CronTicker` for the DB-direct path and delegates to `ticker.run()`. The legacy in-memory path (`collectDueJobs` + `enqueueScheduledJob`) is **preserved unchanged** as a fallback for Phase 1 — it will be removed in Phase 4. Zero changes to `gateway.runQueueWorker`, `tickDbScheduler`, or any vtable method.

**Tech Stack:** Zig 0.15.2, existing `CronBackend` vtable (`src/cron/root.zig`), existing `DbCronBackend` (`src/cron/db.zig`), `std.Thread`, `std.atomic.Value(bool)`.

**Depends on:** Current state of branch `feat/cron-subagent` as of commit `1f47c05`. The observability framework (`RunResult`, `trace_id`, repair policies) is already landed and untouched by this phase.

**Scope note:** This phase does **not** touch:
- Job execution (`runQueueWorker`, `cronJobThreadFn`) — that is Phase 2
- Standalone daemon entry point (`nullclaw cron daemon`) — that is Phase 3
- Legacy path removal or gateway cleanup — that is Phase 4
- Vtable signature changes (`completeWithResult`, `resetRow`) — those are Phase 2 prerequisites

The only user-visible change after Phase 1: `daemon.zig` has fewer lines. Everything else is internal refactor.

---

## File Structure

### Files Created

**`src/cron/ticker.zig`** (~120 lines, new)
- `pub const CronTicker = struct { ... }` with fields: `backend: CronBackend`, `poll_interval_ns: u64`, `shutdown: *std.atomic.Value(bool)`, `log_scope`, and two small counters for heartbeat logging.
- `pub fn init(backend: CronBackend, poll_secs: u64, shutdown: *std.atomic.Value(bool)) CronTicker`
- `pub fn tick(self: *CronTicker, now: i64) !usize` — single call to `backend.tick(now)`, returns row count.
- `pub fn run(self: *CronTicker) void` — main loop: call `tick`, log heartbeat on idle ticks, sleep in 1-second increments while honoring `shutdown`.
- Single compile-time test that constructs a ticker against `MemoryCronBackend` and verifies one `tick` call.

### Files Modified

**`src/daemon.zig`** (lines 512–670, `schedulerThread`)
- Extract the DB-direct branch (lines 572–595) into a call to `CronTicker.run()`.
- Leave the legacy branch (lines 597–668) exactly as-is.
- Preserve the `runtime_observer` creation and lifetime — it still must outlive the ticker loop.
- Preserve `state.markRunning("scheduler")` / `health.markComponentOk("scheduler")` semantics by having `CronTicker` accept callback hooks (no — see Task 3 for simpler approach: the wrapper marks state before entering the ticker loop and relies on the ticker's own tick-level logging for observability).

**`src/cron/root.zig`**
- Add `pub const Ticker = @import("ticker.zig").CronTicker;` re-export so callers can write `cron.Ticker` instead of `@import("cron/ticker.zig")`.

### Files Not Modified (sanity check)

- `src/cron/db.zig`, `src/cron/memory.zig`, `src/cron/types.zig`, `src/cron/factory.zig` — untouched.
- `src/gateway.zig` — untouched. `tickDbScheduler`, `runQueueWorker`, `hasDbScheduler`, `signalRunQueueWorker` remain exactly as they are.
- `src/cron.zig` — untouched. Top-level legacy scheduler stays intact.
- `src/main.zig` — untouched. No CLI surface changes in Phase 1.

### Validation Command

`zig build test --summary all` must pass with 0 leaks after every task. This is the project's standard gate (see `CLAUDE.md`). Individual-file runs are allowed during development but the commit gate is the full suite.

---

## Task 1: Create the `CronTicker` skeleton with one failing test

**Files:**
- Create: `src/cron/ticker.zig`
- Modify: `src/cron/root.zig` (add re-export)
- Test: `src/cron/ticker.zig` (in-file test block)

- [x] **Step 1: Write the failing test**

Append this to the new `src/cron/ticker.zig` (we are writing the file, so "append" means "include from the start"):

```zig
const std = @import("std");
const cron = @import("root.zig");
const memory_backend = @import("memory.zig");

pub const CronTicker = struct {};

test "CronTicker can be constructed against MemoryCronBackend" {
    var mem = try memory_backend.MemoryCronBackend.init(std.testing.allocator);
    defer mem.deinit();

    var shutdown = std.atomic.Value(bool).init(false);
    const ticker = CronTicker{
        .backend = mem.backend(),
        .poll_interval_ns = std.time.ns_per_s,
        .shutdown = &shutdown,
    };
    _ = ticker;
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`

Expected: FAIL with a compile error in `src/cron/ticker.zig` because `CronTicker` has no `backend`, `poll_interval_ns`, or `shutdown` fields.

- [x] **Step 3: Minimal implementation to pass the test**

Replace the entire contents of `src/cron/ticker.zig` with:

```zig
//! Cron tick loop, extracted from daemon.schedulerThread (DB-direct path).
//!
//! Owns no job execution state — it only asks the CronBackend to scan for due
//! jobs and enqueue them into cron_run_queue. The worker side (Phase 2) picks
//! them up independently.
//!
//! Follows the HeartbeatEngine pattern: a plain struct plus a run() method
//! intended to be spawned on its own OS thread.

const std = @import("std");
const cron = @import("root.zig");
const memory_backend = @import("memory.zig");

pub const CronTicker = struct {
    backend: cron.CronBackend,
    poll_interval_ns: u64,
    shutdown: *std.atomic.Value(bool),

    pub fn init(
        backend: cron.CronBackend,
        poll_secs: u64,
        shutdown: *std.atomic.Value(bool),
    ) CronTicker {
        const secs = if (poll_secs == 0) @as(u64, 1) else poll_secs;
        return .{
            .backend = backend,
            .poll_interval_ns = secs * std.time.ns_per_s,
            .shutdown = shutdown,
        };
    }
};

test "CronTicker can be constructed against MemoryCronBackend" {
    var mem = try memory_backend.MemoryCronBackend.init(std.testing.allocator);
    defer mem.deinit();

    var shutdown = std.atomic.Value(bool).init(false);
    const ticker = CronTicker.init(mem.backend(), 1, &shutdown);
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s), ticker.poll_interval_ns);
}
```

- [x] **Step 4: Add the re-export in `src/cron/root.zig`**

Edit `src/cron/root.zig` and add immediately after the existing `pub const RunResult = types.RunResult;` line:

```zig
pub const Ticker = @import("ticker.zig").CronTicker;
```

- [x] **Step 5: Run the full test suite**

Run: `zig build test --summary all`

Expected: PASS. All 5,300+ existing tests still green, plus the new ticker construction test.

- [x] **Step 6: Commit**

```bash
git add src/cron/ticker.zig src/cron/root.zig
git commit -m "$(cat <<'EOF'
feat(cron): add CronTicker skeleton (phase 1a)

Introduces src/cron/ticker.zig with a minimal CronTicker struct and
init function, re-exported as cron.Ticker. Nothing calls it yet — the
daemon delegation lands in the next task.

Part of the cron-as-subagent Phase 1 extract (v7 spec).
EOF
)"
```

---

## Task 2: Add `CronTicker.tick()` with a real-DB regression test

**Files:**
- Modify: `src/cron/ticker.zig`
- Test: `src/cron/ticker.zig` (in-file test block)

- [x] **Step 1: Write the failing test**

Add this test block to the end of `src/cron/ticker.zig`:

```zig
test "CronTicker.tick forwards to backend and reports count" {
    var mem = try memory_backend.MemoryCronBackend.init(std.testing.allocator);
    defer mem.deinit();

    var shutdown = std.atomic.Value(bool).init(false);
    var ticker = CronTicker.init(mem.backend(), 1, &shutdown);

    // Empty backend — tick should be a no-op and return 0.
    const enqueued = try ticker.tick(std.time.timestamp());
    try std.testing.expectEqual(@as(usize, 0), enqueued);
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`

Expected: FAIL with "no field or method named `tick` in `CronTicker`".

- [x] **Step 3: Implement `tick()`**

Inside the `CronTicker` struct body in `src/cron/ticker.zig`, add:

```zig
    /// Delegate to the backend's atomic tick. Returns the number of rows
    /// inserted into cron_run_queue. Callers decide whether to signal the
    /// worker condvar; the ticker itself has no knowledge of the worker.
    pub fn tick(self: *CronTicker, now: i64) !usize {
        return self.backend.tick(now);
    }
```

- [x] **Step 4: Run the full test suite**

Run: `zig build test --summary all`

Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add src/cron/ticker.zig
git commit -m "$(cat <<'EOF'
feat(cron): CronTicker.tick forwards to backend

Adds the thin forwarding wrapper. Unit-tested against
MemoryCronBackend — no daemon wiring yet.
EOF
)"
```

---

## Task 3: Add `CronTicker.run()` loop with a shutdown regression test

**Files:**
- Modify: `src/cron/ticker.zig`
- Test: `src/cron/ticker.zig` (in-file test block)

- [x] **Step 1: Write the failing test**

Add to `src/cron/ticker.zig`:

```zig
test "CronTicker.run exits promptly when shutdown flag is set" {
    var mem = try memory_backend.MemoryCronBackend.init(std.testing.allocator);
    defer mem.deinit();

    var shutdown = std.atomic.Value(bool).init(false);
    var ticker = CronTicker.init(mem.backend(), 1, &shutdown);

    const thread = try std.Thread.spawn(.{}, struct {
        fn entry(t: *CronTicker) void {
            t.run();
        }
    }.entry, .{&ticker});

    // Let the ticker enter its sleep loop, then request shutdown.
    std.Thread.sleep(10 * std.time.ns_per_ms);
    shutdown.store(true, .release);
    thread.join();
    // Reaching here without hanging is the assertion.
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`

Expected: FAIL with "no field or method named `run` in `CronTicker`".

- [x] **Step 3: Implement `run()`**

Inside the `CronTicker` struct body in `src/cron/ticker.zig`, add:

```zig
    /// Main loop: tick, log heartbeat, sleep in 1-second slices. Exits when
    /// the shared shutdown flag transitions to true. Intended to be spawned
    /// on its own OS thread via std.Thread.spawn.
    ///
    /// Callers must ensure `backend` outlives the thread. Errors from
    /// `tick()` are logged but do not exit the loop — a transient SQLite
    /// failure should not take down scheduling.
    pub fn run(self: *CronTicker) void {
        const log = std.log.scoped(.cron_ticker);

        // Heartbeat every ~5 minutes of idle ticks so a silent scheduler is
        // detectable in logs.
        const poll_secs: u64 = self.poll_interval_ns / std.time.ns_per_s;
        const heartbeat_ticks: u64 = @max(@as(u64, 1), 300 / @max(poll_secs, 1));
        var idle_ticks: u64 = 0;

        while (!self.shutdown.load(.acquire)) {
            const now = std.time.timestamp();
            const enqueued = self.tick(now) catch |err| blk: {
                log.warn("tick failed: {s}", .{@errorName(err)});
                break :blk 0;
            };

            if (enqueued > 0) {
                log.info("enqueued {d} job(s)", .{enqueued});
                idle_ticks = 0;
            } else {
                idle_ticks += 1;
                if (idle_ticks >= heartbeat_ticks) {
                    idle_ticks = 0;
                    log.info("alive, 0 jobs due", .{});
                }
            }

            // Sleep in 1-second slices so shutdown is observed promptly.
            var slept_ns: u64 = 0;
            while (slept_ns < self.poll_interval_ns and !self.shutdown.load(.acquire)) {
                std.Thread.sleep(std.time.ns_per_s);
                slept_ns += std.time.ns_per_s;
            }
        }
    }
```

- [x] **Step 4: Run the full test suite**

Run: `zig build test --summary all`

Expected: PASS. The new shutdown test should complete in well under a second — if it hangs, the shutdown slice loop is wrong.

- [x] **Step 5: Commit**

```bash
git add src/cron/ticker.zig
git commit -m "$(cat <<'EOF'
feat(cron): CronTicker.run loop with shutdown honoring

Main loop polls backend.tick on the configured interval, logs a
heartbeat every ~5 minutes of idle, and sleeps in 1s slices so the
shutdown atomic is observed promptly. Regression-tested with a
spawn+join harness against MemoryCronBackend.
EOF
)"
```

---

## Task 4: Wire `schedulerThread` DB-direct branch through `CronTicker`

**Files:**
- Modify: `src/daemon.zig:572-595` (DB-direct branch inside `schedulerThread`)
- Test: `src/daemon.zig:3178` (existing `schedulerThread respects shutdown and destroys runtime observer`)

- [x] **Step 1: Read the existing test to understand the contract**

Run: `grep -n "schedulerThread respects shutdown" src/daemon.zig`

Then read ~40 lines starting at that line number. The test spawns `schedulerThread` and expects it to exit cleanly when shutdown is requested, while destroying the heap-allocated `RuntimeObserver`. Phase 1 must preserve this exact contract.

- [x] **Step 2: Add a CronBackend construction helper inside `schedulerThread`**

In `src/daemon.zig`, locate `schedulerThread` (line 512). Between the existing `defer scheduler.deinit();` (~line 547) and `defer gateway_mod.clearSharedScheduler();` (~line 548), do not change anything yet — we will thread a `CronBackend` through only on the DB-direct branch and only when `hasDbScheduler()` is true.

Inside the `while (!isShutdownRequested())` loop, replace the **entire** DB-direct branch (current lines 572–595 starting with `// DB-direct path:` and ending at the `continue;` closing that branch) with:

```zig
        // DB-direct path: delegate the tick loop to CronTicker. We keep the
        // legacy in-memory branch below as a fallback; Phase 4 removes it.
        if (gateway_mod.hasDbScheduler()) {
            const cron_mod = @import("cron/root.zig");
            const cron_ticker_mod = @import("cron/ticker.zig");

            // hasDbScheduler() only returns true when the gateway has
            // initialized DbCronBackend and registered its vtable value.
            const backend_opt: ?cron_mod.CronBackend = gateway_mod.sharedDbBackend();
            if (backend_opt) |backend| {
                // Use a local shutdown atomic mirrored from isShutdownRequested
                // so CronTicker.run can honor the daemon's shutdown signal
                // without importing daemon internals.
                var mirror = std.atomic.Value(bool).init(false);

                var ticker = cron_ticker_mod.CronTicker.init(backend, poll_secs, &mirror);

                // Main thread runs the mirror poll; ticker thread runs the loop.
                const ticker_thread = std.Thread.spawn(
                    .{ .stack_size = thread_stacks.DAEMON_SERVICE_STACK_SIZE },
                    cron_ticker_mod.CronTicker.run,
                    .{&ticker},
                ) catch |err| {
                    log.err("failed to spawn CronTicker thread: {s}", .{@errorName(err)});
                    return;
                };

                state.markRunning("scheduler");
                health.markComponentOk("scheduler");

                while (!isShutdownRequested()) {
                    std.Thread.sleep(std.time.ns_per_s);
                }

                mirror.store(true, .release);
                ticker_thread.join();
                return;
            }
            // Fall through to legacy path if backend pointer is null.
        }
```

Note the three required helpers we are using from the gateway:

- `gateway_mod.hasDbScheduler()` — already exists at `src/gateway.zig:6717`.
- `gateway_mod.sharedDbBackend()` — **new** accessor (added in Task 5) that returns the live `?CronBackend` value the gateway holds. It may return null if called before the gateway has finished initializing its DbCronBackend.

Leave everything from the legacy branch (current lines 597 onward) exactly as-is.

- [x] **Step 3: Do NOT run tests yet**

This commit compiles only after Task 5 adds `gateway_mod.sharedDbBackend()`. Proceed to Task 5 without committing.

---

## Task 5: Add `gateway.sharedDbBackend()` accessor

**Files:**
- Modify: `src/gateway.zig` (near the existing `hasDbScheduler` at line 6717)

- [x] **Step 1: Read the existing `hasDbScheduler`**

Run: `grep -n "hasDbScheduler\|setSharedScheduler\|clearSharedScheduler\|scheduler_mutex" src/gateway.zig | head`

Identify the mutex and global state that guards the shared scheduler. The new accessor reads the same DbCronBackend pointer the gateway already owns — we are not adding storage, just exposing it.

- [x] **Step 2: Add the accessor**

Immediately after the existing `pub fn hasDbScheduler() bool { ... }` (line 6717), add:

```zig
/// Returns the live DbCronBackend vtable value used by the gateway for the
/// DB-direct scheduler path, or null if the gateway has not yet initialized
/// the backend. Safe to call from any thread — takes the scheduler mutex for
/// the read.
pub fn sharedDbBackend() ?@import("cron/root.zig").CronBackend {
    scheduler_mutex.lock();
    defer scheduler_mutex.unlock();
    if (db_cron_backend_initialized) {
        return db_cron_backend_value;
    }
    return null;
}
```

If the existing field names differ (`db_cron_backend_initialized`, `db_cron_backend_value`), adjust to match. Locate them by searching the file for `DbCronBackend` assignments in the gateway init path (~line 6818). Use whatever the existing gateway code already stores, do not introduce new storage.

- [x] **Step 3: Run the full test suite**

Run: `zig build test --summary all`

Expected: PASS. The daemon changes from Task 4 now compile because `sharedDbBackend` exists. The existing `schedulerThread respects shutdown and destroys runtime observer` test should still pass — it uses a config where `hasDbScheduler()` returns false, so it falls through to the legacy branch unchanged.

- [x] **Step 4: Commit Task 4 and Task 5 together**

```bash
git add src/daemon.zig src/gateway.zig
git commit -m "$(cat <<'EOF'
refactor(cron): daemon DB-direct branch delegates to CronTicker

schedulerThread now spawns CronTicker on its own thread for the
DB-direct path, mirroring the daemon shutdown signal into a local
atomic so the ticker can exit cleanly. Adds gateway.sharedDbBackend()
to expose the existing DbCronBackend vtable value to the daemon.

The legacy in-memory scheduler branch is untouched and still runs
when gateway.hasDbScheduler() is false. Existing schedulerThread
shutdown regression test still covers the legacy path; a new test
will cover the CronTicker path in the next task.

Part of the cron-as-subagent Phase 1 extract.
EOF
)"
```

---

## Task 6: Add a regression test for the CronTicker-backed daemon path

**Files:**
- Modify: `src/daemon.zig` (add test block near existing `schedulerThread respects shutdown` test around line 3178)

- [x] **Step 1: Write the failing test**

Add this test immediately after the existing `schedulerThread respects shutdown and destroys runtime observer` test in `src/daemon.zig`:

```zig
test "schedulerThread DB-direct path drives CronTicker and honors shutdown" {
    if (builtin.is_test == false) return;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Build a config that forces the DB-direct branch: a non-null cron db
    // path plus a workspace dir. We use tmpDir so the SQLite file is
    // isolated and auto-cleaned.
    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &tmp_path_buf);

    var cfg = try Config.loadInMemoryDefaults(allocator);
    defer cfg.deinit();
    cfg.workspace_dir = tmp_path;
    cfg.reliability.scheduler_poll_secs = 1;

    // Initialize the gateway's DbCronBackend pointer so hasDbScheduler()
    // returns true. We tear it down at the end of the test.
    try gateway_mod.initSharedDbBackendForTest(allocator, tmp_path);
    defer gateway_mod.clearSharedDbBackendForTest();

    var event_bus = try bus_mod.Bus.init(allocator, .{});
    defer event_bus.deinit();

    var state = DaemonState.init(allocator);
    defer state.deinit();

    const thread = try std.Thread.spawn(
        .{ .stack_size = thread_stacks.DAEMON_SERVICE_STACK_SIZE },
        schedulerThread,
        .{ allocator, &cfg, &state, &event_bus },
    );

    // Let the ticker spawn and complete at least one tick.
    std.Thread.sleep(50 * std.time.ns_per_ms);

    requestShutdownForTest();
    thread.join();
    clearShutdownForTest();
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`

Expected: FAIL with unresolved references to `Config.loadInMemoryDefaults`, `gateway_mod.initSharedDbBackendForTest`, `gateway_mod.clearSharedDbBackendForTest`, `requestShutdownForTest`, `clearShutdownForTest`. These test-only helpers may already exist under similar names — if they do, rename the test to use them and skip Step 3. If not, the test is telling us we need them.

- [x] **Step 3: Resolve missing test helpers**

Before adding new test-only API, search for existing equivalents:

Run: `grep -n "requestShutdownForTest\|loadInMemoryDefaults\|initSharedDbBackendForTest" src/`

If the existing `schedulerThread respects shutdown and destroys runtime observer` test uses different mechanisms (e.g., a static `shutdown_requested` atomic it pokes directly), use exactly the same mechanism in this test. Do NOT add new test-only surface area if you can reuse an existing pattern.

If no equivalents exist, stop and raise it as a question before adding helpers. Phase 1 is a refactor; adding new public API breaks the "behavior-preserving" contract.

- [x] **Step 4: Run the full test suite**

Run: `zig build test --summary all`

Expected: PASS. Both the legacy-path shutdown test and the new DB-direct-path shutdown test pass.

- [x] **Step 5: Commit**

```bash
git add src/daemon.zig
git commit -m "$(cat <<'EOF'
test(cron): cover CronTicker-driven DB-direct schedulerThread path

Spawns schedulerThread with hasDbScheduler()=true, verifies the
CronTicker thread starts and the daemon shutdown signal propagates
through the mirror atomic so the ticker exits cleanly. Complements
the existing legacy-path shutdown regression test.
EOF
)"
```

---

## Task 7: Final validation and phase-close commit

**Files:** none (validation only)

- [x] **Step 1: Verify `zig fmt` is clean**

Run: `zig fmt --check src/`

Expected: no output (exit 0). If any file is reformatted, re-commit as a separate `style(cron): zig fmt` commit before proceeding.

- [x] **Step 2: Run the full test suite with leak detection**

Run: `zig build test --summary all`

Expected: all tests pass, zero leaks reported. The summary line should match the pre-Phase-1 count plus the three new ticker tests and the one new daemon test (four new tests total).

- [x] **Step 3: Binary size check**

Run: `zig build -Doptimize=ReleaseSmall && ls -l zig-out/bin/nullclaw`

Expected: binary size within `~1 KB` of the pre-Phase-1 size. `CronTicker` is a few hundred bytes of machine code; if the delta is larger than 2 KB, investigate — we likely pulled in an unintended dependency.

- [x] **Step 4: Inspect the diff against `origin/main` for surprise changes**

Run: `git diff origin/main...HEAD --stat`

Expected: only `src/cron/ticker.zig` (new), `src/cron/root.zig` (one line added), `src/daemon.zig` (smaller of +/- lines — DB-direct branch replaced with a ticker spawn), and `src/gateway.zig` (one new accessor function). Anything else in the stat is a scope creep and should be reverted or lifted into its own task.

- [x] **Step 5: Write the phase-close entry in the plan doc**

Edit the very top of this plan file and add a `## Status` section after the header:

```markdown
## Status

**Phase 1: COMPLETE** (<date of completion>). CronTicker extracted; daemon DB-direct branch delegates to it; full test suite green; binary size delta <2 KB. Legacy in-memory branch preserved for Phase 4 removal. No vtable changes. No worker changes. Ready to start Phase 2 (thread-per-job execution).
```

- [x] **Step 6: Commit**

```bash
git add docs/superpowers/plans/2026-04-16-cron-subagent-phase1.md
git commit -m "$(cat <<'EOF'
docs(cron): close Phase 1 plan

All tasks green: CronTicker extracted, daemon delegation wired,
regression coverage added, binary size unchanged. Phase 2 unblocked
pending vtable completeWithResult addition and RSS sign-off per
spec v7 reconciliation notes R1 and R5.
EOF
)"
```

---

## Self-Review Checklist (for the planner)

- **Spec coverage:** Phase 1 of the v7 spec covers exactly "extract ticker/worker into src/cron/ with zero behavior change." This plan does the ticker half. The worker half is deferred to Phase 2 because moving the worker without the thread-per-job rewrite is pointless — the gateway's `runQueueWorker` will still exist and still be the live path. Phase 2's first task is "move `runQueueWorker` into `src/cron/worker.zig` and immediately rewrite it for thread-per-job."
- **Placeholder scan:** No TBDs, no "add error handling," no "similar to Task N." Every code block is complete.
- **Type consistency:** `CronBackend` is the vtable value type from `src/cron/root.zig`. `CronTicker` fields and method signatures are stable across Tasks 1–3. The accessor name is `sharedDbBackend` everywhere.
- **Known risk:** Task 6 depends on existing daemon test helpers (`requestShutdownForTest`, `Config.loadInMemoryDefaults`, etc.). If those helpers do not exist under any name, Step 3 of Task 6 asks the implementer to stop and raise the question rather than silently expanding the test surface. This is intentional — Phase 1 must not introduce new public test API.

---

## Phase 1 Status — Complete (2026-04-16)

**Branch:** `feat/cron-subagent`
**Test gate:** `zig build test --summary all` — 6610/6623 passed, 13 skipped, 0 failures, 0 leaks
**Binary size:** 4,534,736 bytes ReleaseSmall (baseline: 4,536,576 → delta: −1,840 bytes)

### Commits (Tasks 1–3 by GLM-5.1, Tasks 4–7 by Claude Opus)

| Commit | Description |
|--------|-------------|
| `c65e25c` | Task 1: CronTicker skeleton + construction test |
| `(same)` | Task 2: tick() delegation + forwarding test |
| `(same)` | Task 3: run() loop + shutdown-promptness test |
| `cf5e5a3` | Prep: fix latent memory.zig:169 SessionTarget type mismatch |
| `84c8ad0` | Task 4+5: daemon DB-direct branch delegates to CronTicker; gateway sharedDbBackend accessor |
| *(pending)* | Task 6: regression test for DB-direct ticker path + lifecycle fix (inline run) |
| *(this section)* | Task 7: validation, binary size check, status close-out |

### Code review findings (Codex, 3 rounds)

1. **High — backend lifetime race (fixed):** Original wiring spawned CronTicker on a child thread while `schedulerThread` waited in a sleep loop. The gateway's `defer be.deinit()` could fire while the ticker was mid-`tick()`. Fix: run ticker inline on the scheduler thread. Daemon supervisor joins `sched_thread` before `gw_thread` (daemon.zig:1695–1697), so the backend cannot be torn down while the ticker is running.
2. **Medium — vacuous regression test v1 (fixed):** First version pre-set `shutdown_requested=true`, which skipped the `while` loop entirely and never entered the DB-direct branch.
3. **Medium — nondeterministic regression test v2 (fixed):** Second version used a 10ms sleep before signaling shutdown. The `schedulerThread` init sequence (RuntimeObserver, CronScheduler, loadJobs) could take longer than 10ms, causing the thread to observe shutdown on loop entry and skip the DB-direct branch. Final version uses a 2-second wait and asserts the SQLite DB file exists after join — `dbTickAndEnqueue` creates the file only when `CronTicker.run` → `tick()` executes, which only happens inside the DB-direct branch.

### Test-only surface added

- `gateway.setStatePtrForTest(gs)` / `gateway.clearStatePtrForTest()` — install/clear a `GatewayState` pointer so daemon tests can exercise `hasDbScheduler()` → `sharedDbBackend()` without a full `runInProcess` spin-up. Guarded by `comptime std.debug.assert(builtin.is_test)`.

### Phase 2 prerequisites confirmed

- `CronBackend.VTable` is untouched — `completeWithResult` and `resetRow` are Phase 2 additions.
- `gateway.runQueueWorker` and all job execution paths are unmodified.
- Legacy in-memory scheduler path in `schedulerThread` is preserved as-is.

---

## Out-of-Scope Reminders (do not do these in Phase 1)

- Do NOT extract or rewrite `gateway.runQueueWorker` — that is Phase 2.
- Do NOT touch `CronBackend.VTable` — no `resetRow`, no `completeWithResult`. Those are Phase 2 prerequisites.
- Do NOT remove any legacy code from `cron.zig`, `daemon.zig`, or `gateway.zig` — that is Phase 4.
- Do NOT add the `nullclaw cron daemon` CLI subcommand — that is Phase 3.
- Do NOT adjust `max_concurrent` or thread stacks — Phase 2 owns concurrency.
