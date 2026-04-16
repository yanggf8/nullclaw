# Cron-as-Subagent: Standalone Daemon with Bus-Driven Execution

**Date**: 2026-04-16
**Status**: Draft v7
**Scope**: Decouple cron scheduling and execution from the gateway. Cron jobs execute as spawned sub-agent threads, using the bus outbound queue for delivery only.

**Changelog**:
- v7 (2026-04-16): Reconcile with observability framework that landed 2026-04-11 to 2026-04-15. Vtable `complete()` signature currently does NOT carry `RunResult`/`trace_id`; the observability-rich write path lives in the free function `dbCompleteJob` in `src/cron.zig`. Phase 2 must widen the vtable (or add a `completeWithResult` method) before the job thread can call it without regressing observability. Fix `DequeueResult` ownership note: the struct does not carry an arena — `CronBackend.dequeue(allocator)` writes into the caller-supplied allocator, so each worker-side dispatch creates a per-job arena before `dequeue` and transfers it to the `JobContext`. Scope the minimum viable channel-registry init path as an open question (not punt). Record test-migration plan for legacy `schedulerThread` tests in `src/daemon.zig`. Flag RSS budget (~12–14 MiB) as needing explicit sign-off vs the repo-wide ~1 MiB principle in `CLAUDE.md`.
- v6 (2026-03-27): Fix CompletionFn signature, add mutual exclusion protocol, fix arena ownership, fix ticker/worker mutex interaction, address one-shot race, add graceful shutdown, fix SubagentManager comparison, add channel registry for standalone daemon, expand Phase 4 dead code list, add daemon health/observability.
- v5 (2026-03-26): Fix cross-process wakeup, lease TOCTOU, RSS target.

---

## v7 Reconciliation Notes (Read First)

These items reflect the codebase as of 2026-04-16 on branch `feat/cron-subagent`. They override any conflicting text later in the document.

### R1. Vtable `complete()` vs observability-rich write path

Current `CronBackend.VTable.complete` (`src/cron/root.zig:85`) takes 7 args — exactly what this spec describes elsewhere:

```zig
complete: *const fn (
    ptr: *anyopaque,
    id: []const u8,
    row_id: i64,
    now: i64,
    status: []const u8,
    output: ?[]const u8,
    delivered: bool,
) anyerror!void,
```

However, the observability framework that landed in `feat/cron-subagent` (commits `3ff18d8`, `d833a3e`, `acc9a5b`, `4818066`, `5c4e2e6`) persists **much more** than status+output+delivered: `RunResult` (failure_class, verified, exit_code, duration_ms), `trace_id`, `repair_action`, `source`, `manual`. That write path is **not** on the vtable — it is the free function `dbCompleteJob` in `src/cron.zig` (referenced from `src/cron.zig:5045`, `:5268`, `:5287`, `:5336`, etc.).

**Implication for Phase 2**: If the job thread calls `backend.complete(...)` as written in this spec, it regresses every observability column. Before Phase 2 can start, we must either:

- **Option A (preferred)**: Add a new vtable method `completeWithResult` that takes `RunResult`, `trace_id`, `manual`, and `source`, implemented in `db.zig` by delegating to (or replacing) `dbCompleteJob`. Keep the 7-arg `complete` as a thin wrapper for callers that don't care. Update `memory.zig` accordingly.
- **Option B**: Extend the existing `complete` with an additional `run_result: ?RunResult`, `trace_id: ?[]const u8`, `manual: bool`, `source: []const u8` tail and update all callers.

Option A is less invasive and keeps the existing 7-arg signature valid for any call sites that only need status/output. Implementation of Option A is a prerequisite for Phase 2 and belongs in a small preparatory step.

### R2. `DequeueResult` does not own an arena

`src/cron/types.zig:253`:

```zig
pub const DequeueResult = struct {
    queue_row_id: i64,
    spec: CronJobSpec,
};
```

The vtable signature is `dequeue(ptr, allocator) !?DequeueResult` — strings are written into the **caller-supplied** allocator, and the caller frees them. There is no arena embedded in `DequeueResult`.

**Corrected ownership model for Phase 2**:

1. `CronWorker.drainQueue()` creates a fresh `std.heap.ArenaAllocator` from the long-lived daemon GPA **before** calling `dequeue`.
2. It calls `backend.dequeue(arena.allocator())`. If null, deinit the arena and break.
3. On success, it builds a `JobContext` that **owns** the arena (`arena: std.heap.ArenaAllocator`, passed by value).
4. The job thread calls `defer ctx.arena.deinit()` as its first statement.
5. If `trySpawnJob` fails, the worker calls `arena.deinit()` and then `backend.resetRow(row_id)` so the row can be re-claimed cleanly.

This also resolves what "arena transferred to job thread" means in practice — it's a move of the `ArenaAllocator` struct itself, not a pointer handoff. No thread frees an arena it did not originate.

### R3. Channel registry minimal init — still an open question

Phase 3 claims the daemon can "reuse `channels/root.zig` channel factory." Today `src/channels/root.zig` is invoked from `gateway.zig` with a full `GatewayState` / `Config` graph. A true standalone daemon needs a minimum viable init path that:

- Takes only a `*const Config` and an allocator.
- Returns a `std.StringArrayHashMap(Channel)` keyed by channel name.
- Handles only the channels selected at build time via `-Dchannels=…`.

Specifying this is a **blocker for Phase 3** and should be done as a follow-up spec (`docs/superpowers/specs/2026-04-16-cron-daemon-channel-registry.md`) before Phase 3 is handed to any implementer. Phase 1 and Phase 2 do not need this resolved.

### R4. Legacy test migration

`src/daemon.zig` contains tests that depend on `schedulerThread` (see `src/daemon.zig:3178`, `:3200`). Phase 4's cleanup deletes the legacy in-memory path those tests exercise. Before Phase 4:

