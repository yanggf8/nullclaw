# Cron-as-Subagent: Standalone Daemon with Bus-Driven Execution

**Date**: 2026-03-26
**Status**: Draft v4
**Scope**: Decouple cron scheduling and execution from the gateway. Cron jobs execute as spawned sub-agent threads, using the bus outbound queue for delivery only.

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
| `schedulerThread` | daemon.zig:432 | `scheduler_poll_secs` | Calls `gateway.tickDbScheduler()` via `g_state_ptr` |
| `runQueueWorker` | gateway.zig:3553 | 1s timedWait | Lives inside gateway.zig, uses `GatewayState` mutexes |
| `heartbeatThread` | daemon.zig:226 | `interval_minutes` | **None** — standalone struct, clean pattern to follow |

## Design Principle

**A cron job is a sub-agent.** It receives a task, executes autonomously in its own OS thread, delivers its own results, and reports completion. This follows the exact pattern of `SubagentManager` — not the inbound message dispatcher.

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
  → gateway.tickDbScheduler() (reads g_state_ptr under mutex)
  → SQLite: scan due jobs, INSERT into cron_run_queue
  → gateway.runQueueWorker (1s timedWait poll loop)
    → dequeue from cron_run_queue
    → execute subprocess directly (blocks worker thread)
    → deliverResult via bus.publishOutbound
```

### New Flow (thread-per-job, like SubagentManager)

```
CronTicker (timer thread)
  → tick(now): SQLite scan + enqueue to cron_run_queue
  → condvar.signal()

CronWorker (reactive, condvar-driven)
  → condvar.wait() ← blocks until signaled
  → drain cron_run_queue:
      → dequeue job spec
      → spawn OS thread for this job (like SubagentManager.spawn)
      → continue draining (non-blocking)
  → condvar.wait() ← blocks again

Job Thread (spawned per job, like subagentThreadFn)
  → resolve skill → run subprocess with timeout
  → on_complete callback → DB update (last_run, last_status, last_output)
  → bus.publishOutbound(delivery message) → channel dispatch
  → thread exits
```

### Reactive Worker (No Polling)

The worker does NOT tick or poll. It is purely signal-driven:

```
CronTicker (timer)              CronWorker (blocked)           Job Threads
    │                                │
    ├─ sleep(poll_secs)              ├─ condvar.wait() ← blocks
    ├─ tick → 3 jobs enqueued        │
    ├─ condvar.signal() ─────────────▶ wakes
    │                                ├─ dequeue job 1 → spawn ──────▶ [thread 1: running]
    │                                ├─ dequeue job 2 → spawn ──────▶ [thread 2: running]
    │                                ├─ dequeue job 3 → spawn ──────▶ [thread 3: running]
    │                                ├─ dequeue → null
    ├─ sleep(poll_secs)              ├─ condvar.wait() ← blocks
    │                                │                         [thread 1: complete → outbound bus]
    │                                │                         [thread 2: complete → outbound bus]
    │                                │                         [thread 3: complete → outbound bus]
