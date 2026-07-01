const std = @import("std");
const memory_mod = @import("../memory/root.zig");
const multimodal = @import("../multimodal.zig");
const util = @import("../util.zig");
const Memory = memory_mod.Memory;
const MemoryEntry = memory_mod.MemoryEntry;
const MemoryRuntime = memory_mod.MemoryRuntime;

// ═══════════════════════════════════════════════════════════════════════════
// Memory Loader — inject relevant memory context into user messages
// ═══════════════════════════════════════════════════════════════════════════

/// Default number of memory entries to recall per query.
const DEFAULT_RECALL_LIMIT: usize = 5;
const SCOPED_RECALL_CANDIDATE_LIMIT: usize = 64;
const GLOBAL_RECALL_CANDIDATE_LIMIT: usize = 64;

/// Maximum total bytes of memory context injected into a message.
/// Prevents a few large entries from blowing the token budget.
/// ~4000 bytes ≈ 1000 ASCII tokens or ~1333 CJK tokens.
const MAX_CONTEXT_BYTES: usize = 4_000;

fn containsKey(entries: []const MemoryEntry, key: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return true;
    }
    return false;
}

fn containsCandidateKey(candidates: []const memory_mod.RetrievalCandidate, key: []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.key, key)) return true;
    }
    return false;
}

fn isInternalMemoryKey(key: []const u8) bool {
    return memory_mod.isInternalMemoryKey(key);
}

fn extractMarkdownMemoryKey(content: []const u8) ?[]const u8 {
    return memory_mod.extractMarkdownMemoryKey(content);
}

fn isInternalMemoryEntry(entry: MemoryEntry) bool {
    return memory_mod.isInternalMemoryEntryKeyOrContent(entry.key, entry.content);
}

fn isArchiveConversationKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "archive:conversation:");
}

fn isArchiveConversationEntry(entry: MemoryEntry) bool {
    if (isArchiveConversationKey(entry.key)) return true;
    if (extractMarkdownMemoryKey(entry.content)) |extracted| {
        return isArchiveConversationKey(extracted);
    }
    return false;
}

fn isArchiveConversationCandidate(cand: memory_mod.RetrievalCandidate) bool {
    if (isArchiveConversationKey(cand.key)) return true;
    if (extractMarkdownMemoryKey(cand.snippet)) |extracted| {
        return isArchiveConversationKey(extracted);
    }
    return false;
}

fn isLessonKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "lesson:");
}

fn isLessonEntry(entry: MemoryEntry) bool {
    if (isLessonKey(entry.key)) return true;
    if (extractMarkdownMemoryKey(entry.content)) |extracted| {
        return isLessonKey(extracted);
    }
    return false;
}

fn isLessonCandidate(cand: memory_mod.RetrievalCandidate) bool {
    if (isLessonKey(cand.key)) return true;
    if (extractMarkdownMemoryKey(cand.snippet)) |extracted| {
        return isLessonKey(extracted);
    }
    return false;
}

const Tier = enum { normal, lesson, archive };

fn entryTier(entry: MemoryEntry) Tier {
    if (isArchiveConversationEntry(entry)) return .archive;
    if (isLessonEntry(entry)) return .lesson;
    return .normal;
}

fn candidateTier(cand: memory_mod.RetrievalCandidate) Tier {
    if (isArchiveConversationCandidate(cand)) return .archive;
    if (isLessonCandidate(cand)) return .lesson;
    return .normal;
}

fn sanitizeMemoryText(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    // Strip inline image markers from recalled snippets so stale
    // [IMAGE:...] references do not accidentally trigger multimodal mode.
    const parsed = multimodal.parseImageMarkers(allocator, text) catch return try allocator.dupe(u8, text);
    defer allocator.free(parsed.refs);
    return parsed.cleaned_text;
}

