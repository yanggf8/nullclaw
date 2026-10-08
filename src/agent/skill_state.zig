//! Opt-in structured execution state for CLI skill sessions.
//!
//! Each turn sends the skill policy, the validated state, and the latest
//! observation. The ordinary Agent tool loop still mediates tool calls. The
//! final model reply must contain a state patch; no patch reaches disk until
//! its keys and value types pass the skill's schema.

const std = @import("std");
const fs_compat = @import("../fs_compat.zig");
const compat_io = @import("compat");
const Agent = @import("root.zig").Agent;

const MAX_SCHEMA_BYTES = 32 * 1024;
const MAX_CHECKPOINT_BYTES = 64 * 1024;
const MAX_STATE_BYTES = 16 * 1024;
const MAX_OBSERVATION_BYTES = 16 * 1024;

const Paths = struct {
    dir: []const u8,
    checkpoint: []const u8,
    observations: []const u8,
    lock: []const u8,
};

fn makePaths(allocator: std.mem.Allocator, workspace: []const u8, skill: []const u8, session: []const u8) !Paths {
    var hash: [32]u8 = undefined;
    const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ skill, session });
    defer allocator.free(key);
    std.crypto.hash.sha2.Sha256.hash(key, &hash, .{});
    const hex = std.fmt.bytesToHex(hash, .lower);
    const dir = try std.fs.path.join(allocator, &.{ workspace, "skill-state" });
    const stem = try std.fs.path.join(allocator, &.{ dir, &hex });
    return .{
        .dir = dir,
        .checkpoint = try std.fmt.allocPrint(allocator, "{s}.json", .{stem}),
        .observations = try std.fmt.allocPrint(allocator, "{s}.jsonl", .{stem}),
        .lock = try std.fmt.allocPrint(allocator, "{s}.lock", .{stem}),
    };
}

fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |v| v,
        else => error.InvalidSkillStateJson,
    };
}

fn schemaFields(schema: std.json.Value) !std.json.ObjectMap {
    const root = try object(schema);
    const version = root.get("version") orelse return error.InvalidSkillStateSchema;
    if (version != .integer or version.integer != 1) return error.UnsupportedSkillStateSchema;
    const fields = root.get("fields") orelse return error.InvalidSkillStateSchema;
    const map = try object(fields);
    if (map.count() == 0 or map.count() > 64) return error.InvalidSkillStateSchema;
    var it = map.iterator();
    while (it.next()) |entry| {
        const kind = switch (entry.value_ptr.*) {
            .string => |s| s,
            else => return error.InvalidSkillStateSchema,
        };
        if (!validKind(kind)) return error.InvalidSkillStateSchema;
    }
    return map;
}

fn validKind(kind: []const u8) bool {
    for ([_][]const u8{ "string", "integer", "number", "boolean", "object", "array" }) |allowed| {
        if (std.mem.eql(u8, kind, allowed)) return true;
    }
    return false;
}

fn matchesKind(kind: []const u8, value: std.json.Value) bool {
    if (std.mem.eql(u8, kind, "string")) return value == .string;
    if (std.mem.eql(u8, kind, "integer")) return value == .integer;
    if (std.mem.eql(u8, kind, "number")) return value == .integer or value == .float or value == .number_string;
    if (std.mem.eql(u8, kind, "boolean")) return value == .bool;
    if (std.mem.eql(u8, kind, "object")) return value == .object;
    if (std.mem.eql(u8, kind, "array")) return value == .array;
    return false;
}

fn validateAndApply(allocator: std.mem.Allocator, fields: std.json.ObjectMap, state: *std.json.ObjectMap, patch: std.json.Value) !void {
    const changes = try object(patch);
    var it = changes.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const expected = fields.get(key) orelse return error.UnknownSkillStateField;
        if (entry.value_ptr.* != .null and !matchesKind(expected.string, entry.value_ptr.*)) {
            return error.InvalidSkillStateValue;
        }
    }
    it = changes.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .null) {
            _ = state.swapRemove(entry.key_ptr.*);
        } else {
            try state.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    const encoded = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = state.* }, .{});
    if (encoded.len > MAX_STATE_BYTES) return error.SkillStateTooLarge;
}

