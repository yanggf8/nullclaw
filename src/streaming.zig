const providers = @import("providers/root.zig");

pub const OutboundStage = enum {
    chunk,
    final,
};

pub const Event = struct {
    stage: OutboundStage,
    text: []const u8 = "",
};

pub const Sink = struct {
    callback: *const fn (ctx: *anyopaque, event: Event) void,
    ctx: *anyopaque,

    pub fn emit(self: Sink, event: Event) void {
        self.callback(self.ctx, event);
    }

    pub fn emitChunk(self: Sink, text: []const u8) void {
        if (text.len == 0) return;
        self.emit(.{
            .stage = .chunk,
            .text = text,
        });
    }

    pub fn emitFinal(self: Sink) void {
        self.emit(.{ .stage = .final });
    }
};

pub fn eventFromProviderChunk(chunk: providers.StreamChunk) ?Event {
    if (chunk.is_final) return .{ .stage = .final };
    if (chunk.delta.len == 0) return null;
    return .{
        .stage = .chunk,
        .text = chunk.delta,
    };
}

pub fn forwardProviderChunk(sink: Sink, chunk: providers.StreamChunk) void {
    if (eventFromProviderChunk(chunk)) |event| {
        sink.emit(event);
    }
}

// ---------------------------------------------------------------------------
// TagFilter – state-machine that strips tool-control blocks from a stream of
// chunks before forwarding to an inner Sink.
// ---------------------------------------------------------------------------