/// Build a memory context preamble by searching stored memories.
///
/// Returns a formatted string like:
/// ```
/// [Memory context]
/// - key1: value1
/// - key2: value2
/// ```
///
/// Returns an empty owned string if no relevant memories are found.
pub fn loadContext(
    allocator: std.mem.Allocator,
    mem: Memory,
    user_message: []const u8,
    session_id: ?[]const u8,
) ![]const u8 {
    const scoped_entries = mem.recall(allocator, user_message, SCOPED_RECALL_CANDIDATE_LIMIT, session_id) catch {
        return try allocator.dupe(u8, "");
    };
    defer memory_mod.freeEntries(allocator, scoped_entries);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var buf_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const w = &buf_writer.writer;

    var appended: usize = 0;
    var wrote_header = false;

    // Prefer scoped high-signal entries first. Lessons follow normal entries;
    // archived conversation chunks come last within the same scope.
    for ([_]Tier{ .normal, .lesson, .archive }) |tier| {
        for (scoped_entries) |entry| {
            if (isInternalMemoryEntry(entry)) continue;
            if (entryTier(entry) != tier) continue;
            if (!wrote_header) {
                try w.writeAll("[Memory context]\n");
                wrote_header = true;
            }
            // Truncate individual entry content to prevent a single large memory from blowing the budget
            const content = util.truncateUtf8(entry.content, MAX_CONTEXT_BYTES / 2);
            const sanitized = try sanitizeMemoryText(allocator, content);
            defer allocator.free(sanitized);
            try w.print("- {s}: {s}\n", .{ entry.key, sanitized });
            appended += 1;
            if (appended >= DEFAULT_RECALL_LIMIT or buf.items.len >= MAX_CONTEXT_BYTES) break;
        }
        if (appended >= DEFAULT_RECALL_LIMIT or buf.items.len >= MAX_CONTEXT_BYTES) break;
    }

    if (appended < DEFAULT_RECALL_LIMIT and buf.items.len < MAX_CONTEXT_BYTES and session_id != null) {
        // When scoped recall is enabled, also include global (session_id = null)
        // memory so long-term facts from memory_store remain visible in session chats.
        const global_entries = mem.recall(allocator, user_message, GLOBAL_RECALL_CANDIDATE_LIMIT, null) catch null;
        defer if (global_entries) |entries| memory_mod.freeEntries(allocator, entries);

        if (global_entries) |entries| {
            for (entries) |entry| {
                if (entry.session_id != null) continue; // keep scoped isolation (no cross-session bleed)
                if (containsKey(scoped_entries, entry.key)) continue;
                if (isInternalMemoryEntry(entry)) continue;
                if (isArchiveConversationEntry(entry)) continue; // avoid low-provenance global archive bleed

                if (!wrote_header) {
                    try w.writeAll("[Memory context]\n");
                    wrote_header = true;
                }
                const content = util.truncateUtf8(entry.content, MAX_CONTEXT_BYTES / 2);
                const sanitized = try sanitizeMemoryText(allocator, content);
                defer allocator.free(sanitized);
                try w.print("- {s}: {s}\n", .{ entry.key, sanitized });
                appended += 1;
                if (appended >= DEFAULT_RECALL_LIMIT or buf.items.len >= MAX_CONTEXT_BYTES) break;
            }
        }
    }

    if (!wrote_header) {
        return try allocator.dupe(u8, "");
    }
    try w.writeAll("\n");

    buf = buf_writer.toArrayList();
    return try buf.toOwnedSlice(allocator);
}

/// Load context using the full retrieval pipeline (hybrid search, RRF, etc.)
/// when a MemoryRuntime is available.
pub fn loadContextWithRuntime(
    allocator: std.mem.Allocator,
    rt: *MemoryRuntime,
    user_message: []const u8,
    session_id: ?[]const u8,
) ![]const u8 {
    const scoped_candidates = rt.search(allocator, user_message, SCOPED_RECALL_CANDIDATE_LIMIT, session_id) catch {
        return try allocator.dupe(u8, "");
    };
    defer memory_mod.retrieval.freeCandidates(allocator, scoped_candidates);

    // Our utility tracking (for memory quality in cron/sensorium) + upstream fallback
    for (scoped_candidates) |cand| {
        if (!isInternalMemoryKey(cand.key)) rt.recordRecall(cand.key);
    }

    var scoped_fallback_entries: ?[]MemoryEntry = null;
    if (scoped_candidates.len < SCOPED_RECALL_CANDIDATE_LIMIT) {
        scoped_fallback_entries = rt.memory.recall(allocator, user_message, SCOPED_RECALL_CANDIDATE_LIMIT, session_id) catch null;
    }
    defer if (scoped_fallback_entries) |entries| memory_mod.freeEntries(allocator, entries);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var buf_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const w = &buf_writer.writer;
    var appended: usize = 0;
    var wrote_header = false;

    for ([_]Tier{ .normal, .lesson, .archive }) |tier| {
        for (scoped_candidates) |cand| {
            if (isInternalMemoryKey(cand.key)) continue;
            if (extractMarkdownMemoryKey(cand.snippet)) |extracted| {
                if (isInternalMemoryKey(extracted)) continue;
            }
            if (candidateTier(cand) != tier) continue;
            if (!wrote_header) {
                try w.writeAll("[Memory context]\n");
                wrote_header = true;
            }
            const snippet = util.truncateUtf8(cand.snippet, MAX_CONTEXT_BYTES / 2);
            const sanitized = try sanitizeMemoryText(allocator, snippet);
            defer allocator.free(sanitized);
            try w.print("- {s}: {s}\n", .{ cand.key, sanitized });
            appended += 1;
            if (appended >= DEFAULT_RECALL_LIMIT or buf.items.len >= MAX_CONTEXT_BYTES) break;
        }
        if (appended < DEFAULT_RECALL_LIMIT and buf.items.len < MAX_CONTEXT_BYTES) {
            if (scoped_fallback_entries) |entries| {
                for (entries) |entry| {
                    if (containsCandidateKey(scoped_candidates, entry.key)) continue;
                    if (isInternalMemoryEntry(entry)) continue;
                    if (entryTier(entry) != tier) continue;
                    if (!wrote_header) {
                        try w.writeAll("[Memory context]\n");
                        wrote_header = true;
                    }
                    const content = util.truncateUtf8(entry.content, MAX_CONTEXT_BYTES / 2);
                    const sanitized = try sanitizeMemoryText(allocator, content);
                    defer allocator.free(sanitized);
                    try w.print("- {s}: {s}\n", .{ entry.key, sanitized });
                    appended += 1;
                    if (appended >= DEFAULT_RECALL_LIMIT or buf.items.len >= MAX_CONTEXT_BYTES) break;
                }
            }
        }
        if (appended >= DEFAULT_RECALL_LIMIT or buf.items.len >= MAX_CONTEXT_BYTES) break;
    }

    if (appended < DEFAULT_RECALL_LIMIT and buf.items.len < MAX_CONTEXT_BYTES and session_id != null) {
        const global_entries = rt.memory.recall(allocator, user_message, GLOBAL_RECALL_CANDIDATE_LIMIT, null) catch null;
        defer if (global_entries) |entries| memory_mod.freeEntries(allocator, entries);

        if (global_entries) |entries| {
            for (entries) |entry| {
                if (entry.session_id != null) continue; // keep scoped isolation (no cross-session bleed)
                if (containsCandidateKey(scoped_candidates, entry.key)) continue;
                if (scoped_fallback_entries) |fallback_entries| {
                    if (containsKey(fallback_entries, entry.key)) continue;
                }
                if (isInternalMemoryEntry(entry)) continue;
                if (isArchiveConversationEntry(entry)) continue; // avoid low-provenance global archive bleed

                if (!wrote_header) {
                    try w.writeAll("[Memory context]\n");
                    wrote_header = true;
                }
                const content = util.truncateUtf8(entry.content, MAX_CONTEXT_BYTES / 2);
                const sanitized = try sanitizeMemoryText(allocator, content);
                defer allocator.free(sanitized);
                try w.print("- {s}: {s}\n", .{ entry.key, sanitized });
                appended += 1;
                if (appended >= DEFAULT_RECALL_LIMIT or buf.items.len >= MAX_CONTEXT_BYTES) break;
            }
        }
    }

    if (!wrote_header) return try allocator.dupe(u8, "");
    try w.writeAll("\n");

    buf = buf_writer.toArrayList();
    return try buf.toOwnedSlice(allocator);
}

