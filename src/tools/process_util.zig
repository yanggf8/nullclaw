const std = @import("std");
const std_compat = @import("compat");
const AtomicBool = std.atomic.Value(bool);
const builtin = @import("builtin");
const thread_stacks = @import("../thread_stacks.zig");

// Win32 APIs used for codepage fallback decoding on Windows.
extern "kernel32" fn MultiByteToWideChar(
    code_page: std.os.windows.UINT,
    flags: std.os.windows.DWORD,
    input: ?[*]const u8,
    input_len: i32,
    output: ?[*]u16,
    output_len: i32,
) callconv(.winapi) i32;

extern "kernel32" fn WideCharToMultiByte(
    code_page: std.os.windows.UINT,
    flags: std.os.windows.DWORD,
    input: ?[*]const u16,
    input_len: i32,
    output: ?[*]u8,
    output_len: i32,
    default_char: ?[*]const u8,
    used_default_char: ?*std.os.windows.BOOL,
) callconv(.winapi) i32;

extern "kernel32" fn GetACP() callconv(.winapi) std.os.windows.UINT;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) std.os.windows.UINT;
extern "kernel32" fn GetProcessId(process_handle: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.DWORD;
extern "kernel32" fn WaitForSingleObject(
    handle: std.os.windows.HANDLE,
    milliseconds: std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.DWORD;
extern "kernel32" fn OpenProcess(
    desired_access: std.os.windows.DWORD,
    inherit_handle: std.os.windows.BOOL,
    process_id: std.os.windows.DWORD,
) callconv(.winapi) ?std.os.windows.HANDLE;

const CP_UTF8: std.os.windows.UINT = 65001;
const CP_GBK: std.os.windows.UINT = 936;
const MB_ERR_INVALID_CHARS: std.os.windows.DWORD = 0x00000008;
const PROCESS_SYNCHRONIZE: std.os.windows.DWORD = 0x00100000;
const WAIT_OBJECT_0: std.os.windows.DWORD = 0x00000000;
const WAIT_TIMEOUT: std.os.windows.DWORD = 0x00000102;

threadlocal var thread_interrupt_flag: ?*const AtomicBool = null;

pub fn setThreadInterruptFlag(flag: ?*const AtomicBool) void {
    thread_interrupt_flag = flag;
}

/// Result of a child process execution.
pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    success: bool,
    exit_code: ?u32 = null,
    interrupted: bool = false,
    timed_out: bool = false,

    /// Free both stdout and stderr buffers.
    pub fn deinit(self: *const RunResult, allocator: std.mem.Allocator) void {
        if (self.stdout.len > 0) allocator.free(self.stdout);
        if (self.stderr.len > 0) allocator.free(self.stderr);
    }
};

/// Options for running a child process.
pub const RunOptions = struct {
    cwd: ?[]const u8 = null,
    env_map: ?*std_compat.process.EnvMap = null,
    max_output_bytes: usize = 1_048_576,
    cancel_flag: ?*const AtomicBool = null,
    timeout_ns: ?u64 = null,
};

const ProcessWatcherCtx = struct {
    child: *std_compat.process.Child,
    cancel_flag: ?*const AtomicBool,
    timeout_ns: ?u64,
    done: *AtomicBool,
    timed_out: *AtomicBool,
};

fn terminateWindowsProcessTreeByPid(pid: std.os.windows.DWORD) void {
    if (pid == 0) return;

    var pid_buf: [32]u8 = undefined;
    if (std.fmt.bufPrint(&pid_buf, "{d}", .{pid})) |pid_arg| {
        // `TerminateProcess` only reaches the direct child handle; use
        // `taskkill /T` first so shell wrappers do not strand descendants.
        var taskkill = std_compat.process.Child.init(&.{ "taskkill", "/T", "/F", "/PID", pid_arg }, std.heap.page_allocator);
        taskkill.stdin_behavior = .Ignore;
        taskkill.stdout_behavior = .Ignore;
        taskkill.stderr_behavior = .Ignore;
        taskkill.create_no_window = true;
        _ = taskkill.spawnAndWait() catch null;
    } else |_| {}
}

fn terminateChild(child: *std_compat.process.Child) void {
    if (comptime builtin.os.tag == .windows) {
        terminateWindowsProcessTreeByPid(GetProcessId(child.id));
        _ = child.kill() catch {};
    } else if (comptime builtin.os.tag == .wasi) {
        return;
    } else {
        const process_group_id: std.posix.pid_t = -child.id;
        std.posix.kill(process_group_id, std.posix.SIG.TERM) catch {
            std.posix.kill(child.id, std.posix.SIG.TERM) catch {};
            return;
        };

        std_compat.thread.sleep(100 * std.time.ns_per_ms);
        std.posix.kill(process_group_id, std.posix.SIG.KILL) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => {},
        };
    }
}

/// How long a timed-out process group gets between SIGTERM and SIGKILL.
/// Long enough for a TERM handler to flush and exit, short enough that a
/// child ignoring TERM stalls the collecting worker by at most this much.
/// Paid only when something outlives TERM: the wait ends as soon as the
/// whole group is gone.
pub const timeout_term_grace_ns: u64 = 500 * std.time.ns_per_ms;
/// Bound on reaping the direct child after SIGKILL. SIGKILL cannot be caught,
/// but a process stuck in uninterruptible sleep cannot act on it either; the
/// collecting worker must not wedge behind one.
const kill_reap_bound_ns: u64 = 1 * std.time.ns_per_s;
const group_poll_ns: u64 = 10 * std.time.ns_per_ms;

