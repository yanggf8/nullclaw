//! Agent subprocess runner — spawns `nullclaw agent -m "<prompt>"` as a child
//! process with timeout, output capture, and platform-specific exec fallbacks.
//!
//! Extracted from cron.zig so that any subsystem (cron, heartbeat, etc.) can
//! spawn agent jobs without depending on the scheduler.

const std = @import("std");
const std_compat = @import("compat");
const builtin = @import("builtin");
const platform = @import("platform.zig");
const process_util = @import("tools/process_util.zig");

pub const AgentRunResult = struct {
    success: bool,
    output: []const u8,
};

pub const MAX_OUTPUT_BYTES: usize = 1_048_576;
const POLL_STEP_NS: u64 = 200 * std.time.ns_per_ms;
/// After a timeout kill, how long to keep draining output the group wrote
/// before it died. EOF normally arrives at once (the whole group is dead);
/// the bound only matters if a descendant left the group and still holds the
/// pipes, which must not keep the collector waiting.
const POST_KILL_DRAIN_NS: u64 = 200 * std.time.ns_per_ms;
const LINUX_SELF_EXE_PATH = "/proc/self/exe";
const DELETED_EXE_SUFFIX = " (deleted)";

fn pathAgentExecutableName() []const u8 {
    return if (comptime builtin.os.tag == .windows) "nullclaw.exe" else "nullclaw";
}

fn hasTimeoutExpired(start_ns: i128, timeout_secs: u64) bool {
    if (timeout_secs == 0) return false;
    const timeout_ns = @as(i128, @intCast(timeout_secs)) * std.time.ns_per_s;
    const now_ns = std_compat.time.nanoTimestamp();
    return now_ns - start_ns >= timeout_ns;
}

fn collectChildOutputWithTimeout(
    child: *std_compat.process.Child,
    allocator: std.mem.Allocator,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    timeout_secs: u64,
    start_ns: i128,
) !bool {
    const stdout_file = child.stdout.?;
    const stderr_file = child.stderr.?;
    // On any error (output over the cap, OOM, poll/read failure) the child is
    // still running and its pipes will not be read again: abort it boundedly,
    // with its process group.
    errdefer process_util.abortChild(child);
    var stdout_open = true;
    var stderr_open = true;
    var timed_out = false;
    var drain_deadline_ns: i128 = 0;
    // The timeout path reaps the child and records its term, so wait() will
    // not close the pipes for us.
    defer {
        if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) {
            if (timed_out) process_util.closeChildStdio(child);
        }
    }
    var read_buf: [4096]u8 = undefined;
    while (true) {
        if (!stdout_open and !stderr_open) break;

        if (comptime builtin.os.tag == .windows) {
            if (stdout_open) {
                const n = stdout_file.read(&read_buf) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    else => return err,
                };
                if (n == 0) {
                    stdout_open = false;
                } else {
                    try stdout.appendSlice(allocator, read_buf[0..n]);
                    if (stdout.items.len > MAX_OUTPUT_BYTES) return error.StdoutStreamTooLong;
                }
            }

            if (stderr_open) {
                const n = stderr_file.read(&read_buf) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    else => return err,
                };
                if (n == 0) {
                    stderr_open = false;
                } else {
                    try stderr.appendSlice(allocator, read_buf[0..n]);
                    if (stderr.items.len > MAX_OUTPUT_BYTES) return error.StderrStreamTooLong;
                }
            }

            if (stdout_open or stderr_open) {
                std_compat.thread.sleep(POLL_STEP_NS);
            }
        } else {
            const poll_ms: i32 = if (timed_out)
                drainPollMs(drain_deadline_ns)
            else if (timeout_secs == 0)
                -1
            else
                @intCast(@divTrunc(POLL_STEP_NS, std.time.ns_per_ms));
            var poll_fds = [_]std.posix.pollfd{
                .{
                    .fd = if (stdout_open) stdout_file.handle else -1,
                    .events = if (stdout_open) std.posix.POLL.IN | std.posix.POLL.HUP else 0,
                    .revents = 0,
                },
                .{
                    .fd = if (stderr_open) stderr_file.handle else -1,
                    .events = if (stderr_open) std.posix.POLL.IN | std.posix.POLL.HUP else 0,
                    .revents = 0,
                },
            };
            _ = try std.posix.poll(&poll_fds, poll_ms);

            if (stdout_open and (poll_fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0) {
                const n = stdout_file.read(&read_buf) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    else => return err,
                };
                if (n == 0) {
                    stdout_open = false;
                } else {
                    try stdout.appendSlice(allocator, read_buf[0..n]);
                    if (stdout.items.len > MAX_OUTPUT_BYTES) return error.StdoutStreamTooLong;
                }
            }

            if (stderr_open and (poll_fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0) {
                const n = stderr_file.read(&read_buf) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    else => return err,
                };
                if (n == 0) {
                    stderr_open = false;
                } else {
                    try stderr.appendSlice(allocator, read_buf[0..n]);
                    if (stderr.items.len > MAX_OUTPUT_BYTES) return error.StderrStreamTooLong;
                }
            }

            if (timed_out and std_compat.time.monotonicNanoTimestamp() >= drain_deadline_ns) break;
        }

        if (!timed_out and hasTimeoutExpired(start_ns, timeout_secs)) {
            try terminateChildHard(child);
            timed_out = true;
            // Monotonic: a wall-clock step must not stretch the bounded drain.
            drain_deadline_ns = std_compat.time.monotonicNanoTimestamp() + POST_KILL_DRAIN_NS;
        }
    }

    return timed_out;
}