```

The ticker is the only component with a timer. The worker drains the queue and spawns — it never blocks on execution. Job threads run in parallel, respecting `max_concurrent` limit.

### SubagentManager Parallel

| Aspect | SubagentManager | Cron Worker |
|--------|-----------------|-------------|
| Trigger | Agent tool call (`spawn`) | CronTicker condvar signal |
| Dispatch | `std.Thread.spawn(subagentThreadFn)` | `std.Thread.spawn(cronJobThreadFn)` |
| Execution | LLM agent loop on spawned thread | Skill subprocess on spawned thread |
| Concurrency | `max_concurrent = 4` | `max_concurrent` (configurable) |
| Result delivery | `bus.publishOutbound()` | `bus.publishOutbound()` |
| Completion | `completeTask()` → update in-memory state | `on_complete()` → update SQLite |
| Bus usage | **Outbound only** (delivery) | **Outbound only** (delivery) |
| Inbound bus | Posts result as InboundMessage to notify parent | **Not used** |

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

The current bus is single-consumer per queue. If we need multiple independent consumers of the outbound queue (e.g., cron delivery + audit log + metrics), we can extend to a **consumer group** model:

```zig
pub const ConsumerGroup = struct {
    groups: [MAX_GROUPS]BoundedQueue(OutboundMessage, QUEUE_CAPACITY),
    group_count: usize,

    pub fn publish(self: *ConsumerGroup, msg: OutboundMessage) void {
        // Fan-out: copy message to each group's queue
        for (self.groups[0..self.group_count]) |*q| {
            q.publish(msg.dupe(allocator));
        }
    }

    pub fn consume(self: *ConsumerGroup, group_id: usize) ?OutboundMessage {
        return self.groups[group_id].consume();
    }
};
```

Each consumer group drains independently. This is a non-breaking extension — v1 uses the existing single-consumer bus. Consumer groups are additive if needed later.

### Job Type Handling

| Job Type | Execution | Thread | Notes |
|----------|-----------|--------|-------|
| `skill` | `resolveSkillExec` → subprocess | Spawned OS thread | Full sub-agent pattern |
| `agent` | Agent LLM loop with tool access | Spawned OS thread | Uses `TaskRunnerFn` like SubagentManager |
| `shell` | Direct subprocess exec | Spawned OS thread | Legacy — migrate to skill type |

All job types spawn OS threads. No bus inbound. The thread model is uniform.

### Completion Tracking

Each job thread calls `on_complete` when done, updating SQLite directly.

```zig
pub const CompletionFn = *const fn (
    ctx: *anyopaque,         // worker context (DB write handle)
    job_id: []const u8,      // which job completed
    queue_row_id: i64,       // cron_run_queue row to delete
    status: []const u8,      // "ok" or "error"
    output: ?[]const u8,     // output text (caller-owned, callee must dupe if persisting)
) void;
```

**Ownership contract**: `output` is owned by the job thread's arena. The `on_complete` implementation dupes it into its own buffer before writing to SQLite. The job thread frees its arena after the callback returns.

**`queue_row_id`** is included so `complete()` can atomically delete the run-queue row and update the job record in a single transaction.

### Session Isolation

Each cron job thread runs in isolation — no shared session state with user conversations or other cron jobs. The thread has its own:
- Arena allocator (freed on thread exit)
- Subprocess execution context
- Skill resolution context

There is no session_key collision risk because cron jobs don't go through the session manager.

### Concurrency Control

Uses a condvar to avoid spin-waiting when at capacity:

```zig
pub const CronWorker = struct {
    max_concurrent: u32 = 4,
    active_count: u32 = 0,
    capacity_mutex: std.Thread.Mutex = .{},
    capacity_cond: std.Thread.Condition = .{},

    fn spawnJob(self: *CronWorker, spec: CronJobSpec) !void {
        self.capacity_mutex.lock();
        // Block until a slot opens — no polling
        while (self.active_count >= self.max_concurrent) {
            self.capacity_cond.wait(&self.capacity_mutex);
        }
        self.active_count += 1;
        self.capacity_mutex.unlock();
        // spawn thread...
    }

    fn jobComplete(self: *CronWorker) void {
        self.capacity_mutex.lock();
        self.active_count -= 1;
        self.capacity_mutex.unlock();
        self.capacity_cond.signal();  // wake worker if blocked on capacity
    }
};
```

`active_count` is protected by `capacity_mutex` — no atomics needed. The worker blocks on `capacity_cond.wait()` (zero CPU) instead of polling. `jobComplete` signals the condvar, waking the worker to spawn the next job.

Default `max_concurrent = 4` matches `SubagentConfig.max_concurrent`. Configurable via `config.scheduler.max_concurrent_jobs`.

## Components

### 1. CronTicker

Extracted from `daemon.schedulerThread`. Follows `HeartbeatEngine` pattern.

```zig
pub const CronTicker = struct {
    db_path: [:0]const u8,
    poll_interval_ns: u64,
    worker_cond: *std.Thread.Condition,
    worker_mutex: *std.Thread.Mutex,

    pub fn tick(self: *CronTicker, now: i64) !usize;  // returns jobs enqueued
    pub fn run(self: *CronTicker) void;                // loop: sleep → tick → signal
};
```

**Mutex discipline**: The ticker acquires `worker_mutex` before calling `condvar.signal()`. The worker holds `worker_mutex` when checking the queue predicate and entering `wait()`. Because the worker re-checks the queue in a loop before waiting (see CronWorker.run), signals are never lost — even if the ticker signals while the worker is mid-drain.

```
Responsibility: Poll SQLite on interval, enqueue due jobs, signal worker.
Input: tick interval (from config), DB path
Output: rows in cron_run_queue + condvar signal
Dependencies: SQLite only (no gateway, no bus, no channels)
```

### 2. CronWorker

Reactive dispatcher — blocks on condvar, drains queue by spawning threads, blocks again. Never executes jobs itself.

```zig
pub const CronWorker = struct {
    db_path: [:0]const u8,
    bus: *bus_mod.Bus,
    cond: *std.Thread.Condition,
    mutex: *std.Thread.Mutex,
    allocator: std.mem.Allocator,
    max_concurrent: u32 = 4,
    active_count: u32 = 0,
    capacity_mutex: std.Thread.Mutex = .{},
    capacity_cond: std.Thread.Condition = .{},
    on_complete: CompletionFn,
    on_complete_ctx: *anyopaque,
    shutdown: bool = false,

    pub fn run(self: *CronWorker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.shutdown) {
            // Standard condvar predicate loop — prevents lost wakeups.
            // On each iteration: drain queue, THEN re-check before waiting.
            // If ticker signaled while we were spawning, the queue is non-empty
            // and we loop back to drain without entering wait().
            while (self.drainQueue()) {}  // drain returns true if it spawned anything
            if (self.shutdown) break;
            self.cond.wait(self.mutex);   // blocks only when queue is confirmed empty
        }
    }
};
```

**Lost-wakeup prevention**: The worker holds `mutex` and checks the queue (via `drainQueue`) in a loop. It only enters `cond.wait()` after confirming the queue is empty. If the ticker signals between two `drainQueue` calls, the signal is "absorbed" but the next `drainQueue` iteration finds the new rows and processes them. This is the standard condvar predicate pattern — no wakeups are lost.

**`drainQueue` semantics**: Returns `true` if it dequeued and spawned (or attempted to spawn) at least one job. Returns `false` when `dequeue()` returns `null` (queue empty). The outer `while (self.drainQueue()) {}` loop terminates only when the queue is confirmed empty — the predicate for entering `cond.wait()`.

```
Responsibility: Wait for signal, dequeue all ready jobs, spawn execution threads.
Input: condvar signal from CronTicker, cron_run_queue (SQLite)
Output: spawned job threads
Dependencies: SQLite, bus (outbound only, passed to job threads for delivery)
No polling — purely reactive. No execution — just dispatch.
```

On startup, calls `resetInProgress()` with `worker_pid` filter to only reset its own rows.

**Dequeue-then-spawn ordering**: The worker calls `dequeue()` (marks row `in_progress`) then spawns the thread. If the spawn fails (out of memory, thread limit), the worker calls `resetRow(queue_row_id)` to return the row to `pending` for retry on next wake.

**`resetRow` vtable method** (to be added to `CronBackend.VTable`):

```zig
/// Reset a single queue row from 'in_progress' back to 'pending'.
/// Used for spawn-failure recovery. Returns false if row not found.
resetRow: *const fn (ptr: *anyopaque, row_id: i64) anyerror!bool,
```

This is distinct from `resetInProgress` (which resets ALL in-progress rows on startup). `resetRow` targets a single row for surgical recovery when a thread spawn fails.

### 3. Job Thread (cronJobThreadFn)

One OS thread per job, like `subagentThreadFn`.

```zig
fn cronJobThreadFn(ctx: *JobContext) void {
    defer ctx.worker.jobComplete();  // decrement active_count → signals capacity_cond
    defer ctx.arena.deinit();

    const output = switch (ctx.spec.job_type) {
        .skill => resolveAndRunSkill(ctx),
        .agent => runAgentJob(ctx),
        .shell => runShellJob(ctx),
    };

    // Update DB via callback (dupes output into its own buffer before writing)
    ctx.worker.on_complete(
        ctx.worker.on_complete_ctx,
        ctx.spec.id,
        ctx.queue_row_id,
        if (output.success) "ok" else "error",
        output.text,
    );

    // Deliver via bus outbound (if configured).
    // IMPORTANT: OutboundMessage must be allocated with a persistent allocator (not
    // the thread-local arena) because BoundedQueue.consume() returns a shallow struct
    // copy — string fields (channel, chat_id, content) are pointers, not owned copies.
    // The outbound dispatcher calls msg.deinit() after delivery, freeing these strings.
    // This matches the existing pattern used by all other publishOutbound callers.
    if (shouldDeliver(ctx.spec.delivery, output.success)) {
        const msg = bus.makeOutbound(ctx.worker.allocator,  // persistent allocator
            ctx.spec.delivery.channel.?,
            ctx.spec.delivery.to orelse "default",
            output.text,
        ) catch return;
        ctx.bus.publishOutboundTimeout(msg, 30_000) catch {
            msg.deinit(ctx.worker.allocator);  // clean up on publish failure
            if (!ctx.spec.delivery.best_effort) {
                // Log delivery failure
            }
            return;
        };
        // msg ownership transferred to outbound dispatcher (calls msg.deinit() after delivery)
    }
}
```

**Lifetime safety**: The `OutboundMessage` is allocated with `ctx.worker.allocator` (the CronDaemon's long-lived GPA), NOT the thread-local arena. `BoundedQueue.consume()` returns a shallow struct copy — the slice fields (`channel`, `content`, etc.) still point into the original allocation. The outbound dispatcher calls `msg.deinit()` after delivery, freeing these strings. This matches how every other `publishOutbound` caller in the codebase works (e.g., `deliverResult` in `src/cron.zig`). The thread-local arena is only used for subprocess execution scratch data.

**Timeout enforcement**: `resolveAndRunSkill` spawns the subprocess with a wall-clock timer. If `timeout_secs` elapses, the subprocess is killed (`std.process.Child.kill()`), and the thread returns `status="error"`.

### 4. CronDaemon (new entry point)

A new CLI command: `nullclaw cron daemon`

```
Lifecycle:
  1. Load config
  2. Open cron.db, enforce WAL mode (PRAGMA journal_mode=wal)
  3. Acquire SQLite advisory lock (cron_meta table) — exit if another daemon holds it
  4. Init bus (outbound queue only, for delivery)
  5. Init CronWorker (registers on_complete for DB writes)
  6. Spawn CronTicker thread (timer — the only thread that sleeps)
  7. Spawn CronWorker thread (reactive — blocks on condvar)
  8. Spawn outbound dispatcher thread (consumes bus outbound → channel delivery)
  9. Main thread: wait for shutdown signal
  10. On shutdown: signal condvar, close bus, join threads, close DB
