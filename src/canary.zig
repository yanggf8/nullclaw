//! Canary isolation — scratch memory safety boundary.
//! Commit 2 (RED): tests only; sanitizeConfigInPlace / assertScratchDbPath /
//! initScratchMemoryRuntime and MemoryRuntime.primaryDbPath() land in commit 3.

const std = @import("std");
const std_compat = @import("compat");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Agent = @import("agent/root.zig").Agent;
const Config = @import("config.zig").Config;
const MemoryConfig = @import("config_types.zig").MemoryConfig;
const memory = @import("memory/root.zig");
const MemoryRuntime = memory.MemoryRuntime;
const tools_mod = @import("tools/root.zig");
const Tool = tools_mod.Tool;
const providers = @import("providers/root.zig");
const Provider = providers.Provider;
const observability = @import("observability.zig");
const security = @import("security/policy.zig");

/// Error set for assertScratchDbPath (implemented in commit 3).
pub const AssertScratchDbPathError = error{
    CanaryScratchDbPathOutsideWorkspace,
    CanaryScratchDbPathUnderHomeNullclaw,
};

pub fn sanitizeConfigInPlace(cfg: *Config, scratch_ws: []const u8, scratch_config_path: []const u8) void {
    cfg.workspace_dir = scratch_ws;
    cfg.workspace_dir_override = scratch_ws;
    cfg.config_path = scratch_config_path;
    cfg.memory.backend = "sqlite";
    cfg.memory.auto_save = false;
    cfg.memory.search.store.sidecar_path = "";
    cfg.memory.response_cache.enabled = false;
    cfg.memory.qmd.enabled = false;
    cfg.security.audit.log_path = "audit.log";
    cfg.backfillRuntimeDerivedFields() catch {};
    cfg.syncFlatFields();
}

pub fn assertScratchDbPath(db_path: []const u8, scratch_ws: []const u8) AssertScratchDbPathError!void {
    if (std.mem.indexOf(u8, db_path, "/.nullclaw/") != null) return error.CanaryScratchDbPathUnderHomeNullclaw;
    if (!std.mem.startsWith(u8, db_path, scratch_ws)) return error.CanaryScratchDbPathOutsideWorkspace;
}

pub fn initScratchMemoryRuntime(
    allocator: std.mem.Allocator,
    memcfg: *const MemoryConfig,
    scratch_ws: []const u8,
) (AssertScratchDbPathError || error{ CanaryMemoryInitFailed, CanaryScratchDbPathMissing })!MemoryRuntime {
    var rt = memory.initRuntime(allocator, memcfg, scratch_ws) orelse return error.CanaryMemoryInitFailed;
    errdefer rt.deinit();
    const db_path = rt.primaryDbPath() orelse return error.CanaryScratchDbPathMissing;
    try assertScratchDbPath(db_path, scratch_ws);
    return rt;
}

pub const TOKEN_BLOWUP_FACTOR: f64 = 3.0;

pub const CanaryInputClass = enum {
    tool_failure,
    memory_dependent,
    simple_qa,
};

pub const ArmMetrics = struct {
    reflection: Agent.ReflectionMetrics,
    main_turn_tokens: usize = 0,
    response_len: usize = 0,
    lesson_count: usize = 0,
    max_lesson_utility_score: f32 = 0.5,
    duration_ms: u64 = 0,
    turn_a_saved: bool = false,
    turn_b_recalled_lesson: bool = false,
    loop_closed: bool = false,
};

pub const CanaryInputResult = struct {
    class: CanaryInputClass,
    baseline: ArmMetrics,
    treatment: ArmMetrics,
};

pub const KillSignalOptions = struct {
    token_blowup_factor: f64 = TOKEN_BLOWUP_FACTOR,
};

pub const KillSignalEvaluation = struct {
    reflection_no_save: bool = false,
    loop_never_closed: bool = false,
    no_arm_difference: bool = false,
    token_blowup: bool = false,
    token_blowup_ratio: ?f64 = null,

    pub fn any(self: @This()) bool {
        return self.reflection_no_save or self.loop_never_closed or self.no_arm_difference or self.token_blowup;
    }
};