/// Poll timeout for the bounded post-kill drain: the time left until
/// `deadline_ns`, never negative (which would mean "wait forever").
fn drainPollMs(deadline_ns: i128) i32 {
    const left_ns = deadline_ns - std_compat.time.monotonicNanoTimestamp();
    if (left_ns <= 0) return 0;
    return @intCast(@divTrunc(left_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms));
}

fn terminateChildHard(child: *std_compat.process.Child) !void {
    if (comptime builtin.os.tag == .windows) {
        _ = child.kill() catch return;
        return;
    }
    if (comptime builtin.os.tag == .wasi) return error.UnsupportedOperation;

    // The child runs in its own process group (see `run`), so the timeout
    // reaches every descendant: a grandchild that inherited the pipes would
    // otherwise hold them open, and the collector with them, for as long as
    // it lives.
    process_util.terminateProcessGroupAndReap(child, process_util.timeout_term_grace_ns);
}

fn buildAgentOutput(
    allocator: std.mem.Allocator,
    stdout: []const u8,
    stderr: []const u8,
    timeout_secs: u64,
    timed_out: bool,
) ![]const u8 {
    if (timed_out) {
        const source = if (stdout.len > 0) stdout else stderr;
        if (source.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}\n\n[agent timed out after {d}s]", .{ source, timeout_secs });
        }
        return std.fmt.allocPrint(allocator, "agent timed out after {d}s", .{timeout_secs});
    }

    const output_source = if (stdout.len > 0) stdout else if (stderr.len > 0) stderr else "";
    return allocator.dupe(u8, output_source);
}

fn preferExecPath(self_exe_path: []const u8) []const u8 {
    if (comptime builtin.os.tag == .linux) {
        if (std.mem.endsWith(u8, self_exe_path, DELETED_EXE_SUFFIX)) {
            return LINUX_SELF_EXE_PATH;
        }
    }
    return self_exe_path;
}

pub fn run(
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    prompt: []const u8,
    model: ?[]const u8,
    timeout_secs: u64,
) !AgentRunResult {
    const exe_path = try std_compat.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    var exec_path = preferExecPath(exe_path);
    var exec_cwd = cwd;
    var tried_no_cwd = false;
    var tried_proc_self_exe = std.mem.eql(u8, exec_path, LINUX_SELF_EXE_PATH);
    var tried_path_exec = false;

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);

    var child: std_compat.process.Child = undefined;
    spawn_loop: while (true) {
        argv.clearRetainingCapacity();
        try argv.append(allocator, exec_path);
        try argv.append(allocator, "agent");
        if (model) |m| {
            try argv.append(allocator, "--model");
            try argv.append(allocator, m);
        }
        try argv.append(allocator, "-m");
        try argv.append(allocator, prompt);

        child = std_compat.process.Child.init(argv.items, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.cwd = exec_cwd;
        process_util.isolateProcessGroup(&child);

        child.spawn() catch |err| switch (err) {
            error.FileNotFound => {
                // If cwd disappeared, retry from process cwd.
                if (exec_cwd != null and !tried_no_cwd) {
                    exec_cwd = null;
                    tried_no_cwd = true;
                    continue :spawn_loop;
                }

                // If current binary path became stale after in-place rebuild,
                // Linux can still re-exec through /proc/self/exe.
                if (comptime builtin.os.tag == .linux) {
                    if (!tried_proc_self_exe and !std.mem.eql(u8, exec_path, LINUX_SELF_EXE_PATH)) {
                        exec_path = LINUX_SELF_EXE_PATH;
                        exec_cwd = cwd;
                        tried_no_cwd = false;
                        tried_proc_self_exe = true;
                        continue :spawn_loop;
                    }
                }

                // Cross-platform fallback: try resolving `nullclaw` from PATH.
                // Useful when self-exe path is stale or inaccessible outside Linux.
                if (!tried_path_exec) {
                    exec_path = pathAgentExecutableName();
                    exec_cwd = null;
                    tried_no_cwd = true;
                    tried_path_exec = true;
                    continue :spawn_loop;
                }

                return err;
            },
            else => return err,
        };
        break :spawn_loop;
    }

    errdefer process_util.abortChild(&child);

    const start_ns = std_compat.time.nanoTimestamp();

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    const timed_out = try collectChildOutputWithTimeout(
        &child,
        allocator,
        &stdout,
        &stderr,
        timeout_secs,
        start_ns,
    );

    const term = try child.wait();
    const success = !timed_out and switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    const output = try buildAgentOutput(allocator, stdout.items, stderr.items, timeout_secs, timed_out);
    return .{ .success = success, .output = output };
}

