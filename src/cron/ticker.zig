//! CronTicker — periodic tick driver for CronBackend.
//!
//! Owns a backend reference, a poll interval, and a shutdown flag.
//! The run loop (later task) will call backend.tick(now) every poll_interval_ns
//! until shutdown is signaled.
//!
//! Ownership:
//! - Caller owns the MemoryCronBackend / DbCronBackend struct.
//! - Caller owns the shutdown atomic — CronTicker holds a pointer, does not free.
//! - CronTicker is a value type — copy freely, do not free.
const std = @import("std");
const std_compat = @import("compat");

const cron = @import("root.zig");
const memory_backend = @import("memory.zig");

const WATCHDOG_CHECK_INTERVAL_NS: u64 = 60 * std.time.ns_per_s;
const WATCHDOG_WARN_AFTER_NS: i128 = 10 * std.time.ns_per_min;
// Keep this fixed and conservative: cron ticks are cheap, and a 15-minute
// scheduler silence is long enough to avoid restart churn while still bounding
// missed deliveries without growing the config surface.
const WATCHDOG_ABORT_AFTER_NS: i128 = 15 * std.time.ns_per_min;

const SchedulerWatchdogDecision = enum {
    ok,
    warning,
    abort,
};

const SchedulerWatchdogState = struct {
    mutex: std_compat.sync.Mutex = .{},
    last_tick_ns: i128,
    jobs_exist: bool,
    warned: bool = false,

    fn init(now_ns: i128, jobs_exist: bool) SchedulerWatchdogState {
        return .{
            .last_tick_ns = now_ns,
            .jobs_exist = jobs_exist,
        };
    }

    fn markTick(self: *SchedulerWatchdogState, now_ns: i128) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.last_tick_ns = now_ns;
        self.warned = false;
    }

    fn evaluate(self: *SchedulerWatchdogState, now_ns: i128) SchedulerWatchdogDecision {
        self.mutex.lock();
        defer self.mutex.unlock();

        const decision = schedulerWatchdogDecision(
            now_ns,
            self.last_tick_ns,
            self.jobs_exist,
            self.warned,
        );
        if (decision == .warning) self.warned = true;
        return decision;
    }
};

fn schedulerWatchdogDecision(
    now_ns: i128,
    last_tick_ns: i128,
    jobs_exist: bool,
    already_warned: bool,
) SchedulerWatchdogDecision {
    if (!jobs_exist or last_tick_ns <= 0 or now_ns <= last_tick_ns) return .ok;

    const stalled_for_ns = now_ns - last_tick_ns;
    if (stalled_for_ns >= WATCHDOG_ABORT_AFTER_NS) return .abort;
    if (stalled_for_ns >= WATCHDOG_WARN_AFTER_NS and !already_warned) return .warning;
    return .ok;
}

fn countSchedulableJob(ptr: *anyopaque, row: cron.types.CronJobSummary) anyerror!void {
    if (row.enabled and !row.paused) {
        const found: *bool = @ptrCast(@alignCast(ptr));
        found.* = true;
        return error.StopCounting;
    }
}

fn backendHasSchedulableJobs(backend: cron.CronBackend) bool {
    var found = false;
    const visitor = cron.CronBackend.RowVisitor{
        .ptr = &found,
        .visit = countSchedulableJob,
    };
    // page_allocator is safe: the visitor reserves no heap and stops on the
    // first schedulable row, so listRows never reaches an allocating path.
    backend.listRows(std.heap.page_allocator, visitor) catch |err| switch (err) {
        error.StopCounting => return true,
        else => {
            std.log.scoped(.cron_watchdog).warn(
                "job inventory failed: {s}; arming scheduler watchdog fail-safe",
                .{@errorName(err)},
            );
            return true;
        },
    };
    return found;
}