/// Give a not-yet-spawned child its own process group (pgid = its pid), so a
/// timeout can signal the child together with every descendant it spawns —
/// e.g. the real command behind an `sh -c` wrapper — unless we run
/// interactively.
///
/// Rule: isolate only when our own stdin is NOT a terminal. The gateway under
/// systemd (stdin = /dev/null) and scripted CLI runs isolate. An interactive
/// `nullclaw cron run` keeps the child in our (foreground) group, so Ctrl-C
/// still reaches the child and its descendants, and a child that opens
/// /dev/tty is not stopped by SIGTTIN as a background group. Such a child has
/// no group of its own, so `terminateProcessGroupAndReap` signals the pid
/// alone — still bounded, but its descendants are not reached.
///
/// No-op on Windows/WASI, which have no POSIX process groups.
pub fn isolateProcessGroup(child: *std_compat.process.Child) void {
    applyProcessGroupPolicy(child, std_compat.fs.File.stdin().isTty());
}

/// `isolateProcessGroup` with the "is our stdin a terminal" answer supplied,
/// so tests can exercise both branches without a real tty.
pub fn applyProcessGroupPolicy(child: *std_compat.process.Child, stdin_is_tty: bool) void {
    if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        if (shouldIsolateProcessGroup(stdin_is_tty)) child.pgid = 0;
    }
}

pub fn shouldIsolateProcessGroup(stdin_is_tty: bool) bool {
    return !stdin_is_tty;
}

/// Signal the child's process group; when there is no such group (the child
/// was not spawned with `isolateProcessGroup`) or it cannot be signalled,
/// signal the child itself. Errors are ignored: a child that is already gone
/// needs no signal.
fn signalGroupAndLeader(pid: std.posix.pid_t, sig: std.posix.SIG) void {
    std.posix.kill(-pid, sig) catch {
        std.posix.kill(pid, sig) catch {};
    };
}

/// True while any member of process group `pgid` exists. EPERM means a member
/// exists that we may not signal, so it counts as alive.
fn processGroupAlive(pgid: std.posix.pid_t) bool {
    std.posix.kill(-pgid, @as(std.posix.SIG, @enumFromInt(0))) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        else => return true,
    };
    return true;
}

/// Non-blocking reap of the direct child. True once it has been reaped — or
/// once there is nothing left to reap (ECHILD: e.g. SIGCHLD set to SIG_IGN),
/// so the caller never blocks on a pid that will not report.
fn tryReapChild(pid: std.posix.pid_t) bool {
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    const rc = std.posix.system.waitpid(pid, &status, std.posix.W.NOHANG);
    return switch (std.posix.errno(rc)) {
        .SUCCESS => rc != 0,
        .CHILD => true,
        else => false, // EINTR: try again on the next poll
    };
}

/// Terminate a timed-out child together with its process group, and reap it,
/// without ever waiting unboundedly. POSIX only.
///
///   1. SIGTERM to the group (falls back to the pid when it has no group);
///   2. wait up to `grace_ns` for the child to exit and the group to empty,
///      reaping the child as soon as it exits;
///   3. SIGKILL to whatever is left of the group, and to the child if it is
///      still unreaped;
///   4. reap the child, bounded by `kill_reap_bound_ns`.
///
/// Leaves `child.term` set to SIGKILL — exactly what `Child.kill()` records —
/// so a later `wait()`/`kill()` returns it without touching the (possibly
/// reused) pid again. Does NOT close the stdio pipes: a caller can still drain
/// them, and must then call `closeChildStdio`.
pub fn terminateProcessGroupAndReap(child: *std_compat.process.Child, grace_ns: u64) void {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        // No process groups here; callers keep their own platform path.
        _ = child.kill() catch {};
    } else {
        terminateProcessGroupAndReapPosix(child, grace_ns);
    }
}

fn terminateProcessGroupAndReapPosix(child: *std_compat.process.Child, grace_ns: u64) void {
    if (child.term != null) return;

    const pid = child.id;
    signalGroupAndLeader(pid, std.posix.SIG.TERM);

    var reaped = false;
    var waited_ns: u64 = 0;
    while (true) {
        if (!reaped) reaped = tryReapChild(pid);
        if (reaped and !processGroupAlive(pid)) break;
        if (waited_ns >= grace_ns) break;
        std_compat.thread.sleep(group_poll_ns);
        waited_ns +|= group_poll_ns;
    }

    // Once the child is reaped its pid may be reused, so only the group (whose
    // id outlives the leader while members remain) is signalled after that.
    if (processGroupAlive(pid)) std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
    if (!reaped) {
        std.posix.kill(pid, std.posix.SIG.KILL) catch {};
        waited_ns = 0;
        while (true) {
            reaped = tryReapChild(pid);
            if (reaped or waited_ns >= kill_reap_bound_ns) break;
            std_compat.thread.sleep(group_poll_ns);
            waited_ns +|= group_poll_ns;
        }
        if (!reaped) {
            std.log.warn("child pid={d} not reaped within {d}ms of SIGKILL; reaping it in the background", .{ pid, kill_reap_bound_ns / std.time.ns_per_ms });
            reapInBackground(pid);
        }
    }

    child.term = .{ .signal = std.posix.SIG.KILL };
}