// ── Tests ──────────────────────────────────────────────────────────

test "collectChildOutputWithTimeout disables timeout when set to zero" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var child = std_compat.process.Child.init(&.{ platform.getShell(), platform.getShellFlag(), "echo ready" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    errdefer process_util.abortChild(&child);

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    const timed_out = try collectChildOutputWithTimeout(
        &child,
        allocator,
        &stdout,
        &stderr,
        0,
        std_compat.time.nanoTimestamp(),
    );
    const term = try child.wait();

    try std.testing.expect(!timed_out);
    switch (term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => try std.testing.expect(false),
    }
    try std.testing.expect(std.mem.indexOf(u8, stdout.items, "ready") != null);
}

test "collectChildOutputWithTimeout kills process after deadline" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var child = std_compat.process.Child.init(&.{ platform.getShell(), platform.getShellFlag(), "sleep 2; echo never" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    process_util.applyProcessGroupPolicy(&child, false);
    try child.spawn();
    errdefer process_util.abortChild(&child);

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    const start_ns = std_compat.time.nanoTimestamp();
    const timed_out = try collectChildOutputWithTimeout(
        &child,
        allocator,
        &stdout,
        &stderr,
        1,
        start_ns,
    );
    const elapsed_ns = std_compat.time.nanoTimestamp() - start_ns;
    const term = try child.wait();

    try std.testing.expect(timed_out);
    const completed_ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    try std.testing.expect(!completed_ok);
    // Regression: only the shell was SIGKILLed and the collector then waited
    // for EOF, which the `sleep 2` grandchild held off — a 1s timeout took 2s.
    try std.testing.expect(elapsed_ns < 1800 * std.time.ns_per_ms);
    try std.testing.expectEqualStrings("", stdout.items);
}

test "collectChildOutputWithTimeout kills the timed-out child's descendants" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try std_compat.fs.Dir.wrap(tmp_dir.dir).realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const pid_path = try std_compat.fs.path.join(allocator, &.{ tmp_path, "grandchild.pid" });
    defer allocator.free(pid_path);
    const command = try std.fmt.allocPrint(allocator, "sleep 30 & echo $! > \"{s}\"; wait", .{pid_path});
    defer allocator.free(command);

    var child = std_compat.process.Child.init(&.{ platform.getShell(), platform.getShellFlag(), command }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    process_util.applyProcessGroupPolicy(&child, false);
    try child.spawn();
    errdefer process_util.abortChild(&child);

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    const start_ns = std_compat.time.nanoTimestamp();
    const timed_out = try collectChildOutputWithTimeout(&child, allocator, &stdout, &stderr, 1, start_ns);
    const elapsed_ns = std_compat.time.nanoTimestamp() - start_ns;
    // The collector reaped the child, so it must also have released the pipes.
    try std.testing.expect(child.stdout == null and child.stderr == null);
    _ = try child.wait();

    const pid_bytes = try std_compat.fs.cwd().readFileAlloc(allocator, pid_path, 32);
    defer allocator.free(pid_bytes);
    const grandchild = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid_bytes, " \t\r\n"), 10);
    defer if (process_util.processExists(grandchild)) std.posix.kill(grandchild, std.posix.SIG.KILL) catch {};

    try std.testing.expect(timed_out);
    // Regression: the grandchild held the pipes open, so the "1s" timeout
    // lasted as long as the grandchild (30s here, forever for a stuck one).
    try std.testing.expect(elapsed_ns < 1800 * std.time.ns_per_ms);
    // Killed, not orphaned. A zombie awaiting PID 1's reap counts as gone.
    var gone = false;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        if (process_util.processExitedOrZombie(grandchild)) {
            gone = true;
            break;
        }
        std_compat.thread.sleep(20 * std.time.ns_per_ms);
    }
    try std.testing.expect(gone);
}