pub fn evaluateKillSignals(results: []const CanaryInputResult, opts: KillSignalOptions) KillSignalEvaluation {
    var baseline_total: usize = 0;
    var treatment_total: usize = 0;
    var eval: KillSignalEvaluation = .{};

    for (results) |r| {
        baseline_total += r.baseline.main_turn_tokens + r.baseline.reflection.reflection_estimated_tokens;
        treatment_total += r.treatment.main_turn_tokens + r.treatment.reflection.reflection_estimated_tokens;

        if (r.class == .memory_dependent) {
            if (!r.treatment.turn_a_saved) {
                eval.reflection_no_save = true;
            } else if (!r.treatment.turn_b_recalled_lesson) {
                eval.loop_never_closed = true;
            } else if (r.treatment.loop_closed == r.baseline.loop_closed) {
                eval.no_arm_difference = true;
            }
        }
    }

    if (baseline_total > 0) {
        const ratio = @as(f64, @floatFromInt(treatment_total)) / @as(f64, @floatFromInt(baseline_total));
        eval.token_blowup_ratio = ratio;
        eval.token_blowup = ratio > opts.token_blowup_factor;
    }

    return eval;
}

pub const CanaryReport = struct {
    results: []const CanaryInputResult,
    kills: KillSignalEvaluation,
};

pub fn buildMetricsSummary(allocator: std.mem.Allocator, report: CanaryReport) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var buf_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const w = &buf_writer.writer;

    try w.writeAll("nullclaw self-improvement canary metrics\n");
    try w.writeAll("========================================\n");

    var baseline_token_total: usize = 0;
    var treatment_token_total: usize = 0;

    for (report.results) |r| {
        baseline_token_total += r.baseline.main_turn_tokens + r.baseline.reflection.reflection_estimated_tokens;
        treatment_token_total += r.treatment.main_turn_tokens + r.treatment.reflection.reflection_estimated_tokens;

        try w.print("\n[{s}]\n", .{@tagName(r.class)});
        try w.print("  baseline reflection_estimated_tokens: {d}\n", .{r.baseline.reflection.reflection_estimated_tokens});
        try w.print("  treatment reflection_estimated_tokens: {d}\n", .{r.treatment.reflection.reflection_estimated_tokens});
        try w.print("  treatment lesson_count: {d}\n", .{r.treatment.lesson_count});
        try w.print("  treatment judge_continue_count: {d}\n", .{r.treatment.reflection.judge_continue_count});
        try w.print("  [{s}] baseline: turn_a_saved={} turn_b_recalled_lesson={} loop_closed={} main_turn_tokens={d}\n", .{
            @tagName(r.class),
            r.baseline.turn_a_saved,
            r.baseline.turn_b_recalled_lesson,
            r.baseline.loop_closed,
            r.baseline.main_turn_tokens,
        });
        try w.print("  [{s}] treatment: turn_a_saved={} turn_b_recalled_lesson={} loop_closed={} main_turn_tokens={d}\n", .{
            @tagName(r.class),
            r.treatment.turn_a_saved,
            r.treatment.turn_b_recalled_lesson,
            r.treatment.loop_closed,
            r.treatment.main_turn_tokens,
        });
    }

    try w.print("\nTotal baseline tokens: {d}\n", .{baseline_token_total});
    try w.print("Total treatment tokens: {d}\n", .{treatment_token_total});

    const kills = report.kills;
    try w.writeAll("\nKill signals:\n");
    try w.print("  reflection_no_save={}\n", .{kills.reflection_no_save});
    try w.print("  loop_never_closed={}\n", .{kills.loop_never_closed});
    try w.print("  no_arm_difference={}\n", .{kills.no_arm_difference});
    try w.print("  token_blowup={}\n", .{kills.token_blowup});
    if (kills.token_blowup_ratio) |ratio| {
        try w.print("  token_blowup_ratio={d:.2}\n", .{ratio});
    }

    buf = buf_writer.toArrayList();
    return buf.toOwnedSlice(allocator);
}