/// Hand an unreaped child to a detached thread that blocks in waitpid until
/// it finally exits. `child.term` is recorded without a reap, so nothing else
/// would ever wait on this pid: in the long-lived daemon it would stay a
/// zombie forever. If the thread cannot be spawned the pid is left as before.
fn reapInBackground(pid: std.posix.pid_t) void {
    const thread = std.Thread.spawn(
        .{ .stack_size = thread_stacks.COORDINATION_STACK_SIZE },
        blockingReap,
        .{pid},
    ) catch |err| {
        std.log.warn("child pid={d}: background reaper not started ({s}); it stays unreaped", .{ pid, @errorName(err) });
        return;
    };
    thread.detach();
}

fn blockingReap(pid: std.posix.pid_t) void {
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (true) {
        const rc = std.posix.system.waitpid(pid, &status, 0);
        switch (std.posix.errno(rc)) {
            .INTR => continue,
            else => return, // reaped, or ECHILD: nothing left to reap
        }
    }
}

/// Test aid: true once `pid` has exited, counting an unreaped zombie as
/// exited. `processExists` (kill(pid, 0)) still sees a zombie, so a killed
/// orphan reads as alive until PID 1 reaps it — which a container's PID 1 may
/// never do promptly. Linux reads the state from /proc; elsewhere it falls
/// back to `processExists`.
pub fn processExitedOrZombie(pid: std.posix.pid_t) bool {
    if (comptime builtin.os.tag == .linux) {
        var path_buf: [48]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return !processExists(pid);
        var stat_buf: [512]u8 = undefined;
        const file = std_compat.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return true,
            else => return !processExists(pid),
        };
        defer file.close();
        const n = file.read(&stat_buf) catch return !processExists(pid);
        const stat = stat_buf[0..n];
        // "pid (comm) S ..." — comm may contain ')' and spaces, so take the
        // state from after the LAST ')'.
        const rparen = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return !processExists(pid);
        if (rparen + 2 >= stat.len) return !processExists(pid);
        return stat[rparen + 2] == 'Z';
    }
    return !processExists(pid);
}

/// Close and forget the child's stdio pipes — what `Child.kill()`/`wait()`
/// do on the way out, for a child whose `term` was recorded without them.
pub fn closeChildStdio(child: *std_compat.process.Child) void {
    if (child.stdin) |f| f.close();
    child.stdin = null;
    if (child.stdout) |f| f.close();
    child.stdout = null;
    if (child.stderr) |f| f.close();
    child.stderr = null;
}

/// Error-path cleanup for a spawned child: terminate it (with its process
/// group on POSIX), reap it and release its stdio, never waiting unboundedly.
///
/// Use this instead of `errdefer { child.kill(); child.wait(); }`. On POSIX
/// `Child.kill()` SIGTERMs the leader pid alone and then waits without bound,
/// so a child that ignores TERM — or an `sh -c` wrapper waiting on a
/// descendant blocked writing into a pipe nobody reads any more — wedges the
/// caller forever.
///
/// Safe on a child that was already reaped or terminated (`child.term` set):
/// it only releases any pipes still held. Afterwards `child.term` is set, so a
/// later `wait()`/`kill()` returns at once.
pub fn abortChild(child: *std_compat.process.Child) void {
    if (comptime builtin.os.tag == .wasi) return;
    if (comptime builtin.os.tag == .windows) {
        // Unchanged Windows behaviour: TerminateProcess, then the reap.
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return;
    }
    if (child.term == null) terminateProcessGroupAndReap(child, timeout_term_grace_ns);
    closeChildStdio(child);
}

fn processWatcherMain(ctx: *ProcessWatcherCtx) void {
    const poll_ns = 20 * std.time.ns_per_ms;
    var waited_ns: u64 = 0;

    while (!ctx.done.load(.acquire)) {
        if (ctx.cancel_flag) |flag| {
            if (flag.load(.acquire)) {
                terminateChild(ctx.child);
                break;
            }
        }
        if (ctx.timeout_ns) |limit| {
            if (waited_ns >= limit) {
                ctx.timed_out.store(true, .release);
                terminateChild(ctx.child);
                break;
            }
        }
        std_compat.thread.sleep(poll_ns);
        waited_ns +|= poll_ns;
    }
}

fn wasInterrupted(cancel_flag: ?*const AtomicBool) bool {
    if (cancel_flag) |flag| {
        return flag.load(.acquire);
    }
    return false;
}

pub fn processExists(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, @as(std.posix.SIG, @enumFromInt(0))) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        else => return true,
    };
    return true;
}

fn processExistsWindows(pid: std.os.windows.DWORD) bool {
    if (pid == 0) return false;

    const handle = OpenProcess(PROCESS_SYNCHRONIZE, .FALSE, pid) orelse return false;
    defer std.os.windows.CloseHandle(handle);

    return switch (WaitForSingleObject(handle, 0)) {
        WAIT_TIMEOUT => true,
        WAIT_OBJECT_0 => false,
        else => false,
    };
}

fn appendUtf8Replacement(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    try out.appendSlice(allocator, "\xEF\xBF\xBD");
}

fn lossilyNormalizeToUtf8(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.ensureTotalCapacity(allocator, input.len);

    var i: usize = 0;
    while (i < input.len) {
        const byte = input[i];
        if (byte < 0x80) {
            try out.append(allocator, byte);
            i += 1;
            continue;
        }

        const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try appendUtf8Replacement(&out, allocator);
            i += 1;
            continue;
        };

        const step: usize = @intCast(seq_len);
        if (i + step > input.len) {
            try appendUtf8Replacement(&out, allocator);
            i += 1;
            continue;
        }

        const candidate = input[i .. i + step];
        _ = std.unicode.utf8Decode(candidate) catch {
            try appendUtf8Replacement(&out, allocator);
            i += 1;
            continue;
        };

        try out.appendSlice(allocator, candidate);
        i += step;
    }

    return out.toOwnedSlice(allocator);
}