fn runSchedulerWatchdog(state: *SchedulerWatchdogState, shutdown: *std.atomic.Value(bool)) void {
    const log = std.log.scoped(.cron_watchdog);

    while (!shutdown.load(.acquire)) {
        var slept_ns: u64 = 0;
        while (slept_ns < WATCHDOG_CHECK_INTERVAL_NS and !shutdown.load(.acquire)) {
            std_compat.thread.sleep(std.time.ns_per_s);
            slept_ns += std.time.ns_per_s;
        }
        if (shutdown.load(.acquire)) break;

        const now_ns = std_compat.time.monotonicNanoTimestamp();
        switch (state.evaluate(now_ns)) {
            .ok => {},
            .warning => log.warn("scheduler ticker has not advanced for 10 minutes", .{}),
            .abort => {
                log.err("scheduler ticker has not advanced for 15 minutes; aborting for supervisor restart", .{});
                std.process.abort();
            },
        }
    }
}

pub const CronTicker = struct {
    backend: cron.CronBackend,
    poll_interval_ns: u64,
    shutdown: *std.atomic.Value(bool),

    pub fn init(backend: cron.CronBackend, poll_secs: u64, shutdown: *std.atomic.Value(bool)) CronTicker {
        const clamped = if (poll_secs == 0) @as(u64, 1) else poll_secs;
        return .{
            .backend = backend,
            .poll_interval_ns = clamped * @as(u64, @intCast(std.time.ns_per_s)),
            .shutdown = shutdown,
        };
    }

    /// Delegate to the backend's atomic tick. Returns the number of rows
    /// inserted into cron_run_queue. Callers decide whether to signal the
    /// worker condvar; the ticker itself has no knowledge of the worker.
    pub fn tick(self: *CronTicker, now: i64) !usize {
        return self.backend.tick(now);
    }

    /// Main loop: tick, log heartbeat, sleep in 1-second slices. Exits when
    /// the shared shutdown flag transitions to true. Intended to be spawned
    /// on its own OS thread via std.Thread.spawn.
    ///
    /// Callers must ensure `backend` outlives the thread. Errors from
    /// `tick()` are logged but do not exit the loop — a transient SQLite
    /// failure should not take down scheduling.
    pub fn run(self: *CronTicker) void {
        const log = std.log.scoped(.cron_ticker);

        // jobs_exist is sampled once at startup. If the inventory changes at
        // runtime (empty DB gains a job, or all jobs are deleted), the watchdog
        // arming state does not refresh — re-checking on every watcher tick
        // would add a DB query every 60s and is overkill for the wedge we
        // guard against. Restart the daemon to re-arm.
        var watchdog_state = SchedulerWatchdogState.init(
            std_compat.time.monotonicNanoTimestamp(),
            backendHasSchedulableJobs(self.backend),
        );
        const watchdog_thread = if (watchdog_state.jobs_exist)
            std.Thread.spawn(.{}, runSchedulerWatchdog, .{ &watchdog_state, self.shutdown }) catch |err| blk: {
                std.log.scoped(.cron_watchdog).warn("scheduler watchdog disabled: {s}", .{@errorName(err)});
                break :blk null;
            }
        else
            null;
        defer if (watchdog_thread) |thread| thread.join();

        // Heartbeat every ~5 minutes of idle ticks so a silent scheduler is
        // detectable in logs.
        const poll_secs: u64 = self.poll_interval_ns / std.time.ns_per_s;
        const heartbeat_ticks: u64 = @max(@as(u64, 1), 300 / @max(poll_secs, 1));
        var idle_ticks: u64 = 0;

        while (!self.shutdown.load(.acquire)) {
            watchdog_state.markTick(std_compat.time.monotonicNanoTimestamp());
            const now = std_compat.time.timestamp();
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
                std_compat.thread.sleep(std.time.ns_per_s);
                slept_ns += std.time.ns_per_s;
            }
        }
    }
};

