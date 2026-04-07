const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const mem_root = @import("../memory/root.zig");
const Memory = mem_root.Memory;
const MemoryCategory = mem_root.MemoryCategory;
const MemoryEntry = mem_root.MemoryEntry;

pub const MemoryListTool = struct {
    memory: ?Memory = null,

    pub const tool_name = "memory_list";
    pub const tool_description = "List memory entries in recency order. Use for requests like 'show first N memory records' without shell/sqlite access.";
    pub const tool_params =
        \\{"type":"object","properties":{"limit":{"type":"integer","description":"Max entries to return (default: 5, max: 100)"},"category":{"type":"string","description":"Optional category filter (core|daily|conversation|custom)"},"session_id":{"type":"string","description":"Optional session filter"},"include_content":{"type":"boolean","description":"Include content preview (default: true)"},"include_internal":{"type":"boolean","description":"Include internal autosave/hygiene keys (default: false)"}}}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *MemoryListTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *MemoryListTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const m = self.memory orelse {
            const msg = try std.fmt.allocPrint(allocator, "Memory backend not configured. Cannot list entries.", .{});
            return ToolResult{ .success = false, .output = msg };
        };

        const limit_raw = root.getInt(args, "limit") orelse 5;
        const limit: usize = if (limit_raw > 0 and limit_raw <= 100) @intCast(limit_raw) else 5;

        const category_opt: ?MemoryCategory = if (root.getString(args, "category")) |cat_raw|
            if (cat_raw.len > 0) MemoryCategory.fromString(cat_raw) else null
        else
            null;

        const session_id_opt: ?[]const u8 = if (root.getString(args, "session_id")) |sid_raw|
            if (sid_raw.len > 0) sid_raw else root.threadMemorySessionId()
        else
            root.threadMemorySessionId();

        const include_content = root.getBool(args, "include_content") orelse true;
        const include_internal = root.getBool(args, "include_internal") orelse false;

        const entries = m.list(allocator, category_opt, session_id_opt) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to list memory entries: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        defer mem_root.freeEntries(allocator, entries);

        var filtered_total: usize = 0;
        for (entries) |entry| {
            if (!include_internal and isInternalEntry(entry)) continue;
            filtered_total += 1;
        }

        if (filtered_total == 0) {
            const msg = if (category_opt != null)
                "No memory entries found for this filter."
            else
                "No memory entries found.";
            return ToolResult{ .success = true, .output = msg };
        }

        const shown = @min(limit, filtered_total);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        const w = out.writer(allocator);
        try w.print("Memory entries: showing {d}/{d}\n", .{ shown, filtered_total });

        var written: usize = 0;
        for (entries) |entry| {
            if (!include_internal and isInternalEntry(entry)) continue;
            if (written >= shown) break;
            const age_tag = ageTag(entry.timestamp);
            try w.print("  {d}. {s} [{s}] {s}{s}\n", .{ written + 1, entry.key, entry.category.toString(), entry.timestamp, age_tag });
            if (include_content) {
                const preview = truncateUtf8(entry.content, 120);
                try w.print("     {s}{s}\n", .{ preview, if (entry.content.len > preview.len) "..." else "" });
            }
            written += 1;
        }

        return ToolResult{ .success = true, .output = try out.toOwnedSlice(allocator) };
    }

    fn ageTag(timestamp: []const u8) []const u8 {
        const ts = std.fmt.parseInt(i64, std.mem.trim(u8, timestamp, " \t\r\n"), 10) catch return "";
        const age_days = @divFloor(std.time.timestamp() - ts, 86400);
        if (age_days >= 30) return " ⚠ likely stale";
        if (age_days >= 7) return " — verify before acting";
        return "";
    }

    fn isInternalEntry(entry: MemoryEntry) bool {
        return mem_root.isInternalMemoryEntryKeyOrContent(entry.key, entry.content);
    }

    fn truncateUtf8(s: []const u8, max_len: usize) []const u8 {
        if (s.len <= max_len) return s;
        var end: usize = max_len;
        while (end > 0 and s[end] & 0xC0 == 0x80) end -= 1;
        return s[0..end];
    }
};

test "memory_list tool name" {
    var mt = MemoryListTool{};
    const t = mt.tool();
    try std.testing.expectEqualStrings("memory_list", t.name());
}

test "memory_list executes without backend" {
    var mt = MemoryListTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "not configured") != null);
}

test "memory_list filters internal keys by default" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("autosave_user_1", "hello", .conversation, null);
    try mem.store("user_language", "ru", .core, null);
    try mem.store("last_hygiene_at", "1772051598", .core, null);

    var mt = MemoryListTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"limit\":10}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "user_language") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "autosave_user_") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "last_hygiene_at") == null);
}

test "memory_list include_internal true includes autosave entries" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("autosave_user_1", "hello", .conversation, null);

    var mt = MemoryListTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"include_internal\":true}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "autosave_user_1") != null);
}

test "memory_list filters markdown-encoded internal keys in content" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("MEMORY:3", "**last_hygiene_at**: 1772051598", .core, null);
    try mem.store("MEMORY:4", "**Name**: User", .core, null);

    var mt = MemoryListTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"limit\":10}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "last_hygiene_at") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "**Name**: User") != null);
}

test "memory_list shows stale tag for old entries" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    // Store an entry, then overwrite its timestamp to 40 days ago via raw store
    try mem.store("old_fact", "something", .core, null);

    // Manually check ageTag logic: a timestamp 40 days ago should be "likely stale"
    const now = std.time.timestamp();
    const forty_days_ago = now - 40 * 86400;
    var ts_buf: [32]u8 = undefined;
    const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{forty_days_ago});
    try std.testing.expectEqualStrings(" ⚠ likely stale", MemoryListTool.ageTag(ts_str));

    const seven_days_ago = now - 8 * 86400;
    const ts_str2 = try std.fmt.bufPrint(&ts_buf, "{d}", .{seven_days_ago});
    try std.testing.expectEqualStrings(" — verify before acting", MemoryListTool.ageTag(ts_str2));

    const recent = now - 2 * 86400;
    const ts_str3 = try std.fmt.bufPrint(&ts_buf, "{d}", .{recent});
    try std.testing.expectEqualStrings("", MemoryListTool.ageTag(ts_str3));
}

test "memory_list filters bootstrap internal keys by default" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("__bootstrap.prompt.AGENTS.md", "internal-agents", .core, null);
    try mem.store("user_topic", "shipping", .core, null);

    var mt = MemoryListTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"limit\":10}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "user_topic") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__bootstrap.prompt.AGENTS.md") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "internal-agents") == null);
}