fn tryDecodeWindowsCodePageToUtf8(
    allocator: std.mem.Allocator,
    input: []const u8,
    code_page: std.os.windows.UINT,
) !?[]u8 {
    if (input.len == 0 or code_page == 0) return null;

    const in_len: i32 = std.math.cast(i32, input.len) orelse return null;
    // Keep UTF-8 strict so a console forced to CP_UTF8 does not swallow
    // ACP/GBK bytes with U+FFFD substitutions before we can try fallbacks.
    const decode_flags: std.os.windows.DWORD = if (code_page == CP_UTF8) MB_ERR_INVALID_CHARS else 0;

    const wide_len = MultiByteToWideChar(code_page, decode_flags, input.ptr, in_len, null, 0);
    if (wide_len <= 0) return null;

    const wide_len_usize: usize = @intCast(wide_len);
    const wide = try allocator.alloc(u16, wide_len_usize);
    defer allocator.free(wide);

    if (MultiByteToWideChar(code_page, decode_flags, input.ptr, in_len, wide.ptr, wide_len) <= 0) return null;

    const utf8_len = WideCharToMultiByte(CP_UTF8, 0, wide.ptr, wide_len, null, 0, null, null);
    if (utf8_len <= 0) return null;

    const utf8_len_usize: usize = @intCast(utf8_len);
    const out = try allocator.alloc(u8, utf8_len_usize);
    errdefer allocator.free(out);

    if (WideCharToMultiByte(CP_UTF8, 0, wide.ptr, wide_len, out.ptr, utf8_len, null, null) <= 0) return null;

    return out;
}

fn tryDecodeWindowsOutputToUtf8(allocator: std.mem.Allocator, input: []const u8) !?[]u8 {
    const console_cp = GetConsoleOutputCP();
    if (try tryDecodeWindowsCodePageToUtf8(allocator, input, console_cp)) |decoded| return decoded;

    // Prefer GBK before ACP: Western single-byte ACPs like CP1252 will happily
    // decode arbitrary high bytes into mojibake ("ÖÐÎÄ"), which would mask
    // genuine GBK console output that we can still recover losslessly.
    const ansi_cp = GetACP();
    if (console_cp != CP_GBK and ansi_cp != CP_GBK) {
        if (try tryDecodeWindowsCodePageToUtf8(allocator, input, CP_GBK)) |decoded| return decoded;
    }

    if (ansi_cp != console_cp) {
        if (try tryDecodeWindowsCodePageToUtf8(allocator, input, ansi_cp)) |decoded| return decoded;
    }

    return null;
}

fn normalizeCapturedOutputOwned(allocator: std.mem.Allocator, input: []u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(input)) return input;

    if (comptime builtin.os.tag == .windows) {
        if (try tryDecodeWindowsOutputToUtf8(allocator, input)) |decoded| {
            allocator.free(input);
            return decoded;
        }
    }

    const lossy = try lossilyNormalizeToUtf8(allocator, input);
    allocator.free(input);
    return lossy;
}

/// Run a child process, capture stdout and stderr, and return the result.
///
/// The caller owns the returned stdout and stderr buffers.
/// Use `result.deinit(allocator)` to free them.
pub fn run(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    opts: RunOptions,
) !RunResult {
    var child = std_compat.process.Child.init(argv, allocator);
    // Captured child processes are non-interactive; inheriting stdin can let
    // spawned commands stall waiting for input from the parent process.
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        // Isolate the child into its own process group so timeout/cancel signals
        // can terminate shell wrappers together with any descendants they spawn.
        child.pgid = 0;
    }
    if (opts.cwd) |cwd| child.cwd = cwd;
    if (opts.env_map) |env| child.env_map = env;

    try child.spawn();
    // On an error return (output over max_output_bytes, OOM, wait failure)
    // nobody reads the pipes again: abort the child and its group boundedly
    // instead of leaking it blocked on a full pipe. Declared before the
    // watcher's defer, so the watcher is joined first.
    errdefer abortChild(&child);

    const effective_cancel_flag = opts.cancel_flag orelse thread_interrupt_flag;
    const effective_timeout_ns = if (opts.timeout_ns) |limit|
        if (limit == 0) null else limit
    else
        null;
    var cancel_done = AtomicBool.init(false);
    var timed_out = AtomicBool.init(false);
    var cancel_watcher: ?std.Thread = null;
    var watcher_ctx: ProcessWatcherCtx = undefined;
    if (effective_cancel_flag != null or effective_timeout_ns != null) {
        watcher_ctx = .{
            .child = &child,
            .cancel_flag = effective_cancel_flag,
            .timeout_ns = effective_timeout_ns,
            .done = &cancel_done,
            .timed_out = &timed_out,
        };
        cancel_watcher = std.Thread.spawn(.{}, processWatcherMain, .{&watcher_ctx}) catch null;
    }
    defer {
        cancel_done.store(true, .release);
        if (cancel_watcher) |t| t.join();
    }

    var stdout = if (child.stdout) |stdout_file| blk: {
        break :blk stdout_file.readToEndAlloc(allocator, opts.max_output_bytes) catch |err| {
            if (wasInterrupted(effective_cancel_flag) or timed_out.load(.acquire)) {
                break :blk try allocator.dupe(u8, "");
            }
            return err;
        };
    } else try allocator.dupe(u8, "");
    errdefer allocator.free(stdout);
    stdout = try normalizeCapturedOutputOwned(allocator, stdout);

    var stderr = if (child.stderr) |stderr_file| blk: {
        break :blk stderr_file.readToEndAlloc(allocator, opts.max_output_bytes) catch |err| {
            if (wasInterrupted(effective_cancel_flag) or timed_out.load(.acquire)) {
                break :blk try allocator.dupe(u8, "");
            }
            return err;
        };
    } else try allocator.dupe(u8, "");
    errdefer allocator.free(stderr);
    stderr = try normalizeCapturedOutputOwned(allocator, stderr);

    const term = try child.wait();
    const interrupted = wasInterrupted(effective_cancel_flag);
    const did_time_out = timed_out.load(.acquire);

    return switch (term) {
        .exited => |code| .{
            .stdout = stdout,
            .stderr = stderr,
            .success = code == 0,
            .exit_code = code,
            .interrupted = interrupted,
            .timed_out = did_time_out,
        },
        else => .{
            .stdout = stdout,
            .stderr = stderr,
            .success = false,
            .exit_code = null,
            .interrupted = interrupted,
            .timed_out = did_time_out,
        },
    };
}