const canary_fail_instructive_error = "canary-topic rule: answer follow-ups directly from the learned rule; do not retry canary_fail. Tool contract: canary_fail is blocked here.";

const CanaryFailTool = struct {
    const Self = @This();
    pub const tool_name = "canary_fail";
    pub const tool_description = "Canary probe tool that always fails.";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}";
    pub const vtable = tools_mod.ToolVTable(Self);

    fn tool(self: *Self) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *Self, _: std.mem.Allocator, _: tools_mod.JsonObjectMap) !tools_mod.ToolResult {
        return tools_mod.ToolResult.fail(canary_fail_instructive_error);
    }
};

const lesson_category: memory.MemoryCategory = .{ .custom = "lesson" };

fn inducePromptForClass(class: CanaryInputClass) []const u8 {
    return switch (class) {
        .tool_failure => "Call canary_fail exactly once. When it fails, do not retry it. Then answer in one short sentence stating the learned rule: canary-topic follow-ups should be answered directly from the learned rule, not by retrying canary_fail.",
        .memory_dependent => "Canary memory drill. Call canary_fail exactly once. When it fails, do not retry it. Then answer in one short sentence stating the durable lesson: for canary-topic follow-ups, answer directly from the learned rule and do not retry canary_fail.",
        .simple_qa => "What is 2+2? Reply with just the number.",
    };
}

fn recallPromptForClass(class: CanaryInputClass) []const u8 {
    return switch (class) {
        .tool_failure => "Briefly state whether the previous canary_fail attempt produced a useful lesson. Do not call tools.",
        .memory_dependent => "Canary-topic follow-up. Using any recalled memory, state the durable lesson learned about the canary_fail tool. Answer from the saved lesson; do not call any tool.",
        .simple_qa => "What is 3+3? Reply with just the number.",
    };
}