fn loadState(allocator: std.mem.Allocator, path: []const u8, digest: []const u8) !std.json.ObjectMap {
    const bytes = fs_compat.readFileAlloc(@import("compat").fs.cwd(), allocator, path, MAX_CHECKPOINT_BYTES) catch |err| switch (err) {
        error.FileNotFound => return .empty,
        else => return err,
    };
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    const root = try object(parsed.value);
    const saved_digest = root.get("schema_sha256") orelse return error.InvalidSkillStateCheckpoint;
    if (saved_digest != .string or !std.mem.eql(u8, saved_digest.string, digest)) return error.SkillStateSchemaChanged;
    return try object(root.get("state") orelse return error.InvalidSkillStateCheckpoint);
}

fn saveState(allocator: std.mem.Allocator, path: []const u8, digest: []const u8, state: std.json.ObjectMap) !void {
    const data = try std.json.Stringify.valueAlloc(allocator, .{
        .schema_sha256 = digest,
        .state = std.json.Value{ .object = state },
    }, .{});
    if (data.len > MAX_CHECKPOINT_BYTES) return error.SkillStateTooLarge;
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    {
        const file = try fs_compat.createPath(tmp, .{ .truncate = true });
        defer file.close();
        try file.chmod(0o600);
        try file.writeAll(data);
        try file.sync();
    }
    try fs_compat.renamePath(tmp, path);
}

fn appendObservation(allocator: std.mem.Allocator, path: []const u8, kind: []const u8, text: []const u8) !void {
    if (text.len > MAX_OBSERVATION_BYTES) return error.SkillObservationTooLarge;
    const line = try std.json.Stringify.valueAlloc(allocator, .{ .kind = kind, .text = text }, .{});
    const file = try fs_compat.openPathForAppend(path);
    defer file.close();
    try file.chmod(0o600);
    try file.seekFromEnd(0);
    try file.writeAll(line);
    try file.writeAll("\n");
    try file.sync();
}

fn discardPromptHistory(agent: *Agent) void {
    for (agent.history.items) |*message| message.deinit(agent.allocator);
    agent.history.items.len = 0;
    agent.has_system_prompt = false;
    agent.system_prompt_has_conversation_context = false;
    agent.system_prompt_conversation_context_fingerprint = null;
    agent.workspace_prompt_fingerprint = null;
    // Keep redactor mappings until the channel/CLI has rendered the reply.
}