// ── Tests ───────────────────────────────────────────────────────────

test "run echo returns stdout" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const result = try run(allocator, &.{ "echo", "hello" }, .{});
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u32, 0), result.exit_code.?);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hello") != null);
}

test "run failing command returns exit code" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const result = try run(allocator, &.{ "ls", "/nonexistent_dir_xyz_42" }, .{});
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expect(result.exit_code.? != 0);
    try std.testing.expect(result.stderr.len > 0);
}

test "run with cwd" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const result = try run(allocator, &.{"pwd"}, .{ .cwd = "/tmp" });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    // /tmp may resolve to /private/tmp on macOS
    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "tmp") != null);
}

test "run honors cancel flag and interrupts child" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var cancel = AtomicBool.init(false);

    const ThreadResult = struct {
        res: ?RunResult = null,
        err: ?anyerror = null,
    };
    var thread_result = ThreadResult{};

    const Runner = struct {
        fn runThread(
            allocator_inner: std.mem.Allocator,
            cancel_flag: *const AtomicBool,
            out: *ThreadResult,
        ) void {
            out.res = run(allocator_inner, &.{ "sh", "-c", "sleep 5; echo done" }, .{
                .cancel_flag = cancel_flag,
            }) catch |err| {
                out.err = err;
                return;
            };
        }
    };

    const t = try std.Thread.spawn(.{}, Runner.runThread, .{ allocator, &cancel, &thread_result });
    std_compat.thread.sleep(100 * std.time.ns_per_ms);
    cancel.store(true, .release);
    t.join();

    try std.testing.expect(thread_result.err == null);
    const result = thread_result.res orelse return error.TestUnexpectedResult;
    defer result.deinit(allocator);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.interrupted);
    try std.testing.expect(!result.timed_out);
}

test "run timeout interrupts child" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const result = try run(allocator, &.{ "sh", "-c", "sleep 5" }, .{
        .timeout_ns = 100 * std.time.ns_per_ms,
    });
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expect(!result.interrupted);
    try std.testing.expect(result.timed_out);
}

test "run zero timeout disables watchdog" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const result = try run(allocator, &.{ "sh", "-c", "sleep 0.1; echo done" }, .{
        .timeout_ns = 0,
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(!result.timed_out);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "done") != null);
}

test "run timeout kills Windows shell descendants" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try @import("compat").fs.Dir.wrap(tmp_dir.dir).realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const pid_path = try std_compat.fs.path.join(allocator, &.{ tmp_path, "child.pid" });
    defer allocator.free(pid_path);
    try @import("compat").fs.Dir.wrap(tmp_dir.dir).writeFile(.{
        .sub_path = "child.ps1",
        // Regression: invoking PowerShell through `-Command ... -- arg` is not
        // reliable on GitHub's Windows runner and can let cmd.exe exit before
        // the timeout watchdog fires. Keep the payload in a script file so the
        // wrapper deterministically stays alive until the watchdog kills it.
        .data =
        \\param([string]$PidPath)
        \\$PID | Set-Content -NoNewline -LiteralPath $PidPath
        \\Start-Sleep -Seconds 8
        \\
        ,
    });
    try @import("compat").fs.Dir.wrap(tmp_dir.dir).writeFile(.{
        .sub_path = "wrapper.cmd",
        // Keep cmd.exe in front so the test still exercises descendant cleanup
        // instead of timing out a direct PowerShell child.
        .data =
        \\@echo off
        \\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0child.ps1" "%~dp0child.pid"
        \\
        ,
    });
    const script_path = try std_compat.fs.path.join(allocator, &.{ tmp_path, "wrapper.cmd" });
    defer allocator.free(script_path);

    const result = try run(allocator, &.{ "cmd.exe", "/c", script_path }, .{
        .timeout_ns = 2 * std.time.ns_per_s,
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.timed_out);

    var pid_bytes: ?[]u8 = null;
    var read_attempt: usize = 0;
    while (read_attempt < 20) : (read_attempt += 1) {
        pid_bytes = std_compat.fs.cwd().readFileAlloc(allocator, pid_path, 32) catch |err| switch (err) {
            error.FileNotFound => blk: {
                std_compat.thread.sleep(50 * std.time.ns_per_ms);
                break :blk null;
            },
            else => return err,
        };
        if (pid_bytes != null) break;
    }
    const pid_bytes_owned = pid_bytes orelse return error.FileNotFound;
    defer allocator.free(pid_bytes_owned);
    const child_pid = try std.fmt.parseInt(
        std.os.windows.DWORD,
        std.mem.trim(u8, pid_bytes_owned, " \t\r\n"),
        10,
    );
    defer if (processExistsWindows(child_pid)) terminateWindowsProcessTreeByPid(child_pid);

    var exited = false;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        if (!processExistsWindows(child_pid)) {
            exited = true;
            break;
        }
        std_compat.thread.sleep(50 * std.time.ns_per_ms);
    }

    try std.testing.expect(exited);
}