- Identify every test that spawns `schedulerThread` directly or asserts on `collectDueJobs` / `enqueueScheduledJob`.
- Port them to drive `CronTicker` and `CronWorker` directly (they are designed to be injectable).
- Preserve the shutdown/RuntimeObserver regression coverage (`schedulerThread respects shutdown and destroys runtime observer`) by replicating it against the new `CronWorker.run` loop.

### R5. RSS budget vs `~1 MiB` CLAUDE.md principle — explicit sign-off required

The daemon's projected RSS is 12–14 MiB (4 job threads × 2 MiB `HEAVY_RUNTIME_STACK_SIZE` + 3 infra threads + SQLite/arenas/bus). `CLAUDE.md` states "Hard constraints: 678 KB binary, ~1 MB peak RSS." The daemon intentionally trades memory for concurrency.

**Required**: Before Phase 2 lands, get explicit sign-off on relaxing the RSS target for the `nullclaw cron daemon` subcommand specifically (not for the main binary). Two viable stances:

- **Accept**: Document that the daemon is exempt from the 1 MiB RSS target and record the accepted ceiling (e.g. 16 MiB).
- **Reduce**: Lower `max_concurrent` default to 2 and/or use default stacks for skill/shell jobs, reserving `HEAVY_RUNTIME_STACK_SIZE` only for `job_type=agent`. This brings the ceiling closer to 6–8 MiB.

The spec currently assumes "Accept." Confirm before Phase 2.

---

## Problem

The cron system is embedded inside the gateway HTTP process:

1. **Gateway is a single point of failure** — port-binding issues, restart loops, and missed jobs during bounces.
2. **Gateway is security-sensitive** — an HTTP endpoint that should not be required for scheduled task execution.
3. **Testing requires wall-clock waits** — no way to fire a job and observe the result without sleeping 1+ minutes.
4. **The event bus is ignored** — `schedulerThread` receives `event_bus` but discards it (`_ = event_bus`). The bus exists but is underutilized.

### Current Thread Layout (all gateway-coupled)

| Thread | Location | Interval | Gateway Dependency |
|--------|----------|----------|-------------------|
| `schedulerThread` | daemon.zig:473 | `scheduler_poll_secs` | Calls `gateway.tickDbScheduler()` via DB path, or legacy `collectDueJobs` via in-memory scheduler |
| `runQueueWorker` | gateway.zig:3535 | 1s timedWait | Lives inside gateway.zig, uses `GatewayState` mutexes |
| `heartbeatThread` | daemon.zig:226 | `interval_minutes` | **None** — standalone struct, clean pattern to follow |

### Current Codebase State

The following already exists and will be preserved/adapted:

- **CronBackend vtable** (`src/cron/root.zig`): `tick`, `add`, `remove`, `pause`, `resumeJob`, `update`, `get`, `listRows`, `getOutput`, `enqueue`, `dequeue`, `complete`, `resetInProgress`
- **DbCronBackend** (`src/cron/db.zig`): SQLite implementation, each vtable method opens its own DB connection (thread-safe)
- **MemoryCronBackend** (`src/cron/memory.zig`): In-memory implementation for testing
- **Domain types** (`src/cron/types.zig`): `CronJobSpec`, `DequeueResult`, `NewJobSpec`, etc.
- **DB schema**: `cron_jobs` and `cron_run_queue` tables with atomic dequeue+claim
- **Delivery system** (`cron.zig:deliverResult`): Routes via `bus.publishOutbound()`
- **Crash recovery**: `dbResetInProgressJobs()` resets in-progress rows on startup
- **Config**: `SchedulerConfig.max_concurrent = 4` exists in `config_types.zig` but is **unused** — the current worker is single-threaded

## Design Principle

**A cron job is a sub-agent.** It receives a task, executes autonomously in its own OS thread, delivers its own results, and reports completion. This follows the SubagentManager spawn pattern — not the inbound message dispatcher.

### Why NOT InboundMessage

The inbound dispatcher (`daemon.zig:942`) processes messages **sequentially**:

```zig
while (bus.consumeInbound()) |msg| {
    session_mgr.processMessageStreaming(session_key, ...);
    // ^^^ BLOCKS until agent turn completes (could be 30s+)
}
```

If cron posted InboundMessages to the bus, a 30-second skill job would block all user messages for 30 seconds. This is unacceptable.

`SubagentManager` solves this by **not using the inbound bus for work dispatch**. It spawns OS threads directly. The bus is used only for posting results back. Cron follows the same pattern.

## Architecture

### Current Flow (gateway-coupled)

```
daemon.schedulerThread
  → gateway.tickDbScheduler() (DB path, signals condvar)
  → SQLite: scan due jobs, INSERT into cron_run_queue
  → gateway.runQueueWorker (1s timedWait poll loop)
    → dequeue from cron_run_queue (atomic claim)
    → execute subprocess directly (BLOCKS worker thread — single-threaded)
    → deliverResult via bus.publishOutbound
```

### New Flow (thread-per-job, like SubagentManager)

```
CronTicker (timer thread)
  → tick(now): SQLite scan + enqueue to cron_run_queue
  → signal_cond.signal()  ← separate from worker_mutex

CronWorker (reactive, condvar + timedWait)
  → worker_mutex.lock()
  → check signal_flag, reset it
  → worker_mutex.unlock()
  → drain cron_run_queue (mutex-free, SQLite atomic dequeue):
      → dequeue job spec
      → try spawn OS thread for this job
      → if spawn fails: resetRow(queue_row_id), continue
      → if at capacity: stop draining, wait for slot
  → worker_mutex.lock() → timedWait(1s) → repeat

Job Thread (spawned per job, like subagentThreadFn)
  → resolve skill → run subprocess with timeout
  → complete() callback → DB update (last_run, last_status, last_output)
  → bus.publishOutbound(delivery message) → channel dispatch
  → thread exits → signals capacity_cond
```

### Decoupled Ticker Signaling

**Key change from v5**: The ticker does NOT hold `worker_mutex` to signal. Instead, the ticker sets a flag and signals a separate condvar. This prevents the ticker from blocking when the worker is at capacity.