test "CronTicker can be constructed against MemoryCronBackend" {
    const allocator = std.testing.allocator;

    var mem_be = memory_backend.MemoryCronBackend.init(allocator);
    defer mem_be.deinit();
    const be = mem_be.backend();

    var shutdown = std.atomic.Value(bool).init(false);

    const ticker = CronTicker.init(be, 1, &shutdown);
    try std.testing.expectEqual(std.time.ns_per_s, ticker.poll_interval_ns);
}

test "CronTicker.tick forwards to backend and reports count" {
    const allocator = std.testing.allocator;

    var mem = memory_backend.MemoryCronBackend.init(allocator);
    defer mem.deinit();

    var shutdown = std.atomic.Value(bool).init(false);
    var ticker = CronTicker.init(mem.backend(), 1, &shutdown);

    const enqueued = try ticker.tick(std_compat.time.timestamp());
    try std.testing.expectEqual(@as(usize, 0), enqueued);
}

test "CronTicker.run exits promptly when shutdown flag is set" {
    const allocator = std.testing.allocator;

    var mem = memory_backend.MemoryCronBackend.init(allocator);
    defer mem.deinit();

    var shutdown = std.atomic.Value(bool).init(false);
    var ticker = CronTicker.init(mem.backend(), 1, &shutdown);

    const thread = try std.Thread.spawn(.{}, CronTicker.run, .{&ticker});

    // Let the ticker enter its sleep loop, then request shutdown.
    std_compat.thread.sleep(10 * std.time.ns_per_ms);
    shutdown.store(true, .release);
    thread.join();
    // Reaching here without hanging is the assertion.
}

test "scheduler watchdog decision warns once then aborts stalled ticker" {
    const base: i128 = 1_000_000;

    // Regression: a silent ticker must be classified without calling abort()
    // from tests; the runtime watcher applies the abort action.
    try std.testing.expectEqual(
        SchedulerWatchdogDecision.ok,
        schedulerWatchdogDecision(base + WATCHDOG_ABORT_AFTER_NS, base, false, false),
    );
    try std.testing.expectEqual(
        SchedulerWatchdogDecision.ok,
        schedulerWatchdogDecision(base + WATCHDOG_WARN_AFTER_NS - 1, base, true, false),
    );
    try std.testing.expectEqual(
        SchedulerWatchdogDecision.warning,
        schedulerWatchdogDecision(base + WATCHDOG_WARN_AFTER_NS, base, true, false),
    );
    try std.testing.expectEqual(
        SchedulerWatchdogDecision.ok,
        schedulerWatchdogDecision(base + WATCHDOG_WARN_AFTER_NS, base, true, true),
    );
    try std.testing.expectEqual(
        SchedulerWatchdogDecision.abort,
        schedulerWatchdogDecision(base + WATCHDOG_ABORT_AFTER_NS, base, true, true),
    );
}

test "scheduler watchdog re-arms warning after a recovered tick" {
    const base: i128 = 1_000_000;
    var state = SchedulerWatchdogState.init(base, true);

    // First stall: warning fires at base + WARN_AFTER, then suppresses.
    try std.testing.expectEqual(
        SchedulerWatchdogDecision.warning,
        state.evaluate(base + WATCHDOG_WARN_AFTER_NS),
    );
    try std.testing.expectEqual(
        SchedulerWatchdogDecision.ok,
        state.evaluate(base + WATCHDOG_WARN_AFTER_NS + std.time.ns_per_min),
    );

    // Recovered: a tick clears the warned latch.
    const recovered_at = base + WATCHDOG_WARN_AFTER_NS + std.time.ns_per_min;
    state.markTick(recovered_at);

    // Re-stall from the new baseline: warning must fire again.
    try std.testing.expectEqual(
        SchedulerWatchdogDecision.ok,
        state.evaluate(recovered_at + WATCHDOG_WARN_AFTER_NS - 1),
    );
    try std.testing.expectEqual(
        SchedulerWatchdogDecision.warning,
        state.evaluate(recovered_at + WATCHDOG_WARN_AFTER_NS),
    );
}
