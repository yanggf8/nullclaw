// src/agent/reflection.zig
//
// After-turn reflection pass (slice 2: pure module, no turn wiring yet).
// Stub bodies return trivial values so the tests below compile and fail on
// assertions (true RED); the real logic is filled in by the implementer.

const std = @import("std");
const providers = @import("../providers/root.zig");
const Provider = providers.Provider;

pub const FailureClass = enum { none, policy, transient, logic, user_input };

pub const ReflectionResult = struct {
    worth_saving: bool,
    lesson: []const u8,
    failure_class: FailureClass,
};

pub const ToolSummary = struct {
    name: []const u8,
    ok: bool,
    brief: []const u8,
};

pub const ReflectionContext = struct {
    user_goal: []const u8,
    tools: []const ToolSummary,
    final_text: []const u8,
    iteration: usize,
};

pub const MAX_PROMPT_BYTES: usize = 8192;
pub const MAX_RESPONSE_BYTES: usize = 4096;
pub const MAX_LESSON_BYTES: usize = 512;
pub const MAX_LESSONS_PER_SESSION: usize = 8;
pub const LESSON_CATEGORY = "lesson";

pub fn parseReflectionResult(arena: std.mem.Allocator, json_bytes: []const u8) ?ReflectionResult {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, json_bytes, .{}) catch return null;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };

    const worth_v = obj.get("worth_saving") orelse return null;
    const worth_saving = switch (worth_v) {
        .bool => |b| b,
        else => return null,
    };

    const lesson_v = obj.get("lesson") orelse return null;
    const lesson_raw = switch (lesson_v) {
        .string => |s| s,
        else => return null,
    };

    const fc_v = obj.get("failure_class") orelse return null;
    const fc_raw = switch (fc_v) {
        .string => |s| s,
        else => return null,
    };

    const failure_class = std.meta.stringToEnum(FailureClass, fc_raw) orelse return null;

    const lesson = arena.dupe(u8, lesson_raw) catch return null;
    return ReflectionResult{
        .worth_saving = worth_saving,
        .lesson = lesson,
        .failure_class = failure_class,
    };
}

pub fn sanitizeLesson(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var buf: [MAX_LESSON_BYTES]u8 = undefined;
    var i: usize = 0;
    for (raw) |c| {
        if (c < 0x20) continue;
        if (i >= MAX_LESSON_BYTES) break;
        buf[i] = c;
        i += 1;
    }
    return arena.dupe(u8, buf[0..i]);
}

pub fn lessonPassesQualityGate(lesson: []const u8) bool {
    const trimmed = std.mem.trim(u8, lesson, " \t\r\n");
    if (trimmed.len < 12) return false;
    const generic_phrases = [_][]const u8{ "try again", "retry", "error", "failed", "none" };
    for (generic_phrases) |g| {
        if (std.mem.eql(u8, trimmed, g)) return false;
    }
    return true;
}

pub fn buildReflectionPrompt(arena: std.mem.Allocator, ctx: ReflectionContext) ![]const u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(arena);

    try list.appendSlice(arena, "You are judging an agent turn for a lesson worth remembering.\n");
    try list.appendSlice(arena, "User goal: ");
    try list.appendSlice(arena, ctx.user_goal);
    try list.appendSlice(arena, "\n");
    try list.appendSlice(arena, "Tools used this turn:\n");
    for (ctx.tools) |tool| {
        try list.appendSlice(arena, "  - ");
        try list.appendSlice(arena, tool.name);
        try list.appendSlice(arena, ": ");
        try list.appendSlice(arena, if (tool.ok) "ok" else "fail");
        try list.appendSlice(arena, " (");
        try list.appendSlice(arena, tool.brief);
        try list.appendSlice(arena, ")\n");
    }
    try list.appendSlice(arena, "Short outcome: ");
    const max_outcome: usize = 256;
    const outcome = if (ctx.final_text.len > max_outcome) ctx.final_text[0..max_outcome] else ctx.final_text;
    try list.appendSlice(arena, outcome);
    if (ctx.final_text.len > max_outcome) {
        try list.appendSlice(arena, "...");
    }
    try list.appendSlice(arena, "\n\nReply ONLY with this exact JSON shape (no extra text):\n");
    try list.appendSlice(arena, "{\"worth_saving\": <true|false>, \"lesson\": \"<brief lesson>\", \"failure_class\": \"none|policy|transient|logic|user_input\"}\n");

    const final_slice = if (list.items.len > MAX_PROMPT_BYTES) list.items[0..MAX_PROMPT_BYTES] else list.items;
    const owned = try arena.dupe(u8, final_slice);
    list.deinit(arena);
    return owned;
}

