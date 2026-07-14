const std = @import("std");
const builtin = @import("builtin");
const std_compat = @import("compat");
const fs_compat = @import("../fs_compat.zig");
const platform = @import("../platform.zig");
const root = @import("root.zig");

const Provider = root.Provider;
const ChatMessage = root.ChatMessage;
const ChatRequest = root.ChatRequest;
const ChatResponse = root.ChatResponse;

/// Provider that delegates to the locally authenticated Grok CLI.
///
/// Grok's own tools, web search, memory, and subagents are disabled so this
/// provider cannot bypass NullClaw's tool and workspace policy boundaries.
pub const GrokCliProvider = struct {
    allocator: std.mem.Allocator,
    model: []const u8,

    pub const DEFAULT_MODEL = "grok-composer-2.5-fast";
    const MAX_OUTPUT_BYTES: usize = 4 * 1024 * 1024;
    const CLI_SYSTEM_CONSTRAINTS =
        "Answer the user directly. Do not use Grok CLI tools, web search, memory, plans, or subagents.";

    pub fn init(allocator: std.mem.Allocator, model: ?[]const u8) GrokCliProvider {
        return .{
            .allocator = allocator,
            .model = model orelse DEFAULT_MODEL,
        };
    }

    pub fn provider(self: *GrokCliProvider) Provider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    const vtable = Provider.VTable{
        .chatWithSystem = chatWithSystemImpl,
        .chat = chatImpl,
        .supportsNativeTools = supportsNativeToolsImpl,
        .supports_vision = supportsVisionImpl,
        .getName = getNameImpl,
        .deinit = deinitImpl,
    };

    fn chatWithSystemImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        const self: *GrokCliProvider = @ptrCast(@alignCast(ptr));
        return runGrok(
            allocator,
            effectiveModel(model, self.model),
            system_prompt,
            message,
        );
    }

    fn chatImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        model: []const u8,
        _: f64,
    ) anyerror!ChatResponse {
        const self: *GrokCliProvider = @ptrCast(@alignCast(ptr));
        const resolved_model = effectiveModel(model, self.model);
        const prompt = try renderPromptMessages(allocator, request.messages);
        defer allocator.free(prompt);

        const content = try runGrok(
            allocator,
            resolved_model,
            extractSystemPrompt(request.messages),
            prompt,
        );
        return .{
            .content = content,
            .model = try allocator.dupe(u8, resolved_model),
        };
    }

    fn supportsNativeToolsImpl(_: *anyopaque) bool {
        return false;
    }

    fn supportsVisionImpl(_: *anyopaque) bool {
        return false;
    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "grok-cli";
    }

    fn deinitImpl(_: *anyopaque) void {}
};

fn isGrokModel(model: []const u8) bool {
    const trimmed = std.mem.trim(u8, model, " \t\r\n");
    return std.mem.startsWith(u8, trimmed, "grok-");
}

fn effectiveModel(requested_model: []const u8, configured_model: []const u8) []const u8 {
    const requested = std.mem.trim(u8, requested_model, " \t\r\n");
    if (isGrokModel(requested)) return requested;

    const configured = std.mem.trim(u8, configured_model, " \t\r\n");
    if (isGrokModel(configured)) return configured;

    return GrokCliProvider.DEFAULT_MODEL;
}

fn extractSystemPrompt(messages: []const ChatMessage) ?[]const u8 {
    for (messages) |message| {
        if (message.role == .system) return message.content;
    }
    return null;
}

fn renderPromptMessages(allocator: std.mem.Allocator, messages: []const ChatMessage) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    var wrote_any = false;
    for (messages) |message| {
        if (message.role == .system) continue;

        if (wrote_any) try buf.appendSlice(allocator, "\n\n");
        wrote_any = true;

        switch (message.role) {
            .user => try buf.appendSlice(allocator, "User:\n"),
            .assistant => try buf.appendSlice(allocator, "Assistant:\n"),
            .tool => try buf.appendSlice(allocator, "Tool result:\n"),
            .system => unreachable,
        }
        try buf.appendSlice(allocator, message.content);
    }

    if (!wrote_any) return error.NoUserMessage;
    return buf.toOwnedSlice(allocator);
}