test "run timeout kills spawned shell descendants" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try @import("compat").fs.Dir.wrap(tmp_dir.dir).realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const pid_path = try std_compat.fs.path.join(allocator, &.{ tmp_path, "child.pid" });
    defer allocator.free(pid_path);
    const command = try std.fmt.allocPrint(allocator, "(sleep 30) & echo $! > \"{s}\"; wait", .{pid_path});
    defer allocator.free(command);

    // Regression: timing out `sh -c ...` must not leave a background child
    // running after the wrapper shell exits.
    const result = try run(allocator, &.{ "sh", "-c", command }, .{
        .timeout_ns = 200 * std.time.ns_per_ms,
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.timed_out);

    const pid_bytes = try std_compat.fs.cwd().readFileAlloc(allocator, pid_path, 32);
    defer allocator.free(pid_bytes);
    const child_pid = try std.fmt.parseInt(
        std.posix.pid_t,
        std.mem.trim(u8, pid_bytes, " \t\r\n"),
        10,
    );
    defer if (processExists(child_pid)) {
        std.posix.kill(child_pid, std.posix.SIG.KILL) catch {};
    };

    var exited = false;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        if (!processExists(child_pid)) {
            exited = true;
            break;
        }
        std_compat.thread.sleep(50 * std.time.ns_per_ms);
    }

    try std.testing.expect(exited);
}

fn waitForFileForTest(path: []const u8) bool {
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        std_compat.fs.cwd().access(path, .{}) catch {
            std_compat.thread.sleep(20 * std.time.ns_per_ms);
            continue;
        };
        return true;
    }
    return false;
}

test "terminateProcessGroupAndReap sends SIGTERM to descendants before SIGKILL" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try std_compat.fs.Dir.wrap(tmp_dir.dir).realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const ready_path = try std_compat.fs.path.join(allocator, &.{ tmp_path, "ready" });
    defer allocator.free(ready_path);
    const term_path = try std_compat.fs.path.join(allocator, &.{ tmp_path, "term" });
    defer allocator.free(term_path);
    // A grandchild that records the SIGTERM it receives, then exits.
    const command = try std.fmt.allocPrint(
        allocator,
        "(trap 'echo term > \"{s}\"; exit 0' TERM; echo ready > \"{s}\"; while :; do sleep 0.05; done) & wait",
        .{ term_path, ready_path },
    );
    defer allocator.free(command);

    var child = std_compat.process.Child.init(&.{ "sh", "-c", command }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    applyProcessGroupPolicy(&child, false);
    try child.spawn();
    errdefer {
        std.posix.kill(-child.id, std.posix.SIG.KILL) catch {};
        _ = child.wait() catch {};
    }
    try std.testing.expect(waitForFileForTest(ready_path));

    terminateProcessGroupAndReap(&child, timeout_term_grace_ns);

    try std.testing.expectEqual(std_compat.process.Child.Term{ .signal = std.posix.SIG.KILL }, try child.wait());
    // The grandchild got TERM (a chance to clean up), not just the final KILL.
    const marker = try std_compat.fs.cwd().readFileAlloc(allocator, term_path, 32);
    defer allocator.free(marker);
    try std.testing.expectEqualStrings("term\n", marker);
}