/// Enrich a user message with memory context prepended.
/// If no context is available, returns an owned dupe of the original message.
pub fn enrichMessage(
    allocator: std.mem.Allocator,
    mem: Memory,
    user_message: []const u8,
    session_id: ?[]const u8,
) ![]const u8 {
    const context = try loadContext(allocator, mem, user_message, session_id);
    if (context.len == 0) {
        allocator.free(context);
        return try allocator.dupe(u8, user_message);
    }

    defer allocator.free(context);
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ context, user_message });
}

/// Enrich a user message using the retrieval engine if available, else raw recall.
pub fn enrichMessageWithRuntime(
    allocator: std.mem.Allocator,
    mem: Memory,
    mem_rt: ?*MemoryRuntime,
    user_message: []const u8,
    session_id: ?[]const u8,
) ![]const u8 {
    const context = if (mem_rt) |rt|
        try loadContextWithRuntime(allocator, rt, user_message, session_id)
    else
        try loadContext(allocator, mem, user_message, session_id);

    if (context.len == 0) {
        allocator.free(context);
        return try allocator.dupe(u8, user_message);
    }

    defer allocator.free(context);
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ context, user_message });
}

// ═══════════════════════════════════════════════════════════════════════════
// Sensorium — per-turn ambient self-state prefix
// ═══════════════════════════════════════════════════════════════════════════

/// Snapshot of live agent and scheduler state for sensorium injection.
/// All fields are plain values (no borrowed slices) — safe to copy and store.
pub const SensoriumData = struct {
    now_secs: i64 = 0,
    tz_offset_s: i32 = 0,
    scheduler_jobs: u32 = 0,
    scheduler_next_fire_secs: ?i64 = null,
    scheduler_recent_failures: u32 = 0,
    session_tokens: u64 = 0,
    rate_budget_remaining: u32 = 0,
    rate_budget_max: u32 = 0,
};

/// Build a compact sensorium prefix line. Caller owns returned slice.
/// Fields with zero/null values are omitted to avoid noise.
/// Output is ≤ 256 bytes under normal conditions.
pub fn buildSensoriumPrefix(allocator: std.mem.Allocator, data: SensoriumData) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var buf_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const w = &buf_writer.writer;

    try w.writeAll("<sensorium");

    // Timestamp and timezone
    if (data.now_secs > 0) {
        try w.print(" ts=\"{d}\"", .{data.now_secs});
    }
    if (data.tz_offset_s != 0) {
        const sign: u8 = if (data.tz_offset_s >= 0) '+' else '-';
        const abs_s: u32 = @intCast(@abs(data.tz_offset_s));
        const h = abs_s / 3600;
        const m = (abs_s % 3600) / 60;
        if (m == 0) {
            try w.print(" tz=\"{c}{d:0>2}00\"", .{ sign, h });
        } else {
            try w.print(" tz=\"{c}{d:0>2}{d:0>2}\"", .{ sign, h, m });
        }
    }

    // Scheduler fields — omit when all zero
    if (data.scheduler_jobs > 0) {
        try w.print(" jobs=\"{d}\"", .{data.scheduler_jobs});
    }
    if (data.scheduler_next_fire_secs) |nf| {
        const delta = nf - data.now_secs;
        if (delta > 0) {
            if (delta < 3600) {
                try w.print(" next_fire_in=\"{d}m\"", .{@divTrunc(delta, 60)});
            } else {
                try w.print(" next_fire_in=\"{d}h\"", .{@divTrunc(delta, 3600)});
            }
        } else {
            try w.writeAll(" next_fire_in=\"now\"");
        }
    }
    if (data.scheduler_recent_failures > 0) {
        try w.print(" failures=\"{d}\"", .{data.scheduler_recent_failures});
    }

    // Cost / token fields
    if (data.session_tokens > 0) {
        try w.print(" tokens=\"{d}\"", .{data.session_tokens});
    }

    // Rate budget — only show when there is a limit
    if (data.rate_budget_max > 0) {
        try w.print(" rate=\"{d}/{d}\"", .{ data.rate_budget_remaining, data.rate_budget_max });
    }

    try w.writeAll("/>\n");
    buf = buf_writer.toArrayList();
    return try buf.toOwnedSlice(allocator);
}

