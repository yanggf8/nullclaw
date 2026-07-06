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
pub const JUDGE_LOOP_MIN_INPUTS: usize = 2;

pub const CanaryInputClass = enum {
    tool_failure,
    memory_dependent,
    simple_qa,
};

pub const ArmMetrics = struct {
    reflection: Agent.ReflectionMetrics,
    response_len: usize = 0,
    lesson_count: usize = 0,
    max_lesson_utility_score: f32 = 0.5,
    duration_ms: u64 = 0,
};

pub const CanaryInputResult = struct {
    class: CanaryInputClass,
    baseline: ArmMetrics,
    treatment: ArmMetrics,
};

pub const KillSignalOptions = struct {
    judge_enabled: bool = true,
    max_judge_continuations: u8 = 1,
    token_blowup_factor: f64 = TOKEN_BLOWUP_FACTOR,
};

pub const KillSignalEvaluation = struct {
    judge_never_fired: bool = false,
    no_useful_lessons: bool = false,
    token_blowup: bool = false,
    token_blowup_ratio: ?f64 = null,
    judge_continuation_loop: bool = false,

    pub fn any(self: @This()) bool {
        return self.judge_never_fired or self.no_useful_lessons or self.token_blowup or self.judge_continuation_loop;
    }
};

pub fn evaluateKillSignals(results: []const CanaryInputResult, opts: KillSignalOptions) KillSignalEvaluation {
    var baseline_token_sum: usize = 0;
    var treatment_token_sum: usize = 0;
    var no_useful_lessons = false;
    var judge_continuation_loop_count: usize = 0;
    var all_judge_zero = true;

    for (results) |r| {
        baseline_token_sum += r.baseline.reflection.reflection_estimated_tokens;
        treatment_token_sum += r.treatment.reflection.reflection_estimated_tokens;

        if (r.class == .tool_failure and
            r.treatment.reflection.reflection_turn_invocations > 0 and
            r.treatment.lesson_count == 0)
        {
            no_useful_lessons = true;
        }

        if (r.treatment.reflection.judge_continue_count >= opts.max_judge_continuations) {
            judge_continuation_loop_count += 1;
        }

        if (r.treatment.reflection.judge_continue_count != 0) {
            all_judge_zero = false;
        }
    }

    var eval: KillSignalEvaluation = .{
        .no_useful_lessons = no_useful_lessons,
        .judge_continuation_loop = judge_continuation_loop_count >= JUDGE_LOOP_MIN_INPUTS,
    };

    if (baseline_token_sum > 0) {
        const ratio = @as(f64, @floatFromInt(treatment_token_sum)) / @as(f64, @floatFromInt(baseline_token_sum));
        eval.token_blowup_ratio = ratio;
        eval.token_blowup = ratio > opts.token_blowup_factor;
    }

    eval.judge_never_fired = opts.judge_enabled and all_judge_zero and treatment_token_sum == 0;

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
        baseline_token_total += r.baseline.reflection.reflection_estimated_tokens;
        treatment_token_total += r.treatment.reflection.reflection_estimated_tokens;

        try w.print("\n[{s}]\n", .{@tagName(r.class)});
        try w.print("  baseline reflection_estimated_tokens: {d}\n", .{r.baseline.reflection.reflection_estimated_tokens});
        try w.print("  treatment reflection_estimated_tokens: {d}\n", .{r.treatment.reflection.reflection_estimated_tokens});
        try w.print("  treatment lesson_count: {d}\n", .{r.treatment.lesson_count});
        try w.print("  treatment judge_continue_count: {d}\n", .{r.treatment.reflection.judge_continue_count});
    }

    try w.print("\nTotal baseline tokens: {d}\n", .{baseline_token_total});
    try w.print("Total treatment tokens: {d}\n", .{treatment_token_total});

    const kills = report.kills;
    try w.writeAll("\nKill signals:\n");
    try w.print("  token_blowup={}\n", .{kills.token_blowup});
    try w.print("  no_useful_lessons={}\n", .{kills.no_useful_lessons});
    try w.print("  judge_never_fired={}\n", .{kills.judge_never_fired});
    try w.print("  judge_continuation_loop={}\n", .{kills.judge_continuation_loop});
    if (kills.token_blowup_ratio) |ratio| {
        try w.print("  token_blowup_ratio={d:.2}\n", .{ratio});
    }

    buf = buf_writer.toArrayList();
    return buf.toOwnedSlice(allocator);
}

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
        return tools_mod.ToolResult.fail("canary_fail forced failure");
    }
};