pub fn reflectOnTurn(
    arena: std.mem.Allocator,
    provider: Provider,
    model: []const u8,
    ctx: ReflectionContext,
) !?ReflectionResult {
    const prompt = try buildReflectionPrompt(arena, ctx);
    const response = provider.chatWithSystem(arena, null, prompt, model, 0.0) catch {
        return null;
    };
    const capped_len = @min(response.len, MAX_RESPONSE_BYTES);
    const capped = response[0..capped_len];
    return parseReflectionResult(arena, capped);
}

// ── tests ────────────────────────────────────────────────────────────

const ReflectionMockProvider = struct {
    response: ?[]const u8 = null,
    fail: bool = false,
    calls: usize = 0,
    captured_model: ?[]const u8 = null,

    fn provider(self: *ReflectionMockProvider) Provider {
        return Provider{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn chatWithSystem(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: ?[]const u8,
        _: []const u8,
        model: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        const self: *ReflectionMockProvider = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        self.captured_model = model;
        if (self.fail) return error.MockProviderFailure;
        return allocator.dupe(u8, self.response orelse "{}");
    }

    fn chat(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: providers.ChatRequest,
        _: []const u8,
        _: f64,
    ) anyerror!providers.ChatResponse {
        return .{ .content = try allocator.dupe(u8, "") };
    }

    fn supportsNativeTools(_: *anyopaque) bool {
        return false;
    }

    fn getName(_: *anyopaque) []const u8 {
        return "reflection-mock-provider";
    }

    fn deinit(_: *anyopaque) void {}

    const vtable = Provider.VTable{
        .chatWithSystem = chatWithSystem,
        .chat = chat,
        .supportsNativeTools = supportsNativeTools,
        .getName = getName,
        .deinit = deinit,
    };
};

const valid_verdict =
    \\{"worth_saving":true,"lesson":"Prefer bounded retries for transient provider failures.","failure_class":"logic"}
;

test "reflection_module_lesson_category_is_lesson" {
    try std.testing.expectEqualStrings("lesson", LESSON_CATEGORY);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // RED: parseReflectionResult is a stub and returns null for valid JSON.
    try std.testing.expect(parseReflectionResult(arena.allocator(), valid_verdict) != null);
}

test "reflection_module_failure_class_rejects_unknown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // RED: parseReflectionResult is a stub, so the valid sanity check fails first.
    try std.testing.expect(parseReflectionResult(arena.allocator(), valid_verdict) != null);
    try std.testing.expect(parseReflectionResult(arena.allocator(),
        \\{"worth_saving":true,"lesson":"A specific lesson.","failure_class":"bogus"}
    ) == null);
}

test "reflection_module_parses_valid_verdict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // RED: parseReflectionResult is a stub and returns null.
    const result_opt = parseReflectionResult(arena.allocator(), valid_verdict);
    try std.testing.expect(result_opt != null);

    const result = result_opt.?;
    try std.testing.expect(result.worth_saving);
    try std.testing.expectEqualStrings("Prefer bounded retries for transient provider failures.", result.lesson);
    try std.testing.expectEqual(FailureClass.logic, result.failure_class);
}

test "reflection_module_malformed_json_returns_null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // RED: parseReflectionResult is a stub, so the valid sanity check fails first.
    try std.testing.expect(parseReflectionResult(arena.allocator(), valid_verdict) != null);
    try std.testing.expect(parseReflectionResult(arena.allocator(), "{not-json") == null);
}