test "collectChildOutputWithTimeout does not wait for a descendant that left the process group" {
    // `setsid` the command is util-linux; the escape itself is what is tested.
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try std_compat.fs.Dir.wrap(tmp_dir.dir).realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const pid_path = try std_compat.fs.path.join(allocator, &.{ tmp_path, "escaped.pid" });
    defer allocator.free(pid_path);
    // setsid moves the background sleep into a new session (and group) that
    // the timeout cannot reach, while it keeps the inherited pipes open.
    const command = try std.fmt.allocPrint(allocator, "setsid sleep 30 & echo $! > \"{s}\"; wait", .{pid_path});
    defer allocator.free(command);

    var child = std_compat.process.Child.init(&.{ platform.getShell(), platform.getShellFlag(), command }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    process_util.applyProcessGroupPolicy(&child, false);
    try child.spawn();
    errdefer process_util.abortChild(&child);

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    const start_ns = std_compat.time.nanoTimestamp();
    const timed_out = try collectChildOutputWithTimeout(&child, allocator, &stdout, &stderr, 1, start_ns);
    const elapsed_ns = std_compat.time.nanoTimestamp() - start_ns;
    _ = try child.wait();

    const pid_bytes = try std_compat.fs.cwd().readFileAlloc(allocator, pid_path, 32);
    defer allocator.free(pid_bytes);
    const escaped = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid_bytes, " \t\r\n"), 10);
    // Out of the timeout's reach by construction; clean it up here.
    std.posix.kill(escaped, std.posix.SIG.KILL) catch {};

    try std.testing.expect(timed_out);
    // The post-kill drain is bounded: the escaped process's open pipe end
    // must not hold the collector the way the old `poll(-1)` did.
    try std.testing.expect(elapsed_ns < 1800 * std.time.ns_per_ms);
}

test "collectChildOutputWithTimeout aborts a TERM-ignoring child whose output overflows the cap, boundedly" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    // Regression: `run`'s `errdefer { kill(); wait(); }` SIGTERMed the `sh -c`
    // wrapper alone and then waited without bound; the wrapper ignores TERM
    // and waits for `head`, blocked writing into the still-open pipe, so a
    // heartbeat agent run that overflowed its output cap hung the daemon.
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try std_compat.fs.Dir.wrap(tmp_dir.dir).realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const pid_path = try std_compat.fs.path.join(allocator, &.{ tmp_path, "grandchild.pid" });
    defer allocator.free(pid_path);
    const command = try std.fmt.allocPrint(
        allocator,
        "trap '' TERM; sleep 30 & echo $! > \"{s}\"; head -c 2000000 /dev/zero >&2; wait",
        .{pid_path},
    );
    defer allocator.free(command);

    var child = std_compat.process.Child.init(&.{ platform.getShell(), platform.getShellFlag(), command }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    process_util.applyProcessGroupPolicy(&child, false);
    try child.spawn();
    const pid = child.id;
    // Never Child.kill() here: that is the unbounded wait under test.
    defer if (child.term == null) {
        std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
        _ = child.wait() catch {};
    };

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    const start_ns = std_compat.time.nanoTimestamp();
    const result = collectChildOutputWithTimeout(&child, allocator, &stdout, &stderr, 60, start_ns);
    const elapsed_ns = std_compat.time.nanoTimestamp() - start_ns;

    try std.testing.expectError(error.StderrStreamTooLong, result);
    try std.testing.expect(elapsed_ns < 5 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(?std_compat.process.Child.Term, .{ .signal = std.posix.SIG.KILL }), child.term);
    try std.testing.expect(child.stdout == null and child.stderr == null);
    try std.testing.expectEqual(std_compat.process.Child.Term{ .signal = std.posix.SIG.KILL }, try child.wait());
    try std.testing.expect(process_util.processExitedOrZombie(pid));

    const pid_bytes = try std_compat.fs.cwd().readFileAlloc(allocator, pid_path, 32);
    defer allocator.free(pid_bytes);
    const grandchild = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid_bytes, " \t\r\n"), 10);
    defer if (!process_util.processExitedOrZombie(grandchild)) std.posix.kill(grandchild, std.posix.SIG.KILL) catch {};
    var gone = false;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        if (process_util.processExitedOrZombie(grandchild)) {
            gone = true;
            break;
        }
        std_compat.thread.sleep(20 * std.time.ns_per_ms);
    }
    try std.testing.expect(gone);
}

test "preferExecPath keeps regular executable path" {
    const input = "/home/user/bin/nullclaw";
    try std.testing.expectEqualStrings(input, preferExecPath(input));
}

test "preferExecPath uses proc self exe for deleted linux path" {
    if (comptime builtin.os.tag != .linux) return;
    try std.testing.expectEqualStrings(LINUX_SELF_EXE_PATH, preferExecPath("/tmp/nullclaw (deleted)"));
}

test "pathAgentExecutableName returns platform command name" {
    const expected = if (comptime builtin.os.tag == .windows) "nullclaw.exe" else "nullclaw";
    try std.testing.expectEqualStrings(expected, pathAgentExecutableName());
}
