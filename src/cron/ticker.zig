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