```
CronTicker (timer)              CronWorker                     Job Threads
    │                                │
    ├─ sleep(poll_secs)              ├─ lock(worker_mutex)
    ├─ tick → 3 jobs enqueued        ├─ check signal_flag → false
    │                                ├─ timedWait(worker_mutex, 1s) ← blocks
    ├─ lock(signal_mutex)            │
    ├─ signal_flag = true            │
    ├─ signal_cond.signal() ─────────▶ wakes instantly
    ├─ unlock(signal_mutex)          ├─ unlock(worker_mutex)
    │                                ├─ dequeue job 1 → spawn ──────▶ [thread 1]
    │                                ├─ dequeue job 2 → spawn ──────▶ [thread 2]
    │                                ├─ dequeue job 3 → spawn ──────▶ [thread 3]
    │                                ├─ dequeue → null (empty)
    ├─ sleep(poll_secs)              ├─ lock(worker_mutex)
    │                                ├─ check signal_flag → false
    │                                ├─ timedWait(1s) ← blocks
    │                                │                         [thread 1: complete]
    │                                │                         [thread 2: complete]
    │                                │                         [thread 3: complete]

External enqueue (CLI/gateway):
    nullclaw cron run <id>
      → backend.enqueue(id, now)   (no condvar signal — cross-process)
      → worker wakes within ≤1s via timedWait timeout
      → dequeues and spawns as normal
```

The 1-second `timedWait` is negligible overhead (one mutex lock + flag check per second when idle) and eliminates the need for any cross-process signaling mechanism. Scheduled jobs get near-instant wakeup via the separate signal condvar from CronTicker.

### SubagentManager Comparison

| Aspect | SubagentManager | Cron Worker |
|--------|-----------------|-------------|
| Trigger | Agent tool call (`spawn`) | CronTicker signal + timedWait |
| Dispatch | `std.Thread.spawn(subagentThreadFn)` | `std.Thread.spawn(cronJobThreadFn)` |
| Execution | LLM agent loop on spawned thread | Skill subprocess on spawned thread |
| Concurrency | `max_concurrent = 4` | `max_concurrent` (configurable) |
| Result delivery | `bus.publishInbound()` (notifies parent agent) | `bus.publishOutbound()` (channel delivery) |
| Completion | `completeTask()` → update in-memory state | `complete()` → update SQLite |
| Bus usage | **Inbound** (result → parent agent session) | **Outbound only** (result → Telegram/Discord) |

**Key difference**: SubagentManager posts results to the **inbound** bus as system messages to notify the parent agent session. Cron posts to the **outbound** bus for channel delivery. Cron never touches the inbound bus.

### Bus Role: Outbound Delivery Only

The bus serves a single purpose for cron: **delivery routing**.

```
Job Thread completes
  → bus.publishOutbound(OutboundMessage{
        channel: "telegram",
        chat_id: delivery.to,
        content: skill_output,
    })
  → outbound dispatcher thread consumes
  → Telegram channel.send()
```

The inbound queue is untouched. User messages from Telegram/Discord flow through the inbound dispatcher as before, completely unblocked by cron activity.

### Consumer Groups (Future Extension)

The current bus is single-consumer per queue. If we need multiple independent consumers of the outbound queue (e.g., cron delivery + audit log + metrics), we can extend to a **consumer group** model. This is a non-breaking extension — v1 uses the existing single-consumer bus. Consumer groups are additive if needed later.

### Job Type Handling

| Job Type | Execution | Thread | Notes |
|----------|-----------|--------|-------|
| `skill` | `resolveSkillExec` → subprocess | Spawned OS thread | Full sub-agent pattern |
| `agent` | Agent LLM loop with tool access | Spawned OS thread | Uses `HEAVY_RUNTIME_STACK_SIZE` (2 MiB) |
| `shell` | Direct subprocess exec | Spawned OS thread | Legacy — migrate to skill type |

All job types spawn OS threads. No bus inbound. The thread model is uniform.

### Completion Tracking

Each job thread calls `complete()` via the vtable when done, updating SQLite directly.

The `complete()` call aligns with the existing `CronBackend.VTable.complete` signature:

```zig
complete: *const fn (
    ptr: *anyopaque,
    job_id: []const u8,      // which job completed
    queue_row_id: i64,        // cron_run_queue row to delete
    now: i64,                 // completion timestamp
    status: []const u8,       // "ok" or "error"
    output: ?[]const u8,      // output text (caller-owned, callee must dupe)
    delivered: bool,          // whether delivery succeeded
) anyerror!void,
```

**Parameters preserved from existing vtable**:
- `now` — completion timestamp for `last_run_secs`
- `delivered` — distinguishes "output delivered to channel" vs "saved but not sent"
- `delete_after_run` — handled by `complete()` reading the job's `delete_after_run` flag from the DB row, not passed as a parameter (matches current `DbCronBackend.vtableComplete` behavior)

**Ownership contract**: `output` is owned by the job thread's arena. The `complete()` implementation dupes it into SQLite via bind. The job thread frees its arena after the callback returns.

**`queue_row_id`** is included so `complete()` can atomically delete the run-queue row and update the job record in a single transaction.

**One-shot job race**: When a `one_shot = true` job completes, `complete()` deletes the job row. If the ticker fires again before `complete()` runs (slow job, next tick within the same minute), `tick()` will try to enqueue it again. The `dequeue()` call will claim it. The second `complete()` call must handle "job already deleted" gracefully — the existing `dbCompleteJob` does a conditional UPDATE that is a no-op if the row is gone. This is acceptable.

### Session Isolation

Each cron job thread runs in isolation — no shared session state with user conversations or other cron jobs. The thread has its own:
- Arena allocator (transferred from dequeue, freed on thread exit)
- Subprocess execution context
- Skill resolution context

There is no session_key collision risk because cron jobs don't go through the session manager.

### Concurrency Control

Uses a separate capacity condvar to avoid blocking the drain loop:

```zig
pub const CronWorker = struct {
    max_concurrent: u32 = 4,
    active_count: u32 = 0,
    capacity_mutex: std.Thread.Mutex = .{},
    capacity_cond: std.Thread.Condition = .{},

    fn trySpawnJob(self: *CronWorker, spec: CronJobSpec, arena: ArenaAllocator, row_id: i64) !bool {
        self.capacity_mutex.lock();
        defer self.capacity_mutex.unlock();
        if (self.active_count >= self.max_concurrent) {
            return false;  // at capacity — stop draining, don't block
        }
        self.active_count += 1;
        // spawn thread (passes arena ownership to job thread)...
        return true;
    }

    fn jobComplete(self: *CronWorker) void {
        self.capacity_mutex.lock();
        self.active_count -= 1;
        self.capacity_mutex.unlock();
        self.capacity_cond.signal();  // wake worker if waiting for slot
    }
};
```

**Non-blocking spawn**: `trySpawnJob` returns `false` immediately when at capacity instead of blocking. The drain loop stops and the worker enters `timedWait`. When a job completes, `jobComplete` signals `capacity_cond`, which also wakes the worker to resume draining. This prevents the ticker from being blocked by a full capacity situation (v5 deadlock risk).

Default `max_concurrent = 4`. Configurable via existing `config.scheduler.max_concurrent` field in `SchedulerConfig` (defined in `config_types.zig` but currently unused — this spec activates it).

## Components

### 1. CronTicker

Extracted from `daemon.schedulerThread`. Follows `HeartbeatEngine` pattern.

```zig
pub const CronTicker = struct {
    db_path: [:0]const u8,
    poll_interval_ns: u64,
    signal_flag: *bool,           // set to true when jobs enqueued
    signal_mutex: *std.Thread.Mutex,
    signal_cond: *std.Thread.Condition,
    shutdown: *std.atomic.Value(bool),

    pub fn tick(self: *CronTicker, now: i64) !usize;  // returns jobs enqueued
    pub fn run(self: *CronTicker) void;                // loop: sleep → tick → signal
};
```

**Signal protocol**: The ticker sets `signal_flag = true` under `signal_mutex`, then signals `signal_cond`. The worker checks `signal_flag` under the same mutex, resets it, and proceeds to drain. The ticker never touches `worker_mutex` — no contention between ticker and capacity-blocked worker.

```
Responsibility: Poll SQLite on interval, enqueue due jobs, signal worker.
Input: tick interval (from config), DB path
Output: rows in cron_run_queue + signal flag
Dependencies: SQLite only (no gateway, no bus, no channels)
```

**Legacy path**: Phase 1 preserves both the DB-direct path (`tickDbScheduler`) and the legacy in-memory path (`collectDueJobs`). The ticker abstracts over both via the `CronBackend.tick()` vtable method.

### 2. CronWorker

Reactive dispatcher — blocks on condvar, drains queue by spawning threads, blocks again. Never executes jobs itself.

```zig
pub const CronWorker = struct {
    backend: CronBackend,         // vtable for DB operations
    bus: *bus_mod.Bus,
    allocator: std.mem.Allocator, // long-lived GPA (outlives all job threads)
    signal_flag: *bool,
    signal_mutex: *std.Thread.Mutex,
    signal_cond: *std.Thread.Condition,
    max_concurrent: u32 = 4,
    active_count: u32 = 0,
    capacity_mutex: std.Thread.Mutex = .{},
    capacity_cond: std.Thread.Condition = .{},
    shutdown: *std.atomic.Value(bool),
    // Job thread tracking for graceful shutdown
    active_threads: [MAX_CONCURRENT]?std.Thread = .{null} ** MAX_CONCURRENT,
    active_threads_mutex: std.Thread.Mutex = .{},

    pub fn run(self: *CronWorker) void {
        // Crash recovery: reset all in-progress rows
        self.backend.resetInProgress() catch {};

        while (!self.shutdown.load(.acquire)) {
            // Check signal flag
            self.signal_mutex.lock();
            const signaled = self.signal_flag.*;
            self.signal_flag.* = false;
            self.signal_mutex.unlock();

            // Drain queue (non-blocking spawn, stops at capacity)
            if (signaled or self.timedWaitExpired) {
                self.drainQueue();
            }

            // Wait for signal or timeout
            self.signal_mutex.lock();
            if (!self.signal_flag.* and !self.shutdown.load(.acquire)) {
                self.signal_cond.timedWait(self.signal_mutex, 1 * std.time.ns_per_s) catch {};
            }
            self.signal_mutex.unlock();
        }
    }
};
```

**`drainQueue` semantics**: Calls `backend.dequeue()` in a loop. For each result, calls `trySpawnJob()`. If `trySpawnJob` returns false (at capacity), stops draining. Remaining jobs stay in the queue and are picked up on next wake (either from `capacity_cond` signal or 1s timeout).

```
Responsibility: Wait for signal, dequeue ready jobs, spawn execution threads.
Input: signal from CronTicker, cron_run_queue (SQLite via vtable)
Output: spawned job threads
Dependencies: CronBackend vtable, bus (outbound only, passed to job threads)
No execution — just dispatch.
```

**Dequeue-then-spawn ordering**: The worker calls `backend.dequeue()` (marks row `in_progress`) then spawns the thread. If the spawn fails (out of memory, thread limit), the worker calls `backend.resetRow(queue_row_id)` to return the row to `pending` for retry on next wake.

**Arena ownership**: Each `dequeue()` call returns a `DequeueResult` with strings allocated from the vtable's own arena (in DbCronBackend, via `arena_allocator`). The worker transfers this arena to the `JobContext`. The job thread owns and frees it via `defer ctx.arena.deinit()`. The worker's own allocator is never used for dequeued strings.

### `resetRow` vtable method

To be added to `CronBackend.VTable` for spawn-failure recovery:

```zig
/// Reset a single queue row from 'in_progress' back to 'pending'.
/// Used for spawn-failure recovery. Returns false if row not found.
resetRow: *const fn (ptr: *anyopaque, row_id: i64) anyerror!bool,
```

