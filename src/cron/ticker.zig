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

        // Heartbeat every ~5 minutes of idle ticks so a silent scheduler is
        // detectable in logs.
        const poll_secs: u64 = self.poll_interval_ns / std.time.ns_per_s;
        const heartbeat_ticks: u64 = @max(@as(u64, 1), 300 / @max(poll_secs, 1));
        var idle_ticks: u64 = 0;

        while (!self.shutdown.load(.acquire)) {
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
