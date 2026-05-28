//! HTTP Gateway — lightweight HTTP server for nullclaw.
//!
//! Mirrors ZeroClaw's axum-based gateway with:
//!   - Sliding-window rate limiting (per-IP)
//!   - Idempotency store (deduplicates webhook requests)
//!   - Body size limits (configurable, default 64KB)
//!   - Request timeouts (configurable, default 30s)
//!   - Bearer token authentication (PairingGuard)
//!   - Endpoints: /health, /ready, /status, /doctor, /pair, /logout, /webhook, /a2a, /.well-known/agent-card.json, /whatsapp, /telegram, /line, /lark, /wechat, /wecom, /qq, /max, /slack/events, /api/messages (Teams)
//!
//! Uses std.http.Server (built-in, no external deps).

const builtin = @import("builtin");
const std = @import("std");
const std_compat = @import("compat");
const build_options = @import("build_options");
const daemon = @import("daemon.zig");
const doctor_mod = @import("doctor.zig");
const health = @import("health.zig");
const status_mod = @import("status.zig");
const Config = @import("config.zig").Config;
const config_types = @import("config_types.zig");
const fs_compat = @import("fs_compat.zig");
const session_mod = @import("session.zig");
const providers = @import("providers/root.zig");
const http_util = @import("http_util.zig");
const tools_mod = @import("tools/root.zig");
const memory_mod = @import("memory/root.zig");
const bootstrap_mod = @import("bootstrap/root.zig");
const subagent_mod = @import("subagent.zig");
const subagent_runner = @import("subagent_runner.zig");
const observability = @import("observability.zig");
const agent_routing = @import("agent_routing.zig");
const security = @import("security/policy.zig");
const audit_mod = @import("security/audit.zig");
const botframework_auth = @import("security/botframework_auth.zig");
const tencent_crypto = @import("security/tencent_crypto.zig");
const root_mod = @import("root.zig");
const PairingGuard = @import("security/pairing.zig").PairingGuard;
const constantTimeEq = @import("security/pairing.zig").constantTimeEq;
const isPublicBindHost = @import("security/pairing.zig").isPublicBind;
const channels = @import("channels/root.zig");
const bus_mod = @import("bus.zig");
const a2a = @import("a2a.zig");
const thread_stacks = @import("thread_stacks.zig");
const channel_adapters = @import("channel_adapters.zig");
const cron_mod = @import("cron.zig");
const cron_backend_mod = @import("cron/root.zig");
const cron_db_mod = @import("cron/db.zig");
const memory_loader = @import("agent/memory_loader.zig");
const ConversationContext = @import("agent/prompt.zig").ConversationContext;
const buildConversationContext = @import("agent/prompt.zig").buildConversationContext;
const log = std.log.scoped(.gateway);

/// Maximum request body size (64KB) — prevents memory exhaustion.
pub const MAX_BODY_SIZE: usize = 65_536;
const MAX_HEADER_SIZE: usize = 8_192;

/// Request timeout (30s) — prevents slow-loris attacks.
pub const REQUEST_TIMEOUT_SECS: u64 = 30;
const ACCEPT_POLL_INTERVAL_MS: u64 = 100;
const ACCEPT_ERROR_BACKOFF_MAX_MS: u64 = 1_000;
const ACCEPT_ERROR_LOG_INTERVAL: u32 = 20;

/// Sliding window for rate limiting (60s).
pub const RATE_LIMIT_WINDOW_SECS: u64 = 60;

/// How often the rate limiter sweeps stale IP entries (5 min).
const RATE_LIMITER_SWEEP_INTERVAL_SECS: u64 = 300;
const MAX_OBSERVED_TOOL_EVENTS: usize = 512;

const GatewayObservedToolEventKind = enum { start, result };

const GatewayObservedToolEvent = struct {
    seq: u64,
    kind: GatewayObservedToolEventKind,
    tool: []u8,
    success: bool = false,
};

const WebhookRouting = struct {
    sender_id: []const u8,
    chat_id: []const u8,
    session_key: []const u8,
    owned_session_key: ?[]const u8 = null,
    metadata_json: ?[]const u8 = null,
    conversation_context: ?ConversationContext = null,

    fn deinit(self: *WebhookRouting, allocator: std.mem.Allocator) void {
        if (self.owned_session_key) |owned| allocator.free(owned);
        if (self.metadata_json) |owned| allocator.free(owned);
    }
};

/// Audit callback for SecurityPolicy — bridges PolicyAuditEntry to AuditLogger.
fn auditPolicyCallback(ctx: *anyopaque, entry: security.PolicyAuditEntry) void {
    const logger: *audit_mod.AuditLogger = @ptrCast(@alignCast(ctx));
    var ev = audit_mod.AuditEvent.init(.policy_violation);
    ev.action = .{
        .command = entry.command,
        .risk_level = entry.risk_level.toString(),
        .approved = false,
        .allowed = entry.decision == .allowed,
    };
    ev.security = .{
        .policy_violation = entry.decision == .denied,
        .rate_limit_remaining = null,
        .sandbox_backend = null,
    };
    logger.log(&ev) catch {};
}

/// Scheduler snapshot callback for sensorium injection.
/// ctx points to GatewayState. Acquires scheduler_mutex briefly to read job state.
fn schedulerSnapshotCallback(ctx: *anyopaque) memory_loader.SensoriumData {
    const state: *GatewayState = @ptrCast(@alignCast(ctx));
    var sd = memory_loader.SensoriumData{};
    if (!state.scheduler_mutex.tryLock()) return sd;
    defer state.scheduler_mutex.unlock();
    const sched = state.scheduler orelse return sd;
    const jobs = sched.listJobs();
    sd.scheduler_jobs = @intCast(jobs.len);
    var nearest: ?i64 = null;
    var failures: u32 = 0;
    for (jobs) |job| {
        const nr = job.next_run_secs;
        if (nr > 0 and (nearest == null or nr < nearest.?)) nearest = nr;
        if (job.last_status) |status| {
            if (std.mem.eql(u8, status, "failed")) failures += 1;
        }
    }
    if (nearest) |nr| sd.scheduler_next_fire_secs = nr;
    sd.scheduler_recent_failures = failures;
    return sd;
}

fn simpleConversationContext(
    channel: []const u8,
    account_id: ?[]const u8,
    peer_id: []const u8,
    delivery_chat_id: ?[]const u8,
    is_group: bool,
    group_id: ?[]const u8,
) ?ConversationContext {
    return buildConversationContext(.{
        .channel = channel,
        .account_id = account_id,
        .delivery_chat_id = delivery_chat_id,
        .peer_id = peer_id,
        .is_group = is_group,
        .group_id = if (is_group) (group_id orelse peer_id) else null,
    });
}

fn appendWebhookMetadataField(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    wrote_field: *bool,
    key: []const u8,
    value: []const u8,
) !void {
    if (value.len == 0) return;
    if (wrote_field.*) try out.appendSlice(allocator, ",");
    wrote_field.* = true;
    try out.appendSlice(allocator, "\"");
    try out.appendSlice(allocator, key);
    try out.appendSlice(allocator, "\":");
    try root_mod.json_util.appendJsonString(out, allocator, value);
}

fn buildWebhookRoutingMetadataJson(
    allocator: std.mem.Allocator,
    account_id: ?[]const u8,
    peer_kind: ?agent_routing.ChatType,
    peer_id: ?[]const u8,
    sender_username: ?[]const u8,
    sender_display_name: ?[]const u8,
) ?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    out.append(allocator, '{') catch return null;
    var wrote_field = false;

    if (account_id) |value| {
        appendWebhookMetadataField(&out, allocator, &wrote_field, "account_id", value) catch return null;
    }
    if (peer_kind) |kind| {
        const kind_str = switch (kind) {
            .direct => "direct",
            .group => "group",
            .channel => "channel",
        };
        appendWebhookMetadataField(&out, allocator, &wrote_field, "peer_kind", kind_str) catch return null;
    }
    if (peer_id) |value| {
        appendWebhookMetadataField(&out, allocator, &wrote_field, "peer_id", value) catch return null;
    }
    if (sender_username) |value| {
        appendWebhookMetadataField(&out, allocator, &wrote_field, "sender_username", value) catch return null;
    }
    if (sender_display_name) |value| {
        appendWebhookMetadataField(&out, allocator, &wrote_field, "sender_display_name", value) catch return null;
    }

    out.append(allocator, '}') catch return null;
    if (!wrote_field) {
        out.deinit(allocator);
        return null;
    }
    return out.toOwnedSlice(allocator) catch null;
}

const GatewayTurnToolEvent = struct {
    kind: GatewayObservedToolEventKind,
    tool: []const u8,
    success: bool = false,
};

/// Thread-safe observer that records tool call events within the gateway.
/// Used to enrich webhook responses with tool execution summaries.
const GatewayThreadObserver = struct {
    allocator: std.mem.Allocator,
    mutex: std_compat.sync.Mutex = .{},
    next_seq: u64 = 0,
    events: std.ArrayListUnmanaged(GatewayObservedToolEvent) = .empty,

    const vtable = observability.Observer.VTable{
        .record_event = recordEvent,
        .record_metric = recordMetric,
        .flush = flush,
        .name = name,
        .get_trace_id = getTraceId,
        .set_trace_id = setTraceId,
    };

    pub fn init(allocator: std.mem.Allocator) GatewayThreadObserver {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *GatewayThreadObserver) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.events.items) |event| {
            self.allocator.free(event.tool);
        }
        self.events.deinit(self.allocator);
    }

    pub fn observer(self: *GatewayThreadObserver) observability.Observer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn currentSeq(self: *GatewayThreadObserver) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.next_seq;
    }

    pub fn collectSince(
        self: *GatewayThreadObserver,
        allocator: std.mem.Allocator,
        seq: u64,
    ) ![]GatewayTurnToolEvent {
        self.mutex.lock();
        defer self.mutex.unlock();

        var count: usize = 0;
        for (self.events.items) |event| {
            if (event.seq > seq) count += 1;
        }

        const out = try allocator.alloc(GatewayTurnToolEvent, count);
        errdefer allocator.free(out);
        var out_idx: usize = 0;
        errdefer {
            for (out[0..out_idx]) |event| {
                allocator.free(event.tool);
            }
        }
        for (self.events.items) |event| {
            if (event.seq <= seq) continue;

            out[out_idx] = .{
                .kind = event.kind,
                .tool = try allocator.dupe(u8, event.tool),
                .success = event.success,
            };
            out_idx += 1;
        }

        return out;
    }

    fn recordEvent(ptr: *anyopaque, event: *const observability.ObserverEvent) void {
        const self: *GatewayThreadObserver = @ptrCast(@alignCast(ptr));
        switch (event.*) {
            .tool_call_start => |e| self.appendEvent(.start, e.tool, false),
            .tool_call => |e| self.appendEvent(.result, e.tool, e.success),
            else => {},
        }
    }

    fn recordMetric(_: *anyopaque, _: *const observability.ObserverMetric) void {}
    fn flush(_: *anyopaque) void {}
    fn getTraceId(_: *anyopaque) ?[32]u8 {
        return null;
    }
    fn setTraceId(_: *anyopaque, _: [32]u8) void {}
    fn name(_: *anyopaque) []const u8 {
        return "gateway_thread";
    }

    fn appendEvent(
        self: *GatewayThreadObserver,
        kind: GatewayObservedToolEventKind,
        tool: []const u8,
        success: bool,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const owned_tool = self.allocator.dupe(u8, tool) catch return;

        self.next_seq += 1;
        self.events.append(self.allocator, .{
            .seq = self.next_seq,
            .kind = kind,
            .tool = owned_tool,
            .success = success,
        }) catch {
            self.allocator.free(owned_tool);
            return;
        };

        while (self.events.items.len > MAX_OBSERVED_TOOL_EVENTS) {
            const oldest = self.events.orderedRemove(0);
            self.allocator.free(oldest.tool);
        }
    }
};

// ── Rate Limiter ─────────────────────────────────────────────────

/// Sliding-window rate limiter. Tracks timestamps per key.
/// Not thread-safe by itself; callers must hold a lock.
pub const SlidingWindowRateLimiter = struct {
    limit_per_window: u32,
    window_ns: i128,
    /// Map of owned key bytes -> list of request timestamps (as nanoTimestamp values).
    entries: std.StringHashMapUnmanaged(std.ArrayList(i128)),
    last_sweep: i128,

    pub fn init(limit_per_window: u32, window_secs: u64) SlidingWindowRateLimiter {
        return .{
            .limit_per_window = limit_per_window,
            .window_ns = @as(i128, @intCast(window_secs)) * 1_000_000_000,
            .entries = .empty,
            .last_sweep = std_compat.time.nanoTimestamp(),
        };
    }

    pub fn deinit(self: *SlidingWindowRateLimiter, allocator: std.mem.Allocator) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.entries.deinit(allocator);
    }

    /// Returns true if the request is allowed, false if rate-limited.
    pub fn allow(self: *SlidingWindowRateLimiter, allocator: std.mem.Allocator, key: []const u8) bool {
        if (self.limit_per_window == 0) return true;

        const now = std_compat.time.nanoTimestamp();
        const cutoff = now - self.window_ns;

        // Periodic sweep
        if (now - self.last_sweep > @as(i128, RATE_LIMITER_SWEEP_INTERVAL_SECS) * 1_000_000_000) {
            self.sweep(allocator, cutoff);
            self.last_sweep = now;
        }

        const timestamps = blk: {
            if (self.entries.getPtr(key)) |existing| break :blk existing;

            const owned_key = allocator.dupe(u8, key) catch return true;
            self.entries.put(allocator, owned_key, .empty) catch {
                allocator.free(owned_key);
                return true;
            };
            break :blk self.entries.getPtr(key) orelse return true;
        };

        // Remove expired entries
        var i: usize = 0;
        while (i < timestamps.items.len) {
            if (timestamps.items[i] <= cutoff) {
                _ = timestamps.swapRemove(i);
            } else {
                i += 1;
            }
        }

        if (timestamps.items.len >= self.limit_per_window) return false;

        timestamps.append(allocator, now) catch return true;
        return true;
    }

    fn sweep(self: *SlidingWindowRateLimiter, allocator: std.mem.Allocator, cutoff: i128) void {
        var iter = self.entries.iterator();
        var to_remove: std.ArrayList([]const u8) = .empty;
        defer to_remove.deinit(allocator);

        while (iter.next()) |entry| {
            var timestamps = entry.value_ptr;
            var i: usize = 0;
            while (i < timestamps.items.len) {
                if (timestamps.items[i] <= cutoff) {
                    _ = timestamps.swapRemove(i);
                } else {
                    i += 1;
                }
            }
            if (timestamps.items.len == 0) {
                to_remove.append(allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.entries.fetchRemove(key)) |kv| {
                allocator.free(kv.key);
                var list = kv.value;
                list.deinit(allocator);
            }
        }
    }
};

// ── Gateway Rate Limiter ─────────────────────────────────────────

pub const GatewayRateLimiter = struct {
    pair: SlidingWindowRateLimiter,
    webhook: SlidingWindowRateLimiter,

    pub fn init(pair_per_minute: u32, webhook_per_minute: u32) GatewayRateLimiter {
        return .{
            .pair = SlidingWindowRateLimiter.init(pair_per_minute, RATE_LIMIT_WINDOW_SECS),
            .webhook = SlidingWindowRateLimiter.init(webhook_per_minute, RATE_LIMIT_WINDOW_SECS),
        };
    }

    pub fn deinit(self: *GatewayRateLimiter, allocator: std.mem.Allocator) void {
        self.pair.deinit(allocator);
        self.webhook.deinit(allocator);
    }

    pub fn allowPair(self: *GatewayRateLimiter, allocator: std.mem.Allocator, key: []const u8) bool {
        return self.pair.allow(allocator, key);
    }

    pub fn allowWebhook(self: *GatewayRateLimiter, allocator: std.mem.Allocator, key: []const u8) bool {
        return self.webhook.allow(allocator, key);
    }
};

// ── Idempotency Store ────────────────────────────────────────────

pub const IdempotencyStore = struct {
    ttl_ns: i128,
    /// Map of key -> timestamp when recorded.
    keys: std.StringHashMapUnmanaged(i128),

    pub fn init(ttl_secs: u64) IdempotencyStore {
        return .{
            .ttl_ns = @as(i128, @intCast(@max(ttl_secs, 1))) * 1_000_000_000,
            .keys = .empty,
        };
    }

    pub fn deinit(self: *IdempotencyStore, allocator: std.mem.Allocator) void {
        var iter = self.keys.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.keys.deinit(allocator);
    }

    /// Returns true if this key is new and is now recorded.
    /// Returns false if this is a duplicate.
    pub fn recordIfNew(self: *IdempotencyStore, allocator: std.mem.Allocator, key: []const u8) bool {
        const now = std_compat.time.nanoTimestamp();
        const cutoff = now - self.ttl_ns;

        // Clean expired keys (simple sweep)
        var iter = self.keys.iterator();
        var to_remove: std.ArrayList([]const u8) = .empty;
        defer to_remove.deinit(allocator);
        while (iter.next()) |entry| {
            if (entry.value_ptr.* < cutoff) {
                to_remove.append(allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (to_remove.items) |k| {
            if (self.keys.fetchRemove(k)) |kv| {
                allocator.free(kv.key);
            }
        }

        // Check if already present after removing expired entries. Idempotency
        // keys are exact identifiers; do not truncate or prefix-match them.
        if (self.keys.get(key)) |_| return false;

        // Record new key
        const duped_key = allocator.dupe(u8, key) catch return true;
        self.keys.put(allocator, duped_key, now) catch {
            allocator.free(duped_key);
            return true;
        };
        return true;
    }
};

// ── Gateway server ───────────────────────────────────────────────

/// Gateway server state, shared across request handlers.
pub const GatewayState = struct {
    allocator: std.mem.Allocator,
    rate_limiter: GatewayRateLimiter,
    idempotency: IdempotencyStore,
    // Security policy for runtime enforcement (including cron shell jobs).
    // Owned by GatewayState; freed in deinit().
    security_policy: ?*security.SecurityPolicy = null,
    // Heap-owned RateTracker backing the policy's sliding window. Must be deinit()+destroyed.
    security_tracker: ?*security.RateTracker = null,
    whatsapp_verify_token: []const u8,
    whatsapp_app_secret: []const u8,
    whatsapp_access_token: []const u8,
    whatsapp_account_id: []const u8 = "default",
    telegram_bot_token: []const u8,
    telegram_account_id: []const u8 = "default",
    telegram_allow_from: []const []const u8 = &.{},
    whatsapp_allow_from: []const []const u8 = &.{},
    whatsapp_group_allow_from: []const []const u8 = &.{},
    whatsapp_groups: []const []const u8 = &.{},
    whatsapp_group_policy: []const u8 = "allowlist",
    line_channel_secret: []const u8 = "",
    line_access_token: []const u8 = "",
    line_account_id: []const u8 = "default",
    line_allow_from: []const []const u8 = &.{},
    lark_verification_token: []const u8 = "",
    lark_app_id: []const u8 = "",
    lark_app_secret: []const u8 = "",
    lark_account_id: []const u8 = "default",
    lark_allow_from: []const []const u8 = &.{},
    wechat_account_id: []const u8 = "default",
    wechat_allow_from: []const []const u8 = &.{},
    wechat_callback_token: []const u8 = "",
    wechat_encoding_aes_key: []const u8 = "",
    wechat_app_id: []const u8 = "",
    wecom_account_id: []const u8 = "default",
    wecom_allow_from: []const []const u8 = &.{},
    wecom_callback_token: []const u8 = "",
    wecom_encoding_aes_key: []const u8 = "",
    wecom_corp_id: []const u8 = "",
    qq_channels: std.ArrayListUnmanaged(channels.qq.QQChannel) = .empty,
    teams_auth_cache: botframework_auth.KeyCache = .{},
    pairing_guard: ?PairingGuard,
    event_bus: ?*bus_mod.Bus = null,

    // Scheduler pointer and mutex — set by the daemon's scheduler thread via
    // setSharedScheduler so HTTP cron handlers can access it safely.
    scheduler: ?*cron_mod.CronScheduler = null,
    scheduler_mutex: std_compat.sync.Mutex = .{},

    // Path to the SQLite cron DB — used by DB-direct functions (runQueueWorker,
    // dbTickAndEnqueue, future handler rewrites). Populated in gateway.run().
    cron_db_path: ?[:0]const u8 = null,

    // Working directory for DB-backed cron child processes — mirrors the
    // shell_cwd used by the legacy in-memory scheduler path.
    cron_workspace_dir: ?[]const u8 = null,

    // CronBackend vtable — set by gateway.run() after cron_db_path is populated.
    // runQueueWorker uses this for atomic dequeue+claim. Null until gateway.run() starts.
    cron_db_backend: ?cron_db_mod.DbCronBackend = null,

    // Alert delivery destination for DB-backed skill job failures.
    // Mirrors CronScheduler.alert_delivery for the run queue worker path.
    alert_delivery: ?cron_mod.DeliveryConfig = null,

    // Job run queue — handleCronRun enqueues job IDs here; a single worker
    // thread pops and executes them sequentially to avoid concurrent Telegram
    // deliveries racing each other.
    run_queue: std.ArrayListUnmanaged([]const u8) = .empty,
    run_queue_mutex: std_compat.sync.Mutex = .{},
    run_queue_cond: std_compat.sync.Condition = .{},
    run_queue_stop: bool = false,
    run_queue_thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator) GatewayState {
        return initWithVerifyToken(allocator, "");
    }

    pub fn initWithVerifyToken(allocator: std.mem.Allocator, verify_token: []const u8) GatewayState {
        return .{
            .allocator = allocator,
            .rate_limiter = GatewayRateLimiter.init(10, 30),
            .idempotency = IdempotencyStore.init(300),
            .whatsapp_verify_token = verify_token,
            .whatsapp_app_secret = "",
            .whatsapp_access_token = "",
            .telegram_bot_token = "",
            .pairing_guard = null,
        };
    }

    /// Start the single-threaded job run worker.
    pub fn startRunQueue(self: *GatewayState) !void {
        self.run_queue_thread = try std.Thread.spawn(.{}, runQueueWorker, .{self});
    }

    /// Signal the worker to stop and wait for it to exit.
    pub fn stopRunQueue(self: *GatewayState) void {
        {
            self.run_queue_mutex.lock();
            defer self.run_queue_mutex.unlock();
            self.run_queue_stop = true;
            self.run_queue_cond.signal();
        }
        if (self.run_queue_thread) |t| {
            t.join();
            self.run_queue_thread = null;
        }
        // Free any remaining queued ids.
        for (self.run_queue.items) |id| self.allocator.free(id);
        self.run_queue.deinit(self.allocator);
        self.run_queue = .empty;
    }

    /// Enqueue a job id for sequential execution. Takes ownership of id_dupe.
    pub fn enqueueRunJob(self: *GatewayState, id_dupe: []const u8) !void {
        self.run_queue_mutex.lock();
        defer self.run_queue_mutex.unlock();
        try self.run_queue.append(self.allocator, id_dupe);
        self.run_queue_cond.signal();
    }

    pub fn deinit(self: *GatewayState) void {
        self.stopRunQueue();
        for (self.qq_channels.items) |*qq_ch| {
            qq_ch.channel().stop();
        }
        self.qq_channels.deinit(self.allocator);
        self.rate_limiter.deinit(self.allocator);
        self.idempotency.deinit(self.allocator);
        self.teams_auth_cache.deinit(self.allocator);
        if (self.pairing_guard) |*guard| {
            guard.deinit();
        }
        // Free the heap-allocated security policy + its backing tracker (Issue A).
        // The tracker owns an ArrayList that must be explicitly deinit()ed.
        if (self.security_policy) |p| {
            self.allocator.destroy(p);
        }
        if (self.security_tracker) |t| {
            t.deinit();
            self.allocator.destroy(t);
        }
    }
};

/// Publish an inbound message to the event bus. Returns true on success.
fn publishToBus(
    eb: *bus_mod.Bus,
    allocator: std.mem.Allocator,
    channel: []const u8,
    sender_id: []const u8,
    chat_id: []const u8,
    content: []const u8,
    session_key: []const u8,
    metadata_json: ?[]const u8,
) bool {
    const msg = bus_mod.makeInboundFull(
        allocator,
        channel,
        sender_id,
        chat_id,
        content,
        session_key,
        &.{},
        metadata_json,
    ) catch return false;
    eb.publishInbound(msg) catch {
        msg.deinit(allocator);
        return false;
    };
    return true;
}

/// Check if all registered health components are OK.
fn isHealthOk() bool {
    return health.allComponentsOk();
}

/// Readiness response — encapsulates HTTP status and body for /ready.
pub const ReadyResponse = struct {
    http_status: []const u8,
    body: []const u8,
    /// Whether body was allocated and should be freed by caller.
    allocated: bool,
};

/// Handle the /ready endpoint logic. Queries the global health registry
/// and returns the appropriate HTTP status and JSON body.
/// If `allocated` is true in the result, the caller owns `body` memory.
pub fn handleReady(allocator: std.mem.Allocator) ReadyResponse {
    const readiness = health.checkRegistryReadiness(allocator) catch {
        return .{
            .http_status = "500 Internal Server Error",
            .body = "{\"status\":\"not_ready\",\"checks\":[]}",
            .allocated = false,
        };
    };
    defer readiness.deinit(allocator);

    const json_body = readiness.formatJson(allocator) catch {
        return .{
            .http_status = "500 Internal Server Error",
            .body = "{\"status\":\"not_ready\",\"checks\":[]}",
            .allocated = false,
        };
    };
    return .{
        .http_status = if (readiness.status == .ready) "200 OK" else "503 Service Unavailable",
        .body = json_body,
        .allocated = true,
    };
}

/// Extract a query parameter value from a URL target string.
/// e.g. parseQueryParam("/whatsapp?hub.mode=subscribe&hub.challenge=abc", "hub.challenge") => "abc"
/// Returns null if the parameter is not found.
pub fn parseQueryParam(target: []const u8, name: []const u8) ?[]const u8 {
    const qmark = std.mem.indexOf(u8, target, "?") orelse return null;
    var query = target[qmark + 1 ..];

    while (query.len > 0) {
        // Find end of this key=value pair
        const amp = std.mem.indexOf(u8, query, "&") orelse query.len;
        const pair = query[0..amp];

        // Split on '='
        const eq = std.mem.indexOf(u8, pair, "=");
        if (eq) |eq_pos| {
            const key = pair[0..eq_pos];
            const value = pair[eq_pos + 1 ..];
            if (std.mem.eql(u8, key, name)) return value;
        }

        // Advance past the '&'
        if (amp < query.len) {
            query = query[amp + 1 ..];
        } else {
            break;
        }
    }
    return null;
}

// ── Bearer Token Validation ──────────────────────────────────────

/// Validate a bearer token against a list of paired tokens.
/// Returns true if paired_tokens is empty (backwards compat) or token matches.
pub fn validateBearerToken(token: []const u8, paired_tokens: []const []const u8) bool {
    if (paired_tokens.len == 0) return true;
    for (paired_tokens) |pt| {
        if (constantTimeEq(token, pt)) return true;
    }
    return false;
}

/// Extract the value of a named header from raw HTTP bytes.
/// Searches for "Name: value\r\n" (case-insensitive name match).
pub fn extractHeader(raw: []const u8, name: []const u8) ?[]const u8 {
    // Skip past the first line (request line)
    var pos: usize = 0;
    while (pos + 1 < raw.len) {
        if (raw[pos] == '\r' and raw[pos + 1] == '\n') {
            pos += 2;
            break;
        }
        pos += 1;
    }

    // Scan headers
    while (pos < raw.len) {
        // Find end of this header line
        const line_end = std.mem.indexOf(u8, raw[pos..], "\r\n") orelse break;
        const line = raw[pos .. pos + line_end];
        if (line.len == 0) break; // empty line = end of headers

        // Check if this line starts with "name:"
        if (line.len > name.len and line[name.len] == ':') {
            const header_name = line[0..name.len];
            if (asciiEqlIgnoreCase(header_name, name)) {
                // Skip ": " and any leading whitespace
                var val_start: usize = name.len + 1;
                while (val_start < line.len and line[val_start] == ' ') val_start += 1;
                return line[val_start..];
            }
        }

        pos += line_end + 2;
    }
    return null;
}

/// Extract the bearer token from an Authorization header value.
/// "Bearer <token>" -> "<token>", or null if format doesn't match.
pub fn extractBearerToken(auth_header: []const u8) ?[]const u8 {
    const prefix = "Bearer ";
    if (auth_header.len > prefix.len and std.mem.startsWith(u8, auth_header, prefix)) {
        return auth_header[prefix.len..];
    }
    return null;
}

/// Returns true when a webhook request should be accepted for the current
/// pairing state and bearer token. Missing pairing state fails closed.
pub fn isWebhookAuthorized(pairing_guard: ?*const PairingGuard, bearer_token: ?[]const u8) bool {
    const guard = pairing_guard orelse return false;
    if (!guard.requirePairing()) return true;
    const token = bearer_token orelse return false;
    return guard.isAuthenticated(token);
}

/// Returns true when a generic gateway endpoint (/webhook, /cron, /a2a) should
/// be accepted for the current bind exposure and bearer token. Public binds
/// always require a valid stored bearer token, even when interactive pairing is
/// disabled, so generic endpoints cannot silently become anonymous Internet
/// entrypoints.
pub fn isGenericGatewayEndpointAuthorized(
    pairing_guard: ?*const PairingGuard,
    bearer_token: ?[]const u8,
    public_bind: bool,
) bool {
    if (!public_bind) return isWebhookAuthorized(pairing_guard, bearer_token);

    const guard = pairing_guard orelse return false;
    const token = bearer_token orelse return false;
    if (guard.requirePairing()) return guard.isAuthenticated(token);
    if (!guard.hasPairedTokens()) return false;
    return guard.matchesStoredToken(token);
}

fn shouldSyncWebhookForWorker(
    config_opt: ?*const Config,
    pairing_guard: ?*const PairingGuard,
    bearer_token: ?[]const u8,
) bool {
    const cfg = config_opt orelse return false;
    if (!cfg.gateway.webhook_sync_for_workers) return false;
    const guard = pairing_guard orelse return false;
    const token = bearer_token orelse return false;
    return guard.matchesConfiguredToken(token);
}

fn isPairEndpointAllowed(public_bind: bool, client_identifier: []const u8) bool {
    return !public_bind or !isPublicBindHost(client_identifier);
}

/// Revoke a currently authenticated bearer token. Returns false when pairing is
/// unavailable, disabled, or the token is missing/invalid.
pub fn revokeAuthorizedBearerToken(pairing_guard: ?*PairingGuard, bearer_token: ?[]const u8) bool {
    const guard = pairing_guard orelse return false;
    if (!guard.requirePairing()) return false;
    const token = bearer_token orelse return false;
    if (!guard.isAuthenticated(token)) return false;
    return guard.revokeToken(token);
}

fn isAdminRouteAuthorized(pairing_guard: ?*const PairingGuard, bearer_token: ?[]const u8) bool {
    const guard = pairing_guard orelse return true;
    if (!guard.requirePairing()) return true;
    if (!guard.hasPairedTokens()) return false;
    return isWebhookAuthorized(pairing_guard, bearer_token);
}

fn isCronRouteAuthorized(pairing_guard: ?*const PairingGuard, bearer_token: ?[]const u8, public_bind: bool) bool {
    if (public_bind) return isGenericGatewayEndpointAuthorized(pairing_guard, bearer_token, true);
    return isAdminRouteAuthorized(pairing_guard, bearer_token);
}

/// Format the /pair success payload. Returns null when buffer is too small.
pub fn formatPairSuccessResponse(buf: []u8, token: []const u8, expires_in_secs: u32) ?[]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{{\"status\":\"paired\",\"token\":\"{s}\",\"expires_in\":{d}}}",
        .{ token, expires_in_secs },
    ) catch null;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        const al = if (ac >= 'A' and ac <= 'Z') ac + 32 else ac;
        const bl = if (bc >= 'A' and bc <= 'Z') bc + 32 else bc;
        if (al != bl) return false;
    }
    return true;
}

fn asciiEndsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    if (suffix.len > haystack.len) return false;
    return asciiEqlIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
}

// ── WhatsApp HMAC-SHA256 Signature Verification ─────────────────

/// Verify a WhatsApp webhook HMAC-SHA256 signature.
///
/// Meta sends `X-Hub-Signature-256: sha256=<hex-digest>` on every webhook POST.
/// This function computes HMAC-SHA256 over `body` using `app_secret` as the key,
/// then performs a constant-time comparison against the hex digest in the header.
///
/// Returns `true` if the signature is valid, `false` otherwise.
pub fn verifyWhatsappSignature(body: []const u8, signature_header: []const u8, app_secret: []const u8) bool {
    // Reject empty secrets — misconfiguration guard
    if (app_secret.len == 0) return false;

    // Header must start with "sha256="
    const prefix = "sha256=";
    if (!std.mem.startsWith(u8, signature_header, prefix)) return false;

    const provided_hex = signature_header[prefix.len..];

    // HMAC-SHA256 digest is 32 bytes = 64 hex chars
    if (provided_hex.len != 64) return false;

    // Decode the provided hex string into bytes
    const provided_bytes = hexDecode(provided_hex) orelse return false;

    // Compute expected HMAC-SHA256
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var expected: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&expected, body, app_secret);

    // Constant-time comparison — prevents timing side-channels
    return constantTimeEql(&expected, &provided_bytes);
}

/// Decode a 64-char lowercase hex string into 32 bytes.
/// Returns null if any character is not a valid hex digit.
fn hexDecode(hex: []const u8) ?[32]u8 {
    if (hex.len != 64) return null;
    var out: [32]u8 = undefined;
    for (0..32) |i| {
        const hi = hexVal(hex[i * 2]) orelse return null;
        const lo = hexVal(hex[i * 2 + 1]) orelse return null;
        out[i] = (hi << 4) | lo;
    }
    return out;
}

/// Convert a single hex character to its 4-bit value.
fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

/// Constant-time comparison of two 32-byte arrays.
/// Always examines all bytes regardless of where a mismatch occurs.
fn constantTimeEql(a: *const [32]u8, b: *const [32]u8) bool {
    var diff: u8 = 0;
    for (a, b) |ab, bb| {
        diff |= ab ^ bb;
    }
    return diff == 0;
}

// ── JSON Helpers ────────────────────────────────────────────────

/// Escape a string for safe embedding inside a JSON string value.
/// Handles: \ → \\, " → \", control chars (0x00-0x1F) → \uXXXX,
/// newlines → \n, tabs → \t, carriage returns → \r.
pub fn jsonEscapeInto(writer: anytype, input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

/// Wrap a value as a JSON string field: `"key":"escaped_value"`.
/// Returns an owned slice allocated with the provided allocator.
pub fn jsonWrapField(allocator: std.mem.Allocator, key: []const u8, value: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var buf_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const w = &buf_writer.writer;
    try w.writeByte('"');
    try w.writeAll(key);
    try w.writeAll("\":\"");
    try jsonEscapeInto(w, value);
    try w.writeByte('"');
    buf = buf_writer.toArrayList();
    return buf.toOwnedSlice(allocator);
}

/// Build a JSON response object: `{"status":"ok","response":"<escaped>"}`.
/// Returns an owned slice. Caller must free.
pub fn jsonWrapResponse(allocator: std.mem.Allocator, response: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var buf_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const w = &buf_writer.writer;
    try w.writeAll("{\"status\":\"ok\",\"response\":\"");
    try jsonEscapeInto(w, response);
    try w.writeAll("\"}");
    buf = buf_writer.toArrayList();
    return buf.toOwnedSlice(allocator);
}

/// Build a JSON array summarizing tool events from a turn.
fn buildThreadEventsJson(
    allocator: std.mem.Allocator,
    tool_events: []const GatewayTurnToolEvent,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var buf_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const w = &buf_writer.writer;

    try w.writeByte('[');

    var tool_results: usize = 0;
    var failed_results: usize = 0;
    for (tool_events) |event| {
        if (event.kind != .result) continue;
        tool_results += 1;
        if (!event.success) failed_results += 1;
    }

    if (tool_results > 0) {
        try w.writeAll("{\"type\":\"tool_summary\",\"total\":");
        try w.print("{d}", .{tool_results});
        try w.writeAll(",\"failed\":");
        try w.print("{d}", .{failed_results});
        try w.writeByte('}');
    }

    try w.writeByte(']');
    buf = buf_writer.toArrayList();
    return buf.toOwnedSlice(allocator);
}

/// Build a webhook success response with tool events:
/// `{"status":"ok","response":"<escaped>","thread_events":[...]}`.
fn buildWebhookSuccessResponse(
    allocator: std.mem.Allocator,
    response_text: []const u8,
    thread_events_json: []const u8,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var buf_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const w = &buf_writer.writer;
    try w.writeAll("{\"status\":\"ok\",\"response\":\"");
    try jsonEscapeInto(w, response_text);
    try w.writeAll("\",\"thread_events\":");
    try w.writeAll(thread_events_json);
    try w.writeByte('}');
    buf = buf_writer.toArrayList();
    return buf.toOwnedSlice(allocator);
}

/// Build a JSON challenge response: `{"challenge":"<escaped>"}`.
/// Returns an owned slice. Caller must free.
fn jsonWrapChallenge(allocator: std.mem.Allocator, challenge: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var buf_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const w = &buf_writer.writer;
    try w.writeAll("{\"challenge\":\"");
    try jsonEscapeInto(w, challenge);
    try w.writeAll("\"}");
    buf = buf_writer.toArrayList();
    return buf.toOwnedSlice(allocator);
}

/// Extract a string field from a JSON blob (minimal parser, no allocations).
pub fn jsonStringField(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    // Skip whitespace and colon
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or
        after_key[i] == '\t' or after_key[i] == '\n' or after_key[i] == '\r')) : (i += 1)
    {}

    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1; // skip opening quote

    // Find closing quote (handle escaped quotes)
    const start = i;
    while (i < after_key.len) : (i += 1) {
        if (after_key[i] == '\\' and i + 1 < after_key.len) {
            i += 1;
            continue;
        }
        if (after_key[i] == '"') {
            return after_key[start..i];
        }
    }
    return null;
}

fn isJsonObjectPayload(allocator: std.mem.Allocator, body: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return false;
    defer parsed.deinit();
    return parsed.value == .object;
}

/// Extract an integer field from a JSON blob.
pub fn jsonIntField(json: []const u8, key: []const u8) ?i64 {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    // Skip whitespace and colon
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or
        after_key[i] == '\t' or after_key[i] == '\n' or after_key[i] == '\r')) : (i += 1)
    {}

    if (i >= after_key.len) return null;

    // Parse integer (possibly negative)
    const is_negative = after_key[i] == '-';
    if (is_negative) i += 1;
    if (i >= after_key.len or after_key[i] < '0' or after_key[i] > '9') return null;

    var result: i64 = 0;
    while (i < after_key.len and after_key[i] >= '0' and after_key[i] <= '9') : (i += 1) {
        result = result * 10 + @as(i64, after_key[i] - '0');
    }
    return if (is_negative) -result else result;
}

fn findWhatsAppConfigByVerifyToken(cfg: *const Config, verify_token: []const u8) ?*const config_types.WhatsAppConfig {
    for (cfg.channels.whatsapp) |*wa_cfg| {
        if (std.mem.eql(u8, wa_cfg.verify_token, verify_token)) return wa_cfg;
    }
    return null;
}

fn findWhatsAppConfigByPhoneNumberId(cfg: *const Config, phone_number_id: []const u8) ?*const config_types.WhatsAppConfig {
    for (cfg.channels.whatsapp) |*wa_cfg| {
        if (std.mem.eql(u8, wa_cfg.phone_number_id, phone_number_id)) return wa_cfg;
    }
    return null;
}

fn selectWhatsAppConfig(
    cfg_opt: ?*const Config,
    body: ?[]const u8,
    verify_token: ?[]const u8,
) ?*const config_types.WhatsAppConfig {
    if (!build_options.enable_channel_whatsapp) return null;
    const cfg = cfg_opt orelse return null;
    if (cfg.channels.whatsapp.len == 0) return null;

    if (verify_token) |token| {
        if (findWhatsAppConfigByVerifyToken(cfg, token)) |wa_cfg| {
            return wa_cfg;
        }
    }

    if (body) |b| {
        if (jsonStringField(b, "phone_number_id")) |phone_number_id| {
            if (findWhatsAppConfigByPhoneNumberId(cfg, phone_number_id)) |wa_cfg| {
                return wa_cfg;
            }
        }
    }

    return &cfg.channels.whatsapp[0];
}

fn findTelegramConfigByAccountId(cfg: *const Config, account_id: []const u8) ?*const config_types.TelegramConfig {
    for (cfg.channels.telegram) |*tg_cfg| {
        if (std.ascii.eqlIgnoreCase(tg_cfg.account_id, account_id)) return tg_cfg;
    }
    return null;
}

fn selectTelegramConfig(
    cfg_opt: ?*const Config,
    target: []const u8,
) ?*const config_types.TelegramConfig {
    if (!build_options.enable_channel_telegram) return null;
    const cfg = cfg_opt orelse return null;
    if (cfg.channels.telegram.len == 0) return null;

    if (parseQueryParam(target, "account_id")) |account_id| {
        if (findTelegramConfigByAccountId(cfg, account_id)) |tg_cfg| {
            return tg_cfg;
        }
    }
    if (parseQueryParam(target, "account")) |account_id| {
        if (findTelegramConfigByAccountId(cfg, account_id)) |tg_cfg| {
            return tg_cfg;
        }
    }

    if (cfg.channels.telegramPrimary()) |primary| {
        if (findTelegramConfigByAccountId(cfg, primary.account_id)) |tg_cfg| {
            return tg_cfg;
        }
    }
    return &cfg.channels.telegram[0];
}

fn findMaxConfigByAccountId(cfg: *const Config, account_id: []const u8) ?*const config_types.MaxConfig {
    for (cfg.channels.max) |*max_cfg| {
        if (std.ascii.eqlIgnoreCase(max_cfg.account_id, account_id)) return max_cfg;
    }
    return null;
}

fn findMaxConfigByWebhookSecret(cfg: *const Config, secret: []const u8) ?*const config_types.MaxConfig {
    for (cfg.channels.max) |*max_cfg| {
        if (max_cfg.webhook_secret) |configured_secret| {
            if (configured_secret.len > 0 and std.mem.eql(u8, configured_secret, secret)) return max_cfg;
        }
    }
    return null;
}

fn countMaxWebhookAccounts(cfg: *const Config) usize {
    var count: usize = 0;
    for (cfg.channels.max) |max_cfg| {
        if (max_cfg.mode == .webhook) count += 1;
    }
    return count;
}

fn selectMaxConfig(
    cfg_opt: ?*const Config,
    target: []const u8,
    secret_header: ?[]const u8,
) ?*const config_types.MaxConfig {
    if (!build_options.enable_channel_max) return null;
    const cfg = cfg_opt orelse return null;
    if (cfg.channels.max.len == 0) return null;

    if (parseQueryParam(target, "account_id")) |account_id| {
        return findMaxConfigByAccountId(cfg, account_id);
    }
    if (parseQueryParam(target, "account")) |account_id| {
        return findMaxConfigByAccountId(cfg, account_id);
    }

    if (secret_header) |raw_secret| {
        const secret = std.mem.trim(u8, raw_secret, " \t\r\n");
        if (secret.len > 0) {
            return findMaxConfigByWebhookSecret(cfg, secret);
        }
    }

    const webhook_count = countMaxWebhookAccounts(cfg);
    if (webhook_count == 1) {
        for (cfg.channels.max) |*max_cfg| {
            if (max_cfg.mode == .webhook) return max_cfg;
        }
    }

    if (cfg.channels.max.len == 1) {
        return &cfg.channels.max[0];
    }

    return null;
}

fn hasLineSecrets(cfg: *const Config) bool {
    if (!build_options.enable_channel_line) return false;
    for (cfg.channels.line) |line_cfg| {
        if (line_cfg.channel_secret.len > 0) return true;
    }
    return false;
}

fn selectLineConfigBySignature(
    cfg_opt: ?*const Config,
    body: []const u8,
    signature: ?[]const u8,
) ?*const config_types.LineConfig {
    if (!build_options.enable_channel_line) return null;
    const cfg = cfg_opt orelse return null;
    if (cfg.channels.line.len == 0) return null;

    if (signature) |sig| {
        for (cfg.channels.line) |*line_cfg| {
            if (channels.line.LineChannel.verifySignature(body, sig, line_cfg.channel_secret)) {
                return line_cfg;
            }
        }
        return null;
    }

    return &cfg.channels.line[0];
}

fn findLarkConfigByVerificationToken(
    cfg: *const Config,
    verification_token: []const u8,
) ?*const config_types.LarkConfig {
    for (cfg.channels.lark) |*lark_cfg| {
        if (std.mem.eql(u8, lark_cfg.verification_token orelse "", verification_token)) {
            return lark_cfg;
        }
    }
    return null;
}

fn selectLarkConfig(
    cfg_opt: ?*const Config,
    body: []const u8,
) ?*const config_types.LarkConfig {
    if (!build_options.enable_channel_lark) return null;
    const cfg = cfg_opt orelse return null;
    if (cfg.channels.lark.len == 0) return null;

    if (jsonStringField(body, "token")) |verification_token| {
        if (findLarkConfigByVerificationToken(cfg, verification_token)) |lark_cfg| {
            return lark_cfg;
        }
    }

    return &cfg.channels.lark[0];
}

fn findWeComConfigByAccountId(
    cfg: *const Config,
    account_id: []const u8,
) ?*const config_types.WeComConfig {
    for (cfg.channels.wecom) |*wecom_cfg| {
        if (std.ascii.eqlIgnoreCase(wecom_cfg.account_id, account_id)) return wecom_cfg;
    }
    return null;
}

fn findWeChatConfigByAccountId(
    cfg: *const Config,
    account_id: []const u8,
) ?*const config_types.WeChatConfig {
    for (cfg.channels.wechat) |*wechat_cfg| {
        if (std.ascii.eqlIgnoreCase(wechat_cfg.account_id, account_id)) return wechat_cfg;
    }
    return null;
}

fn selectWeChatConfig(
    cfg_opt: ?*const Config,
    target: []const u8,
) ?*const config_types.WeChatConfig {
    if (!build_options.enable_channel_wechat) return null;
    const cfg = cfg_opt orelse return null;
    if (cfg.channels.wechat.len == 0) return null;

    if (parseQueryParam(target, "account_id")) |account_id| {
        if (findWeChatConfigByAccountId(cfg, account_id)) |wechat_cfg| {
            return wechat_cfg;
        }
    }
    if (parseQueryParam(target, "account")) |account_id| {
        if (findWeChatConfigByAccountId(cfg, account_id)) |wechat_cfg| {
            return wechat_cfg;
        }
    }

    if (cfg.channels.wechatPrimary()) |primary| {
        if (findWeChatConfigByAccountId(cfg, primary.account_id)) |wechat_cfg| {
            return wechat_cfg;
        }
    }

    return &cfg.channels.wechat[0];
}

fn selectWeComConfig(
    cfg_opt: ?*const Config,
    target: []const u8,
) ?*const config_types.WeComConfig {
    if (!build_options.enable_channel_wecom) return null;
    const cfg = cfg_opt orelse return null;
    if (cfg.channels.wecom.len == 0) return null;

    if (parseQueryParam(target, "account_id")) |account_id| {
        if (findWeComConfigByAccountId(cfg, account_id)) |wecom_cfg| {
            return wecom_cfg;
        }
    }
    if (parseQueryParam(target, "account")) |account_id| {
        if (findWeComConfigByAccountId(cfg, account_id)) |wecom_cfg| {
            return wecom_cfg;
        }
    }

    if (cfg.channels.wecomPrimary()) |primary| {
        if (findWeComConfigByAccountId(cfg, primary.account_id)) |wecom_cfg| {
            return wecom_cfg;
        }
    }

    return &cfg.channels.wecom[0];
}

fn findQqConfigByAccountId(cfg: *const Config, account_id: []const u8) ?*const config_types.QQConfig {
    for (cfg.channels.qq) |*qq_cfg| {
        if (std.ascii.eqlIgnoreCase(qq_cfg.account_id, account_id)) return qq_cfg;
    }
    return null;
}

fn findQqConfigByAppId(cfg: *const Config, app_id: []const u8) ?*const config_types.QQConfig {
    for (cfg.channels.qq) |*qq_cfg| {
        if (std.mem.eql(u8, qq_cfg.app_id, app_id)) return qq_cfg;
    }
    return null;
}

fn selectQqConfig(
    cfg_opt: ?*const Config,
    target: []const u8,
    app_id_header: ?[]const u8,
) ?*const config_types.QQConfig {
    if (!build_options.enable_channel_qq) return null;
    const cfg = cfg_opt orelse return null;
    if (cfg.channels.qq.len == 0) return null;

    if (parseQueryParam(target, "account_id")) |account_id| {
        if (findQqConfigByAccountId(cfg, account_id)) |qq_cfg| {
            return qq_cfg;
        }
    }
    if (parseQueryParam(target, "account")) |account_id| {
        if (findQqConfigByAccountId(cfg, account_id)) |qq_cfg| {
            return qq_cfg;
        }
    }

    if (app_id_header) |raw_app_id| {
        const app_id = std.mem.trim(u8, raw_app_id, " \t\r\n");
        if (app_id.len > 0) {
            if (findQqConfigByAppId(cfg, app_id)) |qq_cfg| {
                return qq_cfg;
            }
        }
    }

    if (cfg.channels.qqPrimary()) |primary| {
        if (findQqConfigByAccountId(cfg, primary.account_id)) |qq_cfg| {
            return qq_cfg;
        }
    }

    return &cfg.channels.qq[0];
}

fn findQqRuntimeChannel(state: *GatewayState, account_id: []const u8) ?*channels.qq.QQChannel {
    for (state.qq_channels.items) |*qq_ch| {
        if (std.ascii.eqlIgnoreCase(qq_ch.config.account_id, account_id)) return qq_ch;
    }
    return null;
}

fn webhookBasePath(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |qi| return target[0..qi];
    return target;
}

fn normalizeSlackWebhookPath(path: []const u8) []const u8 {
    if (!build_options.enable_channel_slack) return path;
    return channels.slack.SlackChannel.normalizeWebhookPath(path);
}

fn hasSlackHttpEndpoint(cfg_opt: ?*const Config, base_path: []const u8) bool {
    if (!build_options.enable_channel_slack) return false;
    const cfg = cfg_opt orelse return std.mem.eql(u8, base_path, channels.slack.SlackChannel.DEFAULT_WEBHOOK_PATH);
    for (cfg.channels.slack) |slack_cfg| {
        if (slack_cfg.mode != .http) continue;
        if (std.mem.eql(u8, normalizeSlackWebhookPath(slack_cfg.webhook_path), base_path)) return true;
    }
    return false;
}

fn verifySlackSignature(
    allocator: std.mem.Allocator,
    body: []const u8,
    timestamp_header: []const u8,
    signature_header: []const u8,
    signing_secret: []const u8,
) bool {
    if (signing_secret.len == 0) return false;
    const ts_trimmed = std.mem.trim(u8, timestamp_header, " \t\r\n");
    const sig_trimmed = std.mem.trim(u8, signature_header, " \t\r\n");
    if (!std.mem.startsWith(u8, sig_trimmed, "v0=")) return false;

    const provided_hex = sig_trimmed["v0=".len..];
    if (provided_hex.len != 64) return false;

    const ts = std.fmt.parseInt(i64, ts_trimmed, 10) catch return false;
    const now = std_compat.time.timestamp();
    const delta = if (now >= ts) now - ts else ts - now;
    if (delta > 300) return false; // 5-minute replay window

    var base_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer base_buf.deinit(allocator);
    var base_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &base_buf);
    const bw = &base_writer.writer;
    bw.print("v0:{s}:", .{ts_trimmed}) catch return false;
    bw.writeAll(body) catch return false;
    base_buf = base_writer.toArrayList();

    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [32]u8 = undefined;
    HmacSha256.create(&mac, base_buf.items, signing_secret);

    var provided: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const hi = hexVal(provided_hex[i * 2]) orelse return false;
        const lo = hexVal(provided_hex[i * 2 + 1]) orelse return false;
        provided[i] = (hi << 4) | lo;
    }
    return constantTimeEql(&mac, &provided);
}

const SIGNED_WEBHOOK_MAX_SKEW_SECS: i64 = 300;

fn isFreshSignedWebhookTimestampAt(timestamp_value: []const u8, now: i64, max_skew_secs: i64) bool {
    const ts_trimmed = std.mem.trim(u8, timestamp_value, " \t\r\n");
    const ts = std.fmt.parseInt(i64, ts_trimmed, 10) catch return false;
    const delta = if (now >= ts) now - ts else ts - now;
    return delta <= max_skew_secs;
}

fn isFreshSignedWebhookTimestamp(timestamp_value: []const u8) bool {
    return isFreshSignedWebhookTimestampAt(timestamp_value, std_compat.time.timestamp(), SIGNED_WEBHOOK_MAX_SKEW_SECS);
}

fn findSlackConfigForRequest(
    allocator: std.mem.Allocator,
    cfg_opt: ?*const Config,
    target: []const u8,
    body: []const u8,
    timestamp_header: ?[]const u8,
    signature_header: ?[]const u8,
) ?*const config_types.SlackConfig {
    if (!build_options.enable_channel_slack) return null;
    const cfg = cfg_opt orelse return null;
    if (cfg.channels.slack.len == 0) return null;

    const base_path = webhookBasePath(target);
    for (cfg.channels.slack) |*slack_cfg| {
        if (slack_cfg.mode != .http) continue;
        if (!std.mem.eql(u8, normalizeSlackWebhookPath(slack_cfg.webhook_path), base_path)) continue;

        const secret = slack_cfg.signing_secret orelse continue;
        if (timestamp_header == null or signature_header == null) continue;
        if (verifySlackSignature(
            allocator,
            body,
            timestamp_header.?,
            signature_header.?,
            secret,
        )) return slack_cfg;
    }
    return null;
}

fn slackSessionKey(
    buf: []u8,
    account_id: []const u8,
    sender_id: []const u8,
    channel_id: []const u8,
    is_dm: bool,
) []const u8 {
    if (is_dm) {
        return std.fmt.bufPrint(buf, "slack:{s}:direct:{s}", .{ account_id, sender_id }) catch "slack:unknown";
    }
    return std.fmt.bufPrint(buf, "slack:{s}:channel:{s}", .{ account_id, channel_id }) catch "slack:unknown";
}

fn slackSessionKeyRouted(
    allocator: std.mem.Allocator,
    fallback_buf: []u8,
    account_id: []const u8,
    sender_id: []const u8,
    channel_id: []const u8,
    is_dm: bool,
    cfg_opt: ?*const Config,
) []const u8 {
    const fallback = slackSessionKey(fallback_buf, account_id, sender_id, channel_id, is_dm);
    return resolveRouteSessionKey(
        allocator,
        cfg_opt,
        "slack",
        account_id,
        .{
            .kind = if (is_dm) .direct else .channel,
            .id = if (is_dm) sender_id else channel_id,
        },
        fallback,
    );
}

fn slackEnvelopeBotUserId(payload_root: std.json.ObjectMap) ?[]const u8 {
    const authz = payload_root.get("authorizations") orelse return null;
    if (authz != .array or authz.array.items.len == 0) return null;
    const first = authz.array.items[0];
    if (first != .object) return null;
    const uid_val = first.object.get("user_id") orelse return null;
    if (uid_val != .string or uid_val.string.len == 0) return null;
    return uid_val.string;
}

fn decodeFormComponent(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        const ch = encoded[i];
        if (ch == '+') {
            try out.append(allocator, ' ');
            continue;
        }
        if (ch == '%' and i + 2 < encoded.len) {
            const hi = hexVal(encoded[i + 1]) orelse {
                try out.append(allocator, ch);
                continue;
            };
            const lo = hexVal(encoded[i + 2]) orelse {
                try out.append(allocator, ch);
                continue;
            };
            try out.append(allocator, (hi << 4) | lo);
            i += 2;
            continue;
        }
        try out.append(allocator, ch);
    }

    return out.toOwnedSlice(allocator);
}

fn slackDecodeInteractivePayload(allocator: std.mem.Allocator, body: []const u8) ?[]u8 {
    var fields = std.mem.splitScalar(u8, body, '&');
    while (fields.next()) |field| {
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const key = field[0..eq];
        if (!std.mem.eql(u8, key, "payload")) continue;
        return decodeFormComponent(allocator, field[eq + 1 ..]) catch null;
    }
    return null;
}

fn slackParseCallbackValue(value: []const u8) ?struct { token: []const u8, option_index: usize } {
    if (!std.mem.startsWith(u8, value, "ncslack:")) return null;
    const rest = value["ncslack:".len..];
    const sep = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return null;
    const token = rest[0..sep];
    if (token.len == 0) return null;
    const option_index = std.fmt.parseUnsigned(usize, rest[sep + 1 ..], 10) catch return null;
    return .{ .token = token, .option_index = option_index };
}

const SlackInteractiveTarget = struct {
    channel_id: []const u8,
    thread_id: ?[]const u8 = null,
    is_dm: bool,
};

fn slackInteractiveTarget(target: []const u8, fallback_channel_id: []const u8) SlackInteractiveTarget {
    var channel_id = if (target.len > 0) target else fallback_channel_id;
    var thread_id: ?[]const u8 = null;

    if (std.mem.indexOfScalar(u8, channel_id, ':')) |idx| {
        if (idx > 0) {
            const parsed_thread = channel_id[idx + 1 ..];
            channel_id = channel_id[0..idx];
            if (parsed_thread.len > 0) thread_id = parsed_thread;
        }
    }

    return .{
        .channel_id = channel_id,
        .thread_id = thread_id,
        .is_dm = channel_id.len > 0 and channel_id[0] == 'D',
    };
}

fn whatsappSessionKey(buf: []u8, body: []const u8) []const u8 {
    const sender = jsonStringField(body, "from") orelse "unknown";
    const group_id = jsonStringField(body, "group_jid") orelse jsonStringField(body, "group_id");
    if (group_id) |gid| {
        return std.fmt.bufPrint(buf, "whatsapp:group:{s}:{s}", .{ gid, sender }) catch "whatsapp:unknown";
    }
    return std.fmt.bufPrint(buf, "whatsapp:{s}", .{sender}) catch "whatsapp:unknown";
}

fn whatsappReplyTarget(body: []const u8) []const u8 {
    // Cloud API delivery is addressed by recipient id ("from" for inbound DMs).
    // Group IDs are used for routing/session isolation, not outbound target.
    return jsonStringField(body, "from") orelse "unknown";
}

fn whatsappIsGroupMessage(body: []const u8) bool {
    return jsonStringField(body, "group_jid") != null or
        jsonStringField(body, "group_id") != null;
}

fn whatsappGroupId(body: []const u8) ?[]const u8 {
    return jsonStringField(body, "group_jid") orelse
        jsonStringField(body, "group_id");
}

fn whatsappSenderAllowed(
    sender: ?[]const u8,
    is_group: bool,
    group_id: ?[]const u8,
    allow_from: []const []const u8,
    group_allow_from: []const []const u8,
    groups: []const []const u8,
    group_policy: []const u8,
) bool {
    const sender_id = sender orelse return false;

    if (!is_group) {
        if (allow_from.len == 0) return false;
        return whatsappSenderInAllowlist(allow_from, sender_id);
    }

    if (std.mem.eql(u8, group_policy, "disabled")) return false;

    const group_allowlist_enabled = std.mem.eql(u8, group_policy, "allowlist") or groups.len > 0;
    if (group_allowlist_enabled) {
        const gid = group_id orelse return false;
        if (!channels.isAllowed(groups, gid)) return false;
    }

    if (std.mem.eql(u8, group_policy, "open")) return true;

    const effective_allow = if (group_allow_from.len > 0) group_allow_from else allow_from;
    if (effective_allow.len == 0) return false;
    return whatsappSenderInAllowlist(effective_allow, sender_id);
}

fn whatsappSenderInAllowlist(allowlist: []const []const u8, sender_raw: []const u8) bool {
    if (channels.isAllowed(allowlist, sender_raw)) return true;

    var normalized_buf: [64]u8 = undefined;
    const sender_normalized = channels.whatsapp.WhatsAppChannel.normalizePhone(&normalized_buf, sender_raw);
    if (!std.mem.eql(u8, sender_normalized, sender_raw) and channels.isAllowed(allowlist, sender_normalized)) {
        return true;
    }
    if (sender_normalized.len > 0 and sender_normalized[0] == '+' and
        channels.isAllowed(allowlist, sender_normalized[1..]))
    {
        return true;
    }
    return false;
}

fn whatsappSessionKeyRouted(
    allocator: std.mem.Allocator,
    fallback_buf: []u8,
    body: []const u8,
    cfg_opt: ?*const Config,
    account_id: []const u8,
) []const u8 {
    const sender = jsonStringField(body, "from") orelse "unknown";
    const group_id = jsonStringField(body, "group_jid") orelse jsonStringField(body, "group_id");
    const peer_id = if (group_id) |gid|
        if (gid.len > 0) gid else sender
    else
        sender;
    const peer_kind: agent_routing.ChatType = if (group_id != null) .group else .direct;

    if (cfg_opt) |cfg| {
        const route = agent_routing.resolveRouteWithSession(allocator, .{
            .channel = "whatsapp",
            .account_id = account_id,
            .peer = .{ .kind = peer_kind, .id = peer_id },
        }, cfg.agent_bindings, cfg.agents, cfg.session) catch return whatsappSessionKey(fallback_buf, body);
        allocator.free(route.main_session_key);
        return route.session_key;
    }

    return whatsappSessionKey(fallback_buf, body);
}

fn resolveRouteSessionKey(
    allocator: std.mem.Allocator,
    cfg_opt: ?*const Config,
    channel: []const u8,
    account_id: []const u8,
    peer: agent_routing.PeerRef,
    fallback: []const u8,
) []const u8 {
    if (cfg_opt) |cfg| {
        const route = agent_routing.resolveRouteWithSession(allocator, .{
            .channel = channel,
            .account_id = account_id,
            .peer = peer,
        }, cfg.agent_bindings, cfg.agents, cfg.session) catch return fallback;
        allocator.free(route.main_session_key);
        return route.session_key;
    }
    return fallback;
}

fn qqPeerRefFromInbound(inbound: *const bus_mod.InboundMessage) ?agent_routing.PeerRef {
    const meta = inbound.metadata_json;
    const is_group = if (meta) |json| std.mem.indexOf(u8, json, "\"is_group\":true") != null else false;
    const is_dm = if (meta) |json| std.mem.indexOf(u8, json, "\"is_dm\":true") != null else false;
    const channel_id = if (meta) |json| jsonStringField(json, "channel_id") else null;
    const group_id = if (meta) |json| jsonStringField(json, "group_openid") orelse jsonStringField(json, "group_id") else null;

    if (is_group) {
        const peer_id = group_id orelse channel_id orelse return null;
        return .{ .kind = .group, .id = peer_id };
    }
    if (is_dm or std.mem.startsWith(u8, inbound.chat_id, "dm:")) {
        return .{ .kind = .direct, .id = inbound.sender_id };
    }

    const raw_channel = channel_id orelse inbound.chat_id;
    const normalized_channel = if (std.mem.startsWith(u8, raw_channel, "channel:"))
        raw_channel["channel:".len..]
    else
        raw_channel;
    if (normalized_channel.len == 0) return null;
    return .{ .kind = .channel, .id = normalized_channel };
}

fn qqSessionKeyRouted(
    allocator: std.mem.Allocator,
    inbound: *const bus_mod.InboundMessage,
    cfg_opt: ?*const Config,
) ?[]const u8 {
    const cfg = cfg_opt orelse return null;
    const account_id = if (inbound.metadata_json) |json|
        (jsonStringField(json, "account_id") orelse "default")
    else
        "default";
    const peer = qqPeerRefFromInbound(inbound) orelse return null;

    const route = agent_routing.resolveRouteWithSession(allocator, .{
        .channel = "qq",
        .account_id = account_id,
        .peer = peer,
    }, cfg.agent_bindings, cfg.agents, cfg.session) catch return null;
    allocator.free(route.main_session_key);
    return route.session_key;
}

fn teamsPeerRef(
    body: []const u8,
    from_id: []const u8,
    conversation_id: []const u8,
) struct {
    peer: agent_routing.PeerRef,
    is_dm: bool,
} {
    const conversation_type = teamsNestedField(body, "conversation", "conversationType") orelse "";
    const is_dm = conversation_type.len == 0 or std.mem.eql(u8, conversation_type, "personal");
    return .{
        .peer = .{
            .kind = if (is_dm) .direct else .channel,
            .id = if (is_dm) from_id else conversation_id,
        },
        .is_dm = is_dm,
    };
}

fn teamsSessionKeyRouted(
    allocator: std.mem.Allocator,
    fallback_buf: []u8,
    config: *const Config,
    body: []const u8,
    account_id: []const u8,
    tenant_id: []const u8,
    conversation_id: []const u8,
    from_id: []const u8,
) []const u8 {
    const fallback = std.fmt.bufPrint(fallback_buf, "teams:{s}:{s}", .{ tenant_id, conversation_id }) catch "teams:default";
    const peer_info = teamsPeerRef(body, from_id, conversation_id);
    return resolveRouteSessionKey(
        allocator,
        config,
        "teams",
        account_id,
        peer_info.peer,
        fallback,
    );
}

fn webhookRouting(
    allocator: std.mem.Allocator,
    body: []const u8,
    bearer: ?[]const u8,
    cfg_opt: ?*const Config,
) WebhookRouting {
    const owned_fallback_key = std.fmt.allocPrint(allocator, "webhook:{s}", .{bearer orelse "anon"}) catch null;
    const fallback_key = owned_fallback_key orelse "webhook:anon";

    const channel = jsonStringField(body, "channel");
    const peer_kind = if (jsonStringField(body, "peer_kind")) |raw| channel_adapters.parsePeerKind(raw) else null;
    const peer_id = jsonStringField(body, "peer_id");
    const sender_id = jsonStringField(body, "sender_id") orelse bearer;
    const sender_username = jsonStringField(body, "sender_username");
    const sender_display_name = jsonStringField(body, "sender_display_name");
    const account_id = jsonStringField(body, "account_id");
    const bus_sender_id = sender_id orelse "anon";
    const bus_chat_id = peer_id orelse fallback_key;
    const metadata_json = buildWebhookRoutingMetadataJson(
        allocator,
        account_id,
        peer_kind,
        peer_id,
        sender_username,
        sender_display_name,
    );

    const conversation_context = if (channel != null or peer_id != null or sender_id != null or account_id != null or sender_username != null or sender_display_name != null)
        buildConversationContext(.{
            .channel = channel,
            .account_id = account_id,
            .sender_id = sender_id,
            .sender_username = sender_username,
            .sender_display_name = sender_display_name,
            .delivery_chat_id = bus_chat_id,
            .peer_id = peer_id,
            .is_group = if (peer_kind) |kind| kind != .direct else null,
            .group_id = if (peer_kind) |kind| if (kind == .direct) null else peer_id else null,
        })
    else
        null;

    if (cfg_opt) |cfg| {
        if (channel) |channel_name| {
            if (peer_kind) |kind| {
                if (peer_id) |resolved_peer_id| {
                    const route = agent_routing.resolveRouteWithSession(allocator, .{
                        .channel = channel_name,
                        .account_id = account_id orelse "default",
                        .peer = .{ .kind = kind, .id = resolved_peer_id },
                    }, cfg.agent_bindings, cfg.agents, cfg.session) catch return .{
                        .sender_id = bus_sender_id,
                        .chat_id = bus_chat_id,
                        .session_key = fallback_key,
                        .owned_session_key = owned_fallback_key,
                        .metadata_json = metadata_json,
                        .conversation_context = conversation_context,
                    };
                    if (owned_fallback_key) |owned| allocator.free(owned);
                    allocator.free(route.main_session_key);
                    return .{
                        .sender_id = bus_sender_id,
                        .chat_id = bus_chat_id,
                        .session_key = route.session_key,
                        .owned_session_key = route.session_key,
                        .metadata_json = metadata_json,
                        .conversation_context = conversation_context,
                    };
                }
            }
        }
    }

    return .{
        .sender_id = bus_sender_id,
        .chat_id = bus_chat_id,
        .session_key = fallback_key,
        .owned_session_key = owned_fallback_key,
        .metadata_json = metadata_json,
        .conversation_context = conversation_context,
    };
}

fn telegramChatIsGroup(allocator: std.mem.Allocator, body: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;

    const msg_obj = parsed.value.object.get("message") orelse
        parsed.value.object.get("edited_message") orelse return false;
    if (msg_obj != .object) return false;

    const chat_obj = msg_obj.object.get("chat") orelse return false;
    if (chat_obj != .object) return false;

    const type_val = chat_obj.object.get("type") orelse return false;
    if (type_val != .string) return false;

    return std.mem.eql(u8, type_val.string, "group") or
        std.mem.eql(u8, type_val.string, "supergroup") or
        std.mem.eql(u8, type_val.string, "channel");
}

fn telegramSenderAllowed(allocator: std.mem.Allocator, allow_from: []const []const u8, body: []const u8) bool {
    if (allow_from.len == 0) return true;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;

    const msg_obj = parsed.value.object.get("message") orelse
        parsed.value.object.get("edited_message") orelse return false;
    if (msg_obj != .object) return false;

    const from_obj = msg_obj.object.get("from") orelse return false;
    if (from_obj != .object) return false;

    if (from_obj.object.get("username")) |uname| {
        if (uname == .string and channels.isAllowed(allow_from, uname.string)) return true;
    }

    if (from_obj.object.get("id")) |id_val| {
        if (id_val == .integer) {
            var id_buf: [32]u8 = undefined;
            const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{id_val.integer}) catch return false;
            if (channels.isAllowed(allow_from, id_str)) return true;
        }
    }

    return false;
}

fn telegramSessionKeyRouted(
    allocator: std.mem.Allocator,
    fallback_buf: []u8,
    body: []const u8,
    cfg_opt: ?*const Config,
    account_id: []const u8,
) []const u8 {
    const target = telegramWebhookTarget(allocator, body) orelse return "telegram:0";
    const fallback = telegramFallbackSessionKey(fallback_buf, target.chat_id, target.message_thread_id);
    var peer_buf: [64]u8 = undefined;
    const peer_id = std.fmt.bufPrint(&peer_buf, "{d}", .{target.chat_id}) catch return fallback;
    const peer_kind: agent_routing.ChatType = if (target.is_group) .group else .direct;

    if (cfg_opt) |cfg| {
        if (target.is_group and target.message_thread_id != null) {
            const thread_id = target.message_thread_id.?;
            const topic_peer_id = std.fmt.allocPrint(allocator, "{s}:thread:{d}", .{ peer_id, thread_id }) catch return fallback;
            defer allocator.free(topic_peer_id);

            const route = agent_routing.resolveRouteWithSession(allocator, .{
                .channel = "telegram",
                .account_id = account_id,
                .peer = .{ .kind = peer_kind, .id = topic_peer_id },
                .parent_peer = .{ .kind = peer_kind, .id = peer_id },
            }, cfg.agent_bindings, cfg.agents, cfg.session) catch return fallback;
            allocator.free(route.main_session_key);
            return route.session_key;
        }
    }

    return resolveRouteSessionKey(
        allocator,
        cfg_opt,
        "telegram",
        account_id,
        .{ .kind = peer_kind, .id = peer_id },
        fallback,
    );
}

const TelegramWebhookTarget = struct {
    chat_id: i64,
    is_group: bool,
    message_thread_id: ?i64 = null,
};

fn telegramMessageValue(root: std.json.Value) ?std.json.Value {
    if (root != .object) return null;
    return root.object.get("message") orelse root.object.get("edited_message");
}

fn telegramMessageThreadId(message: std.json.Value) ?i64 {
    if (message != .object) return null;

    if (message.object.get("message_thread_id")) |thread_id_val| {
        if (thread_id_val == .integer and thread_id_val.integer > 0) {
            return thread_id_val.integer;
        }
    }

    const is_topic_message = blk: {
        const field = message.object.get("is_topic_message") orelse break :blk false;
        break :blk field == .bool and field.bool;
    };
    if (!is_topic_message) return null;

    const reply_to_message = message.object.get("reply_to_message") orelse return null;
    if (reply_to_message != .object) return null;

    const reply_message_id = reply_to_message.object.get("message_id") orelse return null;
    if (reply_message_id != .integer or reply_message_id.integer <= 0) return null;
    return reply_message_id.integer;
}

fn telegramWebhookTarget(allocator: std.mem.Allocator, body: []const u8) ?TelegramWebhookTarget {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        if (jsonIntField(body, "chat_id")) |chat_id| {
            return .{
                .chat_id = chat_id,
                .is_group = false,
            };
        }
        return null;
    };
    defer parsed.deinit();

    const message = telegramMessageValue(parsed.value) orelse {
        if (jsonIntField(body, "chat_id")) |chat_id| {
            return .{
                .chat_id = chat_id,
                .is_group = false,
            };
        }
        return null;
    };
    if (message != .object) return null;

    const chat = message.object.get("chat") orelse return null;
    if (chat != .object) return null;

    const id_val = chat.object.get("id") orelse return null;
    if (id_val != .integer) return null;

    const chat_type = blk: {
        const field = chat.object.get("type") orelse break :blk "";
        break :blk if (field == .string) field.string else "";
    };

    return .{
        .chat_id = id_val.integer,
        .is_group = std.mem.eql(u8, chat_type, "group") or
            std.mem.eql(u8, chat_type, "supergroup") or
            std.mem.eql(u8, chat_type, "channel"),
        .message_thread_id = telegramMessageThreadId(message),
    };
}

fn telegramFallbackSessionKey(fallback_buf: []u8, chat_id: i64, message_thread_id: ?i64) []const u8 {
    if (message_thread_id) |thread_id| {
        return std.fmt.bufPrint(fallback_buf, "telegram:{d}:thread:{d}", .{ chat_id, thread_id }) catch "telegram:0";
    }
    return std.fmt.bufPrint(fallback_buf, "telegram:{d}", .{chat_id}) catch "telegram:0";
}

fn telegramChatTargetAlloc(allocator: std.mem.Allocator, chat_id: i64, message_thread_id: ?i64) ![]u8 {
    if (message_thread_id) |thread_id| {
        return std.fmt.allocPrint(allocator, "{d}#topic:{d}", .{ chat_id, thread_id });
    }
    return std.fmt.allocPrint(allocator, "{d}", .{chat_id});
}

fn telegramChatId(allocator: std.mem.Allocator, body: []const u8) ?i64 {
    return if (telegramWebhookTarget(allocator, body)) |target| target.chat_id else jsonIntField(body, "chat_id");
}

fn telegramSenderIdentity(
    allocator: std.mem.Allocator,
    body: []const u8,
    id_buf: []u8,
) []const u8 {
    if (jsonStringField(body, "username")) |uname| return uname;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return "unknown";
    defer parsed.deinit();
    if (parsed.value != .object) return "unknown";

    const msg_obj = parsed.value.object.get("message") orelse
        parsed.value.object.get("edited_message") orelse return "unknown";
    if (msg_obj != .object) return "unknown";

    const from_obj = msg_obj.object.get("from") orelse return "unknown";
    if (from_obj != .object) return "unknown";
    if (from_obj.object.get("id")) |id_val| {
        if (id_val == .integer) {
            return std.fmt.bufPrint(id_buf, "{d}", .{id_val.integer}) catch "unknown";
        }
    }
    return "unknown";
}

fn lineSessionKey(buf: []u8, evt: channels.line.LineEvent) []const u8 {
    return std.fmt.bufPrint(buf, "line:{s}", .{evt.user_id orelse "unknown"}) catch "line:unknown";
}

fn lineReplyTarget(evt: channels.line.LineEvent) []const u8 {
    const source_type = evt.source_type orelse "";
    if (std.mem.eql(u8, source_type, "group")) {
        return evt.group_id orelse evt.user_id orelse "unknown";
    }
    if (std.mem.eql(u8, source_type, "room")) {
        return evt.room_id orelse evt.user_id orelse "unknown";
    }
    return evt.user_id orelse "unknown";
}

fn lineSessionKeyRouted(
    allocator: std.mem.Allocator,
    fallback_buf: []u8,
    evt: channels.line.LineEvent,
    cfg_opt: ?*const Config,
    account_id: []const u8,
) []const u8 {
    const fallback = lineSessionKey(fallback_buf, evt);
    const src_type = evt.source_type orelse "";
    const peer_kind: agent_routing.ChatType = if (std.mem.eql(u8, src_type, "group") or std.mem.eql(u8, src_type, "room")) .group else .direct;
    var peer_buf: [160]u8 = undefined;
    const peer_id = if (std.mem.eql(u8, src_type, "group"))
        std.fmt.bufPrint(&peer_buf, "group:{s}", .{evt.group_id orelse evt.user_id orelse "unknown"}) catch return fallback
    else if (std.mem.eql(u8, src_type, "room"))
        std.fmt.bufPrint(&peer_buf, "room:{s}", .{evt.room_id orelse evt.user_id orelse "unknown"}) catch return fallback
    else
        evt.user_id orelse "unknown";
    return resolveRouteSessionKey(
        allocator,
        cfg_opt,
        "line",
        account_id,
        .{ .kind = peer_kind, .id = peer_id },
        fallback,
    );
}

fn larkSessionKey(buf: []u8, msg: channels.lark.ParsedLarkMessage) []const u8 {
    return std.fmt.bufPrint(buf, "lark:{s}", .{msg.sender}) catch "lark:unknown";
}

fn larkSessionKeyRouted(
    allocator: std.mem.Allocator,
    fallback_buf: []u8,
    msg: channels.lark.ParsedLarkMessage,
    cfg_opt: ?*const Config,
    account_id: []const u8,
) []const u8 {
    const fallback = larkSessionKey(fallback_buf, msg);
    const peer_kind: agent_routing.ChatType = if (msg.is_group) .group else .direct;
    return resolveRouteSessionKey(
        allocator,
        cfg_opt,
        "lark",
        account_id,
        .{ .kind = peer_kind, .id = msg.sender },
        fallback,
    );
}

fn wecomSessionKey(buf: []u8, sender: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "wecom:{s}", .{sender}) catch "wecom:unknown";
}

fn wechatSessionKey(buf: []u8, sender: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "wechat:{s}", .{sender}) catch "wechat:unknown";
}

fn wechatSessionKeyRouted(
    allocator: std.mem.Allocator,
    fallback_buf: []u8,
    sender: []const u8,
    cfg_opt: ?*const Config,
    account_id: []const u8,
) []const u8 {
    const fallback = wechatSessionKey(fallback_buf, sender);
    return resolveRouteSessionKey(
        allocator,
        cfg_opt,
        "wechat",
        account_id,
        .{ .kind = .direct, .id = sender },
        fallback,
    );
}

fn wecomSessionKeyRouted(
    allocator: std.mem.Allocator,
    fallback_buf: []u8,
    sender: []const u8,
    cfg_opt: ?*const Config,
    account_id: []const u8,
) []const u8 {
    const fallback = wecomSessionKey(fallback_buf, sender);
    return resolveRouteSessionKey(
        allocator,
        cfg_opt,
        "wecom",
        account_id,
        .{ .kind = .direct, .id = sender },
        fallback,
    );
}

fn maxSessionKey(buf: []u8, account_id: []const u8, sender: []const u8, reply_target: []const u8, is_group: bool) []const u8 {
    if (is_group) {
        return std.fmt.bufPrint(buf, "max:{s}:chat:{s}", .{ account_id, reply_target }) catch "max:default";
    }
    return std.fmt.bufPrint(buf, "max:{s}:{s}", .{ account_id, sender }) catch "max:default";
}

fn maxSessionKeyRouted(
    allocator: std.mem.Allocator,
    fallback_buf: []u8,
    sender: []const u8,
    reply_target: []const u8,
    is_group: bool,
    cfg_opt: ?*const Config,
    account_id: []const u8,
) []const u8 {
    const fallback = maxSessionKey(fallback_buf, account_id, sender, reply_target, is_group);
    const peer_id = if (is_group) reply_target else sender;
    return resolveRouteSessionKey(
        allocator,
        cfg_opt,
        "max",
        account_id,
        .{ .kind = if (is_group) .group else .direct, .id = peer_id },
        fallback,
    );
}

// ── Message Processing ──────────────────────────────────────────

/// Extract the HTTP request body from raw bytes.
/// Finds the \r\n\r\n boundary and returns everything after it.
pub fn extractBody(raw: []const u8) ?[]const u8 {
    const separator = "\r\n\r\n";
    const pos = std.mem.indexOf(u8, raw, separator) orelse return null;
    const body = raw[pos + separator.len ..];
    if (body.len == 0) return null;
    return body;
}

fn headerEndOffset(raw: []const u8) ?usize {
    const separator = "\r\n\r\n";
    const pos = std.mem.indexOf(u8, raw, separator) orelse return null;
    return pos + separator.len;
}

fn maxHttpRequestSize(max_body: usize) usize {
    return std.math.add(usize, MAX_HEADER_SIZE, max_body) catch std.math.maxInt(usize);
}

fn effectiveRequestReadTimeoutSecs(config_opt: ?*const Config) u64 {
    if (config_opt) |cfg| {
        if (cfg.gateway.request_timeout_secs > 0) return cfg.gateway.request_timeout_secs;
    }
    return REQUEST_TIMEOUT_SECS;
}

fn ensureSafeGatewayBind(host: []const u8, config_opt: ?*const Config, tunnel_url_opt: ?[]const u8) !void {
    if (!isPublicBindHost(host)) return;
    if (config_opt) |cfg| {
        if (cfg.gateway.allow_public_bind) return;
    }
    if (tunnel_url_opt) |url| {
        if (url.len > 0) return;
    }
    return error.PublicBindRequiresTunnel;
}

fn clientIdentifierFromAddress(address: std_compat.net.Address, buf: *[64]u8) []const u8 {
    return switch (address.any.family) {
        std.posix.AF.INET => blk: {
            const octets: *const [4]u8 = @ptrCast(&address.in.sa.addr);
            break :blk std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ octets[0], octets[1], octets[2], octets[3] }) catch "ipv4";
        },
        std.posix.AF.INET6 => blk: {
            const bytes = address.in6.sa.addr;
            break :blk std.fmt.bufPrint(
                buf,
                "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}",
                .{
                    bytes[0],  bytes[1],  bytes[2],  bytes[3],
                    bytes[4],  bytes[5],  bytes[6],  bytes[7],
                    bytes[8],  bytes[9],  bytes[10], bytes[11],
                    bytes[12], bytes[13], bytes[14], bytes[15],
                },
            ) catch "ipv6";
        },
        else => "unknown",
    };
}

fn allowScopedWebhook(state: *GatewayState, scope: []const u8, client_identifier: []const u8) bool {
    var key_buf: [96]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ scope, client_identifier }) catch return true;
    return state.rate_limiter.allowWebhook(state.allocator, key);
}

fn allowScopedPair(state: *GatewayState, scope: []const u8, client_identifier: []const u8) bool {
    var key_buf: [96]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ scope, client_identifier }) catch return true;
    return state.rate_limiter.allowPair(state.allocator, key);
}

fn expectedHttpRequestSize(raw: []const u8, max_body: usize) !?usize {
    const header_end = headerEndOffset(raw) orelse {
        if (raw.len > MAX_HEADER_SIZE) return error.RequestTooLarge;
        return null;
    };
    if (header_end > MAX_HEADER_SIZE) return error.RequestTooLarge;

    const header_slice = raw[0..header_end];
    const content_length_raw = extractHeader(header_slice, "Content-Length") orelse return header_end;
    const trimmed = std.mem.trim(u8, content_length_raw, " \t");
    if (trimmed.len == 0) return error.InvalidContentLength;

    const content_length = std.fmt.parseInt(usize, trimmed, 10) catch return error.InvalidContentLength;
    if (content_length > max_body) return error.RequestTooLarge;

    const max_request_size = maxHttpRequestSize(max_body);
    const total = std.math.add(usize, header_end, content_length) catch return error.RequestTooLarge;
    if (total > max_request_size) return error.RequestTooLarge;
    return total;
}

fn configureRequestReadTimeout(stream: *std_compat.net.Stream, timeout_secs: u64) void {
    if (comptime builtin.os.tag == .windows) return;
    if (!@hasDecl(std.posix.SO, "RCVTIMEO")) return;

    const zero_timeout = std.posix.timeval{ .sec = 0, .usec = 0 };
    const TimevalSecs = @TypeOf(zero_timeout.sec);
    const timeout = std.posix.timeval{
        .sec = @intCast(@min(timeout_secs, @as(u64, std.math.maxInt(TimevalSecs)))),
        .usec = 0,
    };
    std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        &std.mem.toBytes(timeout),
    ) catch {};
}

fn readHttpRequestFromReader(allocator: std.mem.Allocator, reader: anytype, max_body: usize) ![]u8 {
    var request_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer request_buf.deinit(allocator);
    var expected_total: ?usize = null;
    const max_request_size = maxHttpRequestSize(max_body);
    var chunk: [2048]u8 = undefined;

    while (true) {
        const n = reader.read(&chunk) catch |err| {
            if (err == error.Timeout or err == error.WouldBlock) return error.RequestTimeout;
            return err;
        };
        if (n == 0) return error.IncompleteRequest;

        try request_buf.appendSlice(allocator, chunk[0..n]);
        if (request_buf.items.len > max_request_size) return error.RequestTooLarge;

        if (expected_total == null) {
            expected_total = try expectedHttpRequestSize(request_buf.items, max_body);
        }

        if (expected_total) |total| {
            if (request_buf.items.len >= total) {
                request_buf.items.len = total;
                return request_buf.toOwnedSlice(allocator);
            }
        }
    }
}

fn readHttpRequest(allocator: std.mem.Allocator, stream: *std_compat.net.Stream, max_body: usize) ![]u8 {
    return readHttpRequestFromReader(allocator, stream, max_body);
}

fn maybeProbeA2aVision(session_mgr: anytype, allocator: std.mem.Allocator, cfg: *const Config) void {
    if (!cfg.a2a.enabled) return;
    session_mgr.probeVision(allocator);
}

const LocalAgentRuntime = struct {
    provider_bundle: providers.runtime_bundle.RuntimeProviderBundle,
    session_mgr: session_mod.SessionManager,
    tools_slice: []const tools_mod.Tool,
    mem_rt: ?*memory_mod.MemoryRuntime,
    bootstrap_provider: ?bootstrap_mod.BootstrapProvider,
    subagent_manager: ?*subagent_mod.SubagentManager,
    sec_tracker: *security.RateTracker,
    sec_policy: *security.SecurityPolicy,

    fn deinit(self: *LocalAgentRuntime, allocator: std.mem.Allocator) void {
        self.session_mgr.deinit();
        if (self.tools_slice.len > 0) tools_mod.deinitTools(allocator, self.tools_slice);
        if (self.bootstrap_provider) |bp| bp.deinit();
        if (self.subagent_manager) |mgr| {
            mgr.deinit();
            allocator.destroy(mgr);
        }
        if (self.mem_rt) |rt| {
            rt.deinit();
            allocator.destroy(rt);
        }
        self.provider_bundle.deinit();
        allocator.destroy(self.sec_policy);
        self.sec_tracker.deinit();
        allocator.destroy(self.sec_tracker);
    }
};

fn initLocalAgentRuntime(
    allocator: std.mem.Allocator,
    cfg: *const Config,
    runtime_observer: *observability.RuntimeObserver,
    event_bus: ?*bus_mod.Bus,
) !LocalAgentRuntime {
    var provider_bundle = try providers.runtime_bundle.RuntimeProviderBundle.init(allocator, cfg);
    errdefer provider_bundle.deinit();

    const provider_i: providers.Provider = provider_bundle.provider();
    const resolved_api_key = provider_bundle.primaryApiKey();

    const mem_rt: ?*memory_mod.MemoryRuntime = blk: {
        var rt_value = memory_mod.initRuntime(allocator, &cfg.memory, cfg.workspace_dir) orelse break :blk null;
        errdefer rt_value.deinit();

        const rt = try allocator.create(memory_mod.MemoryRuntime);
        rt.* = rt_value;
        break :blk rt;
    };
    errdefer if (mem_rt) |rt| {
        rt.deinit();
        allocator.destroy(rt);
    };
    const mem_opt: ?memory_mod.Memory = if (mem_rt) |rt| rt.memory else null;

    const bootstrap_provider = bootstrap_mod.createProvider(
        allocator,
        cfg.memory.backend,
        mem_opt,
        cfg.workspace_dir,
    ) catch null;
    errdefer if (bootstrap_provider) |bp| bp.deinit();

    const subagent_manager = allocator.create(subagent_mod.SubagentManager) catch null;
    errdefer if (subagent_manager) |mgr| allocator.destroy(mgr);
    if (subagent_manager) |mgr| {
        mgr.* = subagent_mod.SubagentManager.init(allocator, cfg, event_bus, .{});
        mgr.observer = runtime_observer.backendObserver();
        mgr.task_runner = subagent_runner.runTaskWithTools;
        errdefer mgr.deinit();
    }

    const sec_tracker = try allocator.create(security.RateTracker);
    sec_tracker.* = security.RateTracker.init(allocator, cfg.autonomy.max_actions_per_hour);
    errdefer {
        sec_tracker.deinit();
        allocator.destroy(sec_tracker);
    }

    const sec_policy = try allocator.create(security.SecurityPolicy);
    errdefer allocator.destroy(sec_policy);
    sec_policy.* = .{
        .autonomy = cfg.autonomy.level,
        .workspace_dir = cfg.workspace_dir,
        .workspace_only = cfg.autonomy.workspace_only,
        .allowed_commands = security.resolveAllowedCommands(cfg.autonomy.level, cfg.autonomy.allowed_commands),
        .max_actions_per_hour = cfg.autonomy.max_actions_per_hour,
        .require_approval_for_medium_risk = cfg.autonomy.require_approval_for_medium_risk,
        .block_high_risk_commands = cfg.autonomy.block_high_risk_commands,
        .block_medium_risk_commands = cfg.autonomy.block_medium_risk_commands,
        .allow_raw_url_chars = cfg.autonomy.allow_raw_url_chars,
        .tracker = sec_tracker,
    };

    const tools_slice = tools_mod.allTools(allocator, cfg.workspace_dir, .{
        .http_enabled = cfg.http_request.enabled,
        .http_allowed_domains = cfg.http_request.allowed_domains,
        .http_max_response_size = cfg.http_request.max_response_size,
        .http_timeout_secs = cfg.http_request.timeout_secs,
        .web_search_base_url = cfg.http_request.search_base_url,
        .web_search_provider = cfg.http_request.search_provider,
        .web_search_fallback_providers = cfg.http_request.search_fallback_providers,
        .browser_enabled = cfg.browser.enabled,
        .screenshot_enabled = true,
        .mcp_server_configs = cfg.mcp_servers,
        .agents = cfg.agents,
        .configured_providers = cfg.providers,
        .fallback_api_key = resolved_api_key,
        .allowed_paths = cfg.autonomy.allowed_paths,
        .tools_config = cfg.tools,
        .policy = sec_policy,
        .subagent_manager = subagent_manager,
        .bootstrap_provider = bootstrap_provider,
        .backend_name = cfg.memory.backend,
        .sandbox_backend = cfg.security.sandbox.backend,
        .sandbox_enabled = cfg.sandboxEnabled(),
    }) catch &.{};
    errdefer if (tools_slice.len > 0) tools_mod.deinitTools(allocator, tools_slice);

    var session_mgr = session_mod.SessionManager.init(
        allocator,
        cfg,
        provider_i,
        tools_slice,
        mem_opt,
        runtime_observer.observer(),
        if (mem_rt) |rt| rt.session_store else null,
        if (mem_rt) |rt| rt.response_cache else null,
    );
    session_mgr.policy = sec_policy;
    if (mem_rt) |rt| {
        session_mgr.mem_rt = rt;
        tools_mod.bindMemoryRuntime(tools_slice, rt);
    }

    return .{
        .provider_bundle = provider_bundle,
        .session_mgr = session_mgr,
        .tools_slice = tools_slice,
        .mem_rt = mem_rt,
        .bootstrap_provider = bootstrap_provider,
        .subagent_manager = subagent_manager,
        .sec_tracker = sec_tracker,
        .sec_policy = sec_policy,
    };
}

fn ensureLocalAgentRuntime(
    allocator: std.mem.Allocator,
    runtime_opt: *?LocalAgentRuntime,
    cfg: *const Config,
    runtime_observer: *observability.RuntimeObserver,
    event_bus: ?*bus_mod.Bus,
) !*session_mod.SessionManager {
    if (runtime_opt.* == null) {
        runtime_opt.* = try initLocalAgentRuntime(allocator, cfg, runtime_observer, event_bus);
        if (runtime_opt.*) |*runtime| {
            maybeProbeA2aVision(&runtime.session_mgr, allocator, cfg);
        }
    }
    return &runtime_opt.*.?.session_mgr;
}

const CONTENT_TYPE_JSON = "application/json";
const CONTENT_TYPE_TEXT = "text/plain; charset=utf-8";
const CONTENT_TYPE_XML = "application/xml; charset=utf-8";

fn formatHttpResponseHeader(
    buf: []u8,
    status: []const u8,
    content_type: []const u8,
    body_len: usize,
) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, content_type, body_len },
    );
}

fn writeHttpResponse(stream: *std_compat.net.Stream, status: []const u8, content_type: []const u8, body: []const u8) void {
    var header_buf: [512]u8 = undefined;
    const header = formatHttpResponseHeader(&header_buf, status, content_type, body.len) catch return;
    _ = stream.write(header) catch return;
    if (body.len > 0) _ = stream.write(body) catch {};
}

fn writeJsonResponse(stream: *std_compat.net.Stream, status: []const u8, body: []const u8) void {
    writeHttpResponse(stream, status, CONTENT_TYPE_JSON, body);
}

/// Process an incoming message by spawning `nullclaw agent -m "..."`.
/// Returns the agent's response text. Caller owns the returned memory.
pub fn processIncomingMessage(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    // Find our own executable path
    var self_buf: [std_compat.fs.max_path_bytes]u8 = undefined;
    const self_path = std_compat.fs.selfExePath(&self_buf) catch "nullclaw";

    var child = std_compat.process.Child.init(
        &[_][]const u8{ self_path, "agent", "-m", message },
        allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Read stdout
    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);

    const stdout_reader = child.stdout.?;
    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = stdout_reader.read(&read_buf) catch break;
        if (n == 0) break;
        try stdout_buf.appendSlice(allocator, read_buf[0..n]);
    }

    const term = try child.wait();
    _ = term;

    if (stdout_buf.items.len > 0) {
        return try allocator.dupe(u8, stdout_buf.items);
    }
    return try allocator.dupe(u8, "No response from agent");
}

/// Send a reply to a Telegram chat using the Bot API.
pub fn sendTelegramReply(
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    chat_id: i64,
    message_thread_id: ?i64,
    text: []const u8,
) !void {
    // Build the curl command to call the Telegram API
    const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/sendMessage", .{bot_token});
    defer allocator.free(url);

    // JSON-escape the text for the body
    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(allocator);
    var body_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &body_buf);
    const w = &body_writer.writer;
    try w.print("{{\"chat_id\":{d},\"text\":\"", .{chat_id});
    for (text) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeAll("\"");
    if (message_thread_id) |thread_id| {
        try w.print(",\"message_thread_id\":{d}", .{thread_id});
    }
    try w.writeAll("}");
    body_buf = body_writer.toArrayList();

    const body = body_buf.items;

    var curl_child = std_compat.process.Child.init(
        &[_][]const u8{
            "curl", "-s",                             "-X", "POST",
            "-H",   "Content-Type: application/json", "-d", body,
            url,
        },
        allocator,
    );
    curl_child.stdout_behavior = .Pipe;
    curl_child.stderr_behavior = .Pipe;

    curl_child.spawn() catch return;
    _ = curl_child.wait() catch {};
}

fn userFacingAgentError(err: anyerror) []const u8 {
    return switch (err) {
        error.CurlFailed, error.CurlReadError, error.CurlWaitError, error.CurlWriteError, error.CurlDnsError, error.CurlConnectError, error.CurlTimeout, error.CurlTlsError => "Network error contacting provider. Check base_url, DNS, proxy, and TLS certificates, then try again.",
        error.ProviderDoesNotSupportVision => "The current provider does not support image input.",
        error.AllProvidersFailed => "All configured providers failed for this request. Check model/provider compatibility and credentials.",
        error.NoResponseContent => "Model returned an empty response. Please try again.",
        error.OutOfMemory => "Out of memory.",
        else => "An error occurred. Try again.",
    };
}

fn userFacingAgentErrorJson(err: anyerror) []const u8 {
    return switch (err) {
        error.CurlFailed, error.CurlReadError, error.CurlWaitError, error.CurlWriteError, error.CurlDnsError, error.CurlConnectError, error.CurlTimeout, error.CurlTlsError => "{\"error\":\"network error contacting provider\"}",
        error.ProviderDoesNotSupportVision => "{\"error\":\"provider does not support image input\"}",
        error.AllProvidersFailed => "{\"error\":\"all providers failed for this request\"}",
        error.NoResponseContent => "{\"error\":\"model returned empty response\"}",
        error.OutOfMemory => "{\"error\":\"out of memory\"}",
        else => "{\"error\":\"agent failure\"}",
    };
}

const WebhookHandlerContext = struct {
    root_allocator: std.mem.Allocator,
    req_allocator: std.mem.Allocator,
    raw_request: []const u8,
    method: []const u8,
    target: []const u8,
    client_identifier: []const u8 = "test-client",
    config_opt: ?*const Config,
    state: *GatewayState,
    session_mgr_opt: ?*session_mod.SessionManager,
    response_status: []const u8 = "200 OK",
    response_content_type: []const u8 = CONTENT_TYPE_JSON,
    response_body: []const u8 = "",
};

fn persistCronSchedulerOr500(ctx: *WebhookHandlerContext, scheduler: *cron_mod.CronScheduler) bool {
    cron_mod.saveJobs(scheduler) catch |err| {
        std.log.scoped(.gateway).warn("cron persistence failed: {s}", .{@errorName(err)});
        ctx.response_status = "500 Internal Server Error";
        ctx.response_body = "{\"error\":\"failed to persist cron state\"}";
        return false;
    };
    return true;
}

fn setPlainTextResponse(ctx: *WebhookHandlerContext, body: []const u8) void {
    ctx.response_content_type = CONTENT_TYPE_TEXT;
    ctx.response_body = body;
}

fn setXmlResponse(ctx: *WebhookHandlerContext, body: []const u8) void {
    ctx.response_content_type = CONTENT_TYPE_XML;
    ctx.response_body = body;
}

const WebhookHandlerFn = *const fn (ctx: *WebhookHandlerContext) void;

const WebhookRouteDescriptor = struct {
    path: []const u8,
    handler: WebhookHandlerFn,
};

const webhook_route_descriptors = [_]WebhookRouteDescriptor{
    .{ .path = "/telegram", .handler = handleTelegramWebhookRoute },
    .{ .path = "/whatsapp", .handler = handleWhatsAppWebhookRoute },
    .{ .path = "/slack/events", .handler = handleSlackWebhookRoute },
    .{ .path = "/line", .handler = handleLineWebhookRoute },
    .{ .path = "/lark", .handler = handleLarkWebhookRoute },
    .{ .path = "/wechat", .handler = handleWeChatWebhookRoute },
    .{ .path = "/wecom", .handler = handleWeComWebhookRoute },
    .{ .path = "/qq", .handler = handleQqWebhookRoute },
    .{ .path = "/max", .handler = handleMaxWebhookRoute },
    .{ .path = "/api/messages", .handler = handleTeamsWebhookRoute },
};

fn findWebhookRouteDescriptor(path: []const u8) ?*const WebhookRouteDescriptor {
    for (&webhook_route_descriptors) |*desc| {
        if (std.mem.eql(u8, desc.path, path)) return desc;
    }
    return null;
}

// ── Cron REST API route descriptors ──────────────────────────────

const CronRouteDescriptor = struct {
    path: []const u8,
    method: []const u8,
    handler: *const fn (ctx: *WebhookHandlerContext) void,
};

const cron_route_descriptors = [_]CronRouteDescriptor{
    .{ .path = "/cron", .method = "GET", .handler = handleCronList },
    .{ .path = "/cron/add", .method = "POST", .handler = handleCronAdd },
    .{ .path = "/cron/remove", .method = "POST", .handler = handleCronRemove },
    .{ .path = "/cron/pause", .method = "POST", .handler = handleCronPause },
    .{ .path = "/cron/resume", .method = "POST", .handler = handleCronResume },
    .{ .path = "/cron/update", .method = "POST", .handler = handleCronUpdate },
    .{ .path = "/cron/run", .method = "POST", .handler = handleCronRun },
    .{ .path = "/cron/output", .method = "POST", .handler = handleCronOutput },
    .{ .path = "/cron/load-from-seed", .method = "POST", .handler = handleCronLoadFromSeed },
};

fn findCronRouteDescriptor(path: []const u8) ?*const CronRouteDescriptor {
    for (&cron_route_descriptors) |*desc| {
        if (std.mem.eql(u8, desc.path, path)) return desc;
    }
    return null;
}

fn cronObjectStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value == .string and value.string.len > 0) return value.string;
    return null;
}

fn cronObjectBoolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    if (value == .bool) return value.bool;
    return null;
}

fn lockRequestScheduler(ctx: *WebhookHandlerContext) ?*cron_mod.CronScheduler {
    // Use tryLock to avoid blocking HTTP worker threads indefinitely.
    // Returns null (→ 503) if the scheduler is momentarily busy rather than
    // saturating the thread pool and hanging the entire gateway.
    // Invariant: returns non-null IFF the lock is held. Callers must call
    // unlockRequestScheduler() iff this returns non-null.
    if (!ctx.state.scheduler_mutex.tryLock()) return null;
    if (ctx.state.scheduler == null) {
        ctx.state.scheduler_mutex.unlock();
        return null;
    }
    return ctx.state.scheduler;
}

fn unlockRequestScheduler(ctx: *WebhookHandlerContext) void {
    ctx.state.scheduler_mutex.unlock();
}

/// Serialize a single CronJob to a JSON object appended to `buf`.
fn appendCronJobJson(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, job: cron_mod.CronJob) !void {
    try buf.appendSlice(allocator, "{");
    try buf.appendSlice(allocator, "\"id\":");
    try appendJsonStringBuf(buf, allocator, job.id);
    try buf.appendSlice(allocator, ",\"expression\":");
    try appendJsonStringBuf(buf, allocator, job.expression);
    try buf.appendSlice(allocator, ",\"command\":");
    try appendJsonStringBuf(buf, allocator, job.command);
    var int_buf: [32]u8 = undefined;
    try buf.appendSlice(allocator, ",\"next_run_secs\":");
    try buf.appendSlice(allocator, std.fmt.bufPrint(&int_buf, "{d}", .{job.next_run_secs}) catch "0");
    try buf.appendSlice(allocator, ",\"last_run_secs\":");
    if (job.last_run_secs) |lrs| {
        try buf.appendSlice(allocator, std.fmt.bufPrint(&int_buf, "{d}", .{lrs}) catch "0");
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",\"last_status\":");
    if (job.last_status) |ls| {
        try appendJsonStringBuf(buf, allocator, ls);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",\"last_output\":");
    if (job.last_output) |lo| try appendJsonStringBuf(buf, allocator, lo) else try buf.appendSlice(allocator, "null");
    try buf.appendSlice(allocator, ",\"paused\":");
    try buf.appendSlice(allocator, if (job.paused) "true" else "false");
    try buf.appendSlice(allocator, ",\"one_shot\":");
    try buf.appendSlice(allocator, if (job.one_shot) "true" else "false");
    try buf.appendSlice(allocator, ",\"job_type\":");
    try appendJsonStringBuf(buf, allocator, job.job_type.asStr());
    try buf.appendSlice(allocator, ",\"session_target\":");
    try appendJsonStringBuf(buf, allocator, job.session_target.asStr());
    try buf.appendSlice(allocator, ",\"enabled\":");
    try buf.appendSlice(allocator, if (job.enabled) "true" else "false");
    try buf.appendSlice(allocator, ",\"delete_after_run\":");
    try buf.appendSlice(allocator, if (job.delete_after_run) "true" else "false");
    try buf.appendSlice(allocator, ",\"prompt\":");
    if (job.prompt) |p| try appendJsonStringBuf(buf, allocator, p) else try buf.appendSlice(allocator, "null");
    try buf.appendSlice(allocator, ",\"model\":");
    if (job.model) |m| try appendJsonStringBuf(buf, allocator, m) else try buf.appendSlice(allocator, "null");
    try buf.appendSlice(allocator, ",\"delivery_mode\":");
    try appendJsonStringBuf(buf, allocator, job.delivery.mode.asStr());
    try buf.appendSlice(allocator, ",\"delivery_channel\":");
    if (job.delivery.channel) |channel| try appendJsonStringBuf(buf, allocator, channel) else try buf.appendSlice(allocator, "null");
    try buf.appendSlice(allocator, ",\"delivery_account_id\":");
    if (job.delivery.account_id) |account_id| try appendJsonStringBuf(buf, allocator, account_id) else try buf.appendSlice(allocator, "null");
    try buf.appendSlice(allocator, ",\"delivery_to\":");
    if (job.delivery.to) |to| try appendJsonStringBuf(buf, allocator, to) else try buf.appendSlice(allocator, "null");
    try buf.appendSlice(allocator, ",\"delivery_peer_kind\":");
    if (job.delivery.peer_kind) |peer_kind| {
        try appendJsonStringBuf(buf, allocator, switch (peer_kind) {
            .direct => "direct",
            .group => "group",
            .channel => "channel",
        });
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",\"delivery_peer_id\":");
    if (job.delivery.peer_id) |peer_id| try appendJsonStringBuf(buf, allocator, peer_id) else try buf.appendSlice(allocator, "null");
    try buf.appendSlice(allocator, ",\"delivery_thread_id\":");
    if (job.delivery.thread_id) |thread_id| try appendJsonStringBuf(buf, allocator, thread_id) else try buf.appendSlice(allocator, "null");
    try buf.appendSlice(allocator, ",\"delivery_best_effort\":");
    try buf.appendSlice(allocator, if (job.delivery.best_effort) "true" else "false");
    try buf.appendSlice(allocator, ",\"created_at_s\":");
    try buf.appendSlice(allocator, std.fmt.bufPrint(&int_buf, "{d}", .{job.created_at_s}) catch "0");
    try buf.appendSlice(allocator, ",\"timeout_secs\":");
    if (job.timeout_secs) |t| {
        try buf.appendSlice(allocator, std.fmt.bufPrint(&int_buf, "{d}", .{t}) catch "null");
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",\"skill_name\":");
    if (job.skill_name) |sn| try appendJsonStringBuf(buf, allocator, sn) else try buf.appendSlice(allocator, "null");
    try buf.appendSlice(allocator, ",\"skill_args\":");
    if (job.skill_args) |sa| try appendJsonStringBuf(buf, allocator, sa) else try buf.appendSlice(allocator, "null");
    try buf.appendSlice(allocator, ",\"tz_offset_s\":");
    try buf.appendSlice(allocator, std.fmt.bufPrint(&int_buf, "{d}", .{job.tz_offset_s}) catch "0");
    try buf.appendSlice(allocator, "}");
}

/// Serialize a single cron_backend_mod.CronJob to a JSON object appended to `buf`.
fn appendCronBackendJobJson(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, job: cron_backend_mod.CronJob) !void {
    try buf.appendSlice(allocator, "{");
    try buf.appendSlice(allocator, "\"id\":");
    try appendJsonStringBuf(buf, allocator, job.id);
    try buf.appendSlice(allocator, ",\"expression\":");
    try appendJsonStringBuf(buf, allocator, job.expression);
    try buf.appendSlice(allocator, ",\"command\":");
    try appendJsonStringBuf(buf, allocator, job.command);
    var int_buf: [32]u8 = undefined;
    try buf.appendSlice(allocator, ",\"next_run_secs\":");
    try buf.appendSlice(allocator, std.fmt.bufPrint(&int_buf, "{d}", .{job.next_run_secs}) catch "0");
    try buf.appendSlice(allocator, ",\"last_run_secs\":");
    if (job.last_run_secs) |lrs| {
        try buf.appendSlice(allocator, std.fmt.bufPrint(&int_buf, "{d}", .{lrs}) catch "0");
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",\"last_status\":");
    if (job.last_status) |ls| {
        try appendJsonStringBuf(buf, allocator, ls);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",\"last_output\":");
    if (job.last_output) |lo| try appendJsonStringBuf(buf, allocator, lo) else try buf.appendSlice(allocator, "null");
    try buf.appendSlice(allocator, ",\"paused\":");
    try buf.appendSlice(allocator, if (job.paused) "true" else "false");
    try buf.appendSlice(allocator, ",\"one_shot\":");
    try buf.appendSlice(allocator, if (job.one_shot) "true" else "false");
    try buf.appendSlice(allocator, ",\"job_type\":");
    try appendJsonStringBuf(buf, allocator, job.job_type.asStr());
    try buf.appendSlice(allocator, ",\"enabled\":");
    try buf.appendSlice(allocator, if (job.enabled) "true" else "false");
    try buf.appendSlice(allocator, ",\"delete_after_run\":");
    try buf.appendSlice(allocator, if (job.delete_after_run) "true" else "false");
    try buf.appendSlice(allocator, ",\"prompt\":");
    if (job.prompt) |p| try appendJsonStringBuf(buf, allocator, p) else try buf.appendSlice(allocator, "null");
    try buf.appendSlice(allocator, ",\"model\":");
    if (job.model) |m| try appendJsonStringBuf(buf, allocator, m) else try buf.appendSlice(allocator, "null");
    try buf.appendSlice(allocator, ",\"delivery_mode\":");
    try appendJsonStringBuf(buf, allocator, job.delivery.mode.asStr());
    try buf.appendSlice(allocator, ",\"delivery_channel\":");
    if (job.delivery.channel) |ch| try appendJsonStringBuf(buf, allocator, ch) else try buf.appendSlice(allocator, "null");
    try buf.appendSlice(allocator, ",\"delivery_account_id\":");
    if (job.delivery.account_id) |aid| try appendJsonStringBuf(buf, allocator, aid) else try buf.appendSlice(allocator, "null");
    try buf.appendSlice(allocator, ",\"delivery_to\":");
    if (job.delivery.to) |to| try appendJsonStringBuf(buf, allocator, to) else try buf.appendSlice(allocator, "null");
    try buf.appendSlice(allocator, ",\"delivery_best_effort\":");
    try buf.appendSlice(allocator, if (job.delivery.best_effort) "true" else "false");
    try buf.appendSlice(allocator, ",\"created_at_s\":");
    try buf.appendSlice(allocator, std.fmt.bufPrint(&int_buf, "{d}", .{job.created_at_s}) catch "0");
    try buf.appendSlice(allocator, ",\"timeout_secs\":");
    if (job.timeout_secs) |t| {
        try buf.appendSlice(allocator, std.fmt.bufPrint(&int_buf, "{d}", .{t}) catch "null");
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",\"skill_name\":");
    if (job.skill_name) |sn| try appendJsonStringBuf(buf, allocator, sn) else try buf.appendSlice(allocator, "null");
    try buf.appendSlice(allocator, ",\"skill_args\":");
    if (job.skill_args) |sa| try appendJsonStringBuf(buf, allocator, sa) else try buf.appendSlice(allocator, "null");
    try buf.appendSlice(allocator, ",\"tz_offset_s\":");
    try buf.appendSlice(allocator, std.fmt.bufPrint(&int_buf, "{d}", .{job.tz_offset_s}) catch "0");
    try buf.appendSlice(allocator, ",\"verification_mode\":");
    try appendJsonStringBuf(buf, allocator, job.verification_mode.asStr());
    try buf.appendSlice(allocator, ",\"repair_policy\":");
    try appendJsonStringBuf(buf, allocator, job.repair_policy.asStr());
    try buf.appendSlice(allocator, "}");
}

/// Append a JSON-escaped string literal (with surrounding quotes) to `buf`.
fn appendJsonStringBuf(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

fn handleCronList(ctx: *WebhookHandlerContext) void {
    if (!std.mem.eql(u8, ctx.method, "GET")) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }

    // ── DB-direct path ────────────────────────────────────────────────
    var used_db = false;
    if (ctx.state.cron_db_path) |db_path| {
        const db = cron_mod.openCronDbAtPath(db_path) catch null;
        if (db) |d| {
            defer cron_mod.closeCronDb(d);
            used_db = true;
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            cron_mod.dbListJobsJson(d, &buf, ctx.req_allocator, 0) catch {
                ctx.response_status = "500 Internal Server Error";
                ctx.response_body = "{\"error\":\"db query failed\"}";
                return;
            };
            ctx.response_status = "200 OK";
            ctx.response_body = buf.items;
            return;
        }
    }

    // ── Legacy in-memory scheduler path ──────────────────────────────
    if (!used_db) {
        const sched = lockRequestScheduler(ctx) orelse {
            ctx.response_status = "503 Service Unavailable";
            ctx.response_body = "{\"error\":\"scheduler not running\"}";
            return;
        };
        defer unlockRequestScheduler(ctx);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        buf.appendSlice(ctx.req_allocator, "[") catch {
            ctx.response_status = "500 Internal Server Error";
            ctx.response_body = "{\"error\":\"out of memory\"}";
            return;
        };
        const jobs = sched.listJobs();
        for (jobs, 0..) |job, i| {
            if (i > 0) buf.appendSlice(ctx.req_allocator, ",") catch {};
            appendCronJobJson(&buf, ctx.req_allocator, job) catch {
                ctx.response_status = "500 Internal Server Error";
                ctx.response_body = "{\"error\":\"serialization failed\"}";
                return;
            };
        }
        buf.appendSlice(ctx.req_allocator, "]") catch {};
        ctx.response_status = "200 OK";
        ctx.response_body = buf.items;
    }
}

fn handleCronAdd(ctx: *WebhookHandlerContext) void {
    if (!std.mem.eql(u8, ctx.method, "POST")) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }
    const body = extractBody(ctx.raw_request) orelse {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"missing body\"}";
        return;
    };

    const parsed = std.json.parseFromSlice(std.json.Value, ctx.req_allocator, body, .{}) catch {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"invalid json\"}";
        return;
    };
    if (parsed.value != .object) {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"json body must be an object\"}";
        return;
    }

    const obj = parsed.value.object;
    const expression_opt = cronObjectStringField(obj, "expression");
    const delay_opt = cronObjectStringField(obj, "delay");
    if (expression_opt == null and delay_opt == null) {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"missing expression or delay\"}";
        return;
    }
    if (expression_opt != null and delay_opt != null) {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"provide expression or delay, not both\"}";
        return;
    }

    const prompt_opt = cronObjectStringField(obj, "prompt");
    const command_opt = cronObjectStringField(obj, "command");
    const name_add_opt = cronObjectStringField(obj, "name");
    const model_opt = cronObjectStringField(obj, "model");
    const session_target = if (cronObjectStringField(obj, "session_target")) |raw|
        cron_mod.SessionTarget.parseStrict(raw) catch {
            ctx.response_status = "400 Bad Request";
            ctx.response_body = "{\"error\":\"invalid session_target\"}";
            return;
        }
    else
        cron_mod.SessionTarget.isolated;
    const delivery_mode_opt = cronObjectStringField(obj, "delivery_mode");
    const delivery_channel_opt = cronObjectStringField(obj, "delivery_channel");
    const delivery_account_id_opt = cronObjectStringField(obj, "delivery_account_id");
    const delivery_to_opt = cronObjectStringField(obj, "delivery_to");
    const delivery_peer_kind = blk: {
        const raw = cronObjectStringField(obj, "delivery_peer_kind") orelse break :blk null;
        if (std.mem.eql(u8, raw, "direct")) break :blk agent_routing.ChatType.direct;
        if (std.mem.eql(u8, raw, "group")) break :blk agent_routing.ChatType.group;
        if (std.mem.eql(u8, raw, "channel")) break :blk agent_routing.ChatType.channel;
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"invalid delivery_peer_kind\"}";
        return;
    };
    const delivery_peer_id_opt = cronObjectStringField(obj, "delivery_peer_id");
    const delivery_thread_id_opt = cronObjectStringField(obj, "delivery_thread_id");
    const delivery_best_effort = cronObjectBoolField(obj, "delivery_best_effort") orelse true;
    const one_shot_opt = cronObjectBoolField(obj, "one_shot");
    const enabled_add_opt = cronObjectBoolField(obj, "enabled");
    const job_type_opt = cronObjectStringField(obj, "job_type");
    const skill_name_opt = cronObjectStringField(obj, "skill_name");
    const skill_args_opt = cronObjectStringField(obj, "skill_args");
    const timeout_secs_add: ?u32 = blk: {
        const v = jsonIntField(body, "timeout_secs") orelse break :blk null;
        if (v <= 0) break :blk null;
        break :blk @intCast(v);
    };
    const tz_offset_s_add: i32 = blk: {
        const v = jsonIntField(body, "tz_offset_s") orelse break :blk 0;
        break :blk @intCast(v);
    };
    const verification_mode_add = if (cronObjectStringField(obj, "verification_mode")) |raw|
        cron_backend_mod.VerificationMode.parseStrict(raw) catch {
            ctx.response_status = "400 Bad Request";
            ctx.response_body = "{\"error\":\"invalid verification_mode\"}";
            return;
        }
    else
        cron_backend_mod.VerificationMode.none;
    const repair_policy_add = if (cronObjectStringField(obj, "repair_policy")) |raw|
        cron_backend_mod.RepairPolicy.parseStrict(raw) catch {
            ctx.response_status = "400 Bad Request";
            ctx.response_body = "{\"error\":\"invalid repair_policy\"}";
            return;
        }
    else
        cron_backend_mod.RepairPolicy.none;

    // ── DB-direct path ────────────────────────────────────────────────
    if (ctx.state.cron_db_backend) |*be| {
        // For @once: delay jobs, compute next_run_secs from the delay string
        // and pass it as next_run_secs_override so vtableAdd doesn't try to
        // parse "@once:30m" as a cron expression.
        const next_run_override: i64 = if (delay_opt) |delay| blk: {
            const delay_secs = cron_mod.parseDuration(delay) catch {
                ctx.response_status = "400 Bad Request";
                ctx.response_body = "{\"error\":\"invalid delay\"}";
                return;
            };
            break :blk std_compat.time.timestamp() + delay_secs;
        } else 0;

        var expr_buf: [80]u8 = undefined;
        const expr: []const u8 = if (delay_opt) |delay|
            std.fmt.bufPrint(&expr_buf, "@once:{s}", .{delay}) catch "@once"
        else
            expression_opt.?;

        // Skill jobs don't use command/prompt for execution — only skill_name/skill_args.
        // For shell and agent jobs, command or prompt is required.
        const is_skill_job = skill_name_opt != null or
            (job_type_opt != null and std.mem.eql(u8, job_type_opt.?, "skill"));
        if (is_skill_job and (skill_name_opt == null or skill_name_opt.?.len == 0)) {
            ctx.response_status = "400 Bad Request";
            ctx.response_body = "{\"error\":\"skill jobs require skill_name\"}";
            return;
        }

        // Validate at add time (not just execution) to prevent persisting unsafe jobs.
        if (is_skill_job) {
            cron_mod.validateSkillNameSafe(skill_name_opt.?) catch {
                ctx.response_status = "400 Bad Request";
                ctx.response_body = "{\"error\":\"invalid or unsafe skill_name\"}";
                return;
            };
            if (skill_args_opt) |sa| {
                cron_mod.validateSkillArgsSafe(sa) catch {
                    ctx.response_status = "400 Bad Request";
                    ctx.response_body = "{\"error\":\"invalid or unsafe skill_args\"}";
                    return;
                };
            }
        }
        const cmd: []const u8 = if (prompt_opt != null)
            prompt_opt.?
        else if (command_opt) |c|
            c
        else if (is_skill_job)
            "" // placeholder; execution path uses skill_name/skill_args
        else {
            ctx.response_status = "400 Bad Request";
            ctx.response_body = "{\"error\":\"missing command or prompt\"}";
            return;
        };

        const db_delivery = cron_backend_mod.DeliveryConfig{
            .mode = if (delivery_mode_opt) |raw|
                cron_backend_mod.DeliveryMode.parse(raw)
            else if (delivery_channel_opt != null or delivery_account_id_opt != null or delivery_to_opt != null)
                .always
            else
                .none,
            .channel = delivery_channel_opt,
            .account_id = delivery_account_id_opt,
            .to = delivery_to_opt,
            .peer_kind = delivery_peer_kind,
            .peer_id = delivery_peer_id_opt,
            .thread_id = delivery_thread_id_opt,
            .best_effort = delivery_best_effort,
        };

        // Determine job_type: explicit "skill" wins, then infer from fields.
        const db_job_type: cron_backend_mod.JobType = if (job_type_opt) |jt|
            cron_backend_mod.JobType.parse(jt)
        else if (skill_name_opt != null)
            .skill
        else if (prompt_opt != null)
            .agent
        else
            .shell;

        const spec = cron_backend_mod.NewJobSpec{
            .expression = expr,
            .job_type = db_job_type,
            .command = cmd,
            .prompt = prompt_opt,
            .name = name_add_opt,
            .model = model_opt,
            .skill_name = skill_name_opt,
            .skill_args = skill_args_opt,
            .one_shot = one_shot_opt orelse (delay_opt != null),
            .delete_after_run = one_shot_opt orelse (delay_opt != null),
            .enabled = enabled_add_opt orelse true,
            .timeout_secs = timeout_secs_add,
            .delivery = db_delivery,
            .session_target = @enumFromInt(@intFromEnum(session_target)),
            .next_run_secs_override = next_run_override,
            .tz_offset_s = tz_offset_s_add,
            .verification_mode = verification_mode_add,
            .repair_policy = repair_policy_add,
        };

        const job = be.backend().add(ctx.req_allocator, spec) catch |err| {
            ctx.response_status = "400 Bad Request";
            ctx.response_body = if (err == error.InvalidCronExpression)
                "{\"error\":\"invalid cron expression\"}"
            else
                "{\"error\":\"add failed\"}";
            return;
        };

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        appendCronBackendJobJson(&buf, ctx.req_allocator, job) catch {
            ctx.response_status = "500 Internal Server Error";
            ctx.response_body = "{\"error\":\"serialization failed\"}";
            return;
        };
        ctx.response_status = "200 OK";
        ctx.response_body = buf.items;
        return;
    }

    if (prompt_opt == null and session_target != .isolated) {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"session_target requires prompt\"}";
        return;
    }

    // ── Legacy in-memory path ─────────────────────────────────────────
    const sched = lockRequestScheduler(ctx) orelse {
        ctx.response_status = "503 Service Unavailable";
        ctx.response_body = "{\"error\":\"scheduler not running\"}";
        return;
    };
    defer unlockRequestScheduler(ctx);

    const delivery = cron_mod.enrichDeliveryRouting(.{
        .mode = if (delivery_mode_opt) |raw|
            cron_mod.DeliveryMode.parse(raw)
        else if (delivery_channel_opt != null or delivery_account_id_opt != null or delivery_to_opt != null)
            .always
        else
            .none,
        .channel = delivery_channel_opt,
        .account_id = delivery_account_id_opt,
        .to = delivery_to_opt,
        .peer_kind = delivery_peer_kind,
        .peer_id = delivery_peer_id_opt,
        .thread_id = delivery_thread_id_opt,
        .best_effort = delivery_best_effort,
        .channel_owned = false,
        .account_id_owned = false,
        .to_owned = false,
    });

    const job_ptr = if (delay_opt) |delay|
        if (prompt_opt != null)
            sched.addAgentOnce(delay, prompt_opt.?, model_opt, delivery) catch |err| {
                ctx.response_status = "400 Bad Request";
                ctx.response_body = if (err == error.MaxTasksReached)
                    "{\"error\":\"max tasks reached\"}"
                else if (err == error.EmptyDelay or err == error.InvalidDurationNumber or err == error.UnknownDurationUnit or err == error.DurationTooLarge)
                    "{\"error\":\"invalid delay\"}"
                else
                    "{\"error\":\"add failed\"}";
                return;
            }
        else blk: {
            const cmd = command_opt orelse {
                ctx.response_status = "400 Bad Request";
                ctx.response_body = "{\"error\":\"missing command or prompt\"}";
                return;
            };
            break :blk sched.addOnce(delay, cmd) catch |err| {
                ctx.response_status = "400 Bad Request";
                ctx.response_body = if (err == error.MaxTasksReached)
                    "{\"error\":\"max tasks reached\"}"
                else if (err == error.EmptyDelay or err == error.InvalidDurationNumber or err == error.UnknownDurationUnit or err == error.DurationTooLarge)
                    "{\"error\":\"invalid delay\"}"
                else
                    "{\"error\":\"add failed\"}";
                return;
            };
        }
    else if (prompt_opt != null)
        sched.addAgentJob(expression_opt.?, prompt_opt.?, model_opt, delivery) catch |err| {
            ctx.response_status = "400 Bad Request";
            ctx.response_body = if (err == error.MaxTasksReached)
                "{\"error\":\"max tasks reached\"}"
            else if (err == error.InvalidCronExpression)
                "{\"error\":\"invalid cron expression\"}"
            else
                "{\"error\":\"add failed\"}";
            return;
        }
    else blk: {
        const cmd = command_opt orelse {
            ctx.response_status = "400 Bad Request";
            ctx.response_body = "{\"error\":\"missing command or prompt\"}";
            return;
        };
        break :blk sched.addJob(expression_opt.?, cmd) catch |err| {
            ctx.response_status = "400 Bad Request";
            ctx.response_body = if (err == error.MaxTasksReached)
                "{\"error\":\"max tasks reached\"}"
            else if (err == error.InvalidCronExpression)
                "{\"error\":\"invalid cron expression\"}"
            else
                "{\"error\":\"add failed\"}";
            return;
        };
    };

    if (timeout_secs_add) |t| job_ptr.timeout_secs = t;
    if (one_shot_opt) |os| {
        job_ptr.one_shot = os;
        job_ptr.delete_after_run = os;
    }
    if (enabled_add_opt) |ena| {
        job_ptr.enabled = ena;
        job_ptr.paused = !ena;
    }
    if (name_add_opt) |n| {
        job_ptr.name = sched.allocator.dupe(u8, n) catch null;
    }
    if (skill_name_opt) |sn| {
        job_ptr.skill_name = sched.allocator.dupe(u8, sn) catch null;
        job_ptr.job_type = .skill;
    }
    if (skill_args_opt) |sa| {
        job_ptr.skill_args = sched.allocator.dupe(u8, sa) catch null;
    }
    if (job_type_opt) |jt| {
        job_ptr.job_type = cron_mod.JobType.parse(jt);
    }
    // Apply delivery config for shell expression-path jobs (addJob doesn't accept delivery).
    // Strings must be duped into the scheduler allocator — delivery_*_opt point into
    // the req_allocator JSON parse tree which is freed after this handler returns.
    if (expression_opt != null and prompt_opt == null) {
        const ch = if (delivery_channel_opt) |s| sched.allocator.dupe(u8, s) catch null else null;
        const aid = if (delivery_account_id_opt) |s| sched.allocator.dupe(u8, s) catch null else null;
        const to = if (delivery_to_opt) |s| sched.allocator.dupe(u8, s) catch null else null;
        job_ptr.delivery = .{
            .mode = if (delivery_mode_opt) |raw|
                cron_mod.DeliveryMode.parse(raw)
            else if (ch != null or aid != null or to != null)
                .always
            else
                .none,
            .channel = ch,
            .account_id = aid,
            .to = to,
            .best_effort = delivery_best_effort,
            .channel_owned = ch != null,
            .account_id_owned = aid != null,
            .to_owned = to != null,
        };
    }

    job_ptr.session_target = session_target;
    if (tz_offset_s_add != 0) {
        job_ptr.tz_offset_s = tz_offset_s_add;
        job_ptr.next_run_secs = cron_mod.nextRunForCronExpressionTz(
            job_ptr.expression,
            std_compat.time.timestamp(),
            tz_offset_s_add,
        ) catch job_ptr.next_run_secs;
    }
    cron_mod.saveJobs(sched) catch |err| {
        std.log.scoped(.gateway).warn("cron add persist failed: {s}", .{@errorName(err)});
        ctx.response_status = "500 Internal Server Error";
        ctx.response_body = "{\"error\":\"failed to persist job\"}";
        return;
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendCronJobJson(&buf, ctx.req_allocator, job_ptr.*) catch {
        ctx.response_status = "500 Internal Server Error";
        ctx.response_body = "{\"error\":\"serialization failed\"}";
        return;
    };
    ctx.response_status = "200 OK";
    ctx.response_body = buf.items;
}

fn handleCronRemove(ctx: *WebhookHandlerContext) void {
    if (!std.mem.eql(u8, ctx.method, "POST")) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }
    const body = extractBody(ctx.raw_request) orelse {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"missing body\"}";
        return;
    };
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.req_allocator, body, .{}) catch {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"invalid json\"}";
        return;
    };
    if (parsed.value != .object) {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"json body must be an object\"}";
        return;
    }
    const id = cronObjectStringField(parsed.value.object, "id") orelse {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"missing id\"}";
        return;
    };

    // ── DB-direct path ────────────────────────────────────────────────
    if (ctx.state.cron_db_backend) |*be| {
        const found = be.backend().remove(id) catch false;
        if (!found) {
            ctx.response_status = "404 Not Found";
            ctx.response_body = "{\"error\":\"job not found\"}";
            return;
        }
        ctx.response_status = "200 OK";
        ctx.response_body = "{\"status\":\"removed\"}";
        return;
    }

    // ── Legacy in-memory path ─────────────────────────────────────────
    const sched = lockRequestScheduler(ctx) orelse {
        ctx.response_status = "503 Service Unavailable";
        ctx.response_body = "{\"error\":\"scheduler not running\"}";
        return;
    };
    defer unlockRequestScheduler(ctx);

    if (!sched.removeJob(id)) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"job not found\"}";
        return;
    }
    cron_mod.saveJobs(sched) catch |err| {
        std.log.scoped(.gateway).warn("cron delete failed: {s}", .{@errorName(err)});
        ctx.response_status = "500 Internal Server Error";
        ctx.response_body = "{\"error\":\"failed to persist job\"}";
        return;
    };
    ctx.response_status = "200 OK";
    ctx.response_body = "{\"status\":\"removed\"}";
}

fn handleCronPause(ctx: *WebhookHandlerContext) void {
    if (!std.mem.eql(u8, ctx.method, "POST")) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }
    const body = extractBody(ctx.raw_request) orelse {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"missing body\"}";
        return;
    };
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.req_allocator, body, .{}) catch {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"invalid json\"}";
        return;
    };
    if (parsed.value != .object) {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"json body must be an object\"}";
        return;
    }
    const id = cronObjectStringField(parsed.value.object, "id") orelse {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"missing id\"}";
        return;
    };

    // ── DB-direct path ────────────────────────────────────────────────
    if (ctx.state.cron_db_backend) |*be| {
        const found = be.backend().pause(id) catch false;
        if (!found) {
            ctx.response_status = "404 Not Found";
            ctx.response_body = "{\"error\":\"job not found\"}";
            return;
        }
        ctx.response_status = "200 OK";
        ctx.response_body = "{\"status\":\"paused\"}";
        return;
    }

    // ── Legacy in-memory path ─────────────────────────────────────────
    const sched = lockRequestScheduler(ctx) orelse {
        ctx.response_status = "503 Service Unavailable";
        ctx.response_body = "{\"error\":\"scheduler not running\"}";
        return;
    };
    defer unlockRequestScheduler(ctx);

    if (!sched.pauseJob(id)) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"job not found\"}";
        return;
    }
    cron_mod.saveJobs(sched) catch |err| {
        std.log.scoped(.gateway).warn("cron pause persist failed: {s}", .{@errorName(err)});
        ctx.response_status = "500 Internal Server Error";
        ctx.response_body = "{\"error\":\"failed to persist job\"}";
        return;
    };
    ctx.response_status = "200 OK";
    ctx.response_body = "{\"status\":\"paused\"}";
}

fn handleCronResume(ctx: *WebhookHandlerContext) void {
    if (!std.mem.eql(u8, ctx.method, "POST")) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }
    const body = extractBody(ctx.raw_request) orelse {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"missing body\"}";
        return;
    };
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.req_allocator, body, .{}) catch {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"invalid json\"}";
        return;
    };
    if (parsed.value != .object) {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"json body must be an object\"}";
        return;
    }
    const id = cronObjectStringField(parsed.value.object, "id") orelse {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"missing id\"}";
        return;
    };

    // ── DB-direct path ────────────────────────────────────────────────
    if (ctx.state.cron_db_backend) |*be| {
        const found = be.backend().resumeJob(id) catch false;
        if (!found) {
            ctx.response_status = "404 Not Found";
            ctx.response_body = "{\"error\":\"job not found\"}";
            return;
        }
        ctx.response_status = "200 OK";
        ctx.response_body = "{\"status\":\"resumed\"}";
        return;
    }

    // ── Legacy in-memory path ─────────────────────────────────────────
    const sched = lockRequestScheduler(ctx) orelse {
        ctx.response_status = "503 Service Unavailable";
        ctx.response_body = "{\"error\":\"scheduler not running\"}";
        return;
    };
    defer unlockRequestScheduler(ctx);

    if (!sched.resumeJob(id)) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"job not found\"}";
        return;
    }
    cron_mod.saveJobs(sched) catch |err| {
        std.log.scoped(.gateway).warn("cron resume persist failed: {s}", .{@errorName(err)});
        ctx.response_status = "500 Internal Server Error";
        ctx.response_body = "{\"error\":\"failed to persist job\"}";
        return;
    };
    ctx.response_status = "200 OK";
    ctx.response_body = "{\"status\":\"resumed\"}";
}

fn handleCronUpdate(ctx: *WebhookHandlerContext) void {
    if (!std.mem.eql(u8, ctx.method, "POST")) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }
    const body = extractBody(ctx.raw_request) orelse {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"missing body\"}";
        return;
    };
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.req_allocator, body, .{}) catch {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"invalid json\"}";
        return;
    };
    if (parsed.value != .object) {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"json body must be an object\"}";
        return;
    }

    const obj = parsed.value.object;
    const id = cronObjectStringField(obj, "id") orelse {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"missing id\"}";
        return;
    };

    const expression = cronObjectStringField(obj, "expression");
    const command = cronObjectStringField(obj, "command");
    const prompt = cronObjectStringField(obj, "prompt");
    const name = cronObjectStringField(obj, "name");
    const model = cronObjectStringField(obj, "model");
    const delivery_channel = cronObjectStringField(obj, "delivery_channel");
    const delivery_to = cronObjectStringField(obj, "delivery_to");
    const delivery_mode = cronObjectStringField(obj, "delivery_mode");
    const delivery_account_id = cronObjectStringField(obj, "delivery_account_id");
    const paused_opt = cronObjectBoolField(obj, "paused");
    const enabled_explicit = cronObjectBoolField(obj, "enabled");
    const enabled_opt = if (enabled_explicit) |enabled| enabled else if (paused_opt) |paused| !paused else null;

    const timeout_secs_opt: ?u32 = blk: {
        const v = jsonIntField(body, "timeout_secs") orelse break :blk null;
        if (v <= 0) break :blk null;
        break :blk @intCast(v);
    };

    const next_run_secs_opt: ?i64 = jsonIntField(body, "next_run_secs");
    const tz_offset_s_opt: ?i32 = blk: {
        const v = jsonIntField(body, "tz_offset_s") orelse break :blk null;
        break :blk @intCast(v);
    };
    const skill_name_upd = cronObjectStringField(obj, "skill_name");
    const skill_args_upd = cronObjectStringField(obj, "skill_args");
    const session_target = if (cronObjectStringField(obj, "session_target")) |raw|
        cron_mod.SessionTarget.parseStrict(raw) catch {
            ctx.response_status = "400 Bad Request";
            ctx.response_body = "{\"error\":\"invalid session_target\"}";
            return;
        }
    else
        null;
    const verification_mode_upd: ?cron_mod.VerificationMode =
        if (cronObjectStringField(obj, "verification_mode")) |raw|
            cron_mod.VerificationMode.parseStrict(raw) catch {
                ctx.response_status = "400 Bad Request";
                ctx.response_body = "{\"error\":\"invalid verification_mode\"}";
                return;
            }
        else
            null;
    const repair_policy_upd: ?cron_mod.RepairPolicy =
        if (cronObjectStringField(obj, "repair_policy")) |raw|
            cron_mod.RepairPolicy.parseStrict(raw) catch {
                ctx.response_status = "400 Bad Request";
                ctx.response_body = "{\"error\":\"invalid repair_policy\"}";
                return;
            }
        else
            null;

    // ── DB-direct path ────────────────────────────────────────────────
    if (ctx.state.cron_db_backend) |*be| {
        const patch = cron_backend_mod.CronJobPatch{
            .expression = expression,
            .command = command,
            .prompt = prompt,
            .name = name,
            .model = model,
            .skill_name = skill_name_upd,
            .skill_args = skill_args_upd,
            .enabled = enabled_opt,
            .delivery_channel = delivery_channel,
            .delivery_to = delivery_to,
            .delivery_mode = delivery_mode,
            .delivery_account_id = delivery_account_id,
            .timeout_secs = timeout_secs_opt,
            .next_run_secs = next_run_secs_opt,
            .tz_offset_s = tz_offset_s_opt,
            .session_target = if (session_target) |st| @as(cron_backend_mod.SessionTarget, @enumFromInt(@intFromEnum(st))) else null,
            .verification_mode = if (verification_mode_upd) |vm| @as(cron_backend_mod.VerificationMode, @enumFromInt(@intFromEnum(vm))) else null,
            .repair_policy = if (repair_policy_upd) |rp| @as(cron_backend_mod.RepairPolicy, @enumFromInt(@intFromEnum(rp))) else null,
        };
        const found = be.backend().update(id, patch) catch false;
        if (!found) {
            ctx.response_status = "404 Not Found";
            ctx.response_body = "{\"error\":\"job not found or update failed\"}";
            return;
        }
        ctx.response_status = "200 OK";
        ctx.response_body = "{\"status\":\"updated\"}";
        return;
    }

    // ── Legacy in-memory path ─────────────────────────────────────────
    const sched = lockRequestScheduler(ctx) orelse {
        ctx.response_status = "503 Service Unavailable";
        ctx.response_body = "{\"error\":\"scheduler not running\"}";
        return;
    };
    defer unlockRequestScheduler(ctx);

    // Validate session_target only applies to agent/skill jobs.
    if (session_target != null) {
        if (sched.getJob(id)) |existing| {
            if (existing.job_type == .shell) {
                ctx.response_status = "400 Bad Request";
                ctx.response_body = "{\"error\":\"session_target requires agent job\"}";
                return;
            }
        }
    }

    const patch = cron_mod.CronJobPatch{
        .expression = expression,
        .command = command,
        .prompt = prompt,
        .name = name,
        .model = model,
        .skill_name = skill_name_upd,
        .skill_args = skill_args_upd,
        .enabled = enabled_opt,
        .delivery_channel = delivery_channel,
        .delivery_to = delivery_to,
        .delivery_mode = delivery_mode,
        .delivery_account_id = delivery_account_id,
        .timeout_secs = timeout_secs_opt,
        .next_run_secs = next_run_secs_opt,
        .tz_offset_s = tz_offset_s_opt,
        .session_target = session_target,
        .verification_mode = verification_mode_upd,
        .repair_policy = repair_policy_upd,
    };

    if (!sched.updateJob(sched.allocator, id, patch)) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"job not found or update failed\"}";
        return;
    }
    cron_mod.saveJobs(sched) catch |err| {
        std.log.scoped(.gateway).warn("cron update persist failed: {s}", .{@errorName(err)});
        ctx.response_status = "500 Internal Server Error";
        ctx.response_body = "{\"error\":\"failed to persist job\"}";
        return;
    };
    ctx.response_status = "200 OK";
    ctx.response_body = "{\"status\":\"updated\"}";
}

fn handleCronRun(ctx: *WebhookHandlerContext) void {
    if (!std.mem.eql(u8, ctx.method, "POST")) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }
    const body = extractBody(ctx.raw_request) orelse {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"missing body\"}";
        return;
    };
    const id = jsonStringField(body, "id") orelse {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"missing id\"}";
        return;
    };

    if (ctx.state.cron_db_path) |db_path| {
        // ── DB-direct path: enqueue job and atomically advance next_run_secs ──
        // Uses dbManualEnqueueJob (not dbEnqueueJob) so the scheduler tick does
        // not immediately re-fire the job after a manual trigger.
        cron_mod.dbManualEnqueueJob(db_path, id, std_compat.time.timestamp()) catch |err| {
            if (err == error.JobNotFound) {
                ctx.response_status = "404 Not Found";
                ctx.response_body = "{\"error\":\"job not found\"}";
            } else {
                ctx.response_status = "500 Internal Server Error";
                ctx.response_body = "{\"error\":\"failed to enqueue job\"}";
            }
            return;
        };

        // Wake the worker.
        {
            ctx.state.run_queue_mutex.lock();
            defer ctx.state.run_queue_mutex.unlock();
            ctx.state.run_queue_cond.signal();
        }
    } else {
        // ── Legacy in-memory path ─────────────────────────────────────────────
        {
            ctx.state.scheduler_mutex.lock();
            defer ctx.state.scheduler_mutex.unlock();
            const sched = ctx.state.scheduler orelse {
                ctx.response_status = "503 Service Unavailable";
                ctx.response_body = "{\"error\":\"scheduler not running\"}";
                return;
            };
            if (sched.getMutableJob(id) == null) {
                ctx.response_status = "404 Not Found";
                ctx.response_body = "{\"error\":\"job not found\"}";
                return;
            }
        }
        const id_dupe = ctx.state.allocator.dupe(u8, id) catch {
            ctx.response_status = "500 Internal Server Error";
            ctx.response_body = "{\"error\":\"out of memory\"}";
            return;
        };
        ctx.state.enqueueRunJob(id_dupe) catch {
            ctx.state.allocator.free(id_dupe);
            ctx.response_status = "500 Internal Server Error";
            ctx.response_body = "{\"error\":\"queue full\"}";
            return;
        };
    }

    ctx.response_status = "200 OK";
    ctx.response_body = "{\"status\":\"queued\"}";
}

fn handleCronOutput(ctx: *WebhookHandlerContext) void {
    const body = extractBody(ctx.raw_request) orelse {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"missing body\"}";
        return;
    };
    const id = jsonStringField(body, "id") orelse {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"id required\"}";
        return;
    };

    // ── DB-direct path ────────────────────────────────────────────────
    var used_db = false;
    if (ctx.state.cron_db_path) |db_path| {
        const db = cron_mod.openCronDbAtPath(db_path) catch null;
        if (db) |d| {
            defer cron_mod.closeCronDb(d);
            used_db = true;
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            const found = cron_mod.dbGetJobOutputJson(d, id, &buf, ctx.req_allocator) catch {
                ctx.response_status = "500 Internal Server Error";
                ctx.response_body = "{\"error\":\"db query failed\"}";
                return;
            };
            if (!found) {
                ctx.response_status = "404 Not Found";
                ctx.response_body = "{\"error\":\"not found\"}";
                return;
            }
            ctx.response_status = "200 OK";
            ctx.response_body = buf.items;
            return;
        }
    }

    // ── Legacy in-memory scheduler path ──────────────────────────────
    if (!used_db) {
        ctx.state.scheduler_mutex.lock();
        defer ctx.state.scheduler_mutex.unlock();
        const sched = ctx.state.scheduler orelse {
            ctx.response_status = "503 Service Unavailable";
            ctx.response_body = "{\"error\":\"scheduler not running\"}";
            return;
        };
        const job = sched.getJob(id) orelse {
            ctx.response_status = "404 Not Found";
            ctx.response_body = "{\"error\":\"not found\"}";
            return;
        };
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        buf.appendSlice(ctx.req_allocator, "{\"id\":") catch {
            ctx.response_status = "500 Internal Server Error";
            ctx.response_body = "{\"error\":\"out of memory\"}";
            return;
        };
        appendJsonStringBuf(&buf, ctx.req_allocator, job.id) catch {};
        buf.appendSlice(ctx.req_allocator, ",\"last_output\":") catch {};
        if (job.last_output) |lo| {
            appendJsonStringBuf(&buf, ctx.req_allocator, lo) catch {};
        } else {
            buf.appendSlice(ctx.req_allocator, "null") catch {};
        }
        buf.appendSlice(ctx.req_allocator, ",\"last_run_secs\":") catch {};
        if (job.last_run_secs) |lrs| {
            var int_buf: [32]u8 = undefined;
            buf.appendSlice(ctx.req_allocator, std.fmt.bufPrint(&int_buf, "{d}", .{lrs}) catch "0") catch {};
        } else {
            buf.appendSlice(ctx.req_allocator, "null") catch {};
        }
        buf.appendSlice(ctx.req_allocator, ",\"last_status\":") catch {};
        if (job.last_status) |ls| {
            appendJsonStringBuf(&buf, ctx.req_allocator, ls) catch {};
        } else {
            buf.appendSlice(ctx.req_allocator, "null") catch {};
        }
        buf.append(ctx.req_allocator, '}') catch {};
        ctx.response_status = "200 OK";
        ctx.response_body = buf.items;
    }
}

/// POST /cron/load-from-seed — restore jobs from ~/.nullclaw/cron-seed.json into the DB.
/// Seed is the source of truth; this is a one-way restore (seed → DB), never the reverse.
fn handleCronLoadFromSeed(ctx: *WebhookHandlerContext) void {
    if (!std.mem.eql(u8, ctx.method, "POST")) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }
    const home = @import("platform.zig").getHomeDir(ctx.req_allocator) catch {
        ctx.response_status = "500 Internal Server Error";
        ctx.response_body = "{\"error\":\"could not determine home dir\"}";
        return;
    };
    const script = std.fs.path.join(ctx.req_allocator, &.{ home, ".nullclaw", "restore-seed.sh" }) catch {
        ctx.response_status = "500 Internal Server Error";
        ctx.response_body = "{\"error\":\"out of memory\"}";
        return;
    };
    const result = std_compat.process.Child.run(.{
        .allocator = ctx.req_allocator,
        .argv = &.{ "/bin/bash", script },
        .max_output_bytes = 4096,
    }) catch |err| {
        std.log.scoped(.gateway).err("load-from-seed failed: {s}", .{@errorName(err)});
        ctx.response_status = "500 Internal Server Error";
        ctx.response_body = "{\"error\":\"restore script failed to run\"}";
        return;
    };
    defer ctx.req_allocator.free(result.stdout);
    defer ctx.req_allocator.free(result.stderr);
    const success = switch (result.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!success) {
        std.log.scoped(.gateway).err("load-from-seed script exited with error: {s}", .{result.stderr});
        ctx.response_status = "500 Internal Server Error";
        ctx.response_body = "{\"error\":\"restore script exited with error\"}";
        return;
    }
    ctx.response_body = "{\"status\":\"restored\"}";
}

/// Worker thread: dequeues job IDs from cron_run_queue (DB) and executes them one at a time.
/// Falls back to the legacy in-memory ArrayList when cron_db_path is not set.
fn runQueueWorker(state: *GatewayState) void {
    const cq_log = std.log.scoped(.cron_queue);

    // Crash recovery: reset any in_progress rows left by a previous crash.
    if (state.cron_db_backend) |*be| {
        be.backend().resetInProgress() catch |err|
            cq_log.warn("resetInProgress failed: {s}", .{@errorName(err)});
    } else if (state.cron_db_path) |db_path| {
        if (cron_mod.openCronDbAtPath(db_path)) |db| {
            defer cron_mod.closeCronDb(db);
            cron_mod.ensureRunQueueTable(db) catch {};
            cron_mod.dbResetInProgressJobs(db) catch |err|
                cq_log.warn("dbResetInProgressJobs failed: {s}", .{@errorName(err)});
        } else |err| {
            log.warn("worker startup: could not open DB for reset: {s}", .{@errorName(err)});
        }
    }

    while (true) {
        // Wait for a wake signal or stop.
        {
            state.run_queue_mutex.lock();
            defer state.run_queue_mutex.unlock();
            // When DB-direct: wake on signal or poll every second to drain any
            // rows enqueued by the scheduler thread (which signals the condvar).
            // When legacy: wait until there are items in the ArrayList.
            if (state.cron_db_path != null) {
                if (!state.run_queue_stop) {
                    // 1-second timeout so we don't miss rows if signal was lost.
                    state.run_queue_mutex.unlock();
                    std_compat.thread.sleep(1 * std.time.ns_per_s);
                    state.run_queue_mutex.lock();
                }
            } else {
                while (state.run_queue.items.len == 0 and !state.run_queue_stop) {
                    state.run_queue_cond.wait(&state.run_queue_mutex);
                }
            }
            if (state.run_queue_stop and state.run_queue.items.len == 0) return;
        }

        if (state.cron_db_backend != null or state.cron_db_path != null) {
            // ── CronBackend path ─────────────────────────────────────────────
            // Prefer the vtable backend (atomic dequeue). Fall back to the
            // raw DB path only if the backend wasn't initialized.
            var job_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer job_arena.deinit();
            const arena = job_arena.allocator();

            const dequeue_result: ?cron_backend_mod.DequeueResult = if (state.cron_db_backend) |*be|
                be.backend().dequeue(arena) catch |err| blk: {
                    log.err("worker: dequeue failed: {s}", .{@errorName(err)});
                    break :blk null;
                }
            else blk: {
                // Fallback: legacy separate claim + load (non-atomic).
                const db_path = state.cron_db_path.?;
                const db = cron_mod.openCronDbAtPath(db_path) catch |err| {
                    log.err("worker: could not open DB: {s}", .{@errorName(err)});
                    break :blk null;
                };
                defer cron_mod.closeCronDb(db);
                cron_mod.ensureRunQueueTable(db) catch {};
                const legacy_deq = cron_mod.dbDequeueNextJob(db, arena) catch break :blk null;
                const legacy_item = legacy_deq orelse break :blk null;
                const legacy_spec_opt = cron_mod.dbLoadJobSpec(db, arena, legacy_item.job_id) catch break :blk null;
                const legacy_spec = legacy_spec_opt orelse break :blk null;
                break :blk cron_backend_mod.DequeueResult{
                    .queue_row_id = legacy_item.queue_row_id,
                    .spec = cron_backend_mod.CronJobSpec{
                        .id = legacy_item.job_id,
                        .job_type = @enumFromInt(@intFromEnum(legacy_spec.job_type)),
                        .command = legacy_spec.command,
                        .prompt = legacy_spec.prompt,
                        .model = legacy_spec.model,
                        .skill_name = legacy_spec.skill_name,
                        .skill_args = legacy_spec.skill_args,
                        .one_shot = legacy_spec.one_shot,
                        .delete_after_run = legacy_spec.delete_after_run,
                        .timeout_secs = legacy_spec.timeout_secs,
                        .delivery = cron_backend_mod.DeliveryConfig{
                            .mode = @enumFromInt(@intFromEnum(legacy_spec.delivery.mode)),
                            .channel = legacy_spec.delivery.channel,
                            .account_id = legacy_spec.delivery.account_id,
                            .to = legacy_spec.delivery.to,
                            .best_effort = legacy_spec.delivery.best_effort,
                        },
                        .session_target = @enumFromInt(@intFromEnum(legacy_spec.session_target)),
                        .verification_mode = @enumFromInt(@intFromEnum(legacy_spec.verification_mode)),
                        .repair_policy = @enumFromInt(@intFromEnum(legacy_spec.repair_policy)),
                    },
                };
            };

            const dr = dequeue_result orelse continue;
            const spec = dr.spec;

            log.info("running queued job '{s}'", .{spec.id});
            const start_ts = std_compat.time.timestamp();
            const timeout: u64 = spec.timeout_secs orelse 0;

            // Convert delivery for deliverResult (same fields, different namespace).
            const delivery = cron_mod.DeliveryConfig{
                .mode = @enumFromInt(@intFromEnum(spec.delivery.mode)),
                .channel = spec.delivery.channel,
                .account_id = spec.delivery.account_id,
                .to = spec.delivery.to,
                .peer_kind = if (spec.delivery.peer_kind) |pk| @enumFromInt(@intFromEnum(pk)) else null,
                .peer_id = spec.delivery.peer_id,
                .thread_id = spec.delivery.thread_id,
                .best_effort = spec.delivery.best_effort,
            };

            const complete = struct {
                fn call(
                    be_opt: *?cron_db_mod.DbCronBackend,
                    db_path_opt: ?[:0]const u8,
                    job_id: []const u8,
                    row_id: i64,
                    ts: i64,
                    status_str: []const u8,
                    output_str: ?[]const u8,
                    dar: bool,
                    delivered: bool,
                    run_result_opt: ?cron_mod.RunResult,
                    trace_id: ?[]const u8,
                    source: ?[]const u8,
                ) void {
                    if (run_result_opt != null or trace_id != null) {
                        // Runs carrying observability data (classification or trace id) must
                        // bypass the vtable path because CronBackend.complete lacks both fields.
                        if (db_path_opt) |dp| {
                            const db2 = cron_mod.openCronDbAtPath(dp) catch return;
                            defer cron_mod.closeCronDb(db2);
                            cron_mod.dbCompleteJob(db2, job_id, row_id, ts, status_str, output_str, dar, run_result_opt, trace_id, false, source, null) catch {};
                        }
                    } else if (be_opt.*) |*be| {
                        be.backend().complete(job_id, row_id, ts, status_str, output_str, delivered) catch |e|
                            std.log.scoped(.cron_queue).err("[{s}] complete failed: {s}", .{ job_id, @errorName(e) });
                    } else if (db_path_opt) |dp| {
                        const db2 = cron_mod.openCronDbAtPath(dp) catch return;
                        defer cron_mod.closeCronDb(db2);
                        cron_mod.dbCompleteJob(db2, job_id, row_id, ts, status_str, output_str, dar, null, trace_id, false, source, null) catch {};
                    }
                }
            }.call;

            switch (spec.job_type) {
                .shell => {
                    const run_trace_id = cron_mod.makeRunTraceId(arena, spec.id, dr.queue_row_id) catch spec.id;
                    const resolved_cmd = cron_mod.resolveSkillCommand(arena, spec.command) catch null;
                    defer if (resolved_cmd) |rc| arena.free(rc);
                    const shell_cmd = resolved_cmd orelse spec.command;

                    switch (cron_mod.checkCronShellPolicy(state.security_policy, shell_cmd)) {
                        .allowed => {},
                        .blocked => |blocked| {
                            log.warn("[{s}] shell blocked by policy: {s}", .{ spec.id, @errorName(blocked.err) });
                            var bad_result = cron_mod.execErrorRunResult();
                            bad_result.failure_class = blocked.failure_class;
                            complete(&state.cron_db_backend, state.cron_db_path, spec.id, dr.queue_row_id, start_ts, "error", null, spec.delete_after_run, false, bad_result, run_trace_id, "cron_scheduler_shell");
                            continue;
                        },
                        .fail_closed => {
                            log.err("[{s}] security policy not available for shell job - failing closed", .{spec.id});
                            var bad_result = cron_mod.execErrorRunResult();
                            bad_result.failure_class = "policy_denied";
                            complete(&state.cron_db_backend, state.cron_db_path, spec.id, dr.queue_row_id, start_ts, "error", null, spec.delete_after_run, false, bad_result, run_trace_id, "cron_scheduler_shell");
                            continue;
                        },
                    }

                    var shell_env = cron_mod.buildCronChildEnv(arena, .{
                        .source = "cron_scheduler_shell",
                        .trace_id = run_trace_id,
                    }) catch |err| {
                        log.err("[{s}] env setup failed: {s}", .{ spec.id, @errorName(err) });
                        complete(&state.cron_db_backend, state.cron_db_path, spec.id, dr.queue_row_id, start_ts, "error", null, spec.delete_after_run, false, cron_mod.execErrorRunResult(), run_trace_id, "cron_scheduler_shell");
                        continue;
                    };
                    defer shell_env.deinit();
                    var shell_child = std_compat.process.Child.init(
                        &.{ @import("platform.zig").getShell(), @import("platform.zig").getShellFlag(), shell_cmd },
                        arena,
                    );
                    shell_child.stdin_behavior = .Ignore;
                    shell_child.stdout_behavior = .Pipe;
                    shell_child.stderr_behavior = .Pipe;
                    shell_child.cwd = state.cron_workspace_dir;
                    shell_child.env_map = &shell_env;
                    shell_child.spawn() catch |err| {
                        log.err("[{s}] exec failed: {s}", .{ spec.id, @errorName(err) });
                        complete(&state.cron_db_backend, state.cron_db_path, spec.id, dr.queue_row_id, start_ts, "error", null, spec.delete_after_run, false, cron_mod.execErrorRunResult(), run_trace_id, "cron_scheduler_shell");
                        continue;
                    };
                    errdefer {
                        _ = shell_child.kill() catch {};
                        _ = shell_child.wait() catch {};
                    }
                    const shell_start_ns = std_compat.time.nanoTimestamp();
                    var shell_stdout: std.ArrayList(u8) = .empty;
                    defer shell_stdout.deinit(arena);
                    var shell_stderr: std.ArrayList(u8) = .empty;
                    defer shell_stderr.deinit(arena);
                    const shell_timed_out = cron_mod.collectChildOutputWithTimeout(
                        &shell_child,
                        arena,
                        &shell_stdout,
                        &shell_stderr,
                        timeout,
                        shell_start_ns,
                    ) catch |err| {
                        log.err("[{s}] collect failed: {s}", .{ spec.id, @errorName(err) });
                        complete(&state.cron_db_backend, state.cron_db_path, spec.id, dr.queue_row_id, start_ts, "error", null, spec.delete_after_run, false, cron_mod.execErrorRunResult(), run_trace_id, "cron_scheduler_shell");
                        continue;
                    };
                    const shell_term = shell_child.wait() catch |err| {
                        log.err("[{s}] wait failed: {s}", .{ spec.id, @errorName(err) });
                        complete(&state.cron_db_backend, state.cron_db_path, spec.id, dr.queue_row_id, start_ts, "error", null, spec.delete_after_run, false, cron_mod.execErrorRunResult(), run_trace_id, "cron_scheduler_shell");
                        continue;
                    };
                    if (shell_timed_out) log.warn("[{s}] timed out after {d}s", .{ spec.id, timeout });
                    var current_exit_code: u8 = switch (shell_term) {
                        .exited => |ec| ec,
                        else => 1,
                    };
                    var current_timed_out = shell_timed_out;
                    var run_result = cron_mod.classifyExecRun(current_exit_code, current_timed_out);
                    var retry_count: u8 = 0;
                    while (cron_mod.shouldRetryOnce(spec, run_result, retry_count)) {
                        retry_count += 1;
                        const saved_failure_class = run_result.failure_class;
                        log.info("[{s}] shell retry 1 (failure_class={s})", .{ spec.id, saved_failure_class orelse "?" });
                        var retry_child = std_compat.process.Child.init(
                            &.{ @import("platform.zig").getShell(), @import("platform.zig").getShellFlag(), shell_cmd },
                            arena,
                        );
                        retry_child.stdin_behavior = .Ignore;
                        retry_child.stdout_behavior = .Pipe;
                        retry_child.stderr_behavior = .Pipe;
                        retry_child.cwd = state.cron_workspace_dir;
                        retry_child.env_map = &shell_env;
                        retry_child.spawn() catch |err| {
                            log.err("[{s}] shell retry spawn failed: {s}", .{ spec.id, @errorName(err) });
                            break;
                        };
                        var retry_stdout: std.ArrayList(u8) = .empty;
                        defer retry_stdout.deinit(arena);
                        var retry_stderr: std.ArrayList(u8) = .empty;
                        defer retry_stderr.deinit(arena);
                        const retry_start_ns = std_compat.time.nanoTimestamp();
                        const retry_timed_out = cron_mod.collectChildOutputWithTimeout(
                            &retry_child,
                            arena,
                            &retry_stdout,
                            &retry_stderr,
                            timeout,
                            retry_start_ns,
                        ) catch false;
                        const retry_term = retry_child.wait() catch break;
                        current_exit_code = switch (retry_term) {
                            .exited => |ec| ec,
                            else => 1,
                        };
                        current_timed_out = retry_timed_out;
                        run_result = cron_mod.classifyExecRun(current_exit_code, current_timed_out);
                        cron_mod.applyRetryOutcome(&run_result, saved_failure_class);
                        if (retry_stdout.items.len > 0) {
                            shell_stdout.clearAndFree(arena);
                            shell_stdout.appendSlice(arena, retry_stdout.items) catch {};
                        }
                        if (retry_stderr.items.len > 0) {
                            shell_stderr.clearAndFree(arena);
                            shell_stderr.appendSlice(arena, retry_stderr.items) catch {};
                        }
                    }
                    if (cron_mod.shouldPauseOnHardFailure(spec, run_result)) {
                        if (pauseCronJobForRepair(state, spec.id)) {
                            run_result.repair_action = "paused_job";
                        } else {
                            log.warn("[{s}] failed to pause job after hard failure", .{spec.id});
                        }
                    } else if (spec.repair_policy == .alert_only and run_result.verified != 1) {
                        run_result.repair_action = "alert_sent";
                    }
                    const success = !current_timed_out and current_exit_code == 0;
                    const raw_output = if (shell_stdout.items.len > 0) shell_stdout.items else shell_stderr.items;
                    const output = std.fmt.allocPrint(arena, "{s}\n\n`{s}`", .{ raw_output, spec.id }) catch raw_output;
                    var delivered = false;
                    if (state.event_bus) |eb| {
                        delivered = cron_mod.deliverResult(state.allocator, delivery, output, success, eb) catch |err| blk: {
                            log.err("[{s}] delivery failed: {s}", .{ spec.id, @errorName(err) });
                            break :blk false;
                        };
                        if (!delivered and raw_output.len > 0 and delivery.mode != .none and delivery.channel != null) {
                            log.warn("[{s}] output not delivered (len={d})", .{ spec.id, output.len });
                        }
                    }
                    const status = if (success) "ok" else "error";
                    complete(&state.cron_db_backend, state.cron_db_path, spec.id, dr.queue_row_id, std_compat.time.timestamp(), status, if (raw_output.len > 0) raw_output else null, spec.delete_after_run, delivered, run_result, run_trace_id, "cron_scheduler_shell");
                    if (spec.repair_policy == .alert_only and run_result.verified != 1) {
                        const preview = if (raw_output.len > 0)
                            raw_output[0..@min(raw_output.len, 200)]
                        else
                            "no output";
                        sendCronRepairAlert(state, arena, spec, "shell", run_result, run_trace_id, preview);
                    }
                    log.info("[{s}] completed ({s})", .{ spec.id, status });
                },
                .agent => {
                    const run_trace_id = cron_mod.makeRunTraceId(arena, spec.id, dr.queue_row_id) catch spec.id;
                    const raw_p = spec.prompt orelse spec.command;
                    const resolved_p = cron_mod.resolveSkillPrompt(arena, raw_p) catch null;
                    defer if (resolved_p) |rp| arena.free(rp);
                    const p = resolved_p orelse raw_p;
                    const agent_result = cron_mod.runAgentJob(arena, state.cron_workspace_dir, p, spec.model, timeout, .{
                        .source = "cron_scheduler_agent",
                        .trace_id = run_trace_id,
                    }) catch |err| {
                        log.err("[{s}] agent failed: {s}", .{ spec.id, @errorName(err) });
                        complete(&state.cron_db_backend, state.cron_db_path, spec.id, dr.queue_row_id, start_ts, "error", null, spec.delete_after_run, false, cron_mod.execErrorRunResult(), run_trace_id, "cron_scheduler_agent");
                        continue;
                    };
                    var raw_agent = agent_result.output;
                    var current_exit_code = agent_result.exit_code;
                    var current_timed_out = agent_result.timed_out;
                    var run_result = cron_mod.classifyExecRun(current_exit_code, current_timed_out);
                    var retry_count: u8 = 0;
                    while (cron_mod.shouldRetryOnce(spec, run_result, retry_count)) {
                        retry_count += 1;
                        const saved_failure_class = run_result.failure_class;
                        log.info("[{s}] agent retry 1 (failure_class={s})", .{ spec.id, saved_failure_class orelse "?" });
                        const retry_result = cron_mod.runAgentJob(arena, state.cron_workspace_dir, p, spec.model, timeout, .{
                            .source = "cron_scheduler_agent",
                            .trace_id = run_trace_id,
                        }) catch |err| {
                            log.err("[{s}] agent retry failed: {s}", .{ spec.id, @errorName(err) });
                            break;
                        };
                        raw_agent = retry_result.output;
                        current_exit_code = retry_result.exit_code;
                        current_timed_out = retry_result.timed_out;
                        run_result = cron_mod.classifyExecRun(current_exit_code, current_timed_out);
                        cron_mod.applyRetryOutcome(&run_result, saved_failure_class);
                    }
                    if (cron_mod.shouldPauseOnHardFailure(spec, run_result)) {
                        if (pauseCronJobForRepair(state, spec.id)) {
                            run_result.repair_action = "paused_job";
                        } else {
                            log.warn("[{s}] failed to pause job after hard failure", .{spec.id});
                        }
                    } else if (spec.repair_policy == .alert_only and run_result.verified != 1) {
                        run_result.repair_action = "alert_sent";
                    }
                    const success = !current_timed_out and current_exit_code == 0;
                    const agent_output = std.fmt.allocPrint(arena, "{s}\n\n`{s}`", .{ raw_agent, spec.id }) catch raw_agent;
                    var delivered = false;
                    if (state.event_bus) |eb| {
                        const job_name = spec.id;
                        const session_target: cron_mod.SessionTarget = @enumFromInt(@intFromEnum(spec.session_target));
                        delivered = if (session_target == .main)
                            cron_mod.deliverViaMainAgent(state.allocator, delivery, agent_output, success, eb, job_name) catch |err| blk: {
                                log.err("[{s}] main-session delivery failed: {s}", .{ spec.id, @errorName(err) });
                                break :blk false;
                            }
                        else
                            cron_mod.deliverResult(state.allocator, delivery, agent_output, success, eb) catch |err| blk: {
                                log.err("[{s}] delivery failed: {s}", .{ spec.id, @errorName(err) });
                                break :blk false;
                            };
                        if (!delivered and raw_agent.len > 0 and delivery.mode != .none and delivery.channel != null) {
                            log.warn("[{s}] output not delivered (len={d})", .{ spec.id, agent_output.len });
                        }
                    }
                    const status = if (success) "ok" else "error";
                    complete(&state.cron_db_backend, state.cron_db_path, spec.id, dr.queue_row_id, std_compat.time.timestamp(), status, if (raw_agent.len > 0) raw_agent else null, spec.delete_after_run, delivered, run_result, run_trace_id, "cron_scheduler_agent");
                    if (spec.repair_policy == .alert_only and run_result.verified != 1) {
                        const preview = if (raw_agent.len > 0)
                            raw_agent[0..@min(raw_agent.len, 200)]
                        else
                            "no output";
                        sendCronRepairAlert(state, arena, spec, "agent", run_result, run_trace_id, preview);
                    }
                    log.info("[{s}] completed ({s})", .{ spec.id, status });
                },
                .skill => {
                    // Skill jobs own their entire workflow including delivery.
                    // Cron only triggers and records status.
                    // For failure alerts: prefer the job's own delivery config (so --deliver-to
                    // jobs get error notifications without requiring a global alert destination),
                    // then fall back to the global alert_delivery, then a no-op empty config.
                    const job_del = cron_mod.DeliveryConfig{
                        .mode = @enumFromInt(@intFromEnum(spec.delivery.mode)),
                        .channel = spec.delivery.channel,
                        .account_id = spec.delivery.account_id,
                        .to = spec.delivery.to,
                        .best_effort = true, // errors are best-effort notifications
                    };
                    const alert_del = if (spec.delivery.mode != .none)
                        job_del
                    else
                        state.alert_delivery orelse cron_mod.DeliveryConfig{};
                    // Per-run trace ID: job_id:queue_row_id (unique per execution).
                    const run_trace_id = cron_mod.makeRunTraceId(arena, spec.id, dr.queue_row_id) catch spec.id;
                    defer if (run_trace_id.ptr != spec.id.ptr) arena.free(run_trace_id);
                    const raw_skill_cmd = cron_mod.resolveSkillExec(arena, spec.skill_name, spec.skill_args) catch |err| {
                        log.err("[{s}] skill resolution failed: {s}", .{ spec.id, @errorName(err) });
                        complete(&state.cron_db_backend, state.cron_db_path, spec.id, dr.queue_row_id, start_ts, "error", null, spec.delete_after_run, false, cron_mod.execErrorRunResult(), run_trace_id, "cron_scheduler_skill");
                        if (state.event_bus) |eb| {
                            const em = std.fmt.allocPrint(arena, "[cron] skill '{s}' resolution failed: {s} trace={s}", .{ spec.skill_name orelse "?", @errorName(err), run_trace_id }) catch null;
                            if (em) |msg| _ = cron_mod.deliverResult(arena, alert_del, msg, false, eb) catch {};
                        }
                        continue;
                    };
                    defer arena.free(raw_skill_cmd);
                    const skill_cmd = raw_skill_cmd;
                    var skill_env = cron_mod.buildCronChildEnv(arena, .{
                        .source = "cron_scheduler_skill",
                        .trace_id = run_trace_id,
                    }) catch |err| {
                        log.err("[{s}] skill env setup failed: {s}", .{ spec.id, @errorName(err) });
                        complete(&state.cron_db_backend, state.cron_db_path, spec.id, dr.queue_row_id, start_ts, "error", null, spec.delete_after_run, false, cron_mod.execErrorRunResult(), run_trace_id, "cron_scheduler_skill");
                        continue;
                    };
                    defer skill_env.deinit();
                    var skill_child = std_compat.process.Child.init(
                        &.{ @import("platform.zig").getShell(), @import("platform.zig").getShellFlag(), skill_cmd },
                        arena,
                    );
                    skill_child.stdin_behavior = .Ignore;
                    skill_child.stdout_behavior = .Pipe;
                    skill_child.stderr_behavior = .Pipe;
                    skill_child.cwd = state.cron_workspace_dir;
                    skill_child.env_map = &skill_env;
                    skill_child.spawn() catch |err| {
                        log.err("[{s}] skill exec failed: {s}", .{ spec.id, @errorName(err) });
                        complete(&state.cron_db_backend, state.cron_db_path, spec.id, dr.queue_row_id, start_ts, "error", null, spec.delete_after_run, false, cron_mod.execErrorRunResult(), run_trace_id, "cron_scheduler_skill");
                        if (state.event_bus) |eb| {
                            const em = std.fmt.allocPrint(arena, "[cron] skill '{s}' failed to start: {s} trace={s}", .{ spec.skill_name orelse "?", @errorName(err), run_trace_id }) catch null;
                            if (em) |msg| _ = cron_mod.deliverResult(arena, alert_del, msg, false, eb) catch {};
                        }
                        continue;
                    };
                    errdefer {
                        _ = skill_child.kill() catch {};
                        _ = skill_child.wait() catch {};
                    }
                    const skill_start_ns = std_compat.time.nanoTimestamp();
                    var skill_stdout: std.ArrayList(u8) = .empty;
                    defer skill_stdout.deinit(arena);
                    var skill_stderr: std.ArrayList(u8) = .empty;
                    defer skill_stderr.deinit(arena);
                    const skill_timed_out = cron_mod.collectChildOutputWithTimeout(
                        &skill_child,
                        arena,
                        &skill_stdout,
                        &skill_stderr,
                        timeout,
                        skill_start_ns,
                    ) catch |err| {
                        log.err("[{s}] skill collect failed: {s}", .{ spec.id, @errorName(err) });
                        complete(&state.cron_db_backend, state.cron_db_path, spec.id, dr.queue_row_id, start_ts, "error", null, spec.delete_after_run, false, cron_mod.execErrorRunResult(), run_trace_id, "cron_scheduler_skill");
                        if (state.event_bus) |eb| {
                            const em = std.fmt.allocPrint(arena, "[cron] skill '{s}' output collection failed: {s} trace={s}", .{ spec.skill_name orelse "?", @errorName(err), run_trace_id }) catch null;
                            if (em) |msg| _ = cron_mod.deliverResult(arena, alert_del, msg, false, eb) catch {};
                        }
                        continue;
                    };
                    const skill_term = skill_child.wait() catch |err| {
                        log.err("[{s}] skill wait failed: {s}", .{ spec.id, @errorName(err) });
                        complete(&state.cron_db_backend, state.cron_db_path, spec.id, dr.queue_row_id, start_ts, "error", null, spec.delete_after_run, false, cron_mod.execErrorRunResult(), run_trace_id, "cron_scheduler_skill");
                        if (state.event_bus) |eb| {
                            const em = std.fmt.allocPrint(arena, "[cron] skill '{s}' wait failed: {s} trace={s}", .{ spec.skill_name orelse "?", @errorName(err), run_trace_id }) catch null;
                            if (em) |msg| _ = cron_mod.deliverResult(arena, alert_del, msg, false, eb) catch {};
                        }
                        continue;
                    };
                    if (skill_timed_out) log.warn("[{s}] skill timed out after {d}s", .{ spec.id, timeout });
                    const skill_exit: u8 = switch (skill_term) {
                        .exited => |ec| ec,
                        else => 1,
                    };
                    var run_result = cron_mod.classifySkillRun(spec, skill_stdout.items, skill_exit, skill_timed_out, run_trace_id);
                    var retry_count: u8 = 0;
                    while (run_result.verified != 1 and spec.repair_policy == .retry_once and retry_count == 0) {
                        retry_count += 1;
                        const saved_failure_class = run_result.failure_class;
                        log.info("[{s}] skill retry 1 (failure_class={s})", .{ spec.id, saved_failure_class orelse "?" });
                        var retry_stdout: std.ArrayList(u8) = .empty;
                        defer retry_stdout.deinit(arena);
                        var retry_stderr: std.ArrayList(u8) = .empty;
                        defer retry_stderr.deinit(arena);
                        var retry_child = std_compat.process.Child.init(
                            &.{ @import("platform.zig").getShell(), @import("platform.zig").getShellFlag(), skill_cmd },
                            arena,
                        );
                        retry_child.stdin_behavior = .Ignore;
                        retry_child.stdout_behavior = .Pipe;
                        retry_child.stderr_behavior = .Pipe;
                        retry_child.cwd = state.cron_workspace_dir;
                        retry_child.env_map = &skill_env;
                        retry_child.spawn() catch |err| {
                            log.err("[{s}] skill retry spawn failed: {s}", .{ spec.id, @errorName(err) });
                            break;
                        };
                        const retry_start_ns = std_compat.time.nanoTimestamp();
                        const retry_timed_out = cron_mod.collectChildOutputWithTimeout(
                            &retry_child,
                            arena,
                            &retry_stdout,
                            &retry_stderr,
                            timeout,
                            retry_start_ns,
                        ) catch false;
                        const retry_term = retry_child.wait() catch break;
                        const retry_exit: u8 = switch (retry_term) {
                            .exited => |ec| ec,
                            else => 1,
                        };
                        run_result = cron_mod.classifySkillRun(spec, retry_stdout.items, retry_exit, retry_timed_out, run_trace_id);
                        run_result.repair_action = if (run_result.verified == 1) "retried_ok" else "retried_failed";
                        if (run_result.failure_class == null) run_result.failure_class = saved_failure_class;
                        // Use retry output for logging/recording if non-empty.
                        if (retry_stdout.items.len > 0) {
                            skill_stdout.clearAndFree(arena);
                            skill_stdout.appendSlice(arena, retry_stdout.items) catch {};
                        }
                        if (retry_stderr.items.len > 0) {
                            skill_stderr.clearAndFree(arena);
                            skill_stderr.appendSlice(arena, retry_stderr.items) catch {};
                        }
                    }
                    if (cron_mod.shouldPauseOnHardFailure(spec, run_result)) {
                        if (pauseCronJobForRepair(state, spec.id)) {
                            run_result.repair_action = "paused_job";
                        } else {
                            log.warn("[{s}] failed to pause job after hard failure", .{spec.id});
                        }
                    } else if (spec.repair_policy == .alert_only and run_result.verified != 1)
                        run_result.repair_action = "alert_sent";
                    const skill_ok = run_result.verified == 1;
                    const skill_output = if (skill_stdout.items.len > 0) skill_stdout.items else skill_stderr.items;
                    const skill_status = if (skill_ok) "ok" else "error";
                    // Skills self-deliver — no cron delivery needed.
                    complete(&state.cron_db_backend, state.cron_db_path, spec.id, dr.queue_row_id, std_compat.time.timestamp(), skill_status, if (skill_output.len > 0) skill_output else null, spec.delete_after_run, false, run_result, run_trace_id, "cron_scheduler_skill");
                    // Alert operator on hard failure (verified=3) or degraded content (verified=2).
                    if (run_result.verified != 1) {
                        if (state.event_bus) |eb| {
                            const stderr_preview = if (skill_stderr.items.len > 0)
                                skill_stderr.items[0..@min(skill_stderr.items.len, 200)]
                            else
                                "no stderr";
                            const fc = run_result.failure_class orelse "unknown";
                            const ra = run_result.repair_action orelse "none";
                            const em = std.fmt.allocPrint(
                                arena,
                                "[cron] skill '{s}' degraded: failure={s} repair={s} trace={s}\n{s}",
                                .{ spec.skill_name orelse "?", fc, ra, run_trace_id, stderr_preview },
                            ) catch null;
                            if (em) |msg| _ = cron_mod.deliverResult(arena, alert_del, msg, false, eb) catch {};
                        }
                    }
                    // Log status with first line of output for delivery observability.
                    // Stdout is typically a delivery confirmation; stderr is errors.
                    // Use stderr for failures (more diagnostic), stdout for success.
                    const log_output = if (!skill_ok and skill_stderr.items.len > 0)
                        skill_stderr.items
                    else
                        skill_stdout.items;
                    if (log_output.len > 0) {
                        const nl = std.mem.indexOfScalar(u8, log_output, '\n') orelse log_output.len;
                        log.info("[{s}] skill completed ({s}, verified={d}): {s}", .{ spec.id, skill_status, run_result.verified, log_output[0..@min(nl, 120)] });
                    } else {
                        log.info("[{s}] skill completed ({s}, verified={d}): (no output)", .{ spec.id, skill_status, run_result.verified });
                    }
                },
            }
        } else {
            // ── Legacy in-memory path (no cron_db_path set) ─────────────────
            const id: []const u8 = blk: {
                state.run_queue_mutex.lock();
                defer state.run_queue_mutex.unlock();
                if (state.run_queue.items.len == 0) continue;
                break :blk state.run_queue.orderedRemove(0);
            };
            defer state.allocator.free(id);

            var job_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer job_arena.deinit();
            const allocator = job_arena.allocator();

            log.info("running queued job '{s}' (legacy)", .{id});

            const sched = s: {
                state.scheduler_mutex.lock();
                defer state.scheduler_mutex.unlock();
                break :s state.scheduler orelse {
                    log.warn("scheduler not running, dropping job '{s}'", .{id});
                    continue;
                };
            };

            const job_type, const command, const prompt, const model, const delivery, const run_cwd, const skill_name_leg, const skill_args_leg = j: {
                state.scheduler_mutex.lock();
                defer state.scheduler_mutex.unlock();
                const job = sched.getMutableJob(id) orelse {
                    log.warn("job '{s}' not found in scheduler", .{id});
                    continue;
                };
                const cwd: ?[]const u8 = if (sched.shell_cwd) |cwd| blk: {
                    std_compat.fs.accessAbsolute(cwd, .{}) catch break :blk null;
                    break :blk cwd;
                } else null;
                const owned_command = allocator.dupe(u8, job.command) catch job.command;
                const owned_prompt = if (job.prompt) |p| allocator.dupe(u8, p) catch p else null;
                const owned_model = if (job.model) |m| allocator.dupe(u8, m) catch m else null;
                const owned_sn: ?[]const u8 = if (job.skill_name) |sn| allocator.dupe(u8, sn) catch sn else null;
                const owned_sa: ?[]const u8 = if (job.skill_args) |sa| allocator.dupe(u8, sa) catch sa else null;
                var owned_delivery = job.delivery;
                owned_delivery.channel_owned = false;
                owned_delivery.account_id_owned = false;
                owned_delivery.to_owned = false;
                if (job.delivery.channel) |ch| owned_delivery.channel = allocator.dupe(u8, ch) catch ch;
                if (job.delivery.account_id) |aid| owned_delivery.account_id = allocator.dupe(u8, aid) catch aid;
                if (job.delivery.to) |t| owned_delivery.to = allocator.dupe(u8, t) catch t;
                break :j .{ job.job_type, owned_command, owned_prompt, owned_model, owned_delivery, cwd, owned_sn, owned_sa };
            };

            const now = std_compat.time.timestamp();
            const job_timeout_secs, const is_agent = s2: {
                state.scheduler_mutex.lock();
                defer state.scheduler_mutex.unlock();
                const jt = if (sched.getMutableJob(id)) |j| j.timeout_secs else null;
                const is_ag = if (sched.getMutableJob(id)) |j| j.job_type == .agent else false;
                break :s2 .{ jt, is_ag };
            };
            const timeout: u64 = if (job_timeout_secs) |t| t else if (is_agent) sched.agent_timeout_secs else 0;

            switch (job_type) {
                .shell => {
                    switch (cron_mod.checkCronShellPolicy(state.security_policy, command)) {
                        .allowed => {},
                        .blocked => |blocked| {
                            log.warn("legacy queued shell job '{s}' blocked by policy: {s}", .{ id, @errorName(blocked.err) });
                            state.scheduler_mutex.lock();
                            if (sched.getMutableJob(id)) |j| {
                                j.last_run_secs = now;
                                j.last_status = "error";
                                _ = cron_mod.dbUpsertAndVerify(sched, j) catch {};
                            }
                            state.scheduler_mutex.unlock();
                            continue;
                        },
                        .fail_closed => {
                            log.err("security policy not available for legacy queued shell job '{s}' - failing closed", .{id});
                            state.scheduler_mutex.lock();
                            if (sched.getMutableJob(id)) |j| {
                                j.last_run_secs = now;
                                j.last_status = "error";
                                _ = cron_mod.dbUpsertAndVerify(sched, j) catch {};
                            }
                            state.scheduler_mutex.unlock();
                            continue;
                        },
                    }

                    var shell_env = cron_mod.buildCronChildEnv(allocator, .{
                        .source = "cron_legacy_scheduler_shell",
                    }) catch |err| {
                        log.err("job '{s}' env setup failed: {s}", .{ id, @errorName(err) });
                        state.scheduler_mutex.lock();
                        if (sched.getMutableJob(id)) |j| {
                            j.last_run_secs = now;
                            j.last_status = "error";
                        }
                        state.scheduler_mutex.unlock();
                        _ = cron_mod.dbUpsertAndVerify(sched, sched.getJob(id) orelse continue) catch {};
                        continue;
                    };
                    defer shell_env.deinit();
                    var shell_child = std_compat.process.Child.init(
                        &.{ @import("platform.zig").getShell(), @import("platform.zig").getShellFlag(), command },
                        allocator,
                    );
                    shell_child.stdin_behavior = .Ignore;
                    shell_child.stdout_behavior = .Pipe;
                    shell_child.stderr_behavior = .Pipe;
                    shell_child.cwd = run_cwd;
                    shell_child.env_map = &shell_env;
                    shell_child.spawn() catch |err| {
                        log.err("job '{s}' exec failed: {s}", .{ id, @errorName(err) });
                        state.scheduler_mutex.lock();
                        if (sched.getMutableJob(id)) |j| {
                            j.last_run_secs = now;
                            j.last_status = "error";
                        }
                        state.scheduler_mutex.unlock();
                        _ = cron_mod.dbUpsertAndVerify(sched, sched.getJob(id) orelse continue) catch {};
                        continue;
                    };
                    errdefer {
                        _ = shell_child.kill() catch {};
                        _ = shell_child.wait() catch {};
                    }
                    const shell_start_ns = std_compat.time.nanoTimestamp();
                    var shell_stdout: std.ArrayList(u8) = .empty;
                    defer shell_stdout.deinit(allocator);
                    var shell_stderr: std.ArrayList(u8) = .empty;
                    defer shell_stderr.deinit(allocator);
                    const shell_timed_out = cron_mod.collectChildOutputWithTimeout(
                        &shell_child,
                        allocator,
                        &shell_stdout,
                        &shell_stderr,
                        timeout,
                        shell_start_ns,
                    ) catch |err| {
                        log.err("job '{s}' collect failed: {s}", .{ id, @errorName(err) });
                        state.scheduler_mutex.lock();
                        if (sched.getMutableJob(id)) |j| {
                            j.last_run_secs = now;
                            j.last_status = "error";
                        }
                        state.scheduler_mutex.unlock();
                        _ = cron_mod.dbUpsertAndVerify(sched, sched.getJob(id) orelse continue) catch {};
                        continue;
                    };
                    const shell_term = shell_child.wait() catch |err| {
                        log.err("job '{s}' wait failed: {s}", .{ id, @errorName(err) });
                        state.scheduler_mutex.lock();
                        if (sched.getMutableJob(id)) |j| {
                            j.last_run_secs = now;
                            j.last_status = "error";
                        }
                        state.scheduler_mutex.unlock();
                        _ = cron_mod.dbUpsertAndVerify(sched, sched.getJob(id) orelse continue) catch {};
                        continue;
                    };
                    if (shell_timed_out) log.warn("job '{s}' shell command timed out after {d}s", .{ id, timeout });
                    const exit_code: u8 = switch (shell_term) {
                        .exited => |ec| ec,
                        else => 1,
                    };
                    const success = !shell_timed_out and exit_code == 0;
                    const raw_output = if (shell_stdout.items.len > 0) shell_stdout.items else shell_stderr.items;
                    const output = std.fmt.allocPrint(allocator, "{s}\n\n`{s}`", .{ raw_output, id }) catch raw_output;
                    defer if (output.ptr != raw_output.ptr) allocator.free(output);
                    {
                        state.scheduler_mutex.lock();
                        if (sched.getMutableJob(id)) |j| {
                            j.last_run_secs = now;
                            j.last_status = if (success) "ok" else "error";
                            if (j.last_output) |old| sched.allocator.free(old);
                            j.last_output = if (raw_output.len > 0) sched.allocator.dupe(u8, raw_output) catch null else null;
                        }
                        state.scheduler_mutex.unlock();
                    }
                    if (state.event_bus) |eb| {
                        const delivered = cron_mod.deliverResult(state.allocator, delivery, output, success, eb) catch |err| blk: {
                            log.err("[{s}] delivery failed: {s}", .{ id, @errorName(err) });
                            break :blk false;
                        };
                        if (!delivered and raw_output.len > 0 and delivery.mode != .none and delivery.channel != null) {
                            log.warn("[{s}] output not delivered (len={d}): {s}...", .{ id, output.len, output[0..@min(200, output.len)] });
                        }
                    }
                    _ = cron_mod.dbUpsertAndVerify(sched, sched.getJob(id) orelse {
                        log.info("[{s}] completed ({s})", .{ id, if (success) "ok" else "error" });
                        continue;
                    }) catch |err| log.err("[{s}] db persist failed: {s}", .{ id, @errorName(err) });
                    log.info("[{s}] completed ({s})", .{ id, if (success) "ok" else "error" });
                },
                .agent => {
                    const p = prompt orelse command;
                    const agent_result = cron_mod.runAgentJob(allocator, run_cwd, p, model, timeout, .{
                        .source = "cron_legacy_scheduler_agent",
                    }) catch |err| {
                        log.err("[{s}] agent failed: {s}", .{ id, @errorName(err) });
                        state.scheduler_mutex.lock();
                        if (sched.getMutableJob(id)) |j| {
                            j.last_run_secs = now;
                            j.last_status = "error";
                        }
                        state.scheduler_mutex.unlock();
                        _ = cron_mod.dbUpsertAndVerify(sched, sched.getJob(id) orelse continue) catch {};
                        continue;
                    };
                    defer allocator.free(agent_result.output);
                    const raw_agent = agent_result.output;
                    const agent_output = std.fmt.allocPrint(allocator, "{s}\n\n`{s}`", .{ raw_agent, id }) catch raw_agent;
                    defer if (agent_output.ptr != raw_agent.ptr) allocator.free(agent_output);
                    {
                        state.scheduler_mutex.lock();
                        if (sched.getMutableJob(id)) |j| {
                            j.last_run_secs = now;
                            j.last_status = if (agent_result.success) "ok" else "error";
                            if (j.last_output) |old| sched.allocator.free(old);
                            j.last_output = if (raw_agent.len > 0) sched.allocator.dupe(u8, raw_agent) catch null else null;
                        }
                        state.scheduler_mutex.unlock();
                    }
                    if (state.event_bus) |eb| {
                        const delivered = cron_mod.deliverResult(state.allocator, delivery, agent_output, agent_result.success, eb) catch |err| blk: {
                            log.err("[{s}] delivery failed: {s}", .{ id, @errorName(err) });
                            break :blk false;
                        };
                        if (!delivered and raw_agent.len > 0 and delivery.mode != .none and delivery.channel != null) {
                            log.warn("[{s}] output not delivered (len={d}): {s}...", .{ id, agent_output.len, agent_output[0..@min(200, agent_output.len)] });
                        }
                    }
                    _ = cron_mod.dbUpsertAndVerify(sched, sched.getJob(id) orelse {
                        log.info("[{s}] completed ({s})", .{ id, if (agent_result.success) "ok" else "error" });
                        continue;
                    }) catch |err| log.err("[{s}] db persist failed: {s}", .{ id, @errorName(err) });
                    log.info("[{s}] completed ({s})", .{ id, if (agent_result.success) "ok" else "error" });
                },
                .skill => {
                    // Skill jobs: resolve via SKILL.md and run as subprocess.
                    const raw_skill_cmd = cron_mod.resolveSkillExec(allocator, skill_name_leg, skill_args_leg) catch |err| {
                        log.err("[{s}] skill resolution failed: {s}", .{ id, @errorName(err) });
                        state.scheduler_mutex.lock();
                        if (sched.getMutableJob(id)) |j| {
                            j.last_run_secs = now;
                            j.last_status = "error";
                        }
                        state.scheduler_mutex.unlock();
                        _ = cron_mod.dbUpsertAndVerify(sched, sched.getJob(id) orelse continue) catch {};
                        continue;
                    };
                    defer allocator.free(raw_skill_cmd);
                    // Per-run trace ID: job_id:timestamp (unique per execution in legacy path).
                    const legacy_trace_id = std.fmt.allocPrint(allocator, "{s}:{d}", .{ id, now }) catch id;
                    defer if (legacy_trace_id.ptr != id.ptr) allocator.free(legacy_trace_id);
                    const skill_cmd = raw_skill_cmd;
                    var skill_env = cron_mod.buildCronChildEnv(allocator, .{
                        .source = "cron_legacy_scheduler_skill",
                        .trace_id = legacy_trace_id,
                    }) catch |err| {
                        log.err("[{s}] skill env setup failed: {s}", .{ id, @errorName(err) });
                        state.scheduler_mutex.lock();
                        if (sched.getMutableJob(id)) |j| {
                            j.last_run_secs = now;
                            j.last_status = "error";
                        }
                        state.scheduler_mutex.unlock();
                        _ = cron_mod.dbUpsertAndVerify(sched, sched.getJob(id) orelse continue) catch {};
                        continue;
                    };
                    defer skill_env.deinit();
                    var skill_child = std_compat.process.Child.init(
                        &.{ @import("platform.zig").getShell(), @import("platform.zig").getShellFlag(), skill_cmd },
                        allocator,
                    );
                    skill_child.stdin_behavior = .Ignore;
                    skill_child.stdout_behavior = .Pipe;
                    skill_child.stderr_behavior = .Pipe;
                    skill_child.cwd = run_cwd;
                    skill_child.env_map = &skill_env;
                    skill_child.spawn() catch |err| {
                        log.err("[{s}] skill exec failed: {s}", .{ id, @errorName(err) });
                        state.scheduler_mutex.lock();
                        if (sched.getMutableJob(id)) |j| {
                            j.last_run_secs = now;
                            j.last_status = "error";
                        }
                        state.scheduler_mutex.unlock();
                        _ = cron_mod.dbUpsertAndVerify(sched, sched.getJob(id) orelse continue) catch {};
                        continue;
                    };
                    errdefer {
                        _ = skill_child.kill() catch {};
                        _ = skill_child.wait() catch {};
                    }
                    const skill_start_ns = std_compat.time.nanoTimestamp();
                    var skill_stdout: std.ArrayList(u8) = .empty;
                    defer skill_stdout.deinit(allocator);
                    var skill_stderr: std.ArrayList(u8) = .empty;
                    defer skill_stderr.deinit(allocator);
                    const skill_timed_out = cron_mod.collectChildOutputWithTimeout(
                        &skill_child,
                        allocator,
                        &skill_stdout,
                        &skill_stderr,
                        timeout,
                        skill_start_ns,
                    ) catch |err| {
                        log.err("[{s}] skill collect failed: {s}", .{ id, @errorName(err) });
                        state.scheduler_mutex.lock();
                        if (sched.getMutableJob(id)) |j| {
                            j.last_run_secs = now;
                            j.last_status = "error";
                        }
                        state.scheduler_mutex.unlock();
                        _ = cron_mod.dbUpsertAndVerify(sched, sched.getJob(id) orelse continue) catch {};
                        continue;
                    };
                    const skill_term = skill_child.wait() catch |err| {
                        log.err("[{s}] skill wait failed: {s}", .{ id, @errorName(err) });
                        state.scheduler_mutex.lock();
                        if (sched.getMutableJob(id)) |j| {
                            j.last_run_secs = now;
                            j.last_status = "error";
                        }
                        state.scheduler_mutex.unlock();
                        _ = cron_mod.dbUpsertAndVerify(sched, sched.getJob(id) orelse continue) catch {};
                        continue;
                    };
                    if (skill_timed_out) log.warn("[{s}] skill timed out after {d}s", .{ id, timeout });
                    const skill_exit: u8 = switch (skill_term) {
                        .exited => |ec| ec,
                        else => 1,
                    };
                    const skill_ok = !skill_timed_out and skill_exit == 0;
                    const skill_output = if (skill_stdout.items.len > 0) skill_stdout.items else skill_stderr.items;
                    {
                        state.scheduler_mutex.lock();
                        if (sched.getMutableJob(id)) |j| {
                            j.last_run_secs = now;
                            j.last_status = if (skill_ok) "ok" else "error";
                            if (j.last_output) |old| sched.allocator.free(old);
                            j.last_output = if (skill_output.len > 0) sched.allocator.dupe(u8, skill_output) catch null else null;
                        }
                        state.scheduler_mutex.unlock();
                    }
                    // Skills self-deliver — no cron delivery.
                    _ = cron_mod.dbUpsertAndVerify(sched, sched.getJob(id) orelse {
                        log.info("[{s}] skill completed ({s}): (no output)", .{ id, if (skill_ok) "ok" else "error" });
                        continue;
                    }) catch |err| log.err("[{s}] db persist failed: {s}", .{ id, @errorName(err) });
                    if (skill_output.len > 0) {
                        const nl2 = std.mem.indexOfScalar(u8, skill_output, '\n') orelse skill_output.len;
                        log.info("[{s}] skill completed ({s}): {s}", .{ id, if (skill_ok) "ok" else "error", skill_output[0..@min(nl2, 120)] });
                    } else {
                        log.info("[{s}] skill completed ({s}): (no output)", .{ id, if (skill_ok) "ok" else "error" });
                    }
                },
            }
        }
    }
}

fn pauseCronJobForRepair(state: *GatewayState, job_id: []const u8) bool {
    if (state.cron_db_backend) |*be| {
        return be.backend().pause(job_id) catch false;
    }
    if (state.cron_db_path) |db_path| {
        const db = cron_mod.openCronDbAtPath(db_path) catch return false;
        defer cron_mod.closeCronDb(db);
        return cron_mod.dbSetJobPaused(db, job_id, true) catch false;
    }
    return false;
}

fn cronRepairAlertDelivery(state: *const GatewayState, spec: anytype) cron_mod.DeliveryConfig {
    if (spec.delivery.mode != .none) {
        return .{
            .mode = @enumFromInt(@intFromEnum(spec.delivery.mode)),
            .channel = spec.delivery.channel,
            .account_id = spec.delivery.account_id,
            .to = spec.delivery.to,
            .best_effort = true,
        };
    }
    return state.alert_delivery orelse cron_mod.DeliveryConfig{};
}

fn sendCronRepairAlert(
    state: *const GatewayState,
    allocator: std.mem.Allocator,
    spec: anytype,
    job_kind: []const u8,
    run_result: cron_mod.RunResult,
    trace_id: []const u8,
    preview: []const u8,
) void {
    const eb = state.event_bus orelse return;
    const fc = run_result.failure_class orelse "unknown";
    const ra = run_result.repair_action orelse "none";
    const alert_del = cronRepairAlertDelivery(state, spec);
    const msg = std.fmt.allocPrint(
        allocator,
        "[cron] {s} '{s}' degraded: failure={s} repair={s} trace={s}\n{s}",
        .{ job_kind, spec.id, fc, ra, trace_id, preview },
    ) catch return;
    defer allocator.free(msg);
    _ = cron_mod.deliverResult(allocator, alert_del, msg, false, eb) catch {};
}

fn handleTelegramWebhookRoute(ctx: *WebhookHandlerContext) void {
    if (!build_options.enable_channel_telegram) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"telegram channel disabled in this build\"}";
        return;
    }

    const is_post = std.mem.eql(u8, ctx.method, "POST");
    if (!is_post) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }

    if (!allowScopedWebhook(ctx.state, "telegram", ctx.client_identifier)) {
        ctx.response_status = "429 Too Many Requests";
        ctx.response_body = "{\"error\":\"rate limited\"}";
        return;
    }

    const body = extractBody(ctx.raw_request);
    if (body) |b| {
        var tg_bot_token = ctx.state.telegram_bot_token;
        var tg_allow_from = ctx.state.telegram_allow_from;
        var tg_account_id = ctx.state.telegram_account_id;
        if (selectTelegramConfig(ctx.config_opt, ctx.target)) |tg_cfg| {
            tg_bot_token = tg_cfg.bot_token;
            tg_allow_from = tg_cfg.allow_from;
            tg_account_id = tg_cfg.account_id;
        }

        const msg_text = jsonStringField(b, "text");
        const telegram_target = telegramWebhookTarget(ctx.req_allocator, b);
        const chat_id = if (telegram_target) |target| target.chat_id else telegramChatId(ctx.req_allocator, b);
        const tg_authorized = telegramSenderAllowed(ctx.req_allocator, tg_allow_from, b);
        if (!tg_authorized) {
            ctx.response_body = "{\"status\":\"unauthorized\"}";
            return;
        }

        if (msg_text != null and telegram_target != null and chat_id != null) {
            var sender_buf: [32]u8 = undefined;
            const sender = telegramSenderIdentity(ctx.req_allocator, b, &sender_buf);
            var cid_buf: [32]u8 = undefined;
            const cid_str = std.fmt.bufPrint(&cid_buf, "{d}", .{chat_id.?}) catch "0";
            const is_group = telegram_target.?.is_group;
            const thread_id = telegram_target.?.message_thread_id;
            const peer_kind = if (is_group) "group" else "direct";
            const chat_target = telegramChatTargetAlloc(ctx.req_allocator, chat_id.?, thread_id) catch {
                ctx.response_status = "500 Internal Server Error";
                ctx.response_body = "{\"error\":\"failed to allocate telegram target\"}";
                return;
            };
            defer ctx.req_allocator.free(chat_target);

            if (ctx.state.event_bus) |eb| {
                var meta_buf: [384]u8 = undefined;
                const meta = if (thread_id) |tid|
                    std.fmt.bufPrint(&meta_buf, "{{\"account_id\":\"{s}\",\"peer_kind\":\"{s}\",\"peer_id\":\"{s}\",\"thread_id\":\"{d}\"}}", .{
                        tg_account_id,
                        peer_kind,
                        cid_str,
                        tid,
                    }) catch null
                else
                    std.fmt.bufPrint(&meta_buf, "{{\"account_id\":\"{s}\",\"peer_kind\":\"{s}\",\"peer_id\":\"{s}\"}}", .{
                        tg_account_id,
                        peer_kind,
                        cid_str,
                    }) catch null;
                var kb: [64]u8 = undefined;
                const tg_cfg_opt: ?*const Config = if (ctx.config_opt) |cfg| cfg else null;
                const sk = telegramSessionKeyRouted(ctx.req_allocator, &kb, b, tg_cfg_opt, tg_account_id);
                _ = publishToBus(eb, ctx.state.allocator, "telegram", sender, chat_target, msg_text.?, sk, meta);
                ctx.response_body = "{\"status\":\"ok\"}";
            } else if (ctx.session_mgr_opt) |sm| {
                var kb: [64]u8 = undefined;
                const tg_cfg_opt: ?*const Config = if (ctx.config_opt) |cfg| cfg else null;
                const sk = telegramSessionKeyRouted(ctx.req_allocator, &kb, b, tg_cfg_opt, tg_account_id);
                const conversation_context: ?ConversationContext = simpleConversationContext(
                    "telegram",
                    tg_account_id,
                    cid_str,
                    chat_target,
                    std.mem.eql(u8, peer_kind, "group"),
                    if (std.mem.eql(u8, peer_kind, "group")) cid_str else null,
                );
                const reply: ?[]const u8 = sm.processInboundMessage(sk, msg_text.?, conversation_context) catch |err| blk: {
                    if (tg_bot_token.len > 0) {
                        sendTelegramReply(ctx.req_allocator, tg_bot_token, chat_id.?, thread_id, userFacingAgentError(err)) catch {};
                    }
                    break :blk null;
                };
                if (reply) |r| {
                    defer ctx.root_allocator.free(r);
                    if (tg_bot_token.len > 0) {
                        sendTelegramReply(ctx.req_allocator, tg_bot_token, chat_id.?, thread_id, r) catch {};
                    }
                    ctx.response_body = "{\"status\":\"ok\"}";
                } else {
                    ctx.response_body = "{\"status\":\"received\"}";
                }
            } else {
                ctx.response_body = "{\"status\":\"received\"}";
            }
        } else {
            ctx.response_body = "{\"status\":\"ok\"}";
        }
    } else {
        ctx.response_body = "{\"status\":\"received\"}";
    }
}

fn handleWhatsAppWebhookRoute(ctx: *WebhookHandlerContext) void {
    if (!build_options.enable_channel_whatsapp) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"whatsapp channel disabled in this build\"}";
        return;
    }

    const is_get = std.mem.eql(u8, ctx.method, "GET");
    if (is_get) {
        const mode = parseQueryParam(ctx.target, "hub.mode");
        const token = parseQueryParam(ctx.target, "hub.verify_token");
        const challenge = parseQueryParam(ctx.target, "hub.challenge");
        var wa_verify_token = ctx.state.whatsapp_verify_token;
        if (selectWhatsAppConfig(ctx.config_opt, null, token)) |wa_cfg| {
            wa_verify_token = wa_cfg.verify_token;
        }

        if (mode != null and challenge != null and token != null and
            std.mem.eql(u8, mode.?, "subscribe") and
            wa_verify_token.len > 0 and
            std.mem.eql(u8, token.?, wa_verify_token))
        {
            ctx.response_body = challenge.?;
        } else {
            ctx.response_status = "403 Forbidden";
            ctx.response_body = "{\"error\":\"verification failed\"}";
        }
        return;
    }

    const is_post = std.mem.eql(u8, ctx.method, "POST");
    if (!is_post) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }

    if (!allowScopedWebhook(ctx.state, "whatsapp", ctx.client_identifier)) {
        ctx.response_status = "429 Too Many Requests";
        ctx.response_body = "{\"error\":\"rate limited\"}";
        return;
    }

    const wa_body = extractBody(ctx.raw_request);
    if (wa_body) |body| {
        if (!isJsonObjectPayload(ctx.req_allocator, body)) {
            ctx.response_status = "400 Bad Request";
            ctx.response_body = "{\"error\":\"invalid json payload\"}";
            return;
        }
    }
    var wa_app_secret = ctx.state.whatsapp_app_secret;
    var wa_access_token = ctx.state.whatsapp_access_token;
    var wa_allow_from = ctx.state.whatsapp_allow_from;
    var wa_group_allow_from = ctx.state.whatsapp_group_allow_from;
    var wa_groups = ctx.state.whatsapp_groups;
    var wa_group_policy = ctx.state.whatsapp_group_policy;
    var wa_account_id = ctx.state.whatsapp_account_id;
    if (selectWhatsAppConfig(ctx.config_opt, wa_body, null)) |wa_cfg| {
        wa_app_secret = wa_cfg.app_secret orelse "";
        wa_access_token = wa_cfg.access_token;
        wa_allow_from = wa_cfg.allow_from;
        wa_group_allow_from = wa_cfg.group_allow_from;
        wa_groups = wa_cfg.groups;
        wa_group_policy = wa_cfg.group_policy;
        wa_account_id = wa_cfg.account_id;
    }

    const sig_header = extractHeader(ctx.raw_request, "X-Hub-Signature-256");
    if (wa_app_secret.len > 0) sig_check: {
        const sig = sig_header orelse {
            ctx.response_status = "403 Forbidden";
            ctx.response_body = "{\"error\":\"missing signature\"}";
            break :sig_check;
        };
        const body = wa_body orelse {
            ctx.response_body = "{\"status\":\"received\"}";
            break :sig_check;
        };
        if (!verifyWhatsappSignature(body, sig, wa_app_secret)) {
            ctx.response_status = "403 Forbidden";
            ctx.response_body = "{\"error\":\"invalid signature\"}";
            break :sig_check;
        }
        const wa_sender = jsonStringField(body, "from");
        const wa_is_group = whatsappIsGroupMessage(body);
        const wa_group_id = whatsappGroupId(body);
        if (!whatsappSenderAllowed(
            wa_sender,
            wa_is_group,
            wa_group_id,
            wa_allow_from,
            wa_group_allow_from,
            wa_groups,
            wa_group_policy,
        )) {
            ctx.response_body = "{\"status\":\"unauthorized\"}";
            break :sig_check;
        }
        const msg_text = jsonStringField(body, "text") orelse jsonStringField(body, "body") orelse
            channels.whatsapp.WhatsAppChannel.downloadMediaFromPayload(ctx.req_allocator, wa_access_token, body);
        if (msg_text) |mt| {
            var wa_key_buf: [256]u8 = undefined;
            const wa_cfg_opt: ?*const Config = if (ctx.config_opt) |cfg| cfg else null;
            const wa_session_key = whatsappSessionKeyRouted(ctx.req_allocator, &wa_key_buf, body, wa_cfg_opt, wa_account_id);
            const wa_sender_id = wa_sender orelse "unknown";
            const wa_chat_target = whatsappReplyTarget(body);
            const wa_peer_kind = if (wa_is_group) "group" else "direct";
            const wa_peer_id = wa_group_id orelse wa_sender_id;

            if (ctx.state.event_bus) |eb| {
                var meta_buf: [384]u8 = undefined;
                const meta = std.fmt.bufPrint(&meta_buf, "{{\"account_id\":\"{s}\",\"peer_kind\":\"{s}\",\"peer_id\":\"{s}\"}}", .{
                    wa_account_id,
                    wa_peer_kind,
                    wa_peer_id,
                }) catch null;
                _ = publishToBus(eb, ctx.state.allocator, "whatsapp", wa_sender_id, wa_chat_target, mt, wa_session_key, meta);
                ctx.response_body = "{\"status\":\"received\"}";
            } else if (ctx.session_mgr_opt) |sm| {
                const conversation_context: ?ConversationContext = simpleConversationContext(
                    "whatsapp",
                    wa_account_id,
                    wa_peer_id,
                    wa_chat_target,
                    wa_is_group,
                    wa_group_id,
                );
                const reply: ?[]const u8 = sm.processInboundMessage(wa_session_key, mt, conversation_context) catch |err| blk: {
                    ctx.response_body = userFacingAgentErrorJson(err);
                    break :blk null;
                };
                if (reply) |r| {
                    defer ctx.root_allocator.free(r);
                    ctx.response_body = ctx.req_allocator.dupe(u8, r) catch "{\"status\":\"received\"}";
                } else {
                    ctx.response_body = "{\"status\":\"received\"}";
                }
            } else {
                ctx.response_body = "{\"status\":\"received\"}";
            }
        } else {
            ctx.response_body = "{\"status\":\"received\"}";
        }
        return;
    }

    if (wa_body) |b| {
        const wa_sender = jsonStringField(b, "from");
        const wa_is_group = whatsappIsGroupMessage(b);
        const wa_group_id = whatsappGroupId(b);
        if (!whatsappSenderAllowed(
            wa_sender,
            wa_is_group,
            wa_group_id,
            wa_allow_from,
            wa_group_allow_from,
            wa_groups,
            wa_group_policy,
        )) {
            ctx.response_body = "{\"status\":\"unauthorized\"}";
            return;
        }
        const msg_text = jsonStringField(b, "text") orelse jsonStringField(b, "body") orelse
            channels.whatsapp.WhatsAppChannel.downloadMediaFromPayload(ctx.req_allocator, wa_access_token, b);
        if (msg_text) |mt| {
            var wa_key_buf: [256]u8 = undefined;
            const wa_cfg_opt: ?*const Config = if (ctx.config_opt) |cfg| cfg else null;
            const wa_session_key = whatsappSessionKeyRouted(ctx.req_allocator, &wa_key_buf, b, wa_cfg_opt, wa_account_id);
            const wa_sender_ns = wa_sender orelse "unknown";
            const wa_chat_target_ns = whatsappReplyTarget(b);
            const wa_peer_kind = if (wa_is_group) "group" else "direct";
            const wa_peer_id = wa_group_id orelse wa_sender_ns;

            if (ctx.state.event_bus) |eb| {
                var meta_buf: [384]u8 = undefined;
                const meta = std.fmt.bufPrint(&meta_buf, "{{\"account_id\":\"{s}\",\"peer_kind\":\"{s}\",\"peer_id\":\"{s}\"}}", .{
                    wa_account_id,
                    wa_peer_kind,
                    wa_peer_id,
                }) catch null;
                _ = publishToBus(eb, ctx.state.allocator, "whatsapp", wa_sender_ns, wa_chat_target_ns, mt, wa_session_key, meta);
                ctx.response_body = "{\"status\":\"received\"}";
            } else if (ctx.session_mgr_opt) |sm| {
                const conversation_context: ?ConversationContext = simpleConversationContext(
                    "whatsapp",
                    wa_account_id,
                    wa_peer_id,
                    wa_chat_target_ns,
                    wa_is_group,
                    wa_group_id,
                );
                const reply: ?[]const u8 = sm.processInboundMessage(wa_session_key, mt, conversation_context) catch |err| blk: {
                    ctx.response_body = userFacingAgentErrorJson(err);
                    break :blk null;
                };
                if (reply) |r| {
                    defer ctx.root_allocator.free(r);
                    ctx.response_body = ctx.req_allocator.dupe(u8, r) catch "{\"status\":\"received\"}";
                } else {
                    ctx.response_body = "{\"status\":\"received\"}";
                }
            } else {
                ctx.response_body = "{\"status\":\"received\"}";
            }
        } else {
            ctx.response_body = "{\"status\":\"received\"}";
        }
    } else {
        ctx.response_body = "{\"status\":\"received\"}";
    }
}

fn handleSlackWebhookRoute(ctx: *WebhookHandlerContext) void {
    if (!build_options.enable_channel_slack) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"slack channel disabled in this build\"}";
        return;
    }

    if (!std.mem.eql(u8, ctx.method, "POST")) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }
    if (!allowScopedWebhook(ctx.state, "slack", ctx.client_identifier)) {
        ctx.response_status = "429 Too Many Requests";
        ctx.response_body = "{\"error\":\"rate limited\"}";
        return;
    }

    const body = extractBody(ctx.raw_request) orelse {
        ctx.response_body = "{\"status\":\"received\"}";
        return;
    };

    const ts_header = extractHeader(ctx.raw_request, "X-Slack-Request-Timestamp");
    const sig_header = extractHeader(ctx.raw_request, "X-Slack-Signature");

    const slack_cfg = findSlackConfigForRequest(ctx.req_allocator, ctx.config_opt, ctx.target, body, ts_header, sig_header) orelse {
        if (hasSlackHttpEndpoint(ctx.config_opt, webhookBasePath(ctx.target))) {
            ctx.response_status = "403 Forbidden";
            ctx.response_body = "{\"error\":\"invalid signature\"}";
            return;
        }
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"slack account not configured\"}";
        return;
    };

    const content_type = extractHeader(ctx.raw_request, "Content-Type");
    const is_form_payload = if (content_type) |header_value| blk: {
        const semi = std.mem.indexOfScalar(u8, header_value, ';') orelse header_value.len;
        const base = std.mem.trim(u8, header_value[0..semi], " \t\r\n");
        break :blk asciiEqlIgnoreCase(base, "application/x-www-form-urlencoded");
    } else false;

    const effective_body = if (is_form_payload)
        slackDecodeInteractivePayload(ctx.req_allocator, body) orelse {
            ctx.response_body = "{\"status\":\"parse_error\"}";
            return;
        }
    else
        body;
    defer if (effective_body.ptr != body.ptr) ctx.req_allocator.free(effective_body);

    const parsed = std.json.parseFromSlice(std.json.Value, ctx.req_allocator, effective_body, .{}) catch {
        ctx.response_body = "{\"status\":\"parse_error\"}";
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    }

    const payload_type = if (parsed.value.object.get("type")) |tv|
        if (tv == .string) tv.string else ""
    else
        "";

    if (std.mem.eql(u8, payload_type, "url_verification")) {
        const challenge = jsonStringField(effective_body, "challenge") orelse "";
        if (challenge.len == 0) {
            ctx.response_body = "{\"status\":\"ok\"}";
            return;
        }
        const challenge_resp = jsonWrapChallenge(ctx.req_allocator, challenge) catch {
            ctx.response_body = "{\"status\":\"ok\"}";
            return;
        };
        ctx.response_body = challenge_resp;
        return;
    }

    if (std.mem.eql(u8, payload_type, "block_actions")) {
        const user_val = parsed.value.object.get("user") orelse {
            ctx.response_body = "{\"status\":\"ok\"}";
            return;
        };
        const channel_val = parsed.value.object.get("channel") orelse {
            ctx.response_body = "{\"status\":\"ok\"}";
            return;
        };
        const actions_val = parsed.value.object.get("actions") orelse {
            ctx.response_body = "{\"status\":\"ok\"}";
            return;
        };
        if (user_val != .object or channel_val != .object or actions_val != .array or actions_val.array.items.len == 0) {
            ctx.response_body = "{\"status\":\"ok\"}";
            return;
        }
        const sender_id_val = user_val.object.get("id") orelse {
            ctx.response_body = "{\"status\":\"ok\"}";
            return;
        };
        const callback_channel_val = channel_val.object.get("id") orelse {
            ctx.response_body = "{\"status\":\"ok\"}";
            return;
        };
        const first_action = actions_val.array.items[0];
        if (sender_id_val != .string or callback_channel_val != .string or first_action != .object) {
            ctx.response_body = "{\"status\":\"ok\"}";
            return;
        }
        const value_val = first_action.object.get("value") orelse {
            ctx.response_body = "{\"status\":\"ok\"}";
            return;
        };
        if (value_val != .string) {
            ctx.response_body = "{\"status\":\"ok\"}";
            return;
        }
        const parsed_callback = slackParseCallbackValue(value_val.string) orelse {
            ctx.response_body = "{\"status\":\"ok\"}";
            return;
        };

        var callback_channel = channels.slack.SlackChannel.initFromConfig(ctx.req_allocator, slack_cfg.*);
        switch (callback_channel.consumeInteractionSelection(parsed_callback.token, parsed_callback.option_index, sender_id_val.string)) {
            .ok => |selection| {
                defer ctx.req_allocator.free(selection.submit_text);
                defer ctx.req_allocator.free(selection.target);

                const interactive_target = slackInteractiveTarget(selection.target, callback_channel_val.string);

                var key_buf: [256]u8 = undefined;
                const session_key = slackSessionKeyRouted(
                    ctx.req_allocator,
                    &key_buf,
                    slack_cfg.account_id,
                    sender_id_val.string,
                    interactive_target.channel_id,
                    interactive_target.is_dm,
                    ctx.config_opt,
                );

                if (ctx.state.event_bus) |eb| {
                    var meta_buf: [384]u8 = undefined;
                    const metadata = if (interactive_target.thread_id) |thread_id|
                        std.fmt.bufPrint(
                            &meta_buf,
                            "{{\"account_id\":\"{s}\",\"is_dm\":{s},\"channel_id\":\"{s}\",\"peer_kind\":\"{s}\",\"peer_id\":\"{s}\",\"thread_id\":\"{s}\",\"interactive\":true}}",
                            .{
                                slack_cfg.account_id,
                                if (interactive_target.is_dm) "true" else "false",
                                interactive_target.channel_id,
                                if (interactive_target.is_dm) "direct" else "channel",
                                if (interactive_target.is_dm) sender_id_val.string else interactive_target.channel_id,
                                thread_id,
                            },
                        ) catch null
                    else
                        std.fmt.bufPrint(
                            &meta_buf,
                            "{{\"account_id\":\"{s}\",\"is_dm\":{s},\"channel_id\":\"{s}\",\"peer_kind\":\"{s}\",\"peer_id\":\"{s}\",\"interactive\":true}}",
                            .{
                                slack_cfg.account_id,
                                if (interactive_target.is_dm) "true" else "false",
                                interactive_target.channel_id,
                                if (interactive_target.is_dm) "direct" else "channel",
                                if (interactive_target.is_dm) sender_id_val.string else interactive_target.channel_id,
                            },
                        ) catch null;
                    _ = publishToBus(
                        eb,
                        ctx.state.allocator,
                        "slack",
                        sender_id_val.string,
                        selection.target,
                        selection.submit_text,
                        session_key,
                        metadata,
                    );
                } else if (ctx.session_mgr_opt) |sm| {
                    const conversation_context: ?ConversationContext = simpleConversationContext(
                        "slack",
                        slack_cfg.account_id,
                        if (interactive_target.is_dm) sender_id_val.string else interactive_target.channel_id,
                        selection.target,
                        !interactive_target.is_dm,
                        if (!interactive_target.is_dm) interactive_target.channel_id else null,
                    );
                    const reply: ?[]const u8 = sm.processInboundMessage(session_key, selection.submit_text, conversation_context) catch |err| blk: {
                        var outbound_ch = channels.slack.SlackChannel.initFromConfig(ctx.req_allocator, slack_cfg.*);
                        outbound_ch.sendMessage(selection.target, userFacingAgentError(err)) catch {};
                        break :blk null;
                    };
                    if (reply) |r| {
                        defer ctx.root_allocator.free(r);
                        var outbound_ch = channels.slack.SlackChannel.initFromConfig(ctx.req_allocator, slack_cfg.*);
                        outbound_ch.sendMessage(selection.target, r) catch {};
                    }
                }
            },
            else => {},
        }

        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    }

    if (!std.mem.eql(u8, payload_type, "event_callback")) {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    }

    const event_val = parsed.value.object.get("event") orelse {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    };
    if (event_val != .object) {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    }
    const event_obj = event_val.object;

    const event_type_val = event_obj.get("type") orelse {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    };
    if (event_type_val != .string) {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    }
    const event_type = event_type_val.string;
    if (!std.mem.eql(u8, event_type, "message") and !std.mem.eql(u8, event_type, "app_mention")) {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    }

    if (event_obj.get("subtype")) |subtype_val| {
        if (subtype_val == .string and subtype_val.string.len > 0) {
            ctx.response_body = "{\"status\":\"ok\"}";
            return;
        }
    }

    const user_val = event_obj.get("user") orelse {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    };
    if (user_val != .string or user_val.string.len == 0) {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    }
    const sender_id = user_val.string;

    const text_val = event_obj.get("text") orelse {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    };
    if (text_val != .string) {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    }
    const text = std.mem.trim(u8, text_val.string, " \t\r\n");
    if (text.len == 0) {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    }

    const channel_val = event_obj.get("channel") orelse {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    };
    if (channel_val != .string or channel_val.string.len == 0) {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    }
    const channel_id = channel_val.string;
    const is_dm = blk: {
        if (event_obj.get("channel_type")) |ct| {
            if (ct == .string and std.mem.eql(u8, ct.string, "im")) break :blk true;
        }
        break :blk channel_id.len > 0 and channel_id[0] == 'D';
    };

    var policy_channel = channels.slack.SlackChannel.initFromConfig(ctx.req_allocator, slack_cfg.*);
    const envelope_bot_user_id = slackEnvelopeBotUserId(parsed.value.object);
    var allowed = policy_channel.shouldHandle(sender_id, is_dm, text, envelope_bot_user_id);
    if (!allowed and std.mem.eql(u8, event_type, "app_mention")) {
        allowed = channels.checkPolicy(policy_channel.policy, sender_id, is_dm, true);
    }
    if (!allowed) {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    }

    var key_buf: [256]u8 = undefined;
    const sk = slackSessionKeyRouted(
        ctx.req_allocator,
        &key_buf,
        slack_cfg.account_id,
        sender_id,
        channel_id,
        is_dm,
        ctx.config_opt,
    );

    if (ctx.state.event_bus) |eb| {
        var meta_buf: [384]u8 = undefined;
        const peer_kind = if (is_dm) "direct" else "channel";
        const peer_id = if (is_dm) sender_id else channel_id;
        const metadata = std.fmt.bufPrint(
            &meta_buf,
            "{{\"account_id\":\"{s}\",\"is_dm\":{s},\"channel_id\":\"{s}\",\"peer_kind\":\"{s}\",\"peer_id\":\"{s}\"}}",
            .{
                slack_cfg.account_id,
                if (is_dm) "true" else "false",
                channel_id,
                peer_kind,
                peer_id,
            },
        ) catch null;
        _ = publishToBus(eb, ctx.state.allocator, "slack", sender_id, channel_id, text, sk, metadata);
    } else if (ctx.session_mgr_opt) |sm| {
        const conversation_context: ?ConversationContext = simpleConversationContext(
            "slack",
            slack_cfg.account_id,
            if (is_dm) sender_id else channel_id,
            channel_id,
            !is_dm,
            if (!is_dm) channel_id else null,
        );
        const reply: ?[]const u8 = sm.processInboundMessage(sk, text, conversation_context) catch |err| blk: {
            var outbound_ch = channels.slack.SlackChannel.initFromConfig(ctx.req_allocator, slack_cfg.*);
            outbound_ch.sendMessage(channel_id, userFacingAgentError(err)) catch {};
            break :blk null;
        };
        if (reply) |r| {
            defer ctx.root_allocator.free(r);
            var outbound_ch = channels.slack.SlackChannel.initFromConfig(ctx.req_allocator, slack_cfg.*);
            outbound_ch.sendMessage(channel_id, r) catch {};
        }
    }

    ctx.response_body = "{\"status\":\"ok\"}";
}

fn linePeerMetadata(evt: channels.line.LineEvent, peer_buf: []u8) struct {
    kind: []const u8,
    id: []const u8,
} {
    const src_type = evt.source_type orelse "";
    if (std.mem.eql(u8, src_type, "group")) {
        return .{
            .kind = "group",
            .id = std.fmt.bufPrint(peer_buf, "group:{s}", .{evt.group_id orelse evt.user_id orelse "unknown"}) catch "group:unknown",
        };
    }
    if (std.mem.eql(u8, src_type, "room")) {
        return .{
            .kind = "group",
            .id = std.fmt.bufPrint(peer_buf, "room:{s}", .{evt.room_id orelse evt.user_id orelse "unknown"}) catch "room:unknown",
        };
    }
    return .{
        .kind = "direct",
        .id = evt.user_id orelse "unknown",
    };
}

fn handleLineWebhookRoute(ctx: *WebhookHandlerContext) void {
    if (!build_options.enable_channel_line) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"line channel disabled in this build\"}";
        return;
    }

    const is_post = std.mem.eql(u8, ctx.method, "POST");
    if (!is_post) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }
    if (!allowScopedWebhook(ctx.state, "line", ctx.client_identifier)) {
        ctx.response_status = "429 Too Many Requests";
        ctx.response_body = "{\"error\":\"rate limited\"}";
        return;
    }

    const body = extractBody(ctx.raw_request);
    if (body) |b| {
        var line_channel_secret = ctx.state.line_channel_secret;
        var line_access_token = ctx.state.line_access_token;
        var line_allow_from = ctx.state.line_allow_from;
        var line_account_id = ctx.state.line_account_id;

        const sig_header = extractHeader(ctx.raw_request, "X-Line-Signature");
        if (ctx.config_opt) |cfg| {
            const needs_signature = hasLineSecrets(cfg);
            if (needs_signature) {
                const sig = sig_header orelse {
                    ctx.response_status = "403 Forbidden";
                    ctx.response_body = "{\"error\":\"missing signature\"}";
                    return;
                };
                const matched_line_cfg = selectLineConfigBySignature(ctx.config_opt, b, sig) orelse {
                    ctx.response_status = "403 Forbidden";
                    ctx.response_body = "{\"error\":\"invalid signature\"}";
                    return;
                };
                line_channel_secret = matched_line_cfg.channel_secret;
                line_access_token = matched_line_cfg.access_token;
                line_allow_from = matched_line_cfg.allow_from;
                line_account_id = matched_line_cfg.account_id;
            } else if (cfg.channels.linePrimary()) |line_cfg| {
                line_channel_secret = line_cfg.channel_secret;
                line_access_token = line_cfg.access_token;
                line_allow_from = line_cfg.allow_from;
                line_account_id = line_cfg.account_id;
            }
        } else if (line_channel_secret.len > 0) {
            const sig = sig_header orelse {
                ctx.response_status = "403 Forbidden";
                ctx.response_body = "{\"error\":\"missing signature\"}";
                return;
            };
            if (!channels.line.LineChannel.verifySignature(b, sig, line_channel_secret)) {
                ctx.response_status = "403 Forbidden";
                ctx.response_body = "{\"error\":\"invalid signature\"}";
                return;
            }
        }

        const events = channels.line.LineChannel.parseWebhookEvents(ctx.req_allocator, b) catch {
            ctx.response_body = "{\"status\":\"parse_error\"}";
            return;
        };
        for (events) |evt| {
            if (line_allow_from.len > 0) {
                if (evt.user_id) |uid| {
                    if (!channels.isAllowed(line_allow_from, uid)) continue;
                } else continue;
            }
            if (evt.message_text) |text| {
                var kb: [128]u8 = undefined;
                const line_cfg_opt: ?*const Config = if (ctx.config_opt) |cfg| cfg else null;
                const sk = lineSessionKeyRouted(ctx.req_allocator, &kb, evt, line_cfg_opt, line_account_id);
                const uid = evt.user_id orelse "unknown";
                const line_target = lineReplyTarget(evt);
                var peer_buf: [160]u8 = undefined;
                const line_peer = linePeerMetadata(evt, &peer_buf);

                if (ctx.state.event_bus) |eb| {
                    var meta_buf: [384]u8 = undefined;
                    const meta = std.fmt.bufPrint(&meta_buf, "{{\"account_id\":\"{s}\",\"peer_kind\":\"{s}\",\"peer_id\":\"{s}\"}}", .{
                        line_account_id,
                        line_peer.kind,
                        line_peer.id,
                    }) catch null;
                    _ = publishToBus(eb, ctx.state.allocator, "line", uid, line_target, text, sk, meta);
                } else if (ctx.session_mgr_opt) |sm| {
                    const conversation_context: ?ConversationContext = simpleConversationContext(
                        "line",
                        line_account_id,
                        line_peer.id,
                        line_target,
                        !std.mem.eql(u8, line_peer.kind, "direct"),
                        if (!std.mem.eql(u8, line_peer.kind, "direct")) line_peer.id else null,
                    );
                    const reply: ?[]const u8 = sm.processInboundMessage(sk, text, conversation_context) catch |err| blk: {
                        if (evt.reply_token) |rt| {
                            var line_ch = channels.line.LineChannel.init(ctx.req_allocator, .{
                                .access_token = line_access_token,
                                .channel_secret = line_channel_secret,
                            });
                            line_ch.replyMessage(rt, userFacingAgentError(err)) catch {};
                        }
                        break :blk null;
                    };
                    if (reply) |r| {
                        defer ctx.root_allocator.free(r);
                        if (evt.reply_token) |rt| {
                            var line_ch = channels.line.LineChannel.init(ctx.req_allocator, .{
                                .access_token = line_access_token,
                                .channel_secret = line_channel_secret,
                            });
                            line_ch.replyMessage(rt, r) catch {};
                        }
                    }
                }
            }
        }
        ctx.response_body = "{\"status\":\"ok\"}";
    } else {
        ctx.response_body = "{\"status\":\"received\"}";
    }
}

fn handleLarkWebhookRoute(ctx: *WebhookHandlerContext) void {
    if (!build_options.enable_channel_lark) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"lark channel disabled in this build\"}";
        return;
    }

    const is_post = std.mem.eql(u8, ctx.method, "POST");
    if (!is_post) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }
    if (!allowScopedWebhook(ctx.state, "lark", ctx.client_identifier)) {
        ctx.response_status = "429 Too Many Requests";
        ctx.response_body = "{\"error\":\"rate limited\"}";
        return;
    }

    const body = extractBody(ctx.raw_request) orelse {
        ctx.response_body = "{\"status\":\"received\"}";
        return;
    };
    var lark_verification_token = ctx.state.lark_verification_token;
    var lark_app_id = ctx.state.lark_app_id;
    var lark_app_secret = ctx.state.lark_app_secret;
    var lark_allow_from = ctx.state.lark_allow_from;
    var lark_account_id = ctx.state.lark_account_id;
    if (selectLarkConfig(ctx.config_opt, body)) |lark_cfg| {
        lark_verification_token = lark_cfg.verification_token orelse "";
        lark_app_id = lark_cfg.app_id;
        lark_app_secret = lark_cfg.app_secret;
        lark_allow_from = lark_cfg.allow_from;
        lark_account_id = lark_cfg.account_id;
    }

    if (std.mem.indexOf(u8, body, "\"url_verification\"") != null) {
        const challenge = jsonStringField(body, "challenge");
        if (challenge) |c| {
            const challenge_resp = jsonWrapChallenge(ctx.req_allocator, c) catch null;
            ctx.response_body = challenge_resp orelse "{\"status\":\"ok\"}";
        } else {
            ctx.response_body = "{\"status\":\"ok\"}";
        }
        return;
    }

    if (lark_verification_token.len > 0) {
        const payload_token = blk: {
            const parsed = std.json.parseFromSlice(std.json.Value, ctx.req_allocator, body, .{}) catch break :blk @as(?[]const u8, null);
            defer parsed.deinit();
            if (parsed.value != .object) break :blk @as(?[]const u8, null);
            const header = parsed.value.object.get("header") orelse break :blk @as(?[]const u8, null);
            if (header != .object) break :blk @as(?[]const u8, null);
            const token_val = header.object.get("token") orelse break :blk @as(?[]const u8, null);
            break :blk if (token_val == .string) ctx.req_allocator.dupe(u8, token_val.string) catch null else null;
        };
        if (payload_token) |pt| {
            if (!std.mem.eql(u8, pt, lark_verification_token)) {
                ctx.response_status = "403 Forbidden";
                ctx.response_body = "{\"error\":\"invalid verification token\"}";
                return;
            }
        }
    }

    var lark_ch = channels.lark.LarkChannel.init(
        ctx.req_allocator,
        lark_app_id,
        lark_app_secret,
        lark_verification_token,
        0,
        lark_allow_from,
    );
    const messages = lark_ch.parseEventPayload(ctx.req_allocator, body) catch {
        ctx.response_body = "{\"status\":\"parse_error\"}";
        return;
    };
    for (messages) |msg| {
        var kb: [128]u8 = undefined;
        const lark_cfg_opt: ?*const Config = if (ctx.config_opt) |cfg| cfg else null;
        const sk = larkSessionKeyRouted(ctx.req_allocator, &kb, msg, lark_cfg_opt, lark_account_id);

        if (ctx.state.event_bus) |eb| {
            var meta_buf: [320]u8 = undefined;
            const meta = std.fmt.bufPrint(&meta_buf, "{{\"account_id\":\"{s}\",\"peer_kind\":\"{s}\",\"peer_id\":\"{s}\"}}", .{
                lark_account_id,
                if (msg.is_group) "group" else "direct",
                msg.sender,
            }) catch null;
            _ = publishToBus(eb, ctx.state.allocator, "lark", msg.sender, msg.sender, msg.content, sk, meta);
        } else if (ctx.session_mgr_opt) |sm| {
            const conversation_context: ?ConversationContext = simpleConversationContext(
                "lark",
                lark_account_id,
                msg.sender,
                msg.sender,
                msg.is_group,
                if (msg.is_group) msg.sender else null,
            );
            const reply: ?[]const u8 = sm.processInboundMessage(sk, msg.content, conversation_context) catch |err| blk: {
                lark_ch.sendMessage(msg.sender, userFacingAgentError(err)) catch {};
                break :blk null;
            };
            if (reply) |r| {
                defer ctx.root_allocator.free(r);
                lark_ch.sendMessage(msg.sender, r) catch {};
            }
        }
    }
    ctx.response_body = "{\"status\":\"ok\"}";
}

fn handleWeChatWebhookRoute(ctx: *WebhookHandlerContext) void {
    if (!build_options.enable_channel_wechat) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"wechat channel disabled in this build\"}";
        return;
    }

    var wechat_account_id = ctx.state.wechat_account_id;
    var wechat_allow_from = ctx.state.wechat_allow_from;
    var callback_token = ctx.state.wechat_callback_token;
    var secure_aes_key = ctx.state.wechat_encoding_aes_key;
    var expected_app_id = ctx.state.wechat_app_id;
    if (selectWeChatConfig(ctx.config_opt, ctx.target)) |wechat_cfg| {
        wechat_account_id = wechat_cfg.account_id;
        wechat_allow_from = wechat_cfg.allow_from;
        callback_token = wechat_cfg.callback_token;
        secure_aes_key = wechat_cfg.encoding_aes_key orelse "";
        expected_app_id = wechat_cfg.app_id orelse "";
    }
    if (callback_token.len == 0) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"wechat callback not configured\"}";
        return;
    }

    const secure_enabled = callback_token.len > 0 and secure_aes_key.len > 0;

    if (std.mem.eql(u8, ctx.method, "GET")) {
        const echo = parseQueryParam(ctx.target, "echostr") orelse {
            ctx.response_body = "{\"status\":\"ok\"}";
            return;
        };

        if (callback_token.len > 0) {
            const timestamp = parseQueryParam(ctx.target, "timestamp") orelse {
                ctx.response_status = "400 Bad Request";
                ctx.response_body = "{\"error\":\"missing timestamp\"}";
                return;
            };
            const nonce = parseQueryParam(ctx.target, "nonce") orelse {
                ctx.response_status = "400 Bad Request";
                ctx.response_body = "{\"error\":\"missing nonce\"}";
                return;
            };
            if (!isFreshSignedWebhookTimestamp(timestamp)) {
                ctx.response_status = "403 Forbidden";
                ctx.response_body = "{\"error\":\"stale timestamp\"}";
                return;
            }

            if (secure_enabled) {
                const msg_signature = parseQueryParam(ctx.target, "msg_signature") orelse {
                    ctx.response_status = "400 Bad Request";
                    ctx.response_body = "{\"error\":\"missing msg_signature\"}";
                    return;
                };
                if (!channels.wechat.verifyMessageSignature(callback_token, timestamp, nonce, echo, msg_signature)) {
                    ctx.response_status = "403 Forbidden";
                    ctx.response_body = "{\"error\":\"invalid signature\"}";
                    return;
                }

                const expected_app_id_opt: ?[]const u8 = if (expected_app_id.len > 0) expected_app_id else null;
                const plain_echo = channels.wechat.decryptSecurePayload(
                    ctx.req_allocator,
                    secure_aes_key,
                    echo,
                    expected_app_id_opt,
                ) catch {
                    ctx.response_status = "403 Forbidden";
                    ctx.response_body = "{\"error\":\"decrypt failed\"}";
                    return;
                };
                setPlainTextResponse(ctx, plain_echo);
                return;
            } else {
                const signature = parseQueryParam(ctx.target, "signature") orelse {
                    ctx.response_status = "400 Bad Request";
                    ctx.response_body = "{\"error\":\"missing signature\"}";
                    return;
                };
                if (!channels.wechat.verifySignature(callback_token, timestamp, nonce, signature)) {
                    ctx.response_status = "403 Forbidden";
                    ctx.response_body = "{\"error\":\"invalid signature\"}";
                    return;
                }
            }
        }

        setPlainTextResponse(ctx, echo);
        return;
    }

    if (!std.mem.eql(u8, ctx.method, "POST")) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }

    if (!allowScopedWebhook(ctx.state, "wechat", ctx.client_identifier)) {
        ctx.response_status = "429 Too Many Requests";
        ctx.response_body = "{\"error\":\"rate limited\"}";
        return;
    }

    const body = extractBody(ctx.raw_request) orelse {
        setPlainTextResponse(ctx, "success");
        return;
    };

    const inbound_payload = if (secure_enabled) blk: {
        const encrypted = channels.wechat.extractEncryptedField(body) orelse {
            ctx.response_status = "400 Bad Request";
            ctx.response_body = "{\"error\":\"missing Encrypt field\"}";
            return;
        };
        const msg_signature = parseQueryParam(ctx.target, "msg_signature") orelse {
            ctx.response_status = "400 Bad Request";
            ctx.response_body = "{\"error\":\"missing msg_signature\"}";
            return;
        };
        const timestamp = parseQueryParam(ctx.target, "timestamp") orelse {
            ctx.response_status = "400 Bad Request";
            ctx.response_body = "{\"error\":\"missing timestamp\"}";
            return;
        };
        const nonce = parseQueryParam(ctx.target, "nonce") orelse {
            ctx.response_status = "400 Bad Request";
            ctx.response_body = "{\"error\":\"missing nonce\"}";
            return;
        };
        if (!isFreshSignedWebhookTimestamp(timestamp)) {
            ctx.response_status = "403 Forbidden";
            ctx.response_body = "{\"error\":\"stale timestamp\"}";
            return;
        }

        if (!channels.wechat.verifyMessageSignature(callback_token, timestamp, nonce, encrypted, msg_signature)) {
            ctx.response_status = "403 Forbidden";
            ctx.response_body = "{\"error\":\"invalid signature\"}";
            return;
        }

        const expected_app_id_opt: ?[]const u8 = if (expected_app_id.len > 0) expected_app_id else null;
        break :blk channels.wechat.decryptSecurePayload(
            ctx.req_allocator,
            secure_aes_key,
            encrypted,
            expected_app_id_opt,
        ) catch {
            ctx.response_status = "403 Forbidden";
            ctx.response_body = "{\"error\":\"decrypt failed\"}";
            return;
        };
    } else blk: {
        if (callback_token.len > 0) {
            const signature = parseQueryParam(ctx.target, "signature") orelse {
                ctx.response_status = "400 Bad Request";
                ctx.response_body = "{\"error\":\"missing signature\"}";
                return;
            };
            const timestamp = parseQueryParam(ctx.target, "timestamp") orelse {
                ctx.response_status = "400 Bad Request";
                ctx.response_body = "{\"error\":\"missing timestamp\"}";
                return;
            };
            const nonce = parseQueryParam(ctx.target, "nonce") orelse {
                ctx.response_status = "400 Bad Request";
                ctx.response_body = "{\"error\":\"missing nonce\"}";
                return;
            };
            if (!isFreshSignedWebhookTimestamp(timestamp)) {
                ctx.response_status = "403 Forbidden";
                ctx.response_body = "{\"error\":\"stale timestamp\"}";
                return;
            }
            if (!channels.wechat.verifySignature(callback_token, timestamp, nonce, signature)) {
                ctx.response_status = "403 Forbidden";
                ctx.response_body = "{\"error\":\"invalid signature\"}";
                return;
            }
        }

        break :blk ctx.req_allocator.dupe(u8, body) catch {
            ctx.response_status = "500 Internal Server Error";
            ctx.response_body = "{\"error\":\"out of memory\"}";
            return;
        };
    };
    defer ctx.req_allocator.free(inbound_payload);

    var inbound = channels.wechat.parseIncomingPayload(ctx.req_allocator, inbound_payload) catch {
        setPlainTextResponse(ctx, "success");
        return;
    } orelse {
        setPlainTextResponse(ctx, "success");
        return;
    };
    defer inbound.deinit(ctx.req_allocator);

    if (wechat_allow_from.len > 0 and !channels.isAllowed(wechat_allow_from, inbound.from_user)) {
        setPlainTextResponse(ctx, "success");
        return;
    }

    if (ctx.state.event_bus) |eb| {
        var key_buf: [128]u8 = undefined;
        const session_key = wechatSessionKeyRouted(
            ctx.req_allocator,
            &key_buf,
            inbound.from_user,
            ctx.config_opt,
            wechat_account_id,
        );
        var meta_buf: [320]u8 = undefined;
        const meta = std.fmt.bufPrint(&meta_buf, "{{\"account_id\":\"{s}\",\"peer_kind\":\"direct\",\"peer_id\":\"{s}\"}}", .{
            wechat_account_id,
            inbound.from_user,
        }) catch null;
        _ = publishToBus(eb, ctx.state.allocator, "wechat", inbound.from_user, inbound.from_user, inbound.content, session_key, meta);
        setPlainTextResponse(ctx, "success");
        return;
    }

    if (ctx.session_mgr_opt) |sm| {
        var key_buf: [128]u8 = undefined;
        const session_key = wechatSessionKeyRouted(
            ctx.req_allocator,
            &key_buf,
            inbound.from_user,
            ctx.config_opt,
            wechat_account_id,
        );
        const reply: ?[]const u8 = sm.processInboundMessage(session_key, inbound.content, null) catch null;
        if (reply) |r| {
            defer ctx.root_allocator.free(r);
            const now_secs = std_compat.time.timestamp();
            const xml = channels.wechat.buildPassiveTextReply(
                ctx.req_allocator,
                inbound.from_user,
                inbound.to_user,
                r,
                now_secs,
            ) catch {
                setPlainTextResponse(ctx, "success");
                return;
            };
            setXmlResponse(ctx, xml);
            return;
        }
    }

    setPlainTextResponse(ctx, "success");
}

fn handleWeComWebhookRoute(ctx: *WebhookHandlerContext) void {
    if (!build_options.enable_channel_wecom) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"wecom channel disabled in this build\"}";
        return;
    }

    var wecom_account_id = ctx.state.wecom_account_id;
    var wecom_allow_from = ctx.state.wecom_allow_from;
    var secure_token = ctx.state.wecom_callback_token;
    var secure_aes_key = ctx.state.wecom_encoding_aes_key;
    var secure_corp_id = ctx.state.wecom_corp_id;
    var wecom_cfg_opt: ?*const config_types.WeComConfig = null;
    if (selectWeComConfig(ctx.config_opt, ctx.target)) |wecom_cfg| {
        wecom_cfg_opt = wecom_cfg;
        wecom_account_id = wecom_cfg.account_id;
        wecom_allow_from = wecom_cfg.allow_from;
        secure_token = wecom_cfg.callback_token orelse "";
        secure_aes_key = wecom_cfg.encoding_aes_key orelse "";
        secure_corp_id = wecom_cfg.corp_id orelse "";
    }

    const secure_enabled = secure_token.len > 0 and secure_aes_key.len > 0;
    if (!secure_enabled) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"wecom secure callback not configured\"}";
        return;
    }

    if (std.mem.eql(u8, ctx.method, "GET")) {
        if (parseQueryParam(ctx.target, "echostr")) |echo_str| {
            const msg_sig = parseQueryParam(ctx.target, "msg_signature") orelse {
                ctx.response_status = "400 Bad Request";
                ctx.response_body = "{\"error\":\"missing msg_signature\"}";
                return;
            };
            const timestamp = parseQueryParam(ctx.target, "timestamp") orelse {
                ctx.response_status = "400 Bad Request";
                ctx.response_body = "{\"error\":\"missing timestamp\"}";
                return;
            };
            const nonce = parseQueryParam(ctx.target, "nonce") orelse {
                ctx.response_status = "400 Bad Request";
                ctx.response_body = "{\"error\":\"missing nonce\"}";
                return;
            };
            if (!isFreshSignedWebhookTimestamp(timestamp)) {
                ctx.response_status = "403 Forbidden";
                ctx.response_body = "{\"error\":\"stale timestamp\"}";
                return;
            }

            if (!channels.wecom.verifySignature(secure_token, timestamp, nonce, echo_str, msg_sig)) {
                ctx.response_status = "403 Forbidden";
                ctx.response_body = "{\"error\":\"invalid signature\"}";
                return;
            }

            const expected_receive_id: ?[]const u8 = if (secure_corp_id.len > 0) secure_corp_id else null;
            const plain_echo = channels.wecom.decryptSecurePayload(
                ctx.req_allocator,
                secure_aes_key,
                echo_str,
                expected_receive_id,
            ) catch {
                ctx.response_status = "403 Forbidden";
                ctx.response_body = "{\"error\":\"decrypt failed\"}";
                return;
            };
            setPlainTextResponse(ctx, plain_echo);
        } else {
            ctx.response_body = "{\"status\":\"ok\"}";
        }
        return;
    }

    if (!std.mem.eql(u8, ctx.method, "POST")) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }
    if (!allowScopedWebhook(ctx.state, "wecom", ctx.client_identifier)) {
        ctx.response_status = "429 Too Many Requests";
        ctx.response_body = "{\"error\":\"rate limited\"}";
        return;
    }

    const body = extractBody(ctx.raw_request) orelse {
        ctx.response_body = "{\"status\":\"received\"}";
        return;
    };

    const inbound_payload = blk: {
        const encrypted = channels.wecom.extractEncryptedField(body) orelse {
            ctx.response_status = "400 Bad Request";
            ctx.response_body = "{\"error\":\"missing Encrypt field\"}";
            return;
        };
        const msg_sig = parseQueryParam(ctx.target, "msg_signature") orelse {
            ctx.response_status = "400 Bad Request";
            ctx.response_body = "{\"error\":\"missing msg_signature\"}";
            return;
        };
        const timestamp = parseQueryParam(ctx.target, "timestamp") orelse {
            ctx.response_status = "400 Bad Request";
            ctx.response_body = "{\"error\":\"missing timestamp\"}";
            return;
        };
        const nonce = parseQueryParam(ctx.target, "nonce") orelse {
            ctx.response_status = "400 Bad Request";
            ctx.response_body = "{\"error\":\"missing nonce\"}";
            return;
        };
        if (!isFreshSignedWebhookTimestamp(timestamp)) {
            ctx.response_status = "403 Forbidden";
            ctx.response_body = "{\"error\":\"stale timestamp\"}";
            return;
        }

        if (!channels.wecom.verifySignature(secure_token, timestamp, nonce, encrypted, msg_sig)) {
            ctx.response_status = "403 Forbidden";
            ctx.response_body = "{\"error\":\"invalid signature\"}";
            return;
        }

        const expected_receive_id: ?[]const u8 = if (secure_corp_id.len > 0) secure_corp_id else null;
        break :blk channels.wecom.decryptSecurePayload(
            ctx.req_allocator,
            secure_aes_key,
            encrypted,
            expected_receive_id,
        ) catch {
            ctx.response_status = "403 Forbidden";
            ctx.response_body = "{\"error\":\"decrypt failed\"}";
            return;
        };
    };
    defer ctx.req_allocator.free(inbound_payload);

    var inbound = channels.wecom.parseIncomingPayload(ctx.req_allocator, inbound_payload) catch {
        ctx.response_body = "{\"status\":\"parse_error\"}";
        return;
    } orelse {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    };
    defer inbound.deinit(ctx.req_allocator);

    if (wecom_allow_from.len > 0 and !channels.isAllowed(wecom_allow_from, inbound.sender)) {
        ctx.response_body = "{\"status\":\"unauthorized\"}";
        return;
    }

    var key_buf: [128]u8 = undefined;
    const session_key = wecomSessionKeyRouted(
        ctx.req_allocator,
        &key_buf,
        inbound.sender,
        ctx.config_opt,
        wecom_account_id,
    );

    if (ctx.state.event_bus) |eb| {
        var meta_buf: [320]u8 = undefined;
        const meta = std.fmt.bufPrint(&meta_buf, "{{\"account_id\":\"{s}\",\"peer_kind\":\"direct\",\"peer_id\":\"{s}\"}}", .{
            wecom_account_id,
            inbound.sender,
        }) catch null;
        _ = publishToBus(eb, ctx.state.allocator, "wecom", inbound.sender, inbound.sender, inbound.content, session_key, meta);
        ctx.response_body = "{\"status\":\"received\"}";
        return;
    }

    if (ctx.session_mgr_opt) |sm| {
        const reply: ?[]const u8 = sm.processInboundMessage(session_key, inbound.content, null) catch |err| blk: {
            if (wecom_cfg_opt) |wecom_cfg| {
                var wecom_ch = channels.wecom.WeComChannel.initFromConfig(ctx.req_allocator, wecom_cfg.*);
                wecom_ch.sendMessageAuto("", userFacingAgentError(err)) catch {};
            }
            break :blk null;
        };
        if (reply) |r| {
            defer ctx.root_allocator.free(r);
            if (wecom_cfg_opt) |wecom_cfg| {
                var wecom_ch = channels.wecom.WeComChannel.initFromConfig(ctx.req_allocator, wecom_cfg.*);
                wecom_ch.sendMessageAuto("", r) catch {};
            }
        }
    }

    ctx.response_body = "{\"status\":\"ok\"}";
}

fn handleQqWebhookRoute(ctx: *WebhookHandlerContext) void {
    if (!build_options.enable_channel_qq) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"qq channel disabled in this build\"}";
        return;
    }

    if (!std.mem.eql(u8, ctx.method, "POST")) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }
    if (!allowScopedWebhook(ctx.state, "qq", ctx.client_identifier)) {
        ctx.response_status = "429 Too Many Requests";
        ctx.response_body = "{\"error\":\"rate limited\"}";
        return;
    }

    const body = extractBody(ctx.raw_request) orelse {
        ctx.response_body = "{\"status\":\"received\"}";
        return;
    };
    const parsed_probe = std.json.parseFromSlice(std.json.Value, ctx.req_allocator, body, .{}) catch {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"invalid json payload\"}";
        return;
    };
    defer parsed_probe.deinit();

    const app_id_header = extractHeader(ctx.raw_request, "X-Bot-Appid");
    const qq_cfg = selectQqConfig(ctx.config_opt, ctx.target, app_id_header) orelse {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"qq not configured\"}";
        return;
    };

    if (qq_cfg.receive_mode != .webhook) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"qq webhook mode not enabled\"}";
        return;
    }

    if (app_id_header) |raw_app_id| {
        const app_id = std.mem.trim(u8, raw_app_id, " \t\r\n");
        if (app_id.len > 0 and !std.mem.eql(u8, app_id, qq_cfg.app_id)) {
            ctx.response_status = "401 Unauthorized";
            ctx.response_body = "{\"error\":\"invalid X-Bot-Appid\"}";
            return;
        }
    }

    var qq_channel = findQqRuntimeChannel(ctx.state, qq_cfg.account_id) orelse blk: {
        ctx.state.qq_channels.append(ctx.state.allocator, channels.qq.QQChannel.initFromConfig(ctx.state.allocator, qq_cfg.*)) catch {
            ctx.response_status = "500 Internal Server Error";
            ctx.response_body = "{\"error\":\"qq channel init failed\"}";
            return;
        };
        break :blk &ctx.state.qq_channels.items[ctx.state.qq_channels.items.len - 1];
    };

    if (qq_channel.buildWebhookValidationResponse(ctx.req_allocator, body) catch null) |challenge_resp| {
        ctx.response_body = challenge_resp;
        return;
    }

    const inbound_opt = qq_channel.parseWebhookPayload(ctx.req_allocator, body) catch {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    };

    if (inbound_opt) |inbound| {
        defer inbound.deinit(qq_channel.allocator);

        if (ctx.state.event_bus) |eb| {
            _ = publishToBus(
                eb,
                ctx.state.allocator,
                "qq",
                inbound.sender_id,
                inbound.chat_id,
                inbound.content,
                inbound.session_key,
                inbound.metadata_json,
            );
            ctx.response_body = "{\"status\":\"received\"}";
            return;
        }

        if (ctx.session_mgr_opt) |sm| {
            const routed_session_key: ?[]const u8 = qqSessionKeyRouted(ctx.req_allocator, &inbound, ctx.config_opt);
            defer if (routed_session_key) |owned| ctx.req_allocator.free(owned);
            const session_key = routed_session_key orelse inbound.session_key;
            const peer = qqPeerRefFromInbound(&inbound);
            const meta = inbound.metadata_json;
            const account_id = if (meta) |json| jsonStringField(json, "account_id") else null;
            const conversation_context = buildConversationContext(.{
                .channel = "qq",
                .account_id = account_id,
                .sender_id = inbound.sender_id,
                .delivery_chat_id = inbound.chat_id,
                .peer_id = if (peer) |resolved| resolved.id else null,
                .is_group = if (peer) |resolved| resolved.kind != .direct else null,
                .group_id = if (peer) |resolved| if (resolved.kind == .direct) null else resolved.id else null,
            });
            const reply: ?[]const u8 = sm.processInboundMessage(session_key, inbound.content, conversation_context) catch |err| blk: {
                qq_channel.sendMessage(inbound.chat_id, userFacingAgentError(err)) catch {};
                break :blk null;
            };
            if (reply) |r| {
                defer ctx.root_allocator.free(r);
                qq_channel.sendMessage(inbound.chat_id, r) catch {};
            }
        }
    }

    ctx.response_body = "{\"status\":\"ok\"}";
}

fn handleMaxWebhookRoute(ctx: *WebhookHandlerContext) void {
    if (!build_options.enable_channel_max) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"max channel disabled in this build\"}";
        return;
    }

    if (!std.mem.eql(u8, ctx.method, "POST")) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }
    if (!allowScopedWebhook(ctx.state, "max", ctx.client_identifier)) {
        ctx.response_status = "429 Too Many Requests";
        ctx.response_body = "{\"error\":\"rate limited\"}";
        return;
    }

    const body = extractBody(ctx.raw_request) orelse {
        ctx.response_body = "{\"status\":\"received\"}";
        return;
    };

    const secret_header = extractHeader(ctx.raw_request, "X-Max-Bot-Api-Secret");
    const max_cfg = selectMaxConfig(ctx.config_opt, ctx.target, secret_header) orelse {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"max not configured\"}";
        return;
    };

    if (max_cfg.mode != .webhook) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"max webhook mode not enabled\"}";
        return;
    }

    // Verify secret header if secret is configured
    if (max_cfg.webhook_secret) |secret| {
        if (secret.len > 0) {
            if (secret_header) |sig| {
                if (!std.mem.eql(u8, std.mem.trim(u8, sig, " \t\r\n"), secret)) {
                    ctx.response_status = "403 Forbidden";
                    ctx.response_body = "{\"error\":\"invalid secret\"}";
                    return;
                }
            } else {
                ctx.response_status = "403 Forbidden";
                ctx.response_body = "{\"error\":\"missing secret\"}";
                return;
            }
        }
    }

    // Parse the update JSON
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.req_allocator, body, .{}) catch {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"invalid json payload\"}";
        return;
    };
    defer parsed.deinit();

    var max_ch = channels.max.MaxChannel.initFromConfig(ctx.req_allocator, max_cfg.*);

    if (max_ch.processUpdate(ctx.req_allocator, parsed.value)) |inbound| {
        defer inbound.deinit(ctx.req_allocator);

        const reply_target = inbound.reply_target orelse inbound.sender;
        const peer_id = if (inbound.is_group) reply_target else inbound.sender;
        var kb: [192]u8 = undefined;
        const sk = maxSessionKeyRouted(
            ctx.req_allocator,
            &kb,
            inbound.sender,
            reply_target,
            inbound.is_group,
            ctx.config_opt,
            max_cfg.account_id,
        );
        const peer_kind: []const u8 = if (inbound.is_group) "group" else "direct";

        if (ctx.state.event_bus) |eb| {
            var meta_buf: [384]u8 = undefined;
            const meta = std.fmt.bufPrint(&meta_buf, "{{\"account_id\":\"{s}\",\"peer_kind\":\"{s}\",\"peer_id\":\"{s}\"}}", .{
                max_cfg.account_id,
                peer_kind,
                peer_id,
            }) catch null;
            _ = publishToBus(eb, ctx.state.allocator, "max", inbound.sender, reply_target, inbound.content, sk, meta);
            ctx.response_body = "{\"status\":\"received\"}";
            return;
        }

        if (ctx.session_mgr_opt) |sm| {
            channels.max.setInteractiveOwnerContext(inbound.sender);
            defer channels.max.setInteractiveOwnerContext(null);
            const conversation_context: ?ConversationContext = simpleConversationContext(
                "max",
                max_cfg.account_id,
                peer_id,
                reply_target,
                inbound.is_group,
                if (inbound.is_group) reply_target else null,
            );
            const reply: ?[]const u8 = sm.processInboundMessage(sk, inbound.content, conversation_context) catch |err| blk: {
                max_ch.sendMessage(reply_target, userFacingAgentError(err)) catch {};
                break :blk null;
            };
            if (reply) |r| {
                defer ctx.root_allocator.free(r);
                max_ch.sendMessage(reply_target, r) catch {};
            }
        }
    }

    ctx.response_body = "{\"status\":\"ok\"}";
}

test "handleWhatsAppWebhookRoute rejects malformed JSON before sender extraction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const whatsapp_accounts = [_]config_types.WhatsAppConfig{
        .{
            .account_id = "main",
            .phone_number_id = "phone-1",
            .access_token = "token",
            .verify_token = "verify",
            .allow_from = &.{"user-1"},
        },
    };

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .channels = .{ .whatsapp = &whatsapp_accounts },
    };

    const raw_request = "POST /whatsapp HTTP/1.1\r\nContent-Length: 27\r\n\r\n{\"from\":\"user-1\",\"text\":\"hi\"";

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();

    var ctx = WebhookHandlerContext{
        .root_allocator = allocator,
        .req_allocator = allocator,
        .raw_request = raw_request,
        .method = "POST",
        .target = "/whatsapp",
        .config_opt = &cfg,
        .state = &state,
        .session_mgr_opt = null,
    };

    handleWhatsAppWebhookRoute(&ctx);
    try std.testing.expectEqualStrings("400 Bad Request", ctx.response_status);
    try std.testing.expectEqualStrings("{\"error\":\"invalid json payload\"}", ctx.response_body);
}

fn handleTeamsWebhookRoute(ctx: *WebhookHandlerContext) void {
    if (!build_options.enable_channel_teams) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"teams channel disabled in this build\"}";
        return;
    }

    const is_post = std.mem.eql(u8, ctx.method, "POST");
    if (!is_post) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }

    if (!allowScopedWebhook(ctx.state, "teams", ctx.client_identifier)) {
        ctx.response_status = "429 Too Many Requests";
        ctx.response_body = "{\"error\":\"rate limited\"}";
        return;
    }

    // Get config
    const config = ctx.config_opt orelse {
        ctx.response_status = "500 Internal Server Error";
        ctx.response_body = "{\"error\":\"no config\"}";
        return;
    };
    if (config.channels.teams.len == 0) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"teams not configured\"}";
        return;
    }

    const body = extractBody(ctx.raw_request) orelse {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"empty body\"}";
        return;
    };
    if (!isJsonObjectPayload(ctx.req_allocator, body)) {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"invalid json payload\"}";
        return;
    }

    // Parse Bot Framework Activity JSON
    const activity_type = jsonStringField(body, "type") orelse {
        ctx.response_status = "202 Accepted";
        ctx.response_body = "{\"status\":\"accepted\"}";
        return;
    };

    // Only process "message" activities
    if (!std.mem.eql(u8, activity_type, "message")) {
        ctx.response_status = "202 Accepted";
        ctx.response_body = "{\"status\":\"accepted\"}";
        return;
    }

    const text = jsonStringField(body, "text") orelse {
        ctx.response_status = "202 Accepted";
        ctx.response_body = "{\"status\":\"accepted\"}";
        return;
    };

    // Extract and validate serviceUrl — this is untrusted input from the webhook payload.
    // Only allow HTTPS URLs to trusted Bot Framework domains to prevent SSRF.
    const service_url = jsonStringField(body, "serviceUrl") orelse {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"missing serviceUrl\"}";
        return;
    };
    const channel_id = jsonStringField(body, "channelId") orelse {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"missing channelId\"}";
        return;
    };
    if (!isValidBotFrameworkServiceUrl(service_url)) {
        std.log.scoped(.teams).warn("Teams webhook rejected untrusted serviceUrl: {s}", .{service_url});
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"untrusted serviceUrl\"}";
        return;
    }

    // Resolve Teams config: match by tenant_id from channelData if multiple
    // accounts are configured, otherwise fall back to primary.
    const payload_tenant_id = teamsPayloadTenantId(body);
    const teams_cfg = blk: {
        if (payload_tenant_id) |tid| {
            for (config.channels.teams) |tc| {
                if (std.mem.eql(u8, tc.tenant_id, tid)) break :blk tc;
            }
        }
        break :blk config.channels.teamsPrimary() orelse {
            ctx.response_status = "404 Not Found";
            ctx.response_body = "{\"error\":\"no matching teams config for tenant\"}";
            return;
        };
    };

    const auth_header = extractHeader(ctx.raw_request, "Authorization");
    const bearer = if (auth_header) |header| extractBearerToken(header) else null;
    const bearer_token = bearer orelse {
        ctx.response_status = "403 Forbidden";
        ctx.response_body = "{\"error\":\"forbidden\"}";
        return;
    };
    ctx.state.teams_auth_cache.verifyConnectorToken(
        ctx.state.allocator,
        bearer_token,
        teams_cfg.client_id,
        service_url,
        channel_id,
    ) catch |err| {
        std.log.scoped(.teams).warn("Teams webhook JWT validation failed: {}", .{err});
        ctx.response_status = "403 Forbidden";
        ctx.response_body = "{\"error\":\"forbidden\"}";
        return;
    };

    if (teams_cfg.webhook_secret) |secret| {
        const header_val = extractHeader(ctx.raw_request, "X-Webhook-Secret");
        if (header_val == null or !std.mem.eql(u8, std.mem.trim(u8, header_val.?, " \t\r\n"), secret)) {
            ctx.response_status = "401 Unauthorized";
            ctx.response_body = "{\"error\":\"unauthorized\"}";
            return;
        }
    }

    // For nested fields, use manual parsing since jsonStringField doesn't handle nesting
    const conversation_id = teamsNestedField(body, "conversation", "id") orelse {
        ctx.response_status = "400 Bad Request";
        ctx.response_body = "{\"error\":\"missing conversation.id\"}";
        return;
    };

    const from_id = teamsNestedField(body, "from", "id") orelse "unknown";
    const from_name = teamsNestedField(body, "from", "name");

    const peer_info = teamsPeerRef(body, from_id, conversation_id);
    var key_buf: [256]u8 = undefined;
    const sk = teamsSessionKeyRouted(
        ctx.req_allocator,
        &key_buf,
        config,
        body,
        teams_cfg.account_id,
        teams_cfg.tenant_id,
        conversation_id,
        from_id,
    );

    // Build chat_id as "serviceUrl|conversationId" for outbound routing
    var chat_buf: [512]u8 = undefined;
    const chat_id = std.fmt.bufPrint(&chat_buf, "{s}|{s}", .{ service_url, conversation_id }) catch {
        ctx.response_status = "500 Internal Server Error";
        ctx.response_body = "{\"error\":\"chat_id overflow\"}";
        return;
    };

    // Build metadata JSON
    var meta_buf: [512]u8 = undefined;
    const metadata = std.fmt.bufPrint(
        &meta_buf,
        "{{\"account_id\":\"{s}\",\"service_url\":\"{s}\",\"conversation_id\":\"{s}\",\"from_id\":\"{s}\",\"peer_kind\":\"{s}\",\"peer_id\":\"{s}\",\"is_dm\":{s}}}",
        .{
            teams_cfg.account_id,
            service_url,
            conversation_id,
            from_id,
            if (peer_info.is_dm) "direct" else "channel",
            peer_info.peer.id,
            if (peer_info.is_dm) "true" else "false",
        },
    ) catch null;

    // Capture conversation reference if this is the notification channel
    if (teams_cfg.notification_channel_id) |notif_id| {
        if (std.mem.eql(u8, conversation_id, notif_id)) {
            teamsStoreConversationRef(config, service_url, conversation_id);
        }
    }

    const conversation_context = buildConversationContext(.{
        .channel = "teams",
        .account_id = teams_cfg.account_id,
        .sender_uuid = from_id,
        .sender_name = from_name,
        .delivery_chat_id = chat_id,
        .peer_id = peer_info.peer.id,
        .is_group = !peer_info.is_dm,
        .group_id = if (peer_info.is_dm) null else peer_info.peer.id,
    });

    if (ctx.state.event_bus) |eb| {
        _ = publishToBus(eb, ctx.state.allocator, "teams", from_id, chat_id, text, sk, metadata);
    } else if (ctx.session_mgr_opt) |sm| {
        const reply: ?[]const u8 = sm.processInboundMessage(sk, text, conversation_context) catch blk: {
            break :blk null;
        };
        if (reply) |r| {
            defer ctx.root_allocator.free(r);
            var outbound_ch = channels.teams.TeamsChannel.initFromConfig(ctx.req_allocator, teams_cfg);
            const aid = outbound_ch.sendMessage(service_url, conversation_id, r) catch |err| blk: {
                std.log.scoped(.teams).warn("Teams direct-reply sendMessage failed: {}", .{err});
                break :blk null;
            };
            if (aid) |id| ctx.req_allocator.free(id);
        }
    }

    ctx.response_status = "202 Accepted";
    ctx.response_body = "{\"status\":\"accepted\"}";
}

/// Extract a nested string field from JSON: obj.outer.inner
/// Uses jsonStringField on the nested object substring. Handles arbitrary
/// nesting depth within the outer value by tracking brace depth, and skips
/// over braces inside JSON string literals to avoid false matches.
fn teamsNestedField(json: []const u8, outer: []const u8, inner: []const u8) ?[]const u8 {
    const nested_json = jsonObjectFieldSlice(json, outer) orelse return null;
    return jsonStringField(nested_json, inner);
}

fn teamsPayloadTenantId(json: []const u8) ?[]const u8 {
    if (teamsNestedField(json, "channelData", "tenant")) |tenant_id| return tenant_id;
    const channel_data = jsonObjectFieldSlice(json, "channelData") orelse return null;
    return teamsNestedField(channel_data, "tenant", "id");
}

fn jsonObjectFieldSlice(json: []const u8, key: []const u8) ?[]const u8 {
    // Find the outer object key
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    // Find the opening brace of the nested object
    var i: usize = 0;
    while (i < after_key.len and after_key[i] != '{') : (i += 1) {}
    if (i >= after_key.len) return null;

    // Find the matching closing brace, respecting nesting and string literals
    const obj_start = i;
    var depth: usize = 0;
    var in_string = false;
    while (i < after_key.len) : (i += 1) {
        const c = after_key[i];
        if (in_string) {
            if (c == '\\' and i + 1 < after_key.len) {
                i += 1; // skip escaped char
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        if (c == '"') {
            in_string = true;
        } else if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            depth -= 1;
            if (depth == 0) {
                i += 1;
                break;
            }
        }
    }
    return after_key[obj_start..i];
}

/// Validate that a serviceUrl from a Bot Framework Activity is a trusted Microsoft domain.
/// Prevents SSRF by only allowing outbound requests to known Bot Framework endpoints.
fn isValidBotFrameworkServiceUrl(url: []const u8) bool {
    // Must be HTTPS
    if (!std.mem.startsWith(u8, url, "https://")) return false;

    // Extract hostname (after "https://", before "/" or ":")
    const host_start = "https://".len;
    const rest = url[host_start..];
    var host_end: usize = rest.len;
    for (rest, 0..) |c, j| {
        if (c == '/' or c == ':') {
            host_end = j;
            break;
        }
    }
    const host = rest[0..host_end];
    if (host.len == 0) return false;

    const allowed_exact_hosts = [_][]const u8{
        "smba.trafficmanager.net",
    };
    for (allowed_exact_hosts) |exact_host| {
        if (asciiEqlIgnoreCase(host, exact_host)) return true;
    }

    // Allow known Bot Framework service domains, including national cloud variants.
    const allowed_suffixes = [_][]const u8{
        ".botframework.com",
        ".botframework.azure.us",
        ".teams.microsoft.com",
        ".teams.microsoft.us",
        ".skype.com",
    };
    for (allowed_suffixes) |suffix| {
        if (asciiEndsWithIgnoreCase(host, suffix)) return true;
    }
    return false;
}

/// Store Teams conversation reference (serviceUrl + conversationId) to a JSON file
/// for proactive messaging. Uses config_dir from the config.
fn teamsStoreConversationRef(config: *const Config, service_url: []const u8, conversation_id: []const u8) void {
    const config_dir = std_compat.fs.path.dirname(config.config_path) orelse return;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/teams_conversation_ref.json", .{config_dir}) catch return;

    var body_buf: [1024]u8 = undefined;
    const body = std.fmt.bufPrint(
        &body_buf,
        "{{\"serviceUrl\":\"{s}\",\"conversationId\":\"{s}\"}}",
        .{ service_url, conversation_id },
    ) catch return;

    const file = fs_compat.createPath(path, .{}) catch |err| {
        std.log.scoped(.teams).warn("Failed to save conversation reference: {}", .{err});
        return;
    };
    defer file.close();
    file.writeAll(body) catch |err| {
        std.log.scoped(.teams).warn("Failed to write conversation reference: {}", .{err});
    };
    std.log.scoped(.teams).info("Conversation reference saved to {s}", .{path});
}

fn applyRuntimeProviderOverrides(config: *const Config) !void {
    try http_util.setProxyOverride(config.http_request.proxy);
    try providers.setApiErrorLimitOverride(config.diagnostics.api_error_max_chars);
}

const A2aStreamingWorker = struct {
    allocator: std.mem.Allocator,
    body: []u8,
    stream: std_compat.net.Stream,
    registry: *a2a.TaskRegistry,
    session_mgr: *session_mod.SessionManager,

    fn run(self: *@This()) void {
        defer self.stream.close();
        defer self.allocator.free(self.body);
        defer self.allocator.destroy(self);
        a2a.handleStreamingRpc(self.allocator, self.body, &self.stream, self.registry, self.session_mgr);
    }
};

fn spawnA2aStreamingWorker(
    allocator: std.mem.Allocator,
    body: []const u8,
    stream: std_compat.net.Stream,
    registry: *a2a.TaskRegistry,
    session_mgr: *session_mod.SessionManager,
) !void {
    const worker = try allocator.create(A2aStreamingWorker);
    errdefer allocator.destroy(worker);

    const owned_body = try allocator.dupe(u8, body);
    errdefer allocator.free(owned_body);

    worker.* = .{
        .allocator = allocator,
        .body = owned_body,
        .stream = stream,
        .registry = registry,
        .session_mgr = session_mgr,
    };

    const thread = try std.Thread.spawn(
        .{ .stack_size = thread_stacks.SESSION_TURN_STACK_SIZE },
        A2aStreamingWorker.run,
        .{worker},
    );
    thread.detach();
}

// ── Shared scheduler state for cross-thread access ───────────────

var g_shared_scheduler: ?*cron_mod.CronScheduler = null;
// Protects install/remove of the global scheduler pointer only.
// Live request/daemon access must use GatewayState.scheduler_mutex.
var g_shared_scheduler_mutex: std_compat.sync.Mutex = .{};
var g_state_mutex: std_compat.sync.Mutex = .{};
var g_state_ptr: ?*GatewayState = null;

pub fn lockSharedScheduler() void {
    g_shared_scheduler_mutex.lock();
}

pub fn unlockSharedScheduler() void {
    g_shared_scheduler_mutex.unlock();
}

pub fn setSharedScheduler(sched: *cron_mod.CronScheduler) void {
    g_shared_scheduler_mutex.lock();
    defer g_shared_scheduler_mutex.unlock();
    g_shared_scheduler = sched;
    // Also wire into GatewayState.scheduler so /cron/run and queue worker can find it.
    g_state_mutex.lock();
    defer g_state_mutex.unlock();
    if (g_state_ptr) |gs| {
        gs.scheduler_mutex.lock();
        defer gs.scheduler_mutex.unlock();
        gs.scheduler = sched;
    }
}

pub fn clearSharedScheduler() void {
    g_shared_scheduler_mutex.lock();
    defer g_shared_scheduler_mutex.unlock();
    g_shared_scheduler = null;
    g_state_mutex.lock();
    defer g_state_mutex.unlock();
    if (g_state_ptr) |gs| {
        gs.scheduler_mutex.lock();
        defer gs.scheduler_mutex.unlock();
        gs.scheduler = null;
    }
}

/// Route a scheduled job ID to the run queue worker.
/// Called by the daemon scheduler thread after collectDueJobs().
/// Takes ownership of id_owned — frees it on error.
pub fn enqueueScheduledJob(id_owned: []const u8) !void {
    g_state_mutex.lock();
    defer g_state_mutex.unlock();
    const gs = g_state_ptr orelse return error.NoGatewayState;
    try gs.enqueueRunJob(id_owned);
}

/// Tick the DB-direct scheduler: find due jobs, insert into cron_run_queue,
/// advance next_run_secs. Returns number of jobs enqueued, or 0 if no backend.
/// The daemon scheduler thread calls this instead of collectDueJobs when
/// cron_db_backend is initialized.
///
/// IMPORTANT: g_state_mutex is held only to read the backend pointer, then
/// released before the DB operation. This prevents the mutex from blocking
/// HTTP request handlers during the (potentially slow) SQLite transaction.
pub fn tickDbScheduler(now: i64) usize {
    // Snapshot the backend pointer under the lock, then release immediately.
    const be_ptr: ?*cron_db_mod.DbCronBackend = blk: {
        g_state_mutex.lock();
        defer g_state_mutex.unlock();
        const gs = g_state_ptr orelse break :blk null;
        if (gs.cron_db_backend) |*be| break :blk be;
        break :blk null;
    };
    const be = be_ptr orelse return 0;

    // DB tick runs outside the g_state_mutex — safe because DbCronBackend
    // opens its own connection per call (WAL mode, multi-reader safe).
    const n = be.backend().tick(now) catch |err| {
        std.log.scoped(.scheduler).warn("DbCronBackend.tick failed: {s}", .{@errorName(err)});
        return 0;
    };

    if (n > 0) {
        g_state_mutex.lock();
        defer g_state_mutex.unlock();
        if (g_state_ptr) |gs| {
            gs.run_queue_mutex.lock();
            defer gs.run_queue_mutex.unlock();
            gs.run_queue_cond.signal();
        }
    }
    return n;
}

/// Returns true if a DB-backed CronBackend is active in the gateway state.
/// The daemon scheduler thread uses this to decide whether to use tickDbScheduler
/// or the legacy in-memory collectDueJobs path.
pub fn hasDbScheduler() bool {
    g_state_mutex.lock();
    defer g_state_mutex.unlock();
    const gs = g_state_ptr orelse return false;
    return gs.cron_db_backend != null;
}

/// Returns the live DbCronBackend vtable value used by the gateway for the
/// DB-direct scheduler path, or null if the gateway has not yet initialized
/// the backend. Safe to call from any thread — takes g_state_mutex for the
/// snapshot, then releases before returning. The fat pointer's inner *ptr
/// aliases gateway state and is only valid while the gateway is running;
/// callers (daemon CronTicker) must not outlive the gateway.
pub fn sharedDbBackend() ?cron_backend_mod.CronBackend {
    g_state_mutex.lock();
    defer g_state_mutex.unlock();
    const gs = g_state_ptr orelse return null;
    if (gs.cron_db_backend) |*be| return be.backend();
    return null;
}

/// Test-only: install a GatewayState pointer so hasDbScheduler() /
/// sharedDbBackend() observe a caller-owned state. Paired with
/// clearStatePtrForTest(). The caller owns the state struct and must keep it
/// alive until clearStatePtrForTest() returns. Only referenced from tests.
pub fn setStatePtrForTest(gs: *GatewayState) void {
    comptime std.debug.assert(builtin.is_test);
    g_state_mutex.lock();
    defer g_state_mutex.unlock();
    g_state_ptr = gs;
}

pub fn clearStatePtrForTest() void {
    comptime std.debug.assert(builtin.is_test);
    g_state_mutex.lock();
    defer g_state_mutex.unlock();
    g_state_ptr = null;
}

/// Wake the run queue worker without pushing to the in-memory ArrayList.
/// Used by the DB-direct scheduler path: jobs are already in cron_run_queue,
/// we just need the worker to wake up and drain the table.
pub fn signalRunQueueWorker() void {
    g_state_mutex.lock();
    defer g_state_mutex.unlock();
    const gs = g_state_ptr orelse return;
    gs.run_queue_mutex.lock();
    defer gs.run_queue_mutex.unlock();
    gs.run_queue_cond.signal();
}

/// RAII guard that holds GatewayState.scheduler_mutex for the duration of a
/// daemon scheduler tick (reload → snapshot → tick → save).
///
/// Concurrency contract
/// ────────────────────
/// Two distinct serialisation layers protect CronScheduler:
///   1. runQueueWorker (this file) serialises *manual* /cron/run requests so
///      runs A and B never execute concurrently.
///   2. This guard serialises the *daemon scheduler loop* against every HTTP
///      handler and the queue worker.  Without it, reloadJobs() (which swaps
///      scheduler.jobs via std.mem.swap) and tick() (which mutates next_run_secs)
///      would race against live getMutableJob pointers held by the other actors.
///
/// Obtain via acquireSchedulerGuard(). Release with `defer guard.release()`.
pub const SchedulerGuard = struct {
    gs: ?*GatewayState,

    /// Release the lock. Safe to call more than once; subsequent calls are no-ops.
    pub fn release(self: *SchedulerGuard) void {
        if (self.gs) |s| {
            s.scheduler_mutex.unlock();
            self.gs = null;
        }
    }
};

/// Acquire GatewayState.scheduler_mutex and return a SchedulerGuard.
/// If no gateway is running the guard is a no-op (gs == null).
/// Usage:
///   var guard = gateway_mod.acquireSchedulerGuard();
///   defer guard.release();
pub fn acquireSchedulerGuard() SchedulerGuard {
    g_state_mutex.lock();
    defer g_state_mutex.unlock();
    if (g_state_ptr) |gs| {
        gs.scheduler_mutex.lock();
        return .{ .gs = gs };
    }
    return .{ .gs = null };
}

/// Acquire the gateway's scheduler_mutex so the daemon's scheduler thread
/// can safely reload/tick/save without racing the HTTP handlers and queue worker.
/// Returns the locked GatewayState pointer (to be passed to unlockSharedSchedulerMutex),
/// or null if no gateway is running.
pub fn lockSharedSchedulerMutex() ?*GatewayState {
    var g = acquireSchedulerGuard();
    const gs = g.gs;
    g.gs = null; // transfer ownership to caller
    return gs;
}

/// Release the gateway's scheduler_mutex. Pass the value returned by lockSharedSchedulerMutex.
/// No-op if null (gateway was not running when lock was called).
pub fn unlockSharedSchedulerMutex(gs: ?*GatewayState) void {
    if (gs) |s| s.scheduler_mutex.unlock();
}

fn nextAcceptSleepMs(previous_sleep_ms: u64, err: anyerror) u64 {
    if (err == error.WouldBlock) return ACCEPT_POLL_INTERVAL_MS;
    const base = if (previous_sleep_ms < ACCEPT_POLL_INTERVAL_MS) ACCEPT_POLL_INTERVAL_MS else previous_sleep_ms;
    return @min(base * 2, ACCEPT_ERROR_BACKOFF_MAX_MS);
}

/// Run the HTTP gateway. Binds to host:port and serves HTTP requests.
/// Endpoints: GET /health, GET /ready, GET /status, GET /doctor, POST /pair, POST /logout, POST /webhook, GET|POST /whatsapp, POST /telegram, POST /slack/events, POST /line, POST /lark, GET|POST /wechat, GET|POST /wecom, POST /qq, POST /max
/// If config_ptr is null, loads config internally (for backward compatibility).
/// `tunnel_url_opt` should contain the daemon's active external tunnel URL when
/// one is available; a non-null value allows non-loopback binds without setting
/// `gateway.allow_public_bind=true`.
pub fn run(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    config_ptr: ?*const Config,
    event_bus: ?*bus_mod.Bus,
    tunnel_url_opt: ?[]const u8,
) !void {
    health.markComponentOk("gateway");

    var state = GatewayState.init(allocator);
    defer state.deinit();
    state.event_bus = event_bus;

    // Resolve and store the cron DB path for DB-direct worker/handler access.
    // Only populated when SQLite is compiled in; otherwise the worker and handlers
    // must stay on the in-memory scheduler path.
    state.cron_db_path = if (build_options.enable_sqlite)
        cron_mod.getCronDbPathZ(allocator) catch null
    else
        null;
    defer if (state.cron_db_path) |p| allocator.free(p);

    // Workspace dir for DB-backed job children — mirrors shell_cwd of the legacy scheduler path.
    if (config_ptr) |cfg| {
        if (cfg.workspace_dir.len > 0) state.cron_workspace_dir = cfg.workspace_dir;
    }

    // Initialize DbCronBackend so runQueueWorker gets atomic dequeue+claim.
    if (state.cron_db_path) |db_path| {
        state.cron_db_backend = cron_db_mod.DbCronBackend.init(allocator, db_path) catch null;
    }
    defer if (state.cron_db_backend) |*be| be.deinit();

    // Wire alert delivery for DB-backed skill job failures.
    if (config_ptr) |cfg| {
        if (cfg.scheduler.alert_channel != null and cfg.scheduler.alert_to != null) {
            state.alert_delivery = .{
                .mode = .always,
                .channel = cfg.scheduler.alert_channel,
                .account_id = cfg.scheduler.alert_account,
                .to = cfg.scheduler.alert_to,
                .best_effort = true,
            };
        }
    }

    // Stack storage for audit logger. Declared early so it can be wired into the heap policy
    // in the early-construction block (before startRunQueue). Lifetime covers the whole run()
    // function (until gateway shutdown), which is sufficient for audit_ctx pointers stored in
    // the long-lived heap policy.
    var sec_audit_log_opt: ?audit_mod.AuditLogger = null;

    // Security policy must be constructed *before* starting any shell-capable workers (DB-direct cron, etc.).
    // Do not gate this on local-agent/A2A/webhook_sync — cron shell jobs need enforcement regardless of runtime mode.
    if (config_ptr) |cfg| {
        // Heap-allocate the RateTracker so it outlives this stack frame.
        const tracker_ptr = allocator.create(security.RateTracker) catch null;
        if (tracker_ptr) |t| {
            t.* = security.RateTracker.init(allocator, cfg.autonomy.max_actions_per_hour);
            state.security_tracker = t;

            const pol = security.SecurityPolicy{
                .autonomy = cfg.autonomy.level,
                .workspace_dir = cfg.workspace_dir,
                .workspace_only = cfg.autonomy.workspace_only,
                .allowed_commands = security.resolveAllowedCommands(cfg.autonomy.level, cfg.autonomy.allowed_commands),
                .max_actions_per_hour = cfg.autonomy.max_actions_per_hour,
                .require_approval_for_medium_risk = cfg.autonomy.require_approval_for_medium_risk,
                .block_high_risk_commands = cfg.autonomy.block_high_risk_commands,
                .block_medium_risk_commands = cfg.autonomy.block_medium_risk_commands,
                .allow_raw_url_chars = cfg.autonomy.allow_raw_url_chars,
                .tracker = t,
            };

            // Heap-allocate the policy so the pointer we store on state is always valid.
            const pol_ptr = allocator.create(security.SecurityPolicy) catch null;
            if (pol_ptr) |p| {
                p.* = pol;
                state.security_policy = p;

                // Wire audit logger into the *single* early heap policy if enabled.
                // This ensures cron shell jobs (which go through state.security_policy)
                // and agent/runtime code (which receives the same pointer) share one
                // policy + one tracker + one audit sink. Previously audit was only on
                // a second stack policy created later.
                if (cfg.security.audit.enabled) {
                    const audit_base = std.fs.path.dirname(cfg.config_path) orelse ".";
                    if (audit_mod.AuditLogger.init(allocator, .{
                        .enabled = true,
                        .log_path = if (cfg.security.audit.log_path.len > 0) cfg.security.audit.log_path else "policy_audit.jsonl",
                        .max_size_mb = cfg.security.audit.max_size_mb,
                    }, audit_base)) |al| {
                        sec_audit_log_opt = al;
                        p.*.audit_fn = auditPolicyCallback;
                        p.*.audit_ctx = &sec_audit_log_opt.?;
                    } else |_| {}
                }
            }
        }
    }

    // Start the sequential job run queue worker thread.
    state.startRunQueue() catch |err| {
        std.log.scoped(.gateway).warn("failed to start run queue worker: {s}", .{@errorName(err)});
    };

    // Register this GatewayState as the active state so the scheduler thread
    // can set its scheduler pointer via setSharedScheduler/clearSharedScheduler.
    g_state_mutex.lock();
    g_state_ptr = &state;
    g_state_mutex.unlock();
    defer {
        g_state_mutex.lock();
        if (g_state_ptr == &state) g_state_ptr = null;
        g_state_mutex.unlock();
    }

    var owned_config: ?Config = null;
    var config_opt: ?*const Config = null;
    if (config_ptr) |cfg| {
        config_opt = cfg;
    } else {
        owned_config = Config.load(allocator) catch null;
        if (owned_config) |*c| {
            config_opt = c;
        }
    }
    defer if (owned_config) |*c| c.deinit();
    const max_body = if (config_opt) |cfg| cfg.gateway.max_body_size_bytes else MAX_BODY_SIZE;
    const request_timeout_secs = effectiveRequestReadTimeoutSecs(config_opt);
    try ensureSafeGatewayBind(host, config_opt, tunnel_url_opt);
    const public_bind = isPublicBindHost(host);

    // Provider runtime bundle (primary + reliability wrapper) must outlive the accept loop.
    // (from feat/cron-subagent: includes subagent_manager, sec_audit_log, cron_db paths)
    var provider_bundle_opt: ?providers.runtime_bundle.RuntimeProviderBundle = null;
    var session_mgr_opt: ?session_mod.SessionManager = null;
    var tools_slice: []const tools_mod.Tool = &.{};
    var mem_rt: ?memory_mod.MemoryRuntime = null;
    var bootstrap_provider_opt: ?bootstrap_mod.BootstrapProvider = null;
    var subagent_manager_opt: ?*subagent_mod.SubagentManager = null;

    // Local request-response agent runtime (from upstream, for lazy A2A/gateway init)
    var local_agent_runtime_opt: ?LocalAgentRuntime = null;

    var gateway_thread_observer = GatewayThreadObserver.init(allocator);
    defer gateway_thread_observer.deinit();
    var runtime_observer: ?*observability.RuntimeObserver = null;
    defer if (runtime_observer) |obs| obs.destroy();
    var a2a_registry = a2a.TaskRegistry.init(allocator);
    defer a2a_registry.deinit();
    const needs_local_agent = event_bus == null;

    if (config_opt) |cfg_ptr| {
        const cfg = cfg_ptr;
        try applyRuntimeProviderOverrides(cfg);
        runtime_observer = try observability.RuntimeObserver.create(
            allocator,
            .{
                .workspace_dir = cfg.workspace_dir,
                .backend = cfg.diagnostics.backend,
                .otel_endpoint = cfg.diagnostics.otel_endpoint,
                .otel_service_name = cfg.diagnostics.otel_service_name,
            },
            cfg.diagnostics.otel_headers,
            &.{gateway_thread_observer.observer()},
        );
        state.rate_limiter = GatewayRateLimiter.init(
            cfg.gateway.pair_rate_limit_per_minute,
            cfg.gateway.webhook_rate_limit_per_minute,
        );
        state.idempotency = IdempotencyStore.init(cfg.gateway.idempotency_ttl_secs);
        state.pairing_guard = try PairingGuard.init(
            allocator,
            cfg.gateway.require_pairing,
            cfg.gateway.paired_tokens,
        );
        if (cfg.channels.telegramPrimary()) |tg_cfg| {
            state.telegram_bot_token = tg_cfg.bot_token;
            state.telegram_allow_from = tg_cfg.allow_from;
            state.telegram_account_id = tg_cfg.account_id;
        }
        if (cfg.channels.whatsappPrimary()) |wa_cfg| {
            state.whatsapp_verify_token = wa_cfg.verify_token;
            state.whatsapp_app_secret = wa_cfg.app_secret orelse "";
            state.whatsapp_access_token = wa_cfg.access_token;
            state.whatsapp_allow_from = wa_cfg.allow_from;
            state.whatsapp_group_allow_from = wa_cfg.group_allow_from;
            state.whatsapp_groups = wa_cfg.groups;
            state.whatsapp_group_policy = wa_cfg.group_policy;
            state.whatsapp_account_id = wa_cfg.account_id;
        }
        if (cfg.channels.linePrimary()) |line_cfg| {
            state.line_channel_secret = line_cfg.channel_secret;
            state.line_access_token = line_cfg.access_token;
            state.line_allow_from = line_cfg.allow_from;
            state.line_account_id = line_cfg.account_id;
        }
        if (cfg.channels.larkPrimary()) |lark_cfg| {
            state.lark_verification_token = lark_cfg.verification_token orelse "";
            state.lark_app_id = lark_cfg.app_id;
            state.lark_app_secret = lark_cfg.app_secret;
            state.lark_allow_from = lark_cfg.allow_from;
            state.lark_account_id = lark_cfg.account_id;
        }
        if (cfg.channels.wechatPrimary()) |wechat_cfg| {
            state.wechat_allow_from = wechat_cfg.allow_from;
            state.wechat_account_id = wechat_cfg.account_id;
            state.wechat_callback_token = wechat_cfg.callback_token;
            state.wechat_encoding_aes_key = wechat_cfg.encoding_aes_key orelse "";
            state.wechat_app_id = wechat_cfg.app_id orelse "";
        }
        if (cfg.channels.wecomPrimary()) |wecom_cfg| {
            state.wecom_allow_from = wecom_cfg.allow_from;
            state.wecom_account_id = wecom_cfg.account_id;
            state.wecom_callback_token = wecom_cfg.callback_token orelse "";
            state.wecom_encoding_aes_key = wecom_cfg.encoding_aes_key orelse "";
            state.wecom_corp_id = wecom_cfg.corp_id orelse "";
        }
        if (build_options.enable_channel_qq) {
            for (cfg.channels.qq) |qq_cfg| {
                try state.qq_channels.append(allocator, channels.qq.QQChannel.initFromConfig(allocator, qq_cfg));
            }
        }

        // Merged condition: support both our cron/subagent/A2A needs and upstream's webhook_sync_for_workers lazy runtime.
        // In daemon mode, inbound is usually on bus, but A2A + webhook_sync + our subagent/cron paths need the local runtime.
        if (needs_local_agent or cfg.a2a.enabled or cfg.gateway.webhook_sync_for_workers) {
            // Unified early heap policy (created before startRunQueue, with tracker + optional audit wiring)
            // is the single source of truth for *all* paths: cron DB-direct shell jobs (via state.security_policy),
            // legacy queued, and agent/runtime/session/tools (passed explicitly below). No second policy/tracker.
            provider_bundle_opt = try providers.runtime_bundle.RuntimeProviderBundle.init(allocator, cfg);

            if (provider_bundle_opt) |*bundle| {
                const provider_i: providers.Provider = bundle.provider();
                const resolved_api_key = bundle.primaryApiKey();

                // Optional memory backend.
                mem_rt = memory_mod.initRuntime(allocator, &cfg.memory, cfg.workspace_dir);
                const mem_opt: ?memory_mod.Memory = if (mem_rt) |rt| rt.memory else null;

                bootstrap_provider_opt = bootstrap_mod.createProvider(
                    allocator,
                    cfg.memory.backend,
                    mem_opt,
                    cfg.workspace_dir,
                ) catch null;

                // Subagent manager (core of feat/cron-subagent)
                const subagent_manager = allocator.create(subagent_mod.SubagentManager) catch null;
                if (subagent_manager) |mgr| {
                    mgr.* = subagent_mod.SubagentManager.init(allocator, cfg, event_bus, .{});
                    mgr.observer = runtime_observer.?.backendObserver();
                    mgr.task_runner = subagent_runner.runTaskWithTools;
                    subagent_manager_opt = mgr;
                }

                // Tools (with policy + subagent_manager bound)
                tools_slice = tools_mod.allTools(allocator, cfg.workspace_dir, .{
                    .http_enabled = cfg.http_request.enabled,
                    .http_allowed_domains = cfg.http_request.allowed_domains,
                    .http_max_response_size = cfg.http_request.max_response_size,
                    .http_timeout_secs = cfg.http_request.timeout_secs,
                    .web_search_base_url = cfg.http_request.search_base_url,
                    .web_search_provider = cfg.http_request.search_provider,
                    .web_search_fallback_providers = cfg.http_request.search_fallback_providers,
                    .browser_enabled = cfg.browser.enabled,
                    .screenshot_enabled = true,
                    .mcp_server_configs = cfg.mcp_servers,
                    .agents = cfg.agents,
                    .configured_providers = cfg.providers,
                    .fallback_api_key = resolved_api_key,
                    .allowed_paths = cfg.autonomy.allowed_paths,
                    .tools_config = cfg.tools,
                    .policy = state.security_policy,
                    .subagent_manager = subagent_manager_opt,
                    .bootstrap_provider = bootstrap_provider_opt,
                    .backend_name = cfg.memory.backend,
                    .sandbox_backend = cfg.security.sandbox.backend,
                    .sandbox_enabled = cfg.sandboxEnabled(),
                }) catch &.{};

                var sm = session_mod.SessionManager.init(allocator, cfg, provider_i, tools_slice, mem_opt, runtime_observer.?.observer(), if (mem_rt) |rt| rt.session_store else null, if (mem_rt) |*rt| rt.response_cache else null);
                if (state.security_policy) |policy| {
                    sm.policy = policy;
                }
                if (mem_rt) |*rt| {
                    sm.mem_rt = rt;
                    tools_mod.bindMemoryRuntime(tools_slice, rt);
                }
                if (cfg.agent.sensorium_enabled) {
                    sm.scheduler_snapshot_fn = schedulerSnapshotCallback;
                    sm.scheduler_snapshot_ctx = @ptrCast(&state);
                }
                session_mgr_opt = sm;

                // Eagerly probe vision for A2A (common to both sides)
                if (session_mgr_opt) |*mgr| maybeProbeA2aVision(mgr, allocator, cfg);
            }

            // Also initialize upstream LocalAgentRuntime path when needed (for lazy A2A / webhook_sync)
            if (needs_local_agent or cfg.gateway.webhook_sync_for_workers) {
                local_agent_runtime_opt = try initLocalAgentRuntime(allocator, cfg, runtime_observer.?, event_bus);
                if (local_agent_runtime_opt) |*runtime| {
                    maybeProbeA2aVision(&runtime.session_mgr, allocator, cfg);
                }
            }
        }
    } else {
        try http_util.setProxyOverride(null);
        try providers.setApiErrorLimitOverride(null);
    }
    if (state.pairing_guard == null) {
        state.pairing_guard = try PairingGuard.init(allocator, true, &.{});
    }

    // Cleanup for all objects we actually created (Rule 1 — must match our declarations)
    defer if (provider_bundle_opt) |*bundle| bundle.deinit();
    defer if (bootstrap_provider_opt) |bp| bp.deinit();
    defer if (mem_rt) |*rt| rt.deinit();
    defer if (subagent_manager_opt) |mgr| {
        mgr.deinit();
        allocator.destroy(mgr);
    };
    defer if (tools_slice.len > 0) tools_mod.deinitTools(allocator, tools_slice);
    defer if (session_mgr_opt) |*sm| sm.deinit();
    defer if (sec_audit_log_opt) |*al| al.deinit();

    // Cleanup for upstream lazy runtime (if initialized)
    defer if (local_agent_runtime_opt) |*runtime| runtime.deinit(allocator);

    // Resolve the listen address
    const addr = try std_compat.net.Address.resolveIp(host, port);
    const daemon_mode = event_bus != null;

    // Best-effort probe to detect if the port is already in use.
    // A TOCTOU gap exists between probe and listen(), but listen() will still
    // fail with AddressInUse if another process binds the port in that window.
    const probe_conn = std_compat.net.tcpConnectToAddress(addr) catch null;
    if (probe_conn) |conn| {
        conn.close();
        return error.AddressInUse;
    }

    var server = try addr.listen(.{
        .reuse_address = true,
        // Daemon/service shutdown needs the accept loop to observe the shared
        // shutdown flag instead of blocking forever in accept().
        .force_nonblocking = daemon_mode,
    });
    defer server.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var bw = std_compat.fs.File.stdout().writer(&stdout_buf);
    const stdout = &bw.interface;
    try stdout.print("Gateway listening on {s}:{d}\n", .{ host, port });
    try stdout.flush();
    if (config_opt) |cfg| {
        if (cfg.autonomy.level == .yolo) {
            try stdout.print("\x1b[1;31m[WARNING] YOLO mode active — all security checks bypassed\x1b[0m\n", .{});
            try stdout.flush();
        }
        // In daemon mode the parent already prints model/provider.
        if (config_ptr == null) cfg.printModelConfig();
    }
    if (state.pairing_guard) |*guard| {
        if (guard.pairingCode()) |code| {
            _ = code;
            try stdout.print("Gateway pairing code generated (hidden for security). Use the /pair flow to complete pairing.\n", .{});
            try stdout.flush();
        }
    }

    var accept_sleep_ms: u64 = ACCEPT_POLL_INTERVAL_MS;
    var accept_error_count: u32 = 0;

    // Accept loop — read raw HTTP from TCP connections
    while (true) {
        if (daemon_mode and daemon.isShutdownRequested()) break;

        var conn = server.accept() catch |err| switch (err) {
            error.WouldBlock => {
                accept_sleep_ms = nextAcceptSleepMs(accept_sleep_ms, err);
                std_compat.thread.sleep(accept_sleep_ms * std.time.ns_per_ms);
                continue;
            },
            else => {
                accept_error_count +|= 1;
                const next_sleep_ms = nextAcceptSleepMs(accept_sleep_ms, err);
                if (accept_error_count == 1 or (accept_error_count % ACCEPT_ERROR_LOG_INTERVAL) == 0) {
                    log.warn("gateway accept failed ({s}); backing off for {d}ms", .{ @errorName(err), next_sleep_ms });
                }
                accept_sleep_ms = next_sleep_ms;
                std_compat.thread.sleep(accept_sleep_ms * std.time.ns_per_ms);
                continue;
            },
        };
        accept_sleep_ms = ACCEPT_POLL_INTERVAL_MS;
        accept_error_count = 0;
        var close_conn = true;
        defer if (close_conn) conn.stream.close();
        configureRequestReadTimeout(&conn.stream, request_timeout_secs);
        var client_identifier_buf: [64]u8 = undefined;
        const client_identifier = clientIdentifierFromAddress(conn.address, &client_identifier_buf);

        // Per-request arena — all request-scoped allocations freed in one shot
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const req_allocator = arena.allocator();

        // Read full HTTP request (headers + optional body).
        const raw = readHttpRequest(req_allocator, &conn.stream, max_body) catch |err| {
            switch (err) {
                error.RequestTooLarge => writeJsonResponse(&conn.stream, "413 Payload Too Large", "{\"error\":\"request too large\"}"),
                error.InvalidContentLength => writeJsonResponse(&conn.stream, "400 Bad Request", "{\"error\":\"invalid content-length\"}"),
                error.RequestTimeout => writeJsonResponse(&conn.stream, "408 Request Timeout", "{\"error\":\"request timeout\"}"),
                else => {},
            }
            continue;
        };

        // Parse first line: "METHOD /path HTTP/1.1\r\n"
        const first_line_end = std.mem.indexOf(u8, raw, "\r\n") orelse continue;
        const first_line = raw[0..first_line_end];
        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method_str = parts.next() orelse continue;
        const target = parts.next() orelse continue;

        // Simple routing — control endpoints + descriptor-driven channel webhooks.
        const ControlRoute = enum { health, ready, status, doctor, webhook, pair, logout };
        const control_route_map = std.StaticStringMap(ControlRoute).initComptime(.{
            .{ "/health", .health },
            .{ "/ready", .ready },
            .{ "/status", .status },
            .{ "/doctor", .doctor },
            .{ "/webhook", .webhook },
            .{ "/pair", .pair },
            .{ "/logout", .logout },
        });
        const base_path = if (std.mem.indexOfScalar(u8, target, '?')) |qi| target[0..qi] else target;
        const is_post = std.mem.eql(u8, method_str, "POST");
        var response_status: []const u8 = "200 OK";
        var response_content_type: []const u8 = CONTENT_TYPE_JSON;
        var response_body: []const u8 = "";
        var pair_response_buf: [256]u8 = undefined;

        if (findCronRouteDescriptor(base_path)) |desc| {
            // Auth check for /cron endpoints:
            // - Loopback/local binds follow admin route auth
            // - Public binds always require a valid stored bearer token
            // - Pairing required, no tokens yet → DENY (bootstrap phase; CLI falls back to disk)
            // - Pairing required, tokens exist → require valid bearer token
            const auth_header = extractHeader(raw, "Authorization");
            const bearer = if (auth_header) |ah| extractBearerToken(ah) else null;
            const pairing_guard = if (state.pairing_guard) |*guard| guard else null;
            const cron_authorized = isCronRouteAuthorized(pairing_guard, bearer, public_bind);
            if (!cron_authorized) {
                response_status = "401 Unauthorized";
                response_body = "{\"error\":\"unauthorized\"}";
            } else {
                _ = desc.method; // method check is inside each handler
                var cron_ctx = WebhookHandlerContext{
                    .root_allocator = allocator,
                    .req_allocator = req_allocator,
                    .raw_request = raw,
                    .method = method_str,
                    .target = target,
                    .client_identifier = client_identifier,
                    .config_opt = config_opt,
                    .state = &state,
                    .session_mgr_opt = if (local_agent_runtime_opt) |*runtime| &runtime.session_mgr else null,
                };
                desc.handler(&cron_ctx);
                response_status = cron_ctx.response_status;
                response_content_type = cron_ctx.response_content_type;
                response_body = cron_ctx.response_body;
            }
        } else if (findWebhookRouteDescriptor(base_path)) |desc| {
            var webhook_ctx = WebhookHandlerContext{
                .root_allocator = allocator,
                .req_allocator = req_allocator,
                .raw_request = raw,
                .method = method_str,
                .target = target,
                .client_identifier = client_identifier,
                .config_opt = config_opt,
                .state = &state,
                .session_mgr_opt = if (local_agent_runtime_opt) |*runtime| &runtime.session_mgr else null,
            };
            desc.handler(&webhook_ctx);
            response_status = webhook_ctx.response_status;
            response_content_type = webhook_ctx.response_content_type;
            response_body = webhook_ctx.response_body;
        } else if (hasSlackHttpEndpoint(config_opt, base_path)) {
            var webhook_ctx = WebhookHandlerContext{
                .root_allocator = allocator,
                .req_allocator = req_allocator,
                .raw_request = raw,
                .method = method_str,
                .target = target,
                .client_identifier = client_identifier,
                .config_opt = config_opt,
                .state = &state,
                .session_mgr_opt = if (local_agent_runtime_opt) |*runtime| &runtime.session_mgr else null,
            };
            handleSlackWebhookRoute(&webhook_ctx);
            response_status = webhook_ctx.response_status;
            response_content_type = webhook_ctx.response_content_type;
            response_body = webhook_ctx.response_body;
        } else if (std.mem.eql(u8, base_path, "/.well-known/agent.json") or
            std.mem.eql(u8, base_path, "/.well-known/agent-card.json"))
        {
            // A2A Agent Card discovery (public, no auth).
            if (config_opt) |cfg| {
                if (cfg.a2a.enabled) {
                    const vision_capable = if (local_agent_runtime_opt) |runtime| runtime.session_mgr.vision_capable else null;
                    const card = a2a.handleAgentCard(req_allocator, cfg, vision_capable);
                    response_status = card.status;
                    response_body = card.body;
                } else {
                    response_status = "404 Not Found";
                    response_body = "{\"error\":\"a2a not enabled\"}";
                }
            } else {
                response_status = "404 Not Found";
                response_body = "{\"error\":\"not configured\"}";
            }
        } else if (std.mem.eql(u8, base_path, "/a2a")) {
            // A2A JSON-RPC endpoint (auth required).
            if (!is_post) {
                response_status = "405 Method Not Allowed";
                response_body = "{\"error\":\"method not allowed\"}";
            } else if (config_opt == null or !config_opt.?.a2a.enabled) {
                response_status = "404 Not Found";
                response_body = "{\"error\":\"a2a not enabled\"}";
            } else {
                const auth_header = extractHeader(raw, "Authorization");
                const bearer = if (auth_header) |ah| extractBearerToken(ah) else null;
                const pairing_guard = if (state.pairing_guard) |*guard| guard else null;
                if (!isGenericGatewayEndpointAuthorized(pairing_guard, bearer, public_bind)) {
                    response_status = "401 Unauthorized";
                    response_body = "{\"error\":\"unauthorized\"}";
                } else if (!allowScopedWebhook(&state, "a2a", client_identifier)) {
                    response_status = "429 Too Many Requests";
                    response_body = "{\"error\":\"rate limited\"}";
                } else {
                    const body = extractBody(raw);
                    if (body) |b| {
                        const a2a_session_mgr = if (local_agent_runtime_opt) |*runtime|
                            &runtime.session_mgr
                        else if (config_opt) |cfg|
                            ensureLocalAgentRuntime(allocator, &local_agent_runtime_opt, cfg, runtime_observer.?, event_bus) catch null
                        else
                            null;

                        if (a2a_session_mgr) |sm| {
                            if (a2a.isStreamingMethod(b)) {
                                // SSE streaming runs in its own worker so the main accept
                                // loop can continue serving tasks/cancel and new requests.
                                if (spawnA2aStreamingWorker(allocator, b, conn.stream, &a2a_registry, sm)) {
                                    close_conn = false;
                                    response_status = "";
                                    response_body = "";
                                } else |_| {
                                    response_status = "503 Service Unavailable";
                                    response_body = "{\"error\":\"stream setup failed\"}";
                                }
                            } else {
                                const resp = a2a.handleJsonRpc(req_allocator, b, &a2a_registry, sm);
                                response_status = resp.status;
                                response_body = resp.body;
                            }
                        } else {
                            response_status = "503 Service Unavailable";
                            response_body = "{\"error\":\"agent not available\"}";
                        }
                    } else {
                        response_status = "400 Bad Request";
                        response_body = "{\"error\":\"empty body\"}";
                    }
                }
            }
        } else if (control_route_map.get(base_path)) |route| switch (route) {
            .health => {
                response_body = if (isHealthOk()) "{\"status\":\"ok\"}" else "{\"status\":\"degraded\"}";
            },
            .ready => {
                const readiness = health.checkRegistryReadiness(req_allocator) catch {
                    response_status = "500 Internal Server Error";
                    response_body = "{\"status\":\"not_ready\",\"checks\":[]}";
                    continue;
                };
                defer readiness.deinit(req_allocator);
                const json_body = readiness.formatJson(req_allocator) catch {
                    response_status = "500 Internal Server Error";
                    response_body = "{\"status\":\"not_ready\",\"checks\":[]}";
                    continue;
                };
                response_body = json_body;
                if (readiness.status != .ready) {
                    response_status = "503 Service Unavailable";
                }
            },
            .status => {
                const auth_header = extractHeader(raw, "Authorization");
                const bearer = if (auth_header) |ah| extractBearerToken(ah) else null;
                const pairing_guard = if (state.pairing_guard) |*guard| guard else null;
                if (!isAdminRouteAuthorized(pairing_guard, bearer)) {
                    response_status = "401 Unauthorized";
                    response_body = "{\"error\":\"unauthorized\"}";
                    continue;
                }
                response_body = status_mod.buildRuntimeStatusJson(req_allocator) catch {
                    response_status = "500 Internal Server Error";
                    response_body = "{\"error\":\"status_unavailable\"}";
                    continue;
                };
            },
            .doctor => {
                const auth_header = extractHeader(raw, "Authorization");
                const bearer = if (auth_header) |ah| extractBearerToken(ah) else null;
                const pairing_guard = if (state.pairing_guard) |*guard| guard else null;
                if (!isAdminRouteAuthorized(pairing_guard, bearer)) {
                    response_status = "401 Unauthorized";
                    response_body = "{\"error\":\"unauthorized\"}";
                    continue;
                }
                response_body = doctor_mod.buildDoctorJson(req_allocator) catch {
                    response_status = "500 Internal Server Error";
                    response_body = "{\"error\":\"doctor_unavailable\"}";
                    continue;
                };
            },
            .webhook => {
                if (!is_post) {
                    response_status = "405 Method Not Allowed";
                    response_body = "{\"error\":\"method not allowed\"}";
                } else {
                    const auth_header = extractHeader(raw, "Authorization");
                    const bearer = if (auth_header) |ah| extractBearerToken(ah) else null;
                    const pairing_guard = if (state.pairing_guard) |*guard| guard else null;
                    if (!isGenericGatewayEndpointAuthorized(pairing_guard, bearer, public_bind)) {
                        response_status = "401 Unauthorized";
                        response_body = "{\"error\":\"unauthorized\"}";
                    } else if (!allowScopedWebhook(&state, "webhook", client_identifier)) {
                        response_status = "429 Too Many Requests";
                        response_body = "{\"error\":\"rate limited\"}";
                    } else {
                        const body = extractBody(raw);
                        if (body) |b| {
                            const msg_text = jsonStringField(b, "message") orelse jsonStringField(b, "text") orelse b;
                            var routing = webhookRouting(req_allocator, b, bearer, config_opt);
                            defer routing.deinit(req_allocator);

                            // Worker-style sync path opt-in: when the request authenticates with
                            // a token from `paired_tokens` and `gateway.webhook_sync_for_workers`
                            // is set, take the synchronous session-manager branch instead of the
                            // event bus. This gives NullBoiler-style orchestrators the
                            // `{"status":"ok","response":"..."}` response their dispatch contract
                            // expects (Gap 3 from `docs/integration-analysis.md`). Channel
                            // webhooks (no paired-token bearer) continue through the bus path
                            // unchanged.
                            const sync_for_worker = shouldSyncWebhookForWorker(config_opt, pairing_guard, bearer);
                            const use_bus = state.event_bus != null and !sync_for_worker;

                            if (use_bus) {
                                _ = publishToBus(
                                    state.event_bus.?,
                                    state.allocator,
                                    "webhook",
                                    routing.sender_id,
                                    routing.chat_id,
                                    msg_text,
                                    routing.session_key,
                                    routing.metadata_json,
                                );
                                response_body = "{\"status\":\"received\"}";
                            } else if (local_agent_runtime_opt) |*runtime| {
                                const sm = &runtime.session_mgr;
                                const start_seq = gateway_thread_observer.currentSeq();
                                const reply: ?[]const u8 = sm.processInboundMessage(routing.session_key, msg_text, routing.conversation_context) catch |err| blk: {
                                    response_body = userFacingAgentErrorJson(err);
                                    break :blk null;
                                };
                                if (reply) |r| {
                                    defer allocator.free(r);
                                    const tool_events = gateway_thread_observer.collectSince(req_allocator, start_seq) catch &.{};
                                    const thread_events_json = buildThreadEventsJson(req_allocator, tool_events) catch "[]";
                                    const json_resp = buildWebhookSuccessResponse(req_allocator, r, thread_events_json) catch null;
                                    response_body = json_resp orelse "{\"status\":\"received\"}";
                                } else {
                                    response_body = "{\"status\":\"received\"}";
                                }
                            } else {
                                response_body = "{\"status\":\"received\"}";
                            }
                        } else {
                            response_body = "{\"status\":\"received\"}";
                        }
                    }
                }
            },
            .pair => {
                if (!is_post) {
                    response_status = "405 Method Not Allowed";
                    response_body = "{\"error\":\"method not allowed\"}";
                } else if (!isPairEndpointAllowed(public_bind, client_identifier)) {
                    response_status = "403 Forbidden";
                    response_body = "{\"error\":\"pairing requires loopback client on public bind\"}";
                } else if (!allowScopedPair(&state, "pair", client_identifier)) {
                    response_status = "429 Too Many Requests";
                    response_body = "{\"error\":\"rate limited\"}";
                } else {
                    if (state.pairing_guard) |*guard| {
                        const pairing_code = extractHeader(raw, "X-Pairing-Code");
                        switch (guard.attemptPair(pairing_code)) {
                            .paired => |token| {
                                defer allocator.free(token);
                                if (formatPairSuccessResponse(&pair_response_buf, token, guard.tokenExpiresInSecs())) |pair_resp| {
                                    response_body = pair_resp;
                                } else {
                                    response_status = "500 Internal Server Error";
                                    response_body = "{\"error\":\"pairing response failed\"}";
                                }
                            },
                            .missing_code => {
                                response_status = "400 Bad Request";
                                response_body = "{\"error\":\"missing X-Pairing-Code\"}";
                            },
                            .invalid_code => {
                                response_status = "401 Unauthorized";
                                response_body = "{\"error\":\"invalid pairing code\"}";
                            },
                            .already_paired => {
                                response_status = "409 Conflict";
                                response_body = "{\"error\":\"already paired\"}";
                            },
                            .disabled => {
                                response_status = "403 Forbidden";
                                response_body = "{\"error\":\"pairing disabled\"}";
                            },
                            .locked_out => {
                                response_status = "429 Too Many Requests";
                                response_body = "{\"error\":\"pairing locked out\"}";
                            },
                            .internal_error => {
                                response_status = "500 Internal Server Error";
                                response_body = "{\"error\":\"pairing failed\"}";
                            },
                        }
                    } else {
                        response_status = "500 Internal Server Error";
                        response_body = "{\"error\":\"pairing unavailable\"}";
                    }
                }
            },
            .logout => {
                if (!is_post) {
                    response_status = "405 Method Not Allowed";
                    response_body = "{\"error\":\"method not allowed\"}";
                } else {
                    const auth_header = extractHeader(raw, "Authorization");
                    const bearer = if (auth_header) |ah| extractBearerToken(ah) else null;
                    const pairing_guard = if (state.pairing_guard) |*guard| guard else null;
                    if (!revokeAuthorizedBearerToken(pairing_guard, bearer)) {
                        response_status = "401 Unauthorized";
                        response_body = "{\"error\":\"unauthorized\"}";
                    } else {
                        response_body = "{\"status\":\"revoked\"}";
                    }
                }
            },
        } else {
            response_status = "404 Not Found";
            response_body = "{\"error\":\"not found\"}";
        }

        // Send HTTP response (skip if SSE streaming already wrote directly).
        if (response_status.len > 0) {
            writeHttpResponse(&conn.stream, response_status, response_content_type, response_body);
        }
    }

    // Drain barrier: wait for any thread currently holding scheduler_mutex (e.g. the
    // daemon's schedulerThread with a locked_gs token) to release it before we let
    // state go out of scope.  Acquire + immediate release is sufficient because once
    // we hold it we know no other thread is inside the critical section.
    state.scheduler_mutex.lock();
    state.scheduler_mutex.unlock();
}

// ── Tests ────────────────────────────────────────────────────────

test "cron auth matrix: no pairing guard allows all" {
    // When pairing is not configured, admin routes stay open.
    try std.testing.expect(isWebhookAuthorized(null, null) == false); // webhook still fails
    try std.testing.expect(isAdminRouteAuthorized(null, null));
}

test "cron auth matrix: pairing disabled allows all" {
    var guard = try PairingGuard.init(std.testing.allocator, false, &.{});
    defer guard.deinit();
    try std.testing.expect(!guard.requirePairing());
    try std.testing.expect(isAdminRouteAuthorized(&guard, null));
}

test "cron auth matrix: local bind follows admin auth" {
    var guard = try PairingGuard.init(std.testing.allocator, false, &.{});
    defer guard.deinit();

    try std.testing.expect(isCronRouteAuthorized(null, null, false));
    try std.testing.expect(isCronRouteAuthorized(&guard, null, false));
}

test "cron auth matrix: public bind requires stored token" {
    // Regression: public /cron must not inherit anonymous admin-route access.
    var disabled_guard = try PairingGuard.init(std.testing.allocator, false, &.{});
    defer disabled_guard.deinit();

    try std.testing.expect(!isCronRouteAuthorized(null, null, true));
    try std.testing.expect(!isCronRouteAuthorized(&disabled_guard, null, true));
    try std.testing.expect(!isCronRouteAuthorized(&disabled_guard, "anything", true));

    const tokens = [_][]const u8{"zc_public_static_token"};
    var stored_guard = try PairingGuard.init(std.testing.allocator, false, &tokens);
    defer stored_guard.deinit();

    try std.testing.expect(isCronRouteAuthorized(&stored_guard, "zc_public_static_token", true));
    try std.testing.expect(!isCronRouteAuthorized(&stored_guard, "wrong", true));
}

test "generic endpoint auth matrix: loopback allows pairing-disabled local access" {
    var guard = try PairingGuard.init(std.testing.allocator, false, &.{});
    defer guard.deinit();

    try std.testing.expect(isGenericGatewayEndpointAuthorized(&guard, null, false));
}

test "generic endpoint auth matrix: public bind denies pairing-disabled access without stored token" {
    var guard = try PairingGuard.init(std.testing.allocator, false, &.{});
    defer guard.deinit();

    try std.testing.expect(!isGenericGatewayEndpointAuthorized(&guard, null, true));
    try std.testing.expect(!isGenericGatewayEndpointAuthorized(&guard, "anything", true));
}

test "generic endpoint auth matrix: public bind accepts stored token even when pairing disabled" {
    const tokens = [_][]const u8{"zc_public_static_token"};
    var guard = try PairingGuard.init(std.testing.allocator, false, &tokens);
    defer guard.deinit();

    try std.testing.expect(isGenericGatewayEndpointAuthorized(&guard, "zc_public_static_token", true));
    try std.testing.expect(!isGenericGatewayEndpointAuthorized(&guard, "wrong", true));
}

test "pair endpoint access matrix: loopback always allowed" {
    try std.testing.expect(isPairEndpointAllowed(false, "203.0.113.10"));
    try std.testing.expect(isPairEndpointAllowed(true, "127.0.0.1"));
    try std.testing.expect(isPairEndpointAllowed(true, "::1"));
}

test "pair endpoint access matrix: public bind rejects non-loopback clients" {
    try std.testing.expect(!isPairEndpointAllowed(true, "192.168.1.10"));
    try std.testing.expect(!isPairEndpointAllowed(true, "203.0.113.10"));
    try std.testing.expect(!isPairEndpointAllowed(true, "example.com"));
}

test "cron auth matrix: bootstrap phase denies all" {
    // Pairing required but no tokens issued yet → deny regardless of bearer
    var guard = try PairingGuard.init(std.testing.allocator, true, &.{});
    defer guard.deinit();
    try std.testing.expect(guard.requirePairing());
    try std.testing.expect(!guard.hasPairedTokens());
    try std.testing.expect(!isAdminRouteAuthorized(&guard, null));
}

test "cron auth matrix: paired phase requires valid token" {
    const tokens = [_][]const u8{"zc_secret_token"};
    var guard = try PairingGuard.init(std.testing.allocator, true, &tokens);
    defer guard.deinit();
    try std.testing.expect(guard.requirePairing());
    try std.testing.expect(guard.hasPairedTokens());
    try std.testing.expect(isAdminRouteAuthorized(&guard, "zc_secret_token"));
    try std.testing.expect(!isAdminRouteAuthorized(&guard, "wrong_token"));
    try std.testing.expect(!isAdminRouteAuthorized(&guard, null));
}

test "shared scheduler registration sets and clears global pointer" {
    var scheduler = cron_mod.CronScheduler.init(std.testing.allocator, 4, true);
    defer scheduler.deinit();
    defer clearSharedScheduler();

    setSharedScheduler(&scheduler);
    lockSharedScheduler();
    try std.testing.expect(g_shared_scheduler == &scheduler);
    unlockSharedScheduler();

    clearSharedScheduler();
    lockSharedScheduler();
    try std.testing.expect(g_shared_scheduler == null);
    unlockSharedScheduler();
}

test "cron handlers use GatewayState scheduler instead of global pointer" {
    // Regression: restore/bounce updates must mutate the daemon-owned scheduler
    // guarded by GatewayState.scheduler_mutex, not whichever scheduler pointer is
    // still parked in g_shared_scheduler.
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    const base_a = try @import("compat").fs.Dir.wrap(tmp_a.dir).realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base_a);
    const db_path_a_str = try std.fmt.allocPrint(std.testing.allocator, "{s}/cron_a.db", .{base_a});
    defer std.testing.allocator.free(db_path_a_str);
    const db_path_a = try std.testing.allocator.dupeZ(u8, db_path_a_str);
    defer std.testing.allocator.free(db_path_a);

    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();
    const base_b = try @import("compat").fs.Dir.wrap(tmp_b.dir).realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base_b);
    const db_path_b_str = try std.fmt.allocPrint(std.testing.allocator, "{s}/cron_b.db", .{base_b});
    defer std.testing.allocator.free(db_path_b_str);
    const db_path_b = try std.testing.allocator.dupeZ(u8, db_path_b_str);
    defer std.testing.allocator.free(db_path_b);

    var request_scheduler = cron_mod.CronScheduler.init(std.testing.allocator, 8, true);
    request_scheduler.db_path = db_path_a;
    defer request_scheduler.deinit();

    var global_scheduler = cron_mod.CronScheduler.init(std.testing.allocator, 8, true);
    global_scheduler.db_path = db_path_b;
    defer global_scheduler.deinit();

    setSharedScheduler(&global_scheduler);
    defer clearSharedScheduler();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req_allocator = arena.allocator();

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.scheduler_mutex.lock();
    state.scheduler = &request_scheduler;
    state.scheduler_mutex.unlock();

    const raw =
        "POST /cron/add HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Type: application/json\r\n\r\n" ++
        "{\"expression\":\"*/10 * * * *\",\"command\":\"echo request-scheduler\"}";

    var ctx = WebhookHandlerContext{
        .root_allocator = req_allocator,
        .req_allocator = req_allocator,
        .raw_request = raw,
        .method = "POST",
        .target = "/cron/add",
        .config_opt = null,
        .state = &state,
        .session_mgr_opt = null,
    };
    handleCronAdd(&ctx);

    try std.testing.expectEqualStrings("200 OK", ctx.response_status);
    try std.testing.expectEqual(@as(usize, 1), request_scheduler.listJobs().len);
    try std.testing.expectEqual(@as(usize, 0), global_scheduler.listJobs().len);
}

test "handleCronAdd preserves delivery routing fields" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const db_path_str = try std.fmt.allocPrint(std.testing.allocator, "{s}/cron_delivery.db", .{base});
    defer std.testing.allocator.free(db_path_str);
    const db_path = try std.testing.allocator.dupeZ(u8, db_path_str);
    defer std.testing.allocator.free(db_path);

    var scheduler = cron_mod.CronScheduler.init(std.testing.allocator, 8, true);
    scheduler.db_path = db_path;
    defer scheduler.deinit();
    setSharedScheduler(&scheduler);
    defer clearSharedScheduler();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req_allocator = arena.allocator();

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.scheduler_mutex.lock();
    state.scheduler = &scheduler;
    state.scheduler_mutex.unlock();

    const raw =
        "POST /cron/add HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Type: application/json\r\n\r\n" ++
        "{\"expression\":\"*/10 * * * *\",\"prompt\":\"Check \\\"traffic\\\"\",\"model\":\"openrouter/anthropic/claude-sonnet-4\",\"session_target\":\"main\",\"delivery_mode\":\"always\",\"delivery_channel\":\"telegram\",\"delivery_account_id\":\"backup\",\"delivery_to\":\"chat-42\",\"delivery_peer_kind\":\"group\",\"delivery_peer_id\":\"-100123\",\"delivery_thread_id\":\"77\",\"delivery_best_effort\":false}";

    var ctx = WebhookHandlerContext{
        .root_allocator = req_allocator,
        .req_allocator = req_allocator,
        .raw_request = raw,
        .method = "POST",
        .target = "/cron/add",
        .config_opt = null,
        .state = &state,
        .session_mgr_opt = null,
    };
    handleCronAdd(&ctx);

    try std.testing.expectEqualStrings("200 OK", ctx.response_status);
    const jobs = scheduler.listJobs();
    try std.testing.expectEqual(@as(usize, 1), jobs.len);
    try std.testing.expectEqual(cron_mod.DeliveryMode.always, jobs[0].delivery.mode);
    try std.testing.expectEqualStrings("Check \"traffic\"", jobs[0].command);
    try std.testing.expectEqualStrings("Check \"traffic\"", jobs[0].prompt.?);
    try std.testing.expectEqual(cron_mod.SessionTarget.main, jobs[0].session_target);
    try std.testing.expectEqualStrings("telegram", jobs[0].delivery.channel.?);
    try std.testing.expectEqualStrings("backup", jobs[0].delivery.account_id.?);
    try std.testing.expectEqualStrings("chat-42", jobs[0].delivery.to.?);
    try std.testing.expectEqual(agent_routing.ChatType.group, jobs[0].delivery.peer_kind.?);
    try std.testing.expectEqualStrings("-100123", jobs[0].delivery.peer_id.?);
    try std.testing.expectEqualStrings("77", jobs[0].delivery.thread_id.?);
    try std.testing.expect(!jobs[0].delivery.best_effort);

    const parsed = try std.json.parseFromSlice(std.json.Value, req_allocator, ctx.response_body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("main", parsed.value.object.get("session_target").?.string);
}

test "handleCronAdd supports one-shot delay payloads" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const db_path_str = try std.fmt.allocPrint(std.testing.allocator, "{s}/cron_once.db", .{base});
    defer std.testing.allocator.free(db_path_str);
    const db_path = try std.testing.allocator.dupeZ(u8, db_path_str);
    defer std.testing.allocator.free(db_path);

    var scheduler = cron_mod.CronScheduler.init(std.testing.allocator, 8, true);
    scheduler.db_path = db_path;
    defer scheduler.deinit();
    setSharedScheduler(&scheduler);
    defer clearSharedScheduler();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req_allocator = arena.allocator();

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.scheduler_mutex.lock();
    state.scheduler = &scheduler;
    state.scheduler_mutex.unlock();

    const raw =
        "POST /cron/add HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Type: application/json\r\n\r\n" ++
        "{\"delay\":\"5m\",\"command\":\"echo once\"}";

    var ctx = WebhookHandlerContext{
        .root_allocator = req_allocator,
        .req_allocator = req_allocator,
        .raw_request = raw,
        .method = "POST",
        .target = "/cron/add",
        .config_opt = null,
        .state = &state,
        .session_mgr_opt = null,
    };
    handleCronAdd(&ctx);

    try std.testing.expectEqualStrings("200 OK", ctx.response_status);
    const jobs = scheduler.listJobs();
    try std.testing.expectEqual(@as(usize, 1), jobs.len);
    try std.testing.expect(jobs[0].one_shot);
    try std.testing.expect(std.mem.startsWith(u8, jobs[0].expression, "@once:"));
    try std.testing.expectEqualStrings("echo once", jobs[0].command);
}

test "handleCronAdd preserves delivery routing for one-shot agent payloads" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const db_path_str = try std.fmt.allocPrint(std.testing.allocator, "{s}/cron_oneshot.db", .{base});
    defer std.testing.allocator.free(db_path_str);
    const db_path = try std.testing.allocator.dupeZ(u8, db_path_str);
    defer std.testing.allocator.free(db_path);

    var scheduler = cron_mod.CronScheduler.init(std.testing.allocator, 8, true);
    scheduler.db_path = db_path;
    defer scheduler.deinit();
    setSharedScheduler(&scheduler);
    defer clearSharedScheduler();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req_allocator = arena.allocator();

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.scheduler_mutex.lock();
    state.scheduler = &scheduler;
    state.scheduler_mutex.unlock();

    const raw =
        "POST /cron/add HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Type: application/json\r\n\r\n" ++
        "{\"delay\":\"5m\",\"prompt\":\"Summarize incidents\",\"session_target\":\"main\",\"delivery_mode\":\"always\",\"delivery_channel\":\"matrix\",\"delivery_account_id\":\"backup\",\"delivery_to\":\"!room:example\",\"delivery_peer_kind\":\"group\",\"delivery_peer_id\":\"!room:example\"}";

    var ctx = WebhookHandlerContext{
        .root_allocator = req_allocator,
        .req_allocator = req_allocator,
        .raw_request = raw,
        .method = "POST",
        .target = "/cron/add",
        .config_opt = null,
        .state = &state,
        .session_mgr_opt = null,
    };
    handleCronAdd(&ctx);

    try std.testing.expectEqualStrings("200 OK", ctx.response_status);
    const jobs = scheduler.listJobs();
    try std.testing.expectEqual(@as(usize, 1), jobs.len);
    try std.testing.expect(jobs[0].one_shot);
    try std.testing.expectEqual(cron_mod.JobType.agent, jobs[0].job_type);
    try std.testing.expectEqual(cron_mod.SessionTarget.main, jobs[0].session_target);
    try std.testing.expectEqualStrings("matrix", jobs[0].delivery.channel.?);
    try std.testing.expectEqualStrings("backup", jobs[0].delivery.account_id.?);
    try std.testing.expectEqualStrings("!room:example", jobs[0].delivery.to.?);
    try std.testing.expectEqual(agent_routing.ChatType.group, jobs[0].delivery.peer_kind.?);
    try std.testing.expectEqualStrings("!room:example", jobs[0].delivery.peer_id.?);
}

test "handleCronAdd rejects session_target for shell jobs" {
    var scheduler = cron_mod.CronScheduler.init(std.testing.allocator, 8, true);
    defer scheduler.deinit();
    setSharedScheduler(&scheduler);
    defer clearSharedScheduler();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req_allocator = arena.allocator();

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();

    const raw =
        "POST /cron/add HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Type: application/json\r\n\r\n" ++
        "{\"expression\":\"*/10 * * * *\",\"command\":\"echo hello\",\"session_target\":\"main\"}";

    var ctx = WebhookHandlerContext{
        .root_allocator = req_allocator,
        .req_allocator = req_allocator,
        .raw_request = raw,
        .method = "POST",
        .target = "/cron/add",
        .config_opt = null,
        .state = &state,
        .session_mgr_opt = null,
    };
    handleCronAdd(&ctx);

    try std.testing.expectEqualStrings("400 Bad Request", ctx.response_status);
    try std.testing.expect(std.mem.indexOf(u8, ctx.response_body, "session_target requires prompt") != null);
}

test "handleCronAdd rejects invalid session_target" {
    var scheduler = cron_mod.CronScheduler.init(std.testing.allocator, 8, true);
    defer scheduler.deinit();
    setSharedScheduler(&scheduler);
    defer clearSharedScheduler();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req_allocator = arena.allocator();

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();

    const raw =
        "POST /cron/add HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Type: application/json\r\n\r\n" ++
        "{\"expression\":\"*/10 * * * *\",\"prompt\":\"Summarize\",\"session_target\":\"primary\"}";

    var ctx = WebhookHandlerContext{
        .root_allocator = req_allocator,
        .req_allocator = req_allocator,
        .raw_request = raw,
        .method = "POST",
        .target = "/cron/add",
        .config_opt = null,
        .state = &state,
        .session_mgr_opt = null,
    };
    handleCronAdd(&ctx);

    try std.testing.expectEqualStrings("400 Bad Request", ctx.response_status);
    try std.testing.expect(std.mem.indexOf(u8, ctx.response_body, "invalid session_target") != null);
}

test "handleCronUpdate accepts session_target" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const db_path_str = try std.fmt.allocPrint(std.testing.allocator, "{s}/cron_update_st.db", .{base});
    defer std.testing.allocator.free(db_path_str);
    const db_path = try std.testing.allocator.dupeZ(u8, db_path_str);
    defer std.testing.allocator.free(db_path);

    var scheduler = cron_mod.CronScheduler.init(std.testing.allocator, 8, true);
    scheduler.db_path = db_path;
    defer scheduler.deinit();
    const job = try scheduler.addAgentJob("* * * * *", "Summarize incidents", null, .{});
    setSharedScheduler(&scheduler);
    defer clearSharedScheduler();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req_allocator = arena.allocator();

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.scheduler_mutex.lock();
    state.scheduler = &scheduler;
    state.scheduler_mutex.unlock();

    const raw = try std.fmt.allocPrint(
        req_allocator,
        "POST /cron/update HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n\r\n{{\"id\":\"{s}\",\"session_target\":\"main\"}}",
        .{job.id},
    );

    var ctx = WebhookHandlerContext{
        .root_allocator = req_allocator,
        .req_allocator = req_allocator,
        .raw_request = raw,
        .method = "POST",
        .target = "/cron/update",
        .config_opt = null,
        .state = &state,
        .session_mgr_opt = null,
    };
    handleCronUpdate(&ctx);

    try std.testing.expectEqualStrings("200 OK", ctx.response_status);
    try std.testing.expectEqual(cron_mod.SessionTarget.main, scheduler.listJobs()[0].session_target);
}

test "handleCronUpdate rejects session_target for shell jobs" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const db_path_str = try std.fmt.allocPrint(std.testing.allocator, "{s}/cron_update_shell.db", .{base});
    defer std.testing.allocator.free(db_path_str);
    const db_path = try std.testing.allocator.dupeZ(u8, db_path_str);
    defer std.testing.allocator.free(db_path);

    var scheduler = cron_mod.CronScheduler.init(std.testing.allocator, 8, true);
    scheduler.db_path = db_path;
    defer scheduler.deinit();
    const job = try scheduler.addJob("* * * * *", "echo hello");
    setSharedScheduler(&scheduler);
    defer clearSharedScheduler();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req_allocator = arena.allocator();

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.scheduler_mutex.lock();
    state.scheduler = &scheduler;
    state.scheduler_mutex.unlock();

    const raw = try std.fmt.allocPrint(
        req_allocator,
        "POST /cron/update HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n\r\n{{\"id\":\"{s}\",\"session_target\":\"main\"}}",
        .{job.id},
    );

    var ctx = WebhookHandlerContext{
        .root_allocator = req_allocator,
        .req_allocator = req_allocator,
        .raw_request = raw,
        .method = "POST",
        .target = "/cron/update",
        .config_opt = null,
        .state = &state,
        .session_mgr_opt = null,
    };
    handleCronUpdate(&ctx);

    try std.testing.expectEqualStrings("400 Bad Request", ctx.response_status);
    try std.testing.expect(std.mem.indexOf(u8, ctx.response_body, "session_target requires agent job") != null);
}

test "handleCronUpdate rejects invalid session_target" {
    var scheduler = cron_mod.CronScheduler.init(std.testing.allocator, 8, true);
    defer scheduler.deinit();
    const job = try scheduler.addAgentJob("* * * * *", "Summarize incidents", null, .{});
    setSharedScheduler(&scheduler);
    defer clearSharedScheduler();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req_allocator = arena.allocator();

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();

    const raw = try std.fmt.allocPrint(
        req_allocator,
        "POST /cron/update HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n\r\n{{\"id\":\"{s}\",\"session_target\":\"primary\"}}",
        .{job.id},
    );

    var ctx = WebhookHandlerContext{
        .root_allocator = req_allocator,
        .req_allocator = req_allocator,
        .raw_request = raw,
        .method = "POST",
        .target = "/cron/update",
        .config_opt = null,
        .state = &state,
        .session_mgr_opt = null,
    };
    handleCronUpdate(&ctx);

    try std.testing.expectEqualStrings("400 Bad Request", ctx.response_status);
    try std.testing.expect(std.mem.indexOf(u8, ctx.response_body, "invalid session_target") != null);
}

test "constants are set correctly" {
    try std.testing.expectEqual(@as(usize, 65_536), MAX_BODY_SIZE);
    try std.testing.expectEqual(@as(u64, 30), REQUEST_TIMEOUT_SECS);
    try std.testing.expectEqual(@as(u64, 60), RATE_LIMIT_WINDOW_SECS);
}

test "rate limiter allows up to limit" {
    var limiter = SlidingWindowRateLimiter.init(2, 60);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allow(std.testing.allocator, "127.0.0.1"));
    try std.testing.expect(limiter.allow(std.testing.allocator, "127.0.0.1"));
    try std.testing.expect(!limiter.allow(std.testing.allocator, "127.0.0.1"));
}

test "rate limiter zero limit always allows" {
    var limiter = SlidingWindowRateLimiter.init(0, 60);
    defer limiter.deinit(std.testing.allocator);

    for (0..100) |_| {
        try std.testing.expect(limiter.allow(std.testing.allocator, "any-key"));
    }
}

test "rate limiter different keys are independent" {
    var limiter = SlidingWindowRateLimiter.init(1, 60);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allow(std.testing.allocator, "ip-1"));
    try std.testing.expect(!limiter.allow(std.testing.allocator, "ip-1"));
    try std.testing.expect(limiter.allow(std.testing.allocator, "ip-2"));
}

test "gateway rate limiter blocks after limit" {
    var limiter = GatewayRateLimiter.init(2, 2);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allowPair(std.testing.allocator, "127.0.0.1"));
    try std.testing.expect(limiter.allowPair(std.testing.allocator, "127.0.0.1"));
    try std.testing.expect(!limiter.allowPair(std.testing.allocator, "127.0.0.1"));
}

test "scoped webhook rate limits stay independent per route and client" {
    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.rate_limiter = GatewayRateLimiter.init(1, 1);

    try std.testing.expect(allowScopedWebhook(&state, "telegram", "203.0.113.10"));
    try std.testing.expect(!allowScopedWebhook(&state, "telegram", "203.0.113.10"));
    try std.testing.expect(allowScopedWebhook(&state, "slack", "203.0.113.10"));
    try std.testing.expect(allowScopedWebhook(&state, "telegram", "203.0.113.11"));
}

test "ensureSafeGatewayBind rejects public host without tunnel or override" {
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
    };
    try std.testing.expectError(error.PublicBindRequiresTunnel, ensureSafeGatewayBind("0.0.0.0", &cfg, null));
}

test "ensureSafeGatewayBind allows public host when explicitly enabled" {
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.gateway.allow_public_bind = true;
    try ensureSafeGatewayBind("0.0.0.0", &cfg, null);
}

test "ensureSafeGatewayBind allows public host when tunnel is active" {
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
    };
    try ensureSafeGatewayBind("0.0.0.0", &cfg, "https://public.example");
}

test "shouldSyncWebhookForWorker requires opt-in and stored token" {
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
    };
    var guard = try PairingGuard.init(std.testing.allocator, true, &.{"worker-token"});
    defer guard.deinit();

    // Regression: worker webhooks must bypass the bus only for the explicit
    // paired-token opt-in, not for missing or unrelated bearer credentials.
    try std.testing.expect(!shouldSyncWebhookForWorker(&cfg, &guard, "worker-token"));
    cfg.gateway.webhook_sync_for_workers = true;
    try std.testing.expect(shouldSyncWebhookForWorker(&cfg, &guard, "worker-token"));
    try std.testing.expect(!shouldSyncWebhookForWorker(&cfg, &guard, "wrong-token"));
    try std.testing.expect(!shouldSyncWebhookForWorker(&cfg, &guard, null));
    try std.testing.expect(!shouldSyncWebhookForWorker(&cfg, null, "worker-token"));
    try std.testing.expect(!shouldSyncWebhookForWorker(null, &guard, "worker-token"));

    _ = try guard.setPairingCode("123456");
    const pair_result = guard.attemptPair("123456");
    const runtime_token = switch (pair_result) {
        .paired => |token| token,
        else => return error.TestUnexpectedResult,
    };
    defer std.testing.allocator.free(runtime_token);
    try std.testing.expect(guard.matchesStoredToken(runtime_token));
    try std.testing.expect(!shouldSyncWebhookForWorker(&cfg, &guard, runtime_token));
}

test "idempotency store rejects duplicate key" {
    var store = IdempotencyStore.init(30);
    defer store.deinit(std.testing.allocator);

    try std.testing.expect(store.recordIfNew(std.testing.allocator, "req-1"));
    try std.testing.expect(!store.recordIfNew(std.testing.allocator, "req-1"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "req-2"));
}

test "idempotency store allows different keys" {
    var store = IdempotencyStore.init(300);
    defer store.deinit(std.testing.allocator);

    try std.testing.expect(store.recordIfNew(std.testing.allocator, "a"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "b"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "c"));
    try std.testing.expect(!store.recordIfNew(std.testing.allocator, "a"));
}

test "findWebhookRouteDescriptor resolves known webhook paths" {
    try std.testing.expect(findWebhookRouteDescriptor("/telegram") != null);
    try std.testing.expect(findWebhookRouteDescriptor("/whatsapp") != null);
    try std.testing.expect(findWebhookRouteDescriptor("/slack/events") != null);
    try std.testing.expect(findWebhookRouteDescriptor("/line") != null);
    try std.testing.expect(findWebhookRouteDescriptor("/lark") != null);
    try std.testing.expect(findWebhookRouteDescriptor("/wechat") != null);
    try std.testing.expect(findWebhookRouteDescriptor("/wecom") != null);
    try std.testing.expect(findWebhookRouteDescriptor("/qq") != null);
    try std.testing.expect(findWebhookRouteDescriptor("/max") != null);
    try std.testing.expect(findWebhookRouteDescriptor("/health") == null);
}

// ── Additional gateway tests ────────────────────────────────────

test "rate limiter single request allowed" {
    var limiter = SlidingWindowRateLimiter.init(1, 60);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allow(std.testing.allocator, "test-key"));
    try std.testing.expect(!limiter.allow(std.testing.allocator, "test-key"));
}

test "rate limiter high limit" {
    var limiter = SlidingWindowRateLimiter.init(100, 60);
    defer limiter.deinit(std.testing.allocator);

    for (0..100) |_| {
        try std.testing.expect(limiter.allow(std.testing.allocator, "ip"));
    }
    try std.testing.expect(!limiter.allow(std.testing.allocator, "ip"));
}

test "gateway rate limiter pair and webhook independent" {
    var limiter = GatewayRateLimiter.init(1, 1);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allowPair(std.testing.allocator, "ip"));
    try std.testing.expect(!limiter.allowPair(std.testing.allocator, "ip"));
    // Webhook should still be allowed since it's separate
    try std.testing.expect(limiter.allowWebhook(std.testing.allocator, "ip"));
    try std.testing.expect(!limiter.allowWebhook(std.testing.allocator, "ip"));
}

test "gateway rate limiter zero limits always allow" {
    var limiter = GatewayRateLimiter.init(0, 0);
    defer limiter.deinit(std.testing.allocator);

    for (0..50) |_| {
        try std.testing.expect(limiter.allowPair(std.testing.allocator, "any"));
        try std.testing.expect(limiter.allowWebhook(std.testing.allocator, "any"));
    }
}

test "idempotency store init with various TTLs" {
    var store1 = IdempotencyStore.init(1);
    defer store1.deinit(std.testing.allocator);
    try std.testing.expect(store1.ttl_ns > 0);

    var store2 = IdempotencyStore.init(3600);
    defer store2.deinit(std.testing.allocator);
    try std.testing.expect(store2.ttl_ns > store1.ttl_ns);
}

test "idempotency store zero TTL treated as 1 second" {
    var store = IdempotencyStore.init(0);
    defer store.deinit(std.testing.allocator);
    // Should use @max(0, 1) = 1 second
    try std.testing.expectEqual(@as(i128, 1_000_000_000), store.ttl_ns);
}

test "idempotency store many unique keys" {
    var store = IdempotencyStore.init(300);
    defer store.deinit(std.testing.allocator);

    // Use distinct string literals to avoid buffer aliasing
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "key-alpha"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "key-beta"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "key-gamma"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "key-delta"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "key-epsilon"));
}

test "idempotency store duplicate after many inserts" {
    var store = IdempotencyStore.init(300);
    defer store.deinit(std.testing.allocator);

    try std.testing.expect(store.recordIfNew(std.testing.allocator, "first"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "second"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "third"));
    // First key should still be duplicate
    try std.testing.expect(!store.recordIfNew(std.testing.allocator, "first"));
}

test "idempotency store allows expired key again" {
    var store = IdempotencyStore.init(1);
    defer store.deinit(std.testing.allocator);

    try std.testing.expect(store.recordIfNew(std.testing.allocator, "expires"));
    const entry = store.keys.getPtr("expires") orelse return error.TestUnexpectedResult;
    entry.* = std_compat.time.nanoTimestamp() - store.ttl_ns - 1;

    try std.testing.expect(store.recordIfNew(std.testing.allocator, "expires"));
    try std.testing.expect(!store.recordIfNew(std.testing.allocator, "expires"));
}

test "idempotency store keeps long keys exact" {
    var store = IdempotencyStore.init(300);
    defer store.deinit(std.testing.allocator);

    var long_key_a: [200]u8 = undefined;
    @memset(&long_key_a, 'A');
    var long_key_b: [200]u8 = undefined;
    @memset(&long_key_b, 'A');
    long_key_b[199] = 'B';

    try std.testing.expect(store.recordIfNew(std.testing.allocator, &long_key_a));
    try std.testing.expect(!store.recordIfNew(std.testing.allocator, &long_key_a));

    // Same first 199 bytes, different final byte: still a distinct idempotency key.
    try std.testing.expect(store.recordIfNew(std.testing.allocator, &long_key_b));
    // Prefix is also distinct from the longer key.
    try std.testing.expect(store.recordIfNew(std.testing.allocator, long_key_a[0..128]));
}

test "rate limiter window_ns calculation" {
    const limiter = SlidingWindowRateLimiter.init(10, 120);
    try std.testing.expectEqual(@as(i128, 120_000_000_000), limiter.window_ns);
}

test "MAX_BODY_SIZE is 64KB (default)" {
    try std.testing.expectEqual(@as(usize, 64 * 1024), MAX_BODY_SIZE);
}

test "maxHttpRequestSize saturates on overflow" {
    try std.testing.expectEqual(std.math.maxInt(usize), maxHttpRequestSize(std.math.maxInt(usize)));
}

test "RATE_LIMIT_WINDOW_SECS is 60" {
    try std.testing.expectEqual(@as(u64, 60), RATE_LIMIT_WINDOW_SECS);
}

test "REQUEST_TIMEOUT_SECS is 30" {
    try std.testing.expectEqual(@as(u64, 30), REQUEST_TIMEOUT_SECS);
}

test "effectiveRequestReadTimeoutSecs uses configured value and defaults zero to 30" {
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };

    cfg.gateway.request_timeout_secs = 45;
    try std.testing.expectEqual(@as(u64, 45), effectiveRequestReadTimeoutSecs(&cfg));

    cfg.gateway.request_timeout_secs = 0;
    try std.testing.expectEqual(@as(u64, REQUEST_TIMEOUT_SECS), effectiveRequestReadTimeoutSecs(&cfg));
}

test "rate limiter different keys do not interfere" {
    var limiter = SlidingWindowRateLimiter.init(2, 60);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allow(std.testing.allocator, "key-a"));
    try std.testing.expect(limiter.allow(std.testing.allocator, "key-b"));
    try std.testing.expect(limiter.allow(std.testing.allocator, "key-a"));
    // key-a should now be at limit
    try std.testing.expect(!limiter.allow(std.testing.allocator, "key-a"));
    // key-b still has room
    try std.testing.expect(limiter.allow(std.testing.allocator, "key-b"));
}

// ── WhatsApp / parseQueryParam tests ────────────────────────────

test "parseQueryParam extracts single param" {
    const val = parseQueryParam("/whatsapp?hub.mode=subscribe", "hub.mode");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("subscribe", val.?);
}

test "parseQueryParam extracts param from multiple" {
    const target = "/whatsapp?hub.mode=subscribe&hub.verify_token=mytoken&hub.challenge=abc123";
    try std.testing.expectEqualStrings("subscribe", parseQueryParam(target, "hub.mode").?);
    try std.testing.expectEqualStrings("mytoken", parseQueryParam(target, "hub.verify_token").?);
    try std.testing.expectEqualStrings("abc123", parseQueryParam(target, "hub.challenge").?);
}

test "parseQueryParam returns null for missing param" {
    const val = parseQueryParam("/whatsapp?hub.mode=subscribe", "hub.challenge");
    try std.testing.expect(val == null);
}

test "parseQueryParam returns null for no query string" {
    const val = parseQueryParam("/whatsapp", "hub.mode");
    try std.testing.expect(val == null);
}

test "parseQueryParam empty value" {
    const val = parseQueryParam("/path?key=", "key");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("", val.?);
}

test "parseQueryParam partial key match does not match" {
    const val = parseQueryParam("/path?hub.mode_extra=subscribe", "hub.mode");
    try std.testing.expect(val == null);
}

test "GatewayState initWithVerifyToken stores token" {
    var state = GatewayState.initWithVerifyToken(std.testing.allocator, "test-verify-token");
    defer state.deinit();
    try std.testing.expectEqualStrings("test-verify-token", state.whatsapp_verify_token);
}

test "GatewayState init has empty verify token" {
    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expectEqualStrings("", state.whatsapp_verify_token);
}

test "pauseCronJobForRepair falls back to cron_db_path when backend is null" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try @import("compat").fs.Dir.wrap(tmp.dir).realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const db_path_str = try std.fmt.allocPrint(std.testing.allocator, "{s}/pause_fallback.db", .{base});
    defer std.testing.allocator.free(db_path_str);
    const db_path_z = try std.testing.allocator.dupeZ(u8, db_path_str);
    defer std.testing.allocator.free(db_path_z);

    var backend = try cron_db_mod.DbCronBackend.init(std.testing.allocator, db_path_z);
    defer backend.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const job = try backend.backend().add(a, .{
        .expression = "0 8 * * *",
        .job_type = .skill,
        .command = "",
        .skill_name = "weather",
        .skill_args = "--location 臺北市",
        .verification_mode = .skill_contract,
        .repair_policy = .pause_on_fail,
    });

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.cron_db_path = db_path_z;
    // Intentionally leave cron_db_backend null to exercise the raw DB fallback.
    try std.testing.expect(pauseCronJobForRepair(&state, job.id));

    const loaded = (try backend.backend().get(a, job.id)).?;
    try std.testing.expect(loaded.paused);
}

test "sendCronRepairAlert uses alert delivery fallback for alert_only shell failures" {
    const allocator = std.testing.allocator;
    var state = GatewayState.init(allocator);
    defer state.deinit();

    var test_bus = bus_mod.Bus.init();
    defer test_bus.close();
    state.event_bus = &test_bus;
    state.alert_delivery = .{
        .mode = .always,
        .channel = "telegram",
        .to = "ops-chat",
        .best_effort = true,
    };

    const spec = struct {
        id: []const u8 = "shell-job-1",
        repair_policy: cron_mod.RepairPolicy = .alert_only,
        delivery: cron_mod.DeliveryConfig = .{},
    }{};
    const run_result = cron_mod.RunResult{
        .exit_code = 1,
        .timed_out = false,
        .failure_class = "exec_error",
        .repair_action = "alert_sent",
        .verified = 3,
    };

    sendCronRepairAlert(&state, allocator, spec, "shell", run_result, "trace-shell-1", "stderr preview");

    try std.testing.expectEqual(@as(usize, 1), test_bus.outboundDepth());
    var msg = test_bus.consumeOutbound().?;
    defer msg.deinit(allocator);
    try std.testing.expectEqualStrings("telegram", msg.channel);
    try std.testing.expectEqualStrings("ops-chat", msg.chat_id);
    try std.testing.expect(std.mem.indexOf(u8, msg.content, "shell 'shell-job-1' degraded") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.content, "failure=exec_error") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.content, "repair=alert_sent") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.content, "trace=trace-shell-1") != null);
}

// ── Bearer Token Validation tests ───────────────────────────────

test "validateBearerToken allows when no paired tokens" {
    try std.testing.expect(validateBearerToken("anything", &.{}));
}

test "validateBearerToken allows valid token" {
    const tokens = &[_][]const u8{ "token-a", "token-b", "token-c" };
    try std.testing.expect(validateBearerToken("token-b", tokens));
}

test "validateBearerToken rejects invalid token" {
    const tokens = &[_][]const u8{ "token-a", "token-b" };
    try std.testing.expect(!validateBearerToken("token-c", tokens));
}

test "validateBearerToken rejects empty token when tokens configured" {
    const tokens = &[_][]const u8{"secret"};
    try std.testing.expect(!validateBearerToken("", tokens));
}

test "validateBearerToken exact match required" {
    const tokens = &[_][]const u8{"abc123"};
    try std.testing.expect(validateBearerToken("abc123", tokens));
    try std.testing.expect(!validateBearerToken("abc1234", tokens));
    try std.testing.expect(!validateBearerToken("abc12", tokens));
}

test "isWebhookAuthorized fails closed when pairing guard missing" {
    try std.testing.expect(!isWebhookAuthorized(null, "token"));
}

test "isWebhookAuthorized allows when pairing disabled" {
    var guard = try PairingGuard.init(std.testing.allocator, false, &.{});
    defer guard.deinit();
    try std.testing.expect(isWebhookAuthorized(&guard, null));
}

test "isWebhookAuthorized requires valid bearer token when pairing enabled" {
    const tokens = [_][]const u8{"zc_valid"};
    var guard = try PairingGuard.init(std.testing.allocator, true, &tokens);
    defer guard.deinit();

    try std.testing.expect(isWebhookAuthorized(&guard, "zc_valid"));
    try std.testing.expect(!isWebhookAuthorized(&guard, null));
    try std.testing.expect(!isWebhookAuthorized(&guard, "zc_invalid"));
}

test "revokeAuthorizedBearerToken removes authenticated token" {
    const tokens = [_][]const u8{"zc_valid"};
    var guard = try PairingGuard.init(std.testing.allocator, true, &tokens);
    defer guard.deinit();

    try std.testing.expect(revokeAuthorizedBearerToken(&guard, "zc_valid"));
    try std.testing.expect(!guard.isAuthenticated("zc_valid"));
}

test "revokeAuthorizedBearerToken rejects missing or invalid tokens" {
    const tokens = [_][]const u8{"zc_valid"};
    var guard = try PairingGuard.init(std.testing.allocator, true, &tokens);
    defer guard.deinit();

    try std.testing.expect(!revokeAuthorizedBearerToken(&guard, null));
    try std.testing.expect(!revokeAuthorizedBearerToken(&guard, "zc_invalid"));
    try std.testing.expect(guard.isAuthenticated("zc_valid"));
}

test "formatPairSuccessResponse includes paired token" {
    var buf: [256]u8 = undefined;
    const response = formatPairSuccessResponse(&buf, "zc_token_123", 3600) orelse unreachable;
    try std.testing.expectEqualStrings(
        "{\"status\":\"paired\",\"token\":\"zc_token_123\",\"expires_in\":3600}",
        response,
    );
}

test "formatPairSuccessResponse fails when buffer is too small" {
    var buf: [8]u8 = undefined;
    try std.testing.expect(formatPairSuccessResponse(&buf, "zc_token_123", 3600) == null);
}

// ── extractHeader tests ──────────────────────────────────────────

test "extractHeader finds Authorization header" {
    const raw = "POST /webhook HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer secret123\r\nContent-Type: application/json\r\n\r\n";
    const val = extractHeader(raw, "Authorization");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("Bearer secret123", val.?);
}

test "extractHeader case insensitive" {
    const raw = "GET /health HTTP/1.1\r\ncontent-type: text/plain\r\n\r\n";
    const val = extractHeader(raw, "Content-Type");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("text/plain", val.?);
}

test "extractHeader returns null for missing header" {
    const raw = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const val = extractHeader(raw, "Authorization");
    try std.testing.expect(val == null);
}

test "extractHeader returns null for empty headers" {
    const raw = "GET / HTTP/1.1\r\n\r\n";
    try std.testing.expect(extractHeader(raw, "Host") == null);
}

// ── extractBearerToken tests ─────────────────────────────────────

test "extractBearerToken extracts token" {
    try std.testing.expectEqualStrings("mytoken", extractBearerToken("Bearer mytoken").?);
}

test "extractBearerToken returns null for non-Bearer" {
    try std.testing.expect(extractBearerToken("Basic abc123") == null);
}

test "extractBearerToken returns null for empty string" {
    try std.testing.expect(extractBearerToken("") == null);
}

test "extractBearerToken returns null for just Bearer" {
    // "Bearer " is 7 chars, "Bearer" is 6 — no space
    try std.testing.expect(extractBearerToken("Bearer") == null);
}

// ── JSON helper tests ────────────────────────────────────────────

test "jsonStringField extracts value" {
    const json = "{\"message\": \"hello world\"}";
    const val = jsonStringField(json, "message");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("hello world", val.?);
}

test "jsonStringField returns null for missing key" {
    const json = "{\"other\": \"value\"}";
    try std.testing.expect(jsonStringField(json, "message") == null);
}

test "jsonStringField handles nested JSON" {
    const json = "{\"message\": {\"text\": \"hi\"}, \"text\": \"direct\"}";
    const val = jsonStringField(json, "text");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("hi", val.?);
}

test "slackDecodeInteractivePayload decodes form payload json" {
    const allocator = std.testing.allocator;
    const decoded = slackDecodeInteractivePayload(
        allocator,
        "payload=%7B%22type%22%3A%22block_actions%22%2C%22actions%22%3A%5B%5D%7D",
    ) orelse return error.TestUnexpectedResult;
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("{\"type\":\"block_actions\",\"actions\":[]}", decoded);
}

test "slackDecodeInteractivePayload finds payload after other form fields" {
    const allocator = std.testing.allocator;
    const decoded = slackDecodeInteractivePayload(
        allocator,
        "foo=bar&payload=%7B%22type%22%3A%22block_actions%22%7D",
    ) orelse return error.TestUnexpectedResult;
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("{\"type\":\"block_actions\"}", decoded);
}

test "slackParseCallbackValue parses token and option index" {
    const parsed = slackParseCallbackValue("ncslack:abc123:2") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("abc123", parsed.token);
    try std.testing.expectEqual(@as(usize, 2), parsed.option_index);
}

test "slackInteractiveTarget extracts base channel and thread id" {
    const parsed = slackInteractiveTarget("C12345:1700.1", "C999");
    try std.testing.expectEqualStrings("C12345", parsed.channel_id);
    try std.testing.expect(parsed.thread_id != null);
    try std.testing.expectEqualStrings("1700.1", parsed.thread_id.?);
    try std.testing.expect(!parsed.is_dm);
}

test "slackInteractiveTarget falls back to callback channel id for dm" {
    const parsed = slackInteractiveTarget("", "D12345");
    try std.testing.expectEqualStrings("D12345", parsed.channel_id);
    try std.testing.expect(parsed.thread_id == null);
    try std.testing.expect(parsed.is_dm);
}

test "jsonIntField extracts positive integer" {
    const json = "{\"chat_id\": 12345}";
    const val = jsonIntField(json, "chat_id");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(i64, 12345), val.?);
}

test "jsonIntField extracts negative integer" {
    const json = "{\"offset\": -100}";
    const val = jsonIntField(json, "offset");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(i64, -100), val.?);
}

test "jsonIntField returns null for missing key" {
    const json = "{\"other\": 42}";
    try std.testing.expect(jsonIntField(json, "chat_id") == null);
}

test "jsonIntField returns null for string value" {
    const json = "{\"chat_id\": \"not a number\"}";
    try std.testing.expect(jsonIntField(json, "chat_id") == null);
}

test "selectWhatsAppConfig picks account by phone_number_id" {
    const wa_accounts = [_]config_types.WhatsAppConfig{
        .{
            .account_id = "main",
            .access_token = "tok-a",
            .phone_number_id = "111",
            .verify_token = "verify-a",
        },
        .{
            .account_id = "backup",
            .access_token = "tok-b",
            .phone_number_id = "222",
            .verify_token = "verify-b",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .whatsapp = &wa_accounts,
        },
    };
    const body = "{\"entry\":[{\"changes\":[{\"value\":{\"metadata\":{\"phone_number_id\":\"222\"}}}]}]}";
    const selected = selectWhatsAppConfig(&cfg, body, null);
    if (!build_options.enable_channel_whatsapp) {
        try std.testing.expect(selected == null);
        return;
    }
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("backup", selected.?.account_id);
}

test "selectTelegramConfig picks account by query account_id" {
    const tg_accounts = [_]config_types.TelegramConfig{
        .{
            .account_id = "main",
            .bot_token = "token-main",
            .allow_from = &.{"main-user"},
        },
        .{
            .account_id = "backup",
            .bot_token = "token-backup",
            .allow_from = &.{"backup-user"},
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .telegram = &tg_accounts,
        },
    };

    const selected = selectTelegramConfig(&cfg, "/telegram?account_id=backup");
    if (!build_options.enable_channel_telegram) {
        try std.testing.expect(selected == null);
        return;
    }
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("backup", selected.?.account_id);
}

test "selectTelegramConfig falls back to preferred primary account" {
    const tg_accounts = [_]config_types.TelegramConfig{
        .{
            .account_id = "z-last",
            .bot_token = "token-z",
        },
        .{
            .account_id = "default",
            .bot_token = "token-default",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .telegram = &tg_accounts,
        },
    };

    const selected = selectTelegramConfig(&cfg, "/telegram");
    if (!build_options.enable_channel_telegram) {
        try std.testing.expect(selected == null);
        return;
    }
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("default", selected.?.account_id);
}

test "selectMaxConfig picks account by secret header" {
    const max_accounts = [_]config_types.MaxConfig{
        .{
            .account_id = "main",
            .bot_token = "max-main",
            .mode = .webhook,
            .webhook_secret = "secret-a",
        },
        .{
            .account_id = "backup",
            .bot_token = "max-backup",
            .mode = .webhook,
            .webhook_secret = "secret-b",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .max = &max_accounts,
        },
    };

    const selected = selectMaxConfig(&cfg, "/max", "secret-b");
    if (!build_options.enable_channel_max) {
        try std.testing.expect(selected == null);
        return;
    }
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("backup", selected.?.account_id);
}

test "selectMaxConfig picks account by query account_id" {
    const max_accounts = [_]config_types.MaxConfig{
        .{
            .account_id = "main",
            .bot_token = "max-main",
        },
        .{
            .account_id = "backup",
            .bot_token = "max-backup",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .max = &max_accounts,
        },
    };

    const selected = selectMaxConfig(&cfg, "/max?account_id=backup", null);
    if (!build_options.enable_channel_max) {
        try std.testing.expect(selected == null);
        return;
    }
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("backup", selected.?.account_id);
}

test "selectMaxConfig does not fall back when secret header is invalid" {
    const max_accounts = [_]config_types.MaxConfig{
        .{
            .account_id = "main",
            .bot_token = "max-main",
            .mode = .webhook,
            .webhook_secret = "secret-a",
        },
        .{
            .account_id = "backup",
            .bot_token = "max-backup",
            .mode = .webhook,
            .webhook_secret = "secret-b",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .max = &max_accounts,
        },
    };

    const selected = selectMaxConfig(&cfg, "/max", "wrong-secret");
    if (!build_options.enable_channel_max) {
        try std.testing.expect(selected == null);
        return;
    }
    try std.testing.expect(selected == null);
}

test "selectMaxConfig requires explicit routing when multiple webhook accounts exist" {
    const max_accounts = [_]config_types.MaxConfig{
        .{
            .account_id = "main",
            .bot_token = "max-main",
            .mode = .webhook,
        },
        .{
            .account_id = "backup",
            .bot_token = "max-backup",
            .mode = .webhook,
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .max = &max_accounts,
        },
    };

    const selected = selectMaxConfig(&cfg, "/max", null);
    if (!build_options.enable_channel_max) {
        try std.testing.expect(selected == null);
        return;
    }
    try std.testing.expect(selected == null);
}

test "selectMaxConfig picks sole webhook account even when polling account exists" {
    const max_accounts = [_]config_types.MaxConfig{
        .{
            .account_id = "poller",
            .bot_token = "max-poll",
            .mode = .polling,
        },
        .{
            .account_id = "webhook",
            .bot_token = "max-webhook",
            .mode = .webhook,
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .max = &max_accounts,
        },
    };

    const selected = selectMaxConfig(&cfg, "/max", null);
    if (!build_options.enable_channel_max) {
        try std.testing.expect(selected == null);
        return;
    }
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("webhook", selected.?.account_id);
}

test "selectWhatsAppConfig picks account by verify_token" {
    const wa_accounts = [_]config_types.WhatsAppConfig{
        .{
            .account_id = "main",
            .access_token = "tok-a",
            .phone_number_id = "111",
            .verify_token = "verify-a",
        },
        .{
            .account_id = "backup",
            .access_token = "tok-b",
            .phone_number_id = "222",
            .verify_token = "verify-b",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .whatsapp = &wa_accounts,
        },
    };
    const selected = selectWhatsAppConfig(&cfg, null, "verify-b");
    if (!build_options.enable_channel_whatsapp) {
        try std.testing.expect(selected == null);
        return;
    }
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("backup", selected.?.account_id);
}

test "selectLineConfigBySignature matches account and rejects bad signature" {
    const body = "{\"events\":[]}";
    const line_accounts = [_]config_types.LineConfig{
        .{
            .account_id = "main",
            .access_token = "line-a",
            .channel_secret = "secret-a",
        },
        .{
            .account_id = "backup",
            .access_token = "line-b",
            .channel_secret = "secret-b",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .line = &line_accounts,
        },
    };

    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, body, "secret-b");
    var sig_buf: [44]u8 = undefined;
    const signature = std.base64.standard.Encoder.encode(&sig_buf, &mac);

    const selected = selectLineConfigBySignature(&cfg, body, signature);
    if (!build_options.enable_channel_line) {
        try std.testing.expect(selected == null);
        try std.testing.expect(selectLineConfigBySignature(&cfg, body, "invalid-signature") == null);
        return;
    }
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("backup", selected.?.account_id);
    try std.testing.expect(selectLineConfigBySignature(&cfg, body, "invalid-signature") == null);
}

test "selectLarkConfig picks account by verification token" {
    const lark_accounts = [_]config_types.LarkConfig{
        .{
            .account_id = "main",
            .app_id = "app-a",
            .app_secret = "secret-a",
            .verification_token = "token-a",
        },
        .{
            .account_id = "backup",
            .app_id = "app-b",
            .app_secret = "secret-b",
            .verification_token = "token-b",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .lark = &lark_accounts,
        },
    };
    const body = "{\"header\":{\"token\":\"token-b\"}}";
    const selected = selectLarkConfig(&cfg, body);
    if (!build_options.enable_channel_lark) {
        try std.testing.expect(selected == null);
        return;
    }
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("backup", selected.?.account_id);
}

test "selectWeComConfig picks account by query account_id" {
    const wecom_accounts = [_]config_types.WeComConfig{
        .{
            .account_id = "main",
            .webhook_url = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=main",
        },
        .{
            .account_id = "backup",
            .webhook_url = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=backup",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .wecom = &wecom_accounts,
        },
    };

    const selected = selectWeComConfig(&cfg, "/wecom?account_id=backup");
    if (!build_options.enable_channel_wecom) {
        try std.testing.expect(selected == null);
        return;
    }
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("backup", selected.?.account_id);
}

test "selectWeChatConfig picks account by query account_id" {
    const wechat_accounts = [_]config_types.WeChatConfig{
        .{
            .account_id = "main",
            .callback_token = "token-main",
        },
        .{
            .account_id = "backup",
            .callback_token = "token-backup",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .wechat = &wechat_accounts,
        },
    };

    const selected = selectWeChatConfig(&cfg, "/wechat?account_id=backup");
    if (!build_options.enable_channel_wechat) {
        try std.testing.expect(selected == null);
        return;
    }
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("backup", selected.?.account_id);
}

test "formatHttpResponseHeader uses provided content type" {
    var buf: [256]u8 = undefined;
    const header = try formatHttpResponseHeader(&buf, "202 Accepted", CONTENT_TYPE_XML, 11);

    try std.testing.expect(std.mem.containsAtLeast(u8, header, 1, "HTTP/1.1 202 Accepted\r\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, header, 1, "Content-Type: application/xml; charset=utf-8\r\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, header, 1, "Content-Length: 11\r\n"));
}

test "handleWeChatWebhookRoute requires callback token configuration" {
    if (!build_options.enable_channel_wechat) return;

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();

    const raw_request =
        "POST /wechat HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Type: application/xml\r\n\r\n" ++
        "<xml></xml>";
    var ctx = WebhookHandlerContext{
        .root_allocator = std.testing.allocator,
        .req_allocator = std.testing.allocator,
        .raw_request = raw_request,
        .method = "POST",
        .target = "/wechat",
        .config_opt = null,
        .state = &state,
        .session_mgr_opt = null,
    };

    handleWeChatWebhookRoute(&ctx);
    try std.testing.expectEqualStrings("404 Not Found", ctx.response_status);
    try std.testing.expectEqualStrings(CONTENT_TYPE_JSON, ctx.response_content_type);
    try std.testing.expectEqualStrings("{\"error\":\"wechat callback not configured\"}", ctx.response_body);
}

test "handleWeComWebhookRoute requires secure callback configuration" {
    if (!build_options.enable_channel_wecom) return;

    const wecom_accounts = [_]config_types.WeComConfig{
        .{
            .account_id = "main",
            .webhook_url = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=main",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{ .wecom = &wecom_accounts },
    };

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();

    const raw_request =
        "POST /wecom HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Type: application/xml\r\n\r\n" ++
        "<xml></xml>";
    var ctx = WebhookHandlerContext{
        .root_allocator = std.testing.allocator,
        .req_allocator = std.testing.allocator,
        .raw_request = raw_request,
        .method = "POST",
        .target = "/wecom",
        .config_opt = &cfg,
        .state = &state,
        .session_mgr_opt = null,
    };

    handleWeComWebhookRoute(&ctx);
    try std.testing.expectEqualStrings("404 Not Found", ctx.response_status);
    try std.testing.expectEqualStrings(CONTENT_TYPE_JSON, ctx.response_content_type);
    try std.testing.expectEqualStrings("{\"error\":\"wecom secure callback not configured\"}", ctx.response_body);
}

test "selectQqConfig picks account by X-Bot-Appid header" {
    const qq_accounts = [_]config_types.QQConfig{
        .{
            .account_id = "main",
            .app_id = "app-main",
            .app_secret = "secret-main",
        },
        .{
            .account_id = "backup",
            .app_id = "app-backup",
            .app_secret = "secret-backup",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .qq = &qq_accounts,
        },
    };

    const selected = selectQqConfig(&cfg, "/qq", "app-backup");
    if (!build_options.enable_channel_qq) {
        try std.testing.expect(selected == null);
        return;
    }
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("backup", selected.?.account_id);
}

test "selectQqConfig falls back to primary account" {
    const qq_accounts = [_]config_types.QQConfig{
        .{
            .account_id = "z-last",
            .app_id = "app-z",
            .app_secret = "secret-z",
        },
        .{
            .account_id = "default",
            .app_id = "app-default",
            .app_secret = "secret-default",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .qq = &qq_accounts,
        },
    };

    const selected = selectQqConfig(&cfg, "/qq", null);
    if (!build_options.enable_channel_qq) {
        try std.testing.expect(selected == null);
        return;
    }
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("default", selected.?.account_id);
}

test "handleQqWebhookRoute rejects invalid json payload" {
    if (!build_options.enable_channel_qq) return;

    const qq_accounts = [_]config_types.QQConfig{
        .{
            .account_id = "main",
            .app_id = "app-main",
            .app_secret = "secret-main",
            .receive_mode = .webhook,
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .qq = &qq_accounts,
        },
    };

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();

    const raw_request =
        "POST /qq HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "X-Bot-Appid: app-main\r\n" ++
        "Content-Type: application/json\r\n\r\n" ++
        "{invalid";
    var ctx = WebhookHandlerContext{
        .root_allocator = std.testing.allocator,
        .req_allocator = std.testing.allocator,
        .raw_request = raw_request,
        .method = "POST",
        .target = "/qq",
        .config_opt = &cfg,
        .state = &state,
        .session_mgr_opt = null,
    };

    handleQqWebhookRoute(&ctx);
    try std.testing.expectEqualStrings("400 Bad Request", ctx.response_status);
    try std.testing.expectEqualStrings("{\"error\":\"invalid json payload\"}", ctx.response_body);
}

fn testEncodeWeChatSecurePayload(
    allocator: std.mem.Allocator,
    encoding_aes_key: []const u8,
    app_id: []const u8,
    plain_xml: []const u8,
) ![]u8 {
    const key = tencent_crypto.decodeEncodingAesKey(encoding_aes_key) catch {
        return error.InvalidWeChatEncodingAesKey;
    };

    var plain: std.ArrayListUnmanaged(u8) = .empty;
    defer plain.deinit(allocator);
    try plain.appendSlice(allocator, "0123456789ABCDEF");

    const msg_len = plain_xml.len;
    try plain.append(allocator, @as(u8, @truncate((msg_len >> 24) & 0xff)));
    try plain.append(allocator, @as(u8, @truncate((msg_len >> 16) & 0xff)));
    try plain.append(allocator, @as(u8, @truncate((msg_len >> 8) & 0xff)));
    try plain.append(allocator, @as(u8, @truncate(msg_len & 0xff)));
    try plain.appendSlice(allocator, plain_xml);
    try plain.appendSlice(allocator, app_id);

    const cipher = tencent_crypto.aesCbcEncrypt(
        allocator,
        key,
        key[0..16].*,
        plain.items,
        tencent_crypto.WECHAT_PKCS7_BLOCK,
    ) catch |err| switch (err) {
        error.InvalidBlockSize => unreachable,
        else => return err,
    };
    defer allocator.free(cipher);

    const encoded_len = std.base64.standard.Encoder.calcSize(cipher.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, cipher);
    return encoded;
}

test "signed webhook timestamp freshness accepts bounded skew and rejects stale values" {
    const now: i64 = 1_710_000_000;
    try std.testing.expect(isFreshSignedWebhookTimestampAt("1710000000", now, SIGNED_WEBHOOK_MAX_SKEW_SECS));
    try std.testing.expect(isFreshSignedWebhookTimestampAt("1709999700", now, SIGNED_WEBHOOK_MAX_SKEW_SECS));
    try std.testing.expect(!isFreshSignedWebhookTimestampAt("1709999699", now, SIGNED_WEBHOOK_MAX_SKEW_SECS));
    try std.testing.expect(!isFreshSignedWebhookTimestampAt("not-a-timestamp", now, SIGNED_WEBHOOK_MAX_SKEW_SECS));
}

test "handleWeChatWebhookRoute accepts secure encrypted callback" {
    if (!build_options.enable_channel_wechat) return;

    const token = "wechat-token";
    const app_id = "wx_test_app";
    var raw_key: [32]u8 = undefined;
    for (&raw_key, 0..) |*b, idx| b.* = @as(u8, @intCast(idx));
    var key_b64: [44]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key_b64, &raw_key);
    const encoding_aes_key = key_b64[0..43];
    var timestamp_buf: [32]u8 = undefined;
    const timestamp = try std.fmt.bufPrint(&timestamp_buf, "{d}", .{std_compat.time.timestamp()});
    const nonce = "123456";
    const plain_xml = try std.fmt.allocPrint(
        std.testing.allocator,
        "<xml>" ++
            "<ToUserName><![CDATA[gh_abcdef]]></ToUserName>" ++
            "<FromUserName><![CDATA[o_user123]]></FromUserName>" ++
            "<CreateTime>{s}</CreateTime>" ++
            "<MsgType><![CDATA[text]]></MsgType>" ++
            "<Content><![CDATA[hello secure]]></Content>" ++
            "</xml>",
        .{timestamp},
    );
    defer std.testing.allocator.free(plain_xml);

    const encrypted = try testEncodeWeChatSecurePayload(std.testing.allocator, encoding_aes_key, app_id, plain_xml);
    defer std.testing.allocator.free(encrypted);
    const msg_sig = tencent_crypto.wechatMessageSha1Signature(token, timestamp, nonce, encrypted);

    const secure_body = try std.fmt.allocPrint(
        std.testing.allocator,
        "<xml><ToUserName><![CDATA[gh_abcdef]]></ToUserName><Encrypt><![CDATA[{s}]]></Encrypt></xml>",
        .{encrypted},
    );
    defer std.testing.allocator.free(secure_body);

    const target = try std.fmt.allocPrint(
        std.testing.allocator,
        "/wechat?timestamp={s}&nonce={s}&msg_signature={s}",
        .{ timestamp, nonce, msg_sig },
    );
    defer std.testing.allocator.free(target);

    const raw_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "POST {s} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/xml\r\n\r\n{s}",
        .{ target, secure_body },
    );
    defer std.testing.allocator.free(raw_request);

    const wechat_accounts = [_]config_types.WeChatConfig{
        .{
            .account_id = "main",
            .callback_token = token,
            .encoding_aes_key = encoding_aes_key,
            .app_id = app_id,
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{ .wechat = &wechat_accounts },
    };

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();

    var ctx = WebhookHandlerContext{
        .root_allocator = std.testing.allocator,
        .req_allocator = std.testing.allocator,
        .raw_request = raw_request,
        .method = "POST",
        .target = target,
        .config_opt = &cfg,
        .state = &state,
        .session_mgr_opt = null,
    };

    handleWeChatWebhookRoute(&ctx);
    try std.testing.expectEqualStrings("200 OK", ctx.response_status);
    try std.testing.expectEqualStrings(CONTENT_TYPE_TEXT, ctx.response_content_type);
    try std.testing.expectEqualStrings("success", ctx.response_body);
}

test "handleWeChatWebhookRoute rejects stale signed callbacks" {
    if (!build_options.enable_channel_wechat) return;

    const token = "wechat-token";
    const now = std_compat.time.timestamp();
    var timestamp_buf: [32]u8 = undefined;
    const timestamp = try std.fmt.bufPrint(&timestamp_buf, "{d}", .{now - SIGNED_WEBHOOK_MAX_SKEW_SECS - 1});
    const nonce = "123456";
    const signature = tencent_crypto.wechatSha1Signature(token, timestamp, nonce);
    const target = try std.fmt.allocPrint(
        std.testing.allocator,
        "/wechat?timestamp={s}&nonce={s}&signature={s}&echostr=ok",
        .{ timestamp, nonce, signature },
    );
    defer std.testing.allocator.free(target);

    const raw_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "GET {s} HTTP/1.1\r\nHost: localhost\r\n\r\n",
        .{target},
    );
    defer std.testing.allocator.free(raw_request);

    const wechat_accounts = [_]config_types.WeChatConfig{
        .{
            .account_id = "main",
            .callback_token = token,
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{ .wechat = &wechat_accounts },
    };

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();

    var ctx = WebhookHandlerContext{
        .root_allocator = std.testing.allocator,
        .req_allocator = std.testing.allocator,
        .raw_request = raw_request,
        .method = "GET",
        .target = target,
        .config_opt = &cfg,
        .state = &state,
        .session_mgr_opt = null,
    };

    handleWeChatWebhookRoute(&ctx);
    try std.testing.expectEqualStrings("403 Forbidden", ctx.response_status);
    try std.testing.expectEqualStrings("{\"error\":\"stale timestamp\"}", ctx.response_body);
}

test "handleWeComWebhookRoute rejects stale signed callbacks" {
    if (!build_options.enable_channel_wecom) return;

    const token = "wecom-token";
    const corp_id = "wxcorp123";
    var raw_key: [32]u8 = undefined;
    for (&raw_key, 0..) |*b, idx| b.* = @as(u8, @intCast(idx));
    var key_b64: [44]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key_b64, &raw_key);
    const encoding_aes_key = key_b64[0..43];

    const now = std_compat.time.timestamp();
    var timestamp_buf: [32]u8 = undefined;
    const timestamp = try std.fmt.bufPrint(&timestamp_buf, "{d}", .{now - SIGNED_WEBHOOK_MAX_SKEW_SECS - 1});
    const nonce = "654321";
    const echo_str = try testEncodeWeChatSecurePayload(std.testing.allocator, encoding_aes_key, corp_id, "echo-ok");
    defer std.testing.allocator.free(echo_str);
    const msg_sig = tencent_crypto.wechatMessageSha1Signature(token, timestamp, nonce, echo_str);

    const target = try std.fmt.allocPrint(
        std.testing.allocator,
        "/wecom?timestamp={s}&nonce={s}&msg_signature={s}&echostr={s}",
        .{ timestamp, nonce, msg_sig, echo_str },
    );
    defer std.testing.allocator.free(target);

    const raw_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "GET {s} HTTP/1.1\r\nHost: localhost\r\n\r\n",
        .{target},
    );
    defer std.testing.allocator.free(raw_request);

    const wecom_accounts = [_]config_types.WeComConfig{
        .{
            .account_id = "main",
            .webhook_url = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=main",
            .callback_token = token,
            .encoding_aes_key = encoding_aes_key,
            .corp_id = corp_id,
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{ .wecom = &wecom_accounts },
    };

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();

    var ctx = WebhookHandlerContext{
        .root_allocator = std.testing.allocator,
        .req_allocator = std.testing.allocator,
        .raw_request = raw_request,
        .method = "GET",
        .target = target,
        .config_opt = &cfg,
        .state = &state,
        .session_mgr_opt = null,
    };

    handleWeComWebhookRoute(&ctx);
    try std.testing.expectEqualStrings("403 Forbidden", ctx.response_status);
    try std.testing.expectEqualStrings("{\"error\":\"stale timestamp\"}", ctx.response_body);
}

test "whatsappSessionKey builds direct key by sender" {
    const body = "{\"from\":\"15550001111\",\"text\":{\"body\":\"hi\"}}";
    var key_buf: [256]u8 = undefined;
    const key = whatsappSessionKey(&key_buf, body);
    try std.testing.expectEqualStrings("whatsapp:15550001111", key);
}

test "whatsappSessionKey builds group key when group id exists" {
    const body = "{\"from\":\"15550001111\",\"context\":{\"group_jid\":\"1203630@g.us\"},\"text\":{\"body\":\"hi\"}}";
    var key_buf: [256]u8 = undefined;
    const key = whatsappSessionKey(&key_buf, body);
    try std.testing.expectEqualStrings("whatsapp:group:1203630@g.us:15550001111", key);
}

test "telegramSenderAllowed permits when allow_from is empty" {
    const allocator = std.testing.allocator;
    const body =
        \\{"message":{"from":{"id":12345,"username":"alice"}}}
    ;
    try std.testing.expect(telegramSenderAllowed(allocator, &.{}, body));
}

test "telegramChatId extracts nested message.chat.id" {
    const allocator = std.testing.allocator;
    const body =
        \\{"update_id":1,"message":{"chat":{"id":-100777},"from":{"id":12345},"text":"hi"}}
    ;
    try std.testing.expectEqual(@as(i64, -100777), telegramChatId(allocator, body).?);
}

test "telegramChatId falls back to flat chat_id for backward compatibility" {
    const allocator = std.testing.allocator;
    const body = "{\"chat_id\":12345,\"text\":\"hi\"}";
    try std.testing.expectEqual(@as(i64, 12345), telegramChatId(allocator, body).?);
}

test "telegramWebhookTarget extracts topic thread id from message" {
    const allocator = std.testing.allocator;
    const body =
        \\{"message":{"chat":{"id":-100777,"type":"supergroup"},"message_thread_id":42,"text":"hi"}}
    ;
    const target = telegramWebhookTarget(allocator, body) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(i64, -100777), target.chat_id);
    try std.testing.expect(target.is_group);
    try std.testing.expectEqual(@as(?i64, 42), target.message_thread_id);
}

test "telegramWebhookTarget falls back to reply message id for topic replies" {
    const allocator = std.testing.allocator;
    const body =
        \\{"message":{"chat":{"id":-100777,"type":"supergroup"},"is_topic_message":true,"reply_to_message":{"message_id":88},"text":"hi"}}
    ;
    const target = telegramWebhookTarget(allocator, body) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(?i64, 88), target.message_thread_id);
}

test "telegramSenderAllowed matches numeric sender id from nested from object" {
    const allocator = std.testing.allocator;
    const allow_from = [_][]const u8{"12345"};
    const body =
        \\{"message":{"from":{"id":12345},"chat":{"id":-100777}}}
    ;
    try std.testing.expect(telegramSenderAllowed(allocator, &allow_from, body));
}

test "telegramSenderAllowed does not confuse chat id with sender id" {
    const allocator = std.testing.allocator;
    const allow_from = [_][]const u8{"-100777"};
    const body =
        \\{"message":{"from":{"id":12345},"chat":{"id":-100777}}}
    ;
    try std.testing.expect(!telegramSenderAllowed(allocator, &allow_from, body));
}

test "telegramSenderAllowed rejects sender outside allowlist" {
    const allocator = std.testing.allocator;
    const allow_from = [_][]const u8{"alice"};
    const body =
        \\{"message":{"from":{"id":12345}}}
    ;
    try std.testing.expect(!telegramSenderAllowed(allocator, &allow_from, body));
}

test "telegramSenderIdentity falls back to numeric id when username is missing" {
    const allocator = std.testing.allocator;
    var sender_buf: [32]u8 = undefined;
    const body =
        \\{"message":{"from":{"id":12345},"chat":{"id":-100777}}}
    ;
    try std.testing.expectEqualStrings("12345", telegramSenderIdentity(allocator, body, &sender_buf));
}

test "whatsappSenderAllowed direct respects allow_from" {
    const allow_from = [_][]const u8{"+1111111111"};
    try std.testing.expect(whatsappSenderAllowed("+1111111111", false, null, &allow_from, &.{}, &.{}, "allowlist"));
    try std.testing.expect(!whatsappSenderAllowed("+2222222222", false, null, &allow_from, &.{}, &.{}, "allowlist"));
}

test "whatsappSenderAllowed direct denies all when allow_from is empty" {
    try std.testing.expect(!whatsappSenderAllowed("+1111111111", false, null, &.{}, &.{}, &.{}, "allowlist"));
}

test "whatsappSenderAllowed group open bypasses allow_from" {
    const allow_from = [_][]const u8{"+1111111111"};
    try std.testing.expect(whatsappSenderAllowed("+2222222222", true, "1203630@g.us", &allow_from, &.{}, &.{}, "open"));
}

test "whatsappSenderAllowed open policy still respects explicit groups allowlist" {
    const allow_from = [_][]const u8{"+1111111111"};
    const groups = [_][]const u8{"1203630@g.us"};
    try std.testing.expect(whatsappSenderAllowed("+2222222222", true, "1203630@g.us", &allow_from, &.{}, &groups, "open"));
    try std.testing.expect(!whatsappSenderAllowed("+2222222222", true, "1203631@g.us", &allow_from, &.{}, &groups, "open"));
}

test "whatsappSenderAllowed group allowlist uses groups and sender allowlists" {
    const allow_from = [_][]const u8{"+1111111111"};
    const group_allow = [_][]const u8{"+3333333333"};
    const groups = [_][]const u8{"1203630@g.us"};

    try std.testing.expect(whatsappSenderAllowed("+3333333333", true, "1203630@g.us", &allow_from, &group_allow, &groups, "allowlist"));
    try std.testing.expect(!whatsappSenderAllowed("+1111111111", true, "1203630@g.us", &allow_from, &group_allow, &groups, "allowlist"));

    try std.testing.expect(whatsappSenderAllowed("+1111111111", true, "1203630@g.us", &allow_from, &.{}, &groups, "allowlist"));
    try std.testing.expect(!whatsappSenderAllowed("+1111111111", true, "1203631@g.us", &allow_from, &.{}, &groups, "allowlist"));
    try std.testing.expect(!whatsappSenderAllowed("+9999999999", true, "1203630@g.us", &.{}, &.{}, &groups, "allowlist"));
    try std.testing.expect(!whatsappSenderAllowed("+1111111111", true, "1203630@g.us", &allow_from, &.{}, &.{}, "allowlist"));
}

test "whatsappSenderAllowed matches with and without plus prefix" {
    const allow_with_plus = [_][]const u8{"+15550001111"};
    const allow_without_plus = [_][]const u8{"15550001111"};

    try std.testing.expect(whatsappSenderAllowed("15550001111", false, null, &allow_with_plus, &.{}, &.{}, "allowlist"));
    try std.testing.expect(whatsappSenderAllowed("+15550001111", false, null, &allow_without_plus, &.{}, &.{}, "allowlist"));
}

test "whatsappSessionKeyRouted falls back without config" {
    const allocator = std.testing.allocator;
    const body = "{\"from\":\"15550001111\",\"text\":{\"body\":\"hi\"}}";
    var key_buf: [256]u8 = undefined;
    const key = whatsappSessionKeyRouted(allocator, &key_buf, body, null, "default");
    try std.testing.expectEqualStrings("whatsapp:15550001111", key);
}

test "whatsappSessionKeyRouted uses route engine when config exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body = "{\"from\":\"15550001111\",\"group_jid\":\"1203630@g.us\",\"text\":{\"body\":\"hi\"}}";
    var key_buf: [256]u8 = undefined;

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "wa-agent",
                .match = .{
                    .channel = "whatsapp",
                    .account_id = "wa-prod",
                    .peer = .{ .kind = .group, .id = "1203630@g.us" },
                },
            },
        },
    };

    const key = whatsappSessionKeyRouted(allocator, &key_buf, body, &cfg, "wa-prod");
    try std.testing.expectEqualStrings("agent:wa-agent:whatsapp:group:1203630@g.us", key);
}

test "whatsappSessionKeyRouted uses nested context.group_jid for group routing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body = "{\"from\":\"15550001111\",\"context\":{\"group_jid\":\"1203631@g.us\"},\"text\":{\"body\":\"hi\"}}";
    var key_buf: [256]u8 = undefined;

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "wa-context-agent",
                .match = .{
                    .channel = "whatsapp",
                    .account_id = "wa-main",
                    .peer = .{ .kind = .group, .id = "1203631@g.us" },
                },
            },
        },
    };

    const key = whatsappSessionKeyRouted(allocator, &key_buf, body, &cfg, "wa-main");
    try std.testing.expectEqualStrings("agent:wa-context-agent:whatsapp:group:1203631@g.us", key);
}

test "telegramSessionKeyRouted uses group peer for group chats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body =
        \\{"message":{"chat":{"id":-10012345,"type":"supergroup"}}}
    ;
    var key_buf: [128]u8 = undefined;

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "tg-group-agent",
                .match = .{
                    .channel = "telegram",
                    .account_id = "tg-main",
                    .peer = .{ .kind = .group, .id = "-10012345" },
                },
            },
        },
    };

    const key = telegramSessionKeyRouted(allocator, &key_buf, body, &cfg, "tg-main");
    try std.testing.expectEqualStrings("agent:tg-group-agent:telegram:group:-10012345", key);
}

test "telegramSessionKeyRouted uses direct peer for private chats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body =
        \\{"message":{"chat":{"id":4242,"type":"private"}}}
    ;
    var key_buf: [128]u8 = undefined;

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "tg-dm-agent",
                .match = .{
                    .channel = "telegram",
                    .account_id = "tg-main",
                    .peer = .{ .kind = .direct, .id = "4242" },
                },
            },
        },
    };

    const key = telegramSessionKeyRouted(allocator, &key_buf, body, &cfg, "tg-main");
    try std.testing.expectEqualStrings("agent:tg-dm-agent:telegram:direct:4242", key);
}

test "telegramSessionKeyRouted applies session dm_scope for direct chats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body =
        \\{"message":{"chat":{"id":4242,"type":"private"}}}
    ;
    var key_buf: [128]u8 = undefined;

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "tg-dm-agent",
                .match = .{
                    .channel = "telegram",
                    .account_id = "tg-main",
                    .peer = .{ .kind = .direct, .id = "4242" },
                },
            },
        },
        .session = .{
            .dm_scope = .per_peer,
        },
    };

    const key = telegramSessionKeyRouted(allocator, &key_buf, body, &cfg, "tg-main");
    try std.testing.expectEqualStrings("agent:tg-dm-agent:direct:4242", key);
}

test "telegramSessionKeyRouted uses topic peer before group fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body =
        \\{"message":{"chat":{"id":-10012345,"type":"supergroup"},"message_thread_id":42,"text":"hi"}}
    ;
    var key_buf: [128]u8 = undefined;

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "tg-topic-agent",
                .match = .{
                    .channel = "telegram",
                    .account_id = "tg-main",
                    .peer = .{ .kind = .group, .id = "-10012345:thread:42" },
                },
            },
            .{
                .agent_id = "tg-group-agent",
                .match = .{
                    .channel = "telegram",
                    .account_id = "tg-main",
                    .peer = .{ .kind = .group, .id = "-10012345" },
                },
            },
        },
    };

    const key = telegramSessionKeyRouted(allocator, &key_buf, body, &cfg, "tg-main");
    try std.testing.expectEqualStrings("agent:tg-topic-agent:telegram:group:-10012345:thread:42", key);
}

test "lineSessionKeyRouted uses group id for group events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var key_buf: [128]u8 = undefined;
    const evt = channels.line.LineEvent{
        .event_type = "message",
        .user_id = "U111",
        .group_id = "G222",
        .source_type = "group",
    };

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "line-group-agent",
                .match = .{
                    .channel = "line",
                    .account_id = "line-main",
                    .peer = .{ .kind = .group, .id = "group:G222" },
                },
            },
        },
    };

    const key = lineSessionKeyRouted(allocator, &key_buf, evt, &cfg, "line-main");
    try std.testing.expectEqualStrings("agent:line-group-agent:line:group:group:G222", key);
}

test "lineSessionKeyRouted falls back to user session key without config" {
    const allocator = std.testing.allocator;
    var key_buf: [128]u8 = undefined;
    const evt = channels.line.LineEvent{
        .event_type = "message",
        .user_id = "U777",
    };

    const key = lineSessionKeyRouted(allocator, &key_buf, evt, null, "default");
    try std.testing.expectEqualStrings("line:U777", key);
}

test "lineSessionKeyRouted uses room-prefixed peer id for room events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var key_buf: [128]u8 = undefined;
    const evt = channels.line.LineEvent{
        .event_type = "message",
        .user_id = "U111",
        .room_id = "R333",
        .source_type = "room",
    };

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "line-room-agent",
                .match = .{
                    .channel = "line",
                    .account_id = "line-main",
                    .peer = .{ .kind = .group, .id = "room:R333" },
                },
            },
        },
    };

    const key = lineSessionKeyRouted(allocator, &key_buf, evt, &cfg, "line-main");
    try std.testing.expectEqualStrings("agent:line-room-agent:line:group:room:R333", key);
}

test "lineReplyTarget resolves conversation target for group events" {
    const evt = channels.line.LineEvent{
        .event_type = "message",
        .user_id = "U111",
        .group_id = "G222",
        .source_type = "group",
    };
    try std.testing.expectEqualStrings("G222", lineReplyTarget(evt));
}

test "lineReplyTarget resolves conversation target for room events" {
    const evt = channels.line.LineEvent{
        .event_type = "message",
        .user_id = "U111",
        .room_id = "R333",
        .source_type = "room",
    };
    try std.testing.expectEqualStrings("R333", lineReplyTarget(evt));
}

test "lineReplyTarget falls back to user for direct events" {
    const evt = channels.line.LineEvent{
        .event_type = "message",
        .user_id = "U111",
        .source_type = "user",
    };
    try std.testing.expectEqualStrings("U111", lineReplyTarget(evt));
}

test "larkSessionKeyRouted uses route engine when config exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var key_buf: [128]u8 = undefined;
    const msg = channels.lark.ParsedLarkMessage{
        .sender = "ou_abc123",
        .content = "hello",
        .timestamp = 123,
        .is_group = true,
    };

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "lark-group-agent",
                .match = .{
                    .channel = "lark",
                    .account_id = "lark-main",
                    .peer = .{ .kind = .group, .id = "ou_abc123" },
                },
            },
        },
    };

    const key = larkSessionKeyRouted(allocator, &key_buf, msg, &cfg, "lark-main");
    try std.testing.expectEqualStrings("agent:lark-group-agent:lark:group:ou_abc123", key);
}

test "wecomSessionKeyRouted uses route engine when config exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var key_buf: [128]u8 = undefined;
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "wecom-dm-agent",
                .match = .{
                    .channel = "wecom",
                    .account_id = "wecom-main",
                    .peer = .{ .kind = .direct, .id = "zhangsan" },
                },
            },
        },
    };

    const key = wecomSessionKeyRouted(allocator, &key_buf, "zhangsan", &cfg, "wecom-main");
    try std.testing.expectEqualStrings("agent:wecom-dm-agent:wecom:direct:zhangsan", key);
}

test "wechatSessionKeyRouted uses route engine when config exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var key_buf: [128]u8 = undefined;
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "wechat-dm-agent",
                .match = .{
                    .channel = "wechat",
                    .account_id = "wechat-main",
                    .peer = .{ .kind = .direct, .id = "openid_123" },
                },
            },
        },
    };

    const key = wechatSessionKeyRouted(allocator, &key_buf, "openid_123", &cfg, "wechat-main");
    try std.testing.expectEqualStrings("agent:wechat-dm-agent:wechat:direct:openid_123", key);
}

test "maxSessionKeyRouted uses sender identity for direct chats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var key_buf: [128]u8 = undefined;
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "max-direct-agent",
                .match = .{
                    .channel = "max",
                    .account_id = "max-main",
                    .peer = .{ .kind = .direct, .id = "alice" },
                },
            },
        },
    };

    const key = maxSessionKeyRouted(allocator, &key_buf, "alice", "dialog-123", false, &cfg, "max-main");
    try std.testing.expectEqualStrings("agent:max-direct-agent:max:direct:alice", key);
}

test "maxSessionKeyRouted uses chat target for group chats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var key_buf: [128]u8 = undefined;
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "max-group-agent",
                .match = .{
                    .channel = "max",
                    .account_id = "max-main",
                    .peer = .{ .kind = .group, .id = "chat-777" },
                },
            },
        },
    };

    const key = maxSessionKeyRouted(allocator, &key_buf, "alice", "chat-777", true, &cfg, "max-main");
    try std.testing.expectEqualStrings("agent:max-group-agent:max:group:chat-777", key);
}

test "qqSessionKeyRouted uses sender identity for direct chats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "qq-direct-agent",
                .match = .{
                    .channel = "qq",
                    .account_id = "qq-main",
                    .peer = .{ .kind = .direct, .id = "openid-user" },
                },
            },
        },
    };

    const inbound = try bus_mod.makeInboundFull(
        allocator,
        "qq",
        "openid-user",
        "c2c:openid-user:msg001",
        "hello",
        "qq:c2c:openid-user",
        &.{},
        "{\"account_id\":\"qq-main\",\"is_dm\":true,\"user_openid\":\"openid-user\"}",
    );
    defer inbound.deinit(allocator);

    const key = qqSessionKeyRouted(allocator, &inbound, &cfg) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("agent:qq-direct-agent:qq:direct:openid-user", key);
}

test "teamsSessionKeyRouted uses sender identity for personal chats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var key_buf: [256]u8 = undefined;
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "teams-direct-agent",
                .match = .{
                    .channel = "teams",
                    .account_id = "teams-main",
                    .peer = .{ .kind = .direct, .id = "user-42" },
                },
            },
        },
    };

    const body =
        \\{"type":"message","text":"hi","conversation":{"id":"conv-1","conversationType":"personal"},"from":{"id":"user-42"}}
    ;
    const key = teamsSessionKeyRouted(allocator, &key_buf, &cfg, body, "teams-main", "tenant-1", "conv-1", "user-42");
    try std.testing.expectEqualStrings("agent:teams-direct-agent:teams:direct:user-42", key);
}

test "teamsSessionKeyRouted uses conversation id for channel chats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var key_buf: [256]u8 = undefined;
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "teams-channel-agent",
                .match = .{
                    .channel = "teams",
                    .account_id = "teams-main",
                    .peer = .{ .kind = .channel, .id = "conv-chan" },
                },
            },
        },
    };

    const body =
        \\{"type":"message","text":"hi","conversation":{"id":"conv-chan","conversationType":"channel"},"from":{"id":"user-42"}}
    ;
    const key = teamsSessionKeyRouted(allocator, &key_buf, &cfg, body, "teams-main", "tenant-1", "conv-chan", "user-42");
    try std.testing.expectEqualStrings("agent:teams-channel-agent:teams:channel:conv-chan", key);
}

fn buildTeamsWebhookRequest(
    allocator: std.mem.Allocator,
    bearer_token: ?[]const u8,
    webhook_secret: ?[]const u8,
    body: []const u8,
) ![]u8 {
    const auth_header = if (bearer_token) |token|
        try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}\r\n", .{token})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(auth_header);

    const secret_header = if (webhook_secret) |secret|
        try std.fmt.allocPrint(allocator, "X-Webhook-Secret: {s}\r\n", .{secret})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(secret_header);

    return std.fmt.allocPrint(
        allocator,
        "POST /api/messages HTTP/1.1\r\nHost: localhost\r\n{s}{s}Content-Type: application/json\r\n\r\n{s}",
        .{ auth_header, secret_header, body },
    );
}

test "handleTeamsWebhookRoute rejects missing bearer token" {
    if (!build_options.enable_channel_teams) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const teams_accounts = [_]config_types.TeamsConfig{
        .{
            .account_id = "default",
            .client_id = "test-app-id",
            .client_secret = "teams-secret",
            .tenant_id = "tenant-1",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .channels = .{ .teams = &teams_accounts },
    };

    const body =
        \\{"type":"message","text":"hi","serviceUrl":"https://smba.trafficmanager.net/amer/","channelId":"msteams","conversation":{"id":"conv-1","conversationType":"personal"},"from":{"id":"user-42","name":"Alice"},"channelData":{"tenant":{"id":"tenant-1"}}}
    ;
    const raw_request = try buildTeamsWebhookRequest(allocator, null, null, body);

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();

    var ctx = WebhookHandlerContext{
        .root_allocator = allocator,
        .req_allocator = allocator,
        .raw_request = raw_request,
        .method = "POST",
        .target = "/api/messages",
        .config_opt = &cfg,
        .state = &state,
        .session_mgr_opt = null,
    };

    handleTeamsWebhookRoute(&ctx);
    try std.testing.expectEqualStrings("403 Forbidden", ctx.response_status);
    try std.testing.expectEqualStrings("{\"error\":\"forbidden\"}", ctx.response_body);
}

test "handleTeamsWebhookRoute accepts valid connector JWT" {
    if (!build_options.enable_channel_teams) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const teams_accounts = [_]config_types.TeamsConfig{
        .{
            .account_id = "default",
            .client_id = "test-app-id",
            .client_secret = "teams-secret",
            .tenant_id = "tenant-1",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .channels = .{ .teams = &teams_accounts },
    };

    const body =
        \\{"type":"message","text":"hi","serviceUrl":"https://smba.trafficmanager.net/amer/","channelId":"msteams","conversation":{"id":"conv-1","conversationType":"personal"},"from":{"id":"user-42","name":"Alice"},"channelData":{"tenant":{"id":"tenant-1"}}}
    ;
    const raw_request = try buildTeamsWebhookRequest(allocator, botframework_auth.fixtureTokenForTest(), null, body);

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    try state.teams_auth_cache.seedFixtureForTest(std.testing.allocator);

    var ctx = WebhookHandlerContext{
        .root_allocator = allocator,
        .req_allocator = allocator,
        .raw_request = raw_request,
        .method = "POST",
        .target = "/api/messages",
        .config_opt = &cfg,
        .state = &state,
        .session_mgr_opt = null,
    };

    handleTeamsWebhookRoute(&ctx);
    try std.testing.expectEqualStrings("202 Accepted", ctx.response_status);
    try std.testing.expectEqualStrings("{\"status\":\"accepted\"}", ctx.response_body);
}

test "handleTeamsWebhookRoute selects Teams account by nested tenant id" {
    if (!build_options.enable_channel_teams) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Regression: channelData.tenant is typically an object with an id field.
    const teams_accounts = [_]config_types.TeamsConfig{
        .{
            .account_id = "default",
            .client_id = "wrong-app-id",
            .client_secret = "teams-secret",
            .tenant_id = "tenant-other",
        },
        .{
            .account_id = "tenant-match",
            .client_id = "test-app-id",
            .client_secret = "teams-secret",
            .tenant_id = "tenant-1",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .channels = .{ .teams = &teams_accounts },
    };

    const body =
        \\{"type":"message","text":"hi","serviceUrl":"https://smba.trafficmanager.net/amer/","channelId":"msteams","conversation":{"id":"conv-1","conversationType":"personal"},"from":{"id":"user-42","name":"Alice"},"channelData":{"tenant":{"id":"tenant-1"}}}
    ;
    const raw_request = try buildTeamsWebhookRequest(allocator, botframework_auth.fixtureTokenForTest(), null, body);

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    try state.teams_auth_cache.seedFixtureForTest(std.testing.allocator);

    var ctx = WebhookHandlerContext{
        .root_allocator = allocator,
        .req_allocator = allocator,
        .raw_request = raw_request,
        .method = "POST",
        .target = "/api/messages",
        .config_opt = &cfg,
        .state = &state,
        .session_mgr_opt = null,
    };

    handleTeamsWebhookRoute(&ctx);
    try std.testing.expectEqualStrings("202 Accepted", ctx.response_status);
    try std.testing.expectEqualStrings("{\"status\":\"accepted\"}", ctx.response_body);
}

test "handleTeamsWebhookRoute requires configured webhook secret after JWT validation" {
    if (!build_options.enable_channel_teams) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const teams_accounts = [_]config_types.TeamsConfig{
        .{
            .account_id = "default",
            .client_id = "test-app-id",
            .client_secret = "teams-secret",
            .tenant_id = "tenant-1",
            .webhook_secret = "teams-webhook-secret-012345",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .channels = .{ .teams = &teams_accounts },
    };

    const body =
        \\{"type":"message","text":"hi","serviceUrl":"https://smba.trafficmanager.net/amer/","channelId":"msteams","conversation":{"id":"conv-1","conversationType":"personal"},"from":{"id":"user-42","name":"Alice"},"channelData":{"tenant":{"id":"tenant-1"}}}
    ;
    const raw_request = try buildTeamsWebhookRequest(allocator, botframework_auth.fixtureTokenForTest(), null, body);

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    try state.teams_auth_cache.seedFixtureForTest(std.testing.allocator);

    var ctx = WebhookHandlerContext{
        .root_allocator = allocator,
        .req_allocator = allocator,
        .raw_request = raw_request,
        .method = "POST",
        .target = "/api/messages",
        .config_opt = &cfg,
        .state = &state,
        .session_mgr_opt = null,
    };

    handleTeamsWebhookRoute(&ctx);
    try std.testing.expectEqualStrings("401 Unauthorized", ctx.response_status);
    try std.testing.expectEqualStrings("{\"error\":\"unauthorized\"}", ctx.response_body);
}

test "handleTeamsWebhookRoute rejects malformed JSON payload" {
    if (!build_options.enable_channel_teams) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const teams_accounts = [_]config_types.TeamsConfig{
        .{
            .account_id = "default",
            .client_id = "test-app-id",
            .client_secret = "teams-secret",
            .tenant_id = "tenant-1",
            .webhook_secret = "teams-webhook-secret-012345",
        },
    };

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .channels = .{ .teams = &teams_accounts },
    };

    const body = "{\"type\":\"message\",\"text\":"; // Unclosed JSON
    const raw_request = try buildTeamsWebhookRequest(allocator, botframework_auth.fixtureTokenForTest(), null, body);

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    try state.teams_auth_cache.seedFixtureForTest(std.testing.allocator);

    var ctx = WebhookHandlerContext{
        .root_allocator = allocator,
        .req_allocator = allocator,
        .raw_request = raw_request,
        .method = "POST",
        .target = "/api/messages",
        .config_opt = &cfg,
        .state = &state,
        .session_mgr_opt = null,
    };

    handleTeamsWebhookRoute(&ctx);
    try std.testing.expectEqualStrings("400 Bad Request", ctx.response_status);
    try std.testing.expectEqualStrings("{\"error\":\"invalid json payload\"}", ctx.response_body);
}

test "isValidBotFrameworkServiceUrl accepts documented Teams traffic manager host" {
    try std.testing.expect(isValidBotFrameworkServiceUrl("https://smba.trafficmanager.net/amer/"));
    try std.testing.expect(isValidBotFrameworkServiceUrl("https://SMBA.TRAFFICMANAGER.NET/teams/"));
}

test "isValidBotFrameworkServiceUrl rejects unrelated microsoft domains" {
    try std.testing.expect(!isValidBotFrameworkServiceUrl("https://graph.microsoft.com/v1.0"));
    try std.testing.expect(!isValidBotFrameworkServiceUrl("https://contoso.microsoft.com/"));
}

test "webhookRouting uses route engine when standardized peer metadata is present" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "web-direct-agent",
                .match = .{
                    .channel = "web",
                    .account_id = "web-main",
                    .peer = .{ .kind = .direct, .id = "session-1" },
                },
            },
        },
    };

    var routing = webhookRouting(
        allocator,
        "{\"channel\":\"web\",\"account_id\":\"web-main\",\"peer_kind\":\"direct\",\"peer_id\":\"session-1\",\"sender_id\":\"user-1\",\"message\":\"hi\"}",
        "bearer-1",
        &cfg,
    );
    defer routing.deinit(allocator);

    try std.testing.expectEqualStrings("user-1", routing.sender_id);
    try std.testing.expectEqualStrings("session-1", routing.chat_id);
    try std.testing.expectEqualStrings("agent:web-direct-agent:web:direct:session-1", routing.session_key);
    try std.testing.expect(routing.metadata_json != null);
    try std.testing.expect(std.mem.indexOf(u8, routing.metadata_json.?, "\"account_id\":\"web-main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, routing.metadata_json.?, "\"peer_kind\":\"direct\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, routing.metadata_json.?, "\"peer_id\":\"session-1\"") != null);
    try std.testing.expect(routing.conversation_context != null);
    try std.testing.expectEqualStrings("web", routing.conversation_context.?.channel.?);
    try std.testing.expectEqualStrings("session-1", routing.conversation_context.?.delivery_chat_id.?);
    try std.testing.expectEqualStrings("session-1", routing.conversation_context.?.peer_id.?);
}

test "simpleConversationContext keeps delivery target separate from routing peer" {
    const context = simpleConversationContext(
        "slack",
        "slack-main",
        "user-42",
        "D123456",
        false,
        null,
    ) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("slack", context.channel.?);
    try std.testing.expectEqualStrings("slack-main", context.account_id.?);
    try std.testing.expectEqualStrings("D123456", context.delivery_chat_id.?);
    try std.testing.expectEqualStrings("user-42", context.peer_id.?);
    try std.testing.expect(!context.is_group.?);
    try std.testing.expect(context.group_id == null);
}

// ── extractBody tests ────────────────────────────────────────────

test "extractBody finds body after headers" {
    const raw = "POST /webhook HTTP/1.1\r\nHost: localhost\r\n\r\n{\"message\":\"hi\"}";
    const body = extractBody(raw);
    try std.testing.expect(body != null);
    try std.testing.expectEqualStrings("{\"message\":\"hi\"}", body.?);
}

test "extractBody returns null for no body" {
    const raw = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try std.testing.expect(extractBody(raw) == null);
}

test "extractBody returns null for no separator" {
    const raw = "GET /health HTTP/1.1\r\nHost: localhost\r\n";
    try std.testing.expect(extractBody(raw) == null);
}

test "expectedHttpRequestSize returns null when headers are incomplete" {
    const raw = "GET /health HTTP/1.1\r\nHost: localhost\r\n";
    try std.testing.expect(try expectedHttpRequestSize(raw, MAX_BODY_SIZE) == null);
}

test "expectedHttpRequestSize rejects oversized incomplete headers" {
    const raw = try std.testing.allocator.alloc(u8, MAX_HEADER_SIZE + 1);
    defer std.testing.allocator.free(raw);
    for (raw) |*byte| byte.* = 'a';
    try std.testing.expectError(error.RequestTooLarge, expectedHttpRequestSize(raw, MAX_BODY_SIZE));
}

test "expectedHttpRequestSize returns header length for requests without body" {
    const raw = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try std.testing.expectEqual(raw.len, (try expectedHttpRequestSize(raw, MAX_BODY_SIZE)).?);
}

test "expectedHttpRequestSize includes content length payload" {
    const raw = "POST /webhook HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello";
    try std.testing.expectEqual(raw.len, (try expectedHttpRequestSize(raw, MAX_BODY_SIZE)).?);
}

test "expectedHttpRequestSize rejects invalid content length" {
    const raw = "POST /webhook HTTP/1.1\r\nHost: localhost\r\nContent-Length: abc\r\n\r\nhello";
    try std.testing.expectError(error.InvalidContentLength, expectedHttpRequestSize(raw, MAX_BODY_SIZE));
}

test "expectedHttpRequestSize rejects oversized content length" {
    const raw = "POST /webhook HTTP/1.1\r\nHost: localhost\r\nContent-Length: 999999\r\n\r\n";
    try std.testing.expectError(error.RequestTooLarge, expectedHttpRequestSize(raw, MAX_BODY_SIZE));
}

test "expectedHttpRequestSize honors configured max body size" {
    // Regression: gateway.max_body_size_bytes must raise the inbound cap for A2A inlineData uploads.
    const content_length: usize = MAX_BODY_SIZE + 1;
    const raw = try std.fmt.allocPrint(
        std.testing.allocator,
        "POST /webhook HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n",
        .{content_length},
    );
    defer std.testing.allocator.free(raw);

    const expected = (try expectedHttpRequestSize(raw, content_length)).?;
    try std.testing.expectEqual((headerEndOffset(raw).? + content_length), expected);
}

test "readHttpRequestFromReader assembles fragmented request" {
    const ChunkedReader = struct {
        chunks: []const []const u8,
        chunk_idx: usize = 0,
        offset_in_chunk: usize = 0,

        fn read(self: *@This(), out: []u8) !usize {
            while (self.chunk_idx < self.chunks.len and self.offset_in_chunk >= self.chunks[self.chunk_idx].len) {
                self.chunk_idx += 1;
                self.offset_in_chunk = 0;
            }
            if (self.chunk_idx >= self.chunks.len) return 0;

            const chunk = self.chunks[self.chunk_idx];
            const remaining = chunk[self.offset_in_chunk..];
            const n = @min(out.len, remaining.len);
            std.mem.copyForwards(u8, out[0..n], remaining[0..n]);
            self.offset_in_chunk += n;
            return n;
        }
    };

    const expected = "POST /pair HTTP/1.1\r\nHost: localhost\r\nContent-Length: 11\r\n\r\nhello world";
    const chunks = [_][]const u8{
        "POST /pair HTTP/1.1\r\nHo",
        "st: localhost\r\nContent-Length: 11\r\n\r\nhel",
        "lo world",
    };
    var reader = ChunkedReader{ .chunks = chunks[0..] };

    const raw = try readHttpRequestFromReader(std.testing.allocator, &reader, MAX_BODY_SIZE);
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings(expected, raw);
}

test "readHttpRequestFromReader honors configured max body size above default" {
    const ChunkedReader = struct {
        chunks: []const []const u8,
        chunk_idx: usize = 0,
        offset_in_chunk: usize = 0,

        fn read(self: *@This(), out: []u8) !usize {
            while (self.chunk_idx < self.chunks.len and self.offset_in_chunk >= self.chunks[self.chunk_idx].len) {
                self.chunk_idx += 1;
                self.offset_in_chunk = 0;
            }
            if (self.chunk_idx >= self.chunks.len) return 0;

            const chunk = self.chunks[self.chunk_idx];
            const remaining = chunk[self.offset_in_chunk..];
            const n = @min(out.len, remaining.len);
            std.mem.copyForwards(u8, out[0..n], remaining[0..n]);
            self.offset_in_chunk += n;
            return n;
        }
    };

    // Regression: requests larger than 64 KiB must succeed when config raises the limit.
    const body_len = MAX_BODY_SIZE + 1;
    const body = try std.testing.allocator.alloc(u8, body_len);
    defer std.testing.allocator.free(body);
    @memset(body, 'a');

    const header = try std.fmt.allocPrint(
        std.testing.allocator,
        "POST /pair HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n",
        .{body_len},
    );
    defer std.testing.allocator.free(header);

    const request = try std.mem.concat(std.testing.allocator, u8, &.{ header, body });
    defer std.testing.allocator.free(request);

    const split = header.len + 1024;
    const chunks = [_][]const u8{
        request[0..header.len],
        request[header.len..split],
        request[split..],
    };
    var reader = ChunkedReader{ .chunks = chunks[0..] };

    const raw = try readHttpRequestFromReader(std.testing.allocator, &reader, body_len);
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings(request, raw);
}

test "readHttpRequestFromReader returns IncompleteRequest for truncated body" {
    const ChunkedReader = struct {
        chunks: []const []const u8,
        chunk_idx: usize = 0,
        offset_in_chunk: usize = 0,

        fn read(self: *@This(), out: []u8) !usize {
            while (self.chunk_idx < self.chunks.len and self.offset_in_chunk >= self.chunks[self.chunk_idx].len) {
                self.chunk_idx += 1;
                self.offset_in_chunk = 0;
            }
            if (self.chunk_idx >= self.chunks.len) return 0;

            const chunk = self.chunks[self.chunk_idx];
            const remaining = chunk[self.offset_in_chunk..];
            const n = @min(out.len, remaining.len);
            std.mem.copyForwards(u8, out[0..n], remaining[0..n]);
            self.offset_in_chunk += n;
            return n;
        }
    };

    const chunks = [_][]const u8{
        "POST /pair HTTP/1.1\r\nHost: localhost\r\nContent-Length: 8\r\n\r\nabc",
    };
    var reader = ChunkedReader{ .chunks = chunks[0..] };
    try std.testing.expectError(error.IncompleteRequest, readHttpRequestFromReader(std.testing.allocator, &reader, MAX_BODY_SIZE));
}

test "readHttpRequestFromReader maps WouldBlock to RequestTimeout" {
    const TimeoutReader = struct {
        const ReadError = error{ WouldBlock, ConnectionTimedOut };

        fn read(_: *@This(), _: []u8) ReadError!usize {
            return error.WouldBlock;
        }
    };

    var reader = TimeoutReader{};
    try std.testing.expectError(error.RequestTimeout, readHttpRequestFromReader(std.testing.allocator, &reader, MAX_BODY_SIZE));
}

test "readHttpRequestFromReader maps Timeout to RequestTimeout" {
    const TimeoutReader = struct {
        const ReadError = error{ Timeout, ConnectionTimedOut };

        fn read(_: *@This(), _: []u8) ReadError!usize {
            return error.Timeout;
        }
    };

    var reader = TimeoutReader{};
    try std.testing.expectError(error.RequestTimeout, readHttpRequestFromReader(std.testing.allocator, &reader, MAX_BODY_SIZE));
}

test "nextAcceptSleepMs resets to poll interval on WouldBlock" {
    try std.testing.expectEqual(ACCEPT_POLL_INTERVAL_MS, nextAcceptSleepMs(800, error.WouldBlock));
}

test "nextAcceptSleepMs exponentially backs off and caps for non-WouldBlock errors" {
    // Regression #851: repeated accept errors must back off instead of busy-looping.
    const unexpected = error.Unexpected;
    try std.testing.expectEqual(@as(u64, 200), nextAcceptSleepMs(0, unexpected));
    try std.testing.expectEqual(@as(u64, 200), nextAcceptSleepMs(50, unexpected));
    try std.testing.expectEqual(@as(u64, 200), nextAcceptSleepMs(100, unexpected));
    try std.testing.expectEqual(@as(u64, 800), nextAcceptSleepMs(400, unexpected));
    try std.testing.expectEqual(ACCEPT_ERROR_BACKOFF_MAX_MS, nextAcceptSleepMs(900, unexpected));
    try std.testing.expectEqual(ACCEPT_ERROR_BACKOFF_MAX_MS, nextAcceptSleepMs(ACCEPT_ERROR_BACKOFF_MAX_MS, unexpected));
}

test "maybeProbeA2aVision skips probe when a2a is disabled" {
    const ProbeSpy = struct {
        calls: usize = 0,

        fn probeVision(self: *@This(), _: std.mem.Allocator) void {
            self.calls += 1;
        }
    };

    var cfg = Config{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .allocator = std.testing.allocator,
    };
    var spy = ProbeSpy{};
    maybeProbeA2aVision(&spy, std.testing.allocator, &cfg);
    try std.testing.expectEqual(@as(usize, 0), spy.calls);
}

test "maybeProbeA2aVision runs probe when a2a is enabled" {
    const ProbeSpy = struct {
        calls: usize = 0,

        fn probeVision(self: *@This(), _: std.mem.Allocator) void {
            self.calls += 1;
        }
    };

    var cfg = Config{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.a2a.enabled = true;

    var spy = ProbeSpy{};
    maybeProbeA2aVision(&spy, std.testing.allocator, &cfg);
    try std.testing.expectEqual(@as(usize, 1), spy.calls);
}

test "gateway daemon mode keeps local agent runtime lazy even when a2a enabled" {
    var cfg = Config{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.a2a.enabled = true;

    const needs_local_agent = false;
    var local_agent_runtime_opt: ?LocalAgentRuntime = null;

    // Regression: daemon startup must not eagerly build the local A2A runtime,
    // which can synchronously initialize MCP/provider stacks before channels connect.
    if (needs_local_agent) {
        _ = &cfg;
        local_agent_runtime_opt = undefined;
    }

    try std.testing.expect(local_agent_runtime_opt == null);
}

test "local agent runtime keeps policy and memory pointers stable" {
    var cfg = Config{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.memory.backend = "none";
    cfg.security.sandbox.enabled = false;

    var gateway_observer = GatewayThreadObserver.init(std.testing.allocator);
    defer gateway_observer.deinit();

    const runtime_observer = try observability.RuntimeObserver.create(
        std.testing.allocator,
        .{
            .workspace_dir = cfg.workspace_dir,
            .backend = "none",
        },
        &.{},
        &.{gateway_observer.observer()},
    );
    defer runtime_observer.destroy();

    var runtime = try initLocalAgentRuntime(std.testing.allocator, &cfg, runtime_observer, null);
    defer runtime.deinit(std.testing.allocator);

    // Regression: initLocalAgentRuntime returns by value, so runtime-owned
    // pointers must not target locals from inside the initializer.
    try std.testing.expect(runtime.sec_policy.tracker.? == runtime.sec_tracker);
    try std.testing.expect(runtime.session_mgr.policy.? == runtime.sec_policy);
    try std.testing.expect(runtime.mem_rt != null);
    try std.testing.expect(runtime.session_mgr.mem_rt.? == runtime.mem_rt.?);

    var saw_shell = false;
    for (runtime.tools_slice) |tool| {
        if (std.mem.eql(u8, tool.name(), tools_mod.shell.ShellTool.tool_name)) {
            const shell_tool: *tools_mod.shell.ShellTool = @ptrCast(@alignCast(tool.ptr));
            try std.testing.expect(shell_tool.policy.? == runtime.sec_policy);
            saw_shell = true;
            break;
        }
    }
    try std.testing.expect(saw_shell);
}

test "userFacingAgentError maps ProviderDoesNotSupportVision" {
    try std.testing.expectEqualStrings(
        "The current provider does not support image input.",
        userFacingAgentError(error.ProviderDoesNotSupportVision),
    );
}

test "userFacingAgentError maps NoResponseContent" {
    try std.testing.expectEqualStrings(
        "Model returned an empty response. Please try again.",
        userFacingAgentError(error.NoResponseContent),
    );
}

test "userFacingAgentError maps CurlFailed with actionable hint" {
    try std.testing.expectEqualStrings(
        "Network error contacting provider. Check base_url, DNS, proxy, and TLS certificates, then try again.",
        userFacingAgentError(error.CurlFailed),
    );
}

test "userFacingAgentError maps AllProvidersFailed" {
    try std.testing.expectEqualStrings(
        "All configured providers failed for this request. Check model/provider compatibility and credentials.",
        userFacingAgentError(error.AllProvidersFailed),
    );
}

test "userFacingAgentError maps generic error fallback" {
    try std.testing.expectEqualStrings(
        "An error occurred. Try again.",
        userFacingAgentError(error.Unexpected),
    );
}

test "userFacingAgentErrorJson maps NoResponseContent" {
    try std.testing.expectEqualStrings(
        "{\"error\":\"model returned empty response\"}",
        userFacingAgentErrorJson(error.NoResponseContent),
    );
}

test "userFacingAgentErrorJson maps CurlFailed" {
    try std.testing.expectEqualStrings(
        "{\"error\":\"network error contacting provider\"}",
        userFacingAgentErrorJson(error.CurlFailed),
    );
}

test "userFacingAgentErrorJson maps AllProvidersFailed" {
    try std.testing.expectEqualStrings(
        "{\"error\":\"all providers failed for this request\"}",
        userFacingAgentErrorJson(error.AllProvidersFailed),
    );
}

test "userFacingAgentErrorJson maps generic error fallback" {
    try std.testing.expectEqualStrings(
        "{\"error\":\"agent failure\"}",
        userFacingAgentErrorJson(error.Unexpected),
    );
}

test "GatewayState init has empty telegram_bot_token" {
    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expectEqualStrings("", state.telegram_bot_token);
}

// ── asciiEqlIgnoreCase tests ─────────────────────────────────────

test "asciiEqlIgnoreCase equal strings" {
    try std.testing.expect(asciiEqlIgnoreCase("Authorization", "authorization"));
    try std.testing.expect(asciiEqlIgnoreCase("CONTENT-TYPE", "content-type"));
    try std.testing.expect(asciiEqlIgnoreCase("Host", "Host"));
}

test "asciiEqlIgnoreCase different strings" {
    try std.testing.expect(!asciiEqlIgnoreCase("Authorization", "authenticate"));
    try std.testing.expect(!asciiEqlIgnoreCase("a", "ab"));
}

test "asciiEqlIgnoreCase empty strings" {
    try std.testing.expect(asciiEqlIgnoreCase("", ""));
}

// ── WhatsApp HMAC-SHA256 Signature Verification tests ───────────

test "verifyWhatsappSignature valid signature" {
    // Compute a real HMAC-SHA256 and verify it passes
    const body = "{\"entry\":[{\"changes\":[{\"value\":{\"messages\":[{\"text\":{\"body\":\"hello\"}}]}}]}]}";
    const secret = "my_app_secret";
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, body, secret);
    // Format as hex
    var hex_buf: [64]u8 = undefined;
    for (0..32) |i| {
        const byte = mac[i];
        hex_buf[i * 2] = "0123456789abcdef"[byte >> 4];
        hex_buf[i * 2 + 1] = "0123456789abcdef"[byte & 0x0f];
    }
    var header_buf: [71]u8 = undefined; // "sha256=" (7) + 64 hex chars
    @memcpy(header_buf[0..7], "sha256=");
    @memcpy(header_buf[7..71], &hex_buf);
    try std.testing.expect(verifyWhatsappSignature(body, &header_buf, secret));
}

test "verifyWhatsappSignature invalid signature rejected" {
    const body = "{\"message\":\"test\"}";
    const secret = "correct_secret";
    // Provide a well-formed but wrong signature (all zeros)
    const bad_sig = "sha256=0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expect(!verifyWhatsappSignature(body, bad_sig, secret));
}

test "verifyWhatsappSignature missing sha256= prefix rejected" {
    const body = "test body";
    const secret = "secret";
    const no_prefix = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
    try std.testing.expect(!verifyWhatsappSignature(body, no_prefix, secret));
}

test "verifyWhatsappSignature empty body with valid signature" {
    const body = "";
    const secret = "empty_body_secret";
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, body, secret);
    var hex_buf: [64]u8 = undefined;
    for (0..32) |i| {
        const byte = mac[i];
        hex_buf[i * 2] = "0123456789abcdef"[byte >> 4];
        hex_buf[i * 2 + 1] = "0123456789abcdef"[byte & 0x0f];
    }
    var header_buf: [71]u8 = undefined;
    @memcpy(header_buf[0..7], "sha256=");
    @memcpy(header_buf[7..71], &hex_buf);
    try std.testing.expect(verifyWhatsappSignature(body, &header_buf, secret));
}

test "verifyWhatsappSignature empty secret returns false" {
    const body = "any body";
    const sig = "sha256=0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expect(!verifyWhatsappSignature(body, sig, ""));
}

test "verifyWhatsappSignature wrong secret rejected" {
    const body = "{\"data\":\"payload\"}";
    const correct_secret = "real_secret";
    const wrong_secret = "wrong_secret";
    // Compute signature with correct secret
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, body, correct_secret);
    var hex_buf: [64]u8 = undefined;
    for (0..32) |i| {
        const byte = mac[i];
        hex_buf[i * 2] = "0123456789abcdef"[byte >> 4];
        hex_buf[i * 2 + 1] = "0123456789abcdef"[byte & 0x0f];
    }
    var header_buf: [71]u8 = undefined;
    @memcpy(header_buf[0..7], "sha256=");
    @memcpy(header_buf[7..71], &hex_buf);
    // Verify with wrong secret — should fail
    try std.testing.expect(!verifyWhatsappSignature(body, &header_buf, wrong_secret));
}

test "verifyWhatsappSignature constant-time comparison basic check" {
    // Verify that two identical MACs pass and two differing-by-one-bit MACs fail.
    // This doesn't prove constant-time, but ensures the comparison logic is correct.
    const body = "timing test body";
    const secret = "timing_secret";
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, body, secret);

    // constantTimeEql with itself
    try std.testing.expect(constantTimeEql(&mac, &mac));

    // Flip one bit in the last byte
    var altered = mac;
    altered[31] ^= 0x01;
    try std.testing.expect(!constantTimeEql(&mac, &altered));

    // Flip one bit in the first byte
    var altered2 = mac;
    altered2[0] ^= 0x80;
    try std.testing.expect(!constantTimeEql(&mac, &altered2));
}

test "verifyWhatsappSignature hex encoding edge cases" {
    // Truncated hex (too short)
    try std.testing.expect(!verifyWhatsappSignature("body", "sha256=abcdef", "secret"));
    // Too long hex
    try std.testing.expect(!verifyWhatsappSignature("body", "sha256=00000000000000000000000000000000000000000000000000000000000000001", "secret"));
    // Invalid hex characters
    try std.testing.expect(!verifyWhatsappSignature("body", "sha256=zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", "secret"));
    // Empty signature header
    try std.testing.expect(!verifyWhatsappSignature("body", "", "secret"));
    // Just the prefix, no hex
    try std.testing.expect(!verifyWhatsappSignature("body", "sha256=", "secret"));
}

test "verifyWhatsappSignature uppercase hex accepted" {
    // Meta typically sends lowercase, but we accept uppercase too
    const body = "uppercase hex test";
    const secret = "hex_secret";
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, body, secret);
    var hex_buf: [64]u8 = undefined;
    for (0..32) |i| {
        const byte = mac[i];
        hex_buf[i * 2] = "0123456789ABCDEF"[byte >> 4];
        hex_buf[i * 2 + 1] = "0123456789ABCDEF"[byte & 0x0f];
    }
    var header_buf: [71]u8 = undefined;
    @memcpy(header_buf[0..7], "sha256=");
    @memcpy(header_buf[7..71], &hex_buf);
    try std.testing.expect(verifyWhatsappSignature(body, &header_buf, secret));
}

test "verifySlackSignature accepts valid signature" {
    const body = "{\"type\":\"event_callback\"}";
    const secret = "slack_signing_secret";

    var ts_buf: [32]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{std_compat.time.timestamp()}) catch unreachable;

    var signed: std.ArrayListUnmanaged(u8) = .empty;
    defer signed.deinit(std.testing.allocator);
    var signed_writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &signed);
    const sw = &signed_writer.writer;
    try sw.print("v0:{s}:", .{ts});
    try sw.writeAll(body);
    signed = signed_writer.toArrayList();

    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, signed.items, secret);

    var sig_buf: [67]u8 = undefined; // "v0=" + 64 hex
    @memcpy(sig_buf[0..3], "v0=");
    for (0..32) |i| {
        const byte = mac[i];
        sig_buf[3 + i * 2] = "0123456789abcdef"[byte >> 4];
        sig_buf[3 + i * 2 + 1] = "0123456789abcdef"[byte & 0x0f];
    }

    try std.testing.expect(verifySlackSignature(std.testing.allocator, body, ts, &sig_buf, secret));
}

test "verifySlackSignature rejects stale timestamp" {
    const body = "{\"type\":\"event_callback\"}";
    const secret = "slack_signing_secret";

    var ts_buf: [32]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{std_compat.time.timestamp() - 900}) catch unreachable;

    var signed: std.ArrayListUnmanaged(u8) = .empty;
    defer signed.deinit(std.testing.allocator);
    var signed_writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &signed);
    const sw = &signed_writer.writer;
    try sw.print("v0:{s}:", .{ts});
    try sw.writeAll(body);
    signed = signed_writer.toArrayList();

    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, signed.items, secret);

    var sig_buf: [67]u8 = undefined;
    @memcpy(sig_buf[0..3], "v0=");
    for (0..32) |i| {
        const byte = mac[i];
        sig_buf[3 + i * 2] = "0123456789abcdef"[byte >> 4];
        sig_buf[3 + i * 2 + 1] = "0123456789abcdef"[byte & 0x0f];
    }

    try std.testing.expect(!verifySlackSignature(std.testing.allocator, body, ts, &sig_buf, secret));
}

test "verifySlackSignature rejects tampered body" {
    // Compute a valid Slack v0 HMAC-SHA256 signature over the original body,
    // then verify that presenting the same signature with a different body is
    // rejected.  Guards against regressions where body is excluded from the
    // "v0:ts:body" signing input.
    const secret = "slack-signing-secret";
    const original_body = "{\"type\":\"event_callback\",\"event\":{\"text\":\"hello\"}}";
    const tampered_body = "{\"type\":\"event_callback\",\"event\":{\"text\":\"evil\"}}";

    var ts_buf: [32]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{std_compat.time.timestamp()}) catch unreachable;

    var signed: std.ArrayListUnmanaged(u8) = .empty;
    defer signed.deinit(std.testing.allocator);
    var signed_writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &signed);
    const sw = &signed_writer.writer;
    try sw.print("v0:{s}:", .{ts});
    try sw.writeAll(original_body);
    signed = signed_writer.toArrayList();

    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, signed.items, secret);

    var sig_buf: [67]u8 = undefined; // "v0=" + 64 hex chars
    @memcpy(sig_buf[0..3], "v0=");
    for (0..32) |idx| {
        const byte = mac[idx];
        sig_buf[3 + idx * 2] = "0123456789abcdef"[byte >> 4];
        sig_buf[3 + idx * 2 + 1] = "0123456789abcdef"[byte & 0x0f];
    }

    // Original body + correct sig: must accept.
    try std.testing.expect(verifySlackSignature(std.testing.allocator, original_body, ts, &sig_buf, secret));
    // Tampered body + original sig: must reject.
    try std.testing.expect(!verifySlackSignature(std.testing.allocator, tampered_body, ts, &sig_buf, secret));
}

test "hasSlackHttpEndpoint respects mode and webhook_path" {
    const slack_accounts = [_]config_types.SlackConfig{
        .{
            .account_id = "sl-http",
            .mode = .http,
            .bot_token = "xoxb-http",
            .signing_secret = "sec-http",
            .webhook_path = "/slack/custom",
        },
        .{
            .account_id = "sl-socket",
            .mode = .socket,
            .bot_token = "xoxb-socket",
            .app_token = "xapp-socket",
        },
    };
    const cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .slack = &slack_accounts,
        },
    };

    if (!build_options.enable_channel_slack) {
        try std.testing.expect(!hasSlackHttpEndpoint(&cfg, "/slack/custom"));
        try std.testing.expect(!hasSlackHttpEndpoint(&cfg, "/slack/events"));
        try std.testing.expect(!hasSlackHttpEndpoint(&cfg, "/line"));
        return;
    }

    try std.testing.expect(hasSlackHttpEndpoint(&cfg, "/slack/custom"));
    try std.testing.expect(!hasSlackHttpEndpoint(&cfg, "/slack/events"));
    try std.testing.expect(!hasSlackHttpEndpoint(&cfg, "/line"));
}

test "findSlackConfigForRequest selects account by verified signature" {
    const body = "{\"type\":\"event_callback\",\"event\":{\"type\":\"message\",\"channel\":\"C1\",\"user\":\"U1\",\"text\":\"hi\"}}";
    const ts_val = std_compat.time.timestamp();
    var ts_buf: [32]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{ts_val}) catch unreachable;

    const secret_a = "slack_secret_a";
    const secret_b = "slack_secret_b";

    var signed: std.ArrayListUnmanaged(u8) = .empty;
    defer signed.deinit(std.testing.allocator);
    var signed_writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &signed);
    const sw = &signed_writer.writer;
    try sw.print("v0:{s}:", .{ts});
    try sw.writeAll(body);
    signed = signed_writer.toArrayList();

    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac_b: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac_b, signed.items, secret_b);

    var sig_buf: [67]u8 = undefined;
    @memcpy(sig_buf[0..3], "v0=");
    for (0..32) |i| {
        const byte = mac_b[i];
        sig_buf[3 + i * 2] = "0123456789abcdef"[byte >> 4];
        sig_buf[3 + i * 2 + 1] = "0123456789abcdef"[byte & 0x0f];
    }

    const slack_accounts = [_]config_types.SlackConfig{
        .{
            .account_id = "a",
            .mode = .http,
            .bot_token = "xoxb-a",
            .signing_secret = secret_a,
            .webhook_path = "/slack/events",
        },
        .{
            .account_id = "b",
            .mode = .http,
            .bot_token = "xoxb-b",
            .signing_secret = secret_b,
            .webhook_path = "/slack/events",
        },
    };
    const cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .slack = &slack_accounts,
        },
    };

    const selected = findSlackConfigForRequest(std.testing.allocator, &cfg, "/slack/events", body, ts, &sig_buf);
    if (!build_options.enable_channel_slack) {
        try std.testing.expect(selected == null);
        return;
    }
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("b", selected.?.account_id);
}

test "GatewayState init has empty whatsapp_app_secret" {
    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expectEqualStrings("", state.whatsapp_app_secret);
}

// ── /ready endpoint tests ────────────────────────────────────────────

test "handleReady all components healthy returns 200" {
    health.reset();
    health.markComponentOk("gateway");
    health.markComponentOk("database");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("200 OK", resp.http_status);
    // Verify JSON contains "ready" status
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"ready\"") != null);
}

test "handleReady one component unhealthy returns 503" {
    health.reset();
    health.markComponentOk("gateway");
    health.markComponentError("database", "connection refused");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("503 Service Unavailable", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"not_ready\"") != null);
}

test "handleReady no components returns 200 vacuously" {
    health.reset();
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("200 OK", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"checks\":[]") != null);
}

test "handleReady JSON output has checks array" {
    health.reset();
    health.markComponentOk("agent");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"checks\":[") != null);
    // Should contain the agent component
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"name\":\"agent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"healthy\":true") != null);
}

test "handleReady multiple unhealthy components returns 503" {
    health.reset();
    health.markComponentError("gateway", "port in use");
    health.markComponentError("database", "disk full");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("503 Service Unavailable", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"not_ready\"") != null);
}

test "handleReady response body is valid JSON structure" {
    health.reset();
    health.markComponentOk("test-svc");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    // Must start with { and end with }
    try std.testing.expect(resp.body.len > 0);
    try std.testing.expectEqual(@as(u8, '{'), resp.body[0]);
    try std.testing.expectEqual(@as(u8, '}'), resp.body[resp.body.len - 1]);
}

test "handleReady unhealthy component includes error message" {
    health.reset();
    health.markComponentError("cache", "redis timeout");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("503 Service Unavailable", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"message\":\"redis timeout\"") != null);
}

test "handleReady recovered component shows healthy" {
    health.reset();
    health.markComponentError("db", "down");
    health.markComponentOk("db");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("200 OK", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"healthy\":true") != null);
}

test "publishToBus creates inbound message on bus" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const ok = publishToBus(&eb, alloc, "telegram", "user1", "chat42", "hello", "telegram:chat42", null);
    try std.testing.expect(ok);

    // Consume the message
    const msg = eb.consumeInbound() orelse return error.TestUnexpectedResult;
    defer msg.deinit(alloc);
    try std.testing.expectEqualStrings("telegram", msg.channel);
    try std.testing.expectEqualStrings("user1", msg.sender_id);
    try std.testing.expectEqualStrings("chat42", msg.chat_id);
    try std.testing.expectEqualStrings("hello", msg.content);
    try std.testing.expectEqualStrings("telegram:chat42", msg.session_key);
}

test "publishToBus with metadata" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const meta = "{\"account_id\":\"personal\"}";
    const ok = publishToBus(&eb, alloc, "whatsapp", "sender", "chat1", "hi", "wa:chat1", meta);
    try std.testing.expect(ok);

    const msg = eb.consumeInbound() orelse return error.TestUnexpectedResult;
    defer msg.deinit(alloc);
    try std.testing.expectEqualStrings("whatsapp", msg.channel);
    try std.testing.expectEqualStrings("hi", msg.content);
    try std.testing.expect(msg.metadata_json != null);
    try std.testing.expectEqualStrings("{\"account_id\":\"personal\"}", msg.metadata_json.?);
}

test "GatewayState event_bus defaults to null" {
    var gs = GatewayState.init(std.testing.allocator);
    defer gs.deinit();
    try std.testing.expect(gs.event_bus == null);
}

// ── jsonEscapeInto tests ────────────────────────────────────────

fn escapeToString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var buf_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const w = &buf_writer.writer;
    try jsonEscapeInto(w, input);
    buf = buf_writer.toArrayList();
    return buf.toOwnedSlice(allocator);
}

test "jsonEscapeInto escapes double quotes" {
    const result = try escapeToString(std.testing.allocator, "hello \"world\"");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello \\\"world\\\"", result);
}

test "jsonEscapeInto escapes backslashes" {
    const result = try escapeToString(std.testing.allocator, "path\\to\\file");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("path\\\\to\\\\file", result);
}

test "jsonEscapeInto escapes newlines and tabs" {
    const result = try escapeToString(std.testing.allocator, "line1\nline2\ttab");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("line1\\nline2\\ttab", result);
}

test "jsonEscapeInto escapes control chars as unicode" {
    // 0x00, 0x01, 0x1F
    const result = try escapeToString(std.testing.allocator, &[_]u8{ 0x00, 0x01, 0x1F });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\\u0000\\u0001\\u001f", result);
}

test "jsonEscapeInto empty string yields empty output" {
    const result = try escapeToString(std.testing.allocator, "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "jsonEscapeInto passes through unicode and emoji unchanged" {
    const result = try escapeToString(std.testing.allocator, "hello \xc3\xa9\xf0\x9f\x98\x80 world");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello \xc3\xa9\xf0\x9f\x98\x80 world", result);
}

test "jsonEscapeInto escapes carriage return" {
    const result = try escapeToString(std.testing.allocator, "hello\r\nworld");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello\\r\\nworld", result);
}

test "jsonEscapeInto escapes backspace and form feed" {
    const result = try escapeToString(std.testing.allocator, "a\x08b\x0Cc");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a\\bb\\fc", result);
}

test "jsonEscapeInto mixed special characters" {
    const result = try escapeToString(std.testing.allocator, "He said \"hi\\there\"\nnew line");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("He said \\\"hi\\\\there\\\"\\nnew line", result);
}

// ── jsonWrapField tests ─────────────────────────────────────────

test "jsonWrapField produces valid JSON string field" {
    const result = try jsonWrapField(std.testing.allocator, "msg", "hello \"world\"");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\"msg\":\"hello \\\"world\\\"\"", result);
}

test "jsonWrapField with empty value" {
    const result = try jsonWrapField(std.testing.allocator, "key", "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\"key\":\"\"", result);
}

test "jsonWrapField result is valid JSON when wrapped in braces" {
    const field = try jsonWrapField(std.testing.allocator, "response", "test\nvalue");
    defer std.testing.allocator.free(field);
    // Wrap in object: {"response":"test\nvalue"}
    const json = try std.fmt.allocPrint(std.testing.allocator, "{{{s}}}", .{field});
    defer std.testing.allocator.free(json);
    // Parse to verify it's valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const val = parsed.value.object.get("response") orelse unreachable;
    try std.testing.expect(val == .string);
    try std.testing.expectEqualStrings("test\nvalue", val.string);
}

// ── jsonWrapResponse tests ──────────────────────────────────────

test "jsonWrapResponse produces valid JSON with escaped content" {
    const result = try jsonWrapResponse(std.testing.allocator, "Hello \"user\"\nLine 2");
    defer std.testing.allocator.free(result);
    // Verify it's valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const status = parsed.value.object.get("status") orelse unreachable;
    try std.testing.expectEqualStrings("ok", status.string);
    const response = parsed.value.object.get("response") orelse unreachable;
    try std.testing.expectEqualStrings("Hello \"user\"\nLine 2", response.string);
}

test "jsonWrapResponse with clean input" {
    const result = try jsonWrapResponse(std.testing.allocator, "simple reply");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"status\":\"ok\",\"response\":\"simple reply\"}", result);
}

// ── GatewayThreadObserver tests ─────────────────────────────────

test "GatewayThreadObserver init/deinit no leaks" {
    var obs = GatewayThreadObserver.init(std.testing.allocator);
    obs.deinit();
}

test "GatewayThreadObserver records tool events and collectSince works" {
    var obs = GatewayThreadObserver.init(std.testing.allocator);
    defer obs.deinit();

    const seq_before = obs.currentSeq();
    const start_event = observability.ObserverEvent{ .tool_call_start = .{ .tool = "shell" } };
    obs.observer().recordEvent(&start_event);

    const done_event = observability.ObserverEvent{ .tool_call = .{ .tool = "shell", .duration_ms = 50, .success = true } };
    obs.observer().recordEvent(&done_event);

    const events = try obs.collectSince(std.testing.allocator, seq_before);
    defer {
        for (events) |e| std.testing.allocator.free(e.tool);
        std.testing.allocator.free(events);
    }
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("shell", events[0].tool);
    try std.testing.expect(events[0].kind == .start);
    try std.testing.expect(events[1].kind == .result);
    try std.testing.expect(events[1].success);
}

test "GatewayThreadObserver collectSince filters by sequence" {
    var obs = GatewayThreadObserver.init(std.testing.allocator);
    defer obs.deinit();

    const event1 = observability.ObserverEvent{ .tool_call = .{ .tool = "shell", .duration_ms = 10, .success = true } };
    obs.observer().recordEvent(&event1);
    const mid_seq = obs.currentSeq();

    const event2 = observability.ObserverEvent{ .tool_call = .{ .tool = "web_fetch", .duration_ms = 20, .success = false } };
    obs.observer().recordEvent(&event2);

    const events = try obs.collectSince(std.testing.allocator, mid_seq);
    defer {
        for (events) |e| std.testing.allocator.free(e.tool);
        std.testing.allocator.free(events);
    }
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("web_fetch", events[0].tool);
    try std.testing.expect(!events[0].success);
}

test "GatewayThreadObserver collectSince OOM frees partial output" {
    var obs = GatewayThreadObserver.init(std.testing.allocator);
    defer obs.deinit();

    const event1 = observability.ObserverEvent{ .tool_call = .{ .tool = "shell", .duration_ms = 10, .success = true } };
    obs.observer().recordEvent(&event1);
    const event2 = observability.ObserverEvent{ .tool_call = .{ .tool = "web_fetch", .duration_ms = 20, .success = false } };
    obs.observer().recordEvent(&event2);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    // collectSince allocations: out array + first tool dupe + second tool dupe
    failing.fail_index = failing.alloc_index + 2;
    try std.testing.expectError(error.OutOfMemory, obs.collectSince(failing.allocator(), 0));
}

// ── buildThreadEventsJson / buildWebhookSuccessResponse tests ───

test "buildThreadEventsJson empty events" {
    const result = try buildThreadEventsJson(std.testing.allocator, &.{});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("[]", result);
}

test "buildThreadEventsJson with tool results" {
    const events = [_]GatewayTurnToolEvent{
        .{ .kind = .start, .tool = "shell", .success = false },
        .{ .kind = .result, .tool = "shell", .success = true },
        .{ .kind = .result, .tool = "web_fetch", .success = false },
    };
    const result = try buildThreadEventsJson(std.testing.allocator, &events);
    defer std.testing.allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    const summary = parsed.value.array.items[0].object;
    try std.testing.expectEqualStrings("tool_summary", summary.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 2), summary.get("total").?.integer);
    try std.testing.expectEqual(@as(i64, 1), summary.get("failed").?.integer);
}

test "buildWebhookSuccessResponse includes thread_events" {
    const result = try buildWebhookSuccessResponse(std.testing.allocator, "hello", "[]");
    defer std.testing.allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqualStrings("ok", parsed.value.object.get("status").?.string);
    try std.testing.expectEqualStrings("hello", parsed.value.object.get("response").?.string);
    try std.testing.expect(parsed.value.object.get("thread_events").? == .array);
}

// ── jsonWrapChallenge tests ─────────────────────────────────────

test "jsonWrapChallenge produces valid JSON" {
    const result = try jsonWrapChallenge(std.testing.allocator, "abc123");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"challenge\":\"abc123\"}", result);
}

test "jsonWrapChallenge escapes malicious challenge value" {
    const result = try jsonWrapChallenge(std.testing.allocator, "abc\",\"evil\":\"true");
    defer std.testing.allocator.free(result);
    // Must be valid JSON with the value properly escaped
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const challenge = parsed.value.object.get("challenge") orelse unreachable;
    try std.testing.expectEqualStrings("abc\",\"evil\":\"true", challenge.string);
    // Must NOT have an "evil" key (injection prevented)
    try std.testing.expect(parsed.value.object.get("evil") == null);
}

// ── Port conflict detection tests ─────────────────────────────────────

test "run returns AddressInUse when port is already bound" {
    // Find an available port by binding to port 0
    const test_addr = try std_compat.net.Address.resolveIp("127.0.0.1", 0);
    var listener = try test_addr.listen(.{ .reuse_address = true });
    defer listener.deinit();

    // Get the actual port that was assigned
    const bound_port = listener.listen_address.in.getPort();

    // Try to start gateway on the same port - should fail with AddressInUse
    const result = run(std.testing.allocator, "127.0.0.1", bound_port, null, null, null);
    try std.testing.expectError(error.AddressInUse, result);
}

test "handleCronRun rejects non-POST" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var state = GatewayState.init(allocator);
    var ctx = WebhookHandlerContext{
        .root_allocator = allocator,
        .req_allocator = allocator,
        .raw_request = "GET /cron/run HTTP/1.1\r\n\r\n",
        .method = "GET",
        .target = "/cron/run",
        .config_opt = null,
        .state = &state,
        .session_mgr_opt = null,
    };
    handleCronRun(&ctx);
    try std.testing.expectEqualStrings("405 Method Not Allowed", ctx.response_status);
}

test "handleCronRun returns 400 when id missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var state = GatewayState.init(allocator);
    var ctx = WebhookHandlerContext{
        .root_allocator = allocator,
        .req_allocator = allocator,
        .raw_request = "POST /cron/run HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}",
        .method = "POST",
        .target = "/cron/run",
        .config_opt = null,
        .state = &state,
        .session_mgr_opt = null,
    };
    handleCronRun(&ctx);
    try std.testing.expectEqualStrings("400 Bad Request", ctx.response_status);
}

test "handleCronRun returns 503 when scheduler not running" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var state = GatewayState.init(allocator);
    // scheduler remains null (not running)
    var ctx = WebhookHandlerContext{
        .root_allocator = allocator,
        .req_allocator = allocator,
        .raw_request = "POST /cron/run HTTP/1.1\r\nContent-Length: 14\r\n\r\n{\"id\":\"job-1\"}",
        .method = "POST",
        .target = "/cron/run",
        .config_opt = null,
        .state = &state,
        .session_mgr_opt = null,
    };
    handleCronRun(&ctx);
    try std.testing.expectEqualStrings("503 Service Unavailable", ctx.response_status);
}

test "handleCronRun returns 404 for unknown job" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scheduler = cron_mod.CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();
    var state = GatewayState.init(allocator);
    state.scheduler = &scheduler;
    var ctx = WebhookHandlerContext{
        .root_allocator = allocator,
        .req_allocator = allocator,
        .raw_request = "POST /cron/run HTTP/1.1\r\nContent-Length: 22\r\n\r\n{\"id\":\"nonexistent-job\"}",
        .method = "POST",
        .target = "/cron/run",
        .config_opt = null,
        .state = &state,
        .session_mgr_opt = null,
    };
    handleCronRun(&ctx);
    try std.testing.expectEqualStrings("404 Not Found", ctx.response_status);
}

test "/cron/run is registered in route table" {
    const desc = findCronRouteDescriptor("/cron/run");
    try std.testing.expect(desc != null);
    try std.testing.expectEqualStrings("POST", desc.?.method);
}