fn runCanaryArm(
    allocator: std.mem.Allocator,
    cfg: *Config,
    provider: Provider,
    scratch_base: []const u8,
    class: CanaryInputClass,
    is_baseline: bool,
) !ArmMetrics {
    const arm_name: []const u8 = if (is_baseline) "baseline" else "treatment";
    const class_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ scratch_base, @tagName(class) });
    defer allocator.free(class_dir);
    std_compat.fs.makeDirAbsolute(class_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const arm_ws = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ class_dir, arm_name });
    defer allocator.free(arm_ws);
    try std_compat.fs.makeDirAbsolute(arm_ws);

    const scratch_config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{arm_ws});
    defer allocator.free(scratch_config_path);

    sanitizeConfigInPlace(cfg, arm_ws, scratch_config_path);
    cfg.agent.judge_after_turn = false;
    cfg.agent.reflect_after_turn = !is_baseline;

    var rt = try initScratchMemoryRuntime(allocator, &cfg.memory, arm_ws);
    defer rt.deinit();

    var fail_tool = CanaryFailTool{};
    const tool_list = [_]Tool{fail_tool.tool()};

    var tracker = security.RateTracker.init(allocator, cfg.autonomy.max_actions_per_hour);
    defer tracker.deinit();

    var policy = security.SecurityPolicy{
        .autonomy = cfg.autonomy.level,
        .workspace_dir = cfg.workspace_dir,
        .workspace_only = cfg.autonomy.workspace_only,
        .allowed_commands = security.resolveAllowedCommands(cfg.autonomy.level, cfg.autonomy.allowed_commands),
        .max_actions_per_hour = cfg.autonomy.max_actions_per_hour,
        .require_approval_for_medium_risk = cfg.autonomy.require_approval_for_medium_risk,
        .block_high_risk_commands = cfg.autonomy.block_high_risk_commands,
        .block_medium_risk_commands = cfg.autonomy.block_medium_risk_commands,
        .allow_raw_url_chars = cfg.autonomy.allow_raw_url_chars,
        .tracker = &tracker,
    };

    var noop = observability.NoopObserver{};
    var agent = try Agent.fromConfigWithProfile(allocator, cfg, provider, tool_list[0..], rt.memory, noop.observer(), null);
    defer agent.deinit();
    agent.policy = &policy;
    agent.mem_rt = &rt;

    const lessons_before = agent.reflectionMetrics().reflection_lessons_saved;

    const start_ms = std_compat.time.milliTimestamp();

    const resp_a = try agent.turn(inducePromptForClass(class));
    defer allocator.free(resp_a);
    const turn_a_tokens: usize = @intCast(agent.last_turn_usage.total_tokens);

    const post_a = agent.reflectionMetrics();
    const refl_tokens_a = post_a.reflection_estimated_tokens;
    const refl_cost_a = post_a.reflection_estimated_cost_usd;

    const lessons_list = try rt.memory.list(allocator, lesson_category, null);
    defer memory.freeEntries(allocator, lessons_list);

    const turn_a_saved = (post_a.reflection_lessons_saved > lessons_before) and (lessons_list.len > 0);

    const resp_b = try agent.turn(recallPromptForClass(class));
    defer allocator.free(resp_b);
    const turn_b_tokens: usize = @intCast(agent.last_turn_usage.total_tokens);

    const end_ms = std_compat.time.milliTimestamp();

    const post_b = agent.reflectionMetrics();
    const turn_b_recalled_lesson = post_b.recalled_lesson;
    const loop_closed = turn_a_saved and turn_b_recalled_lesson;
    const main_turn_tokens = turn_a_tokens + turn_b_tokens;

    var max_utility: f32 = 0.5;
    for (lessons_list) |entry| {
        if (entry.utility_score > max_utility) max_utility = entry.utility_score;
    }

    return .{
        .reflection = .{
            .reflection_estimated_tokens = refl_tokens_a + post_b.reflection_estimated_tokens,
            .reflection_estimated_cost_usd = refl_cost_a + post_b.reflection_estimated_cost_usd,
            .judge_continue_count = post_b.judge_continue_count,
            .reflection_lessons_saved = post_b.reflection_lessons_saved,
            .reflection_turn_invocations = post_b.reflection_turn_invocations,
            .recalled_lesson = post_b.recalled_lesson,
        },
        .main_turn_tokens = main_turn_tokens,
        .response_len = resp_a.len + resp_b.len,
        .lesson_count = lessons_list.len,
        .max_lesson_utility_score = max_utility,
        .duration_ms = if (end_ms >= start_ms) @intCast(end_ms - start_ms) else 0,
        .turn_a_saved = turn_a_saved,
        .turn_b_recalled_lesson = turn_b_recalled_lesson,
        .loop_closed = loop_closed,
    };
}

pub fn run(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    _ = sub_args;
    if (builtin.is_test) return;

    var cfg = try Config.load(allocator);
    defer cfg.deinit();

    const scratch_base = try std.fmt.allocPrint(allocator, "/tmp/nullclaw-canary-{d}", .{std_compat.time.milliTimestamp()});
    defer allocator.free(scratch_base);
    defer std_compat.fs.deleteTreeAbsolute(scratch_base) catch {};
    try std_compat.fs.makeDirAbsolute(scratch_base);

    var bundle = try providers.runtime_bundle.RuntimeProviderBundle.init(allocator, &cfg);
    defer bundle.deinit();
    const provider = bundle.provider();

    const classes = [_]CanaryInputClass{ .tool_failure, .memory_dependent, .simple_qa };
    var results: [classes.len]CanaryInputResult = undefined;

    for (classes, 0..) |class, i| {
        results[i] = .{
            .class = class,
            .baseline = try runCanaryArm(allocator, &cfg, provider, scratch_base, class, true),
            .treatment = try runCanaryArm(allocator, &cfg, provider, scratch_base, class, false),
        };
    }

    const kills = evaluateKillSignals(&results, .{});
    const report: CanaryReport = .{
        .results = &results,
        .kills = kills,
    };

    const summary = try buildMetricsSummary(allocator, report);
    defer allocator.free(summary);

    const model = cfg.default_model orelse return error.NoDefaultModel;

    var buf: [8192]u8 = undefined;
    var bw = std_compat.fs.File.stdout().writer(&buf);
    const w = &bw.interface;

    if (provider.chatWithSystem(
        allocator,
        "You are evaluating a nullclaw self-improvement canary. Give a concise GO/NO-GO verdict with reasoning from the metrics.",
        summary,
        model,
        0.0,
    )) |verdict| {
        defer allocator.free(verdict);
        try w.print("{s}\n\n", .{verdict});
    } else |err| {
        try w.print("(LLM verdict unavailable: {s} — showing raw metrics)\n\n", .{@errorName(err)});
    }
    try w.print("{s}\n", .{summary});
    try w.flush();
}