pub const TagFilter = struct {
    inner: Sink,
    state: State = .passthrough,
    buf: [max_buf_len]u8 = undefined,
    buf_len: u8 = 0,
    // Bytes suppressed since entering .inside_tag / .skip_to_angle_close for the
    // current tag. A real tool_call/tool_result/think body is at most a few KB
    // (a function name + JSON args, or a short reasoning note). If a provider
    // emits an open tag that is never actually closed -- a false-positive match
    // on plain prose containing "<think>"/"<tool_call>", or a genuine control
    // token the model forgot to close -- the filter would otherwise stay in
    // .inside_tag and silently discard EVERY subsequent byte for the rest of
    // the stream, which reads as massive text loss/corruption downstream.
    // Bound the suppression window: past this many bytes, give up looking for
    // a close tag and resume passthrough so the rest of the stream survives.
    suppressed_len: usize = 0,

    const State = enum {
        passthrough,
        maybe_open, // buffering after '<', checking if prefix matches
        skip_to_angle_close, // prefix matched, eating until '>'
        inside_tag, // inside tag body, suppressing output
        maybe_close, // buffering after '<', checking if close tag matches
    };

    // Generous upper bound on a legitimate suppressed tag body. Tool-call
    // arguments and think blocks are normally well under this; a false-positive
    // open match on ordinary prose would otherwise swallow the rest of the
    // stream, so bail out and resume passthrough once this is exceeded.
    const max_suppressed_len: usize = 8192;

    // Opening tag prefixes. After matching, skip until '>'.
    // Handles canonical XML tags plus provider-specific *_begin wrappers.
    const open_prefixes = [_][]const u8{
        "<tool_call",
        "<tool_result",
        "<tool_call_begin",
        "<tool_result_begin",
        "<|tool_call_begin|",
        "<|tool_result_begin|",
        "<think",
    };

    // Closing tags (fixed match).
    const close_tags = [_][]const u8{
        "</tool_call>",
        "</tool_result>",
        "<tool_call_end>",
        "<tool_result_end>",
        "<|tool_call_end|>",
        "<|tool_result_end|>",
        "</think>",
    };

    // Standalone control tokens that should be stripped, but do not wrap body text.
    const standalone_tags = [_][]const u8{
        "<tool_calls_section_begin>",
        "<tool_calls_section_end>",
        "<tool_calls_section_end|>",
        "<|tool_calls_section_begin|>",
        "<|tool_calls_section_end|>",
        "<tool_call_argument_begin>",
        "<|tool_call_argument_begin|>",
    };

    fn maxLen(comptime tags: []const []const u8) comptime_int {
        var longest: usize = 0;
        for (tags) |tag| {
            if (tag.len > longest) longest = tag.len;
        }
        return longest;
    }

    const max_prefix_len = maxLen(&open_prefixes);
    const max_tag_len = maxLen(&close_tags);
    const max_standalone_len = maxLen(&standalone_tags);
    const max_buf_len = @max(@max(max_prefix_len + 1, max_tag_len), max_standalone_len);

    pub fn init(inner: Sink) TagFilter {
        return .{ .inner = inner };
    }

    /// Return a Sink whose callback routes through this filter.
    pub fn sink(self: *TagFilter) Sink {
        return .{
            .callback = filterCallback,
            .ctx = @ptrCast(self),
        };
    }

    fn filterCallback(ctx: *anyopaque, event: Event) void {
        const self: *TagFilter = @ptrCast(@alignCast(ctx));
        if (event.stage == .final) {
            // Flush any pending buffer as-is (incomplete tag at end of stream).
            self.flushBuf();
            self.inner.emit(event);
            return;
        }
        self.process(event.text);
    }

    fn process(self: *TagFilter, text: []const u8) void {
        var clean_start: usize = 0;
        for (text, 0..) |b, i| {
            switch (self.state) {
                .passthrough => {
                    if (b == '<') {
                        // Flush clean text accumulated so far.
                        if (i > clean_start)
                            self.inner.emitChunk(text[clean_start..i]);
                        self.buf[0] = b;
                        self.buf_len = 1;
                        self.state = .maybe_open;
                    }
                },
                .maybe_open => {
                    self.buf[self.buf_len] = b;
                    self.buf_len += 1;
                    const prefix = self.buf[0..self.buf_len];
                    if (matchesAny(prefix, &standalone_tags)) |_| {
                        self.buf_len = 0;
                        self.state = .passthrough;
                        clean_start = i + 1;
                        continue;
                    }
                    // Check if the bytes before this one match a full open prefix
                    // and this byte is a delimiter ('>' closes the tag, ' ' starts attrs).
                    if (self.buf_len > 1 and (b == '>' or b == ' ') and
                        matchesAnyPrefix(prefix[0 .. self.buf_len - 1], &open_prefixes))
                    {
                        self.buf_len = 0;
                        self.suppressed_len = 0;
                        if (b == '>') {
                            self.state = .inside_tag;
                        } else {
                            self.state = .skip_to_angle_close;
                        }
                        clean_start = i + 1;
                        continue;
                    }
                    // Still a valid prefix of some open tag — keep buffering.
                    if (prefixOfAny(prefix, &open_prefixes) or prefixOfAny(prefix, &standalone_tags)) {
                        clean_start = i + 1;
                        continue;
                    }
                    // Not a prefix of any tag — flush buffer and resume passthrough.
                    self.inner.emitChunk(self.buf[0..self.buf_len]);
                    self.buf_len = 0;
                    self.state = .passthrough;
                    clean_start = i + 1;
                },
                .skip_to_angle_close => {
                    clean_start = i + 1;
                    self.suppressed_len += 1;
                    if (b == '>') {
                        self.state = .inside_tag;
                    } else if (self.suppressed_len > max_suppressed_len) {
                        // Attribute section never closed — not a real tag. Bail
                        // out to passthrough so the rest of the stream survives.
                        self.state = .passthrough;
                    }
                },
                .inside_tag => {
                    clean_start = i + 1;
                    self.suppressed_len += 1;
                    if (b == '<') {
                        self.buf[0] = b;
                        self.buf_len = 1;
                        self.state = .maybe_close;
                    } else if (self.suppressed_len > max_suppressed_len) {
                        // No close tag found within a plausible tool_call/think
                        // body length — treat the open tag as a false positive
                        // and resume passthrough instead of swallowing forever.
                        self.state = .passthrough;
                    }
                },
                .maybe_close => {
                    clean_start = i + 1;
                    self.suppressed_len += 1;
                    self.buf[self.buf_len] = b;
                    self.buf_len += 1;
                    const prefix = self.buf[0..self.buf_len];
                    if (matchesAny(prefix, &close_tags)) |_| {
                        // Complete close tag matched — back to passthrough.
                        self.buf_len = 0;
                        self.state = .passthrough;
                        clean_start = i + 1;
                        continue;
                    }
                    if (self.suppressed_len > max_suppressed_len) {
                        // No close tag found within a plausible body length —
                        // treat the open tag as a false positive.
                        self.buf_len = 0;
                        self.state = .passthrough;
                        clean_start = i + 1;
                        continue;
                    }
                    if (!prefixOfAny(prefix, &close_tags) or self.buf_len >= max_tag_len) {
                        // Not a close tag — stay inside, discard buffer.
                        self.buf_len = 0;
                        self.state = .inside_tag;
                        continue;
                    }
                    // Still a valid prefix of a close tag — keep buffering.
                },
            }
        }
        // Flush remaining clean text in passthrough mode.
        if (self.state == .passthrough and clean_start < text.len)
            self.inner.emitChunk(text[clean_start..]);
    }

    fn flushBuf(self: *TagFilter) void {
        if (self.buf_len > 0 and self.state == .maybe_open) {
            // Incomplete open tag at end of stream — not a real tag, flush it.
            self.inner.emitChunk(self.buf[0..self.buf_len]);
        }
        self.buf_len = 0;
        self.state = .passthrough;
    }

    /// Returns the index if `text` exactly matches any entry in `tags`.
    fn matchesAny(text: []const u8, tags: []const []const u8) ?usize {
        for (tags, 0..) |tag, i| {
            if (std.mem.eql(u8, text, tag)) return i;
        }
        return null;
    }

    /// Returns true if `text` exactly matches any entry in `prefixes`.
    fn matchesAnyPrefix(text: []const u8, prefixes: []const []const u8) bool {
        for (prefixes) |p| {
            if (std.mem.eql(u8, text, p)) return true;
        }
        return false;
    }

    /// Returns true if `text` is a valid prefix of at least one entry in `tags`.
    fn prefixOfAny(text: []const u8, tags: []const []const u8) bool {
        for (tags) |tag| {
            if (text.len <= tag.len and std.mem.eql(u8, text, tag[0..text.len]))
                return true;
        }
        return false;
    }
};