fn runGrok(
    allocator: std.mem.Allocator,
    model: []const u8,
    system_prompt: ?[]const u8,
    prompt: []const u8,
) ![]u8 {
    const cli_path = resolveGrokCommand(allocator) orelse return error.CliNotFound;
    defer allocator.free(cli_path);

    const isolated_cwd = try platform.getTempDir(allocator);
    defer allocator.free(isolated_cwd);

    const system_override = try buildSystemOverride(allocator, system_prompt);
    defer allocator.free(system_override);

    var argv: [24][]const u8 = undefined;
    var argc: usize = 0;
    const fixed_args = [_][]const u8{
        cli_path,
        "-p",
        prompt,
        "--output-format",
        "json",
        "--model",
        model,
        "--cwd",
        isolated_cwd,
        "--permission-mode",
        "dontAsk",
        "--disable-web-search",
        "--no-memory",
        "--no-subagents",
        "--max-turns",
        "1",
        "--tools",
        "",
        "--verbatim",
        "--no-plan",
        "--system-prompt-override",
        system_override,
    };
    for (fixed_args) |arg| {
        argv[argc] = arg;
        argc += 1;
    }
    const result = try std_compat.process.Child.run(.{
        .allocator = allocator,
        .argv = argv[0..argc],
        .max_output_bytes = GrokCliProvider.MAX_OUTPUT_BYTES,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return classifyCliFailure(result.stderr),
        else => return error.CliProcessFailed,
    }

    return parseGrokJson(allocator, result.stdout);
}

fn buildSystemOverride(allocator: std.mem.Allocator, system_prompt: ?[]const u8) ![]u8 {
    const configured = if (system_prompt) |value|
        std.mem.trim(u8, value, " \t\r\n")
    else
        "";
    if (configured.len == 0) {
        return allocator.dupe(u8, GrokCliProvider.CLI_SYSTEM_CONSTRAINTS);
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}\n\n{s}",
        .{ configured, GrokCliProvider.CLI_SYSTEM_CONSTRAINTS },
    );
}