test "sanitizeConfigInPlace forces sqlite and scratch paths" {
    const allocator = std.testing.allocator;

    var base = Config{
        .workspace_dir = "/home/x/.nullclaw/workspace",
        .config_path = "/home/x/.nullclaw/config.json",
        .allocator = allocator,
    };
    base.memory.backend = "postgres";
    base.memory.auto_save = true;
    base.memory.response_cache.enabled = true;
    base.memory.qmd.enabled = true;
    base.memory.search.store.sidecar_path = "/abs/side.db";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const scratch = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(scratch);

    const scratch_config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{scratch});
    defer allocator.free(scratch_config_path);

    sanitizeConfigInPlace(&base, scratch, scratch_config_path);

    try std.testing.expectEqualStrings("sqlite", base.memory.backend);
    try std.testing.expectEqualStrings(scratch, base.workspace_dir);
    try std.testing.expect(base.workspace_dir_override != null);
    try std.testing.expectEqualStrings(scratch, base.workspace_dir_override.?);
    try std.testing.expectEqualStrings(scratch_config_path, base.config_path);
    try std.testing.expect(!base.memory.response_cache.enabled);
    try std.testing.expectEqualStrings("", base.memory.search.store.sidecar_path);
    try std.testing.expect(!base.memory.qmd.enabled);
    try std.testing.expect(!base.memory.auto_save);
}

test "assertScratchDbPath accepts path under scratch, rejects real home" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const scratch = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(scratch);

    const scratch_db = try std.fmt.allocPrint(allocator, "{s}/memory.db", .{scratch});
    defer allocator.free(scratch_db);

    try assertScratchDbPath(scratch_db, scratch);

    try std.testing.expectError(
        error.CanaryScratchDbPathUnderHomeNullclaw,
        assertScratchDbPath("/home/x/.nullclaw/workspace/memory.db", scratch),
    );

    try std.testing.expectError(
        error.CanaryScratchDbPathOutsideWorkspace,
        assertScratchDbPath("/some/other/place/memory.db", scratch),
    );
}

test "initScratchMemoryRuntime isolates db under scratch" {
    if (!build_options.enable_memory_sqlite) return;

    const allocator = std.testing.allocator;

    var base = Config{
        .workspace_dir = "/home/x/.nullclaw/workspace",
        .config_path = "/home/x/.nullclaw/config.json",
        .allocator = allocator,
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const scratch = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(scratch);

    const scratch_config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{scratch});
    defer allocator.free(scratch_config_path);

    sanitizeConfigInPlace(&base, scratch, scratch_config_path);

    var rt = try initScratchMemoryRuntime(allocator, &base.memory, scratch);
    defer rt.deinit();

    const db_path = rt.primaryDbPath() orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.startsWith(u8, db_path, scratch));
    try std.testing.expect(std.mem.indexOf(u8, db_path, "/.nullclaw/") == null);
    try std.testing.expect(std.mem.endsWith(u8, db_path, "memory.db"));
}