/// Return the top recalled memory key (non-internal, highest final_score) for success attribution.
/// Returns null if no eligible candidates found or search fails. Caller owns returned slice.
pub fn topRecalledKey(
    allocator: std.mem.Allocator,
    rt: *MemoryRuntime,
    user_message: []const u8,
    session_id: ?[]const u8,
) ?[]u8 {
    const candidates = rt.search(allocator, user_message, DEFAULT_RECALL_LIMIT, session_id) catch return null;
    defer memory_mod.retrieval.freeCandidates(allocator, candidates);
    for (candidates) |cand| {
        if (!isInternalMemoryKey(cand.key)) {
            return allocator.dupe(u8, cand.key) catch null;
        }
    }
    return null;
}

/// Prepend a sensorium block to `user_message`. Caller owns returned slice.
/// If the sensorium block would be empty (all-zero data), returns a copy of user_message.
pub fn enrichMessageWithSensorium(
    allocator: std.mem.Allocator,
    user_message: []const u8,
    data: SensoriumData,
) ![]u8 {
    // Only emit if there is something meaningful to show
    const has_data = data.now_secs > 0 or data.scheduler_jobs > 0 or
        data.session_tokens > 0 or data.rate_budget_max > 0;
    if (!has_data) return try allocator.dupe(u8, user_message);

    const prefix = try buildSensoriumPrefix(allocator, data);
    defer allocator.free(prefix);
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, user_message });
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "loadContext returns empty for no-op memory" {
    const allocator = std.testing.allocator;
    var none_mem = memory_mod.NoneMemory.init();
    const mem = none_mem.memory();

    const context = try loadContext(allocator, mem, "hello", null);
    defer allocator.free(context);

    try std.testing.expectEqualStrings("", context);
}

test "enrichMessage with no context returns original" {
    const allocator = std.testing.allocator;
    var none_mem = memory_mod.NoneMemory.init();
    const mem = none_mem.memory();

    const enriched = try enrichMessage(allocator, mem, "hello", null);
    defer allocator.free(enriched);

    try std.testing.expectEqualStrings("hello", enriched);
}

test "loadContext with session_id includes global entries but not other sessions" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("sess_a_fact", "session A favorite", .core, "sess-a");
    try mem.store("global_fact", "global favorite", .core, null);
    try mem.store("sess_b_fact", "session B favorite", .core, "sess-b");

    const context = try loadContext(allocator, mem, "favorite", "sess-a");
    defer allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "sess_a_fact") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "global_fact") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "sess_b_fact") == null);
}

test "enrichMessageWithRuntime with no memories returns original message" {
    const allocator = std.testing.allocator;
    var none_mem = memory_mod.NoneMemory.init();
    const mem = none_mem.memory();

    const enriched = try enrichMessageWithRuntime(allocator, mem, null, "hello world", null);
    defer allocator.free(enriched);

    try std.testing.expectEqualStrings("hello world", enriched);
}

test "enrichMessageWithRuntime with memories prepends context" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("user_lang", "Zig is the favorite language", .core, null);

    const enriched = try enrichMessageWithRuntime(allocator, mem, null, "language", null);
    defer allocator.free(enriched);

    // Should contain [Memory context] header and the stored entry
    try std.testing.expect(std.mem.indexOf(u8, enriched, "[Memory context]") != null);
    try std.testing.expect(std.mem.indexOf(u8, enriched, "user_lang") != null);
    try std.testing.expect(std.mem.indexOf(u8, enriched, "Zig is the favorite language") != null);
    // The original message should appear at the end
    try std.testing.expect(std.mem.endsWith(u8, enriched, "language"));
}

test "loadContext filters internal autosave and hygiene entries" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("autosave_user_1", "привет", .conversation, null);
    try mem.store("autosave_assistant_1", "Stored memory: autosave_user_1", .conversation, null);
    try mem.store("last_hygiene_at", "1772051598", .core, null);
    try mem.store("user_language", "Отвечай на русском языке", .core, null);

    const context = try loadContext(allocator, mem, "русском", null);
    defer allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "user_language") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "autosave_user_") == null);
    try std.testing.expect(std.mem.indexOf(u8, context, "autosave_assistant_") == null);
    try std.testing.expect(std.mem.indexOf(u8, context, "last_hygiene_at") == null);
}

test "loadContext filters markdown-encoded internal entries" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    // Markdown backend serializes memory as "**key**: value".
    try mem.store("MEMORY:3", "**last_hygiene_at**: 1772051598", .core, null);
    try mem.store("MEMORY:4", "**Name**: User", .core, null);

    const context = try loadContext(allocator, mem, "User", null);
    defer allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "last_hygiene_at") == null);
    try std.testing.expect(std.mem.indexOf(u8, context, "**Name**: User") != null);
}