**Implementation scope**:
- `CronBackend` (`root.zig`): Add vtable field + forwarding method
- `DbCronBackend` (`db.zig`): `UPDATE cron_run_queue SET status='pending', started_at=NULL WHERE id=? AND status='in_progress'`
- `MemoryCronBackend` (`memory.zig`): Find queue entry by ID, reset status

This is distinct from `resetInProgress` (which resets ALL in-progress rows on startup).

### 3. Job Thread (cronJobThreadFn)

One OS thread per job, like `subagentThreadFn`.

```zig
fn cronJobThreadFn(ctx: *JobContext) void {
    defer ctx.worker.jobComplete(ctx.thread_slot);  // decrement active_count, clear thread slot
    defer ctx.arena.deinit();                        // free dequeued spec strings

    const output = switch (ctx.spec.job_type) {
        .skill => resolveAndRunSkill(ctx),
        .agent => runAgentJob(ctx),
        .shell => runShellJob(ctx),
    };

    const now = std.time.timestamp();

    // Deliver via bus outbound (if configured).
    // IMPORTANT: OutboundMessage strings must be allocated with ctx.worker.allocator
    // (the daemon's long-lived GPA), NOT the thread-local arena. BoundedQueue.consume()
    // returns a shallow struct copy — string fields are pointers into the original
    // allocation. The outbound dispatcher calls msg.deinit() after delivery.
    var delivered = false;
    if (shouldDeliver(ctx.spec.delivery, output.success)) {
        // channel name must come from config/literal, not arena
        const msg = bus_mod.makeOutbound(
            ctx.worker.allocator,   // persistent allocator
            ctx.spec.delivery.channel.?,
            ctx.spec.delivery.to orelse "default",
            output.text,
        ) catch |_| {
            // delivery failed — complete() will record delivered=false
            break;
        };
        ctx.bus.publishOutboundTimeout(msg, 30_000) catch {
            msg.deinit(ctx.worker.allocator);
            if (!ctx.spec.delivery.best_effort) {
                // Log delivery failure
            }
            break;
        };
        delivered = true;
        // msg ownership transferred to outbound dispatcher
    }

    // Update DB via vtable (dupes output into SQLite bind buffer)
    ctx.worker.backend.complete(
        ctx.spec.id,
        ctx.queue_row_id,
        now,
        if (output.success) "ok" else "error",
        output.text,
        delivered,
    ) catch {};
}
```

**`bus_mod.makeOutbound`**: Note this is a free function in `bus.zig`, not a method on `Bus`.

**Timeout enforcement**: `resolveAndRunSkill` spawns the subprocess with a wall-clock timer. If `timeout_secs` elapses, the subprocess is killed (`std.process.Child.kill()`), and the thread returns `status="error"`.

**SQLite thread safety for `complete()`**: Each `DbCronBackend` vtable method opens its own DB connection (WAL mode, 5s busy timeout). Multiple job threads calling `complete()` concurrently is safe — SQLite WAL serializes writes, and each call uses an independent connection. No shared connection mutex needed.

### 4. CronDaemon (new entry point)

A new CLI command: `nullclaw cron daemon`

```
Lifecycle:
  1. Load config
  2. Open cron.db, enforce WAL mode (PRAGMA journal_mode=wal)
  3. Acquire daemon lease (see Daemon Lease Protocol below) — exit if another daemon holds it
  4. Init bus (outbound queue only, for delivery)
  5. Init channel registry (see Channel Registry below)
  6. Init CronWorker (with CronBackend vtable for DB operations)
  7. Spawn CronTicker thread (timer — the only thread that sleeps on poll interval)
  8. Spawn CronWorker thread (timedWait 1s — picks up both ticker signals and external enqueues)
  9. Spawn outbound dispatcher thread (consumes bus outbound → channel delivery via registry)
  10. Main thread: heartbeat loop (update lease timestamp every 5s) + wait for shutdown signal
  11. On shutdown: see Graceful Shutdown below
```

No HTTP listener. No inbound dispatcher. No session manager.

### Channel Registry for Standalone Daemon

The standalone daemon needs to send messages to channels (Telegram, Discord, etc.) via `bus.consumeOutbound()`. The gateway has the full channel registry with all initialized vtable instances. The daemon needs a minimal equivalent.

**Approach**: Reuse `src/channels/root.zig` channel factory. Build with `-Dchannels=telegram` to compile only the needed channel. The daemon calls `channels.initChannel(config, "telegram")` at startup to get a `Channel.VTable` instance. The outbound dispatcher resolves `OutboundMessage.channel` string to the matching vtable instance via a simple name lookup.

```zig
// Daemon outbound dispatcher
fn outboundDispatchLoop(bus: *Bus, registry: *ChannelRegistry) void {
    while (bus.consumeOutbound()) |msg| {
        if (registry.get(msg.channel)) |channel| {
            channel.send(msg) catch {};
        }
        msg.deinit(bus.allocator);
    }
}
```

### Graceful Shutdown

On SIGTERM/SIGINT:

```
1. Set shutdown atomic to true
2. Signal signal_cond (wake ticker and worker)
3. Join CronTicker thread (exits on shutdown check after next sleep)
4. Join CronWorker thread (exits on shutdown check after next timedWait)
5. Wait for in-flight job threads (bounded drain):
   a. Lock active_threads_mutex
   b. For each non-null thread in active_threads: join with 30s timeout
   c. After 30s total: log warning for any remaining threads, proceed
6. Close bus (signals outbound dispatcher)
7. Join outbound dispatcher thread
8. Release daemon lease (DELETE FROM cron_meta)
9. Close DB
```

**Bounded drain**: The daemon waits up to 30 seconds for in-flight jobs to complete. Jobs exceeding this are abandoned (their in-progress queue rows will be reset by `resetInProgress` on next startup). This prevents a stuck job from blocking shutdown indefinitely.