test "canary_fail tool returns instructive contract failure" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer parsed.deinit();

    var tool = CanaryFailTool{};
    const result = try tool.execute(allocator, parsed.value.object);

    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
    try std.testing.expect(result.output.len == 0);
    const err_msg = result.error_msg.?;
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "canary-topic rule") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "do not retry canary_fail") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "answer follow-ups directly") != null);
}

test "canary induce prompts ask for short lesson-carrying answer" {
    const tool_prompt = inducePromptForClass(.tool_failure);
    const mem_prompt = inducePromptForClass(.memory_dependent);

    try std.testing.expect(std.mem.indexOf(u8, tool_prompt, "one short sentence") != null);
    try std.testing.expect(std.mem.indexOf(u8, tool_prompt, "do not retry") != null);
    try std.testing.expect(std.mem.indexOf(u8, tool_prompt, "canary_fail") != null);
    try std.testing.expect(std.mem.indexOf(u8, tool_prompt, "learned rule") != null);

    try std.testing.expect(std.mem.indexOf(u8, mem_prompt, "one short sentence") != null);
    try std.testing.expect(std.mem.indexOf(u8, mem_prompt, "do not retry") != null);
    try std.testing.expect(std.mem.indexOf(u8, mem_prompt, "canary_fail") != null);
    try std.testing.expect(std.mem.indexOf(u8, mem_prompt, "learned rule") != null);
}