test "reflection_module_caps_and_sanitizes_lesson" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw = try arena.allocator().alloc(u8, MAX_LESSON_BYTES + 32);
    @memset(raw, 'a');
    raw[3] = 0x01;
    raw[7] = '\n';

    const sanitized = try sanitizeLesson(arena.allocator(), raw);

    // RED: sanitizeLesson is a stub and returns the oversized raw input.
    try std.testing.expect(sanitized.len <= MAX_LESSON_BYTES);
    try std.testing.expect(std.mem.indexOfScalar(u8, sanitized, 0x01) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, sanitized, '\n') == null);
}

test "reflection_module_quality_gate_rejects_generic" {
    // RED: lessonPassesQualityGate is a stub and returns true.
    try std.testing.expect(!lessonPassesQualityGate("try again"));
}

test "reflection_module_build_prompt_is_compact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const huge_final_text = try arena.allocator().alloc(u8, MAX_PROMPT_BYTES * 2);
    @memset(huge_final_text, 'x');

    const tool_summaries = [_]ToolSummary{
        .{ .name = "shell", .ok = true, .brief = "listed files" },
        .{ .name = "edit", .ok = false, .brief = "patch rejected" },
    };

    const ctx = ReflectionContext{
        .user_goal = "fix the failing reflection tests",
        .tools = tool_summaries[0..],
        .final_text = huge_final_text,
        .iteration = 2,
    };

    const prompt = try buildReflectionPrompt(arena.allocator(), ctx);

    try std.testing.expect(prompt.len <= MAX_PROMPT_BYTES);
    try std.testing.expect(std.mem.indexOf(u8, prompt, huge_final_text) == null);

    // RED: buildReflectionPrompt is a stub and returns an empty string.
    try std.testing.expect(std.mem.indexOf(u8, prompt, ctx.user_goal) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "shell") != null);
}

test "reflection_module_reflect_on_turn_parses_via_mock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var mock = ReflectionMockProvider{ .response = valid_verdict };
    const ctx = ReflectionContext{ .user_goal = "ship slice 2", .tools = &.{}, .final_text = "done", .iteration = 1 };

    // RED: reflectOnTurn is a stub and returns null.
    const result_opt = try reflectOnTurn(arena.allocator(), mock.provider(), "test-model", ctx);
    try std.testing.expect(result_opt != null);

    const result = result_opt.?;
    try std.testing.expect(result.worth_saving);
    try std.testing.expectEqualStrings("Prefer bounded retries for transient provider failures.", result.lesson);
    try std.testing.expectEqual(FailureClass.logic, result.failure_class);
}

test "reflection_module_reflect_on_turn_null_on_provider_error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var mock = ReflectionMockProvider{ .fail = true };
    const ctx = ReflectionContext{ .user_goal = "ship slice 2", .tools = &.{}, .final_text = "done", .iteration = 1 };

    const result = try reflectOnTurn(arena.allocator(), mock.provider(), "test-model", ctx);

    // RED: reflectOnTurn is a stub and never calls the provider.
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
    try std.testing.expect(result == null);
}

test "reflection_module_reflect_on_turn_null_on_bad_verdict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var mock = ReflectionMockProvider{ .response = "{not-json" };
    const ctx = ReflectionContext{ .user_goal = "ship slice 2", .tools = &.{}, .final_text = "done", .iteration = 1 };

    const result = try reflectOnTurn(arena.allocator(), mock.provider(), "test-model", ctx);

    // RED: reflectOnTurn is a stub and never calls the provider.
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
    try std.testing.expect(result == null);
}

test "reflection_module_reflect_on_turn_honors_model" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var mock = ReflectionMockProvider{ .response = valid_verdict };
    const ctx = ReflectionContext{ .user_goal = "ship slice 2", .tools = &.{}, .final_text = "done", .iteration = 1 };

    _ = try reflectOnTurn(arena.allocator(), mock.provider(), "reflection-model", ctx);

    // RED: reflectOnTurn is a stub and never forwards the model to the provider.
    try std.testing.expectEqualStrings("reflection-model", mock.captured_model orelse "");
}