```

No HTTP listener. No inbound dispatcher. No session manager.

## Data Flow Diagram

```
┌─────────────┐                    ┌─────────────┐
│ CronTicker  │──tick+enqueue─────▶│ cron_run_   │
│ (timer)     │──condvar.signal()  │ queue (DB)  │
└─────────────┘        │           └──────┬──────┘
                       │                  │
                       ▼                  │ dequeue (on wake)
               ┌──────────────┐           │
               │  condvar     │◀──────────┘
               └──────┬───────┘
                      │ wake
               ┌──────▼──────┐
               │ CronWorker  │──spawn──┬──────────────────────┐
               │ (reactive)  │        │                      │
               └─────────────┘        ▼                      ▼
                              ┌──────────────┐      ┌──────────────┐
                              │ Job Thread 1 │      │ Job Thread 2 │  ...
                              │ (skill exec) │      │ (agent exec) │
                              └──────┬───────┘      └──────┬───────┘
                                     │                     │
                          on_complete│(DB update)           │on_complete
                                     │                     │
                              ┌──────▼─────────────────────▼──────┐
                              │         bus.publishOutbound()      │
                              │         (delivery messages)        │
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
1. Create isolated DB + condvar + mock spawn counter
2. Insert 3 ready-to-run rows in cron_run_queue
3. Signal condvar
4. Worker wakes, calls dequeue 3 times, spawns 3 mock threads
5. Assert: 3 threads spawned, active_count == 3
6. Assert: cron_run_queue rows marked in_progress
```

Tests reactive dispatch without actual job execution.

### Unit Test: Concurrency Limit

```
1. Set max_concurrent = 2
2. Insert 5 jobs in run queue
3. Signal condvar
4. Worker spawns 2, blocks on 3rd (active_count == max)
5. Complete 1 job (active_count drops to 1)
6. Worker spawns 3rd
7. Assert: never more than 2 active at once
```

### Unit Test: on_complete Callback

```
1. Create isolated DB + mock callback that dupes output into test buffer
2. Job thread calls on_complete(job_id, row_id, "ok", "test output")
3. Assert: test buffer contains "test output"
4. Assert: DB row updated with last_status="ok", last_output="test output"
5. Assert: cron_run_queue row deleted
6. Assert: no double-free (output is caller-owned, callback dupes)
```

### Integration Test: Full Pipeline (mock skill)

```
1. Create isolated DB + Bus + condvar
2. Add a skill job with next_run_secs = now - 1
3. ticker.tick(now) → enqueues, signals condvar
4. Worker wakes, dequeues, spawns job thread
5. Job thread runs mock skill (returns "mock output" immediately)
6. on_complete updates DB
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