test "evaluateKillSignals v2 signal table" {
    const empty_refl = Agent.ReflectionMetrics{
        .reflection_estimated_tokens = 0,
        .reflection_estimated_cost_usd = 0,
        .judge_continue_count = 0,
        .reflection_lessons_saved = 0,
        .reflection_turn_invocations = 0,
    };

    const RatioExpect = union(enum) {
        skip,
        is_null,
        approx: f64,
    };

    const Case = struct {
        name: []const u8,
        class: CanaryInputClass = .memory_dependent,
        baseline: ArmMetrics,
        treatment: ArmMetrics,
        opts: KillSignalOptions = .{},
        expect_any: bool,
        expect_reflection_no_save: bool,
        expect_loop_never_closed: bool,
        expect_no_arm_difference: bool,
        expect_token_blowup: bool,
        ratio_expect: RatioExpect = .skip,
    };

    const cases = [_]Case{
        .{
            .name = "clean",
            .baseline = .{
                .main_turn_tokens = 100,
                .reflection = empty_refl,
                .turn_a_saved = false,
                .turn_b_recalled_lesson = false,
                .loop_closed = false,
            },
            .treatment = .{
                .main_turn_tokens = 120,
                .reflection = .{
                    .reflection_estimated_tokens = 30,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 1,
                    .reflection_turn_invocations = 1,
                    .recalled_lesson = true,
                },
                .turn_a_saved = true,
                .turn_b_recalled_lesson = true,
                .loop_closed = true,
            },
            .expect_any = false,
            .expect_reflection_no_save = false,
            .expect_loop_never_closed = false,
            .expect_no_arm_difference = false,
            .expect_token_blowup = false,
            .ratio_expect = .{ .approx = 1.5 },
        },
        .{
            .name = "reflection_no_save",
            .baseline = .{
                .main_turn_tokens = 50,
                .reflection = empty_refl,
                .turn_a_saved = false,
                .turn_b_recalled_lesson = false,
                .loop_closed = false,
            },
            .treatment = .{
                .main_turn_tokens = 60,
                .reflection = .{
                    .reflection_estimated_tokens = 10,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 1,
                },
                .turn_a_saved = false,
                .turn_b_recalled_lesson = false,
                .loop_closed = false,
            },
            .expect_any = true,
            .expect_reflection_no_save = true,
            .expect_loop_never_closed = false,
            .expect_no_arm_difference = false,
            .expect_token_blowup = false,
        },
        .{
            .name = "loop_never_closed",
            .baseline = .{
                .main_turn_tokens = 50,
                .reflection = empty_refl,
                .turn_a_saved = false,
                .turn_b_recalled_lesson = false,
                .loop_closed = false,
            },
            .treatment = .{
                .main_turn_tokens = 60,
                .reflection = .{
                    .reflection_estimated_tokens = 10,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 1,
                    .reflection_turn_invocations = 1,
                },
                .turn_a_saved = true,
                .turn_b_recalled_lesson = false,
                .loop_closed = false,
            },
            .expect_any = true,
            .expect_reflection_no_save = false,
            .expect_loop_never_closed = true,
            .expect_no_arm_difference = false,
            .expect_token_blowup = false,
        },
        .{
            .name = "no_arm_difference",
            .baseline = .{
                .main_turn_tokens = 80,
                .reflection = empty_refl,
                .turn_a_saved = true,
                .turn_b_recalled_lesson = true,
                .loop_closed = true,
            },
            .treatment = .{
                .main_turn_tokens = 90,
                .reflection = .{
                    .reflection_estimated_tokens = 10,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 1,
                    .reflection_turn_invocations = 1,
                    .recalled_lesson = true,
                },
                .turn_a_saved = true,
                .turn_b_recalled_lesson = true,
                .loop_closed = true,
            },
            .expect_any = true,
            .expect_reflection_no_save = false,
            .expect_loop_never_closed = false,
            .expect_no_arm_difference = true,
            .expect_token_blowup = false,
        },
        .{
            .name = "token_blowup",
            .class = .simple_qa,
            .baseline = .{
                .main_turn_tokens = 100,
                .reflection = empty_refl,
            },
            .treatment = .{
                .main_turn_tokens = 250,
                .reflection = .{
                    .reflection_estimated_tokens = 100,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 0,
                },
            },
            .opts = .{ .token_blowup_factor = 3.0 },
            .expect_any = true,
            .expect_reflection_no_save = false,
            .expect_loop_never_closed = false,
            .expect_no_arm_difference = false,
            .expect_token_blowup = true,
            .ratio_expect = .{ .approx = 3.5 },
        },
        .{
            .name = "baseline_zero",
            .class = .simple_qa,
            .baseline = .{
                .main_turn_tokens = 0,
                .reflection = empty_refl,
            },
            .treatment = .{
                .main_turn_tokens = 50,
                .reflection = .{
                    .reflection_estimated_tokens = 50,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 0,
                },
            },
            .expect_any = false,
            .expect_reflection_no_save = false,
            .expect_loop_never_closed = false,
            .expect_no_arm_difference = false,
            .expect_token_blowup = false,
            .ratio_expect = .is_null,
        },
    };

    for (cases) |c| {
        const results = [_]CanaryInputResult{.{
            .class = c.class,
            .baseline = c.baseline,
            .treatment = c.treatment,
        }};
        const eval = evaluateKillSignals(&results, c.opts);

        try std.testing.expectEqual(c.expect_any, eval.any());
        try std.testing.expectEqual(c.expect_reflection_no_save, eval.reflection_no_save);
        try std.testing.expectEqual(c.expect_loop_never_closed, eval.loop_never_closed);
        try std.testing.expectEqual(c.expect_no_arm_difference, eval.no_arm_difference);
        try std.testing.expectEqual(c.expect_token_blowup, eval.token_blowup);

        switch (c.ratio_expect) {
            .skip => {},
            .is_null => try std.testing.expect(eval.token_blowup_ratio == null),
            .approx => |expected_ratio| {
                try std.testing.expect(eval.token_blowup_ratio != null);
                try std.testing.expectApproxEqAbs(expected_ratio, eval.token_blowup_ratio.?, 0.001);
            },
        }
    }
}