**Job threads writing to SQLite during shutdown**: Safe because each `complete()` call opens its own connection. The connection may fail if the DB file is deleted, but that won't happen during normal shutdown.

### Daemon Lease Protocol

SQLite does not provide process-scoped advisory locks. A persisted row does not auto-release on crash. Instead, the daemon uses a **heartbeat lease**:

**Table DDL** (created by `ensureCronMetaTable`, called alongside `ensureCronTable`):

```sql
CREATE TABLE IF NOT EXISTS cron_meta (
    key   TEXT PRIMARY KEY,
    value TEXT
);
```

**Lease row**: `key = 'daemon_lease'`, `value = JSON { "pid": <pid>, "heartbeat": <unix_timestamp> }`.

**Acquire** (atomic — no TOCTOU):

```sql
-- Step 1: Try INSERT for first-time acquisition
INSERT OR IGNORE INTO cron_meta (key, value)
VALUES ('daemon_lease', json_object('pid', ?new_pid, 'heartbeat', ?now));
-- If sqlite3_changes() == 1 → acquired (no prior row)

-- Step 2: If INSERT was ignored (row exists), try conditional UPDATE
UPDATE cron_meta
SET value = json_object('pid', ?new_pid, 'heartbeat', ?now)
WHERE key = 'daemon_lease'
  AND CAST(json_extract(value, '$.heartbeat') AS INTEGER) < ?stale_threshold;
-- If sqlite3_changes() == 1 → acquired (lease was stale)
-- If sqlite3_changes() == 0 → another daemon is alive → exit with error
```

Both steps are single SQL statements — no SELECT-then-UPDATE gap. Two concurrent starters cannot both succeed: SQLite serializes writes, and the conditional `WHERE` clause ensures only one UPDATE matches a stale heartbeat.

**Heartbeat**: Main thread runs `UPDATE cron_meta SET value=json_object('pid', ?pid, 'heartbeat', ?now) WHERE key='daemon_lease'` every 5 seconds. Stale threshold is 15s (3× heartbeat interval).

**Release** (clean shutdown): `DELETE FROM cron_meta WHERE key='daemon_lease'`.

**Crash recovery**: If the daemon crashes, the heartbeat stops updating. After 15 seconds, any new daemon sees a stale lease via the conditional UPDATE and takes over. No stranded lock rows.

### Mutual Exclusion: Gateway vs Daemon

**Problem**: The daemon lease prevents two daemons from running simultaneously, but does NOT prevent the gateway's `runQueueWorker` and `tickDbScheduler` from competing with the daemon on the same `cron_run_queue`. If both run concurrently, jobs may execute in either process unpredictably, and `resetInProgress` on daemon startup could undo claims from a still-running gateway.

**Solution**: The gateway checks the daemon lease before starting its cron subsystem.

```zig
// In gateway.zig, before starting runQueueWorker and tickDbScheduler:
fn shouldRunCronLocally(db_path: [:0]const u8) bool {
    // Check cron_meta for an active daemon_lease
    const lease = readDaemonLease(db_path) orelse return true;  // no lease → gateway runs cron
    const now = std.time.timestamp();
    if (now - lease.heartbeat > 15) return true;  // stale lease → gateway runs cron
    return false;  // active daemon → gateway skips cron
}
```

The gateway's `schedulerThread` calls this check:
- On startup: skip `runQueueWorker` and `tickDbScheduler` if daemon lease is active
- Every poll cycle: re-check lease (daemon may have stopped since last check)

**Rollback to gateway**: Stop daemon cleanly (deletes lease) → gateway detects no lease on next poll → gateway resumes cron. Or: daemon crashes → lease expires in ≤15s → gateway detects stale lease → gateway resumes cron.

### Daemon Health / Observability

The standalone daemon exposes liveness via two mechanisms:

1. **Lease timestamp**: External monitors can query `SELECT value FROM cron_meta WHERE key='daemon_lease'` and check if the heartbeat timestamp is within 15 seconds of now.

2. **Health file** (optional): The daemon writes a health file at `~/.nullclaw/cron-daemon.health` containing JSON `{"pid": <pid>, "heartbeat": <ts>, "active_jobs": <n>, "total_completed": <n>}`. Updated every heartbeat cycle. External monitoring can stat/read this file. Removed on clean shutdown.

## Data Flow Diagram

```
┌─────────────┐                    ┌─────────────┐
│ CronTicker  │──tick+enqueue─────▶│ cron_run_   │◀──── CLI: nullclaw cron run <id>
│ (timer)     │──signal_flag=true  │ queue (DB)  │      (enqueue only, no sync exec)
└─────────────┘  signal_cond.signal└──────┬──────┘
                       │                  │
                       ▼                  │ dequeue (on wake or timedWait timeout)
               ┌──────────────┐           │
               │  signal_cond │◀──────────┘
               │  + timedWait │
               └──────┬───────┘
                      │ wake (signal or 1s timeout)
               ┌──────▼──────┐
               │ CronWorker  │──trySpawn─┬──────────────────────┐
               │             │          │                      │
               └─────────────┘          ▼                      ▼
                                ┌──────────────┐      ┌──────────────┐
                                │ Job Thread 1 │      │ Job Thread 2 │  ...
                                │ (skill exec) │      │ (agent exec) │
                                └──────┬───────┘      └──────┬───────┘
                                       │                     │
                            complete() │(DB update)          │complete()
                                       │                     │
                                ┌──────▼─────────────────────▼──────┐
                                │      bus.publishOutbound()         │
                                │      (delivery messages)           │
                                └──────────────┬────────────────────┘
                                               │
                                        ┌──────▼──────┐
                                        │  Event Bus  │
                                        │  (outbound) │
                                        └──────┬──────┘
                                               │ consumeOutbound
                                        ┌──────▼──────┐
                                        │  Outbound   │──▶ Telegram API
                                        │  Dispatcher │──▶ Discord API
                                        └─────────────┘    etc.

     ════════════════════════════════════════════════════════
     COMPLETELY SEPARATE (no interaction):

                                        ┌─────────────┐
                                ┌──────▶│  Event Bus  │
                                │       │  (inbound)  │
                                │       └──────┬──────┘
                         Telegram/Discord      │ consumeInbound
                         user messages         │
                                        ┌──────▼──────┐
                                        │  Inbound    │
                                        │  Dispatcher │──▶ Session Manager
                                        └─────────────┘    (user agent turns)
```