### Live Smoke Test

```
nullclaw cron add-skill "* * * * *" commute --from ... --deliver-to ...
nullclaw cron daemon  # standalone, no gateway needed
# Wait ~60s, check Telegram for delivery
nullclaw cron remove <job_id>
```

## Migration Path

### Phase 1: Extract (no behavior change)

Move tick logic into `src/cron/ticker.zig` and worker into `src/cron/worker.zig`. Both import from `src/cron/` and `src/bus.zig` only — zero gateway imports. Daemon and gateway call the new structs. **All existing tests pass unchanged.**

### Phase 2: Thread-per-job Execution

Change `CronWorker` from synchronous execute to spawn-per-job (like SubagentManager). Add `cronJobThreadFn`. Add `max_concurrent` limit. Bus used for outbound delivery only.

Inbound bus is completely untouched. User message processing is unaffected.

### Phase 3: Standalone Daemon

Add `nullclaw cron daemon` CLI command. Runs CronTicker + CronWorker + outbound dispatcher. No HTTP, no inbound dispatcher, no session manager.

**Process coordination**: SQLite advisory lock via `cron_daemon_lock` row in `cron_meta` table. Auto-releases on process death (SQLite handles this).

**Rollback**: Stop daemon, restart gateway. Gateway's scheduler resumes (lock released). Same DB tables, no migration.