test "buildMetricsSummary includes token and kill-signal info" {
    const allocator = std.testing.allocator;

    const results = [_]CanaryInputResult{
        .{
            .class = .tool_failure,
            .baseline = .{
                .reflection = .{
                    .reflection_estimated_tokens = 50,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 0,
                },
                .lesson_count = 0,
            },
            .treatment = .{
                .reflection = .{
                    .reflection_estimated_tokens = 200,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 1,
                    .reflection_lessons_saved = 1,
                    .reflection_turn_invocations = 1,
                },
                .lesson_count = 1,
            },
        },
        .{
            .class = .simple_qa,
            .baseline = .{
                .reflection = .{
                    .reflection_estimated_tokens = 30,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 0,
                },
            },
            .treatment = .{
                .reflection = .{
                    .reflection_estimated_tokens = 90,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 0,
                },
            },
        },
    };

    const kills: KillSignalEvaluation = .{
        .token_blowup = true,
        .token_blowup_ratio = 3.5,
    };

    const report: CanaryReport = .{
        .results = &results,
        .kills = kills,
    };

    const summary = try buildMetricsSummary(allocator, report);
    defer allocator.free(summary);

    try std.testing.expect(summary.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, summary, "token") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "50") != null or std.mem.indexOf(u8, summary, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "token_blowup") != null or std.mem.indexOf(u8, summary, "blowup") != null);
}

test "buildMetricsSummary renders v2 loop outcome fields" {
    const allocator = std.testing.allocator;

    const results = [_]CanaryInputResult{
        .{
            .class = .memory_dependent,
            .baseline = .{
                .reflection = .{
                    .reflection_estimated_tokens = 50,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 0,
                },
                .main_turn_tokens = 100,
                .turn_a_saved = false,
                .turn_b_recalled_lesson = false,
                .loop_closed = false,
            },
            .treatment = .{
                .reflection = .{
                    .reflection_estimated_tokens = 80,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 1,
                    .reflection_turn_invocations = 1,
                },
                .main_turn_tokens = 120,
                .turn_a_saved = true,
                .turn_b_recalled_lesson = true,
                .loop_closed = true,
            },
        },
    };

    const report: CanaryReport = .{
        .results = &results,
        .kills = .{},
    };

    const summary = try buildMetricsSummary(allocator, report);
    defer allocator.free(summary);

    // GREEN impl (commit 3) must render these exact field labels per arm.
    try std.testing.expect(std.mem.indexOf(u8, summary, "turn_a_saved") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "turn_b_recalled_lesson") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "loop_closed") != null);

    // Both arms' bool values must appear (baseline false, treatment true).
    try std.testing.expect(std.mem.indexOf(u8, summary, "turn_a_saved=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "turn_a_saved=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "loop_closed=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "loop_closed=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "turn_b_recalled_lesson=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "turn_b_recalled_lesson=true") != null);
}

test "buildMetricsSummary total tokens include main-turn tokens" {
    const allocator = std.testing.allocator;

    const results = [_]CanaryInputResult{
        .{
            .class = .memory_dependent,
            .baseline = .{
                .reflection = .{
                    .reflection_estimated_tokens = 0,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 0,
                },
                .main_turn_tokens = 400,
                .turn_a_saved = false,
                .turn_b_recalled_lesson = false,
                .loop_closed = false,
            },
            .treatment = .{
                .reflection = .{
                    .reflection_estimated_tokens = 30,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 1,
                    .reflection_turn_invocations = 1,
                },
                .main_turn_tokens = 500,
                .turn_a_saved = true,
                .turn_b_recalled_lesson = true,
                .loop_closed = true,
            },
        },
    };

    const report: CanaryReport = .{
        .results = &results,
        .kills = .{},
    };

    const summary = try buildMetricsSummary(allocator, report);
    defer allocator.free(summary);

    // Total lines must sum main_turn_tokens + reflection_estimated_tokens (same basis as token_blowup).
    // Treatment: 500 + 30 = 530; baseline: 400 + 0 = 400.
    try std.testing.expect(std.mem.indexOf(u8, summary, "530") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Total baseline tokens: 400") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Total treatment tokens: 530") != null);
}

test "buildMetricsSummary handles empty results" {
    const allocator = std.testing.allocator;

    const report: CanaryReport = .{
        .results = &.{},
        .kills = .{},
    };

    const summary = try buildMetricsSummary(allocator, report);
    defer allocator.free(summary);

    try std.testing.expect(summary.len > 0);
}
