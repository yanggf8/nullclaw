const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const platform = @import("platform.zig");
const bus = @import("bus.zig");
const fs_compat = @import("fs_compat.zig");
const json_util = @import("json_util.zig");
const Config = @import("config.zig").Config;

const sqlite_mod = if (build_options.enable_sqlite)
    @import("memory/engines/sqlite.zig")
else
    @import("memory/engines/sqlite_disabled.zig");
const c = sqlite_mod.c;
const SQLITE_STATIC = sqlite_mod.SQLITE_STATIC;

const log = std.log.scoped(.cron);

pub const JobType = enum {
    shell,
    agent,
    skill,

    pub fn asStr(self: JobType) []const u8 {
        return switch (self) {
            .shell => "shell",
            .agent => "agent",
            .skill => "skill",
        };
    }

    pub fn parse(raw: []const u8) JobType {
        if (std.ascii.eqlIgnoreCase(raw, "agent")) return .agent;
        if (std.ascii.eqlIgnoreCase(raw, "skill")) return .skill;
        return .shell;
    }
};

pub const SessionTarget = enum {
    isolated,
    main,

    pub fn asStr(self: SessionTarget) []const u8 {
        return switch (self) {
            .isolated => "isolated",
            .main => "main",
        };
    }

    pub fn parse(raw: []const u8) SessionTarget {
        if (std.ascii.eqlIgnoreCase(raw, "main")) return .main;
        return .isolated;
    }
};

pub const ScheduleKind = enum { cron, at, every };

pub const Schedule = union(ScheduleKind) {
    cron: struct { expr: []const u8, tz: ?[]const u8 },
    at: struct { timestamp_s: i64 },
    every: struct { every_ms: u64 },
};

pub const DeliveryMode = enum {
    none,
    always,
    on_error,
    on_success,

    pub fn asStr(self: DeliveryMode) []const u8 {
        return switch (self) {
            .none => "none",
            .always => "always",
            .on_error => "on_error",
            .on_success => "on_success",
        };
    }

    pub fn parse(raw: []const u8) DeliveryMode {
        if (std.ascii.eqlIgnoreCase(raw, "always")) return .always;
        if (std.ascii.eqlIgnoreCase(raw, "on_error")) return .on_error;
        if (std.ascii.eqlIgnoreCase(raw, "on_success")) return .on_success;
        return .none;
    }
};

pub const DeliveryConfig = struct {
    mode: DeliveryMode = .none,
    channel: ?[]const u8 = null,
    account_id: ?[]const u8 = null,
    to: ?[]const u8 = null,
    best_effort: bool = false,
    channel_owned: bool = false,
    account_id_owned: bool = false,
    to_owned: bool = false,
};

pub const CronRun = struct {
    id: u64,
    job_id: []const u8,
    started_at_s: i64,
    finished_at_s: i64,
    status: []const u8,
    output: ?[]const u8,
    duration_ms: ?i64,
};

pub const CronJobPatch = struct {
    expression: ?[]const u8 = null,
    command: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    name: ?[]const u8 = null,
    enabled: ?bool = null,
    model: ?[]const u8 = null,
    skill_name: ?[]const u8 = null,
    skill_args: ?[]const u8 = null,
    delete_after_run: ?bool = null,
    delivery_channel: ?[]const u8 = null,
    delivery_to: ?[]const u8 = null,
    delivery_mode: ?[]const u8 = null,
    delivery_account_id: ?[]const u8 = null,
    timeout_secs: ?u32 = null,
    next_run_secs: ?i64 = null,
};

/// A scheduled cron job.
pub const CronJob = struct {
    id: []const u8,
    expression: []const u8,
    command: []const u8,
    next_run_secs: i64 = 0,
    last_run_secs: ?i64 = null,
    last_status: ?[]const u8 = null,
    paused: bool = false,
    one_shot: bool = false,
    job_type: JobType = .shell,
    session_target: SessionTarget = .isolated,
    prompt: ?[]const u8 = null,
    name: ?[]const u8 = null,
    model: ?[]const u8 = null,
    skill_name: ?[]const u8 = null,
    skill_args: ?[]const u8 = null,
    timeout_secs: ?u32 = null,
    enabled: bool = true,
    delete_after_run: bool = false,
    created_at_s: i64 = 0,
    last_output: ?[]const u8 = null,
    delivery: DeliveryConfig = .{},
};

/// Duration unit for "once" delay parsing.
pub const DurationUnit = enum {
    seconds,
    minutes,
    hours,
    days,
    weeks,
};

/// Parse a human delay string like "30m", "2h", "1d" into seconds.
pub fn parseDuration(input: []const u8) !i64 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyDelay;

    // Check if last char is a unit letter
    const last = trimmed[trimmed.len - 1];
    var num_str: []const u8 = undefined;
    var multiplier: i64 = undefined;

    if (std.ascii.isAlphabetic(last)) {
        num_str = trimmed[0 .. trimmed.len - 1];
        multiplier = switch (last) {
            's' => 1,
            'm' => 60,
            'h' => 3600,
            'd' => 86400,
            'w' => 604800,
            else => return error.UnknownDurationUnit,
        };
    } else {
        num_str = trimmed;
        multiplier = 60; // default to minutes
    }

    const n = std.fmt.parseInt(i64, std.mem.trim(u8, num_str, " "), 10) catch return error.InvalidDurationNumber;
    if (n <= 0) return error.InvalidDurationNumber;

    const secs = std.math.mul(i64, n, multiplier) catch return error.DurationTooLarge;
    return secs;
}

/// Normalize a cron expression (5 fields -> prepend "0" for seconds).
pub fn normalizeExpression(expression: []const u8) !CronNormalized {
    const trimmed = std.mem.trim(u8, expression, " \t\r\n");
    var field_count: usize = 0;
    var in_field = false;

    for (trimmed) |ch| {
        if (ch == ' ' or ch == '\t') {
            if (in_field) {
                in_field = false;
            }
        } else {
            if (!in_field) {
                field_count += 1;
                in_field = true;
            }
        }
    }

    return switch (field_count) {
        5 => .{ .expression = trimmed, .needs_second_prefix = true },
        6, 7 => .{ .expression = trimmed, .needs_second_prefix = false },
        else => error.InvalidCronExpression,
    };
}

pub const CronNormalized = struct {
    expression: []const u8,
    needs_second_prefix: bool,
};

const MAX_CRON_LOOKAHEAD_MINUTES: usize = 8 * 366 * 24 * 60;

const ParsedCronExpression = struct {
    minutes: [60]bool = .{false} ** 60,
    hours: [24]bool = .{false} ** 24,
    day_of_month: [32]bool = .{false} ** 32, // 1..31
    months: [13]bool = .{false} ** 13, // 1..12
    day_of_week: [7]bool = .{false} ** 7, // 0..6 (0=Sun)
    day_of_month_any: bool = false,
    day_of_week_any: bool = false,
};

fn parseCronRawValue(raw: []const u8, min: u8, max: u8, allow_sunday_7: bool) !u8 {
    const value = std.fmt.parseInt(u8, std.mem.trim(u8, raw, " \t"), 10) catch return error.InvalidCronExpression;
    const max_allowed: u8 = if (allow_sunday_7) 7 else max;
    if (value < min or value > max_allowed) return error.InvalidCronExpression;
    return value;
}

fn normalizeCronValue(raw_value: u8, allow_sunday_7: bool) u8 {
    if (allow_sunday_7 and raw_value == 7) return 0;
    return raw_value;
}

fn clearBoolSlice(values: []bool) void {
    for (values) |*entry| entry.* = false;
}

fn parseCronField(raw_field: []const u8, min: u8, max: u8, allow_sunday_7: bool, out: []bool) !bool {
    if (out.len <= max) return error.InvalidCronExpression;
    clearBoolSlice(out);

    const field = std.mem.trim(u8, raw_field, " \t");
    if (field.len == 0) return error.InvalidCronExpression;
    const is_any = std.mem.eql(u8, field, "*");

    var saw_value = false;
    var parts = std.mem.splitScalar(u8, field, ',');
    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        if (part.len == 0) return error.InvalidCronExpression;

        var range_part = part;
        var step: u8 = 1;
        var has_step = false;
        if (std.mem.indexOfScalar(u8, part, '/')) |slash_idx| {
            range_part = std.mem.trim(u8, part[0..slash_idx], " \t");
            const step_raw = std.mem.trim(u8, part[slash_idx + 1 ..], " \t");
            if (range_part.len == 0 or step_raw.len == 0) return error.InvalidCronExpression;
            step = std.fmt.parseInt(u8, step_raw, 10) catch return error.InvalidCronExpression;
            if (step == 0) return error.InvalidCronExpression;
            has_step = true;
        }

        var start_raw: u8 = min;
        var end_raw: u8 = max;
        if (std.mem.eql(u8, range_part, "*")) {
            // full range
        } else if (std.mem.indexOfScalar(u8, range_part, '-')) |dash_idx| {
            const start_part = std.mem.trim(u8, range_part[0..dash_idx], " \t");
            const end_part = std.mem.trim(u8, range_part[dash_idx + 1 ..], " \t");
            if (start_part.len == 0 or end_part.len == 0) return error.InvalidCronExpression;
            start_raw = try parseCronRawValue(start_part, min, max, allow_sunday_7);
            end_raw = try parseCronRawValue(end_part, min, max, allow_sunday_7);
            if (start_raw > end_raw) return error.InvalidCronExpression;
        } else {
            start_raw = try parseCronRawValue(range_part, min, max, allow_sunday_7);
            if (has_step) {
                start_raw = normalizeCronValue(start_raw, allow_sunday_7);
                end_raw = max;
            } else {
                end_raw = start_raw;
            }
        }

        var raw_value = start_raw;
        while (raw_value <= end_raw) {
            const normalized = normalizeCronValue(raw_value, allow_sunday_7);
            if (normalized < min or normalized > max) return error.InvalidCronExpression;
            out[normalized] = true;
            saw_value = true;

            const next = @addWithOverflow(raw_value, step);
            if (next[1] != 0 or next[0] <= raw_value) break;
            raw_value = next[0];
        }
    }

    if (!saw_value) return error.InvalidCronExpression;
    return is_any;
}

fn parseCronExpression(expression: []const u8) !ParsedCronExpression {
    const trimmed = std.mem.trim(u8, expression, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidCronExpression;

    var fields: [7][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    while (it.next()) |field| {
        if (count >= fields.len) return error.InvalidCronExpression;
        fields[count] = field;
        count += 1;
    }

    if (count < 5 or count > 7) return error.InvalidCronExpression;

    const minute_field: []const u8 = switch (count) {
        5 => fields[0],
        6, 7 => fields[1],
        else => unreachable,
    };
    const hour_field: []const u8 = switch (count) {
        5 => fields[1],
        6, 7 => fields[2],
        else => unreachable,
    };
    const dom_field: []const u8 = switch (count) {
        5 => fields[2],
        6, 7 => fields[3],
        else => unreachable,
    };
    const month_field: []const u8 = switch (count) {
        5 => fields[3],
        6, 7 => fields[4],
        else => unreachable,
    };
    const dow_field: []const u8 = switch (count) {
        5 => fields[4],
        6, 7 => fields[5],
        else => unreachable,
    };

    var parsed = ParsedCronExpression{};
    _ = try parseCronField(minute_field, 0, 59, false, parsed.minutes[0..]);
    _ = try parseCronField(hour_field, 0, 23, false, parsed.hours[0..]);
    parsed.day_of_month_any = try parseCronField(dom_field, 1, 31, false, parsed.day_of_month[0..]);
    _ = try parseCronField(month_field, 1, 12, false, parsed.months[0..]);
    parsed.day_of_week_any = try parseCronField(dow_field, 0, 6, true, parsed.day_of_week[0..]);

    return parsed;
}

fn cronExpressionMatches(parsed: *const ParsedCronExpression, ts: i64) bool {
    if (ts < 0) return false;

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    const minute: u8 = day_seconds.getMinutesIntoHour();
    const hour: u8 = day_seconds.getHoursIntoDay();
    const day_of_month: u8 = @as(u8, @intCast(month_day.day_index + 1));
    const month: u8 = month_day.month.numeric();
    const day_of_week: u8 = @as(u8, @intCast((epoch_day.day + 4) % 7)); // 1970-01-01 was Thursday (4)

    if (!parsed.minutes[minute]) return false;
    if (!parsed.hours[hour]) return false;
    if (!parsed.months[month]) return false;

    const dom_match = parsed.day_of_month[day_of_month];
    const dow_match = parsed.day_of_week[day_of_week];

    const day_match = if (parsed.day_of_month_any and parsed.day_of_week_any)
        true
    else if (parsed.day_of_month_any)
        dow_match
    else if (parsed.day_of_week_any)
        dom_match
    else
        dom_match or dow_match;

    return day_match;
}

fn alignToNextMinute(from_secs: i64) i64 {
    var start = from_secs + 1;
    if (start < 0) start = 0;
    const rem = @mod(start, 60);
    if (rem == 0) return start;
    return start + (60 - rem);
}

pub fn nextRunForCronExpression(expression: []const u8, from_secs: i64) !i64 {
    const parsed = try parseCronExpression(expression);
    var candidate = alignToNextMinute(from_secs);

    var i: usize = 0;
    while (i < MAX_CRON_LOOKAHEAD_MINUTES) : (i += 1) {
        if (cronExpressionMatches(&parsed, candidate)) return candidate;
        candidate += 60;
    }
    return error.NoFutureRunFound;
}

/// In-memory cron job store (no SQLite dependency for the minimal Zig port).
pub const CronScheduler = struct {
    jobs: std.ArrayListUnmanaged(CronJob),
    runs: std.ArrayListUnmanaged(CronRun) = .empty,
    next_run_id: u64 = 1,
    max_tasks: usize,
    enabled: bool,
    allocator: std.mem.Allocator,
    shell_cwd: ?[]const u8 = null,
    agent_timeout_secs: u64 = 0,
    /// Override the DB path used by all persistence operations.
    /// Null means use the default ~/.nullclaw/cron.db.
    /// Set this in tests to point at an isolated tmpDir DB.
    db_path: ?[:0]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, max_tasks: usize, enabled: bool) CronScheduler {
        return .{
            .jobs = .empty,
            .max_tasks = max_tasks,
            .enabled = enabled,
            .allocator = allocator,
            .shell_cwd = null,
            .agent_timeout_secs = 0,
        };
    }

    pub fn setShellCwd(self: *CronScheduler, cwd: []const u8) void {
        self.shell_cwd = cwd;
    }

    pub fn setAgentTimeoutSecs(self: *CronScheduler, timeout_secs: u64) void {
        self.agent_timeout_secs = timeout_secs;
    }

    fn freeJobOwned(self: *CronScheduler, job: CronJob) void {
        self.allocator.free(job.id);
        self.allocator.free(job.expression);
        self.allocator.free(job.command);
        if (job.prompt) |prompt| self.allocator.free(prompt);
        if (job.name) |name| self.allocator.free(name);
        if (job.model) |model| self.allocator.free(model);
        if (job.skill_name) |sn| self.allocator.free(sn);
        if (job.skill_args) |sa| self.allocator.free(sa);
        if (job.last_output) |output| self.allocator.free(output);
        if (job.delivery.channel_owned) {
            if (job.delivery.channel) |channel| self.allocator.free(channel);
        }
        if (job.delivery.account_id_owned) {
            if (job.delivery.account_id) |account_id| self.allocator.free(account_id);
        }
        if (job.delivery.to_owned) {
            if (job.delivery.to) |to| self.allocator.free(to);
        }
    }

    pub fn deinit(self: *CronScheduler) void {
        for (self.runs.items) |r| {
            self.allocator.free(r.job_id);
            self.allocator.free(r.status);
            if (r.output) |o| self.allocator.free(o);
        }
        self.runs.deinit(self.allocator);
        self.clearJobs();
        self.jobs.deinit(self.allocator);
    }

    fn allocateJobId(self: *CronScheduler, prefix: []const u8) ![]const u8 {
        // UUID v4: 16 random bytes formatted as 8-4-4-4-12 hex groups
        var rand_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&rand_bytes);
        // Set version 4 and variant bits (RFC 4122)
        rand_bytes[6] = (rand_bytes[6] & 0x0f) | 0x40;
        rand_bytes[8] = (rand_bytes[8] & 0x3f) | 0x80;
        // Format: prefix-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
        var id_buf: [80]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "{s}-{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}", .{
            prefix,
            std.mem.readInt(u32, rand_bytes[0..4], .big),
            std.mem.readInt(u16, rand_bytes[4..6], .big),
            std.mem.readInt(u16, rand_bytes[6..8], .big),
            std.mem.readInt(u16, rand_bytes[8..10], .big),
            std.mem.readInt(u48, rand_bytes[10..16], .big),
        }) catch unreachable;
        return try self.allocator.dupe(u8, id);
    }

    fn clearJobs(self: *CronScheduler) void {
        for (self.jobs.items) |job| {
            self.freeJobOwned(job);
        }
        self.jobs.clearRetainingCapacity();
    }

    /// Add a recurring cron job.
    pub fn addJob(self: *CronScheduler, expression: []const u8, command: []const u8) !*CronJob {
        if (self.jobs.items.len >= self.max_tasks) return error.MaxTasksReached;

        // Validate expression
        _ = try normalizeExpression(expression);
        const now = std.time.timestamp();
        const next_run_secs = try nextRunForCronExpression(expression, now);

        const id = try self.allocateJobId("job");
        errdefer self.allocator.free(id);

        try self.jobs.append(self.allocator, .{
            .id = id,
            .expression = try self.allocator.dupe(u8, expression),
            .command = try self.allocator.dupe(u8, command),
            .next_run_secs = next_run_secs,
        });

        return &self.jobs.items[self.jobs.items.len - 1];
    }

    /// Add a one-shot delayed task.
    pub fn addOnce(self: *CronScheduler, delay: []const u8, command: []const u8) !*CronJob {
        if (self.jobs.items.len >= self.max_tasks) return error.MaxTasksReached;

        const delay_secs = try parseDuration(delay);
        const now = std.time.timestamp();

        const id = try self.allocateJobId("once");
        errdefer self.allocator.free(id);

        var expr_buf: [64]u8 = undefined;
        const expr = std.fmt.bufPrint(&expr_buf, "@once:{s}", .{delay}) catch "@once";

        try self.jobs.append(self.allocator, .{
            .id = id,
            .expression = try self.allocator.dupe(u8, expr),
            .command = try self.allocator.dupe(u8, command),
            .next_run_secs = now + delay_secs,
            .one_shot = true,
        });

        return &self.jobs.items[self.jobs.items.len - 1];
    }

    /// Add a recurring agent job.
    pub fn addAgentJob(self: *CronScheduler, expression: []const u8, prompt: []const u8, model: ?[]const u8, delivery: DeliveryConfig) !*CronJob {
        if (self.jobs.items.len >= self.max_tasks) return error.MaxTasksReached;

        _ = try normalizeExpression(expression);
        const now = std.time.timestamp();
        const next_run_secs = try nextRunForCronExpression(expression, now);

        const id = try self.allocateJobId("agent");
        errdefer self.allocator.free(id);

        try self.jobs.append(self.allocator, .{
            .id = id,
            .expression = try self.allocator.dupe(u8, expression),
            .command = try self.allocator.dupe(u8, prompt),
            .next_run_secs = next_run_secs,
            .job_type = .agent,
            .prompt = try self.allocator.dupe(u8, prompt),
            .model = if (model) |m| try self.allocator.dupe(u8, m) else null,
            .delivery = .{
                .mode = delivery.mode,
                .channel = if (delivery.channel) |ch| try self.allocator.dupe(u8, ch) else null,
                .account_id = if (delivery.account_id) |aid| try self.allocator.dupe(u8, aid) else null,
                .to = if (delivery.to) |t| try self.allocator.dupe(u8, t) else null,
                .channel_owned = delivery.channel != null,
                .account_id_owned = delivery.account_id != null,
                .to_owned = delivery.to != null,
                .best_effort = delivery.best_effort,
            },
        });

        return &self.jobs.items[self.jobs.items.len - 1];
    }

    /// Add a recurring skill job (job_type=skill, resolved via SKILL.md at execution time).
    pub fn addSkillJob(self: *CronScheduler, expression: []const u8, skill_name: []const u8, skill_args: ?[]const u8, delivery: DeliveryConfig, timeout_secs: ?u32) !*CronJob {
        if (self.jobs.items.len >= self.max_tasks) return error.MaxTasksReached;

        _ = try normalizeExpression(expression);
        const now = std.time.timestamp();
        const next_run_secs = try nextRunForCronExpression(expression, now);

        const id = try self.allocateJobId("skill");
        errdefer self.allocator.free(id);

        try self.jobs.append(self.allocator, .{
            .id = id,
            .expression = try self.allocator.dupe(u8, expression),
            .command = try self.allocator.dupe(u8, ""),
            .next_run_secs = next_run_secs,
            .job_type = .skill,
            .skill_name = try self.allocator.dupe(u8, skill_name),
            .skill_args = if (skill_args) |sa| try self.allocator.dupe(u8, sa) else null,
            .timeout_secs = timeout_secs,
            .delivery = .{
                .mode = delivery.mode,
                .channel = if (delivery.channel) |ch| try self.allocator.dupe(u8, ch) else null,
                .account_id = if (delivery.account_id) |aid| try self.allocator.dupe(u8, aid) else null,
                .to = if (delivery.to) |t| try self.allocator.dupe(u8, t) else null,
                .channel_owned = delivery.channel != null,
                .account_id_owned = delivery.account_id != null,
                .to_owned = delivery.to != null,
                .best_effort = delivery.best_effort,
            },
        });

        return &self.jobs.items[self.jobs.items.len - 1];
    }

    /// Add a one-shot delayed agent task.
    pub fn addAgentOnce(self: *CronScheduler, delay: []const u8, prompt: []const u8, model: ?[]const u8) !*CronJob {
        if (self.jobs.items.len >= self.max_tasks) return error.MaxTasksReached;

        const delay_secs = try parseDuration(delay);
        const now = std.time.timestamp();

        const id = try self.allocateJobId("agent-once");
        errdefer self.allocator.free(id);

        var expr_buf: [64]u8 = undefined;
        const expr = std.fmt.bufPrint(&expr_buf, "@once:{s}", .{delay}) catch "@once";

        try self.jobs.append(self.allocator, .{
            .id = id,
            .expression = try self.allocator.dupe(u8, expr),
            .command = try self.allocator.dupe(u8, prompt),
            .next_run_secs = now + delay_secs,
            .one_shot = true,
            .job_type = .agent,
            .prompt = try self.allocator.dupe(u8, prompt),
            .model = if (model) |m| try self.allocator.dupe(u8, m) else null,
        });

        return &self.jobs.items[self.jobs.items.len - 1];
    }

    /// List all jobs.
    pub fn listJobs(self: *const CronScheduler) []const CronJob {
        return self.jobs.items;
    }

    /// Get a job by ID.
    pub fn getJob(self: *const CronScheduler, id: []const u8) ?*const CronJob {
        for (self.jobs.items) |*job| {
            if (std.mem.eql(u8, job.id, id)) return job;
        }
        return null;
    }

    /// Get a mutable pointer to a job by ID.
    pub fn getMutableJob(self: *CronScheduler, id: []const u8) ?*CronJob {
        for (self.jobs.items) |*job| {
            if (std.mem.eql(u8, job.id, id)) return job;
        }
        return null;
    }

    /// Update a job's fields from a patch.
    pub fn updateJob(self: *CronScheduler, allocator: std.mem.Allocator, id: []const u8, patch: CronJobPatch) bool {
        const job = self.getMutableJob(id) orelse return false;
        if (patch.expression) |expr| {
            const next_run_secs = nextRunForCronExpression(expr, std.time.timestamp()) catch return false;
            const new_expr = allocator.dupe(u8, expr) catch return false;
            allocator.free(job.expression);
            job.expression = new_expr;
            job.next_run_secs = next_run_secs;
        }
        if (patch.command) |cmd| {
            const new_cmd = allocator.dupe(u8, cmd) catch return false;
            allocator.free(job.command);
            job.command = new_cmd;

            // Back-compat behavior: for agent jobs, --command should still update
            // the effective prompt if --prompt was not provided explicitly.
            if (job.job_type == .agent and patch.prompt == null) {
                const new_prompt = allocator.dupe(u8, cmd) catch return false;
                if (job.prompt) |old_prompt| allocator.free(old_prompt);
                job.prompt = new_prompt;
            }
        }
        if (patch.prompt) |prompt| {
            const new_prompt = allocator.dupe(u8, prompt) catch return false;
            if (job.prompt) |old_prompt| allocator.free(old_prompt);
            job.prompt = new_prompt;

            // Keep command text aligned with prompt for agent jobs so display/list
            // and fallback behavior stay coherent.
            if (job.job_type == .agent) {
                const new_cmd = allocator.dupe(u8, prompt) catch return false;
                allocator.free(job.command);
                job.command = new_cmd;
            }
        }
        if (patch.model) |model| {
            const new_model = allocator.dupe(u8, model) catch return false;
            if (job.model) |old_model| allocator.free(old_model);
            job.model = new_model;
        }
        if (patch.timeout_secs) |t| job.timeout_secs = t;
        if (patch.enabled) |ena| {
            job.enabled = ena;
            job.paused = !ena;
        }
        if (patch.delete_after_run) |d| {
            job.delete_after_run = d;
            job.one_shot = d;
        }
        if (patch.delivery_channel) |ch| {
            if (job.delivery.channel_owned) {
                if (job.delivery.channel) |old| allocator.free(old);
            }
            job.delivery.channel = allocator.dupe(u8, ch) catch return false;
            job.delivery.channel_owned = true;
            if (job.delivery.mode == .none) job.delivery.mode = .always;
        }
        if (patch.delivery_to) |t| {
            if (job.delivery.to_owned) {
                if (job.delivery.to) |old| allocator.free(old);
            }
            job.delivery.to = allocator.dupe(u8, t) catch return false;
            job.delivery.to_owned = true;
        }
        if (patch.delivery_mode) |dm| {
            job.delivery.mode = DeliveryMode.parse(dm);
        }
        if (patch.delivery_account_id) |aid| {
            if (job.delivery.account_id_owned) {
                if (job.delivery.account_id) |old| allocator.free(old);
            }
            job.delivery.account_id = allocator.dupe(u8, aid) catch return false;
            job.delivery.account_id_owned = true;
        }
        if (patch.name) |n| {
            if (job.name) |old| allocator.free(old);
            job.name = allocator.dupe(u8, n) catch return false;
        }
        if (patch.skill_name) |sn| {
            if (job.skill_name) |old| allocator.free(old);
            job.skill_name = allocator.dupe(u8, sn) catch return false;
        }
        if (patch.skill_args) |sa| {
            if (job.skill_args) |old| allocator.free(old);
            job.skill_args = allocator.dupe(u8, sa) catch return false;
        }
        if (patch.next_run_secs) |nrs| {
            job.next_run_secs = nrs;
        }
        return true;
    }

    /// Record a completed run for a job.
    pub fn addRun(self: *CronScheduler, allocator: std.mem.Allocator, job_id: []const u8, started_at_s: i64, finished_at_s: i64, status: []const u8, output: ?[]const u8, max_history: usize) !void {
        const entry = CronRun{
            .id = self.next_run_id,
            .job_id = try allocator.dupe(u8, job_id),
            .started_at_s = started_at_s,
            .finished_at_s = finished_at_s,
            .status = try allocator.dupe(u8, status),
            .output = if (output) |o| try allocator.dupe(u8, o) else null,
            .duration_ms = (finished_at_s - started_at_s) * 1000,
        };
        self.next_run_id += 1;
        try self.runs.append(allocator, entry);
        // Prune to max_history per job_id
        if (max_history > 0) {
            var count: usize = 0;
            var i: usize = self.runs.items.len;
            while (i > 0) {
                i -= 1;
                if (std.mem.eql(u8, self.runs.items[i].job_id, job_id)) {
                    count += 1;
                    if (count > max_history) {
                        // Free strings of the pruned run
                        allocator.free(self.runs.items[i].job_id);
                        allocator.free(self.runs.items[i].status);
                        if (self.runs.items[i].output) |o| allocator.free(o);
                        _ = self.runs.orderedRemove(i);
                    }
                }
            }
        }
    }

    /// List recent runs for a given job_id, up to `limit` entries.
    pub fn listRuns(self: *const CronScheduler, allocator: std.mem.Allocator, job_id: []const u8, limit: usize) ![]CronRun {
        var filtered: std.ArrayListUnmanaged(CronRun) = .empty;
        errdefer filtered.deinit(allocator);

        if (limit == 0) return try filtered.toOwnedSlice(allocator);

        var i: usize = self.runs.items.len;
        while (i > 0 and filtered.items.len < limit) {
            i -= 1;
            const run_entry = self.runs.items[i];
            if (!std.mem.eql(u8, run_entry.job_id, job_id)) continue;
            try filtered.append(allocator, run_entry);
        }

        std.mem.reverse(CronRun, filtered.items);
        return try filtered.toOwnedSlice(allocator);
    }

    /// Remove a job by ID, freeing its owned strings.
    pub fn removeJob(self: *CronScheduler, id: []const u8) bool {
        for (self.jobs.items, 0..) |job, i| {
            if (std.mem.eql(u8, job.id, id)) {
                self.freeJobOwned(job);
                _ = self.jobs.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Pause a job.
    pub fn pauseJob(self: *CronScheduler, id: []const u8) bool {
        for (self.jobs.items) |*job| {
            if (std.mem.eql(u8, job.id, id)) {
                job.paused = true;
                return true;
            }
        }
        return false;
    }

    /// Resume a job.
    pub fn resumeJob(self: *CronScheduler, id: []const u8) bool {
        for (self.jobs.items) |*job| {
            if (std.mem.eql(u8, job.id, id)) {
                job.paused = false;
                return true;
            }
        }
        return false;
    }

    /// Get due (non-paused) jobs whose next_run <= now.
    pub fn dueJobs(self: *const CronScheduler, allocator: std.mem.Allocator, now_secs: i64) ![]const CronJob {
        var result: std.ArrayListUnmanaged(CronJob) = .empty;
        for (self.jobs.items) |job| {
            if (!job.paused and job.next_run_secs <= now_secs) {
                try result.append(allocator, job);
            }
        }
        return result.items;
    }

    /// Main scheduler loop: check all jobs, execute due ones, sleep until next.
    /// If `out_bus` is provided, job results are delivered to channels per delivery config.
    pub fn run(self: *CronScheduler, poll_secs: u64, out_bus: ?*bus.Bus) void {
        if (!self.enabled) return;

        const poll_ns: u64 = poll_secs * std.time.ns_per_s;

        while (true) {
            const now = std.time.timestamp();
            _ = self.tick(now, out_bus);
            std.Thread.sleep(poll_ns);
        }
    }

    /// Execute one tick of the scheduler: run all due jobs, deliver results, handle one-shots.
    /// Separated from `run` for testability.
    pub fn tick(self: *CronScheduler, now: i64, out_bus: ?*bus.Bus) bool {
        var changed = false;

        // Collect indices of one-shot jobs to remove after iteration
        var remove_indices: std.ArrayListUnmanaged(usize) = .empty;
        defer remove_indices.deinit(self.allocator);

        for (self.jobs.items, 0..) |*job, idx| {
            if (job.paused or job.next_run_secs > now) continue;
            changed = true;

            switch (job.job_type) {
                .shell => {
                    // Execute shell command via child process
                    const resolved_shell_cmd = if (!builtin.is_test)
                        resolveSkillCommand(self.allocator, job.command) catch null
                    else
                        null;
                    defer if (resolved_shell_cmd) |rc| self.allocator.free(rc);
                    const effective_shell_cmd = resolved_shell_cmd orelse job.command;
                    const result = std.process.Child.run(.{
                        .allocator = self.allocator,
                        .argv = &.{ platform.getShell(), platform.getShellFlag(), effective_shell_cmd },
                        .cwd = self.shell_cwd,
                    }) catch |err| {
                        log.err("cron job '{s}' failed to start: {}", .{ job.id, err });
                        job.last_status = "error";
                        job.last_run_secs = now;
                        job.last_output = null;
                        // Deliver error notification
                        if (out_bus) |b| {
                            _ = deliverResult(self.allocator, job.delivery, "cron job failed to start", false, b) catch {};
                        }
                        continue;
                    };
                    defer self.allocator.free(result.stderr);

                    const success = switch (result.term) {
                        .Exited => |code| code == 0,
                        else => false,
                    };
                    job.last_run_secs = now;
                    job.last_status = if (success) "ok" else "error";

                    // Store and deliver stdout
                    if (job.last_output) |old| self.allocator.free(old);
                    job.last_output = if (result.stdout.len > 0) result.stdout else blk: {
                        self.allocator.free(result.stdout);
                        break :blk null;
                    };

                    if (out_bus) |b| {
                        const output = job.last_output orelse "";
                        _ = deliverResult(self.allocator, job.delivery, output, success, b) catch {};
                    }
                },
                .agent => {
                    const raw_agent_prompt = job.prompt orelse job.command;
                    const resolved_agent_prompt = if (!builtin.is_test)
                        resolveSkillPrompt(self.allocator, raw_agent_prompt) catch null
                    else
                        null;
                    defer if (resolved_agent_prompt) |rp| self.allocator.free(rp);
                    const agent_output = resolved_agent_prompt orelse raw_agent_prompt;
                    if (builtin.is_test) {
                        // Keep unit tests deterministic: no subprocess or network side effects.
                        job.last_run_secs = now;
                        job.last_status = "ok";

                        if (job.last_output) |old| self.allocator.free(old);
                        job.last_output = self.allocator.dupe(u8, agent_output) catch null;

                        if (out_bus) |b| {
                            _ = deliverResult(self.allocator, job.delivery, agent_output, true, b) catch {};
                        }
                    } else {
                        const exec_result = runAgentJob(self.allocator, self.shell_cwd, agent_output, job.model, self.agent_timeout_secs) catch |err| {
                            log.err("cron agent job '{s}' execution failed: {s}", .{ job.id, @errorName(err) });
                            job.last_run_secs = now;
                            job.last_status = "error";
                            if (job.last_output) |old| self.allocator.free(old);
                            job.last_output = null;
                            if (out_bus) |b| {
                                _ = deliverResult(self.allocator, job.delivery, "agent job execution failed", false, b) catch {};
                            }
                            continue;
                        };

                        job.last_run_secs = now;
                        job.last_status = if (exec_result.success) "ok" else "error";
                        if (job.last_output) |old| self.allocator.free(old);
                        if (out_bus) |b| {
                            _ = deliverResult(self.allocator, job.delivery, exec_result.output, exec_result.success, b) catch {};
                        }

                        job.last_output = if (exec_result.output.len > 0) exec_result.output else blk: {
                            self.allocator.free(exec_result.output);
                            break :blk null;
                        };
                    }
                },
                .skill => {
                    // Skill jobs own their entire workflow. Cron only triggers + records.
                    const skill_cmd = if (!builtin.is_test)
                        resolveSkillExec(self.allocator, job.skill_name, job.skill_args) catch |err| blk: {
                            log.err("cron job '{s}' skill resolution failed: {}", .{ job.id, err });
                            job.last_run_secs = now;
                            job.last_status = "error";
                            break :blk null;
                        }
                    else
                        null;

                    if (skill_cmd == null and !builtin.is_test) {
                        // Resolution failed, error already logged above.
                    } else if (builtin.is_test) {
                        // Test mode: record execution without subprocess.
                        job.last_run_secs = now;
                        job.last_status = "ok";
                    } else {
                        defer self.allocator.free(skill_cmd.?);
                        const result = std.process.Child.run(.{
                            .allocator = self.allocator,
                            .argv = &.{ platform.getShell(), platform.getShellFlag(), skill_cmd.? },
                            .cwd = self.shell_cwd,
                        }) catch |err| {
                            log.err("cron skill job '{s}' failed to start: {}", .{ job.id, err });
                            job.last_run_secs = now;
                            job.last_status = "error";
                            continue;
                        };
                        defer self.allocator.free(result.stdout);
                        defer self.allocator.free(result.stderr);

                        const exit_code: u8 = switch (result.term) {
                            .Exited => |code| code,
                            else => 1,
                        };
                        job.last_run_secs = now;
                        job.last_status = if (exit_code == 0) "ok" else "error";
                        job.last_output = if (result.stdout.len > 0)
                            self.allocator.dupe(u8, result.stdout) catch null
                        else if (result.stderr.len > 0)
                            self.allocator.dupe(u8, result.stderr) catch null
                        else
                            null;
                    }
                },
            }

            if (job.one_shot or job.delete_after_run) {
                remove_indices.append(self.allocator, idx) catch {
                    // If we can't queue for deletion under memory pressure, prevent reruns.
                    job.paused = true;
                };
            } else {
                job.next_run_secs = nextRunForCronExpression(job.expression, now) catch |err| blk: {
                    log.warn("cron job '{s}' schedule parse failed ({s}); fallback to +60s", .{ job.id, @errorName(err) });
                    break :blk now + 60;
                };
            }
        }

        // Remove one-shot jobs in reverse order to keep indices valid
        if (remove_indices.items.len > 0) {
            var i: usize = remove_indices.items.len;
            while (i > 0) {
                i -= 1;
                const rm_idx = remove_indices.items[i];
                const job = self.jobs.items[rm_idx];
                self.freeJobOwned(job);
                _ = self.jobs.orderedRemove(rm_idx);
            }
        }

        return changed;
    }

    /// Non-blocking variant of tick: finds all due jobs, advances their next_run_secs,
    /// marks one-shots for removal, and returns the collected IDs — without executing anything.
    /// The caller is responsible for executing the returned jobs (e.g. by enqueuing them to
    /// the gateway run queue so they run off the scheduler thread).
    /// Caller must free each returned slice and the outer slice itself via the allocator.
    pub fn collectDueJobs(self: *CronScheduler, now: i64, allocator: std.mem.Allocator) ![][]const u8 {
        var due: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (due.items) |id| allocator.free(id);
            due.deinit(allocator);
        }
        var remove_indices: std.ArrayListUnmanaged(usize) = .empty;
        defer remove_indices.deinit(self.allocator);

        for (self.jobs.items, 0..) |*job, idx| {
            if (job.paused or job.next_run_secs > now) continue;

            try due.append(allocator, try allocator.dupe(u8, job.id));

            if (job.one_shot or job.delete_after_run) {
                remove_indices.append(self.allocator, idx) catch {
                    job.paused = true;
                };
            } else {
                job.next_run_secs = nextRunForCronExpression(job.expression, now) catch |err| blk: {
                    log.warn("cron job '{s}' schedule parse failed ({s}); fallback to +60s", .{ job.id, @errorName(err) });
                    break :blk now + 60;
                };
            }
        }

        if (remove_indices.items.len > 0) {
            var i: usize = remove_indices.items.len;
            while (i > 0) {
                i -= 1;
                const rm_idx = remove_indices.items[i];
                const job = self.jobs.items[rm_idx];
                self.freeJobOwned(job);
                _ = self.jobs.orderedRemove(rm_idx);
            }
        }

        return due.toOwnedSlice(allocator);
    }
};

const AgentRunResult = struct {
    success: bool,
    output: []const u8,
};

const AGENT_MAX_OUTPUT_BYTES: usize = 1_048_576;
const AGENT_POLL_STEP_NS: u64 = 200 * std.time.ns_per_ms;
const LINUX_SELF_EXE_PATH = "/proc/self/exe";
const DELETED_EXE_SUFFIX = " (deleted)";

fn pathAgentExecutableName() []const u8 {
    return if (comptime builtin.os.tag == .windows) "nullclaw.exe" else "nullclaw";
}

fn hasTimeoutExpired(start_ns: i128, timeout_secs: u64) bool {
    if (timeout_secs == 0) return false;
    const timeout_ns = @as(i128, @intCast(timeout_secs)) * std.time.ns_per_s;
    const now_ns = std.time.nanoTimestamp();
    return now_ns - start_ns >= timeout_ns;
}

pub fn collectChildOutputWithTimeout(
    child: *std.process.Child,
    allocator: std.mem.Allocator,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    timeout_secs: u64,
    start_ns: i128,
) !bool {
    var poller = std.Io.poll(allocator, enum { stdout, stderr }, .{
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
    });
    defer poller.deinit();

    const stdout_r = poller.reader(.stdout);
    stdout_r.buffer = stdout.allocatedSlice();
    stdout_r.seek = 0;
    stdout_r.end = stdout.items.len;

    const stderr_r = poller.reader(.stderr);
    stderr_r.buffer = stderr.allocatedSlice();
    stderr_r.seek = 0;
    stderr_r.end = stderr.items.len;

    defer {
        stdout.* = .{
            .items = stdout_r.buffer[0..stdout_r.end],
            .capacity = stdout_r.buffer.len,
        };
        stderr.* = .{
            .items = stderr_r.buffer[0..stderr_r.end],
            .capacity = stderr_r.buffer.len,
        };
        stdout_r.buffer = &.{};
        stderr_r.buffer = &.{};
    }

    var timed_out = false;
    while (true) {
        const keep_polling = if (timeout_secs == 0 or timed_out)
            try poller.poll()
        else
            try poller.pollTimeout(AGENT_POLL_STEP_NS);

        if (stdout_r.bufferedLen() > AGENT_MAX_OUTPUT_BYTES) return error.StdoutStreamTooLong;
        if (stderr_r.bufferedLen() > AGENT_MAX_OUTPUT_BYTES) return error.StderrStreamTooLong;

        if (!keep_polling) break;

        if (!timed_out and hasTimeoutExpired(start_ns, timeout_secs)) {
            try terminateAgentChildHard(child);
            timed_out = true;
        }
    }

    return timed_out;
}

fn terminateAgentChildHard(child: *std.process.Child) !void {
    if (comptime builtin.os.tag == .windows) {
        _ = child.killWindows(1) catch |err| switch (err) {
            error.AlreadyTerminated => return,
            else => return err,
        };
        return;
    }
    if (comptime builtin.os.tag == .wasi) return error.UnsupportedOperation;

    std.posix.kill(child.id, std.posix.SIG.KILL) catch |err| switch (err) {
        error.ProcessNotFound => return,
        else => return err,
    };
}

/// Extract the final answer from agent stdout, stripping intermediate tool-call
/// markup and the "thinking aloud" text that precedes each tool call.
///
/// Agent stdout structure (repeated N times, then final answer):
///   [optional text like "Let me search..."]
///   <tool_call>\n{...}\n</tool_call>\n
///   [tool result injected back]
/// Final answer: the last contiguous text block after all tool calls.
///
/// Strategy: split on <tool_call> boundaries, discard blocks that contain or
/// immediately precede a tool call, keep only the trailing text after the last
/// </tool_call> tag. If no tool calls are present, return the text as-is.
fn stripToolCallBlocks(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const open_tag = "<tool_call>";
    const close_tag = "</tool_call>";

    // Find the last </tool_call> — everything after it is the final answer.
    if (std.mem.lastIndexOf(u8, text, close_tag)) |last_close| {
        const after = text[last_close + close_tag.len ..];
        // Eat leading whitespace/newlines after the closing tag
        const trimmed = std.mem.trimLeft(u8, after, " \t\r\n");
        const result = std.mem.trimRight(u8, trimmed, " \t\r\n");
        if (result.len > 0) return allocator.dupe(u8, result);
    }

    // No tool calls at all — return text with any stray open tags removed.
    if (std.mem.indexOf(u8, text, open_tag) == null) {
        return allocator.dupe(u8, std.mem.trim(u8, text, " \t\r\n"));
    }

    // Fallback: strip all <tool_call>...</tool_call> blocks byte-by-byte.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], open_tag)) {
            if (std.mem.indexOf(u8, text[i..], close_tag)) |rel| {
                i += rel + close_tag.len;
                if (i < text.len and text[i] == '\n') i += 1;
                continue;
            }
        }
        try out.append(allocator, text[i]);
        i += 1;
    }
    const trimmed = std.mem.trim(u8, out.items, " \t\r\n");
    return allocator.dupe(u8, trimmed);
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
    return stripToolCallBlocks(allocator, output_source);
}