fn classifyCliFailure(stderr: []const u8) anyerror {
    if (containsIgnoreCase(stderr, "not signed in") or
        containsIgnoreCase(stderr, "authentication required"))
    {
        return error.AuthenticationFailed;
    }
    if (containsIgnoreCase(stderr, "rate limit") or containsIgnoreCase(stderr, "too many requests")) {
        return error.RateLimited;
    }
    return error.CliProcessFailed;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        for (needle, 0..) |expected, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(expected)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn parseGrokJson(allocator: std.mem.Allocator, output: []const u8) ![]u8 {
    const Response = struct {
        text: ?[]const u8 = null,
    };
    const parsed = try std.json.parseFromSlice(Response, allocator, output, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const text = parsed.value.text orelse return error.NoResultInOutput;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.NoResultInOutput;
    return allocator.dupe(u8, trimmed);
}

fn resolveGrokCommand(allocator: std.mem.Allocator) ?[]u8 {
    if (std_compat.process.getEnvVarOwned(allocator, "GROK_BIN")) |configured| {
        defer allocator.free(configured);
        const trimmed = std.mem.trim(u8, configured, " \t\r\n");
        if (trimmed.len > 0 and fileExists(trimmed)) {
            return allocator.dupe(u8, trimmed) catch null;
        }
    } else |_| {}

    const binary_name = if (builtin.os.tag == .windows) "grok.exe" else "grok";
    if (resolveFromPath(allocator, binary_name)) |command| return command;

    const home = platform.getHomeDir(allocator) catch return null;
    defer allocator.free(home);
    const candidate = std_compat.fs.path.join(allocator, &.{ home, ".grok", "bin", binary_name }) catch return null;
    if (fileExists(candidate)) return candidate;
    allocator.free(candidate);
    return null;
}

fn resolveFromPath(allocator: std.mem.Allocator, binary_name: []const u8) ?[]u8 {
    const env_path = std_compat.process.getEnvVarOwned(allocator, "PATH") catch return null;
    defer allocator.free(env_path);

    const separator: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var path_it = std.mem.splitScalar(u8, env_path, separator);
    while (path_it.next()) |entry| {
        if (entry.len == 0) continue;
        const candidate = std_compat.fs.path.join(allocator, &.{ entry, binary_name }) catch continue;
        if (fileExists(candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

fn fileExists(path: []const u8) bool {
    if (std_compat.fs.path.isAbsolute(path)) {
        const file = std_compat.fs.openFileAbsolute(path, .{}) catch return false;
        file.close();
        return true;
    }
    fs_compat.accessPath(path, .{}) catch return false;
    return true;
}

test "grok cli vtable has expected capabilities" {
    const provider_vtable = GrokCliProvider.vtable;
    var dummy: u8 = 0;
    try std.testing.expectEqualStrings("grok-cli", provider_vtable.getName(@ptrCast(&dummy)));
    try std.testing.expect(!provider_vtable.supportsNativeTools(@ptrCast(&dummy)));
    try std.testing.expect(provider_vtable.supports_vision != null);
    try std.testing.expect(!provider_vtable.supports_vision.?(@ptrCast(&dummy)));
}

test "grok cli fallback ignores a foreign primary model" {
    // Regression: a fallback provider receives the primary model name first;
    // Grok CLI must not try to resolve a MiniMax/Claude model at xAI.
    try std.testing.expectEqualStrings(
        GrokCliProvider.DEFAULT_MODEL,
        effectiveModel("MiniMax-M3", GrokCliProvider.DEFAULT_MODEL),
    );
}

test "grok cli explicit model overrides the configured default" {
    try std.testing.expectEqualStrings(
        "grok-code-fast-1",
        effectiveModel("grok-code-fast-1", GrokCliProvider.DEFAULT_MODEL),
    );
}

test "grok cli renders the non-system transcript" {
    const messages = [_]ChatMessage{
        ChatMessage.system("Be concise"),
        ChatMessage.user("first"),
        ChatMessage.assistant("second"),
        ChatMessage.toolMsg("tool output", "tc1"),
    };
    const rendered = try renderPromptMessages(std.testing.allocator, &messages);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "User:\nfirst\n\nAssistant:\nsecond\n\nTool result:\ntool output",
        rendered,
    );
}

test "grok cli rejects an all-system transcript" {
    const messages = [_]ChatMessage{ChatMessage.system("Be concise")};
    try std.testing.expectError(
        error.NoUserMessage,
        renderPromptMessages(std.testing.allocator, &messages),
    );
}

test "grok cli system override keeps caller prompt and disables cli agent behavior" {
    // Regression: the CLI's default coding-agent prompt treated a health probe
    // as unfinished work and exited with max-turns instead of returning text.
    const with_prompt = try buildSystemOverride(std.testing.allocator, " Be concise. \n");
    defer std.testing.allocator.free(with_prompt);
    try std.testing.expectEqualStrings(
        "Be concise.\n\nAnswer the user directly. Do not use Grok CLI tools, web search, memory, plans, or subagents.",
        with_prompt,
    );

    const without_prompt = try buildSystemOverride(std.testing.allocator, null);
    defer std.testing.allocator.free(without_prompt);
    try std.testing.expectEqualStrings(
        GrokCliProvider.CLI_SYSTEM_CONSTRAINTS,
        without_prompt,
    );
}

test "grok cli parses headless json output" {
    const result = try parseGrokJson(
        std.testing.allocator,
        "{\"text\":\"  fallback response \\n\",\"stopReason\":\"end_turn\"}",
    );
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("fallback response", result);
}

test "grok cli rejects json without response text" {
    try std.testing.expectError(
        error.NoResultInOutput,
        parseGrokJson(std.testing.allocator, "{\"stopReason\":\"error\"}"),
    );
}

test "grok cli classifies missing login as authentication failure" {
    try std.testing.expectEqual(
        error.AuthenticationFailed,
        classifyCliFailure("Error: Not signed in. Please authenticate."),
    );
}

test "grok cli classifies rate limits" {
    try std.testing.expectEqual(
        error.RateLimited,
        classifyCliFailure("Too Many Requests"),
    );
}