test "loadContext filters bootstrap prompt internal keys" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("__bootstrap.prompt.SOUL.md", "persona-internal", .core, null);
    try mem.store("user_goal", "ship reliable builds", .core, null);

    const context = try loadContext(allocator, mem, "ship", null);
    defer allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "user_goal") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "__bootstrap.prompt.SOUL.md") == null);
    try std.testing.expect(std.mem.indexOf(u8, context, "persona-internal") == null);
}

test "loadContextWithRuntime returns empty when only internal entries match" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("autosave_user_1", "привет", .conversation, null);
    try mem.store("autosave_assistant_1", "Stored memory: autosave_user_1", .conversation, null);
    try mem.store("last_hygiene_at", "1772051598", .core, null);

    const resolved = memory_mod.ResolvedConfig{
        .primary_backend = "test",
        .retrieval_mode = "keyword",
        .vector_mode = "none",
        .embedding_provider = "none",
        .rollout_mode = "off",
        .vector_sync_mode = "best_effort",
        .hygiene_enabled = false,
        .snapshot_enabled = false,
        .cache_enabled = false,
        .semantic_cache_enabled = false,
        .summarizer_enabled = false,
        .source_count = 0,
        .fallback_policy = "degrade",
    };
    var rt = memory_mod.MemoryRuntime{
        .memory = mem,
        .session_store = null,
        .response_cache = null,
        .capabilities = .{
            .supports_keyword_rank = false,
            .supports_session_store = false,
            .supports_transactions = false,
            .supports_outbox = false,
        },
        .resolved = resolved,
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = null,
        ._allocator = allocator,
    };

    const context = try loadContextWithRuntime(allocator, &rt, "привет", null);
    defer allocator.free(context);
    try std.testing.expectEqualStrings("", context);
}

test "loadContextWithRuntime with session_id includes global entries but not other sessions" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("sess_a_fact", "session A favorite", .core, "sess-a");
    try mem.store("global_fact", "global favorite", .core, null);
    try mem.store("sess_b_fact", "session B favorite", .core, "sess-b");

    const resolved = memory_mod.ResolvedConfig{
        .primary_backend = "test",
        .retrieval_mode = "keyword",
        .vector_mode = "none",
        .embedding_provider = "none",
        .rollout_mode = "off",
        .vector_sync_mode = "best_effort",
        .hygiene_enabled = false,
        .snapshot_enabled = false,
        .cache_enabled = false,
        .semantic_cache_enabled = false,
        .summarizer_enabled = false,
        .source_count = 0,
        .fallback_policy = "degrade",
    };
    var rt = memory_mod.MemoryRuntime{
        .memory = mem,
        .session_store = null,
        .response_cache = null,
        .capabilities = .{
            .supports_keyword_rank = false,
            .supports_session_store = false,
            .supports_transactions = false,
            .supports_outbox = false,
        },
        .resolved = resolved,
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = null,
        ._allocator = allocator,
    };

    const context = try loadContextWithRuntime(allocator, &rt, "favorite", "sess-a");
    defer allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "sess_a_fact") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "global_fact") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "sess_b_fact") == null);
}

test "buildSensoriumPrefix with known data produces expected output" {
    const allocator = std.testing.allocator;
    const data = SensoriumData{
        .now_secs = 1744200180,
        .tz_offset_s = 8 * 3600, // +0800
        .scheduler_jobs = 5,
        .scheduler_next_fire_secs = 1744200180 + 12 * 60, // 12m from now
        .scheduler_recent_failures = 0,
        .session_tokens = 24035,
        .rate_budget_remaining = 17,
        .rate_budget_max = 20,
    };
    const prefix = try buildSensoriumPrefix(allocator, data);
    defer allocator.free(prefix);

    try std.testing.expect(std.mem.indexOf(u8, prefix, "ts=\"1744200180\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prefix, "tz=\"+0800\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prefix, "jobs=\"5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prefix, "next_fire_in=\"12m\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prefix, "failures") == null); // 0 failures omitted
    try std.testing.expect(std.mem.indexOf(u8, prefix, "tokens=\"24035\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prefix, "rate=\"17/20\"") != null);
    // Must end with "/>\n"
    try std.testing.expect(std.mem.endsWith(u8, prefix, "/>\n"));
}
test "buildSensoriumPrefix with all-zero data omits noise fields" {
    const allocator = std.testing.allocator;
    const data = SensoriumData{};
    const prefix = try buildSensoriumPrefix(allocator, data);
    defer allocator.free(prefix);

    // Should still produce a minimal tag, just with no attributes
    try std.testing.expect(std.mem.indexOf(u8, prefix, "<sensorium") != null);
    try std.testing.expect(std.mem.indexOf(u8, prefix, "jobs=") == null);
    try std.testing.expect(std.mem.indexOf(u8, prefix, "tokens=") == null);
    try std.testing.expect(std.mem.indexOf(u8, prefix, "rate=") == null);
    try std.testing.expect(std.mem.indexOf(u8, prefix, "failures=") == null);
}

test "enrichMessageWithSensorium prepends sensorium prefix before message" {
    const allocator = std.testing.allocator;
    const data = SensoriumData{
        .now_secs = 1744200180,
        .session_tokens = 100,
        .rate_budget_remaining = 5,
        .rate_budget_max = 20,
    };
    const enriched = try enrichMessageWithSensorium(allocator, "hello world", data);
    defer allocator.free(enriched);

    // Sensorium line comes first, then the original message
    try std.testing.expect(std.mem.startsWith(u8, enriched, "<sensorium"));
    try std.testing.expect(std.mem.indexOf(u8, enriched, "hello world") != null);
    const prefix_end = std.mem.indexOf(u8, enriched, "\n") orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, enriched[prefix_end..], "hello world") != null);
}