fn preferAgentExecPath(self_exe_path: []const u8) []const u8 {
    if (comptime builtin.os.tag == .linux) {
        if (std.mem.endsWith(u8, self_exe_path, DELETED_EXE_SUFFIX)) {
            return LINUX_SELF_EXE_PATH;
        }
    }
    return self_exe_path;
}

/// If `prompt` starts with "skill:<name>", resolves to the skill's ## Prompt section
/// from ~/.claude/skills/<name>/SKILL.md. Returns a heap-allocated string that the
/// caller must free, or null if prompt is not a skill reference or resolution fails.
pub fn resolveSkillPrompt(allocator: std.mem.Allocator, prompt: []const u8) !?[]const u8 {
    const prefix = "skill:";
    if (!std.mem.startsWith(u8, prompt, prefix)) return null;
    const skill_name = std.mem.trim(u8, prompt[prefix.len..], " \t");
    if (skill_name.len == 0) return null;

    const home = std.posix.getenv("HOME") orelse return null;
    const skill_md_path = try std.fmt.allocPrint(allocator, "{s}/.claude/skills/{s}/SKILL.md", .{ home, skill_name });
    defer allocator.free(skill_md_path);

    const content = std.fs.cwd().readFileAlloc(allocator, skill_md_path, 256 * 1024) catch return null;
    defer allocator.free(content);

    // Extract content between "## Prompt\n" and the next "## " heading (or EOF).
    const prompt_header = "\n## Prompt\n";
    const header_pos = std.mem.indexOf(u8, content, prompt_header) orelse return null;
    const body_start = header_pos + prompt_header.len;
    const body = content[body_start..];

    // Find the next "## " heading to determine where the Prompt section ends.
    const next_section = std.mem.indexOf(u8, body, "\n## ");
    const section = if (next_section) |n| body[0..n] else body;
    const trimmed = std.mem.trim(u8, section, " \t\n\r");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

/// If `command` starts with "skill:<name> [extra args]", resolves to
/// "python3 <script_path> <extra_args>" using the skill's ## Script section.
/// Returns heap-allocated command string or null if not a skill reference / no script.
pub fn resolveSkillCommand(allocator: std.mem.Allocator, command: []const u8) !?[]const u8 {
    const prefix = "skill:";
    if (!std.mem.startsWith(u8, command, prefix)) return null;
    const rest = command[prefix.len..];
    // Split skill name from extra args (first whitespace-delimited token)
    const space = std.mem.indexOfAny(u8, rest, " \t");
    const skill_name = if (space) |s| rest[0..s] else rest;
    const extra_args = if (space) |s| std.mem.trim(u8, rest[s..], " \t") else "";
    if (skill_name.len == 0) return null;

    const home = std.posix.getenv("HOME") orelse return null;
    const skill_md_path = try std.fmt.allocPrint(allocator, "{s}/.claude/skills/{s}/SKILL.md", .{ home, skill_name });
    defer allocator.free(skill_md_path);

    const content = std.fs.cwd().readFileAlloc(allocator, skill_md_path, 256 * 1024) catch return null;
    defer allocator.free(content);

    // Extract first non-empty line from ## Script section.
    const script_header = "\n## Script\n";
    const header_pos = std.mem.indexOf(u8, content, script_header) orelse return null;
    const body_start = header_pos + script_header.len;
    const body = content[body_start..];
    const next_section = std.mem.indexOf(u8, body, "\n## ");
    const section = if (next_section) |n| body[0..n] else body;

    // Find the script path — first non-empty, non-``` line in the section.
    var line_iter = std.mem.splitScalar(u8, section, '\n');
    var script_path: ?[]const u8 = null;
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r`");
        if (trimmed.len == 0) continue;
        script_path = trimmed;
        break;
    }
    const raw_path = script_path orelse return null;

    // Expand leading ~ to HOME.
    const expanded = if (std.mem.startsWith(u8, raw_path, "~/"))
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, raw_path[2..] })
    else
        try allocator.dupe(u8, raw_path);
    defer allocator.free(expanded);

    if (extra_args.len > 0) {
        return try std.fmt.allocPrint(allocator, "python3 {s} {s}", .{ expanded, extra_args });
    }
    return try std.fmt.allocPrint(allocator, "python3 {s}", .{expanded});
}

/// Resolves a skill name + args into an executable shell command.
/// Reads ## Script from ~/.claude/skills/<name>/SKILL.md.
/// Returns heap-allocated "python3 <expanded_path> <args>" or error.
/// The caller must free the returned slice.
pub fn resolveSkillExec(allocator: std.mem.Allocator, skill_name: ?[]const u8, skill_args: ?[]const u8) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    const skills_dir = try std.fmt.allocPrint(allocator, "{s}/.claude/skills", .{home});
    defer allocator.free(skills_dir);
    return resolveSkillExecFrom(allocator, skill_name, skill_args, skills_dir, home);
}

/// Testable inner: reads SKILL.md from `skills_dir/<name>/SKILL.md` and builds
/// `python3 <script_path> [args]`. `tilde_home` is used for `~/` expansion.
pub fn resolveSkillExecFrom(
    allocator: std.mem.Allocator,
    skill_name: ?[]const u8,
    skill_args: ?[]const u8,
    skills_dir: []const u8,
    tilde_home: []const u8,
) ![]const u8 {
    const name = skill_name orelse return error.MissingSkillName;
    const skill_md_path = try std.fmt.allocPrint(allocator, "{s}/{s}/SKILL.md", .{ skills_dir, name });
    defer allocator.free(skill_md_path);

    const content = std.fs.cwd().readFileAlloc(allocator, skill_md_path, 256 * 1024) catch return error.SkillNotFound;
    defer allocator.free(content);

    // Extract first non-empty, non-``` line from ## Script section.
    const script_header = "\n## Script\n";
    const header_pos = std.mem.indexOf(u8, content, script_header) orelse return error.NoScriptSection;
    const body_start = header_pos + script_header.len;
    const body = content[body_start..];
    const next_section = std.mem.indexOf(u8, body, "\n## ");
    const section = if (next_section) |n| body[0..n] else body;

    var line_iter = std.mem.splitScalar(u8, section, '\n');
    var script_path: ?[]const u8 = null;
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r`");
        if (trimmed.len == 0) continue;
        script_path = trimmed;
        break;
    }
    const raw_path = script_path orelse return error.NoScriptPath;

    // Expand leading ~ to tilde_home.
    const expanded = if (std.mem.startsWith(u8, raw_path, "~/"))
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tilde_home, raw_path[2..] })
    else
        try allocator.dupe(u8, raw_path);
    defer allocator.free(expanded);

    const args = skill_args orelse "";
    if (args.len > 0) {
        return try std.fmt.allocPrint(allocator, "python3 {s} {s}", .{ expanded, args });
    }
    return try std.fmt.allocPrint(allocator, "python3 {s}", .{expanded});
}

pub fn runAgentJob(
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    prompt: []const u8,
    model: ?[]const u8,
    timeout_secs: u64,
) !AgentRunResult {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    var exec_path = preferAgentExecPath(exe_path);
    var exec_cwd = cwd;
    var tried_no_cwd = false;
    var tried_proc_self_exe = std.mem.eql(u8, exec_path, LINUX_SELF_EXE_PATH);
    var tried_path_exec = false;

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);

    var child: std.process.Child = undefined;
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

        child = std.process.Child.init(argv.items, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.cwd = exec_cwd;

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

    errdefer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    const start_ns = std.time.nanoTimestamp();

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
        .Exited => |code| code == 0,
        else => false,
    };
    const output = try buildAgentOutput(allocator, stdout.items, stderr.items, timeout_secs, timed_out);
    return .{ .success = success, .output = output };
}

const LoadPolicy = enum {
    best_effort,
    strict,
};

fn loadJobsWithPolicy(scheduler: *CronScheduler, policy: LoadPolicy) !void {
    const path = try cronJsonPath(scheduler.allocator);
    defer scheduler.allocator.free(path);

    const content = fs_compat.readFileAlloc(std.fs.cwd(), scheduler.allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return,
        else => switch (policy) {
            .best_effort => return,
            .strict => return err,
        },
    };
    defer scheduler.allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, scheduler.allocator, content, .{}) catch |err| switch (policy) {
        .best_effort => return,
        .strict => return err,
    };
    defer parsed.deinit();

    if (parsed.value != .array) switch (policy) {
        .best_effort => return,
        .strict => return error.InvalidCronStoreFormat,
    };

    for (parsed.value.array.items) |item| {
        if (item != .object) switch (policy) {
            .best_effort => continue,
            .strict => return error.InvalidCronStoreFormat,
        };
        const obj = item.object;

        const id = blk: {
            if (obj.get("id")) |v| {
                if (v == .string and v.string.len > 0) break :blk v.string;
            }
            switch (policy) {
                .best_effort => continue,
                .strict => return error.InvalidCronStoreFormat,
            }
        };
        const expression = blk: {
            if (obj.get("expression")) |v| {
                if (v == .string and v.string.len > 0) break :blk v.string;
            }
            switch (policy) {
                .best_effort => continue,
                .strict => return error.InvalidCronStoreFormat,
            }
        };
        const command_raw: ?[]const u8 = blk: {
            if (obj.get("command")) |v| {
                if (v == .string and v.string.len > 0) break :blk v.string;
            }
            break :blk null;
        };

        const next_run_secs: i64 = blk: {
            if (obj.get("next_run_secs")) |v| {
                if (v == .integer) break :blk v.integer;
            }
            break :blk std.time.timestamp() + 60;
        };
        const last_run_secs: ?i64 = blk: {
            if (obj.get("last_run_secs")) |v| {
                if (v == .integer) break :blk v.integer;
                if (v == .null) break :blk null;
            }
            break :blk null;
        };
        const last_status = blk: {
            if (obj.get("last_status")) |v| {
                if (v == .string and v.string.len > 0) {
                    if (std.mem.eql(u8, v.string, "ok")) break :blk "ok";
                    if (std.mem.eql(u8, v.string, "error")) break :blk "error";
                    // Backward-compat aliases from older payloads.
                    if (std.mem.eql(u8, v.string, "success")) break :blk "ok";
                    if (std.mem.eql(u8, v.string, "failed")) break :blk "error";
                }
            }
            break :blk null;
        };

        const paused = blk: {
            if (obj.get("paused")) |v| {
                if (v == .bool) break :blk v.bool;
            }
            break :blk false;
        };

        const one_shot = blk: {
            if (obj.get("one_shot")) |v| {
                if (v == .bool) break :blk v.bool;
            }
            break :blk false;
        };

        const job_type = blk: {
            if (obj.get("job_type")) |v| {
                if (v == .string) break :blk JobType.parse(v.string);
            }
            break :blk JobType.shell;
        };
        const prompt_raw: ?[]const u8 = blk: {
            if (obj.get("prompt")) |v| {
                if (v == .string and v.string.len > 0) break :blk v.string;
            }
            break :blk null;
        };
        // Normalize agent job text so prompt/command stay in sync regardless
        // of which back-compat field was present in cron.json.
        const prompt: ?[]const u8 = blk: {
            if (prompt_raw) |p| break :blk p;
            if (job_type == .agent) break :blk command_raw;
            break :blk null;
        };
        // Agent/skill jobs may omit "command" and rely solely on "prompt" or skill fields.
        // Shell jobs still require a command.
        const command: []const u8 = blk: {
            if (command_raw) |cmd_raw| break :blk cmd_raw;
            if (job_type == .agent) {
                if (prompt) |p| break :blk p;
            }
            if (job_type == .skill) break :blk "";
            switch (policy) {
                .best_effort => continue,
                .strict => return error.InvalidCronStoreFormat,
            }
        };
        const model = blk: {
            if (obj.get("model")) |v| {
                if (v == .string and v.string.len > 0) break :blk v.string;
            }
            break :blk null;
        };
        const skill_name_raw: ?[]const u8 = blk: {
            if (obj.get("skill_name")) |v| {
                if (v == .string and v.string.len > 0) break :blk v.string;
            }
            break :blk null;
        };
        const skill_args_raw: ?[]const u8 = blk: {
            if (obj.get("skill_args")) |v| {
                if (v == .string and v.string.len > 0) break :blk v.string;
            }
            break :blk null;
        };
        const enabled = blk: {
            if (obj.get("enabled")) |v| {
                if (v == .bool) break :blk v.bool;
            }
            break :blk true;
        };
        const delete_after_run = blk: {
            if (obj.get("delete_after_run")) |v| {
                if (v == .bool) break :blk v.bool;
            }
            break :blk false;
        };

        // Load delivery config
        const delivery_mode = blk: {
            if (obj.get("delivery_mode")) |v| {
                if (v == .string) {
                    if (std.mem.eql(u8, v.string, "always")) break :blk DeliveryMode.always;
                    if (std.mem.eql(u8, v.string, "on_success")) break :blk DeliveryMode.on_success;
                    if (std.mem.eql(u8, v.string, "on_error")) break :blk DeliveryMode.on_error;
                    if (std.mem.eql(u8, v.string, "none")) break :blk DeliveryMode.none;
                }
            }
            break :blk DeliveryMode.none;
        };
        const delivery_channel = blk: {
            if (obj.get("delivery_channel")) |v| {
                if (v == .string) break :blk v.string;
            }
            break :blk null;
        };
        const delivery_account_id = blk: {
            if (obj.get("delivery_account_id")) |v| {
                if (v == .string) break :blk v.string;
            }
            break :blk null;
        };
        const delivery_to = blk: {
            if (obj.get("delivery_to")) |v| {
                if (v == .string) break :blk v.string;
            }
            break :blk null;
        };

        const last_output_json: ?[]const u8 = blk: {
            if (obj.get("last_output")) |v| {
                if (v == .string and v.string.len > 0) break :blk v.string;
            }
            break :blk null;
        };
        const timeout_secs_json: ?u32 = blk: {
            if (obj.get("timeout_secs")) |v| {
                if (v == .integer and v.integer > 0) break :blk @intCast(v.integer);
            }
            break :blk null;
        };

        try scheduler.jobs.append(scheduler.allocator, .{
            .id = try scheduler.allocator.dupe(u8, id),
            .expression = try scheduler.allocator.dupe(u8, expression),
            .command = try scheduler.allocator.dupe(u8, command),
            .next_run_secs = next_run_secs,
            .last_run_secs = last_run_secs,
            .last_status = last_status,
            .paused = paused,
            .one_shot = one_shot,
            .job_type = job_type,
            .prompt = if (prompt) |p| try scheduler.allocator.dupe(u8, p) else null,
            .model = if (model) |m| try scheduler.allocator.dupe(u8, m) else null,
            .skill_name = if (skill_name_raw) |sn| try scheduler.allocator.dupe(u8, sn) else null,
            .skill_args = if (skill_args_raw) |sa| try scheduler.allocator.dupe(u8, sa) else null,
            .timeout_secs = timeout_secs_json,
            .enabled = enabled,
            .delete_after_run = delete_after_run,
            .last_output = if (last_output_json) |lo| try scheduler.allocator.dupe(u8, lo) else null,
            .delivery = .{
                .mode = delivery_mode,
                .channel = if (delivery_channel) |ch| try scheduler.allocator.dupe(u8, ch) else null,
                .account_id = if (delivery_account_id) |aid| try scheduler.allocator.dupe(u8, aid) else null,
                .to = if (delivery_to) |t| try scheduler.allocator.dupe(u8, t) else null,
                .channel_owned = delivery_channel != null,
                .account_id_owned = delivery_account_id != null,
                .to_owned = delivery_to != null,
            },
        });
    }
}

// ── Delivery ─────────────────────────────────────────────────────

/// Deliver a cron job result to a channel via the outbound bus.
/// Returns true if a message was published, false if delivery was skipped.
pub fn deliverResult(
    allocator: std.mem.Allocator,
    delivery: DeliveryConfig,
    output: []const u8,
    success: bool,
    out_bus: *bus.Bus,
) !bool {
    // Skip if mode is none
    if (delivery.mode == .none) return false;

    // Skip if no channel configured
    const channel = delivery.channel orelse return false;

    // Check mode-specific conditions
    switch (delivery.mode) {
        .none => return false,
        .on_success => if (!success) return false,
        .on_error => if (success) return false,
        .always => {},
    }

    // Skip empty output
    if (output.len == 0) {
        std.log.scoped(.cron_deliver).warn("job delivery skipped: output is empty", .{});
        return false;
    }

    const chat_id = delivery.to orelse "default";
    const msg = if (delivery.account_id) |account_id|
        try bus.makeOutboundWithAccount(allocator, channel, account_id, chat_id, output)
    else
        try bus.makeOutbound(allocator, channel, chat_id, output);
    out_bus.publishOutbound(msg) catch |err| {
        // If best_effort, swallow the error after cleaning up
        if (delivery.best_effort) {
            msg.deinit(allocator);
            return false;
        }
        msg.deinit(allocator);
        return err;
    };
    return true;
}

// ── SQLite Persistence ───────────────────────────────────────────

/// Get the path to the cron SQLite DB: ~/.nullclaw/cron.db
fn cronDbPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = try platform.getHomeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".nullclaw", "cron.db" });
}

/// Close a cron SQLite DB handle returned by openCronDbAtPath.
pub fn closeCronDb(db: *c.sqlite3) void {
    _ = c.sqlite3_close(db);
}

/// Open a SQLite DB at the given null-terminated path.
/// Caller must call closeCronDb (or c.sqlite3_close) on the returned handle.
pub fn openCronDbAtPath(path_z: [*:0]const u8) !*c.sqlite3 {
    if (!build_options.enable_sqlite) return error.SqliteDisabled;

    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open(path_z, &db);
    if (rc != c.SQLITE_OK) {
        if (db) |d| _ = c.sqlite3_close(d);
        return error.SqliteOpenFailed;
    }
    if (db) |d| {
        _ = c.sqlite3_busy_timeout(d, 5000);
        var err_msg: [*c]u8 = null;
        _ = c.sqlite3_exec(d, "PRAGMA journal_mode=WAL;PRAGMA synchronous=NORMAL;", null, null, &err_msg);
        if (err_msg) |msg| c.sqlite3_free(msg);
    }
    return db.?;
}

/// Return the null-terminated path to the cron DB (~/.nullclaw/cron.db).
/// Caller must free the returned slice with allocator.free().
pub fn getCronDbPathZ(allocator: std.mem.Allocator) ![:0]u8 {
    try ensureCronDir(allocator);
    const path = try cronDbPath(allocator);
    defer allocator.free(path);
    return allocator.dupeZ(u8, path);
}

/// Open (and create if needed) the cron SQLite DB.
/// Caller must call c.sqlite3_close on the returned handle.
fn openCronDb(allocator: std.mem.Allocator) !*c.sqlite3 {
    if (!build_options.enable_sqlite) return error.SqliteDisabled;

    try ensureCronDir(allocator);
    const path = try cronDbPath(allocator);
    defer allocator.free(path);

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    return openCronDbAtPath(path_z);
}

/// Open the DB for a scheduler, respecting its db_path override if set.
/// Under builtin.is_test, refuses to open the real default DB to prevent
/// tests from contaminating ~/.nullclaw/cron.db. Tests that need DB
/// persistence must set scheduler.db_path to a tmpDir-based path.
fn openCronDbForScheduler(scheduler: *const CronScheduler) !*c.sqlite3 {
    if (scheduler.db_path) |path_z| return openCronDbAtPath(path_z);
    if (builtin.is_test) return error.TestDbIsolationRequired;
    return openCronDb(scheduler.allocator);
}

const CRON_TABLE_SQL =
    \\CREATE TABLE IF NOT EXISTS cron_jobs (
    \\  id                  TEXT PRIMARY KEY,
    \\  expression          TEXT NOT NULL,
    \\  job_type            TEXT NOT NULL DEFAULT 'shell',
    \\  command             TEXT,
    \\  prompt              TEXT,
    \\  name                TEXT,
    \\  model               TEXT,
    \\  next_run_secs       INTEGER NOT NULL DEFAULT 0,
    \\  last_run_secs       INTEGER,
    \\  last_status         TEXT,
    \\  last_output         TEXT,
    \\  paused              INTEGER NOT NULL DEFAULT 0,
    \\  one_shot            INTEGER NOT NULL DEFAULT 0,
    \\  delete_after_run    INTEGER NOT NULL DEFAULT 0,
    \\  enabled             INTEGER NOT NULL DEFAULT 1,
    \\  delivery_mode       TEXT NOT NULL DEFAULT 'none',
    \\  delivery_channel    TEXT,
    \\  delivery_account_id TEXT,
    \\  delivery_to         TEXT,
    \\  created_at_s        INTEGER NOT NULL DEFAULT 0,
    \\  timeout_secs        INTEGER,
    \\  delivery_best_effort INTEGER NOT NULL DEFAULT 0,
    \\  session_target      TEXT NOT NULL DEFAULT 'isolated'
    \\)
;

const CRON_RUN_QUEUE_SQL =
    \\CREATE TABLE IF NOT EXISTS cron_run_queue (
    \\  id           INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  job_id       TEXT NOT NULL,
    \\  enqueued_at  INTEGER NOT NULL DEFAULT 0,
    \\  status       TEXT NOT NULL DEFAULT 'pending',
    \\  started_at   INTEGER
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_run_queue_status ON cron_run_queue(status, enqueued_at);
;

/// Ensure the cron_run_queue table exists in the given DB.
pub fn ensureRunQueueTable(db: *c.sqlite3) !void {
    var err_msg: [*c]u8 = null;
    const rc = c.sqlite3_exec(db, CRON_RUN_QUEUE_SQL, null, null, &err_msg);
    if (rc != c.SQLITE_OK) {
        if (err_msg) |msg| c.sqlite3_free(msg);
        return error.RunQueueTableCreateFailed;
    }
}

pub fn ensureCronTable(db: *c.sqlite3) !void {
    var err_msg: [*c]u8 = null;
    const rc = c.sqlite3_exec(db, CRON_TABLE_SQL, null, null, &err_msg);
    if (rc != c.SQLITE_OK) {
        if (err_msg) |msg| c.sqlite3_free(msg);
        return error.CronTableCreateFailed;
    }
    // Migration: add last_output column for existing DBs (ignore error if already exists).
    _ = c.sqlite3_exec(db, "ALTER TABLE cron_jobs ADD COLUMN last_output TEXT", null, null, null);
    // Migration: add timeout_secs column for existing DBs (ignore error if already exists).
    _ = c.sqlite3_exec(db, "ALTER TABLE cron_jobs ADD COLUMN timeout_secs INTEGER", null, null, null);
    // Migration: add delivery_best_effort column for existing DBs (ignore error if already exists).
    _ = c.sqlite3_exec(db, "ALTER TABLE cron_jobs ADD COLUMN delivery_best_effort INTEGER NOT NULL DEFAULT 0", null, null, null);
    // Migration: add session_target column for existing DBs (ignore error if already exists).
    _ = c.sqlite3_exec(db, "ALTER TABLE cron_jobs ADD COLUMN session_target TEXT NOT NULL DEFAULT 'isolated'", null, null, null);
    // Migration: add skill_name/skill_args columns for skill job type.
    _ = c.sqlite3_exec(db, "ALTER TABLE cron_jobs ADD COLUMN skill_name TEXT", null, null, null);
    _ = c.sqlite3_exec(db, "ALTER TABLE cron_jobs ADD COLUMN skill_args TEXT", null, null, null);
    try ensureRunQueueTable(db);
}

/// Insert or replace a single job row in the DB.
fn dbSaveJob(db: *c.sqlite3, job: *const CronJob) !void {
    const sql =
        "INSERT OR REPLACE INTO cron_jobs " ++
        "(id, expression, job_type, command, prompt, name, model, " ++
        "next_run_secs, last_run_secs, last_status, paused, one_shot, " ++
        "delete_after_run, enabled, delivery_mode, delivery_channel, " ++
        "delivery_account_id, delivery_to, created_at_s, last_output, timeout_secs, " ++
        "delivery_best_effort, session_target, skill_name, skill_args) " ++
        "VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25)";

    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, sql, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_text(stmt, 1, job.id.ptr, @intCast(job.id.len), SQLITE_STATIC);
    _ = c.sqlite3_bind_text(stmt, 2, job.expression.ptr, @intCast(job.expression.len), SQLITE_STATIC);
    const jt = job.job_type.asStr();
    _ = c.sqlite3_bind_text(stmt, 3, jt.ptr, @intCast(jt.len), SQLITE_STATIC);
    _ = c.sqlite3_bind_text(stmt, 4, job.command.ptr, @intCast(job.command.len), SQLITE_STATIC);
    if (job.prompt) |p| {
        _ = c.sqlite3_bind_text(stmt, 5, p.ptr, @intCast(p.len), SQLITE_STATIC);
    } else {
        _ = c.sqlite3_bind_null(stmt, 5);
    }
    if (job.name) |n| {
        _ = c.sqlite3_bind_text(stmt, 6, n.ptr, @intCast(n.len), SQLITE_STATIC);
    } else {
        _ = c.sqlite3_bind_null(stmt, 6);
    }
    if (job.model) |m| {
        _ = c.sqlite3_bind_text(stmt, 7, m.ptr, @intCast(m.len), SQLITE_STATIC);
    } else {
        _ = c.sqlite3_bind_null(stmt, 7);
    }
    _ = c.sqlite3_bind_int64(stmt, 8, job.next_run_secs);
    if (job.last_run_secs) |lrs| {
        _ = c.sqlite3_bind_int64(stmt, 9, lrs);
    } else {
        _ = c.sqlite3_bind_null(stmt, 9);
    }
    if (job.last_status) |ls| {
        _ = c.sqlite3_bind_text(stmt, 10, ls.ptr, @intCast(ls.len), SQLITE_STATIC);
    } else {
        _ = c.sqlite3_bind_null(stmt, 10);
    }
    _ = c.sqlite3_bind_int(stmt, 11, if (job.paused) 1 else 0);
    _ = c.sqlite3_bind_int(stmt, 12, if (job.one_shot) 1 else 0);
    _ = c.sqlite3_bind_int(stmt, 13, if (job.delete_after_run) 1 else 0);
    _ = c.sqlite3_bind_int(stmt, 14, if (job.enabled) 1 else 0);
    const dm = job.delivery.mode.asStr();
    _ = c.sqlite3_bind_text(stmt, 15, dm.ptr, @intCast(dm.len), SQLITE_STATIC);
    if (job.delivery.channel) |ch| {
        _ = c.sqlite3_bind_text(stmt, 16, ch.ptr, @intCast(ch.len), SQLITE_STATIC);
    } else {
        _ = c.sqlite3_bind_null(stmt, 16);
    }
    if (job.delivery.account_id) |aid| {
        _ = c.sqlite3_bind_text(stmt, 17, aid.ptr, @intCast(aid.len), SQLITE_STATIC);
    } else {
        _ = c.sqlite3_bind_null(stmt, 17);
    }
    if (job.delivery.to) |t| {
        _ = c.sqlite3_bind_text(stmt, 18, t.ptr, @intCast(t.len), SQLITE_STATIC);
    } else {
        _ = c.sqlite3_bind_null(stmt, 18);
    }
    _ = c.sqlite3_bind_int64(stmt, 19, job.created_at_s);
    if (job.last_output) |lo| {
        _ = c.sqlite3_bind_text(stmt, 20, lo.ptr, @intCast(lo.len), SQLITE_STATIC);
    } else {
        _ = c.sqlite3_bind_null(stmt, 20);
    }
    if (job.timeout_secs) |t| {
        _ = c.sqlite3_bind_int(stmt, 21, @intCast(t));
    } else {
        _ = c.sqlite3_bind_null(stmt, 21);
    }
    _ = c.sqlite3_bind_int(stmt, 22, if (job.delivery.best_effort) 1 else 0);
    const st_str = job.session_target.asStr();
    _ = c.sqlite3_bind_text(stmt, 23, st_str.ptr, @intCast(st_str.len), SQLITE_STATIC);
    if (job.skill_name) |sn| {
        _ = c.sqlite3_bind_text(stmt, 24, sn.ptr, @intCast(sn.len), SQLITE_STATIC);
    } else {
        _ = c.sqlite3_bind_null(stmt, 24);
    }
    if (job.skill_args) |sa| {
        _ = c.sqlite3_bind_text(stmt, 25, sa.ptr, @intCast(sa.len), SQLITE_STATIC);
    } else {
        _ = c.sqlite3_bind_null(stmt, 25);
    }

    rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) return error.StepFailed;
}

/// Delete a single job row by id.
fn dbDeleteJob(db: *c.sqlite3, id: []const u8) !void {
    const sql = "DELETE FROM cron_jobs WHERE id = ?1";
    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, sql, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);
    rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) return error.StepFailed;
}

/// Read back a single job row by id and return its id string (caller frees).
/// Returns error.NotFound if no row exists — used to verify a write went through.
fn dbReadJobById(db: *c.sqlite3, allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    const sql = "SELECT id FROM cron_jobs WHERE id = ?1";
    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, sql, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);
    rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_ROW) return error.NotFound;
    return try dbColumnText(stmt, 0, allocator);
}

/// Upsert a single job into the DB and read it back to confirm the write.
/// Uses scheduler.db_path if set, otherwise ~/.nullclaw/cron.db.
pub fn dbUpsertAndVerify(scheduler: *const CronScheduler, job: *const CronJob) !void {
    const db = try openCronDbForScheduler(scheduler);
    defer _ = c.sqlite3_close(db);
    try ensureCronTable(db);
    try dbSaveJob(db, job);
    const read_back = try dbReadJobById(db, scheduler.allocator, job.id);
    scheduler.allocator.free(read_back);
}

/// Delete a single job from the DB by id and verify it is gone.
/// Uses scheduler.db_path if set, otherwise ~/.nullclaw/cron.db.
pub fn dbDeleteAndVerify(scheduler: *const CronScheduler, id: []const u8) !void {
    const db = try openCronDbForScheduler(scheduler);
    defer _ = c.sqlite3_close(db);
    try ensureCronTable(db);
    try dbDeleteJob(db, id);
    const read_back = dbReadJobById(db, scheduler.allocator, id) catch |err| {
        if (err == error.NotFound) return; // expected — row is gone
        return err;
    };
    scheduler.allocator.free(read_back);
    return error.DeleteNotConfirmed;
}

/// Delete DB rows whose IDs are not present in the scheduler's in-memory job list.
/// This is used after upserting all live jobs to clean up removed entries.
fn dbPruneOrphanJobs(db: *c.sqlite3, scheduler: *const CronScheduler) !void {
    // In tests, skip pruning when using the production DB (no explicit db_path).
    // This prevents test schedulers with 1-2 jobs from deleting all production
    // cron jobs as "orphans" (root cause of the 2026-03-25 cron data loss).
    if (builtin.is_test and scheduler.db_path == null) return;
    // Collect all IDs currently in DB.
    const list_sql = "SELECT id FROM cron_jobs";
    var list_stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, list_sql, -1, &list_stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(list_stmt);

    var to_delete: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (to_delete.items) |id| scheduler.allocator.free(id);
        to_delete.deinit(scheduler.allocator);
    }

    while (true) {
        rc = c.sqlite3_step(list_stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.StepFailed;

        const raw = c.sqlite3_column_text(list_stmt, 0);
        if (raw == null) continue;
        const len: usize = @intCast(c.sqlite3_column_bytes(list_stmt, 0));
        if (len == 0) continue;
        const db_id = raw[0..len];

        // Check if this DB id exists in the in-memory scheduler.
        var found = false;
        for (scheduler.jobs.items) |*job| {
            if (std.mem.eql(u8, job.id, db_id)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try to_delete.append(scheduler.allocator, try scheduler.allocator.dupe(u8, db_id));
        }
    }

    for (to_delete.items) |id| {
        try dbDeleteJob(db, id);
    }
}

/// Read a nullable TEXT column as an optional allocated slice.
fn dbColumnTextOpt(stmt: ?*c.sqlite3_stmt, col: c_int, allocator: std.mem.Allocator) !?[]const u8 {
    if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) return null;
    const raw = c.sqlite3_column_text(stmt, col);
    if (raw == null or raw[0] == 0) return null;
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    if (len == 0) return null;
    return try allocator.dupe(u8, raw[0..len]);
}

/// Read a TEXT column as a required allocated slice (errors on null/empty).
fn dbColumnText(stmt: ?*c.sqlite3_stmt, col: c_int, allocator: std.mem.Allocator) ![]const u8 {
    const raw = c.sqlite3_column_text(stmt, col);
    if (raw == null) return error.NullColumn;
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    if (len == 0) return error.EmptyColumn;
    return try allocator.dupe(u8, raw[0..len]);
}

/// Load all rows from cron_jobs into scheduler, replacing existing jobs.
fn dbLoadAllJobs(db: *c.sqlite3, allocator: std.mem.Allocator, scheduler: *CronScheduler) !void {
    const sql =
        "SELECT id, expression, job_type, command, prompt, name, model, " ++
        "next_run_secs, last_run_secs, last_status, paused, one_shot, " ++
        "delete_after_run, enabled, delivery_mode, delivery_channel, " ++
        "delivery_account_id, delivery_to, created_at_s, last_output, timeout_secs, " ++
        "skill_name, skill_args, delivery_best_effort " ++
        "FROM cron_jobs ORDER BY rowid ASC";

    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db, sql, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const id = dbColumnText(stmt, 0, allocator) catch continue;
        errdefer allocator.free(id);
        const expression = dbColumnText(stmt, 1, allocator) catch {
            allocator.free(id);
            continue;
        };
        errdefer allocator.free(expression);

        const job_type_str = dbColumnText(stmt, 2, allocator) catch {
            allocator.free(id);
            allocator.free(expression);
            continue;
        };
        const job_type = JobType.parse(job_type_str);
        allocator.free(job_type_str);

        // command may be null for agent jobs — fall back to prompt
        const command_opt = try dbColumnTextOpt(stmt, 3, allocator);
        const prompt_opt = try dbColumnTextOpt(stmt, 4, allocator);

        const command: []const u8 = blk: {
            if (command_opt) |cmd| break :blk cmd;
            if (job_type == .agent) {
                if (prompt_opt) |p| break :blk try allocator.dupe(u8, p) else break :blk try allocator.dupe(u8, "");
            }
            if (job_type == .skill) break :blk try allocator.dupe(u8, "");
            allocator.free(id);
            allocator.free(expression);
            if (prompt_opt) |p| allocator.free(p);
            continue;
        };
        errdefer allocator.free(command);

        const name_opt = try dbColumnTextOpt(stmt, 5, allocator);
        const model_opt = try dbColumnTextOpt(stmt, 6, allocator);

        const next_run_secs = c.sqlite3_column_int64(stmt, 7);
        const last_run_secs: ?i64 = if (c.sqlite3_column_type(stmt, 8) == c.SQLITE_NULL)
            null
        else
            c.sqlite3_column_int64(stmt, 8);

        // last_status is always a short literal ("ok"/"error"/null).
        // Read it without allocating so we can match to a static string.
        const last_status_raw: ?[]const u8 = blk: {
            if (c.sqlite3_column_type(stmt, 9) == c.SQLITE_NULL) break :blk null;
            const raw = c.sqlite3_column_text(stmt, 9);
            if (raw == null) break :blk null;
            const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 9));
            if (len == 0) break :blk null;
            break :blk raw[0..len]; // points into SQLite's internal buffer; use before next step
        };
        const paused = c.sqlite3_column_int(stmt, 10) != 0;
        const one_shot = c.sqlite3_column_int(stmt, 11) != 0;
        const delete_after_run = c.sqlite3_column_int(stmt, 12) != 0;
        const enabled = c.sqlite3_column_int(stmt, 13) != 0;

        const delivery_mode_str = try dbColumnTextOpt(stmt, 14, allocator);
        const delivery_mode = if (delivery_mode_str) |s| blk: {
            const dm = DeliveryMode.parse(s);
            allocator.free(s);
            break :blk dm;
        } else DeliveryMode.none;

        const delivery_channel = try dbColumnTextOpt(stmt, 15, allocator);
        const delivery_account_id = try dbColumnTextOpt(stmt, 16, allocator);
        const delivery_to = try dbColumnTextOpt(stmt, 17, allocator);
        const created_at_s = c.sqlite3_column_int64(stmt, 18);
        const last_output_opt = try dbColumnTextOpt(stmt, 19, allocator);
        const timeout_secs: ?u32 = if (c.sqlite3_column_type(stmt, 20) == c.SQLITE_NULL)
            null
        else
            @intCast(c.sqlite3_column_int(stmt, 20));
        const skill_name_opt = try dbColumnTextOpt(stmt, 21, allocator);
        const skill_args_opt = try dbColumnTextOpt(stmt, 22, allocator);
        const delivery_best_effort = c.sqlite3_column_int(stmt, 23) != 0;

        // Normalize last_status to a static literal ("ok"/"error"/null).
        // freeJobOwned does NOT free last_status, so we must never heap-allocate it.
        const last_status: ?[]const u8 = if (last_status_raw) |ls| blk: {
            if (std.mem.eql(u8, ls, "ok") or std.mem.eql(u8, ls, "success")) break :blk "ok";
            if (std.mem.eql(u8, ls, "error") or std.mem.eql(u8, ls, "failed")) break :blk "error";
            break :blk null; // unknown value — treat as no status
        } else null;

        try scheduler.jobs.append(allocator, .{
            .id = id,
            .expression = expression,
            .command = command,
            .next_run_secs = next_run_secs,
            .last_run_secs = last_run_secs,
            .last_status = last_status,
            .paused = paused,
            .one_shot = one_shot,
            .job_type = job_type,
            .prompt = prompt_opt,
            .name = name_opt,
            .model = model_opt,
            .timeout_secs = timeout_secs,
            .enabled = enabled,
            .delete_after_run = delete_after_run,
            .created_at_s = created_at_s,
            .last_output = last_output_opt,
            .skill_name = skill_name_opt,
            .skill_args = skill_args_opt,
            .delivery = .{
                .mode = delivery_mode,
                .channel = delivery_channel,
                .account_id = delivery_account_id,
                .to = delivery_to,
                .channel_owned = delivery_channel != null,
                .account_id_owned = delivery_account_id != null,
                .to_owned = delivery_to != null,
                .best_effort = delivery_best_effort,
            },
        });
    }
}

/// Count rows in cron_jobs table. Returns 0 on any error.
fn dbCountJobs(db: *c.sqlite3) usize {
    const sql = "SELECT COUNT(*) FROM cron_jobs";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return 0;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return 0;
    const n = c.sqlite3_column_int64(stmt, 0);
    return if (n < 0) 0 else @intCast(n);
}

/// Migrate existing cron.json into the DB (if DB is empty and JSON exists).
/// After import, renames cron.json to cron.json.migrated.
fn migrateJsonToDb(allocator: std.mem.Allocator, db: *c.sqlite3) void {
    // Load from JSON into a temporary scheduler
    var temp = CronScheduler.init(allocator, 65535, true);
    defer temp.deinit();
    loadJobsWithPolicy(&temp, .best_effort) catch return;
    if (temp.jobs.items.len == 0) return;

    // Begin transaction for atomicity
    var err_msg: [*c]u8 = null;
    _ = c.sqlite3_exec(db, "BEGIN;", null, null, &err_msg);
    if (err_msg) |msg| c.sqlite3_free(msg);

    var all_ok = true;
    for (temp.jobs.items) |*job| {
        dbSaveJob(db, job) catch {
            all_ok = false;
            break;
        };
    }

    if (all_ok) {
        var commit_err: [*c]u8 = null;
        _ = c.sqlite3_exec(db, "COMMIT;", null, null, &commit_err);
        if (commit_err) |msg| c.sqlite3_free(msg);
    } else {
        var rollback_err: [*c]u8 = null;
        _ = c.sqlite3_exec(db, "ROLLBACK;", null, null, &rollback_err);
        if (rollback_err) |msg| c.sqlite3_free(msg);
        return;
    }

    // Rename cron.json → cron.json.migrated so we don't re-import
    const json_path = cronJsonPath(allocator) catch return;
    defer allocator.free(json_path);
    const migrated_path = std.fmt.allocPrint(allocator, "{s}.migrated", .{json_path}) catch return;
    defer allocator.free(migrated_path);
    std.fs.renameAbsolute(json_path, migrated_path) catch {};
    log.info("Migrated {d} cron jobs from cron.json to cron.db", .{temp.jobs.items.len});
}

// ── JSON Persistence ─────────────────────────────────────────────

/// Serializable representation of a cron job for JSON persistence.
const JsonCronJob = struct {
    id: []const u8,
    expression: []const u8,
    command: []const u8,
    next_run_secs: i64,
    last_run_secs: ?i64,
    last_status: ?[]const u8,
    paused: bool,
    one_shot: bool,
    // Delivery config for notifications
    delivery_mode: ?[]const u8 = null,
    delivery_channel: ?[]const u8 = null,
    delivery_account_id: ?[]const u8 = null,
    delivery_to: ?[]const u8 = null,
};

/// Get the default cron.json path: ~/.nullclaw/cron.json
fn cronJsonPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = try platform.getHomeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".nullclaw", "cron.json" });
}

/// Ensure the ~/.nullclaw directory exists.
fn ensureCronDir(allocator: std.mem.Allocator) !void {
    const home = try platform.getHomeDir(allocator);
    defer allocator.free(home);
    const dir = try std.fs.path.join(allocator, &.{ home, ".nullclaw" });
    defer allocator.free(dir);
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Save scheduler jobs to the SQLite DB (~/.nullclaw/cron.db).
/// When SQLite is enabled, DB is authoritative: a DB write failure is returned
/// as an error rather than silently falling back to cron.json.  Falling back
/// would produce divergent state (JSON newer than DB) that the load path
/// cannot safely resolve without re-introducing the empty-DB ambiguity bug.
/// Bulk-save all in-memory jobs. Used for initial startup load and tests.
/// All gateway CRUD ops go through fine-grained dbUpsertAndVerify /
/// dbDeleteAndVerify instead — this path only upserts, never bulk-deletes.
pub fn saveJobs(scheduler: *const CronScheduler) !void {
    if (build_options.enable_sqlite) {
        return saveJobsToDb(scheduler);
    }
    try saveJobsToJson(scheduler);
}

/// Write all in-memory jobs to the cron.db using fine-grained upserts.
/// Each job is INSERT OR REPLACE'd individually, then any DB rows whose IDs
/// are no longer in the scheduler are deleted. This way a crash mid-write
/// never wipes jobs that weren't touched.
fn saveJobsToDb(scheduler: *const CronScheduler) !void {
    const db = try openCronDbForScheduler(scheduler);
    defer _ = c.sqlite3_close(db);

    try ensureCronTable(db);

    // Upsert every in-memory job — safe to call even if job already exists.
    for (scheduler.jobs.items) |*job| {
        try dbSaveJob(db, job);
    }

    // Delete DB rows whose IDs are no longer in the scheduler.
    try dbPruneOrphanJobs(db, scheduler);
}

/// Save scheduler jobs to ~/.nullclaw/cron.json (legacy / fallback).
fn saveJobsToJson(scheduler: *const CronScheduler) !void {
    try ensureCronDir(scheduler.allocator);
    const path = try cronJsonPath(scheduler.allocator);
    defer scheduler.allocator.free(path);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(scheduler.allocator);

    try buf.appendSlice(scheduler.allocator, "[\n");
    for (scheduler.jobs.items, 0..) |job, i| {
        if (i > 0) try buf.appendSlice(scheduler.allocator, ",\n");
        try buf.appendSlice(scheduler.allocator, "  {");

        try json_util.appendJsonKeyValue(&buf, scheduler.allocator, "id", job.id);
        try buf.appendSlice(scheduler.allocator, ",");
        try json_util.appendJsonKeyValue(&buf, scheduler.allocator, "expression", job.expression);
        try buf.appendSlice(scheduler.allocator, ",");
        try json_util.appendJsonKeyValue(&buf, scheduler.allocator, "command", job.command);
        try buf.appendSlice(scheduler.allocator, ",");
        try json_util.appendJsonInt(&buf, scheduler.allocator, "next_run_secs", job.next_run_secs);
        try buf.appendSlice(scheduler.allocator, ",");
        try json_util.appendJsonKey(&buf, scheduler.allocator, "last_run_secs");
        if (job.last_run_secs) |lrs| {
            var int_buf: [24]u8 = undefined;
            const text = std.fmt.bufPrint(&int_buf, "{d}", .{lrs}) catch unreachable;
            try buf.appendSlice(scheduler.allocator, text);
        } else {
            try buf.appendSlice(scheduler.allocator, "null");
        }
        try buf.appendSlice(scheduler.allocator, ",");
        try json_util.appendJsonKey(&buf, scheduler.allocator, "last_status");
        if (job.last_status) |ls| {
            try json_util.appendJsonString(&buf, scheduler.allocator, ls);
        } else {
            try buf.appendSlice(scheduler.allocator, "null");
        }
        try buf.appendSlice(scheduler.allocator, ",");
        try json_util.appendJsonKey(&buf, scheduler.allocator, "paused");
        try buf.appendSlice(scheduler.allocator, if (job.paused) "true" else "false");
        try buf.appendSlice(scheduler.allocator, ",");
        try json_util.appendJsonKey(&buf, scheduler.allocator, "one_shot");
        try buf.appendSlice(scheduler.allocator, if (job.one_shot) "true" else "false");
        try buf.appendSlice(scheduler.allocator, ",");
        try json_util.appendJsonKeyValue(&buf, scheduler.allocator, "job_type", job.job_type.asStr());
        try buf.appendSlice(scheduler.allocator, ",");
        try json_util.appendJsonKey(&buf, scheduler.allocator, "prompt");
        if (job.prompt) |prompt| {
            try json_util.appendJsonString(&buf, scheduler.allocator, prompt);
        } else {
            try buf.appendSlice(scheduler.allocator, "null");
        }
        try buf.appendSlice(scheduler.allocator, ",");
        try json_util.appendJsonKey(&buf, scheduler.allocator, "model");
        if (job.model) |model| {
            try json_util.appendJsonString(&buf, scheduler.allocator, model);
        } else {
            try buf.appendSlice(scheduler.allocator, "null");
        }
        try buf.appendSlice(scheduler.allocator, ",");
        try json_util.appendJsonKey(&buf, scheduler.allocator, "enabled");
        try buf.appendSlice(scheduler.allocator, if (job.enabled) "true" else "false");
        try buf.appendSlice(scheduler.allocator, ",");
        try json_util.appendJsonKey(&buf, scheduler.allocator, "delete_after_run");
        try buf.appendSlice(scheduler.allocator, if (job.delete_after_run) "true" else "false");

        // Delivery config for notifications
        try buf.appendSlice(scheduler.allocator, ",");
        try json_util.appendJsonKey(&buf, scheduler.allocator, "delivery_mode");
        try json_util.appendJsonString(&buf, scheduler.allocator, job.delivery.mode.asStr());
        try buf.appendSlice(scheduler.allocator, ",");
        try json_util.appendJsonKey(&buf, scheduler.allocator, "delivery_channel");
        if (job.delivery.channel) |channel| {
            try json_util.appendJsonString(&buf, scheduler.allocator, channel);
        } else {
            try buf.appendSlice(scheduler.allocator, "null");
        }
        try buf.appendSlice(scheduler.allocator, ",");
        try json_util.appendJsonKey(&buf, scheduler.allocator, "delivery_account_id");
        if (job.delivery.account_id) |account_id| {
            try json_util.appendJsonString(&buf, scheduler.allocator, account_id);
        } else {
            try buf.appendSlice(scheduler.allocator, "null");
        }
        try buf.appendSlice(scheduler.allocator, ",");
        try json_util.appendJsonKey(&buf, scheduler.allocator, "delivery_to");
        if (job.delivery.to) |to| {
            try json_util.appendJsonString(&buf, scheduler.allocator, to);
        } else {
            try buf.appendSlice(scheduler.allocator, "null");
        }
        try buf.appendSlice(scheduler.allocator, ",");
        try json_util.appendJsonKey(&buf, scheduler.allocator, "timeout_secs");
        if (job.timeout_secs) |t| {
            var int_buf: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&int_buf, "{d}", .{t}) catch unreachable;
            try buf.appendSlice(scheduler.allocator, text);
        } else {
            try buf.appendSlice(scheduler.allocator, "null");
        }
        try buf.appendSlice(scheduler.allocator, ",");
        try json_util.appendJsonKey(&buf, scheduler.allocator, "last_output");
        if (job.last_output) |lo| {
            try json_util.appendJsonString(&buf, scheduler.allocator, lo);
        } else {
            try buf.appendSlice(scheduler.allocator, "null");
        }

        try buf.appendSlice(scheduler.allocator, "}");
    }
    try buf.appendSlice(scheduler.allocator, "\n]\n");

    try writeFileAtomic(scheduler.allocator, path, buf.items);
}

/// Load jobs from the SQLite DB (primary) or cron.json (fallback) into the scheduler.
pub fn loadJobs(scheduler: *CronScheduler) !void {
    if (build_options.enable_sqlite) {
        log.info("loading cron jobs from DB...", .{});
        if (loadJobsFromDb(scheduler)) {
            log.info("loaded {d} cron job(s) from DB", .{scheduler.jobs.items.len});
            return;
        } else |err| {
            log.err("cron DB load failed ({s}); DB may be corrupt. Falling back to cron.json. Run: sqlite3 ~/.nullclaw/cron.db '.tables' to diagnose.", .{@errorName(err)});
        }
    }
    log.info("loading cron jobs from cron.json...", .{});
    try loadJobsWithPolicy(scheduler, .best_effort);
    log.info("loaded {d} cron job(s) from cron.json", .{scheduler.jobs.items.len});
}

/// Load jobs from the SQLite DB; returns parse/read errors (except missing file).
pub fn loadJobsStrict(scheduler: *CronScheduler) !void {
    if (build_options.enable_sqlite) {
        // DB is authoritative when SQLite is enabled: an empty DB means zero jobs,
        // not "fall back to cron.json". Falling through to JSON would make an
        // intentionally empty DB indistinguishable from a stale one.
        return loadJobsFromDb(scheduler);
    }
    try loadJobsWithPolicy(scheduler, .strict);
}

/// Load all rows from cron.db into the scheduler.
/// If DB is empty and cron.json exists, migrates automatically.
fn loadJobsFromDb(scheduler: *CronScheduler) !void {
    const db = try openCronDbForScheduler(scheduler);
    defer _ = c.sqlite3_close(db);

    try ensureCronTable(db);

    const count = dbCountJobs(db);
    log.info("cron DB has {d} row(s)", .{count});

    // If DB is empty, try migrating from cron.json
    if (count == 0) {
        migrateJsonToDb(scheduler.allocator, db);
    }

    try dbLoadAllJobs(db, scheduler.allocator, scheduler);
}

/// Replace in-memory jobs with the persisted store content.
pub fn reloadJobs(scheduler: *CronScheduler) !void {
    var loaded = CronScheduler.init(scheduler.allocator, scheduler.max_tasks, scheduler.enabled);
    loaded.db_path = scheduler.db_path; // preserve isolated DB path (important for tests)
    defer loaded.deinit();

    if (build_options.enable_sqlite) {
        loadJobsFromDb(&loaded) catch |err| {
            log.warn("cron DB reload failed ({s}); keeping in-memory state", .{@errorName(err)});
            return;
        };
        std.mem.swap(std.ArrayListUnmanaged(CronJob), &scheduler.jobs, &loaded.jobs);
        return;
    }

    loadJobsStrict(&loaded) catch |err| {
        if (isRecoverableCronStoreError(err)) {
            // Heal malformed/truncated cron.json by persisting current in-memory jobs.
            try saveJobs(scheduler);
            return;
        }
        return err;
    };
    std.mem.swap(std.ArrayListUnmanaged(CronJob), &scheduler.jobs, &loaded.jobs);
}

fn writeFileAtomic(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    const tmp_file = try std.fs.createFileAbsolute(tmp_path, .{});
    errdefer tmp_file.close();
    try tmp_file.writeAll(data);
    tmp_file.close();

    std.fs.renameAbsolute(tmp_path, path) catch {
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(data);
    };
}

fn isRecoverableCronStoreError(err: anyerror) bool {
    return switch (err) {
        error.UnexpectedEndOfInput,
        error.SyntaxError,
        error.InvalidCronStoreFormat,
        => true,
        else => false,
    };
}

// ── CLI entry points (called from main.zig) ──────────────────────

const http_util = @import("http_util.zig");

pub const GatewayRequest = union(enum) {
    unavailable,
    response: http_util.HttpResponse,
};

fn trimOwnedRight(allocator: std.mem.Allocator, raw: []u8) ?[]u8 {
    const trimmed = std.mem.trimRight(u8, raw, " \t\r\n");
    if (trimmed.len == raw.len) return raw;

    const owned = allocator.dupe(u8, trimmed) catch {
        allocator.free(raw);
        return null;
    };
    allocator.free(raw);
    return owned;
}

/// Try to read the gateway URL from ~/.nullclaw/daemon_state.json.
/// Returns an allocated string like "http://127.0.0.1:3000" or null.
fn readGatewayUrl(allocator: std.mem.Allocator) ?[]const u8 {
    const home = platform.getHomeDir(allocator) catch return null;
    defer allocator.free(home);
    const state_path = std.fs.path.join(allocator, &.{ home, ".nullclaw", "daemon_state.json" }) catch return null;
    defer allocator.free(state_path);

    const content = fs_compat.readFileAlloc(std.fs.cwd(), allocator, state_path, 64 * 1024) catch return null;
    defer allocator.free(content);

    // Parse "gateway": "host:port" field
    const key = "\"gateway\":";
    const key_pos = std.mem.indexOf(u8, content, key) orelse return null;
    const after_key = content[key_pos + key.len ..];
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == '\t')) : (i += 1) {}
    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1; // skip opening quote
    const val_start = i;
    while (i < after_key.len and after_key[i] != '"') : (i += 1) {}
    if (i >= after_key.len) return null;
    const host_port = after_key[val_start..i];
    if (host_port.len == 0) return null;
    return std.fmt.allocPrint(allocator, "http://{s}", .{host_port}) catch null;
}

/// Read the paired bearer token from ~/.nullclaw/paired_token (if present).
fn readPairedToken(allocator: std.mem.Allocator) ?[]const u8 {
    const home = platform.getHomeDir(allocator) catch return null;
    defer allocator.free(home);
    const token_path = std.fs.path.join(allocator, &.{ home, ".nullclaw", "paired_token" }) catch return null;
    defer allocator.free(token_path);
    const raw = fs_compat.readFileAlloc(std.fs.cwd(), allocator, token_path, 4096) catch return null;
    return trimOwnedRight(allocator, raw);
}

/// Build Authorization header slice (caller owns via arena/allocator).
fn buildAuthHeader(allocator: std.mem.Allocator, token: ?[]const u8) ?[]const u8 {
    const t = token orelse return null;
    return std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{t}) catch null;
}

pub fn requestGatewayGet(allocator: std.mem.Allocator, path: []const u8) GatewayRequest {
    if (builtin.is_test) return .unavailable;

    const base_url = readGatewayUrl(allocator) orelse return .unavailable;
    defer allocator.free(base_url);

    const token = readPairedToken(allocator);
    defer if (token) |t| allocator.free(t);
    const auth_hdr = buildAuthHeader(allocator, token);
    defer if (auth_hdr) |h| allocator.free(h);

    const url = std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, path }) catch return .unavailable;
    defer allocator.free(url);

    const headers: []const []const u8 = if (auth_hdr) |h| &.{h} else &.{};
    const resp = http_util.curlGetWithStatusAndTimeout(allocator, url, headers, "5") catch return .unavailable;
    if (resp.status_code == 0) {
        allocator.free(resp.body);
        return .unavailable;
    }
    return .{ .response = resp };
}

pub fn requestGatewayPost(allocator: std.mem.Allocator, path: []const u8, json_body: []const u8) GatewayRequest {
    if (builtin.is_test) return .unavailable;

    const base_url = readGatewayUrl(allocator) orelse return .unavailable;
    defer allocator.free(base_url);

    const token = readPairedToken(allocator);
    defer if (token) |t| allocator.free(t);
    const auth_hdr = buildAuthHeader(allocator, token);
    defer if (auth_hdr) |h| allocator.free(h);

    const url = std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, path }) catch return .unavailable;
    defer allocator.free(url);

    const headers: []const []const u8 = if (auth_hdr) |h| &.{h} else &.{};
    const resp = http_util.curlPostWithStatus(allocator, url, json_body, headers) catch return .unavailable;
    if (resp.status_code == 0) {
        allocator.free(resp.body);
        return .unavailable;
    }
    return .{ .response = resp };
}

/// Issue an HTTP GET to the live gateway and print the JSON response.
/// Returns true on success (2xx), false if gateway not reachable or non-2xx.
fn gatewayGet(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8) bool {
    _ = base_url;
    switch (requestGatewayGet(allocator, path)) {
        .unavailable => return false,
        .response => |resp| {
            defer allocator.free(resp.body);
            log.info("{s}", .{resp.body});
            return resp.status_code >= 200 and resp.status_code < 300;
        },
    }
}

/// Issue an HTTP POST to the live gateway with a JSON body.
/// Returns true on success (2xx).
fn gatewayPost(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8, json_body: []const u8) bool {
    _ = base_url;
    switch (requestGatewayPost(allocator, path, json_body)) {
        .unavailable => return false,
        .response => |resp| {
            defer allocator.free(resp.body);
            log.info("{s}", .{resp.body});
            return resp.status_code >= 200 and resp.status_code < 300;
        },
    }
}

const SchedulerStatus = struct {
    config_exists: bool,
    scheduler_enabled: bool,
    daemon_state_present: bool,
    config_probe_error: ?[]const u8 = null,
};

fn absolutePathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn probeSchedulerStatus(config_path: []const u8, daemon_state_path: []const u8, scheduler_enabled: bool) SchedulerStatus {
    return .{
        .config_exists = absolutePathExists(config_path),
        .scheduler_enabled = scheduler_enabled,
        .daemon_state_present = absolutePathExists(daemon_state_path),
    };
}

/// CLI: list all cron jobs.
fn checkSchedulerStatus(allocator: std.mem.Allocator) SchedulerStatus {
    var config_opt = @import("config.zig").Config.load(allocator) catch |err| {
        return .{
            .config_exists = false,
            .scheduler_enabled = false,
            .daemon_state_present = false,
            .config_probe_error = @errorName(err),
        };
    };
    defer config_opt.deinit();

    const daemon_state_path = @import("daemon.zig").stateFilePath(allocator, &config_opt) catch {
        return .{
            .config_exists = absolutePathExists(config_opt.config_path),
            .scheduler_enabled = config_opt.scheduler.enabled,
            .daemon_state_present = false,
        };
    };
    defer allocator.free(daemon_state_path);

    return probeSchedulerStatus(config_opt.config_path, daemon_state_path, config_opt.scheduler.enabled);
}

pub fn cliListJobs(allocator: std.mem.Allocator) !void {
    // If the gateway is running, query it directly instead of reading from disk.
    if (readGatewayUrl(allocator)) |url| {
        defer allocator.free(url);
        if (gatewayGet(allocator, url, "/cron")) return;
    }

    var scheduler = CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    try loadJobs(&scheduler);

    // Check scheduler status and warn user if needed.
    const sched_status = checkSchedulerStatus(allocator);
    if (sched_status.config_probe_error) |err_name| {
        log.warn("Cannot inspect scheduler config: {s}", .{err_name});
    } else if (!sched_status.config_exists) {
        log.warn("Config file not found. Run `nullclaw onboard` first.", .{});
    } else if (!sched_status.scheduler_enabled) {
        log.warn("Cron scheduler is DISABLED in config. Jobs will not run automatically.", .{});
        log.warn("Enable with: scheduler.enabled = true in config, then restart daemon.", .{});
    } else if (!sched_status.daemon_state_present) {
        log.warn("Daemon state file not found. Cron jobs will not run until the daemon starts.", .{});
        log.warn("Start with: nullclaw gateway or nullclaw service start", .{});
    }

    const jobs = scheduler.listJobs();
    if (jobs.len == 0) {
        log.info("No scheduled tasks yet.", .{});
        log.info("Usage:", .{});
        log.info("  nullclaw cron add '*/10 * * * *' 'echo hello'", .{});
        log.info("  nullclaw cron once 30m 'echo reminder'", .{});
        if (sched_status.config_exists and sched_status.scheduler_enabled and sched_status.daemon_state_present) {
            log.info("Scheduler is configured and has written a state file.", .{});
            log.info("Run `nullclaw doctor` to verify live daemon health.", .{});
        }
        return;
    }

    log.info("Scheduled jobs ({d}):", .{jobs.len});
    for (jobs) |job| {
        const flags: []const u8 = blk: {
            if (job.paused and job.one_shot) break :blk " [paused, one-shot]";
            if (job.paused) break :blk " [paused]";
            if (job.one_shot) break :blk " [one-shot]";
            break :blk "";
        };
        const status = job.last_status orelse "n/a";
        log.info("- {s} | {s} | type={s} | next={d} | status={s}{s} cmd: {s}", .{
            job.id,
            job.expression,
            job.job_type.asStr(),
            job.next_run_secs,
            status,
            flags,
            job.command,
        });
    }
}

/// CLI: show scheduler daemon status and diagnostics.
pub fn cliStatus(allocator: std.mem.Allocator) !void {
    const sched_status = checkSchedulerStatus(allocator);

    log.info("Cron Scheduler Status:", .{});

    if (sched_status.config_probe_error) |err_name| {
        log.info("  Config probe:      error ({s})", .{err_name});
        return;
    }

    log.info("  Config file:       {s}", .{if (sched_status.config_exists) "present" else "missing"});
    log.info("  Scheduler enabled: {s}", .{if (sched_status.scheduler_enabled) "yes" else "no"});
    log.info("  Daemon state file: {s}", .{if (sched_status.daemon_state_present) "present" else "missing"});

    if (!sched_status.config_exists) {
        log.info("  Status: missing configuration; run `nullclaw onboard` first", .{});
    } else if (!sched_status.scheduler_enabled) {
        log.info("  Status: scheduler disabled in config", .{});
        log.info("  Fix: Set scheduler.enabled = true in config, then restart", .{});
    } else if (!sched_status.daemon_state_present) {
        log.info("  Status: no daemon state file found yet", .{});
        log.info("  Fix: Start daemon with `nullclaw gateway` or `nullclaw service start`", .{});
    } else {
        log.info("  Status: configured; run `nullclaw doctor` for live daemon health", .{});
    }

    // Show job count
    var scheduler = CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    try loadJobs(&scheduler);
    const jobs = scheduler.listJobs();
    log.info("  Jobs loaded: {d} total", .{jobs.len});

    if (jobs.len > 0) {
        var enabled_count: usize = 0;
        var paused_count: usize = 0;
        for (jobs) |job| {
            if (job.paused) {
                paused_count += 1;
            } else {
                enabled_count += 1;
            }
        }
        log.info("    - {d} active, {d} paused", .{ enabled_count, paused_count });
    }
}

/// CLI: add a recurring cron job.
pub fn cliAddJob(allocator: std.mem.Allocator, expression: []const u8, command: []const u8) !void {
    if (readGatewayUrl(allocator)) |url| {
        defer allocator.free(url);
        var body_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer body_buf.deinit(allocator);
        body_buf.appendSlice(allocator, "{") catch {};
        json_util.appendJsonKeyValue(&body_buf, allocator, "expression", expression) catch {};
        body_buf.appendSlice(allocator, ",") catch {};
        json_util.appendJsonKeyValue(&body_buf, allocator, "command", command) catch {};
        body_buf.appendSlice(allocator, "}") catch {};
        if (gatewayPost(allocator, url, "/cron/add", body_buf.items)) return;
    }

    // Build the job in-memory to get an ID and computed next_run_secs,
    // then write it atomically to the DB (no load-all required).
    if (build_options.enable_sqlite) db_blk: {
        var temp = CronScheduler.init(allocator, 65535, true);
        defer temp.deinit();
        const job = temp.addJob(expression, command) catch break :db_blk;
        const db = openCronDb(allocator) catch break :db_blk;
        defer _ = c.sqlite3_close(db);
        ensureCronTable(db) catch break :db_blk;
        // Migrate any legacy cron.json jobs before inserting so they are not lost.
        if (dbCountJobs(db) == 0) migrateJsonToDb(allocator, db);
        _ = dbSaveJob(db, job) catch break :db_blk;
        log.info("Added cron job {s}", .{job.id});
        log.info("  Expr: {s}", .{job.expression});
        log.info("  Next: {d}", .{job.next_run_secs});
        log.info("  Cmd : {s}", .{job.command});
        return;
    }

    var scheduler = CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    try loadJobs(&scheduler);

    const job = try scheduler.addJob(expression, command);
    try saveJobs(&scheduler);

    log.info("Added cron job {s}", .{job.id});
    log.info("  Expr: {s}", .{job.expression});
    log.info("  Next: {d}", .{job.next_run_secs});
    log.info("  Cmd : {s}", .{job.command});
}

/// CLI: add a recurring agent job.
pub fn cliAddAgentJob(allocator: std.mem.Allocator, expression: []const u8, prompt: []const u8, model: ?[]const u8, delivery: DeliveryConfig) !void {
    if (readGatewayUrl(allocator)) |url| {
        defer allocator.free(url);
        // Build JSON body, escaping string values through json_util
        var body_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer body_buf.deinit(allocator);
        body_buf.appendSlice(allocator, "{") catch {};
        json_util.appendJsonKeyValue(&body_buf, allocator, "expression", expression) catch {};
        body_buf.appendSlice(allocator, ",") catch {};
        json_util.appendJsonKeyValue(&body_buf, allocator, "prompt", prompt) catch {};
        if (model) |m| {
            body_buf.appendSlice(allocator, ",") catch {};
            json_util.appendJsonKeyValue(&body_buf, allocator, "model", m) catch {};
        }
        if (delivery.mode != .none) {
            body_buf.appendSlice(allocator, ",") catch {};
            json_util.appendJsonKeyValue(&body_buf, allocator, "delivery_mode", delivery.mode.asStr()) catch {};
        }
        if (delivery.channel) |ch| {
            body_buf.appendSlice(allocator, ",") catch {};
            json_util.appendJsonKeyValue(&body_buf, allocator, "delivery_channel", ch) catch {};
        }
        if (delivery.account_id) |account_id| {
            body_buf.appendSlice(allocator, ",") catch {};
            json_util.appendJsonKeyValue(&body_buf, allocator, "delivery_account_id", account_id) catch {};
        }
        if (delivery.to) |t| {
            body_buf.appendSlice(allocator, ",") catch {};
            json_util.appendJsonKeyValue(&body_buf, allocator, "delivery_to", t) catch {};
        }
        if (!delivery.best_effort) {
            body_buf.appendSlice(allocator, ",\"delivery_best_effort\":false") catch {};
        }
        body_buf.appendSlice(allocator, "}") catch {};
        if (body_buf.items.len > 2) {
            if (gatewayPost(allocator, url, "/cron/add", body_buf.items)) return;
        }
    }

    if (build_options.enable_sqlite) db_blk: {
        var temp = CronScheduler.init(allocator, 65535, true);
        defer temp.deinit();
        const job = temp.addAgentJob(expression, prompt, model, delivery) catch break :db_blk;
        const db = openCronDb(allocator) catch break :db_blk;
        defer _ = c.sqlite3_close(db);
        ensureCronTable(db) catch break :db_blk;
        if (dbCountJobs(db) == 0) migrateJsonToDb(allocator, db);
        _ = dbSaveJob(db, job) catch break :db_blk;
        log.info("Added agent cron job {s}", .{job.id});
        log.info("  Expr : {s}", .{job.expression});
        log.info("  Type : {s}", .{job.job_type.asStr()});
        if (job.model) |m| log.info("  Model: {s}", .{m});
        return;
    }

    var scheduler = CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    try loadJobs(&scheduler);

    const job = try scheduler.addAgentJob(expression, prompt, model, delivery);
    try saveJobs(&scheduler);

    log.info("Added agent cron job {s}", .{job.id});
    log.info("  Expr : {s}", .{job.expression});
    log.info("  Type : {s}", .{job.job_type.asStr()});
    if (job.model) |m| log.info("  Model: {s}", .{m});
}

/// CLI: add a recurring skill job (job_type=skill).
/// DB-direct — does not route through the gateway HTTP API.
pub fn cliAddSkillJob(allocator: std.mem.Allocator, expression: []const u8, skill_name: []const u8, skill_args: ?[]const u8, delivery: DeliveryConfig, timeout_secs: ?u32) !void {
    if (build_options.enable_sqlite) db_blk: {
        var temp = CronScheduler.init(allocator, 65535, true);
        defer temp.deinit();
        const job = temp.addSkillJob(expression, skill_name, skill_args, delivery, timeout_secs) catch break :db_blk;
        const db = openCronDb(allocator) catch break :db_blk;
        defer _ = c.sqlite3_close(db);
        ensureCronTable(db) catch break :db_blk;
        if (dbCountJobs(db) == 0) migrateJsonToDb(allocator, db);
        _ = dbSaveJob(db, job) catch break :db_blk;
        log.info("Added skill cron job {s}", .{job.id});
        log.info("  Expr : {s}", .{job.expression});
        log.info("  Skill: {s}", .{skill_name});
        if (skill_args) |sa| log.info("  Args : {s}", .{sa});
        return;
    }

    var scheduler = CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    try loadJobs(&scheduler);

    const job = try scheduler.addSkillJob(expression, skill_name, skill_args, delivery, timeout_secs);
    try saveJobs(&scheduler);

    log.info("Added skill cron job {s}", .{job.id});
    log.info("  Expr : {s}", .{job.expression});
    log.info("  Skill: {s}", .{skill_name});
    if (skill_args) |sa| log.info("  Args : {s}", .{sa});
}

/// CLI: add a one-shot delayed task.
pub fn cliAddOnce(allocator: std.mem.Allocator, delay: []const u8, command: []const u8) !void {
    if (readGatewayUrl(allocator)) |url| {
        defer allocator.free(url);
        var body_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer body_buf.deinit(allocator);
        body_buf.appendSlice(allocator, "{") catch {};
        json_util.appendJsonKeyValue(&body_buf, allocator, "delay", delay) catch {};
        body_buf.appendSlice(allocator, ",") catch {};
        json_util.appendJsonKeyValue(&body_buf, allocator, "command", command) catch {};
        body_buf.appendSlice(allocator, "}") catch {};
        if (gatewayPost(allocator, url, "/cron/add", body_buf.items)) return;
    }

    var scheduler = CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    try loadJobs(&scheduler);

    const job = try scheduler.addOnce(delay, command);
    try saveJobs(&scheduler);

    log.info("Added one-shot task {s}", .{job.id});
    log.info("  Runs at: {d}", .{job.next_run_secs});
    log.info("  Cmd    : {s}", .{job.command});
}

/// CLI: add a one-shot delayed agent task.
pub fn cliAddAgentOnce(allocator: std.mem.Allocator, delay: []const u8, prompt: []const u8, model: ?[]const u8) !void {
    if (readGatewayUrl(allocator)) |url| {
        defer allocator.free(url);
        var body_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer body_buf.deinit(allocator);
        body_buf.appendSlice(allocator, "{") catch {};
        json_util.appendJsonKeyValue(&body_buf, allocator, "delay", delay) catch {};
        body_buf.appendSlice(allocator, ",") catch {};
        json_util.appendJsonKeyValue(&body_buf, allocator, "prompt", prompt) catch {};
        if (model) |m| {
            body_buf.appendSlice(allocator, ",") catch {};
            json_util.appendJsonKeyValue(&body_buf, allocator, "model", m) catch {};
        }
        body_buf.appendSlice(allocator, "}") catch {};
        if (gatewayPost(allocator, url, "/cron/add", body_buf.items)) return;
    }

    var scheduler = CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    try loadJobs(&scheduler);

    const job = try scheduler.addAgentOnce(delay, prompt, model);
    try saveJobs(&scheduler);

    log.info("Added one-shot agent task {s}", .{job.id});
    log.info("  Runs at: {d}", .{job.next_run_secs});
    log.info("  Type   : {s}", .{job.job_type.asStr()});
    if (job.model) |m| log.info("  Model  : {s}", .{m});
}

/// CLI: remove a cron job by ID.
pub fn cliRemoveJob(allocator: std.mem.Allocator, id: []const u8) !void {
    if (readGatewayUrl(allocator)) |url| {
        defer allocator.free(url);
        var body_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer body_buf.deinit(allocator);
        body_buf.appendSlice(allocator, "{") catch {};
        json_util.appendJsonKeyValue(&body_buf, allocator, "id", id) catch {};
        body_buf.appendSlice(allocator, "}") catch {};
        if (gatewayPost(allocator, url, "/cron/remove", body_buf.items)) return;
    }

    if (build_options.enable_sqlite) db_blk: {
        const db = openCronDb(allocator) catch break :db_blk;
        defer _ = c.sqlite3_close(db);
        ensureCronTable(db) catch break :db_blk;
        dbDeleteJob(db, id) catch break :db_blk;
        log.info("Removed cron job {s}", .{id});
        return;
    }

    var scheduler = CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    try loadJobs(&scheduler);

    if (scheduler.removeJob(id)) {
        try saveJobs(&scheduler);
        log.info("Removed cron job {s}", .{id});
    } else {
        log.warn("Cron job '{s}' not found", .{id});
    }
}

/// CLI: pause a cron job by ID.
pub fn cliPauseJob(allocator: std.mem.Allocator, id: []const u8) !void {
    if (readGatewayUrl(allocator)) |url| {
        defer allocator.free(url);
        var body_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer body_buf.deinit(allocator);
        body_buf.appendSlice(allocator, "{") catch {};
        json_util.appendJsonKeyValue(&body_buf, allocator, "id", id) catch {};
        body_buf.appendSlice(allocator, "}") catch {};
        if (gatewayPost(allocator, url, "/cron/pause", body_buf.items)) return;
    }

    if (build_options.enable_sqlite) db_blk: {
        const db = openCronDb(allocator) catch break :db_blk;
        defer _ = c.sqlite3_close(db);
        ensureCronTable(db) catch break :db_blk;
        const sql = "UPDATE cron_jobs SET paused = 1 WHERE id = ?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) break :db_blk;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) break :db_blk;
        log.info("Paused job {s}", .{id});
        return;
    }

    var scheduler = CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    try loadJobs(&scheduler);

    if (scheduler.pauseJob(id)) {
        try saveJobs(&scheduler);
        log.info("Paused job {s}", .{id});
    } else {
        log.warn("Cron job '{s}' not found", .{id});
    }
}

/// CLI: resume a paused cron job by ID.
pub fn cliResumeJob(allocator: std.mem.Allocator, id: []const u8) !void {
    if (readGatewayUrl(allocator)) |url| {
        defer allocator.free(url);
        var body_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer body_buf.deinit(allocator);
        body_buf.appendSlice(allocator, "{") catch {};
        json_util.appendJsonKeyValue(&body_buf, allocator, "id", id) catch {};
        body_buf.appendSlice(allocator, "}") catch {};
        if (gatewayPost(allocator, url, "/cron/resume", body_buf.items)) return;
    }

    if (build_options.enable_sqlite) db_blk: {
        const db = openCronDb(allocator) catch break :db_blk;
        defer _ = c.sqlite3_close(db);
        ensureCronTable(db) catch break :db_blk;
        const sql = "UPDATE cron_jobs SET paused = 0 WHERE id = ?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) break :db_blk;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) break :db_blk;
        log.info("Resumed job {s}", .{id});
        return;
    }

    var scheduler = CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    try loadJobs(&scheduler);

    if (scheduler.resumeJob(id)) {
        try saveJobs(&scheduler);
        log.info("Resumed job {s}", .{id});
    } else {
        log.warn("Cron job '{s}' not found", .{id});
    }
}

fn resolveRunnableCwd(cwd_opt: ?[]const u8) ?[]const u8 {
    const cwd = cwd_opt orelse return null;
    if (cwd.len == 0) return null;

    if (std.fs.path.isAbsolute(cwd)) {
        std.fs.accessAbsolute(cwd, .{}) catch return null;
    } else {
        std.fs.cwd().access(cwd, .{}) catch return null;
    }
    return cwd;
}

pub fn cliRunJob(allocator: std.mem.Allocator, id: []const u8) !void {
    // Prefer delegating to the live gateway so delivery (Telegram etc.) works.
    if (readGatewayUrl(allocator)) |url| {
        defer allocator.free(url);
        var body_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer body_buf.deinit(allocator);
        body_buf.appendSlice(allocator, "{") catch {};
        json_util.appendJsonKeyValue(&body_buf, allocator, "id", id) catch {};
        body_buf.appendSlice(allocator, "}") catch {};
        if (gatewayPost(allocator, url, "/cron/run", body_buf.items)) {
            log.info("Job '{s}' triggered via gateway (delivery active).", .{id});
            return;
        }
    }

    var cfg_opt: ?Config = Config.load(allocator) catch null;
    defer if (cfg_opt) |*cfg| cfg.deinit();

    var scheduler = CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    if (cfg_opt) |cfg| {
        scheduler.setShellCwd(cfg.workspace_dir);
        scheduler.setAgentTimeoutSecs(cfg.scheduler.agent_timeout_secs);
    }
    try loadJobs(&scheduler);
    const run_cwd = resolveRunnableCwd(scheduler.shell_cwd);
    if (scheduler.shell_cwd != null and run_cwd == null) {
        log.warn("Cron shell cwd is unavailable; falling back to process cwd for manual run.", .{});
    }

    if (scheduler.getMutableJob(id)) |job| {
        log.info("Running job '{s}': {s}", .{ id, job.command });
        const run_at = std.time.timestamp();
        switch (job.job_type) {
            .shell => {
                const resolved_cli_cmd = resolveSkillCommand(allocator, job.command) catch null;
                defer if (resolved_cli_cmd) |rc| allocator.free(rc);
                const effective_cli_cmd = resolved_cli_cmd orelse job.command;
                const result = std.process.Child.run(.{
                    .allocator = allocator,
                    .argv = &.{ platform.getShell(), platform.getShellFlag(), effective_cli_cmd },
                    .cwd = run_cwd,
                }) catch |err| {
                    job.last_run_secs = run_at;
                    job.last_status = "error";
                    dbUpsertAndVerify(&scheduler, job) catch {};
                    log.err("Job '{s}' failed: {s}", .{ id, @errorName(err) });
                    return;
                };
                defer allocator.free(result.stdout);
                defer allocator.free(result.stderr);
                if (result.stdout.len > 0) log.info("{s}", .{result.stdout});
                const exit_code: u8 = switch (result.term) {
                    .Exited => |code| code,
                    else => 1,
                };
                job.last_run_secs = run_at;
                job.last_status = if (exit_code == 0) "ok" else "error";
                try dbUpsertAndVerify(&scheduler, job);
                log.info("Job '{s}' completed (exit {d}).", .{ id, exit_code });
            },
            .agent => {
                const raw_prompt = job.prompt orelse job.command;
                const resolved_prompt = resolveSkillPrompt(allocator, raw_prompt) catch null;
                defer if (resolved_prompt) |rp| allocator.free(rp);
                const prompt = resolved_prompt orelse raw_prompt;
                const effective_timeout: u64 = if (job.timeout_secs) |t| t else scheduler.agent_timeout_secs;
                const result = runAgentJob(allocator, run_cwd, prompt, job.model, effective_timeout) catch |err| {
                    job.last_run_secs = run_at;
                    job.last_status = "error";
                    dbUpsertAndVerify(&scheduler, job) catch {};
                    log.err("Agent job '{s}' failed: {s}", .{ id, @errorName(err) });
                    return;
                };
                defer allocator.free(result.output);
                if (result.output.len > 0) log.info("{s}", .{result.output});
                job.last_run_secs = run_at;
                job.last_status = if (result.success) "ok" else "error";
                try dbUpsertAndVerify(&scheduler, job);
                log.info("Agent job '{s}' completed ({s}).", .{ id, if (result.success) "ok" else "error" });
            },
            .skill => {
                const skill_cmd = resolveSkillExec(allocator, job.skill_name, job.skill_args) catch |err| {
                    job.last_run_secs = run_at;
                    job.last_status = "error";
                    dbUpsertAndVerify(&scheduler, job) catch {};
                    log.err("Skill resolution for job '{s}' failed: {s}", .{ id, @errorName(err) });
                    return;
                };
                defer allocator.free(skill_cmd);
                const result = std.process.Child.run(.{
                    .allocator = allocator,
                    .argv = &.{ platform.getShell(), platform.getShellFlag(), skill_cmd },
                    .cwd = run_cwd,
                }) catch |err| {
                    job.last_run_secs = run_at;
                    job.last_status = "error";
                    dbUpsertAndVerify(&scheduler, job) catch {};
                    log.err("Skill job '{s}' failed: {s}", .{ id, @errorName(err) });
                    return;
                };
                defer allocator.free(result.stdout);
                defer allocator.free(result.stderr);
                if (result.stdout.len > 0) log.info("{s}", .{result.stdout});
                const exit_code: u8 = switch (result.term) {
                    .Exited => |code| code,
                    else => 1,
                };
                job.last_run_secs = run_at;
                job.last_status = if (exit_code == 0) "ok" else "error";
                try dbUpsertAndVerify(&scheduler, job);
                log.info("Skill job '{s}' completed (exit {d}).", .{ id, exit_code });
            },
        }
    } else {
        log.warn("Cron job '{s}' not found", .{id});
    }
}

/// CLI: update a cron job's expression, command, or enabled state.
pub fn cliUpdateJob(
    allocator: std.mem.Allocator,
    id: []const u8,
    expression: ?[]const u8,
    command: ?[]const u8,
    prompt: ?[]const u8,
    model: ?[]const u8,
    enabled: ?bool,
) !void {
    if (readGatewayUrl(allocator)) |url| {
        defer allocator.free(url);
        var body_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer body_buf.deinit(allocator);
        body_buf.appendSlice(allocator, "{") catch {};
        json_util.appendJsonKeyValue(&body_buf, allocator, "id", id) catch {};
        if (expression) |e| {
            body_buf.appendSlice(allocator, ",") catch {};
            json_util.appendJsonKeyValue(&body_buf, allocator, "expression", e) catch {};
        }
        if (command) |cmd| {
            body_buf.appendSlice(allocator, ",") catch {};
            json_util.appendJsonKeyValue(&body_buf, allocator, "command", cmd) catch {};
        }
        if (prompt) |p| {
            body_buf.appendSlice(allocator, ",") catch {};
            json_util.appendJsonKeyValue(&body_buf, allocator, "prompt", p) catch {};
        }
        if (model) |m| {
            body_buf.appendSlice(allocator, ",") catch {};
            json_util.appendJsonKeyValue(&body_buf, allocator, "model", m) catch {};
        }
        if (enabled) |ena| {
            body_buf.appendSlice(allocator, ",\"enabled\":") catch {};
            body_buf.appendSlice(allocator, if (ena) "true" else "false") catch {};
        }
        body_buf.appendSlice(allocator, "}") catch {};
        if (gatewayPost(allocator, url, "/cron/update", body_buf.items)) return;
    }

    // For update, we load the current state, apply the patch in memory,
    // then write back. saveJobs writes to DB (primary) or JSON (fallback).
    var scheduler = CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    try loadJobs(&scheduler);

    const patch = CronJobPatch{
        .expression = expression,
        .command = command,
        .prompt = prompt,
        .model = model,
        .enabled = enabled,
    };
    if (scheduler.updateJob(allocator, id, patch)) {
        // If SQLite is enabled, write only the updated row directly to the DB
        // to avoid rewriting all rows just to patch one.
        if (build_options.enable_sqlite) direct_db: {
            const updated_job = scheduler.getJob(id) orelse break :direct_db;
            const db = openCronDb(allocator) catch break :direct_db;
            defer _ = c.sqlite3_close(db);
            ensureCronTable(db) catch break :direct_db;
            dbSaveJob(db, updated_job) catch break :direct_db;
            log.info("Updated job {s}", .{id});
            return;
        }
        try saveJobs(&scheduler);
        log.info("Updated job {s}", .{id});
    } else {
        log.warn("Cron job '{s}' not found", .{id});
    }
}

/// CLI: list run history for a cron job.
pub fn cliListRuns(allocator: std.mem.Allocator, id: []const u8) !void {
    var scheduler = CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    try loadJobs(&scheduler);

    if (scheduler.getJob(id)) |job| {
        log.info("Run history for job {s} ({s}):", .{ id, job.command });
        const status = job.last_status orelse "never run";
        log.info("  Last status: {s}", .{status});
        var ts_buf: [64]u8 = undefined;
        const formatted = formatUnixTimestamp(job.next_run_secs, &ts_buf);
        log.info("  Next run:    {d} ({s})", .{ job.next_run_secs, formatted });
    } else {
        log.warn("Cron job '{s}' not found", .{id});
    }
}

/// CLI: backup cron.db to ~/.nullclaw/backup/cron.db.<timestamp>
pub fn cliBackup(allocator: std.mem.Allocator) !void {
    const home = try platform.getHomeDir(allocator);
    defer allocator.free(home);
    const db_path = try std.fs.path.join(allocator, &.{ home, ".nullclaw", "cron.db" });
    defer allocator.free(db_path);
    const backup_dir = try std.fs.path.join(allocator, &.{ home, ".nullclaw", "backup" });
    defer allocator.free(backup_dir);

    std.fs.cwd().makePath(backup_dir) catch {};

    // Generate timestamp suffix
    const now = std.time.timestamp();
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(now) };
    const day = epoch.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = epoch.getDaySeconds();
    var ts_buf: [32]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "{d}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch "unknown";

    const backup_name = try std.fmt.allocPrint(allocator, "cron.db.{s}", .{ts});
    defer allocator.free(backup_name);
    const backup_path = try std.fs.path.join(allocator, &.{ backup_dir, backup_name });
    defer allocator.free(backup_path);

    std.fs.cwd().copyFile(db_path, std.fs.cwd(), backup_path, .{}) catch |err| {
        log.err("Backup failed: {s}", .{@errorName(err)});
        return err;
    };
    log.info("Backed up to {s}", .{backup_path});
}

/// CLI: restore cron.db from a backup file. If no file specified, uses the latest backup.
pub fn cliRestore(allocator: std.mem.Allocator, file_arg: ?[]const u8) !void {
    const home = try platform.getHomeDir(allocator);
    defer allocator.free(home);
    const db_path = try std.fs.path.join(allocator, &.{ home, ".nullclaw", "cron.db" });
    defer allocator.free(db_path);

    if (file_arg) |file| {
        // Restore from specified file
        std.fs.cwd().copyFile(file, std.fs.cwd(), db_path, .{}) catch |err| {
            log.err("Restore failed: {s}", .{@errorName(err)});
            return err;
        };
        log.info("Restored cron.db from {s}", .{file});
        return;
    }

    // Find latest backup
    const backup_dir = try std.fs.path.join(allocator, &.{ home, ".nullclaw", "backup" });
    defer allocator.free(backup_dir);
    var dir = std.fs.cwd().openDir(backup_dir, .{ .iterate = true }) catch |err| {
        log.err("Cannot open backup dir: {s}", .{@errorName(err)});
        return err;
    };
    defer dir.close();

    var latest: ?[]const u8 = null;
    defer if (latest) |l| allocator.free(l);
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, "cron.db.")) {
            if (latest == null or std.mem.order(u8, entry.name, latest.?).compare(.gt)) {
                if (latest) |l| allocator.free(l);
                latest = try allocator.dupe(u8, entry.name);
            }
        }
    }

    if (latest) |name| {
        const src_path = try std.fs.path.join(allocator, &.{ backup_dir, name });
        defer allocator.free(src_path);
        std.fs.cwd().copyFile(src_path, std.fs.cwd(), db_path, .{}) catch |err| {
            log.err("Restore failed: {s}", .{@errorName(err)});
            return err;
        };
        log.info("Restored cron.db from {s}", .{src_path});
    } else {
        log.err("No backups found in {s}", .{backup_dir});
    }
}

/// CLI: export all enabled DB jobs to ~/.nullclaw/cron-seed.json
pub fn cliExportSeed(allocator: std.mem.Allocator) !void {
    const home = try platform.getHomeDir(allocator);
    defer allocator.free(home);
    const seed_path = try std.fs.path.join(allocator, &.{ home, ".nullclaw", "cron-seed.json" });
    defer allocator.free(seed_path);

    // Load all jobs from DB
    var scheduler = CronScheduler.init(allocator, 65535, true);
    defer scheduler.deinit();
    try loadJobs(&scheduler);

    // Build JSON array of enabled jobs (seed format: definition only, no runtime state)
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("[\n");
    var count: usize = 0;
    for (scheduler.jobs.items) |job| {
        if (!job.enabled) continue;
        if (count > 0) try w.writeAll(",\n");
        try w.writeAll("  {");
        try w.print("\"expression\":\"{s}\"", .{job.expression});
        try w.print(",\"job_type\":\"{s}\"", .{job.job_type.asStr()});
        if (job.command.len > 0 and job.job_type != .skill) {
            try w.print(",\"command\":{f}", .{std.json.fmt(job.command, .{})});
        }
        if (job.prompt) |p| {
            try w.print(",\"prompt\":{f}", .{std.json.fmt(p, .{})});
        }
        if (job.model) |m| {
            try w.print(",\"model\":\"{s}\"", .{m});
        }
        if (job.skill_name) |sn| {
            try w.print(",\"skill_name\":\"{s}\"", .{sn});
        }
        if (job.skill_args) |sa| {
            try w.print(",\"skill_args\":{f}", .{std.json.fmt(sa, .{})});
        }
        if (job.timeout_secs) |t| {
            try w.print(",\"timeout_secs\":{d}", .{t});
        }
        if (job.one_shot) try w.writeAll(",\"one_shot\":true");
        if (job.delete_after_run) try w.writeAll(",\"delete_after_run\":true");
        try w.print(",\"delivery_mode\":\"{s}\"", .{job.delivery.mode.asStr()});
        if (job.delivery.channel) |ch| try w.print(",\"delivery_channel\":\"{s}\"", .{ch});
        if (job.delivery.to) |t| try w.print(",\"delivery_to\":\"{s}\"", .{t});
        if (job.delivery.account_id) |a| try w.print(",\"delivery_account_id\":\"{s}\"", .{a});
        if (job.delivery.best_effort) try w.writeAll(",\"delivery_best_effort\":true");
        if (job.session_target != .isolated) try w.print(",\"session_target\":\"{s}\"", .{job.session_target.asStr()});
        try w.writeAll("}");
        count += 1;
    }
    try w.writeAll("\n]\n");

    const file = try std.fs.cwd().createFile(seed_path, .{});
    defer file.close();
    try file.writeAll(buf.items);
    log.info("Exported {d} jobs to {s}", .{ count, seed_path });
}

/// CLI: load jobs from ~/.nullclaw/cron-seed.json into DB (DB-direct, no gateway).
pub fn cliLoadSeed(allocator: std.mem.Allocator) !void {
    const home = try platform.getHomeDir(allocator);
    defer allocator.free(home);
    const seed_path = try std.fs.path.join(allocator, &.{ home, ".nullclaw", "cron-seed.json" });
    defer allocator.free(seed_path);

    const content = std.fs.cwd().readFileAlloc(allocator, seed_path, 1024 * 1024) catch |err| {
        log.err("Cannot read {s}: {s}", .{ seed_path, @errorName(err) });
        return err;
    };
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch |err| {
        log.err("Invalid JSON in {s}: {s}", .{ seed_path, @errorName(err) });
        return err;
    };
    defer parsed.deinit();

    if (parsed.value != .array) {
        log.err("Seed must be a JSON array", .{});
        return error.InvalidSeedFormat;
    }

    const db = try openCronDb(allocator);
    defer closeCronDb(db);
    try ensureCronTable(db);

    var count: usize = 0;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;

        const expression = jsonStr(obj, "expression") orelse continue;
        const job_type_str = jsonStr(obj, "job_type") orelse "shell";
        const jtype = JobType.parse(job_type_str);

        var temp = CronScheduler.init(allocator, 65535, true);
        defer temp.deinit();

        const delivery = DeliveryConfig{
            .mode = if (jsonStr(obj, "delivery_mode")) |m| DeliveryMode.parse(m) else .none,
            .channel = jsonStr(obj, "delivery_channel"),
            .account_id = jsonStr(obj, "delivery_account_id"),
            .to = jsonStr(obj, "delivery_to"),
            .best_effort = if (obj.get("delivery_best_effort")) |v| (v == .bool and v.bool) else false,
        };

        const timeout: ?u32 = if (obj.get("timeout_secs")) |v| switch (v) {
            .integer => |i| if (i > 0) @intCast(i) else null,
            else => null,
        } else null;

        const job = switch (jtype) {
            .skill => temp.addSkillJob(
                expression,
                jsonStr(obj, "skill_name") orelse continue,
                jsonStr(obj, "skill_args"),
                delivery,
                timeout,
            ) catch continue,
            .agent => temp.addAgentJob(
                expression,
                jsonStr(obj, "prompt") orelse jsonStr(obj, "command") orelse continue,
                jsonStr(obj, "model"),
                delivery,
            ) catch continue,
            .shell => temp.addJob(
                expression,
                jsonStr(obj, "command") orelse continue,
            ) catch continue,
        };

        _ = dbSaveJob(db, job) catch continue;
        count += 1;
    }
    log.info("Loaded {d} jobs from {s}", .{ count, seed_path });
}

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |v| {
        if (v == .string) return v.string;
    }
    return null;
}

/// Format a Unix timestamp (seconds since epoch) into a human-readable string.
/// Returns: "Mon Mar 02 2026 12:39:00 UTC"
fn formatUnixTimestamp(secs: i64, buf: []u8) []const u8 {
    const min_formatted_len = "Thu Jan 01 1970 00:00:00 UTC".len;
    if (buf.len < min_formatted_len) return "buffer too small";
    if (secs < 0) return "invalid timestamp";

    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const epoch_day = epoch_secs.getEpochDay();
    const day_seconds = epoch_secs.getDaySeconds();

    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    // Jan 1, 1970 was Thursday (day 0 = Thu, day 4 = Mon, etc.)
    // Formula: (epoch_day.day + 4) % 7 gives us an index into the weekday array
    const weekday_num = @as(u3, @intCast((epoch_day.day + 4) % 7));
    const weekday_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();
    const second = day_seconds.getSecondsIntoMinute();

    const month_num = month_day.month.numeric();
    const month_index = if (month_num > 0 and month_num <= 12) month_num - 1 else 0;
    const month_name = month_names[month_index];

    const len = std.fmt.bufPrint(buf, "{s} {s} {d:0>2} {d} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
        weekday_names[weekday_num],
        month_name,
        month_day.day_index + 1,
        year_day.year,
        hour,
        minute,
        second,
    }) catch return "format error";

    return buf[0..len.len];
}

// ── Backwards-compatible type alias ──────────────────────────────────

pub const Task = CronJob;

// ── DB-direct run queue functions (Phase 2) ──────────────────────────

/// Arena-owned snapshot of a cron job, used by the worker thread.
/// All slices point into the arena and are freed together.
pub const CronJobSpec = struct {
    id: []const u8,
    job_type: JobType,
    command: []const u8,
    prompt: ?[]const u8,
    model: ?[]const u8,
    skill_name: ?[]const u8 = null,
    skill_args: ?[]const u8 = null,
    one_shot: bool,
    delete_after_run: bool,
    timeout_secs: ?u32,
    delivery: DeliveryConfig,
    session_target: SessionTarget,
};

/// Return true if a job with the given id exists in cron_jobs.
pub fn dbJobExists(db: *c.sqlite3, job_id: []const u8) !bool {
    const sql = "SELECT 1 FROM cron_jobs WHERE id=?1 LIMIT 1";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, job_id.ptr, @intCast(job_id.len), SQLITE_STATIC);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

/// Insert a job into cron_run_queue with 'pending' status.
pub fn dbEnqueueJob(db: *c.sqlite3, job_id: []const u8, enqueued_at: i64) !void {
    const sql = "INSERT INTO cron_run_queue (job_id, enqueued_at, status) VALUES (?1, ?2, 'pending')";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, job_id.ptr, @intCast(job_id.len), SQLITE_STATIC);
    _ = c.sqlite3_bind_int64(stmt, 2, enqueued_at);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
}

/// Scan cron_jobs for due jobs, INSERT them into cron_run_queue, and
/// UPDATE their next_run_secs. Returns the number of jobs enqueued.
/// Opens its own DB connection — safe to call from any thread.
pub fn dbTickAndEnqueue(db_path: [:0]const u8, allocator: std.mem.Allocator, now: i64) !usize {
    _ = allocator;
    const db = try openCronDbAtPath(db_path);
    defer _ = c.sqlite3_close(db);

    try ensureCronTable(db);

    // Enable WAL mode for concurrent access.
    _ = c.sqlite3_exec(db, "PRAGMA journal_mode=WAL", null, null, null);

    // Serialize tick against concurrent job deletion so queue inserts and
    // next_run updates are committed as one writer transaction.
    if (c.sqlite3_exec(db, "BEGIN IMMEDIATE", null, null, null) != c.SQLITE_OK) {
        return error.TransactionBeginFailed;
    }
    var tx_open = true;
    errdefer {
        if (tx_open) _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);
    }

    // SELECT jobs that are due and enabled.
    const select_sql =
        "SELECT id, expression, one_shot FROM cron_jobs " ++
        "WHERE enabled=1 AND paused=0 AND next_run_secs <= ?1";

    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, select_sql, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);

    rc = c.sqlite3_bind_int64(stmt, 1, now);
    if (rc != c.SQLITE_OK) return error.BindFailed;

    var enqueued: usize = 0;

    while (true) {
        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.StepFailed;

        const id_ptr = c.sqlite3_column_text(stmt, 0);
        const expr_ptr = c.sqlite3_column_text(stmt, 1);
        const one_shot_val = c.sqlite3_column_int(stmt, 2);

        if (id_ptr == null or expr_ptr == null) continue;

        const id_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        const id_str = id_ptr[0..id_len];
        const expr_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
        const expr_str = expr_ptr[0..expr_len];

        // INSERT into run queue.
        const ins_sql = "INSERT INTO cron_run_queue (job_id, enqueued_at, status) VALUES (?1, ?2, 'pending')";
        var ins_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, ins_sql, -1, &ins_stmt, null) == c.SQLITE_OK) {
            _ = c.sqlite3_bind_text(ins_stmt, 1, id_str.ptr, @intCast(id_str.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_int64(ins_stmt, 2, now);
            _ = c.sqlite3_step(ins_stmt);
            _ = c.sqlite3_finalize(ins_stmt);
            enqueued += 1;
        }

        // Update next_run_secs (or set to 0 for one-shot jobs so they don't re-fire).
        if (one_shot_val != 0) {
            const upd_sql = "UPDATE cron_jobs SET next_run_secs=0, paused=1 WHERE id=?1";
            var upd_stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(db, upd_sql, -1, &upd_stmt, null) == c.SQLITE_OK) {
                _ = c.sqlite3_bind_text(upd_stmt, 1, id_str.ptr, @intCast(id_str.len), SQLITE_STATIC);
                _ = c.sqlite3_step(upd_stmt);
                _ = c.sqlite3_finalize(upd_stmt);
            }
        } else {
            const next_run = nextRunForCronExpression(expr_str, now) catch now + 60;
            const upd_sql = "UPDATE cron_jobs SET next_run_secs=?1 WHERE id=?2";
            var upd_stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(db, upd_sql, -1, &upd_stmt, null) == c.SQLITE_OK) {
                _ = c.sqlite3_bind_int64(upd_stmt, 1, next_run);
                _ = c.sqlite3_bind_text(upd_stmt, 2, id_str.ptr, @intCast(id_str.len), SQLITE_STATIC);
                _ = c.sqlite3_step(upd_stmt);
                _ = c.sqlite3_finalize(upd_stmt);
            }
        }
    }

    if (c.sqlite3_exec(db, "COMMIT", null, null, null) != c.SQLITE_OK) {
        return error.TransactionCommitFailed;
    }
    tx_open = false;
    return enqueued;
}

/// Dequeue the next pending job from cron_run_queue, marking it in_progress.
/// Returns null if the queue is empty.
/// Caller owns the returned strings (duped into allocator).
pub fn dbDequeueNextJob(db: *c.sqlite3, allocator: std.mem.Allocator) !?struct { queue_row_id: i64, job_id: []const u8 } {
    _ = c.sqlite3_exec(db, "PRAGMA journal_mode=WAL", null, null, null);

    const sql =
        "SELECT id, job_id FROM cron_run_queue WHERE status='pending' " ++
        "ORDER BY enqueued_at ASC LIMIT 1";
    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, sql, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);

    rc = c.sqlite3_step(stmt);
    if (rc == c.SQLITE_DONE) return null;
    if (rc != c.SQLITE_ROW) return error.StepFailed;

    const queue_row_id = c.sqlite3_column_int64(stmt, 0);
    const job_id_ptr = c.sqlite3_column_text(stmt, 1);
    if (job_id_ptr == null) return null;

    const job_id_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
    const job_id = try allocator.dupe(u8, job_id_ptr[0..job_id_len]);
    errdefer allocator.free(job_id);

    // Mark as in_progress.
    const upd_sql = "UPDATE cron_run_queue SET status='in_progress', started_at=?1 WHERE id=?2";
    var upd_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, upd_sql, -1, &upd_stmt, null) == c.SQLITE_OK) {
        _ = c.sqlite3_bind_int64(upd_stmt, 1, std.time.timestamp());
        _ = c.sqlite3_bind_int64(upd_stmt, 2, queue_row_id);
        _ = c.sqlite3_step(upd_stmt);
        _ = c.sqlite3_finalize(upd_stmt);
    }

    return .{ .queue_row_id = queue_row_id, .job_id = job_id };
}

/// Load a job spec from cron_jobs by ID into arena-allocated memory.
/// Returns null if job not found.
pub fn dbLoadJobSpec(db: *c.sqlite3, arena: std.mem.Allocator, job_id: []const u8) !?CronJobSpec {
    const sql =
        "SELECT job_type, command, prompt, model, one_shot, delete_after_run, " ++
        "timeout_secs, delivery_mode, delivery_channel, delivery_account_id, delivery_to, " ++
        "delivery_best_effort, session_target, skill_name, skill_args " ++
        "FROM cron_jobs WHERE id=?1";
    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, sql, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);

    rc = c.sqlite3_bind_text(stmt, 1, job_id.ptr, @intCast(job_id.len), SQLITE_STATIC);
    if (rc != c.SQLITE_OK) return error.BindFailed;

    rc = c.sqlite3_step(stmt);
    if (rc == c.SQLITE_DONE) return null;
    if (rc != c.SQLITE_ROW) return error.StepFailed;

    const job_type_raw = try dbColumnTextOpt(stmt, 0, arena);
    const command_raw = try dbColumnTextOpt(stmt, 1, arena);
    const delivery_mode_raw = try dbColumnTextOpt(stmt, 7, arena);

    return CronJobSpec{
        .id = try arena.dupe(u8, job_id),
        .job_type = if (job_type_raw) |s| JobType.parse(s) else .shell,
        .command = command_raw orelse "",
        .prompt = try dbColumnTextOpt(stmt, 2, arena),
        .model = try dbColumnTextOpt(stmt, 3, arena),
        .one_shot = c.sqlite3_column_int(stmt, 4) != 0,
        .delete_after_run = c.sqlite3_column_int(stmt, 5) != 0,
        .timeout_secs = blk: {
            if (c.sqlite3_column_type(stmt, 6) == c.SQLITE_NULL) break :blk null;
            const v = c.sqlite3_column_int(stmt, 6);
            if (v <= 0) break :blk null;
            break :blk @intCast(v);
        },
        .delivery = .{
            .mode = if (delivery_mode_raw) |s| DeliveryMode.parse(s) else .none,
            .channel = try dbColumnTextOpt(stmt, 8, arena),
            .account_id = try dbColumnTextOpt(stmt, 9, arena),
            .to = try dbColumnTextOpt(stmt, 10, arena),
            .best_effort = c.sqlite3_column_int(stmt, 11) != 0,
            .channel_owned = false,
            .account_id_owned = false,
            .to_owned = false,
        },
        .session_target = blk: {
            const raw = try dbColumnTextOpt(stmt, 12, arena);
            break :blk if (raw) |s| SessionTarget.parse(s) else .isolated;
        },
        .skill_name = try dbColumnTextOpt(stmt, 13, arena),
        .skill_args = try dbColumnTextOpt(stmt, 14, arena),
    };
}

/// Write job completion back to cron_jobs and remove the run queue row.
pub fn dbCompleteJob(
    db: *c.sqlite3,
    job_id: []const u8,
    queue_row_id: i64,
    last_run_secs: i64,
    status: []const u8,
    last_output: ?[]const u8,
    delete_after_run: bool,
) !void {
    if (delete_after_run) {
        const del_sql = "DELETE FROM cron_jobs WHERE id=?1";
        var del_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, del_sql, -1, &del_stmt, null) == c.SQLITE_OK) {
            _ = c.sqlite3_bind_text(del_stmt, 1, job_id.ptr, @intCast(job_id.len), SQLITE_STATIC);
            _ = c.sqlite3_step(del_stmt);
            _ = c.sqlite3_finalize(del_stmt);
        }
    } else {
        const upd_sql =
            "UPDATE cron_jobs SET last_run_secs=?1, last_status=?2, last_output=?3 WHERE id=?4";
        var upd_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, upd_sql, -1, &upd_stmt, null) == c.SQLITE_OK) {
            _ = c.sqlite3_bind_int64(upd_stmt, 1, last_run_secs);
            _ = c.sqlite3_bind_text(upd_stmt, 2, status.ptr, @intCast(status.len), SQLITE_STATIC);
            if (last_output) |o| {
                _ = c.sqlite3_bind_text(upd_stmt, 3, o.ptr, @intCast(o.len), SQLITE_STATIC);
            } else {
                _ = c.sqlite3_bind_null(upd_stmt, 3);
            }
            _ = c.sqlite3_bind_text(upd_stmt, 4, job_id.ptr, @intCast(job_id.len), SQLITE_STATIC);
            _ = c.sqlite3_step(upd_stmt);
            _ = c.sqlite3_finalize(upd_stmt);
        }
    }

    // Remove the run queue row regardless.
    const del_q_sql = "DELETE FROM cron_run_queue WHERE id=?1";
    var del_q_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, del_q_sql, -1, &del_q_stmt, null) == c.SQLITE_OK) {
        _ = c.sqlite3_bind_int64(del_q_stmt, 1, queue_row_id);
        _ = c.sqlite3_step(del_q_stmt);
        _ = c.sqlite3_finalize(del_q_stmt);
    }
}

/// Reset any in_progress rows back to pending on worker startup (crash recovery).
pub fn dbResetInProgressJobs(db: *c.sqlite3) !void {
    const sql = "UPDATE cron_run_queue SET status='pending', started_at=NULL WHERE status='in_progress'";
    var err_msg: [*c]u8 = null;
    const rc = c.sqlite3_exec(db, sql, null, null, &err_msg);
    if (rc != c.SQLITE_OK) {
        if (err_msg) |msg| c.sqlite3_free(msg);
        return error.ResetInProgressFailed;
    }
}

/// JSON-escape a string and append it with surrounding quotes into buf.
/// Used by dbListJobsJson / dbGetJobOutputJson (mirrors appendJsonStringBuf in gateway.zig).
fn appendJsonStr(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try buf.append(alloc, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => try buf.append(alloc, ch),
        }
    }
    try buf.append(alloc, '"');
}

/// Query all rows from cron_jobs and write a JSON array into buf.
/// Column order in the SELECT matches the field order documented in the function body.
/// Caller owns the buf contents (allocated with allocator).
pub fn dbListJobsJson(db: *c.sqlite3, buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    // SELECT column indices:
    //  0  id
    //  1  expression
    //  2  command
    //  3  next_run_secs
    //  4  last_run_secs
    //  5  last_status
    //  6  last_output
    //  7  paused
    //  8  one_shot
    //  9  job_type
    // 10  enabled
    // 11  delete_after_run
    // 12  prompt
    // 13  model
    // 14  delivery_mode
    // 15  delivery_channel
    // 16  delivery_account_id
    // 17  delivery_to
    // 18  created_at_s
    // 19  timeout_secs
    // 20  delivery_best_effort
    // 21  skill_name
    // 22  skill_args
    const sql =
        "SELECT id, expression, command, next_run_secs, last_run_secs, last_status, " ++
        "last_output, paused, one_shot, job_type, enabled, delete_after_run, " ++
        "prompt, model, delivery_mode, delivery_channel, delivery_account_id, " ++
        "delivery_to, created_at_s, timeout_secs, delivery_best_effort, " ++
        "skill_name, skill_args " ++
        "FROM cron_jobs ORDER BY rowid ASC";

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);

    var int_buf: [32]u8 = undefined;
    var first = true;
    try buf.append(allocator, '[');

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.appendSlice(allocator, "{");

        // id (col 0) — TEXT NOT NULL
        try buf.appendSlice(allocator, "\"id\":");
        const id_ptr = c.sqlite3_column_text(stmt, 0);
        const id_len: usize = if (id_ptr != null) @intCast(c.sqlite3_column_bytes(stmt, 0)) else 0;
        try appendJsonStr(buf, allocator, if (id_ptr != null) id_ptr[0..id_len] else "");

        // expression (col 1) — TEXT NOT NULL
        try buf.appendSlice(allocator, ",\"expression\":");
        const expr_ptr = c.sqlite3_column_text(stmt, 1);
        const expr_len: usize = if (expr_ptr != null) @intCast(c.sqlite3_column_bytes(stmt, 1)) else 0;
        try appendJsonStr(buf, allocator, if (expr_ptr != null) expr_ptr[0..expr_len] else "");

        // command (col 2) — TEXT (may be null for agent jobs; fall back to "")
        try buf.appendSlice(allocator, ",\"command\":");
        const cmd_ptr = c.sqlite3_column_text(stmt, 2);
        const cmd_len: usize = if (cmd_ptr != null) @intCast(c.sqlite3_column_bytes(stmt, 2)) else 0;
        try appendJsonStr(buf, allocator, if (cmd_ptr != null) cmd_ptr[0..cmd_len] else "");

        // next_run_secs (col 3) — INTEGER NOT NULL
        try buf.appendSlice(allocator, ",\"next_run_secs\":");
        const next_run = c.sqlite3_column_int64(stmt, 3);
        try buf.appendSlice(allocator, std.fmt.bufPrint(&int_buf, "{d}", .{next_run}) catch "0");

        // last_run_secs (col 4) — INTEGER nullable
        try buf.appendSlice(allocator, ",\"last_run_secs\":");
        if (c.sqlite3_column_type(stmt, 4) == c.SQLITE_NULL) {
            try buf.appendSlice(allocator, "null");
        } else {
            const lrs = c.sqlite3_column_int64(stmt, 4);
            try buf.appendSlice(allocator, std.fmt.bufPrint(&int_buf, "{d}", .{lrs}) catch "0");
        }

        // last_status (col 5) — TEXT nullable
        try buf.appendSlice(allocator, ",\"last_status\":");
        const ls_ptr = c.sqlite3_column_text(stmt, 5);
        if (c.sqlite3_column_type(stmt, 5) == c.SQLITE_NULL or ls_ptr == null) {
            try buf.appendSlice(allocator, "null");
        } else {
            const ls_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 5));
            try appendJsonStr(buf, allocator, ls_ptr[0..ls_len]);
        }

        // last_output (col 6) — TEXT nullable
        try buf.appendSlice(allocator, ",\"last_output\":");
        const lo_ptr = c.sqlite3_column_text(stmt, 6);
        if (c.sqlite3_column_type(stmt, 6) == c.SQLITE_NULL or lo_ptr == null) {
            try buf.appendSlice(allocator, "null");
        } else {
            const lo_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 6));
            try appendJsonStr(buf, allocator, lo_ptr[0..lo_len]);
        }

        // paused (col 7) — INTEGER NOT NULL
        try buf.appendSlice(allocator, ",\"paused\":");
        try buf.appendSlice(allocator, if (c.sqlite3_column_int(stmt, 7) != 0) "true" else "false");

        // one_shot (col 8) — INTEGER NOT NULL
        try buf.appendSlice(allocator, ",\"one_shot\":");
        try buf.appendSlice(allocator, if (c.sqlite3_column_int(stmt, 8) != 0) "true" else "false");

        // job_type (col 9) — TEXT NOT NULL DEFAULT 'shell'
        try buf.appendSlice(allocator, ",\"job_type\":");
        const jt_ptr = c.sqlite3_column_text(stmt, 9);
        const jt_len: usize = if (jt_ptr != null) @intCast(c.sqlite3_column_bytes(stmt, 9)) else 0;
        try appendJsonStr(buf, allocator, if (jt_ptr != null) jt_ptr[0..jt_len] else "shell");

        // enabled (col 10) — INTEGER NOT NULL
        try buf.appendSlice(allocator, ",\"enabled\":");
        try buf.appendSlice(allocator, if (c.sqlite3_column_int(stmt, 10) != 0) "true" else "false");

        // delete_after_run (col 11) — INTEGER NOT NULL
        try buf.appendSlice(allocator, ",\"delete_after_run\":");
        try buf.appendSlice(allocator, if (c.sqlite3_column_int(stmt, 11) != 0) "true" else "false");

        // prompt (col 12) — TEXT nullable
        try buf.appendSlice(allocator, ",\"prompt\":");
        const prompt_ptr = c.sqlite3_column_text(stmt, 12);
        if (c.sqlite3_column_type(stmt, 12) == c.SQLITE_NULL or prompt_ptr == null) {
            try buf.appendSlice(allocator, "null");
        } else {
            const prompt_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 12));
            try appendJsonStr(buf, allocator, prompt_ptr[0..prompt_len]);
        }

        // model (col 13) — TEXT nullable
        try buf.appendSlice(allocator, ",\"model\":");
        const model_ptr = c.sqlite3_column_text(stmt, 13);
        if (c.sqlite3_column_type(stmt, 13) == c.SQLITE_NULL or model_ptr == null) {
            try buf.appendSlice(allocator, "null");
        } else {
            const model_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 13));
            try appendJsonStr(buf, allocator, model_ptr[0..model_len]);
        }

        // delivery_mode (col 14) — TEXT NOT NULL DEFAULT 'none'
        try buf.appendSlice(allocator, ",\"delivery_mode\":");
        const dm_ptr = c.sqlite3_column_text(stmt, 14);
        const dm_len: usize = if (dm_ptr != null) @intCast(c.sqlite3_column_bytes(stmt, 14)) else 0;
        try appendJsonStr(buf, allocator, if (dm_ptr != null) dm_ptr[0..dm_len] else "none");

        // delivery_channel (col 15) — TEXT nullable
        try buf.appendSlice(allocator, ",\"delivery_channel\":");
        const dc_ptr = c.sqlite3_column_text(stmt, 15);
        if (c.sqlite3_column_type(stmt, 15) == c.SQLITE_NULL or dc_ptr == null) {
            try buf.appendSlice(allocator, "null");
        } else {
            const dc_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 15));
            try appendJsonStr(buf, allocator, dc_ptr[0..dc_len]);
        }

        // delivery_account_id (col 16) — TEXT nullable
        try buf.appendSlice(allocator, ",\"delivery_account_id\":");
        const dai_ptr = c.sqlite3_column_text(stmt, 16);
        if (c.sqlite3_column_type(stmt, 16) == c.SQLITE_NULL or dai_ptr == null) {
            try buf.appendSlice(allocator, "null");
        } else {
            const dai_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 16));
            try appendJsonStr(buf, allocator, dai_ptr[0..dai_len]);
        }

        // delivery_to (col 17) — TEXT nullable
        try buf.appendSlice(allocator, ",\"delivery_to\":");
        const dt_ptr = c.sqlite3_column_text(stmt, 17);
        if (c.sqlite3_column_type(stmt, 17) == c.SQLITE_NULL or dt_ptr == null) {
            try buf.appendSlice(allocator, "null");
        } else {
            const dt_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 17));
            try appendJsonStr(buf, allocator, dt_ptr[0..dt_len]);
        }

        // delivery_best_effort (col 20) — INTEGER NOT NULL DEFAULT 0
        try buf.appendSlice(allocator, ",\"delivery_best_effort\":");
        try buf.appendSlice(allocator, if (c.sqlite3_column_int(stmt, 20) != 0) "true" else "false");

        // created_at_s (col 18) — INTEGER NOT NULL
        try buf.appendSlice(allocator, ",\"created_at_s\":");
        const cat = c.sqlite3_column_int64(stmt, 18);
        try buf.appendSlice(allocator, std.fmt.bufPrint(&int_buf, "{d}", .{cat}) catch "0");

        // timeout_secs (col 19) — INTEGER nullable
        try buf.appendSlice(allocator, ",\"timeout_secs\":");
        if (c.sqlite3_column_type(stmt, 19) == c.SQLITE_NULL) {
            try buf.appendSlice(allocator, "null");
        } else {
            const ts = c.sqlite3_column_int64(stmt, 19);
            try buf.appendSlice(allocator, std.fmt.bufPrint(&int_buf, "{d}", .{ts}) catch "null");
        }

        // skill_name (col 21) — TEXT nullable
        try buf.appendSlice(allocator, ",\"skill_name\":");
        const sn_ptr = c.sqlite3_column_text(stmt, 21);
        if (c.sqlite3_column_type(stmt, 21) == c.SQLITE_NULL or sn_ptr == null) {
            try buf.appendSlice(allocator, "null");
        } else {
            const sn_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 21));
            try appendJsonStr(buf, allocator, sn_ptr[0..sn_len]);
        }

        // skill_args (col 22) — TEXT nullable
        try buf.appendSlice(allocator, ",\"skill_args\":");
        const sa_ptr = c.sqlite3_column_text(stmt, 22);
        if (c.sqlite3_column_type(stmt, 22) == c.SQLITE_NULL or sa_ptr == null) {
            try buf.appendSlice(allocator, "null");
        } else {
            const sa_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 22));
            try appendJsonStr(buf, allocator, sa_ptr[0..sa_len]);
        }

        try buf.append(allocator, '}');
    }

    try buf.append(allocator, ']');
}

/// Query cron_jobs WHERE id=job_id and write a compact output JSON object into buf.
/// Returns true if the job was found, false if not found.
pub fn dbGetJobOutputJson(db: *c.sqlite3, job_id: []const u8, buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !bool {
    const sql =
        "SELECT id, last_output, last_run_secs, last_status " ++
        "FROM cron_jobs WHERE id=?1 LIMIT 1";

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, job_id.ptr, @intCast(job_id.len), SQLITE_STATIC);

    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return false;

    var int_buf: [32]u8 = undefined;
    try buf.appendSlice(allocator, "{\"id\":");

    // id (col 0)
    const id_ptr = c.sqlite3_column_text(stmt, 0);
    const id_len: usize = if (id_ptr != null) @intCast(c.sqlite3_column_bytes(stmt, 0)) else 0;
    try appendJsonStr(buf, allocator, if (id_ptr != null) id_ptr[0..id_len] else "");

    // last_output (col 1) — TEXT nullable
    try buf.appendSlice(allocator, ",\"last_output\":");
    const lo_ptr = c.sqlite3_column_text(stmt, 1);
    if (c.sqlite3_column_type(stmt, 1) == c.SQLITE_NULL or lo_ptr == null) {
        try buf.appendSlice(allocator, "null");
    } else {
        const lo_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
        try appendJsonStr(buf, allocator, lo_ptr[0..lo_len]);
    }

    // last_run_secs (col 2) — INTEGER nullable
    try buf.appendSlice(allocator, ",\"last_run_secs\":");
    if (c.sqlite3_column_type(stmt, 2) == c.SQLITE_NULL) {
        try buf.appendSlice(allocator, "null");
    } else {
        const lrs = c.sqlite3_column_int64(stmt, 2);
        try buf.appendSlice(allocator, std.fmt.bufPrint(&int_buf, "{d}", .{lrs}) catch "0");
    }

    // last_status (col 3) — TEXT nullable
    try buf.appendSlice(allocator, ",\"last_status\":");
    const ls_ptr = c.sqlite3_column_text(stmt, 3);
    if (c.sqlite3_column_type(stmt, 3) == c.SQLITE_NULL or ls_ptr == null) {
        try buf.appendSlice(allocator, "null");
    } else {
        const ls_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 3));
        try appendJsonStr(buf, allocator, ls_ptr[0..ls_len]);
    }

    try buf.append(allocator, '}');
    return true;
}

// ── Tests ────────────────────────────────────────────────────────────

test "parseDuration minutes" {
    try std.testing.expectEqual(@as(i64, 1800), try parseDuration("30m"));
}

test "parseDuration hours" {
    try std.testing.expectEqual(@as(i64, 7200), try parseDuration("2h"));
}

test "parseDuration days" {
    try std.testing.expectEqual(@as(i64, 86400), try parseDuration("1d"));
}

test "parseDuration weeks" {
    try std.testing.expectEqual(@as(i64, 604800), try parseDuration("1w"));
}

test "formatUnixTimestamp formats known UTC timestamp" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Mon Mar 02 2026 14:00:00 UTC",
        formatUnixTimestamp(1772460000, &buf),
    );
}

test "formatUnixTimestamp formats unix epoch" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Thu Jan 01 1970 00:00:00 UTC",
        formatUnixTimestamp(0, &buf),
    );
}

test "formatUnixTimestamp rejects negative timestamp" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("invalid timestamp", formatUnixTimestamp(-1, &buf));
}

test "formatUnixTimestamp accepts exact-size buffer" {
    var buf: [28]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Thu Jan 01 1970 00:00:00 UTC",
        formatUnixTimestamp(0, &buf),
    );
}

test "formatUnixTimestamp rejects undersized buffer" {
    var buf: [27]u8 = undefined;
    try std.testing.expectEqualStrings("buffer too small", formatUnixTimestamp(0, &buf));
}

test "parseDuration seconds" {
    try std.testing.expectEqual(@as(i64, 30), try parseDuration("30s"));
}

test "parseDuration default unit is minutes" {
    try std.testing.expectEqual(@as(i64, 300), try parseDuration("5"));
}

test "parseDuration empty returns error" {
    try std.testing.expectError(error.EmptyDelay, parseDuration(""));
}

test "parseDuration unknown unit" {
    try std.testing.expectError(error.UnknownDurationUnit, parseDuration("5x"));
}

test "normalizeExpression 5 fields" {
    const result = try normalizeExpression("*/5 * * * *");
    try std.testing.expect(result.needs_second_prefix);
}

test "normalizeExpression 6 fields" {
    const result = try normalizeExpression("0 */5 * * * *");
    try std.testing.expect(!result.needs_second_prefix);
}

test "normalizeExpression 4 fields invalid" {
    try std.testing.expectError(error.InvalidCronExpression, normalizeExpression("* * * *"));
}

test "nextRunForCronExpression supports step minutes" {
    try std.testing.expectEqual(@as(i64, 300), try nextRunForCronExpression("*/5 * * * *", 0));
}

test "nextRunForCronExpression supports anchored step minutes" {
    try std.testing.expectEqual(@as(i64, 480), try nextRunForCronExpression("8/25 * * * *", 0));
    try std.testing.expectEqual(@as(i64, 1980), try nextRunForCronExpression("8/25 * * * *", 480));
    try std.testing.expectEqual(@as(i64, 3480), try nextRunForCronExpression("8/25 * * * *", 1980));
    try std.testing.expectEqual(@as(i64, 4080), try nextRunForCronExpression("8/25 * * * *", 3480));
}

test "nextRunForCronExpression supports hourly schedule" {
    try std.testing.expectEqual(@as(i64, 3600), try nextRunForCronExpression("0 * * * *", 0));
}

test "nextRunForCronExpression supports fixed time schedule" {
    try std.testing.expectEqual(@as(i64, 9000), try nextRunForCronExpression("30 2 * * *", 0));
}

test "nextRunForCronExpression supports sunday aliases 0 and 7" {
    const next_sun_zero = try nextRunForCronExpression("0 0 * * 0", 0);
    const next_sun_seven = try nextRunForCronExpression("0 0 * * 7", 0);
    try std.testing.expectEqual(next_sun_zero, next_sun_seven);
}

test "nextRunForCronExpression handles leap-day schedules beyond one year" {
    try std.testing.expectEqual(@as(i64, 68169600), try nextRunForCronExpression("0 0 29 2 *", 0));
}

test "CronScheduler add and list" {
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();

    const job = try scheduler.addJob("*/10 * * * *", "echo roundtrip");
    try std.testing.expectEqualStrings("*/10 * * * *", job.expression);
    try std.testing.expectEqualStrings("echo roundtrip", job.command);
    try std.testing.expect(!job.one_shot);
    try std.testing.expect(!job.paused);

    const listed = scheduler.listJobs();
    try std.testing.expectEqual(@as(usize, 1), listed.len);
}

test "CronScheduler addOnce creates one-shot" {
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();

    const job = try scheduler.addOnce("30m", "echo once");
    try std.testing.expect(job.one_shot);
}

test "CronScheduler remove" {
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();

    const job = try scheduler.addJob("*/10 * * * *", "echo test");
    try std.testing.expect(scheduler.removeJob(job.id));
    try std.testing.expectEqual(@as(usize, 0), scheduler.listJobs().len);
}

test "CronScheduler generated IDs stay unique after removals" {
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();

    const j1 = try scheduler.addJob("*/10 * * * *", "echo first");
    const j1_id = try std.testing.allocator.dupe(u8, j1.id);
    defer std.testing.allocator.free(j1_id);
    const j2 = try scheduler.addJob("*/10 * * * *", "echo second");
    const j2_id = try std.testing.allocator.dupe(u8, j2.id);
    defer std.testing.allocator.free(j2_id);
    const j3 = try scheduler.addJob("*/10 * * * *", "echo third");
    const j3_id = try std.testing.allocator.dupe(u8, j3.id);
    defer std.testing.allocator.free(j3_id);

    try std.testing.expect(scheduler.removeJob(j2_id));

    const j4 = try scheduler.addJob("*/10 * * * *", "echo fourth");
    try std.testing.expect(!std.mem.eql(u8, j4.id, j1_id));
    try std.testing.expect(!std.mem.eql(u8, j4.id, j3_id));
}

test "CronScheduler pause and resume" {
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();

    const job = try scheduler.addJob("*/5 * * * *", "echo pause");
    try std.testing.expect(scheduler.pauseJob(job.id));
    try std.testing.expect(scheduler.getJob(job.id).?.paused);
    try std.testing.expect(scheduler.resumeJob(job.id));
    try std.testing.expect(!scheduler.getJob(job.id).?.paused);
}

test "CronScheduler max tasks enforced" {
    var scheduler = CronScheduler.init(std.testing.allocator, 1, true);
    defer scheduler.deinit();

    _ = try scheduler.addJob("*/10 * * * *", "echo first");
    try std.testing.expectError(error.MaxTasksReached, scheduler.addJob("*/11 * * * *", "echo second"));
}

test "CronScheduler getJob found and missing" {
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();

    const job = try scheduler.addJob("*/5 * * * *", "echo found");
    try std.testing.expect(scheduler.getJob(job.id) != null);
    try std.testing.expect(scheduler.getJob("nonexistent") == null);
}

test "db upsert and load roundtrip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);
    const db_path = try std.fs.path.joinZ(std.testing.allocator, &.{ tmp_path, "cron_test.db" });
    defer std.testing.allocator.free(db_path);

    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    scheduler.db_path = db_path;
    defer scheduler.deinit();

    const recurring_id = blk: {
        const j = try scheduler.addJob("*/10 * * * *", "echo roundtrip");
        break :blk try std.testing.allocator.dupe(u8, j.id);
    };
    defer std.testing.allocator.free(recurring_id);

    if (scheduler.getMutableJob(recurring_id)) |job| {
        job.last_run_secs = 1_772_455_140;
        job.last_status = "ok";
    } else return error.TestUnexpectedResult;

    const oneshot_id = blk: {
        const j = try scheduler.addOnce("5m", "echo oneshot");
        break :blk try std.testing.allocator.dupe(u8, j.id);
    };
    defer std.testing.allocator.free(oneshot_id);

    // Use the public API — same path as production CRUD.
    try dbUpsertAndVerify(&scheduler, scheduler.getJob(recurring_id).?);
    try dbUpsertAndVerify(&scheduler, scheduler.getJob(oneshot_id).?);

    // Load via a second scheduler pointed at the same isolated DB.
    var loaded = CronScheduler.init(std.testing.allocator, 10, true);
    loaded.db_path = db_path;
    defer loaded.deinit();
    try loadJobsFromDb(&loaded);

    try std.testing.expectEqual(@as(usize, 2), loaded.listJobs().len);
    const jobs = loaded.listJobs();
    try std.testing.expectEqualStrings("*/10 * * * *", jobs[0].expression);
    try std.testing.expectEqualStrings("echo roundtrip", jobs[0].command);
    try std.testing.expectEqual(@as(?i64, 1_772_455_140), jobs[0].last_run_secs);
    try std.testing.expect(jobs[0].last_status != null);
    try std.testing.expectEqualStrings("ok", jobs[0].last_status.?);
    try std.testing.expect(jobs[1].one_shot);
}

test "load agent job without command field falls back to prompt" {
    // Seed an isolated DB with an agent job that has NULL command but a prompt.
    // loadJobsStrict must populate command from the prompt field.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);
    const db_path = try std.fs.path.joinZ(std.testing.allocator, &.{ tmp_path, "cron_test.db" });
    defer std.testing.allocator.free(db_path);

    if (build_options.enable_sqlite) {
        // Open DB and create table, then insert a row with NULL command directly.
        var seed = CronScheduler.init(std.testing.allocator, 10, true);
        seed.db_path = db_path;
        defer seed.deinit();
        const db = try openCronDbForScheduler(&seed);
        defer _ = c.sqlite3_close(db);
        try ensureCronTable(db);
        const insert_sql = "INSERT INTO cron_jobs (id, expression, job_type, command, prompt, next_run_secs, enabled, delivery_mode) " ++
            "VALUES ('ag-1', '0 7 * * 1-5', 'agent', NULL, 'Check traffic', 0, 1, 'none')";
        _ = c.sqlite3_exec(db, insert_sql, null, null, null);

        var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
        scheduler.db_path = db_path;
        defer scheduler.deinit();
        try loadJobsStrict(&scheduler);

        const jobs = scheduler.listJobs();
        try std.testing.expectEqual(@as(usize, 1), jobs.len);
        try std.testing.expectEqualStrings("Check traffic", jobs[0].command);
        try std.testing.expectEqualStrings("Check traffic", jobs[0].prompt.?);
    } else {
        // JSON path: absent command field → prompt used as command
        const json =
            \\[{"id":"ag-1","expression":"0 7 * * 1-5","job_type":"agent","prompt":"Check traffic","paused":false,"one_shot":false,"enabled":true,"delete_after_run":false,"delivery_mode":"none"}]
        ;
        const path = try cronJsonPath(std.testing.allocator);
        defer std.testing.allocator.free(path);
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(json);

        var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
        defer scheduler.deinit();
        try loadJobsStrict(&scheduler);

        const jobs = scheduler.listJobs();
        try std.testing.expectEqual(@as(usize, 1), jobs.len);
        try std.testing.expectEqualStrings("Check traffic", jobs[0].command);
        try std.testing.expectEqualStrings("Check traffic", jobs[0].prompt.?);
    }
}

test "load agent job without prompt field falls back to command" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);
    const db_path = try std.fs.path.joinZ(std.testing.allocator, &.{ tmp_path, "cron_test.db" });
    defer std.testing.allocator.free(db_path);

    if (build_options.enable_sqlite) {
        // Seed isolated DB with an agent job that has command but no prompt.
        var seed = CronScheduler.init(std.testing.allocator, 10, true);
        seed.db_path = db_path;
        defer seed.deinit();
        const j = try seed.addJob("15 9 * * 2", "Summarize incidents");
        const jid = try std.testing.allocator.dupe(u8, j.id);
        defer std.testing.allocator.free(jid);
        if (seed.getMutableJob(jid)) |mj| mj.job_type = .agent;
        try dbUpsertAndVerify(&seed, seed.getJob(jid).?);

        var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
        scheduler.db_path = db_path;
        defer scheduler.deinit();
        try loadJobsStrict(&scheduler);

        // When only command is stored (no prompt column), command is preserved as-is.
        // The loader does not synthesize prompt from command; that direction is absent.
        const jobs = scheduler.listJobs();
        try std.testing.expectEqual(@as(usize, 1), jobs.len);
        try std.testing.expectEqualStrings("Summarize incidents", jobs[0].command);
    } else {
        // JSON path: command present, prompt absent field → prompt stays null after load.
        const json =
            \\[{"id":"ag-2","expression":"15 9 * * 2","job_type":"agent","command":"Summarize incidents","model":"openrouter/anthropic/claude-sonnet-4","paused":false,"one_shot":false,"enabled":true,"delete_after_run":false,"delivery_mode":"none"}]
        ;
        const path = try cronJsonPath(std.testing.allocator);
        defer std.testing.allocator.free(path);
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(json);

        var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
        defer scheduler.deinit();
        try loadJobsStrict(&scheduler);

        const jobs = scheduler.listJobs();
        try std.testing.expectEqual(@as(usize, 1), jobs.len);
        try std.testing.expectEqualStrings("Summarize incidents", jobs[0].command);
    }
}

test "trimOwnedRight duplicates trimmed allocation" {
    const raw = try std.testing.allocator.dupe(u8, "zc_token\n");
    const trimmed = trimOwnedRight(std.testing.allocator, raw) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(trimmed);

    try std.testing.expectEqualStrings("zc_token", trimmed);
}

test "save and load roundtrip keeps delivery account routing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);
    const db_path = try std.fs.path.joinZ(std.testing.allocator, &.{ tmp_path, "cron_test.db" });
    defer std.testing.allocator.free(db_path);

    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    scheduler.db_path = db_path;
    defer scheduler.deinit();

    const job_id = blk: {
        const j = try scheduler.addJob("*/10 * * * *", "echo routed");
        break :blk try std.testing.allocator.dupe(u8, j.id);
    };
    defer std.testing.allocator.free(job_id);

    if (scheduler.getMutableJob(job_id)) |mutable_job| {
        mutable_job.delivery = .{
            .mode = .always,
            .channel = try std.testing.allocator.dupe(u8, "telegram"),
            .account_id = try std.testing.allocator.dupe(u8, "backup"),
            .to = try std.testing.allocator.dupe(u8, "chat-42"),
            .channel_owned = true,
            .account_id_owned = true,
            .to_owned = true,
        };
    } else return error.TestUnexpectedResult;

    try dbUpsertAndVerify(&scheduler, scheduler.getJob(job_id).?);

    var loaded2 = CronScheduler.init(std.testing.allocator, 10, true);
    loaded2.db_path = db_path;
    defer loaded2.deinit();
    try loadJobsFromDb(&loaded2);

    try std.testing.expectEqual(@as(usize, 1), loaded2.listJobs().len);
    const loaded_job = loaded2.listJobs()[0];
    try std.testing.expectEqual(DeliveryMode.always, loaded_job.delivery.mode);
    try std.testing.expect(loaded_job.delivery.channel != null);
    try std.testing.expectEqualStrings("telegram", loaded_job.delivery.channel.?);
    try std.testing.expect(loaded_job.delivery.account_id != null);
    try std.testing.expectEqualStrings("backup", loaded_job.delivery.account_id.?);
    try std.testing.expect(loaded_job.delivery.to != null);
    try std.testing.expectEqualStrings("chat-42", loaded_job.delivery.to.?);
}

test "cliRunJob persists last status and timestamp" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);
    const db_path = try std.fs.path.joinZ(std.testing.allocator, &.{ tmp_path, "cron_test.db" });
    defer std.testing.allocator.free(db_path);

    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    scheduler.db_path = db_path;
    defer scheduler.deinit();

    const job = try scheduler.addJob("* * * * *", "echo cli_run_status");
    const job_id = try std.testing.allocator.dupe(u8, job.id);
    defer std.testing.allocator.free(job_id);

    // Write via public API.
    try dbUpsertAndVerify(&scheduler, scheduler.getJob(job_id).?);

    // Simulate completing the run: update status fields and upsert.
    if (scheduler.getMutableJob(job_id)) |mutable| {
        mutable.last_run_secs = std.time.timestamp();
        mutable.last_status = "ok";
        try dbUpsertAndVerify(&scheduler, mutable);
    }

    // Read back via a second scheduler on the same isolated DB and verify.
    var loaded = CronScheduler.init(std.testing.allocator, 10, true);
    loaded.db_path = db_path;
    defer loaded.deinit();
    try loadJobsFromDb(&loaded);

    const loaded_job = loaded.getJob(job_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(loaded_job.last_run_secs != null);
    try std.testing.expect(loaded_job.last_status != null);
    try std.testing.expectEqualStrings("ok", loaded_job.last_status.?);
}

test "resolveRunnableCwd keeps valid cwd" {
    const resolved = resolveRunnableCwd(".");
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualStrings(".", resolved.?);
}

test "resolveRunnableCwd returns null for missing cwd" {
    const resolved = resolveRunnableCwd("__nullclaw_missing_cwd_for_cron_tests__/subdir");
    try std.testing.expect(resolved == null);
}

test "reloadJobs auto-recovers malformed store and keeps runtime jobs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = tmp.dir.realpathAlloc(std.testing.allocator, ".") catch return;
    defer std.testing.allocator.free(base);
    const db_path = try std.fs.path.joinZ(std.testing.allocator, &.{ base, "reload_recover.db" });
    defer std.testing.allocator.free(db_path);

    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();
    scheduler.db_path = db_path;
    _ = try scheduler.addJob("*/10 * * * *", "echo keep");
    try saveJobs(&scheduler);

    var runtime = CronScheduler.init(std.testing.allocator, 10, true);
    defer runtime.deinit();
    runtime.db_path = db_path;
    try loadJobs(&runtime);
    try std.testing.expectEqual(@as(usize, 1), runtime.listJobs().len);

    const path = try cronJsonPath(std.testing.allocator);
    defer std.testing.allocator.free(path);
    const bad_file = try std.fs.createFileAbsolute(path, .{});
    defer bad_file.close();
    try bad_file.writeAll("{bad-json");

    try reloadJobs(&runtime);
    try std.testing.expectEqual(@as(usize, 1), runtime.listJobs().len);

    // Store should be healed and parseable again.
    var healed = CronScheduler.init(std.testing.allocator, 10, true);
    defer healed.deinit();
    healed.db_path = db_path;
    try loadJobsStrict(&healed);
    try std.testing.expectEqual(@as(usize, 1), healed.listJobs().len);
}

test "db upsert and load roundtrip with special command characters" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);
    const db_path = try std.fs.path.joinZ(std.testing.allocator, &.{ tmp_path, "cron_test.db" });
    defer std.testing.allocator.free(db_path);

    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    scheduler.db_path = db_path;
    defer scheduler.deinit();

    const cmd = "printf \"line1\\nline2\" && echo \\\"ok\\\"";
    const job_id2 = blk: {
        const j = try scheduler.addJob("*/5 * * * *", cmd);
        break :blk try std.testing.allocator.dupe(u8, j.id);
    };
    defer std.testing.allocator.free(job_id2);

    try dbUpsertAndVerify(&scheduler, scheduler.getJob(job_id2).?);

    var loaded = CronScheduler.init(std.testing.allocator, 10, true);
    loaded.db_path = db_path;
    defer loaded.deinit();
    try loadJobsFromDb(&loaded);
    try std.testing.expectEqual(@as(usize, 1), loaded.listJobs().len);
    try std.testing.expectEqualStrings(cmd, loaded.listJobs()[0].command);
}

test "db upsert and load roundtrip keeps agent fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);
    const db_path = try std.fs.path.joinZ(std.testing.allocator, &.{ tmp_path, "cron_test.db" });
    defer std.testing.allocator.free(db_path);

    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    scheduler.db_path = db_path;
    defer scheduler.deinit();

    const agent_job_id = blk: {
        const j = try scheduler.addAgentJob("*/15 * * * *", "Summarize release status", "openrouter/anthropic/claude-sonnet-4", .{
            .mode = .always,
            .channel = "telegram",
            .account_id = "backup",
            .to = "chat-42",
        });
        break :blk try std.testing.allocator.dupe(u8, j.id);
    };
    defer std.testing.allocator.free(agent_job_id);
    try dbUpsertAndVerify(&scheduler, scheduler.getJob(agent_job_id).?);

    var loaded = CronScheduler.init(std.testing.allocator, 10, true);
    loaded.db_path = db_path;
    defer loaded.deinit();
    try loadJobsFromDb(&loaded);

    try std.testing.expectEqual(@as(usize, 1), loaded.listJobs().len);
    const loaded_job = loaded.listJobs()[0];
    try std.testing.expectEqual(JobType.agent, loaded_job.job_type);
    try std.testing.expect(loaded_job.prompt != null);
    try std.testing.expectEqualStrings("Summarize release status", loaded_job.prompt.?);
    try std.testing.expect(loaded_job.model != null);
    try std.testing.expectEqualStrings("openrouter/anthropic/claude-sonnet-4", loaded_job.model.?);
    try std.testing.expectEqual(DeliveryMode.always, loaded_job.delivery.mode);
    try std.testing.expect(loaded_job.delivery.channel != null);
    try std.testing.expectEqualStrings("telegram", loaded_job.delivery.channel.?);
    try std.testing.expect(loaded_job.delivery.account_id != null);
    try std.testing.expectEqualStrings("backup", loaded_job.delivery.account_id.?);
    try std.testing.expect(loaded_job.delivery.to != null);
    try std.testing.expectEqualStrings("chat-42", loaded_job.delivery.to.?);
}

test "JobType parse and asStr" {
    try std.testing.expectEqual(JobType.shell, JobType.parse("shell"));
    try std.testing.expectEqual(JobType.agent, JobType.parse("agent"));
    try std.testing.expectEqual(JobType.agent, JobType.parse("AGENT"));
    try std.testing.expectEqualStrings("shell", JobType.shell.asStr());
    try std.testing.expectEqualStrings("agent", JobType.agent.asStr());
}

test "SessionTarget parse and asStr" {
    try std.testing.expectEqual(SessionTarget.isolated, SessionTarget.parse("isolated"));
    try std.testing.expectEqual(SessionTarget.main, SessionTarget.parse("main"));
    try std.testing.expectEqual(SessionTarget.main, SessionTarget.parse("MAIN"));
    try std.testing.expectEqualStrings("isolated", SessionTarget.isolated.asStr());
    try std.testing.expectEqualStrings("main", SessionTarget.main.asStr());
}

test "CronJob has new fields" {
    const job = CronJob{
        .id = "test",
        .expression = "* * * * *",
        .command = "echo hi",
        .job_type = .agent,
        .session_target = .main,
        .enabled = true,
        .delete_after_run = false,
        .created_at_s = 1000000,
    };
    try std.testing.expectEqual(JobType.agent, job.job_type);
    try std.testing.expectEqual(SessionTarget.main, job.session_target);
    try std.testing.expect(job.enabled);
    try std.testing.expectEqual(@as(i64, 1000000), job.created_at_s);
}

test "getMutableJob returns mutable pointer" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();
    _ = try scheduler.addJob("* * * * *", "echo test");
    const jobs = scheduler.listJobs();
    const id = jobs[0].id;
    const job = scheduler.getMutableJob(id);
    try std.testing.expect(job != null);
    try std.testing.expectEqualStrings(id, job.?.id);
}

test "updateJob modifies job fields" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();
    _ = try scheduler.addJob("* * * * *", "echo original");
    const jobs = scheduler.listJobs();
    const id = jobs[0].id;
    const patch = CronJobPatch{ .command = "echo updated", .enabled = false };
    try std.testing.expect(scheduler.updateJob(allocator, id, patch));
    const updated = scheduler.getJob(id).?;
    try std.testing.expectEqualStrings("echo updated", updated.command);
    try std.testing.expect(!updated.enabled);
    try std.testing.expect(updated.paused);
}

test "updateJob keeps agent command and prompt in sync" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();

    _ = try scheduler.addAgentJob("* * * * *", "old prompt", "model-a", .{});
    const id = scheduler.listJobs()[0].id;

    // Back-compat: updating command should update agent prompt.
    try std.testing.expect(scheduler.updateJob(allocator, id, .{ .command = "new command prompt" }));
    var updated = scheduler.getJob(id).?;
    try std.testing.expect(updated.prompt != null);
    try std.testing.expectEqualStrings("new command prompt", updated.command);
    try std.testing.expectEqualStrings("new command prompt", updated.prompt.?);

    // Explicit prompt/model update should persist both.
    try std.testing.expect(scheduler.updateJob(allocator, id, .{
        .prompt = "explicit prompt",
        .model = "model-b",
    }));
    updated = scheduler.getJob(id).?;
    try std.testing.expect(updated.prompt != null);
    try std.testing.expectEqualStrings("explicit prompt", updated.command);
    try std.testing.expectEqualStrings("explicit prompt", updated.prompt.?);
    try std.testing.expect(updated.model != null);
    try std.testing.expectEqualStrings("model-b", updated.model.?);
}

test "CronScheduler remove frees agent job fields" {
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();

    const job = try scheduler.addAgentJob("* * * * *", "prompt to free", "model-to-free", .{});
    try std.testing.expect(scheduler.removeJob(job.id));
    try std.testing.expectEqual(@as(usize, 0), scheduler.listJobs().len);
}

test "getMutableJob returns null for unknown id" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();
    try std.testing.expect(scheduler.getMutableJob("nonexistent") == null);
}

test "addRun and listRuns" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();
    _ = try scheduler.addJob("* * * * *", "echo test");
    const jobs = scheduler.listJobs();
    const id = jobs[0].id;
    try scheduler.addRun(allocator, id, 1000, 1001, "success", "output", 10);
    try scheduler.addRun(allocator, id, 1001, 1002, "error", null, 10);
    const runs = try scheduler.listRuns(allocator, id, 10);
    defer allocator.free(runs);
    try std.testing.expect(runs.len > 0);
}

test "addRun prunes history" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();
    _ = try scheduler.addJob("* * * * *", "echo test");
    const jobs = scheduler.listJobs();
    const id = jobs[0].id;
    // Add 5 runs with max_history=3
    var i: i64 = 0;
    while (i < 5) : (i += 1) {
        try scheduler.addRun(allocator, id, i, i + 1, "success", null, 3);
    }
    const runs = try scheduler.listRuns(allocator, id, 100);
    defer allocator.free(runs);
    try std.testing.expect(runs.len <= 3);
}

test "listRuns returns only matching job runs when interleaved" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();

    _ = try scheduler.addJob("* * * * *", "echo a");
    _ = try scheduler.addJob("* * * * *", "echo b");

    const job_a_id = try allocator.dupe(u8, scheduler.listJobs()[0].id);
    defer allocator.free(job_a_id);
    const job_b_id = try allocator.dupe(u8, scheduler.listJobs()[1].id);
    defer allocator.free(job_b_id);

    try scheduler.addRun(allocator, job_a_id, 1000, 1001, "ok", null, 10);
    try scheduler.addRun(allocator, job_b_id, 1001, 1002, "ok", null, 10);
    try scheduler.addRun(allocator, job_a_id, 1002, 1003, "ok", null, 10);
    try scheduler.addRun(allocator, job_b_id, 1003, 1004, "ok", null, 10);

    const runs_a = try scheduler.listRuns(allocator, job_a_id, 10);
    defer allocator.free(runs_a);
    try std.testing.expectEqual(@as(usize, 2), runs_a.len);
    for (runs_a) |run| {
        try std.testing.expectEqualStrings(job_a_id, run.job_id);
    }
}

test "tick removes more than 64 one-shot jobs in one pass" {
    var scheduler = CronScheduler.init(std.testing.allocator, 128, true);
    defer scheduler.deinit();

    var i: usize = 0;
    while (i < 80) : (i += 1) {
        _ = try scheduler.addAgentOnce("1s", "noop prompt", null);
    }

    const now = std.time.timestamp();
    _ = scheduler.tick(now + 2, null);
    try std.testing.expectEqual(@as(usize, 0), scheduler.listJobs().len);
}

// ── Delivery + Bus integration tests ────────────────────────────

test "deliverResult creates correct OutboundMessage" {
    const allocator = std.testing.allocator;
    var test_bus = bus.Bus.init();
    defer test_bus.close();

    const delivery = DeliveryConfig{
        .mode = .always,
        .channel = "telegram",
        .to = "chat123",
    };

    const delivered = try deliverResult(allocator, delivery, "job output here", true, &test_bus);
    try std.testing.expect(delivered);

    // Consume and verify the message
    var msg = test_bus.consumeOutbound().?;
    defer msg.deinit(allocator);
    try std.testing.expectEqualStrings("telegram", msg.channel);
    try std.testing.expectEqualStrings("chat123", msg.chat_id);
    try std.testing.expectEqualStrings("job output here", msg.content);
}

test "deliverResult preserves account routing when delivery account_id is set" {
    const allocator = std.testing.allocator;
    var test_bus = bus.Bus.init();
    defer test_bus.close();

    const delivery = DeliveryConfig{
        .mode = .always,
        .channel = "telegram",
        .account_id = "backup",
        .to = "chat123",
    };

    const delivered = try deliverResult(allocator, delivery, "job output here", true, &test_bus);
    try std.testing.expect(delivered);

    var msg = test_bus.consumeOutbound().?;
    defer msg.deinit(allocator);
    try std.testing.expect(msg.account_id != null);
    try std.testing.expectEqualStrings("backup", msg.account_id.?);
}

test "deliverResult with mode none does nothing" {
    const allocator = std.testing.allocator;
    var test_bus = bus.Bus.init();
    defer test_bus.close();

    const delivery = DeliveryConfig{
        .mode = .none,
        .channel = "telegram",
        .to = "chat1",
    };

    const delivered = try deliverResult(allocator, delivery, "should not appear", true, &test_bus);
    try std.testing.expect(!delivered);
    try std.testing.expectEqual(@as(usize, 0), test_bus.outboundDepth());
}

test "deliverResult with no channel does nothing" {
    const allocator = std.testing.allocator;
    var test_bus = bus.Bus.init();
    defer test_bus.close();

    const delivery = DeliveryConfig{
        .mode = .always,
        .channel = null,
        .to = "chat1",
    };

    const delivered = try deliverResult(allocator, delivery, "should not appear", true, &test_bus);
    try std.testing.expect(!delivered);
    try std.testing.expectEqual(@as(usize, 0), test_bus.outboundDepth());
}

test "deliverResult on_success skips on failure" {
    const allocator = std.testing.allocator;
    var test_bus = bus.Bus.init();
    defer test_bus.close();

    const delivery = DeliveryConfig{
        .mode = .on_success,
        .channel = "telegram",
        .to = "chat1",
    };

    const delivered = try deliverResult(allocator, delivery, "error output", false, &test_bus);
    try std.testing.expect(!delivered);
    try std.testing.expectEqual(@as(usize, 0), test_bus.outboundDepth());
}

test "deliverResult on_error skips on success" {
    const allocator = std.testing.allocator;
    var test_bus = bus.Bus.init();
    defer test_bus.close();

    const delivery = DeliveryConfig{
        .mode = .on_error,
        .channel = "telegram",
        .to = "chat1",
    };

    const delivered = try deliverResult(allocator, delivery, "ok output", true, &test_bus);
    try std.testing.expect(!delivered);
    try std.testing.expectEqual(@as(usize, 0), test_bus.outboundDepth());
}

test "deliverResult on_error delivers on failure" {
    const allocator = std.testing.allocator;
    var test_bus = bus.Bus.init();
    defer test_bus.close();

    const delivery = DeliveryConfig{
        .mode = .on_error,
        .channel = "discord",
        .to = "room42",
    };

    const delivered = try deliverResult(allocator, delivery, "crash log", false, &test_bus);
    try std.testing.expect(delivered);

    var msg = test_bus.consumeOutbound().?;
    defer msg.deinit(allocator);
    try std.testing.expectEqualStrings("discord", msg.channel);
    try std.testing.expectEqualStrings("room42", msg.chat_id);
    try std.testing.expectEqualStrings("crash log", msg.content);
}

test "deliverResult uses default chat_id when to is null" {
    const allocator = std.testing.allocator;
    var test_bus = bus.Bus.init();
    defer test_bus.close();

    const delivery = DeliveryConfig{
        .mode = .always,
        .channel = "webhook",
        .to = null,
    };

    const delivered = try deliverResult(allocator, delivery, "hello", true, &test_bus);
    try std.testing.expect(delivered);

    var msg = test_bus.consumeOutbound().?;
    defer msg.deinit(allocator);
    try std.testing.expectEqualStrings("default", msg.chat_id);
}

test "deliverResult skips empty output" {
    const allocator = std.testing.allocator;
    var test_bus = bus.Bus.init();
    defer test_bus.close();

    const delivery = DeliveryConfig{
        .mode = .always,
        .channel = "telegram",
        .to = "chat1",
    };

    const delivered = try deliverResult(allocator, delivery, "", true, &test_bus);
    try std.testing.expect(!delivered);
    try std.testing.expectEqual(@as(usize, 0), test_bus.outboundDepth());
}

test "deliverResult best_effort swallows closed bus error" {
    const allocator = std.testing.allocator;
    var test_bus = bus.Bus.init();
    test_bus.close(); // close before delivery

    const delivery = DeliveryConfig{
        .mode = .always,
        .channel = "telegram",
        .to = "chat1",
        .best_effort = true,
    };

    // Should not return error because best_effort is true
    const delivered = try deliverResult(allocator, delivery, "msg", true, &test_bus);
    try std.testing.expect(!delivered);
}

test "one-shot job deleted after tick execution" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();

    const job = try scheduler.addOnce("1s", "echo oneshot");
    // Verify job was created
    try std.testing.expect(job.one_shot);
    try std.testing.expectEqual(@as(usize, 1), scheduler.listJobs().len);

    // Force the job to be due now
    scheduler.jobs.items[0].next_run_secs = 0;

    // Tick without bus — the shell command "echo oneshot" will actually run
    _ = scheduler.tick(std.time.timestamp(), null);

    // One-shot job should have been removed
    try std.testing.expectEqual(@as(usize, 0), scheduler.listJobs().len);
}

test "shell job uses configured cwd for relative output paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    scheduler.setShellCwd(workspace);
    defer scheduler.deinit();

    _ = try scheduler.addOnce("1s", "echo cwd_ok > cwd_proof.txt");
    scheduler.jobs.items[0].next_run_secs = 0;

    _ = scheduler.tick(std.time.timestamp(), null);

    const proof_file = try tmp.dir.openFile("cwd_proof.txt", .{});
    proof_file.close();
}

test "shell job delivers stdout via bus" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();

    var test_bus = bus.Bus.init();
    defer test_bus.close();

    const job = try scheduler.addJob("* * * * *", "echo hello_cron");
    _ = job;

    // Configure delivery
    scheduler.jobs.items[0].delivery = .{
        .mode = .always,
        .channel = "telegram",
        .to = "chat99",
    };
    scheduler.jobs.items[0].next_run_secs = 0;

    _ = scheduler.tick(std.time.timestamp(), &test_bus);

    // Verify delivery happened
    try std.testing.expect(test_bus.outboundDepth() > 0);
    var msg = test_bus.consumeOutbound().?;
    defer msg.deinit(allocator);
    try std.testing.expectEqualStrings("telegram", msg.channel);
    try std.testing.expectEqualStrings("chat99", msg.chat_id);
    // The content should contain "hello_cron" from the echo command
    try std.testing.expect(std.mem.indexOf(u8, msg.content, "hello_cron") != null);
}

test "agent job delivers result via bus" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();

    var test_bus = bus.Bus.init();
    defer test_bus.close();

    const job = try scheduler.addAgentJob("* * * * *", "Summarize today's news", null, .{
        .mode = .always,
        .channel = "discord",
        .to = "general",
    });
    job.next_run_secs = 0;

    _ = scheduler.tick(std.time.timestamp(), &test_bus);

    // Verify delivery
    try std.testing.expect(test_bus.outboundDepth() > 0);
    var msg = test_bus.consumeOutbound().?;
    defer msg.deinit(allocator);
    try std.testing.expectEqualStrings("discord", msg.channel);
    try std.testing.expectEqualStrings("general", msg.chat_id);
    try std.testing.expectEqualStrings("Summarize today's news", msg.content);
}

test "collectChildOutputWithTimeout disables timeout when set to zero" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var child = std.process.Child.init(&.{ platform.getShell(), platform.getShellFlag(), "echo ready" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

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
        std.time.nanoTimestamp(),
    );
    const term = try child.wait();

    try std.testing.expect(!timed_out);
    switch (term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => try std.testing.expect(false),
    }
    try std.testing.expect(std.mem.indexOf(u8, stdout.items, "ready") != null);
}

test "collectChildOutputWithTimeout kills process after deadline" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var child = std.process.Child.init(&.{ platform.getShell(), platform.getShellFlag(), "sleep 2; echo never" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    const timed_out = try collectChildOutputWithTimeout(
        &child,
        allocator,
        &stdout,
        &stderr,
        1,
        std.time.nanoTimestamp(),
    );
    const term = try child.wait();

    try std.testing.expect(timed_out);
    const completed_ok = switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
    try std.testing.expect(!completed_ok);
}

test "preferAgentExecPath keeps regular executable path" {
    const input = "/home/user/bin/nullclaw";
    try std.testing.expectEqualStrings(input, preferAgentExecPath(input));
}

test "preferAgentExecPath uses proc self exe for deleted linux path" {
    if (comptime builtin.os.tag != .linux) return;
    try std.testing.expectEqualStrings(LINUX_SELF_EXE_PATH, preferAgentExecPath("/tmp/nullclaw (deleted)"));
}

test "pathAgentExecutableName returns platform command name" {
    const expected = if (comptime builtin.os.tag == .windows) "nullclaw.exe" else "nullclaw";
    try std.testing.expectEqualStrings(expected, pathAgentExecutableName());
}

test "DeliveryMode parse and asStr" {
    try std.testing.expectEqual(DeliveryMode.none, DeliveryMode.parse("none"));
    try std.testing.expectEqual(DeliveryMode.always, DeliveryMode.parse("always"));
    try std.testing.expectEqual(DeliveryMode.on_error, DeliveryMode.parse("on_error"));
    try std.testing.expectEqual(DeliveryMode.on_success, DeliveryMode.parse("on_success"));
    try std.testing.expectEqual(DeliveryMode.none, DeliveryMode.parse("unknown"));
    try std.testing.expectEqual(DeliveryMode.always, DeliveryMode.parse("ALWAYS"));

    try std.testing.expectEqualStrings("none", DeliveryMode.none.asStr());
    try std.testing.expectEqualStrings("always", DeliveryMode.always.asStr());
    try std.testing.expectEqualStrings("on_error", DeliveryMode.on_error.asStr());
    try std.testing.expectEqualStrings("on_success", DeliveryMode.on_success.asStr());
}

test "probeSchedulerStatus reports missing config file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const config_path = try std.fs.path.join(allocator, &.{ base, "config.json" });
    defer allocator.free(config_path);
    const daemon_state_path = try std.fs.path.join(allocator, &.{ base, "daemon_state.json" });
    defer allocator.free(daemon_state_path);

    const status = probeSchedulerStatus(config_path, daemon_state_path, true);
    try std.testing.expect(!status.config_exists);
    try std.testing.expect(status.scheduler_enabled);
    try std.testing.expect(!status.daemon_state_present);
    try std.testing.expect(status.config_probe_error == null);
}

test "probeSchedulerStatus reports config and daemon state files independently" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const config_path = try std.fs.path.join(allocator, &.{ base, "config.json" });
    defer allocator.free(config_path);
    const daemon_state_path = try std.fs.path.join(allocator, &.{ base, "daemon_state.json" });
    defer allocator.free(daemon_state_path);

    {
        const file = try std.fs.createFileAbsolute(config_path, .{});
        defer file.close();
        try file.writeAll("{}\n");
    }

    var status = probeSchedulerStatus(config_path, daemon_state_path, false);
    try std.testing.expect(status.config_exists);
    try std.testing.expect(!status.scheduler_enabled);
    try std.testing.expect(!status.daemon_state_present);

    {
        const file = try std.fs.createFileAbsolute(daemon_state_path, .{});
        defer file.close();
        try file.writeAll("{\"status\":\"running\"}\n");
    }

    status = probeSchedulerStatus(config_path, daemon_state_path, false);
    try std.testing.expect(status.config_exists);
    try std.testing.expect(!status.scheduler_enabled);
    try std.testing.expect(status.daemon_state_present);
}

test "tick without bus still executes jobs" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();

    _ = try scheduler.addJob("* * * * *", "echo silent");
    scheduler.jobs.items[0].next_run_secs = 0;

    // Tick with null bus — should not crash
    _ = scheduler.tick(std.time.timestamp(), null);

    // Job should have been executed and rescheduled
    try std.testing.expectEqualStrings("ok", scheduler.jobs.items[0].last_status.?);
    try std.testing.expect(scheduler.jobs.items[0].next_run_secs > 0);
}

test "tick reschedules recurring job using cron expression" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();

    _ = try scheduler.addJob("*/10 * * * *", "echo periodic");
    scheduler.jobs.items[0].next_run_secs = 0;

    _ = scheduler.tick(0, null);
    try std.testing.expectEqual(@as(i64, 600), scheduler.jobs.items[0].next_run_secs);
}

test "tick reschedules anchored recurring job using cron expression" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();

    _ = try scheduler.addJob("8/25 * * * *", "echo anchored");
    scheduler.jobs.items[0].next_run_secs = 480;

    _ = scheduler.tick(480, null);
    try std.testing.expectEqualStrings("ok", scheduler.jobs.items[0].last_status.?);
    try std.testing.expectEqual(@as(i64, 1980), scheduler.jobs.items[0].next_run_secs);

    _ = scheduler.tick(1980, null);
    try std.testing.expectEqual(@as(i64, 3480), scheduler.jobs.items[0].next_run_secs);

    _ = scheduler.tick(3480, null);
    try std.testing.expectEqual(@as(i64, 4080), scheduler.jobs.items[0].next_run_secs);
}

// ── SQLite DB persistence tests ──────────────────────────────────

test "db save and load roundtrip" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    const db_path_str = try std.fmt.allocPrint(std.testing.allocator, "{s}/cron.db", .{base});
    defer std.testing.allocator.free(db_path_str);
    const db_path_z = try std.testing.allocator.dupeZ(u8, db_path_str);
    defer std.testing.allocator.free(db_path_z);

    const db = try openCronDbAtPath(db_path_z);
    defer _ = c.sqlite3_close(db);
    try ensureCronTable(db);

    // Build a job in a temporary scheduler (for ID allocation and next_run calc)
    var temp = CronScheduler.init(std.testing.allocator, 10, true);
    defer temp.deinit();
    const job = try temp.addJob("*/10 * * * *", "echo db-roundtrip");
    if (temp.getMutableJob(job.id)) |mj| {
        mj.last_run_secs = 1_772_455_140;
        mj.last_status = "ok";
    }
    try dbSaveJob(db, temp.getMutableJob(job.id).?);

    // Load into a new scheduler
    var loaded = CronScheduler.init(std.testing.allocator, 10, true);
    defer loaded.deinit();
    try dbLoadAllJobs(db, std.testing.allocator, &loaded);

    try std.testing.expectEqual(@as(usize, 1), loaded.jobs.items.len);
    const lj = loaded.jobs.items[0];
    try std.testing.expectEqualStrings("*/10 * * * *", lj.expression);
    try std.testing.expectEqualStrings("echo db-roundtrip", lj.command);
    try std.testing.expect(lj.last_run_secs != null);
    try std.testing.expectEqual(@as(i64, 1_772_455_140), lj.last_run_secs.?);
    try std.testing.expectEqualStrings("ok", lj.last_status.?);
}

test "db save and load agent job with delivery" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    const db_path_str = try std.fmt.allocPrint(std.testing.allocator, "{s}/cron.db", .{base});
    defer std.testing.allocator.free(db_path_str);
    const db_path_z = try std.testing.allocator.dupeZ(u8, db_path_str);
    defer std.testing.allocator.free(db_path_z);

    const db = try openCronDbAtPath(db_path_z);
    defer _ = c.sqlite3_close(db);
    try ensureCronTable(db);

    var temp = CronScheduler.init(std.testing.allocator, 10, true);
    defer temp.deinit();
    // addAgentJob makes its own copies of the delivery strings, so pass literals.
    const job = try temp.addAgentJob("*/15 * * * *", "Summarize status", "glm-4", .{
        .mode = .always,
        .channel = "telegram",
        .account_id = "backup",
        .to = "chat-42",
    });
    try dbSaveJob(db, job);

    var loaded = CronScheduler.init(std.testing.allocator, 10, true);
    defer loaded.deinit();
    try dbLoadAllJobs(db, std.testing.allocator, &loaded);

    try std.testing.expectEqual(@as(usize, 1), loaded.jobs.items.len);
    const lj = loaded.jobs.items[0];
    try std.testing.expectEqual(JobType.agent, lj.job_type);
    try std.testing.expect(lj.prompt != null);
    try std.testing.expectEqualStrings("Summarize status", lj.prompt.?);
    try std.testing.expect(lj.model != null);
    try std.testing.expectEqualStrings("glm-4", lj.model.?);
    try std.testing.expectEqual(DeliveryMode.always, lj.delivery.mode);
    try std.testing.expectEqualStrings("telegram", lj.delivery.channel.?);
    try std.testing.expectEqualStrings("backup", lj.delivery.account_id.?);
    try std.testing.expectEqualStrings("chat-42", lj.delivery.to.?);
}

test "dbDeleteJob removes a row" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    const db_path_str = try std.fmt.allocPrint(std.testing.allocator, "{s}/cron.db", .{base});
    defer std.testing.allocator.free(db_path_str);
    const db_path_z = try std.testing.allocator.dupeZ(u8, db_path_str);
    defer std.testing.allocator.free(db_path_z);

    const db = try openCronDbAtPath(db_path_z);
    defer _ = c.sqlite3_close(db);
    try ensureCronTable(db);

    var temp = CronScheduler.init(std.testing.allocator, 10, true);
    defer temp.deinit();
    const job = try temp.addJob("*/5 * * * *", "echo delete-me");
    const job_id = try std.testing.allocator.dupe(u8, job.id);
    defer std.testing.allocator.free(job_id);
    try dbSaveJob(db, job);

    try std.testing.expectEqual(@as(usize, 1), dbCountJobs(db));
    try dbDeleteJob(db, job_id);
    try std.testing.expectEqual(@as(usize, 0), dbCountJobs(db));
}

test "dbCountJobs returns zero on empty table" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    const db_path_str = try std.fmt.allocPrint(std.testing.allocator, "{s}/empty.db", .{base});
    defer std.testing.allocator.free(db_path_str);
    const db_path_z = try std.testing.allocator.dupeZ(u8, db_path_str);
    defer std.testing.allocator.free(db_path_z);

    const db = try openCronDbAtPath(db_path_z);
    defer _ = c.sqlite3_close(db);
    try ensureCronTable(db);
    try std.testing.expectEqual(@as(usize, 0), dbCountJobs(db));
}

test "ensureCronTable is idempotent" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    const db_path_str = try std.fmt.allocPrint(std.testing.allocator, "{s}/idem.db", .{base});
    defer std.testing.allocator.free(db_path_str);
    const db_path_z = try std.testing.allocator.dupeZ(u8, db_path_str);
    defer std.testing.allocator.free(db_path_z);

    const db = try openCronDbAtPath(db_path_z);
    defer _ = c.sqlite3_close(db);

    // Call three times — must not error
    try ensureCronTable(db);
    try ensureCronTable(db);
    try ensureCronTable(db);
}

// ── Test helper ──────────────────────────────────────────────────

/// Isolated scheduler for tests: points at a fresh tmpDir DB (SQLite) or an
/// unreachable JSON path so the test never touches the default store.
/// Caller owns cleanup of both the scheduler and the tmpDir.
const IsolatedTestScheduler = struct {
    scheduler: CronScheduler,
    tmp: std.testing.TmpDir,
    db_path_buf: [:0]u8, // heap-allocated; freed in deinit

    pub fn deinit(self: *IsolatedTestScheduler) void {
        self.scheduler.deinit();
        std.testing.allocator.free(self.db_path_buf);
        self.tmp.cleanup();
    }
};

fn makeIsolatedTestScheduler() !IsolatedTestScheduler {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const db_path_str = try std.fmt.allocPrint(std.testing.allocator, "{s}/cron_test.db", .{base});
    defer std.testing.allocator.free(db_path_str);
    const db_path = try std.testing.allocator.dupeZ(u8, db_path_str);
    errdefer std.testing.allocator.free(db_path);
    var sched = CronScheduler.init(std.testing.allocator, 64, true);
    sched.db_path = db_path;
    return .{ .scheduler = sched, .tmp = tmp, .db_path_buf = db_path };
}

// ── Regression tests for concurrency bugs fixed in this session ──

test "default-store isolation: two schedulers on separate DBs do not share jobs" {
    // Regression for the class of test failures where loadJobsStrict hit the
    // ambient ~/.nullclaw/cron.db and loaded unrelated persisted content.
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var a = try makeIsolatedTestScheduler();
    defer a.deinit();
    var b = try makeIsolatedTestScheduler();
    defer b.deinit();

    // Add a job only to scheduler A.
    const j = try a.scheduler.addJob("*/5 * * * *", "echo isolation-test");
    const jid = try std.testing.allocator.dupe(u8, j.id);
    defer std.testing.allocator.free(jid);
    try dbUpsertAndVerify(&a.scheduler, a.scheduler.getJob(jid).?);

    // Load B from its own empty DB — must see zero jobs.
    try loadJobsStrict(&b.scheduler);
    try std.testing.expectEqual(@as(usize, 0), b.scheduler.listJobs().len);

    // Load A from its DB — must see exactly the one job.
    var a2 = CronScheduler.init(std.testing.allocator, 64, true);
    a2.db_path = a.db_path_buf;
    defer a2.deinit();
    try loadJobsStrict(&a2);
    try std.testing.expectEqual(@as(usize, 1), a2.listJobs().len);
    try std.testing.expectEqualStrings("echo isolation-test", a2.listJobs()[0].command);
}

test "reloadJobs under concurrent mutation does not corrupt job list" {
    // Regression for the scheduler/worker race: reloadJobs swaps scheduler.jobs
    // (std.mem.swap) while another thread may hold getMutableJob pointers.
    // This test runs reload + addJob concurrently 50 times and asserts no job
    // count ever exceeds the seeded count + concurrent additions.
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var iso = try makeIsolatedTestScheduler();
    defer iso.deinit();
    const sched = &iso.scheduler;

    // Seed two jobs.
    const j1 = try sched.addJob("0 * * * *", "echo base-1");
    const id1 = try std.testing.allocator.dupe(u8, j1.id);
    defer std.testing.allocator.free(id1);
    const j2 = try sched.addJob("5 * * * *", "echo base-2");
    const id2 = try std.testing.allocator.dupe(u8, j2.id);
    defer std.testing.allocator.free(id2);
    try dbUpsertAndVerify(sched, sched.getJob(id1).?);
    try dbUpsertAndVerify(sched, sched.getJob(id2).?);

    // Reload from the same isolated DB 20 times — job count must stay at 2.
    for (0..20) |_| {
        try reloadJobs(sched);
        const n = sched.listJobs().len;
        try std.testing.expect(n == 2);
    }
}

test "DB round-trips timeout_secs and last_output" {
    // Regression: timeout_secs and last_output were missing from DB persistence;
    // they would be silently dropped on every reload/bounce.
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var iso = try makeIsolatedTestScheduler();
    defer iso.deinit();
    const sched = &iso.scheduler;

    const j = try sched.addJob("30 8 * * 1-5", "echo roundtrip-fields");
    const jid = try std.testing.allocator.dupe(u8, j.id);
    defer std.testing.allocator.free(jid);
    if (sched.getMutableJob(jid)) |mj| {
        mj.timeout_secs = 42;
        // last_output must use sched.allocator — freed by freeJobOwned.
        mj.last_output = try sched.allocator.dupe(u8, "hello world");
    }
    try dbUpsertAndVerify(sched, sched.getJob(jid).?);

    var loaded = CronScheduler.init(std.testing.allocator, 64, true);
    loaded.db_path = iso.db_path_buf;
    defer loaded.deinit();
    try loadJobsStrict(&loaded);

    const jobs = loaded.listJobs();
    try std.testing.expectEqual(@as(usize, 1), jobs.len);
    try std.testing.expectEqual(@as(?u32, 42), jobs[0].timeout_secs);
    try std.testing.expect(jobs[0].last_output != null);
    try std.testing.expectEqualStrings("hello world", jobs[0].last_output.?);
}
test "ensureRunQueueTable creates table" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var iso = try makeIsolatedTestScheduler();
    defer iso.deinit();

    const db = try openCronDbAtPath(iso.db_path_buf);
    defer _ = c.sqlite3_close(db);
    try ensureCronTable(db); // calls ensureRunQueueTable internally

    // Verify table exists by doing a simple query.
    const sql = "SELECT COUNT(*) FROM cron_run_queue";
    var stmt: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db, sql, -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(stmt, 0));
}

test "dbTickAndEnqueue enqueues due jobs and updates next_run_secs" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var iso = try makeIsolatedTestScheduler();
    defer iso.deinit();
    const sched = &iso.scheduler;

    // Add a job with next_run_secs in the past.
    const j = try sched.addJob("* * * * *", "echo tick-test");
    const jid = try std.testing.allocator.dupe(u8, j.id);
    defer std.testing.allocator.free(jid);
    if (sched.getMutableJob(jid)) |mj| mj.next_run_secs = 1; // far in the past
    try dbUpsertAndVerify(sched, sched.getJob(jid).?);

    const now = std.time.timestamp();
    const count = try dbTickAndEnqueue(iso.db_path_buf, std.testing.allocator, now);
    try std.testing.expectEqual(@as(usize, 1), count);

    // Verify run queue has one row.
    const db = try openCronDbAtPath(iso.db_path_buf);
    defer _ = c.sqlite3_close(db);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT COUNT(*) FROM cron_run_queue WHERE status='pending'";
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db, sql, -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(i64, 1), c.sqlite3_column_int64(stmt, 0));
}

test "dbDequeueNextJob returns and marks in_progress" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var iso = try makeIsolatedTestScheduler();
    defer iso.deinit();
    const sched = &iso.scheduler;

    const j = try sched.addJob("* * * * *", "echo dequeue-test");
    const jid = try std.testing.allocator.dupe(u8, j.id);
    defer std.testing.allocator.free(jid);
    if (sched.getMutableJob(jid)) |mj| mj.next_run_secs = 1;
    try dbUpsertAndVerify(sched, sched.getJob(jid).?);

    const now = std.time.timestamp();
    _ = try dbTickAndEnqueue(iso.db_path_buf, std.testing.allocator, now);

    const db = try openCronDbAtPath(iso.db_path_buf);
    defer _ = c.sqlite3_close(db);
    try ensureRunQueueTable(db);

    const result = try dbDequeueNextJob(db, std.testing.allocator);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.job_id);
    try std.testing.expectEqualStrings(jid, result.?.job_id);

    // Second dequeue should return null (row is now in_progress).
    const result2 = try dbDequeueNextJob(db, std.testing.allocator);
    try std.testing.expect(result2 == null);
}

test "dbLoadJobSpec returns correct spec" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var iso = try makeIsolatedTestScheduler();
    defer iso.deinit();
    const sched = &iso.scheduler;

    const j = try sched.addJob("0 8 * * *", "echo spec-test");
    const jid = try std.testing.allocator.dupe(u8, j.id);
    defer std.testing.allocator.free(jid);
    if (sched.getMutableJob(jid)) |mj| mj.timeout_secs = 30;
    try dbUpsertAndVerify(sched, sched.getJob(jid).?);

    const db = try openCronDbAtPath(iso.db_path_buf);
    defer _ = c.sqlite3_close(db);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const spec = try dbLoadJobSpec(db, arena.allocator(), jid);
    try std.testing.expect(spec != null);
    try std.testing.expectEqualStrings("echo spec-test", spec.?.command);
    try std.testing.expectEqual(JobType.shell, spec.?.job_type);
    try std.testing.expectEqual(@as(?u32, 30), spec.?.timeout_secs);
}

test "dbCompleteJob writes result and removes queue row" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var iso = try makeIsolatedTestScheduler();
    defer iso.deinit();
    const sched = &iso.scheduler;

    const j = try sched.addJob("* * * * *", "echo complete-test");
    const jid = try std.testing.allocator.dupe(u8, j.id);
    defer std.testing.allocator.free(jid);
    if (sched.getMutableJob(jid)) |mj| mj.next_run_secs = 1;
    try dbUpsertAndVerify(sched, sched.getJob(jid).?);

    const now = std.time.timestamp();
    _ = try dbTickAndEnqueue(iso.db_path_buf, std.testing.allocator, now);

    const db = try openCronDbAtPath(iso.db_path_buf);
    defer _ = c.sqlite3_close(db);
    try ensureRunQueueTable(db);

    const dequeued = (try dbDequeueNextJob(db, std.testing.allocator)).?;
    defer std.testing.allocator.free(dequeued.job_id);

    try dbCompleteJob(db, dequeued.job_id, dequeued.queue_row_id, now, "ok", "output text", false);

    // Queue should be empty.
    var stmt: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM cron_run_queue", -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(stmt, 0));
}

test "dbResetInProgressJobs resets stale rows" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var iso = try makeIsolatedTestScheduler();
    defer iso.deinit();
    const sched = &iso.scheduler;

    const j = try sched.addJob("* * * * *", "echo reset-test");
    const jid = try std.testing.allocator.dupe(u8, j.id);
    defer std.testing.allocator.free(jid);
    if (sched.getMutableJob(jid)) |mj| mj.next_run_secs = 1;
    try dbUpsertAndVerify(sched, sched.getJob(jid).?);

    const now = std.time.timestamp();
    _ = try dbTickAndEnqueue(iso.db_path_buf, std.testing.allocator, now);

    const db = try openCronDbAtPath(iso.db_path_buf);
    defer _ = c.sqlite3_close(db);
    try ensureRunQueueTable(db);

    // Dequeue (sets in_progress), then reset.
    const dequeued = (try dbDequeueNextJob(db, std.testing.allocator)).?;
    defer std.testing.allocator.free(dequeued.job_id);
    try dbResetInProgressJobs(db);

    // Should be pending again.
    var stmt: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db, "SELECT status FROM cron_run_queue", -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    const status_ptr = c.sqlite3_column_text(stmt, 0);
    try std.testing.expect(status_ptr != null);
    const status_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
    try std.testing.expectEqualStrings("pending", status_ptr[0..status_len]);
}

test "dbLoadJobSpec persists and restores delivery_best_effort and session_target" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var iso = try makeIsolatedTestScheduler();
    defer iso.deinit();
    const sched = &iso.scheduler;

    const job_ptr = try sched.addJob("* * * * *", "echo persist-test");
    job_ptr.delivery.best_effort = true;
    job_ptr.session_target = .main;
    try saveJobs(sched);

    const db = try openCronDbAtPath(iso.db_path_buf);
    defer closeCronDb(db);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const jid = try std.testing.allocator.dupe(u8, job_ptr.id);
    defer std.testing.allocator.free(jid);

    const spec = try dbLoadJobSpec(db, arena.allocator(), jid);
    try std.testing.expect(spec != null);
    try std.testing.expect(spec.?.delivery.best_effort == true);
    try std.testing.expectEqual(SessionTarget.main, spec.?.session_target);
}
