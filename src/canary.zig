//! Canary isolation — scratch memory safety boundary.
//! Commit 2 (RED): tests only; sanitizeConfigInPlace / assertScratchDbPath /
//! initScratchMemoryRuntime and MemoryRuntime.primaryDbPath() land in commit 3.

const std = @import("std");
const std_compat = @import("compat");
const build_options = @import("build_options");
const Agent = @import("agent/root.zig").Agent;
const Config = @import("config.zig").Config;
const MemoryConfig = @import("config_types.zig").MemoryConfig;
const memory = @import("memory/root.zig");
const MemoryRuntime = memory.MemoryRuntime;

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