test "enrichMessageWithSensorium with all-zero data returns copy of message" {
    const allocator = std.testing.allocator;
    const data = SensoriumData{};
    const enriched = try enrichMessageWithSensorium(allocator, "unchanged", data);
    defer allocator.free(enriched);

    try std.testing.expectEqualStrings("unchanged", enriched);
}

const OrderedMemory = struct {
    entries: []const Entry,

    const Entry = struct {
        key: []const u8,
        content: []const u8,
        category: memory_mod.MemoryCategory,
        session_id: ?[]const u8 = "sess-a",
    };

    fn memory(self: *OrderedMemory) Memory {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Memory.VTable{
        .name = name,
        .store = store,
        .recall = recall,
        .get = get,
        .list = list,
        .forget = forget,
        .count = count,
        .healthCheck = healthCheck,
        .deinit = deinit,
    };

    fn selfFrom(ptr: *anyopaque) *OrderedMemory {
        return @ptrCast(@alignCast(ptr));
    }

    fn name(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "ordered-test";
    }

    fn store(ptr: *anyopaque, key: []const u8, content: []const u8, category: memory_mod.MemoryCategory, session_id: ?[]const u8) anyerror!void {
        _ = ptr;
        _ = key;
        _ = content;
        _ = category;
        _ = session_id;
        return error.NotSupported;
    }

    fn recall(ptr: *anyopaque, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8) anyerror![]MemoryEntry {
        _ = query;
        return selfFrom(ptr).copyEntries(allocator, limit, null, session_id);
    }

    fn get(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?MemoryEntry {
        const self = selfFrom(ptr);
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return try dupeEntry(allocator, entry);
            }
        }
        return null;
    }

    fn list(ptr: *anyopaque, allocator: std.mem.Allocator, category: ?memory_mod.MemoryCategory, session_id: ?[]const u8) anyerror![]MemoryEntry {
        const self = selfFrom(ptr);
        return self.copyEntries(allocator, self.entries.len, category, session_id);
    }

    fn forget(ptr: *anyopaque, key: []const u8) anyerror!bool {
        _ = ptr;
        _ = key;
        return false;
    }

    fn count(ptr: *anyopaque) anyerror!usize {
        return selfFrom(ptr).entries.len;
    }

    fn healthCheck(ptr: *anyopaque) bool {
        _ = ptr;
        return true;
    }

    fn deinit(ptr: *anyopaque) void {
        _ = ptr;
    }

    fn copyEntries(
        self: *OrderedMemory,
        allocator: std.mem.Allocator,
        limit: usize,
        category_filter: ?memory_mod.MemoryCategory,
        session_id: ?[]const u8,
    ) ![]MemoryEntry {
        var out_len: usize = 0;
        for (self.entries) |entry| {
            if (out_len >= limit) break;
            if (category_filter) |filter| {
                if (!memory_mod.MemoryCategory.eql(entry.category, filter)) continue;
            }
            if (!sessionMatches(entry.session_id, session_id)) continue;
            out_len += 1;
        }

        var result = try allocator.alloc(MemoryEntry, out_len);
        var initialized: usize = 0;
        errdefer {
            for (result[0..initialized]) |*entry| entry.deinit(allocator);
            allocator.free(result);
        }

        for (self.entries) |entry| {
            if (initialized >= out_len) break;
            if (category_filter) |filter| {
                if (!memory_mod.MemoryCategory.eql(entry.category, filter)) continue;
            }
            if (!sessionMatches(entry.session_id, session_id)) continue;
            result[initialized] = try dupeEntry(allocator, entry);
            initialized += 1;
        }

        return result;
    }

    fn sessionMatches(entry_session_id: ?[]const u8, requested_session_id: ?[]const u8) bool {
        if (requested_session_id) |requested| {
            return entry_session_id != null and std.mem.eql(u8, entry_session_id.?, requested);
        }
        return entry_session_id == null;
    }

    fn dupeEntry(allocator: std.mem.Allocator, entry: Entry) !MemoryEntry {
        const id = try allocator.dupe(u8, entry.key);
        errdefer allocator.free(id);

        const key = try allocator.dupe(u8, entry.key);
        errdefer allocator.free(key);

        const content = try allocator.dupe(u8, entry.content);
        errdefer allocator.free(content);

        const timestamp = try allocator.dupe(u8, "1970-01-01T00:00:00Z");
        errdefer allocator.free(timestamp);

        const category: memory_mod.MemoryCategory = switch (entry.category) {
            .custom => |name_value| .{ .custom = try allocator.dupe(u8, name_value) },
            else => entry.category,
        };
        errdefer switch (category) {
            .custom => |name_value| allocator.free(name_value),
            else => {},
        };

        const session_id = if (entry.session_id) |sid| try allocator.dupe(u8, sid) else null;
        errdefer if (session_id) |sid| allocator.free(sid);

        return .{
            .id = id,
            .key = key,
            .content = content,
            .category = category,
            .timestamp = timestamp,
            .session_id = session_id,
        };
    }
};