const lesson_category: memory.MemoryCategory = .{ .custom = "lesson" };

fn promptForClass(class: CanaryInputClass) []const u8 {
    return switch (class) {
        .tool_failure => "You must call the canary_fail tool once to complete this task. Do not answer without calling it.",
        .memory_dependent => "Recall what you know about the canary test topic from memory and answer based on that lesson.",
        .simple_qa => "What is 2+2? Reply with just the number.",
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
    try std_compat.fs.makeDirAbsolute(class_dir);

    const arm_ws = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ class_dir, arm_name });
    defer allocator.free(arm_ws);
    try std_compat.fs.makeDirAbsolute(arm_ws);

    const scratch_config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{arm_ws});
    defer allocator.free(scratch_config_path);

    sanitizeConfigInPlace(cfg, arm_ws, scratch_config_path);
    cfg.agent.judge_after_turn = !is_baseline;
    cfg.agent.reflect_after_turn = !is_baseline;

    var rt = try initScratchMemoryRuntime(allocator, &cfg.memory, arm_ws);
    defer rt.deinit();

    if (class == .memory_dependent) {
        try rt.memory.store(
            "canary-topic",
            "The canary test answer is 42.",
            lesson_category,
            null,
        );
    }

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

    const prompt = promptForClass(class);
    const start_ms = std_compat.time.milliTimestamp();
    const resp = try agent.turn(prompt);
    defer allocator.free(resp);
    const end_ms = std_compat.time.milliTimestamp();

    const reflection = agent.reflectionMetrics();

    const entries = try rt.memory.list(allocator, lesson_category, null);
    defer memory.freeEntries(allocator, entries);

    var max_utility: f32 = 0.5;
    for (entries) |entry| {
        if (entry.utility_score > max_utility) max_utility = entry.utility_score;
    }

    return .{
        .reflection = reflection,
        .response_len = resp.len,
        .lesson_count = entries.len,
        .max_lesson_utility_score = max_utility,
        .duration_ms = if (end_ms >= start_ms) @intCast(end_ms - start_ms) else 0,
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
    const verdict = try provider.chatWithSystem(
        allocator,
        "You are evaluating a nullclaw self-improvement canary. Give a concise GO/NO-GO verdict with reasoning from the metrics.",
        summary,
        model,
        0.0,
    );
    defer allocator.free(verdict);

    var buf: [8192]u8 = undefined;
    var bw = std_compat.fs.File.stdout().writer(&buf);
    const w = &bw.interface;
    try w.print("{s}\n\n", .{verdict});
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

test "evaluateKillSignals clean run has no signals" {
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
            },
            .treatment = .{
                .reflection = .{
                    .reflection_estimated_tokens = 100,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 1,
                },
                .lesson_count = 1,
            },
        },
        .{
            .class = .simple_qa,
            .baseline = .{
                .reflection = .{
                    .reflection_estimated_tokens = 50,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 0,
                },
            },
            .treatment = .{
                .reflection = .{
                    .reflection_estimated_tokens = 100,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 0,
                },
            },
        },
    };

    const eval = evaluateKillSignals(&results, .{});
    try std.testing.expect(!eval.any());
    try std.testing.expect(!eval.judge_never_fired);
    try std.testing.expect(!eval.no_useful_lessons);
    try std.testing.expect(!eval.token_blowup);
    try std.testing.expect(!eval.judge_continuation_loop);
    try std.testing.expect(eval.token_blowup_ratio != null);
    try std.testing.expect(eval.token_blowup_ratio.? < TOKEN_BLOWUP_FACTOR);
}