## Testing Strategy

### Unit Test: CronTicker

```
1. Create isolated tmpDir SQLite DB
2. Insert a job with next_run_secs = now - 1
3. Call ticker.tick(now)
4. Assert: cron_run_queue has 1 row
5. Assert: job.next_run_secs advanced
```

Pure SQLite. No bus, no threads.

### Unit Test: CronWorker Dispatch

```
1. Create isolated DB + signal primitives + mock spawn counter
2. Insert 3 ready-to-run rows in cron_run_queue
3. Set signal_flag = true, signal signal_cond
4. Worker wakes, calls dequeue 3 times, spawns 3 mock threads
5. Assert: 3 threads spawned, active_count == 3
6. Assert: cron_run_queue rows marked in_progress
```

Tests reactive dispatch without actual job execution.

### Unit Test: Concurrency Limit (non-blocking)

```
1. Set max_concurrent = 2
2. Insert 5 jobs in run queue
3. Signal worker
4. Worker spawns 2, trySpawnJob returns false on 3rd (at capacity)
5. Worker enters timedWait (not blocked on capacity_cond)
6. Complete 1 job → capacity_cond.signal()
7. Worker wakes, dequeues and spawns 3rd
8. Assert: never more than 2 active at once
9. Assert: ticker is never blocked by capacity
```

### Unit Test: complete() Callback

```
1. Create isolated DB
2. Job thread calls backend.complete(job_id, row_id, now, "ok", "test output", true)
3. Assert: DB row updated with last_status="ok", last_output="test output"
4. Assert: cron_run_queue row deleted
5. Assert: one_shot job → job row also deleted
6. Assert: concurrent complete() calls don't deadlock (separate connections)
```

### Unit Test: resetRow (spawn failure recovery)

```
1. Create isolated DB
2. Enqueue a job, dequeue it (marks in_progress)
3. Call backend.resetRow(queue_row_id)
4. Assert: row status back to 'pending'
5. Dequeue again → succeeds
```

### Integration Test: Full Pipeline (mock skill)

```
1. Create isolated DB + Bus + signal primitives
2. Add a skill job with next_run_secs = now - 1
3. ticker.tick(now) → enqueues, sets signal_flag
4. Worker wakes, dequeues, spawns job thread
5. Job thread runs mock skill (returns "mock output" immediately)
6. complete() updates DB
7. bus.publishOutbound delivers
8. Test thread calls bus.consumeOutbound()
9. Assert: msg.channel == "telegram", msg.content == "mock output"
10. Assert: DB last_status == "ok"
```

Total time: milliseconds. No wall-clock waits.

### Integration Test: User Messages Unblocked

```
1. Create Bus + spawn slow cron job (sleeps 5s in mock)
2. Publish InboundMessage to bus (simulating Telegram user message)
3. Consume InboundMessage immediately from bus
4. Assert: consumed within <10ms (not blocked by cron job)
5. Assert: cron job still running on its own thread
```

Proves cron and user messages are completely independent.

### Integration Test: Mutual Exclusion

```
1. Create isolated DB
2. Acquire daemon lease (simulate running daemon)
3. Call shouldRunCronLocally() → returns false
4. Delete lease
5. Call shouldRunCronLocally() → returns true
6. Acquire lease, wait 16s (stale)
7. Call shouldRunCronLocally() → returns true
```

### Live Smoke Test

```
nullclaw cron add-skill "* * * * *" commute --from ... --deliver-to ...
nullclaw cron daemon  # standalone, no gateway needed
# Wait ~60s, check Telegram for delivery
nullclaw cron remove <job_id>
```

## Migration Path

### Phase 1: Extract (behavior-preserving refactor)

Move tick logic into `src/cron/ticker.zig` and worker into `src/cron/worker.zig`. Both import from `src/cron/` and `src/bus.zig` only — zero gateway imports.

**Scope clarification**: Phase 1 targets the DB-direct vtable path only. The legacy in-memory path (`collectDueJobs` + `enqueueScheduledJob`) is preserved in `daemon.zig` as a fallback but is not extracted. It will be removed in Phase 4.

Daemon and gateway call the new structs via the vtable. **All existing tests pass unchanged.**

### Phase 2: Thread-per-job Execution

Change `CronWorker` from synchronous execute to spawn-per-job (like SubagentManager). Add `cronJobThreadFn`. Add `max_concurrent` limit using existing `config.scheduler.max_concurrent` field.

**Vtable additions**:
- `resetRow(row_id)` on `CronBackend.VTable` — requires: vtable field in `root.zig`, forwarding method, SQL in `db.zig`, in-memory impl in `memory.zig`

**Bus addition**:
- `publishOutboundTimeout` on `Bus` — delegates to existing `outbound.publishTimeout`

Inbound bus is completely untouched. User message processing is unaffected.

### Phase 3: Standalone Daemon + CLI Enqueue

Add `nullclaw cron daemon` CLI command. Runs CronTicker + CronWorker + outbound dispatcher + channel registry. No HTTP, no inbound dispatcher, no session manager.

**`cliRunJob` rewrite** (moved from Phase 4 to Phase 3): Change `cliRunJob` from synchronous execution to `backend.enqueue(id, now)`. The daemon picks it up within 1 second. This eliminates the race window where CLI and daemon both write `last_run_secs` simultaneously.

**Process coordination**: Heartbeat lease in `cron_meta` table. Gateway checks lease via `shouldRunCronLocally()` before starting cron subsystem.

**Rollback**: Stop daemon → lease expires in ≤15s → restart gateway. Gateway's scheduler resumes. Same DB tables, no migration.

### Phase 4: Cleanup