test "reflection_recall_load_context_orders_core_then_lessons_then_archive" {
    const allocator = std.testing.allocator;

    const ordered_entries = [_]OrderedMemory.Entry{
        .{
            .key = "archive:conversation:x:chunk:0",
            .content = "needle archive",
            .category = .{ .custom = "archive" },
        },
        .{
            .key = "lesson:abc",
            .content = "needle lesson",
            .category = .{ .custom = "lesson" },
        },
        .{
            .key = "core_fact",
            .content = "needle core",
            .category = .core,
        },
    };
    var ordered_mem = OrderedMemory{ .entries = &ordered_entries };
    const mem = ordered_mem.memory();

    const context = try loadContext(allocator, mem, "needle", "sess-a");
    defer allocator.free(context);

    const core_pos = std.mem.indexOf(u8, context, "core_fact") orelse return error.TestUnexpectedResult;
    const lesson_pos = std.mem.indexOf(u8, context, "lesson:abc") orelse return error.TestUnexpectedResult;
    const archive_pos = std.mem.indexOf(u8, context, "archive:conversation:") orelse return error.TestUnexpectedResult;

    // RED: the current two-pass archive-only walk keeps lessons in hostile recall order with normal entries.
    try std.testing.expect(core_pos < lesson_pos);
    try std.testing.expect(lesson_pos < archive_pos);
}

test "reflection_recall_load_context_with_runtime_orders_core_then_lessons" {
    const allocator = std.testing.allocator;

    const ordered_entries = [_]OrderedMemory.Entry{
        .{
            .key = "archive:conversation:x:chunk:0",
            .content = "needle archive",
            .category = .{ .custom = "archive" },
        },
        .{
            .key = "lesson:abc",
            .content = "needle lesson",
            .category = .{ .custom = "lesson" },
        },
        .{
            .key = "core_fact",
            .content = "needle core",
            .category = .core,
        },
    };
    var ordered_mem = OrderedMemory{ .entries = &ordered_entries };
    const mem = ordered_mem.memory();

    const resolved = memory_mod.ResolvedConfig{
        .primary_backend = "test",
        .retrieval_mode = "keyword",
        .vector_mode = "none",
        .embedding_provider = "none",
        .rollout_mode = "off",
        .vector_sync_mode = "best_effort",
        .hygiene_enabled = false,
        .snapshot_enabled = false,
        .cache_enabled = false,
        .semantic_cache_enabled = false,
        .summarizer_enabled = false,
        .source_count = 0,
        .fallback_policy = "degrade",
    };
    var rt = memory_mod.MemoryRuntime{
        .memory = mem,
        .session_store = null,
        .response_cache = null,
        .capabilities = .{
            .supports_keyword_rank = false,
            .supports_session_store = false,
            .supports_transactions = false,
            .supports_outbox = false,
        },
        .resolved = resolved,
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = null,
        ._allocator = allocator,
    };

    const context = try loadContextWithRuntime(allocator, &rt, "needle", "sess-a");
    defer allocator.free(context);

    const core_pos = std.mem.indexOf(u8, context, "core_fact") orelse return error.TestUnexpectedResult;
    const lesson_pos = std.mem.indexOf(u8, context, "lesson:abc") orelse return error.TestUnexpectedResult;
    const archive_pos = std.mem.indexOf(u8, context, "archive:conversation:") orelse return error.TestUnexpectedResult;

    // RED: runtime candidates still use the current two-pass archive-only ordering.
    try std.testing.expect(core_pos < lesson_pos);
    try std.testing.expect(lesson_pos < archive_pos);
}

test "reflection_recall_lesson_entries_are_not_internal_filtered" {
    const allocator = std.testing.allocator;

    try std.testing.expect(isLessonKey("lesson:abc"));
    try std.testing.expect(!isInternalMemoryKey("lesson:abc"));
    try std.testing.expect(!memory_mod.isInternalMemoryEntryKeyOrContent("lesson:abc", "needle lesson"));

    const ordered_entries = [_]OrderedMemory.Entry{
        .{
            .key = "lesson:abc",
            .content = "needle lesson",
            .category = .{ .custom = "lesson" },
        },
    };
    var ordered_mem = OrderedMemory{ .entries = &ordered_entries };
    const mem = ordered_mem.memory();

    const context = try loadContext(allocator, mem, "needle", "sess-a");
    defer allocator.free(context);

    // RED condition for later implementation: lesson tiering must not become lesson filtering.
    try std.testing.expect(std.mem.indexOf(u8, context, "lesson:abc") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "needle lesson") != null);
}

test "loadContext skips globally preserved archive conversation entries" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("sess_a_fact", "session A favorite", .core, "sess-a");
    try mem.store("global_fact", "global favorite", .core, null);
    // Regression: globally scoped archive shards can leak unrelated legacy turns.
    try mem.store(
        "archive:conversation:autosave_user_1699999999000000000:chunk:0",
        "Archived conversation source: archive:conversation:autosave_user_1699999999000000000\nChunk: 1/1\n\nfavorite legacy transcript",
        .{ .custom = "archive" },
        null,
    );

    const context = try loadContext(allocator, mem, "favorite", "sess-a");
    defer allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "sess_a_fact") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "global_fact") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "archive:conversation:autosave_user_1699999999000000000:chunk:0") == null);
}

