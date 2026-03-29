const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const cron = @import("../cron.zig");
const CronScheduler = cron.CronScheduler;
const cron_gateway = @import("cron_gateway.zig");
const cron_db_mod = @import("../cron/db.zig");
const cron_types = @import("../cron/types.zig");

pub fn persistSchedulerOrFail(allocator: std.mem.Allocator, scheduler: *const CronScheduler) !?ToolResult {
    cron.saveJobs(scheduler) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to persist scheduler state: {s}", .{@errorName(err)});
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    };
    return null;
}

/// CronAdd tool — creates a new cron job with either a cron expression or a delay.
pub const CronAddTool = struct {
    pub const tool_name = "cron_add";
    pub const tool_description = "Create a scheduled cron job. Provide either 'expression' (cron syntax) or 'delay' (e.g. '30m', '2h') plus 'command'.";
    pub const tool_params =
        \\{"type":"object","properties":{"expression":{"type":"string","description":"Cron expression (e.g. '*/5 * * * *')"},"delay":{"type":"string","description":"Delay for one-shot tasks (e.g. '30m', '2h')"},"command":{"type":"string","description":"Shell command to execute"},"name":{"type":"string","description":"Optional job name"}},"required":["command"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *CronAddTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(_: *CronAddTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const command = root.getString(args, "command") orelse
            return ToolResult.fail("Missing required 'command' parameter");

        const expression = root.getString(args, "expression");
        const delay = root.getString(args, "delay");

        if (expression == null and delay == null)
            return ToolResult.fail("Missing schedule: provide either 'expression' (cron syntax) or 'delay' (e.g. '30m')");

        // Validate expression if provided
        if (expression) |expr| {
            _ = cron.normalizeExpression(expr) catch
                return ToolResult.fail("Invalid cron expression");
        }

        // Validate delay if provided
        if (delay) |d| {
            _ = cron.parseDuration(d) catch
                return ToolResult.fail("Invalid delay format");
        }

        // DB-direct path: try DbCronBackend first, fall back to CronScheduler.
        if (loadDbBackend(allocator)) |be_val| {
            var be = be_val;
            defer be.deinit();
            var backend = be.backend();

            const expr_str = expression orelse "@once";
            const now = std.time.timestamp();
            const next_override: i64 = if (delay) |d|
                now + (cron.parseDuration(d) catch 60)
            else
                0;

            var job_arena = std.heap.ArenaAllocator.init(allocator);
            defer job_arena.deinit();
            const job = backend.add(job_arena.allocator(), .{
                .expression = expr_str,
                .command = command,
                .one_shot = delay != null,
                .delete_after_run = delay != null,
                .next_run_secs_override = next_override,
            }) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to create job: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };

            const msg = try std.fmt.allocPrint(allocator, "Created cron job {s}: {s} \u{2192} {s}", .{
                job.id,
                job.expression,
                job.command,
            });
            return ToolResult{ .success = true, .output = msg };
        }

        var scheduler = loadScheduler(allocator) catch {
            return ToolResult.fail("Failed to load scheduler state");
        };
        defer scheduler.deinit();

        // Prefer expression (recurring) over delay (one-shot)
        if (expression) |expr| {
            const job = scheduler.addJob(expr, command) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to create job: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };

            if (try persistSchedulerOrFail(allocator, &scheduler)) |result| return result;

            const msg = try std.fmt.allocPrint(allocator, "Created cron job {s}: {s} \u{2192} {s}", .{
                job.id,
                job.expression,
                job.command,
            });
            return ToolResult{ .success = true, .output = msg };
        }

        if (delay) |d| {
            const job = scheduler.addOnce(d, command) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to create one-shot task: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };

            if (try persistSchedulerOrFail(allocator, &scheduler)) |result| return result;

            const msg = try std.fmt.allocPrint(allocator, "Created cron job {s}: {s} \u{2192} {s}", .{
                job.id,
                job.expression,
                job.command,
            });
            return ToolResult{ .success = true, .output = msg };
        }

        return ToolResult.fail("Unexpected state: no expression or delay");
    }
};

/// Load the CronScheduler from persisted state (~/.nullclaw/cron.db, falling back to cron.json).
/// Shared by cron_add, cron_list, cron_remove, and schedule tools.
/// Under builtin.is_test, uses an in-memory-only scheduler (no DB) to prevent
/// tests from contaminating the real ~/.nullclaw/cron.db.
pub fn loadScheduler(allocator: std.mem.Allocator) !CronScheduler {
    var scheduler = CronScheduler.init(allocator, 1024, true);
    if (builtin.is_test) return scheduler; // Skip loading from real DB in tests
    cron.loadJobs(&scheduler) catch {};
    return scheduler;
}

/// Open a DbCronBackend pointing at ~/.nullclaw/cron.db.
/// Returns null under builtin.is_test or if SQLite/path resolution fails.
/// Caller must call deinit() on the returned backend.
pub fn loadDbBackend(allocator: std.mem.Allocator) ?cron_db_mod.DbCronBackend {
    if (builtin.is_test) return null;
    const db_path = cron.getCronDbPathZ(allocator) catch return null;
    defer allocator.free(db_path);
    return cron_db_mod.DbCronBackend.init(allocator, db_path) catch return null;
}

// ── Tests ───────────────────────────────────────────────────────────

test "cron_add_requires_command" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs("{\"expression\": \"*/5 * * * *\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "command") != null);
}

test "cron_add_requires_schedule" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs("{\"command\": \"echo hello\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "expression") != null or
        std.mem.indexOf(u8, result.error_msg.?, "delay") != null);
}

test "cron_add_with_expression" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs("{\"expression\": \"*/5 * * * *\", \"command\": \"echo hello\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    if (result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.output, "Created cron job") != null);
    }
}

test "cron_add_with_delay" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs("{\"delay\": \"30m\", \"command\": \"echo later\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    if (result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.output, "Created cron job") != null);
    }
}

test "cron_add_rejects_invalid_expression" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs("{\"expression\": \"bad cron\", \"command\": \"echo fail\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Invalid cron expression") != null);
}

test "cron_add tool name" {
    var cat = CronAddTool{};
    const t = cat.tool();
    try std.testing.expectEqualStrings("cron_add", t.name());
}

test "cron_add schema has command" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "command") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "expression") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "delay") != null);
}

test "cron_add gateway request body preserves delay and command" {
    const body = try cron_gateway.buildAddBody(std.testing.allocator, null, "30m", "echo later", null, null, null, null);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("30m", parsed.value.object.get("delay").?.string);
    try std.testing.expectEqualStrings("echo later", parsed.value.object.get("command").?.string);
}