Remove from `gateway.zig`:
- `runQueueWorker` and its thread lifecycle
- `tickDbScheduler`, `signalRunQueueWorker`
- `hasDbScheduler`, `clearSharedScheduler`, `setSharedScheduler`
- `acquireSchedulerGuard`, `scheduler_mutex`, `scheduler` field
- `run_queue`, `run_queue_mutex`, `run_queue_cond`, `run_queue_stop`, `run_queue_thread` fields
- `enqueueScheduledJob`

Remove from `daemon.zig`:
- Legacy in-memory scheduler path in `schedulerThread` (collectDueJobs, enqueueScheduledJob)
- `_ = event_bus` dead code

Remove from `cron.zig`:
- Legacy `runQueueWorker`-coupled execution code
- Shell job legacy path (all shell jobs migrated to skill type)

## Constraints

- **Binary size**: Under 678 KB. Build with `-Dchannels=telegram` for standalone daemon.
- **Memory**: RSS is dominated by thread stacks. 4 job threads × 2 MiB (`HEAVY_RUNTIME_STACK_SIZE`) = 8 MiB, plus 3 infrastructure threads (ticker, worker, outbound dispatcher) × ~1 MiB each = 3 MiB, plus SQLite/arenas/bus ≈ 1 MiB. Expect **~12–14 MiB** peak RSS with `max_concurrent = 4` agent jobs. **Worst case**: 4 threads blocked on `publishOutboundTimeout` (30s each) = 8 MiB stack held. Skill/shell-only workloads use smaller default stacks. The ~1 MiB target from the main binary does not apply — the daemon trades memory for concurrency.
- **SQLite WAL**: Enforced on startup via `PRAGMA journal_mode=wal`. Verified, not assumed.
- **SQLite concurrency**: Each vtable method opens its own DB connection (WAL mode, 5s busy timeout). Multiple job threads calling `complete()` concurrently is safe — writes are serialized by SQLite. No shared connection mutex needed.
- **SQLite single-daemon**: The heartbeat lease guarantees single-daemon operation. `resetInProgress()` resets ALL in-progress rows globally on startup — safe because only one daemon holds the lease.
- **Thread stacks**: Job threads use `HEAVY_RUNTIME_STACK_SIZE` (2 MiB) for agent jobs, default stack for skill/shell subprocess jobs.
- **Concurrency**: `max_concurrent` (default 4) limits parallel job threads. Uses existing `config.scheduler.max_concurrent` field.
- **Bus backpressure**: `publishOutboundTimeout` with 30s timeout. On timeout, delivery is marked failed (best_effort jobs ignore this). Worker never blocks on publish — only job threads do.
- **Timeout**: `timeout_secs` enforced per-job via subprocess kill timer on the job thread.

## Non-Goals

- **Consumer groups** — v1 uses single-consumer outbound bus. Consumer groups are a clean extension if needed for audit/metrics.
- **Distributed scheduling** — Single-machine, single-daemon.
- **Gateway removal** — Gateway continues for HTTP API, webhooks, channel endpoints.
- **InboundMessage for cron** — Explicitly rejected. Would block user messages.
- **Self-restart** — Not in scope. The daemon relies on external supervision (systemd, process manager) for restart after crash. Self-restart is a separate design concern requiring its own spec.

## Files Affected

| File | Change | Phase |
|------|--------|-------|
| `src/cron/ticker.zig` | New — extracted tick loop, HeartbeatEngine pattern | 1 |
| `src/cron/worker.zig` | New — reactive condvar worker, spawn-per-job | 1→2 |
| `src/cron/job_thread.zig` | New — per-job thread function (like subagentThreadFn) | 2 |
| `src/cron/daemon.zig` | New — standalone daemon entry point + channel registry init | 3 |
| `src/cron/root.zig` | Add `resetRow(row_id)` vtable method + forwarding | 2 |
| `src/cron/db.zig` | Add `vtableResetRow` SQL implementation | 2 |
| `src/cron/memory.zig` | Add `resetRow` in-memory implementation | 2 |
| `src/cron.zig` | Phase 1: extract tick/worker. Phase 3: rewrite `cliRunJob` to enqueue-only. Phase 4: remove gateway-coupled execution code. Add `ensureCronMetaTable` DDL. | 1→4 |
| `src/daemon.zig` | Phase 1: `schedulerThread` delegates to `CronTicker`. Phase 4: remove legacy in-memory path. | 1→4 |
| `src/gateway.zig` | Phase 3: add `shouldRunCronLocally()` lease check. Phase 4: remove `runQueueWorker`, `tickDbScheduler`, `signalRunQueueWorker`, `hasDbScheduler`, `clearSharedScheduler`, `setSharedScheduler`, `acquireSchedulerGuard`, `scheduler_mutex`, `scheduler`, `run_queue*`, `enqueueScheduledJob`. | 3→4 |
| `src/main.zig` | Add `cron daemon` subcommand | 3 |
| `src/bus.zig` | Add `publishOutboundTimeout` forwarding method (delegates to `outbound.publishTimeout`) | 2 |

## Resolved Questions

1. ~~**Agent job thread stack**~~: `HEAVY_RUNTIME_STACK_SIZE` (2 MiB) for agent jobs, default for skill/shell.
2. ~~**Shared bus instance**~~: Outbound bus is shared. No priority needed — cron delivery and user responses are both outbound messages, same urgency.
3. ~~**CompletionFn signature**~~: Use existing `CronBackend.VTable.complete` directly. No separate callback type.
4. ~~**Gateway/daemon mutual exclusion**~~: Lease check in gateway's `schedulerThread` via `shouldRunCronLocally()`.
5. ~~**Ticker blocking on capacity**~~: Decoupled — ticker uses separate `signal_mutex`/`signal_cond`, never touches `capacity_mutex`.
6. ~~**Arena ownership**~~: Each `dequeue()` result owns its arena, transferred to `JobContext`.
7. ~~**Shutdown policy**~~: Bounded 30s drain for in-flight jobs, then abandon.