test "terminateProcessGroupAndReap kills a TERM-ignoring child that has no process group of its own" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    // Spawned WITHOUT isolateProcessGroup: the group signal finds no group
    // (and must never reach the caller's own group), so the pid is signalled.
    var child = std_compat.process.Child.init(&.{ "sh", "-c", "trap '' TERM; exec sleep 30" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    errdefer {
        std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
        _ = child.wait() catch {};
    }
    const pid = child.id;
    std_compat.thread.sleep(100 * std.time.ns_per_ms); // let the trap take effect

    const start_ns = std_compat.time.nanoTimestamp();
    terminateProcessGroupAndReap(&child, timeout_term_grace_ns);
    const elapsed_ns = std_compat.time.nanoTimestamp() - start_ns;

    try std.testing.expectEqual(std_compat.process.Child.Term{ .signal = std.posix.SIG.KILL }, try child.wait());
    try std.testing.expect(!processExists(pid));
    try std.testing.expect(elapsed_ns < timeout_term_grace_ns + 500 * std.time.ns_per_ms);
}

test "terminateProcessGroupAndReap on an already-exited child returns at once and records its term" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var child = std_compat.process.Child.init(&.{ "sh", "-c", "exit 0" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    applyProcessGroupPolicy(&child, false);
    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }
    std_compat.thread.sleep(100 * std.time.ns_per_ms); // now an unreaped zombie

    const start_ns = std_compat.time.nanoTimestamp();
    terminateProcessGroupAndReap(&child, timeout_term_grace_ns);
    const elapsed_ns = std_compat.time.nanoTimestamp() - start_ns;
    closeChildStdio(&child);

    // Reaped here, so wait() must return the recorded term rather than
    // waiting on the pid a second time.
    try std.testing.expectEqual(std_compat.process.Child.Term{ .signal = std.posix.SIG.KILL }, try child.wait());
    try std.testing.expect(child.stdout == null and child.stderr == null);
    try std.testing.expect(elapsed_ns < timeout_term_grace_ns);
    // A second call is a no-op.
    terminateProcessGroupAndReap(&child, timeout_term_grace_ns);
}

test "run aborts a TERM-ignoring child whose output overflows max_output_bytes" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    // Regression: run() returned error.StreamTooLong with the child still
    // alive (its `head` blocked writing into a pipe nobody read) and its
    // process group leaked.
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try std_compat.fs.Dir.wrap(tmp_dir.dir).realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const pids_path = try std_compat.fs.path.join(allocator, &.{ tmp_path, "pids" });
    defer allocator.free(pids_path);
    const command = try std.fmt.allocPrint(
        allocator,
        "trap '' TERM; sleep 30 & echo \"$$ $!\" > \"{s}\"; head -c 2000000 /dev/zero; wait",
        .{pids_path},
    );
    defer allocator.free(command);

    const start_ns = std_compat.time.nanoTimestamp();
    const result = run(allocator, &.{ "sh", "-c", command }, .{ .max_output_bytes = 4096 });
    const elapsed_ns = std_compat.time.nanoTimestamp() - start_ns;
    try std.testing.expectError(error.StreamTooLong, result);
    try std.testing.expect(elapsed_ns < 5 * std.time.ns_per_s);

    const pid_bytes = try std_compat.fs.cwd().readFileAlloc(allocator, pids_path, 64);
    defer allocator.free(pid_bytes);
    var it = std.mem.tokenizeAny(u8, pid_bytes, " \t\r\n");
    const shell_pid = try std.fmt.parseInt(std.posix.pid_t, it.next().?, 10);
    const grandchild = try std.fmt.parseInt(std.posix.pid_t, it.next().?, 10);
    defer {
        if (!processExitedOrZombie(shell_pid)) std.posix.kill(-shell_pid, std.posix.SIG.KILL) catch {};
        if (!processExitedOrZombie(grandchild)) std.posix.kill(grandchild, std.posix.SIG.KILL) catch {};
    }
    try std.testing.expect(processExitedOrZombie(shell_pid));
    var gone = false;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        if (processExitedOrZombie(grandchild)) {
            gone = true;
            break;
        }
        std_compat.thread.sleep(20 * std.time.ns_per_ms);
    }
    try std.testing.expect(gone);
}

test "abortChild bounds a TERM-ignoring child and is a no-op once the child is reaped" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var child = std_compat.process.Child.init(&.{ "sh", "-c", "trap '' TERM; sleep 30 & wait" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    applyProcessGroupPolicy(&child, false);
    try child.spawn();
    const pid = child.id;
    defer if (child.term == null) {
        std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
        _ = child.wait() catch {};
    };
    std_compat.thread.sleep(100 * std.time.ns_per_ms); // let the trap take effect

    const start_ns = std_compat.time.nanoTimestamp();
    abortChild(&child);
    const elapsed_ns = std_compat.time.nanoTimestamp() - start_ns;

    try std.testing.expectEqual(@as(?std_compat.process.Child.Term, .{ .signal = std.posix.SIG.KILL }), child.term);
    try std.testing.expect(child.stdout == null and child.stderr == null);
    try std.testing.expect(elapsed_ns < timeout_term_grace_ns + 500 * std.time.ns_per_ms);
    try std.testing.expect(!processExists(pid)); // reaped, not a zombie
    // Repeating it (errdefer after a collector that already aborted) is a no-op.
    abortChild(&child);
    try std.testing.expectEqual(std_compat.process.Child.Term{ .signal = std.posix.SIG.KILL }, try child.wait());

    // A child reaped by an ordinary wait() keeps its real term untouched.
    var done = std_compat.process.Child.init(&.{ "sh", "-c", "exit 3" }, allocator);
    done.stdin_behavior = .Ignore;
    done.stdout_behavior = .Pipe;
    done.stderr_behavior = .Pipe;
    try done.spawn();
    try std.testing.expectEqual(std_compat.process.Child.Term{ .exited = 3 }, try done.wait());
    abortChild(&done);
    try std.testing.expectEqual(@as(?std_compat.process.Child.Term, .{ .exited = 3 }), done.term);
}

test "isolateProcessGroup isolates only when stdin is not a terminal" {
    // Regression: an interactive `nullclaw cron run` put its child in a new
    // group, so Ctrl-C left the child and its descendants running.
    try std.testing.expect(shouldIsolateProcessGroup(false));
    try std.testing.expect(!shouldIsolateProcessGroup(true));

    var interactive = std_compat.process.Child.init(&.{"true"}, std.testing.allocator);
    applyProcessGroupPolicy(&interactive, true);
    try std.testing.expectEqual(@as(?std.posix.pid_t, null), interactive.pgid);

    var scripted = std_compat.process.Child.init(&.{"true"}, std.testing.allocator);
    applyProcessGroupPolicy(&scripted, false);
    const expected: ?std.posix.pid_t = if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) null else 0;
    try std.testing.expectEqual(expected, scripted.pgid);
}