test "loadContextWithRuntime skips globally preserved archive conversation entries" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("sess_a_fact", "session A favorite", .core, "sess-a");
    try mem.store("global_fact", "global favorite", .core, null);
    // Regression: globally scoped archive shards can leak unrelated legacy turns.
    try mem.store(
        "archive:conversation:autosave_user_1699999999000000000:chunk:0",
        "Archived conversation source: archive:conversation:autosave_user_1699999999000000000\nChunk: 1/1\n\nfavorite legacy transcript",
        .{ .custom = "archive" },
        null,
    );

    const resolved = memory_mod.ResolvedConfig{
        .primary_backend = "test",
        .retrieval_mode = "keyword",
        .vector_mode = "none",
        .embedding_provider = "none",
        .rollout_mode = "off",
        .vector_sync_mode = "best_effort",
        .hygiene_enabled = false,
        .snapshot_enabled = false,
        .cache_enabled = false,
        .semantic_cache_enabled = false,
        .summarizer_enabled = false,
        .source_count = 0,
        .fallback_policy = "degrade",
    };
    var rt = memory_mod.MemoryRuntime{
        .memory = mem,
        .session_store = null,
        .response_cache = null,
        .capabilities = .{
            .supports_keyword_rank = false,
            .supports_session_store = false,
            .supports_transactions = false,
            .supports_outbox = false,
        },
        .resolved = resolved,
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = null,
        ._allocator = allocator,
    };

    const context = try loadContextWithRuntime(allocator, &rt, "favorite", "sess-a");
    defer allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "sess_a_fact") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "global_fact") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "archive:conversation:autosave_user_1699999999000000000:chunk:0") == null);
}

test "loadContext prefers scoped facts when archive candidates fill recall window" {
    const allocator = std.testing.allocator;

    var mem_impl = memory_mod.InMemoryLruMemory.init(allocator, 32);
    defer mem_impl.deinit();
    const mem = mem_impl.memory();

    try mem.store("scoped_fact", "needle scoped answer", .core, "sess-a");
    var idx: usize = 0;
    while (idx < DEFAULT_RECALL_LIMIT) : (idx += 1) {
        var key_buf: [96]u8 = undefined;
        const key = try std.fmt.bufPrint(
            &key_buf,
            "archive:conversation:autosave_user_1700000000000000000:chunk:{d}",
            .{idx},
        );
        try mem.store(key, "needle archived transcript", .{ .custom = "archive" }, "sess-a");
    }

    // Regression: archive chunks can fill the raw recall limit and hide a lower-ranked scoped fact.
    const context = try loadContext(allocator, mem, "needle", "sess-a");
    defer allocator.free(context);

    const fact_pos = std.mem.indexOf(u8, context, "scoped_fact") orelse return error.TestUnexpectedResult;
    const archive_pos = std.mem.indexOf(u8, context, "archive:conversation:") orelse return error.TestUnexpectedResult;
    try std.testing.expect(fact_pos < archive_pos);
}

test "loadContextWithRuntime prefers scoped facts when engine candidates fill with archives" {
    const allocator = std.testing.allocator;

    var mem_impl = memory_mod.InMemoryLruMemory.init(allocator, 32);
    defer mem_impl.deinit();
    const mem = mem_impl.memory();

    try mem.store("scoped_fact", "needle scoped answer", .core, "sess-a");
    var idx: usize = 0;
    while (idx < DEFAULT_RECALL_LIMIT) : (idx += 1) {
        var key_buf: [96]u8 = undefined;
        const key = try std.fmt.bufPrint(
            &key_buf,
            "archive:conversation:autosave_user_1700000000000000000:chunk:{d}",
            .{idx},
        );
        try mem.store(key, "needle archived transcript", .{ .custom = "archive" }, "sess-a");
    }

    var primary = memory_mod.PrimaryAdapter.init(mem);
    var engine = memory_mod.RetrievalEngine.init(allocator, .{ .max_results = DEFAULT_RECALL_LIMIT });
    defer engine.deinit();
    try engine.addSource(primary.adapter());

    const resolved = memory_mod.ResolvedConfig{
        .primary_backend = "test",
        .retrieval_mode = "keyword",
        .vector_mode = "none",
        .embedding_provider = "none",
        .rollout_mode = "off",
        .vector_sync_mode = "best_effort",
        .hygiene_enabled = false,
        .snapshot_enabled = false,
        .cache_enabled = false,
        .semantic_cache_enabled = false,
        .summarizer_enabled = false,
        .source_count = 0,
        .fallback_policy = "degrade",
    };
    var rt = memory_mod.MemoryRuntime{
        .memory = mem,
        .session_store = null,
        .response_cache = null,
        .capabilities = .{
            .supports_keyword_rank = false,
            .supports_session_store = false,
            .supports_transactions = false,
            .supports_outbox = false,
        },
        .resolved = resolved,
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = &engine,
        ._allocator = allocator,
    };

    // Regression: engine top_k can fill with archive chunks and hide a lower-ranked scoped fact.
    const context = try loadContextWithRuntime(allocator, &rt, "needle", "sess-a");
    defer allocator.free(context);

    const fact_pos = std.mem.indexOf(u8, context, "scoped_fact") orelse return error.TestUnexpectedResult;
    const archive_pos = std.mem.indexOf(u8, context, "archive:conversation:") orelse return error.TestUnexpectedResult;
    try std.testing.expect(fact_pos < archive_pos);
}
