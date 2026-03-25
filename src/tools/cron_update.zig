const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const cron = @import("../cron.zig");
const CronScheduler = cron.CronScheduler;
const cron_gateway = @import("cron_gateway.zig");
const cron_add = @import("cron_add.zig");
const loadScheduler = cron_add.loadScheduler;
const persistSchedulerOrFail = cron_add.persistSchedulerOrFail;

/// CronUpdate tool — update a cron job's expression, command, or enabled state.
pub const CronUpdateTool = struct {
    pub const tool_name = "cron_update";
    pub const tool_description = "Update a cron job: change expression, command, or enable/disable it.";
    pub const tool_params =
        \\{"type":"object","properties":{"job_id":{"type":"string","description":"ID of the cron job to update"},"expression":{"type":"string","description":"New cron expression"},"command":{"type":"string","description":"New command to execute"},"enabled":{"type":"boolean","description":"Enable or disable the job"}},"required":["job_id"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *CronUpdateTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(_: *CronUpdateTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const job_id = root.getString(args, "job_id") orelse
            return ToolResult.fail("Missing 'job_id' parameter");

        const expression = root.getString(args, "expression");
        const command = root.getString(args, "command");
        const enabled = root.getBool(args, "enabled");

        // Validate that at least one field is being updated
        if (expression == null and command == null and enabled == null)
            return ToolResult.fail("Nothing to update — provide expression, command, or enabled");

        // Validate expression if provided
        if (expression) |expr| {
            _ = cron.normalizeExpression(expr) catch
                return ToolResult.fail("Invalid cron expression");
        }

        const gateway_body = cron_gateway.buildUpdateBody(allocator, job_id, expression, command, null, null, enabled) catch null;
        if (gateway_body) |json_body| {
            defer allocator.free(json_body);
            switch (cron.requestGatewayPost(allocator, "/cron/update", json_body)) {
                .unavailable => {},
                .response => |resp| {
                    if (resp.status_code >= 200 and resp.status_code < 300) {
                        return ToolResult{ .success = true, .output = resp.body };
                    }
                    return ToolResult{ .success = false, .output = "", .error_msg = resp.body };
                },
            }
        }

        var scheduler = loadScheduler(allocator) catch {
            return ToolResult.fail("Failed to load scheduler state");
        };
        defer scheduler.deinit();

        const patch = cron.CronJobPatch{
            .expression = expression,
            .command = command,
            .enabled = enabled,
        };

        if (!scheduler.updateJob(allocator, job_id, patch)) {
            const msg = try std.fmt.allocPrint(allocator, "Job '{s}' not found", .{job_id});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        if (try persistSchedulerOrFail(allocator, &scheduler)) |result| return result;

        // Build summary of what changed
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);
        try w.print("Updated job {s}", .{job_id});
        if (expression) |expr| try w.print(" | expression={s}", .{expr});
        if (command) |cmd| try w.print(" | command={s}", .{cmd});
        if (enabled) |ena| try w.print(" | enabled={s}", .{if (ena) "true" else "false"});

        return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "cron_update tool name" {
    var ct = CronUpdateTool{};
    const t = ct.tool();
    try std.testing.expectEqualStrings("cron_update", t.name());
}

test "cron_update schema has job_id" {
    var ct = CronUpdateTool{};
    const t = ct.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "job_id") != null);
}

test "cron_update_requires_job_id" {
    var ct = CronUpdateTool{};
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "job_id") != null);
}

test "cron_update_requires_something" {
    var ct = CronUpdateTool{};
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{\"job_id\": \"job-1\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Nothing to update") != null);
}

test "cron_update_expression" {
    // Test updateJob on an isolated in-memory scheduler with tmpDir persistence.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path_str = try std.fmt.allocPrint(allocator, "{s}/update_expr.db", .{base});
    defer allocator.free(db_path_str);
    const db_path_z = try allocator.dupeZ(u8, db_path_str);
    defer allocator.free(db_path_z);

    var scheduler = CronScheduler.init(allocator, 1024, true);
    scheduler.db_path = db_path_z;
    defer scheduler.deinit();

    const job = try scheduler.addJob("*/5 * * * *", "echo hi");
    const job_id = try allocator.dupe(u8, job.id);
    defer allocator.free(job_id);
    try cron.saveJobs(&scheduler);

    // Update expression
    const updated = scheduler.updateJob(allocator, job_id, .{ .expression = "*/10 * * * *" });
    try std.testing.expect(updated);
    try cron.saveJobs(&scheduler);

    // Verify persisted change
    var loaded = CronScheduler.init(allocator, 10, true);
    loaded.db_path = db_path_z;
    defer loaded.deinit();
    try cron.loadJobsStrict(&loaded);
    const loaded_job = loaded.getJob(job_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("*/10 * * * *", loaded_job.expression);
}

test "cron_update_disable" {
    // Test disabling a job on an isolated scheduler with tmpDir persistence.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path_str = try std.fmt.allocPrint(allocator, "{s}/update_disable.db", .{base});
    defer allocator.free(db_path_str);
    const db_path_z = try allocator.dupeZ(u8, db_path_str);
    defer allocator.free(db_path_z);

    var scheduler = CronScheduler.init(allocator, 1024, true);
    scheduler.db_path = db_path_z;
    defer scheduler.deinit();

    const job = try scheduler.addJob("*/5 * * * *", "echo hi");
    const job_id = try allocator.dupe(u8, job.id);
    defer allocator.free(job_id);
    try cron.saveJobs(&scheduler);

    // Disable
    const updated = scheduler.updateJob(allocator, job_id, .{ .enabled = false });
    try std.testing.expect(updated);
    try cron.saveJobs(&scheduler);

    // Verify persisted change
    var loaded = CronScheduler.init(allocator, 10, true);
    loaded.db_path = db_path_z;
    defer loaded.deinit();
    try cron.loadJobsStrict(&loaded);
    const loaded_job = loaded.getJob(job_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!loaded_job.enabled);
}

test "cron_update_not_found" {
    var ct = CronUpdateTool{};
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{\"job_id\": \"nonexistent-999\", \"command\": \"echo new\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not found") != null);
}

test "cron_update_invalid_expression" {
    var ct = CronUpdateTool{};
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{\"job_id\": \"job-1\", \"expression\": \"bad\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Invalid cron expression") != null);
}

test "cron_update gateway request body keeps enabled false" {
    const body = try cron_gateway.buildUpdateBody(std.testing.allocator, "job-42", null, "echo hi", null, null, false);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("job-42", parsed.value.object.get("id").?.string);
    try std.testing.expectEqualStrings("echo hi", parsed.value.object.get("command").?.string);
    try std.testing.expect(!parsed.value.object.get("enabled").?.bool);
}