test "reapInBackground reaps a child that exits after the caller gave up on it" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    // Regression: past the post-SIGKILL bound the term was recorded unreaped
    // and nothing ever waited on the pid — a permanent zombie in the daemon.
    var child = std_compat.process.Child.init(&.{ "sleep", "0.3" }, std.testing.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const pid = child.id;

    reapInBackground(pid);

    // kill(pid, 0) succeeds on a zombie, so "gone" here means reaped.
    var reaped = false;
    var i: usize = 0;
    while (i < 150) : (i += 1) {
        if (!processExists(pid)) {
            reaped = true;
            break;
        }
        std_compat.thread.sleep(20 * std.time.ns_per_ms);
    }
    if (!reaped) _ = tryReapChild(pid);
    try std.testing.expect(reaped);
}

test "processExitedOrZombie counts an unreaped zombie as exited and a live process as not" {
    // Zombies are recognised through /proc only; elsewhere the helper falls
    // back to kill(pid, 0), which still sees an unreaped zombie.
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var live = std_compat.process.Child.init(&.{ "sleep", "30" }, allocator);
    live.stdin_behavior = .Ignore;
    live.stdout_behavior = .Ignore;
    live.stderr_behavior = .Ignore;
    try live.spawn();
    defer {
        std.posix.kill(live.id, std.posix.SIG.KILL) catch {};
        _ = live.wait() catch {};
    }
    try std.testing.expect(!processExitedOrZombie(live.id));

    var done = std_compat.process.Child.init(&.{ "sh", "-c", "exit 0" }, allocator);
    done.stdin_behavior = .Ignore;
    done.stdout_behavior = .Ignore;
    done.stderr_behavior = .Ignore;
    try done.spawn();
    defer _ = done.wait() catch {};
    var i: usize = 0;
    while (i < 100 and !processExitedOrZombie(done.id)) : (i += 1) {
        std_compat.thread.sleep(20 * std.time.ns_per_ms);
    }
    try std.testing.expect(processExitedOrZombie(done.id));
    // Still a zombie (not yet reaped): kill(pid, 0) alone calls it alive.
    try std.testing.expect(processExists(done.id));
}

test "RunResult deinit frees buffers" {
    const allocator = std.testing.allocator;
    const stdout = try allocator.dupe(u8, "output");
    const stderr = try allocator.dupe(u8, "error");
    const result = RunResult{
        .stdout = stdout,
        .stderr = stderr,
        .success = true,
        .exit_code = 0,
    };
    result.deinit(allocator);
}

test "RunResult deinit with empty buffers" {
    const allocator = std.testing.allocator;
    const result = RunResult{
        .stdout = "",
        .stderr = "",
        .success = true,
        .exit_code = 0,
    };
    result.deinit(allocator); // should not crash or attempt to free ""
}

test "normalizeCapturedOutputOwned converts invalid UTF-8 to safe text" {
    const allocator = std.testing.allocator;
    const invalid = try allocator.dupe(u8, &[_]u8{ 'f', 0x80, 'o' });
    const normalized = try normalizeCapturedOutputOwned(allocator, invalid);
    defer allocator.free(normalized);

    try std.testing.expect(std.unicode.utf8ValidateSlice(normalized));
    try std.testing.expect(std.mem.indexOf(u8, normalized, "f") != null);
    try std.testing.expect(std.mem.indexOf(u8, normalized, "o") != null);
}

test "run normalizes invalid stderr before returning" {
    const allocator = std.testing.allocator;
    const argv: []const []const u8 = if (comptime builtin.os.tag == .windows)
        &.{
            "powershell.exe",
            "-NoProfile",
            "-Command",
            "[Console]::OpenStandardError().Write([byte[]](0xD6,0xD0,0xCE,0xC4),0,4); exit 1",
        }
    else
        &.{ "sh", "-c", "printf '\\200' >&2; exit 1" };

    const result = try run(allocator, argv, .{});
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expect(std.unicode.utf8ValidateSlice(result.stderr));
    if (comptime builtin.os.tag == .windows) {
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "中文") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "\xEF\xBF\xBD") != null);
    }
}

test "windows gbk fallback decodes to utf8" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const gbk = [_]u8{ 0xD6, 0xD0, 0xCE, 0xC4 }; // "中文" in GBK/CP936
    const decoded = try tryDecodeWindowsCodePageToUtf8(allocator, &gbk, CP_GBK);
    try std.testing.expect(decoded != null);
    defer allocator.free(decoded.?);

    try std.testing.expect(std.unicode.utf8ValidateSlice(decoded.?));
    const expected_utf8 = [_]u8{ 0xE4, 0xB8, 0xAD, 0xE6, 0x96, 0x87 }; // "zhongwen" (Chinese chars) in UTF-8 bytes
    try std.testing.expectEqualSlices(u8, &expected_utf8, decoded.?);
}

test "windows utf8 decoder rejects gbk bytes so ansi fallback can run" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const gbk = [_]u8{ 0xD6, 0xD0, 0xCE, 0xC4 }; // "中文" in GBK/CP936
    const decoded = try tryDecodeWindowsCodePageToUtf8(allocator, &gbk, CP_UTF8);
    try std.testing.expect(decoded == null);
}
