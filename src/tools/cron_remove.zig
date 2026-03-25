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

/// CronRemove tool — removes a scheduled cron job by its ID.
pub const CronRemoveTool = struct {
    pub const tool_name = "cron_remove";
    pub const tool_description = "Remove a scheduled cron job by its ID.";
    pub const tool_params =
        \\{"type":"object","properties":{"job_id":{"type":"string","description":"ID of the cron job to remove"}},"required":["job_id"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *CronRemoveTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(_: *CronRemoveTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const job_id = root.getString(args, "job_id") orelse
            return ToolResult.fail("Missing required parameter: job_id");

        if (job_id.len == 0)
            return ToolResult.fail("Missing required parameter: job_id");

        const gateway_body = cron_gateway.buildIdBody(allocator, job_id) catch null;
        if (gateway_body) |json_body| {
            defer allocator.free(json_body);
            switch (cron.requestGatewayPost(allocator, "/cron/remove", json_body)) {
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

        if (scheduler.removeJob(job_id)) {
            if (try persistSchedulerOrFail(allocator, &scheduler)) |result| return result;
            const msg = try std.fmt.allocPrint(allocator, "Removed cron job {s}", .{job_id});
            return ToolResult{ .success = true, .output = msg };
        }

        const msg = try std.fmt.allocPrint(allocator, "Job '{s}' not found", .{job_id});
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "cron_remove_requires_job_id" {
    var t = CronRemoveTool{};
    const tool_iface = t.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try tool_iface.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "job_id") != null);
}

test "cron_remove_not_found" {
    var t = CronRemoveTool{};
    const tool_iface = t.tool();
    const parsed = try root.parseTestArgs("{\"job_id\": \"nonexistent-999\"}");
    defer parsed.deinit();
    const result = try tool_iface.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not found") != null);
}

test "cron_remove_success" {
    // Test removeJob on an isolated in-memory scheduler with tmpDir persistence.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path_str = try std.fmt.allocPrint(allocator, "{s}/remove.db", .{base});
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

    // Remove
    try std.testing.expect(scheduler.removeJob(job_id));
    try cron.saveJobs(&scheduler);

    // Verify removed from persisted state
    var loaded = CronScheduler.init(allocator, 10, true);
    loaded.db_path = db_path_z;
    defer loaded.deinit();
    try cron.loadJobsStrict(&loaded);
    try std.testing.expect(loaded.getJob(job_id) == null);
}

test "cron_remove tool name" {
    var t = CronRemoveTool{};
    const tool_iface = t.tool();
    try std.testing.expectEqualStrings("cron_remove", tool_iface.name());
}

test "cron_remove schema has job_id" {
    var t = CronRemoveTool{};
    const tool_iface = t.tool();
    const schema = tool_iface.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "job_id") != null);
}

test "cron_remove empty job_id" {
    var t = CronRemoveTool{};
    const tool_iface = t.tool();
    const parsed = try root.parseTestArgs("{\"job_id\": \"\"}");
    defer parsed.deinit();
    const result = try tool_iface.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "job_id") != null);
}

test "cron_remove gateway request body includes id" {
    const body = try cron_gateway.buildIdBody(std.testing.allocator, "job-123");
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("job-123", parsed.value.object.get("id").?.string);
}