const std = @import("std");

// ---------------------------------------------------------------------------
// ThinkPassthroughFilter — replaces <think>…</think> with a visible block
// instead of stripping it. Used when reasoning_mode == .stream so that
// thinking content appears live in the CLI.
// ---------------------------------------------------------------------------

/// Header emitted in place of `<think>` tag.
pub const THINK_HEADER = "\n💭 Thinking:\n";
/// Footer emitted in place of `</think>` tag.
pub const THINK_FOOTER = "\n---\n";

pub const ThinkPassthroughFilter = struct {
    inner: Sink,
    state: State = .passthrough,
    buf: [max_buf_len]u8 = undefined,
    buf_len: usize = 0,

    const State = enum {
        passthrough, // normal text — pass through verbatim
        maybe_open, // saw '<', buffering to check for '<think>'
        inside_think, // inside <think>…</think>, pass body through
        maybe_close, // inside think, saw '<', buffering for '</think>'
    };

    const open_tag = "<think>";
    const close_tag = "</think>";
    const max_buf_len = close_tag.len + 1;

    pub fn init(inner: Sink) ThinkPassthroughFilter {
        return .{ .inner = inner };
    }

    pub fn sink(self: *ThinkPassthroughFilter) Sink {
        return .{
            .callback = filterCallback,
            .ctx = @ptrCast(self),
        };
    }

    fn filterCallback(ctx: *anyopaque, event: Event) void {
        const self: *ThinkPassthroughFilter = @ptrCast(@alignCast(ctx));
        if (event.stage == .final) {
            self.flushBuf();
            self.inner.emit(event);
            return;
        }
        self.process(event.text);
    }

    fn process(self: *ThinkPassthroughFilter, text: []const u8) void {
        var clean_start: usize = 0;
        for (text, 0..) |b, i| {
            switch (self.state) {
                .passthrough => {
                    if (b == '<') {
                        if (i > clean_start)
                            self.inner.emitChunk(text[clean_start..i]);
                        self.buf[0] = b;
                        self.buf_len = 1;
                        self.state = .maybe_open;
                    }
                },
                .maybe_open => {
                    self.buf[self.buf_len] = b;
                    self.buf_len += 1;
                    const prefix = self.buf[0..self.buf_len];
                    if (std.mem.eql(u8, prefix, open_tag)) {
                        // Matched <think> — emit header, enter think body.
                        self.buf_len = 0;
                        self.state = .inside_think;
                        self.inner.emitChunk(THINK_HEADER);
                        clean_start = i + 1;
                        continue;
                    }
                    if (std.mem.startsWith(u8, open_tag, prefix)) {
                        // Still a valid prefix of <think> — keep buffering.
                        clean_start = i + 1;
                        continue;
                    }
                    // Not a <think> prefix — flush the buffer as normal text.
                    self.inner.emitChunk(self.buf[0..self.buf_len]);
                    self.buf_len = 0;
                    self.state = .passthrough;
                    clean_start = i + 1;
                },
                .inside_think => {
                    if (b == '<') {
                        if (i > clean_start)
                            self.inner.emitChunk(text[clean_start..i]);
                        self.buf[0] = b;
                        self.buf_len = 1;
                        self.state = .maybe_close;
                        clean_start = i + 1;
                    }
                },
                .maybe_close => {
                    self.buf[self.buf_len] = b;
                    self.buf_len += 1;
                    const prefix = self.buf[0..self.buf_len];
                    if (std.mem.eql(u8, prefix, close_tag)) {
                        // Matched </think> — emit footer, return to passthrough.
                        self.buf_len = 0;
                        self.state = .passthrough;
                        self.inner.emitChunk(THINK_FOOTER);
                        clean_start = i + 1;
                        continue;
                    }
                    if (std.mem.startsWith(u8, close_tag, prefix)) {
                        // Still a valid prefix — keep buffering.
                        clean_start = i + 1;
                        continue;
                    }
                    // Not a </think> close — emit the buffer as think-body text.
                    self.inner.emitChunk(self.buf[0..self.buf_len]);
                    self.buf_len = 0;
                    self.state = .inside_think;
                    clean_start = i + 1;
                },
            }
        }
        // Flush remaining passthrough or inside_think text.
        switch (self.state) {
            .passthrough => {
                if (clean_start < text.len)
                    self.inner.emitChunk(text[clean_start..]);
            },
            .inside_think => {
                if (clean_start < text.len)
                    self.inner.emitChunk(text[clean_start..]);
            },
            else => {}, // buffering — don't flush mid-tag
        }
    }

    fn flushBuf(self: *ThinkPassthroughFilter) void {
        if (self.buf_len > 0) {
            // Incomplete tag at end of stream — emit as-is.
            self.inner.emitChunk(self.buf[0..self.buf_len]);
        }
        self.buf_len = 0;
        self.state = .passthrough;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn collectChunks(comptime max: usize) type {
    return struct {
        chunks: [max][]const u8 = undefined,
        count: usize = 0,
        got_final: bool = false,

        fn callback(ctx: *anyopaque, event: Event) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (event.stage == .final) {
                self.got_final = true;
                return;
            }
            if (self.count < max) {
                self.chunks[self.count] = event.text;
                self.count += 1;
            }
        }

        fn joined(self: *const @This(), buf: []u8) []const u8 {
            var pos: usize = 0;
            for (self.chunks[0..self.count]) |c| {
                @memcpy(buf[pos..][0..c.len], c);
                pos += c.len;
            }
            return buf[0..pos];
        }

        fn sink(self: *@This()) Sink {
            return .{ .callback = callback, .ctx = @ptrCast(self) };
        }
    };
}

test "TagFilter passthrough without tags" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("Hello ");
    s.emitChunk("world!");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Hello world!", col.joined(&buf));
    try std.testing.expect(col.got_final);
}

