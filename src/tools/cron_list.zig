const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const cron = @import("../cron.zig");
const CronScheduler = cron.CronScheduler;
const cron_backend_mod = @import("../cron/root.zig");
const cron_add = @import("cron_add.zig");
const loadScheduler = cron_add.loadScheduler;
const loadDbBackend = cron_add.loadDbBackend;

/// CronList tool — lists all scheduled cron jobs with their status and next run time.
pub const CronListTool = struct {
    pub const tool_name = "cron_list";
    pub const tool_description = "List all scheduled cron jobs with their status and next run time.";
    pub const tool_params =
        \\{"type":"object","properties":{}}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *CronListTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(_: *CronListTool, allocator: std.mem.Allocator, _: JsonObjectMap) !ToolResult {
        // DB-direct path
        if (loadDbBackend(allocator)) |be_val| {
            var be = be_val;
            defer be.deinit();
            var backend = be.backend();

            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            var count: usize = 0;

            const ListCtx = struct {
                buf: *std.ArrayList(u8),
                alloc: std.mem.Allocator,
                count: *usize,

                fn visit(ptr: *anyopaque, row: cron_backend_mod.CronJobSummary) anyerror!void {
                    const ctx: *@This() = @ptrCast(@alignCast(ptr));
                    const status: []const u8 = if (row.paused) "paused" else "enabled";
                    const cmd_label: []const u8 = if (row.skill_name) |sn| sn else if (row.name) |n| n else "?";
                    var buf_writer: std.Io.Writer.Allocating = .fromArrayList(ctx.alloc, ctx.buf);
                    const wr = &buf_writer.writer;
                    try wr.print("- {s} | {s} | {s} | next: {d} | cmd: {s}", .{
                        row.id,
                        row.expression,
                        status,
                        row.next_run_secs,
                        cmd_label,
                    });
                    if (row.skill_args) |args| try wr.print(" {s}", .{args});
                    try wr.print("\n", .{});
                    ctx.buf.* = buf_writer.toArrayList();
                    ctx.count.* += 1;
                }
            };
            var ctx = ListCtx{ .buf = &buf, .alloc = allocator, .count = &count };
            backend.listRows(allocator, .{
                .ptr = @ptrCast(&ctx),
                .visit = ListCtx.visit,
            }) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "DB error listing jobs: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
            if (count == 0) {
                return ToolResult{ .success = true, .output = try allocator.dupe(u8, "No scheduled cron jobs.") };
            }
            return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
        }

        var scheduler = loadScheduler(allocator) catch {
            return ToolResult{ .success = true, .output = try allocator.dupe(u8, "No scheduled cron jobs.") };
        };
        defer scheduler.deinit();

        const jobs = scheduler.listJobs();
        if (jobs.len == 0) {
            return ToolResult{ .success = true, .output = try allocator.dupe(u8, "No scheduled cron jobs.") };
        }

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        var buf_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
        const w = &buf_writer.writer;
        for (jobs) |job| {
            const status: []const u8 = if (job.paused) "paused" else "enabled";
            try w.print("- {s} | {s} | {s} | next: {d} | cmd: {s}\n", .{
                job.id,
                job.expression,
                status,
                job.next_run_secs,
                job.command,
            });
        }
        buf = buf_writer.toArrayList();
        return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "cron_list_empty" {
    // An empty scheduler should produce no formatted output
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();

    const jobs = scheduler.listJobs();
    try std.testing.expectEqual(@as(usize, 0), jobs.len);
}

test "cron_list_with_jobs" {
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();

    const job = try scheduler.addJob("*/5 * * * *", "echo hello");
    try std.testing.expect(scheduler.listJobs().len == 1);

    // Format output the same way the tool does, to verify content
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var buf_writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);
    const w = &buf_writer.writer;
    const status: []const u8 = if (job.paused) "paused" else "enabled";
    try w.print("- {s} | {s} | {s} | next: {d} | cmd: {s}\n", .{
        job.id,
        job.expression,
        status,
        job.next_run_secs,
        job.command,
    });
    buf = buf_writer.toArrayList();
    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, job.id) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "enabled") != null);
}

test "cron_list_shows_paused" {
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();

    const job = try scheduler.addJob("0 * * * *", "echo paused_test");
    try std.testing.expect(scheduler.pauseJob(job.id));

    const jobs = scheduler.listJobs();
    try std.testing.expect(jobs.len == 1);
    try std.testing.expect(jobs[0].paused);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var buf_writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);
    const w = &buf_writer.writer;
    const status: []const u8 = if (jobs[0].paused) "paused" else "enabled";
    try w.print("- {s} | {s} | {s} | next: {d} | cmd: {s}\n", .{
        jobs[0].id,
        jobs[0].expression,
        status,
        jobs[0].next_run_secs,
        jobs[0].command,
    });
    buf = buf_writer.toArrayList();
    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "paused") != null);
}

test "cron_list tool name" {
    var cl = CronListTool{};
    const t = cl.tool();
    try std.testing.expectEqualStrings("cron_list", t.name());
}

test "cron_list tool parameters" {
    var cl = CronListTool{};
    const t = cl.tool();
    const params = t.parametersJson();
    try std.testing.expect(params[0] == '{');
}

test "cron_list execute returns success" {
    var cl = CronListTool{};
    const t = cl.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    // Either "No scheduled cron jobs." or a formatted job list
    try std.testing.expect(result.output.len > 0);
}