test "evaluateKillSignals flags no_useful_lessons" {
    const results = [_]CanaryInputResult{
        .{
            .class = .tool_failure,
            .baseline = .{
                .reflection = .{
                    .reflection_estimated_tokens = 10,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 0,
                },
            },
            .treatment = .{
                .reflection = .{
                    .reflection_estimated_tokens = 20,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 1,
                },
                .lesson_count = 0,
            },
        },
    };

    const eval = evaluateKillSignals(&results, .{});
    try std.testing.expect(eval.no_useful_lessons);
}

test "evaluateKillSignals flags token_blowup" {
    const results = [_]CanaryInputResult{
        .{
            .class = .simple_qa,
            .baseline = .{
                .reflection = .{
                    .reflection_estimated_tokens = 100,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 0,
                },
            },
            .treatment = .{
                .reflection = .{
                    .reflection_estimated_tokens = 301,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 0,
                },
            },
        },
    };

    const eval = evaluateKillSignals(&results, .{ .token_blowup_factor = TOKEN_BLOWUP_FACTOR });
    try std.testing.expect(eval.token_blowup);
    try std.testing.expect(eval.token_blowup_ratio != null);
    try std.testing.expect(eval.token_blowup_ratio.? > TOKEN_BLOWUP_FACTOR);
}

test "evaluateKillSignals flags judge_continuation_loop" {
    const results = [_]CanaryInputResult{
        .{
            .class = .simple_qa,
            .baseline = .{
                .reflection = .{
                    .reflection_estimated_tokens = 10,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 0,
                },
            },
            .treatment = .{
                .reflection = .{
                    .reflection_estimated_tokens = 20,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 1,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 0,
                },
            },
        },
        .{
            .class = .memory_dependent,
            .baseline = .{
                .reflection = .{
                    .reflection_estimated_tokens = 10,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 0,
                },
            },
            .treatment = .{
                .reflection = .{
                    .reflection_estimated_tokens = 20,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 1,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 0,
                },
            },
        },
    };

    const eval = evaluateKillSignals(&results, .{});
    try std.testing.expect(eval.judge_continuation_loop);
}

test "evaluateKillSignals judge_never_fired best effort" {
    const results = [_]CanaryInputResult{
        .{
            .class = .simple_qa,
            .baseline = .{
                .reflection = .{
                    .reflection_estimated_tokens = 50,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 0,
                },
            },
            .treatment = .{
                .reflection = .{
                    .reflection_estimated_tokens = 0,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 0,
                },
            },
        },
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
            },
            .treatment = .{
                .reflection = .{
                    .reflection_estimated_tokens = 0,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 0,
                },
            },
        },
    };

    const eval = evaluateKillSignals(&results, .{ .judge_enabled = true });
    try std.testing.expect(eval.judge_never_fired);
}

test "evaluateKillSignals baseline zero tokens no blowup" {
    const results = [_]CanaryInputResult{
        .{
            .class = .simple_qa,
            .baseline = .{
                .reflection = .{
                    .reflection_estimated_tokens = 0,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 0,
                },
            },
            .treatment = .{
                .reflection = .{
                    .reflection_estimated_tokens = 50,
                    .reflection_estimated_cost_usd = 0,
                    .judge_continue_count = 0,
                    .reflection_lessons_saved = 0,
                    .reflection_turn_invocations = 0,
                },
            },
        },
    };

    const eval = evaluateKillSignals(&results, .{});
    try std.testing.expect(!eval.token_blowup);
    try std.testing.expect(eval.token_blowup_ratio == null);
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