test "TagFilter strips complete tool_call in single chunk" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("Hi <tool_call>{\"name\":\"x\",\"arguments\":{}}</tool_call> bye");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Hi  bye", col.joined(&buf));
}

test "TagFilter strips tool_result with attributes" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("A<tool_result name=\"shell\" status=\"success\">output</tool_result>B");
    s.emitFinal();
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("AB", col.joined(&buf));
}

test "TagFilter strips tool_result without attributes" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("A<tool_result>output</tool_result>B");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("AB", col.joined(&buf));
}

test "TagFilter tag split across chunks" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("Hello <tool_c");
    s.emitChunk("all>{\"name\":\"x\"}</tool_call> world");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Hello  world", col.joined(&buf));
}

test "TagFilter close tag split across chunks" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("<tool_call>body</tool_");
    s.emitChunk("call>after");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("after", col.joined(&buf));
}

test "TagFilter false positive angle bracket" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("a < b > c");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a < b > c", col.joined(&buf));
}

test "TagFilter multiple tool calls" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("A<tool_call>1</tool_call>B<tool_call>2</tool_call>C");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("ABC", col.joined(&buf));
}

test "TagFilter incomplete open tag at end flushes on final" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("end<tool_c");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("end<tool_c", col.joined(&buf));
    try std.testing.expect(col.got_final);
}