/// Run one user turn through an active skill. The state file is keyed by both
/// skill name and session id; a lock denies concurrent CLI writers.
pub fn turn(agent: *Agent, session: []const u8, observation: []const u8) ![]const u8 {
    const skill_name = agent.active_skill_name orelse return error.SkillStateRequiresSkill;
    const skill_path = agent.active_skill_path orelse return error.SkillStateRequiresSkill;
    if (session.len == 0) return error.SkillStateRequiresSession;
    const instructions = agent.active_skill_instructions orelse return error.SkillStateRequiresSkill;
    var arena_state = std.heap.ArenaAllocator.init(agent.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const paths = try makePaths(arena, agent.workspace_dir, skill_name, session);
    try fs_compat.makePath(paths.dir);
    const lock = try fs_compat.createPath(paths.lock, .{ .truncate = false });
    var lock_acquired = false;
    defer {
        if (lock_acquired) lock.toInner().unlock(compat_io.io());
        lock.close();
    }
    try lock.chmod(0o600);
    if (!try lock.toInner().tryLock(compat_io.io(), .exclusive)) return error.SkillStateBusy;
    lock_acquired = true;

    const schema_path = try std.fs.path.join(arena, &.{ skill_path, "state-schema.json" });
    const schema_bytes = try fs_compat.readFileAlloc(@import("compat").fs.cwd(), arena, schema_path, MAX_SCHEMA_BYTES);
    const schema = try std.json.parseFromSlice(std.json.Value, arena, schema_bytes, .{});
    const fields = try schemaFields(schema.value);
    var digest_bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(schema_bytes, &digest_bytes, .{});
    const digest_hex = std.fmt.bytesToHex(digest_bytes, .lower);
    const digest = digest_hex[0..];
    var state = try loadState(arena, paths.checkpoint, digest);

    // The observation is durable before it can be reduced into state.
    try appendObservation(arena, paths.observations, "user", observation);
    const state_json = try std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = state }, .{});
    const prompt = try std.fmt.allocPrint(
        arena,
        "Execute the active skill using only its policy, current state, and latest observation. " ++
            "You may call available tools through the normal tool interface. At the end return ONLY a JSON object " ++
            "with keys patch (object) and reply (string). Patch only fields declared in the schema; null deletes a field. " ++
            "Keep information needed for future steps. Do not include prior reasoning in the reply.\n\n" ++
            "Skill policy:\n{s}\n\nState schema:\n{s}\n\nCurrent state:\n{s}\n\nLatest observation:\n{s}",
        .{ instructions, schema_bytes, state_json, observation },
    );

    // Prior turns never enter this prompt. The normal Agent loop can still use
    // tools within this bounded turn and applies its existing security policy.
    agent.clearHistory();
    defer discardPromptHistory(agent);
    const previous_usage_mode = agent.usage_mode;
    const previous_reasoning_mode = agent.reasoning_mode;
    const previous_judge = agent.judge_after_turn;
    const previous_reflect = agent.reflect_after_turn;
    agent.usage_mode = .off;
    agent.reasoning_mode = .off;
    agent.judge_after_turn = false;
    agent.reflect_after_turn = false;
    defer {
        agent.usage_mode = previous_usage_mode;
        agent.reasoning_mode = previous_reasoning_mode;
        agent.judge_after_turn = previous_judge;
        agent.reflect_after_turn = previous_reflect;
    }
    const raw = try agent.turn(prompt);
    defer agent.allocator.free(raw);
    try appendObservation(arena, paths.observations, "assistant", raw);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, raw, .{});
    const result = try object(parsed.value);
    const reply = result.get("reply") orelse return error.InvalidSkillStateReply;
    if (reply != .string) return error.InvalidSkillStateReply;
    const patch = result.get("patch") orelse return error.InvalidSkillStateReply;
    try validateAndApply(arena, fields, &state, patch);
    try saveState(arena, paths.checkpoint, digest, state);
    return try agent.allocator.dupe(u8, reply.string);
}

test "skill state patch validates fields and types" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const schema = try std.json.parseFromSlice(std.json.Value, arena, "{\"version\":1,\"fields\":{\"step\":\"integer\",\"note\":\"string\"}}", .{});
    const fields = try schemaFields(schema.value);
    var state: std.json.ObjectMap = .empty;
    const good = try std.json.parseFromSlice(std.json.Value, arena, "{\"step\":2,\"note\":\"ready\"}", .{});
    try validateAndApply(arena, fields, &state, good.value);
    try std.testing.expectEqual(@as(i64, 2), state.get("step").?.integer);
    const bad = try std.json.parseFromSlice(std.json.Value, arena, "{\"step\":\"two\"}", .{});
    try std.testing.expectError(error.InvalidSkillStateValue, validateAndApply(arena, fields, &state, bad.value));
    try std.testing.expectEqual(@as(i64, 2), state.get("step").?.integer);
    const unknown = try std.json.parseFromSlice(std.json.Value, arena, "{\"other\":1}", .{});
    try std.testing.expectError(error.UnknownSkillStateField, validateAndApply(arena, fields, &state, unknown.value));
}