### Phase 4: Cleanup

- Migrate doughcon shell jobs to skill type
- Remove shell job legacy path
- Remove `tickDbScheduler` and `runQueueWorker` from gateway.zig
- Remove `_ = event_bus` dead code from schedulerThread

## Constraints

- **Binary size**: Under 678 KB. Build with `-Dchannels=telegram` for standalone daemon.
- **Memory**: ~1 MB RSS. Bus ring buffer fixed-size (100 slots). Job threads use arena allocators (freed on exit).
- **SQLite WAL**: Enforced on startup via `PRAGMA journal_mode=wal`. Verified, not assumed.
- **SQLite concurrency**: `worker_pid` column in `cron_run_queue`. Each process resets only its own rows.
- **Thread stacks**: Job threads use `SESSION_TURN_STACK_SIZE` (2 MB) for agent jobs, default stack for skill/shell subprocess jobs.
- **Concurrency**: `max_concurrent` (default 4) limits parallel job threads. Matches `SubagentConfig.max_concurrent`.
- **Bus backpressure**: `publishOutboundTimeout` with 30s timeout. On timeout, delivery is marked failed (best_effort jobs ignore this). Worker never blocks on publish — only job threads do. **Note**: `Bus.publishOutboundTimeout` is a trivial addition — `BoundedQueue.publishTimeout` already exists (used by `publishInboundTimeout`); the outbound forwarding method just needs to be added.
- **Timeout**: `timeout_secs` enforced per-job via subprocess kill timer on the job thread.

## Non-Goals

- **Consumer groups** — v1 uses single-consumer outbound bus. Consumer groups are a clean extension if needed for audit/metrics.
- **Distributed scheduling** — Single-machine, single-daemon.
- **Gateway removal** — Gateway continues for HTTP API, webhooks, channel endpoints.
- **InboundMessage for cron** — Explicitly rejected. Would block user messages.

## Files Affected

| File | Change |
|------|--------|
| `src/cron/ticker.zig` | New — extracted tick loop, HeartbeatEngine pattern |
| `src/cron/worker.zig` | New — reactive condvar worker, spawn-per-job |
| `src/cron/job_thread.zig` | New — per-job thread function (like subagentThreadFn) |
| `src/cron/daemon.zig` | New — standalone daemon entry point |
| `src/cron.zig` | Remove gateway-coupled execution code |
| `src/cron/root.zig` | Add `resetRow(row_id)` vtable method for spawn-failure recovery |
| `src/daemon.zig` | `schedulerThread` delegates to `CronTicker` |
| `src/gateway.zig` | Remove `runQueueWorker`, `tickDbScheduler`, `signalRunQueueWorker` |
| `src/main.zig` | Add `cron daemon` subcommand |
| `src/bus.zig` | Add `publishOutboundTimeout` forwarding method (1 line — delegates to `outbound.publishTimeout`) |

## Open Questions

1. **Agent job thread stack**: Agent jobs run full LLM loops — should they use `HEAVY_RUNTIME_STACK_SIZE` (2 MB) like SubagentManager, or `SESSION_TURN_STACK_SIZE`?
2. **Shared bus instance**: If running embedded in daemon (not standalone), the cron outbound messages share the bus with user response messages. Should the outbound dispatcher prioritize user messages over cron delivery?