// Regression: a provider (e.g. MiniMax-M3) whose raw output contains an open
// tag like "<think>" or "<tool_call>" that is NEVER followed by its matching
// close tag -- either a false-positive match on ordinary prose, or a genuine
// control token the model failed to close -- used to leave the filter stuck
// in .inside_tag for the rest of the stream, silently discarding every byte
// after the open tag. On a long article-length generation this reads as
// massive, seemingly-random text loss. The filter must give up looking for a
// close tag past a generous byte budget and resume passthrough so the rest
// of the real content survives.
test "TagFilter unterminated open tag past budget resumes passthrough" {
    var col = collectChunks(64){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("before<think>");
    // Well past max_suppressed_len (8192) with no close tag anywhere.
    var filler: [9000]u8 = undefined;
    @memset(&filler, 'x');
    s.emitChunk(&filler);
    s.emitChunk("after the giveup point, this must not be swallowed");
    s.emitFinal();
    var buf: [10240]u8 = undefined;
    const out = col.joined(&buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "after the giveup point, this must not be swallowed") != null);
}

test "TagFilter strips pipe-delimited tool_call control block" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("Before <|tool_call_begin|>{\"name\":\"shell\"}<|tool_call_end|> after");
    s.emitFinal();
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("Before  after", col.joined(&buf));
}

test "TagFilter strips pipe-delimited tool_result block split across chunks" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("A<|tool_result_be");
    s.emitChunk("gin|>hidden");
    s.emitChunk("<|tool_result_end|>B");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("AB", col.joined(&buf));
}

test "TagFilter strips pipe-delimited tool_calls section wrapper" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("Before <|tool_calls_section_begin|>");
    s.emitChunk("<|tool_call_begin|>{\"name\":\"shell\"}");
    s.emitChunk("<|tool_call_end|><|tool_calls_section_end|> after");
    s.emitFinal();
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("Before  after", col.joined(&buf));
}

test "TagFilter strips begin-style tool_call without pipe delimiters" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("A<tool_call_begin>{\"name\":\"shell\"}</tool_call>B");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("AB", col.joined(&buf));
}

test "TagFilter strips section wrapper with mixed pipe-delimited close tag" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("A<tool_calls_section_begin>");
    s.emitChunk("<tool_call_begin> functions.shell:5<{\"command\":\"pwd\"}</tool_call>");
    s.emitChunk("<tool_calls_section_end|>B");
    s.emitFinal();
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("AB", col.joined(&buf));
}

test "TagFilter strips think blocks split across chunks" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("Before <th");
    s.emitChunk("ink>private");
    s.emitChunk("</think> after");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Before  after", col.joined(&buf));
}

test "ThinkPassthroughFilter passthrough without think tags" {
    var col = collectChunks(16){};
    var filter = ThinkPassthroughFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("Hello world!");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Hello world!", col.joined(&buf));
    try std.testing.expect(col.got_final);
}

test "ThinkPassthroughFilter replaces think block with header and footer" {
    var col = collectChunks(16){};
    var filter = ThinkPassthroughFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("Before <think>reasoning here</think> after");
    s.emitFinal();
    var buf: [256]u8 = undefined;
    const expected = "Before " ++ THINK_HEADER ++ "reasoning here" ++ THINK_FOOTER ++ " after";
    try std.testing.expectEqualStrings(expected, col.joined(&buf));
}

test "ThinkPassthroughFilter think tag split across chunks" {
    var col = collectChunks(16){};
    var filter = ThinkPassthroughFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("Before <th");
    s.emitChunk("ink>private");
    s.emitChunk("</think> after");
    s.emitFinal();
    var buf: [256]u8 = undefined;
    const expected = "Before " ++ THINK_HEADER ++ "private" ++ THINK_FOOTER ++ " after";
    try std.testing.expectEqualStrings(expected, col.joined(&buf));
}

test "ThinkPassthroughFilter close tag split across chunks" {
    var col = collectChunks(16){};
    var filter = ThinkPassthroughFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("<think>body</thi");
    s.emitChunk("nk>after");
    s.emitFinal();
    var buf: [256]u8 = undefined;
    const expected = THINK_HEADER ++ "body" ++ THINK_FOOTER ++ "after";
    try std.testing.expectEqualStrings(expected, col.joined(&buf));
}

test "ThinkPassthroughFilter false positive angle bracket passes through" {
    var col = collectChunks(16){};
    var filter = ThinkPassthroughFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("a < b > c");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a < b > c", col.joined(&buf));
}

test "ThinkPassthroughFilter emits final on stream end" {
    var col = collectChunks(16){};
    var filter = ThinkPassthroughFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("text");
    s.emitFinal();
    try std.testing.expect(col.got_final);
}