test "skill state checkpoint roundtrip and schema pin" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const base = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(base);
    const path = try std.fs.path.join(a, &.{ base, "state.json" });
    defer a.free(path);

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state: std.json.ObjectMap = .empty;
    try state.put(arena, "step", .{ .integer = 3 });
    try saveState(arena, path, "schema-a", state);
    const loaded = try loadState(arena, path, "schema-a");
    try std.testing.expectEqual(@as(i64, 3), loaded.get("step").?.integer);
    try std.testing.expectError(error.SkillStateSchemaChanged, loadState(arena, path, "schema-b"));
}

test "skill state paths isolate skill and session" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try makePaths(arena, "/tmp/workspace", "inventory", "one");
    const b = try makePaths(arena, "/tmp/workspace", "inventory", "two");
    const c = try makePaths(arena, "/tmp/workspace", "other", "one");
    try std.testing.expect(!std.mem.eql(u8, a.checkpoint, b.checkpoint));
    try std.testing.expect(!std.mem.eql(u8, a.checkpoint, c.checkpoint));
    try std.testing.expect(std.mem.startsWith(u8, a.checkpoint, "/tmp/workspace/skill-state/"));
}

const TestProvider = struct {
    calls: usize = 0,
    saw_previous_state: bool = false,

    fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
        return allocator.dupe(u8, "");
    }
    fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, request: @import("../providers/root.zig").ChatRequest, _: []const u8, _: f64) anyerror!@import("../providers/root.zig").ChatResponse {
        const self: *TestProvider = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        for (request.messages) |message| {
            if (std.mem.indexOf(u8, message.content, "\"step\":1") != null) self.saw_previous_state = true;
        }
        return .{ .content = try allocator.dupe(u8, if (self.calls == 1)
            "{\"patch\":{\"step\":1},\"reply\":\"first\"}"
        else
            "{\"patch\":{\"step\":2},\"reply\":\"second\"}") };
    }
    fn supportsNativeTools(_: *anyopaque) bool {
        return false;
    }
    fn getName(_: *anyopaque) []const u8 {
        return "skill-state-test";
    }
    fn deinit(_: *anyopaque) void {}
    const vtable = @import("../providers/root.zig").Provider.VTable{
        .chatWithSystem = chatWithSystem,
        .chat = chat,
        .supportsNativeTools = supportsNativeTools,
        .getName = getName,
        .deinit = deinit,
    };
};

test "skill state turn persists a patch and sends it on the next turn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(base);
    const skill_dir = try std.fs.path.join(allocator, &.{ base, "skill" });
    defer allocator.free(skill_dir);
    try fs_compat.makePath(skill_dir);
    const schema_path = try std.fs.path.join(allocator, &.{ skill_dir, "state-schema.json" });
    defer allocator.free(schema_path);
    {
        const file = try fs_compat.createPath(schema_path, .{});
        defer file.close();
        try file.writeAll("{\"version\":1,\"fields\":{\"step\":\"integer\"}}");
    }

    var noop = @import("../observability.zig").NoopObserver{};
    var provider_state = TestProvider{};
    const provider = @import("../providers/root.zig").Provider{ .ptr = @ptrCast(&provider_state), .vtable = &TestProvider.vtable };
    var agent = Agent{
        .allocator = allocator,
        .provider = provider,
        .tools = &.{},
        .tool_specs = &.{},
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0,
        .workspace_dir = base,
        .max_tool_iterations = 2,
        .max_history_messages = 8,
        .auto_save = false,
        .active_skill_name = "test-skill",
        .active_skill_path = skill_dir,
        .active_skill_instructions = "Track the step.",
        .memory_session_id = "task-1",
    };
    defer agent.deinit();

    const first = try turn(&agent, "task-1", "start");
    defer allocator.free(first);
    try std.testing.expectEqualStrings("first", first);
    const second = try turn(&agent, "task-1", "continue");
    defer allocator.free(second);
    try std.testing.expectEqualStrings("second", second);
    try std.testing.expect(provider_state.saw_previous_state);
    try std.testing.expectEqual(@as(usize, 0), agent.historyLen());
}
