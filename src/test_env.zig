//! Test-only helper for overriding process environment variables.
//!
//! Tests must never call libc `setenv` / `unsetenv` directly. The Zig 0.16
//! test runner hands `std.testing.io` (and the global Io that locks stderr for
//! logging) a snapshot of the startup environ block: the array pointer plus
//! the entry count taken at process start. libc `unsetenv` compacts the
//! *current* environ array in place, so while that array is still the startup
//! one, removing a variable shifts the later entries down and leaves a NULL
//! inside the snapshot's counted length. The next log line then panics in
//! `Io.Threaded.Environ.scan` ("attempt to use null value") and the panic
//! handler deadlocks re-entering the same environ mutex; a spawn that inherits
//! the environment segfaults in `createPosixBlock` instead.
//!
//! `setenv` of a name that is not yet present makes glibc, musl and Apple's
//! libc copy environ into an array they own; after that the startup array is
//! never written again. `EnvOverride.init` forces that copy before mutating
//! anything, and every override restores the previous value on `restore()` —
//! unsetting only a variable that was unset to begin with.
//!
//! Scope: an override is visible to in-process `getenv` only. Children spawned
//! through Zig's `std.process` (curl, shells, …) receive the runner's STARTUP
//! environ snapshot, not libc's live one, so an override never reaches them.
//! Environment a spawned child must see (e.g. `no_proxy`) belongs on the test
//! Run step in build.zig (`IsolatedTestHome`).

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

/// Added (never present at startup) to move libc onto its own environ copy.
const detach_sentinel = "NULLCLAW_TEST_ENV_DETACHED";

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn _putenv_s(name: [*:0]const u8, value: [*:0]const u8) c_int;

fn startupEnvironPtr() usize {
    return @intFromPtr(std.testing.environ.block.slice.ptr);
}

fn liveEnvironPtr() usize {
    return @intFromPtr(std.c.environ);
}

/// Make sure libc no longer edits the startup environ array in place.
fn detachFromStartupEnviron() !void {
    if (comptime is_windows) return;
    if (liveEnvironPtr() != startupEnvironPtr()) return;
    if (setenv(detach_sentinel, "1", 1) != 0) return error.EnvMutationFailed;
    // If the sentinel already existed, setenv overwrote it in place and the
    // startup array is still live: refuse rather than corrupt the snapshot.
    if (liveEnvironPtr() == startupEnvironPtr()) return error.EnvironNotDetached;
}

fn rawSet(name: [:0]const u8, value: ?[:0]const u8) !void {
    const rc: c_int = if (value) |v|
        (if (comptime is_windows) _putenv_s(name.ptr, v.ptr) else setenv(name.ptr, v.ptr, 1))
    else
        (if (comptime is_windows) _putenv_s(name.ptr, "") else unsetenv(name.ptr));
    if (rc != 0) return error.EnvMutationFailed;
}

/// Set `name` to `value` (or unset it when null) WITHOUT saving the previous
/// value, for callers that restore it themselves. Prefer `EnvOverride`.
pub fn set(allocator: std.mem.Allocator, name: []const u8, value: ?[]const u8) !void {
    try detachFromStartupEnviron();
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);
    const value_z: ?[:0]u8 = if (value) |v| try allocator.dupeZ(u8, v) else null;
    defer if (value_z) |v| allocator.free(v);
    try rawSet(name_z, value_z);
}

/// One overridden variable. Call `restore()` (usually via `defer`) to put the
/// previous value back; it also frees what `init` allocated.
pub const EnvOverride = struct {
    allocator: std.mem.Allocator,
    name: [:0]u8,
    previous: ?[:0]u8,

    /// Set `name` to `value`, or unset it when `value` is null.
    pub fn init(allocator: std.mem.Allocator, name: []const u8, value: ?[]const u8) !EnvOverride {
        try detachFromStartupEnviron();

        const name_z = try allocator.dupeZ(u8, name);
        errdefer allocator.free(name_z);
        const previous: ?[:0]u8 = if (std.c.getenv(name_z.ptr)) |p|
            try allocator.dupeZ(u8, std.mem.span(p))
        else
            null;
        errdefer if (previous) |p| allocator.free(p);

        const value_z: ?[:0]u8 = if (value) |v| try allocator.dupeZ(u8, v) else null;
        defer if (value_z) |v| allocator.free(v);
        try rawSet(name_z, value_z);

        return .{ .allocator = allocator, .name = name_z, .previous = previous };
    }

    pub fn restore(self: *EnvOverride) void {
        rawSet(self.name, self.previous) catch @panic("test_env: failed to restore environment variable");
        if (self.previous) |p| self.allocator.free(p);
        self.allocator.free(self.name);
        self.* = undefined;
    }
};

fn startupSnapshotIntact() bool {
    for (std.testing.environ.block.slice) |entry| {
        if (entry == null) return false;
    }
    return true;
}

test "EnvOverride unsetting a startup variable keeps the startup environ snapshot intact" {
    if (comptime is_windows) return error.SkipZigTest;
    const snapshot = std.testing.environ.block.slice;
    if (snapshot.len == 0) return error.SkipZigTest;

    // Remove the LAST startup entry: unsetenv on the startup array would turn
    // exactly this slot into the NULL the runner later trips over.
    const last = std.mem.span(snapshot[snapshot.len - 1].?);
    const eq = std.mem.indexOfScalar(u8, last, '=') orelse return error.SkipZigTest;
    const name = last[0..eq];
    const original = try std.testing.allocator.dupe(u8, last[eq + 1 ..]);
    defer std.testing.allocator.free(original);

    {
        var env = try EnvOverride.init(std.testing.allocator, name, null);
        defer env.restore();
        try std.testing.expect(liveEnvironPtr() != startupEnvironPtr());
        try std.testing.expect(std.c.getenv(env.name.ptr) == null);
        try std.testing.expect(startupSnapshotIntact());
    }

    try std.testing.expect(startupSnapshotIntact());
    const name_z = try std.testing.allocator.dupeZ(u8, name);
    defer std.testing.allocator.free(name_z);
    try std.testing.expectEqualStrings(original, std.mem.span(std.c.getenv(name_z.ptr).?));
}

test "EnvOverride restores a previously unset variable to unset" {
    const name = "NULLCLAW_TEST_ENV_HELPER_UNSET_VAR";
    const name_z: [:0]const u8 = name;
    try std.testing.expect(std.c.getenv(name_z.ptr) == null);
    {
        var env = try EnvOverride.init(std.testing.allocator, name, "value-a");
        defer env.restore();
        try std.testing.expectEqualStrings("value-a", std.mem.span(std.c.getenv(name_z.ptr).?));
    }
    try std.testing.expect(std.c.getenv(name_z.ptr) == null);
}

test "EnvOverride restores the previous value of a set variable" {
    const name = "NULLCLAW_TEST_ENV_HELPER_SET_VAR";
    const name_z: [:0]const u8 = name;
    var outer = try EnvOverride.init(std.testing.allocator, name, "outer");
    defer outer.restore();
    {
        var inner = try EnvOverride.init(std.testing.allocator, name, "inner");
        defer inner.restore();
        try std.testing.expectEqualStrings("inner", std.mem.span(std.c.getenv(name_z.ptr).?));
    }
    try std.testing.expectEqualStrings("outer", std.mem.span(std.c.getenv(name_z.ptr).?));
}
