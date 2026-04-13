//! Pure domain types for the cron subsystem. No storage, no I/O, no SQLite.
//! These types are shared by CronBackend implementations and all callers.
const std = @import("std");
const agent_routing = @import("../agent_routing.zig");

pub const JobType = enum {
    shell,
    agent,
    skill,

    pub fn asStr(self: JobType) []const u8 {
        return switch (self) {
            .shell => "shell",
            .agent => "agent",
            .skill => "skill",
        };
    }

    pub fn parse(raw: []const u8) JobType {
        if (std.ascii.eqlIgnoreCase(raw, "agent")) return .agent;
        if (std.ascii.eqlIgnoreCase(raw, "skill")) return .skill;
        return .shell;
    }
};

pub const SessionTarget = enum {
    isolated,
    main,

    pub fn asStr(self: SessionTarget) []const u8 {
        return switch (self) {
            .isolated => "isolated",
            .main => "main",
        };
    }

    pub fn parse(raw: []const u8) SessionTarget {
        if (std.ascii.eqlIgnoreCase(raw, "main")) return .main;
        return .isolated;
    }
};

pub const ScheduleKind = enum { cron, at, every };

pub const Schedule = union(ScheduleKind) {
    cron: struct { expr: []const u8, tz: ?[]const u8 },
    at: struct { timestamp_s: i64 },
    every: struct { every_ms: u64 },
};

pub const DeliveryMode = enum {
    none,
    always,
    on_error,
    on_success,

    pub fn asStr(self: DeliveryMode) []const u8 {
        return switch (self) {
            .none => "none",
            .always => "always",
            .on_error => "on_error",
            .on_success => "on_success",
        };
    }

    pub fn parse(raw: []const u8) DeliveryMode {
        if (std.ascii.eqlIgnoreCase(raw, "always")) return .always;
        if (std.ascii.eqlIgnoreCase(raw, "on_error")) return .on_error;
        if (std.ascii.eqlIgnoreCase(raw, "on_success")) return .on_success;
        return .none;
    }
};

pub const DeliveryConfig = struct {
    mode: DeliveryMode = .none,
    channel: ?[]const u8 = null,
    account_id: ?[]const u8 = null,
    to: ?[]const u8 = null,
    peer_kind: ?agent_routing.ChatType = null,
    peer_id: ?[]const u8 = null,
    thread_id: ?[]const u8 = null,
    best_effort: bool = false,
    channel_owned: bool = false,
    account_id_owned: bool = false,
    to_owned: bool = false,
    peer_id_owned: bool = false,
    thread_id_owned: bool = false,
};

pub const CronRun = struct {
    id: u64,
    job_id: []const u8,
    started_at_s: i64,
    finished_at_s: i64,
    status: []const u8,
    output: ?[]const u8,
    duration_ms: ?i64,
};

pub const CronJobPatch = struct {
    expression: ?[]const u8 = null,
    command: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    name: ?[]const u8 = null,
    enabled: ?bool = null,
    model: ?[]const u8 = null,
    skill_name: ?[]const u8 = null,
    skill_args: ?[]const u8 = null,
    delete_after_run: ?bool = null,
    delivery_channel: ?[]const u8 = null,
    delivery_to: ?[]const u8 = null,
    delivery_mode: ?[]const u8 = null,
    delivery_account_id: ?[]const u8 = null,
    timeout_secs: ?u32 = null,
    next_run_secs: ?i64 = null,
    tz_offset_s: ?i32 = null,
    session_target: ?SessionTarget = null,
    verification_mode: ?VerificationMode = null,
    repair_policy: ?RepairPolicy = null,
};

/// A scheduled cron job — the full persistent record.
pub const CronJob = struct {
    id: []const u8,
    expression: []const u8,
    command: []const u8,
    next_run_secs: i64 = 0,
    last_run_secs: ?i64 = null,
    last_status: ?[]const u8 = null,
    paused: bool = false,
    one_shot: bool = false,
    job_type: JobType = .shell,
    session_target: SessionTarget = .isolated,
    prompt: ?[]const u8 = null,
    name: ?[]const u8 = null,
    model: ?[]const u8 = null,
    skill_name: ?[]const u8 = null,
    skill_args: ?[]const u8 = null,
    timeout_secs: ?u32 = null,
    enabled: bool = true,
    delete_after_run: bool = false,
    created_at_s: i64 = 0,
    last_output: ?[]const u8 = null,
    delivery: DeliveryConfig = .{},
    tz_offset_s: i32 = 0,
    verification_mode: VerificationMode = .none,
    repair_policy: RepairPolicy = .none,
};

/// Immutable execution snapshot returned by CronBackend.dequeue().
/// Claimed and loaded atomically — no second DB lookup needed by the worker.
/// All strings are arena-allocated; caller frees via arena.deinit().
pub const VerificationMode = enum {
    none,
    exit_only,
    content_nonempty,
    content_has_trace,
    skill_contract,

    pub fn asStr(self: VerificationMode) []const u8 {
        return switch (self) {
            .none => "none",
            .exit_only => "exit_only",
            .content_nonempty => "content_nonempty",
            .content_has_trace => "content_has_trace",
            .skill_contract => "skill_contract",
        };
    }

    pub fn parse(s: []const u8) VerificationMode {
        if (std.ascii.eqlIgnoreCase(s, "exit_only")) return .exit_only;
        if (std.ascii.eqlIgnoreCase(s, "content_nonempty")) return .content_nonempty;
        if (std.ascii.eqlIgnoreCase(s, "content_has_trace")) return .content_has_trace;
        if (std.ascii.eqlIgnoreCase(s, "skill_contract")) return .skill_contract;
        return .none;
    }

    /// Strict parse: returns an error for unrecognized values. Use for CLI input
    /// where a typo must not silently downgrade to `.none`.
    pub fn parseStrict(s: []const u8) !VerificationMode {
        if (std.ascii.eqlIgnoreCase(s, "none")) return .none;
        if (std.ascii.eqlIgnoreCase(s, "exit_only")) return .exit_only;
        if (std.ascii.eqlIgnoreCase(s, "content_nonempty")) return .content_nonempty;
        if (std.ascii.eqlIgnoreCase(s, "content_has_trace")) return .content_has_trace;
        if (std.ascii.eqlIgnoreCase(s, "skill_contract")) return .skill_contract;
        return error.InvalidVerificationMode;
    }
};

pub const RepairPolicy = enum {
    none,
    retry_once,
    alert_only,

    pub fn asStr(self: RepairPolicy) []const u8 {
        return switch (self) {
            .none => "none",
            .retry_once => "retry_once",
            .alert_only => "alert_only",
        };
    }

    pub fn parse(s: []const u8) RepairPolicy {
        if (std.ascii.eqlIgnoreCase(s, "retry_once")) return .retry_once;
        if (std.ascii.eqlIgnoreCase(s, "alert_only")) return .alert_only;
        return .none;
    }

    /// Strict parse: returns an error for unrecognized values. Use for CLI input
    /// where a typo must not silently downgrade to `.none`.
    pub fn parseStrict(s: []const u8) !RepairPolicy {
        if (std.ascii.eqlIgnoreCase(s, "none")) return .none;
        if (std.ascii.eqlIgnoreCase(s, "retry_once")) return .retry_once;
        if (std.ascii.eqlIgnoreCase(s, "alert_only")) return .alert_only;
        return error.InvalidRepairPolicy;
    }
};

/// Classification result from a single skill execution.
/// All string fields point to string literals — no allocator needed.
pub const RunResult = struct {
    exit_code: u8,
    timed_out: bool,
    /// "timeout" | "exec_error" | "content_empty" | "content_invalid" | null
    failure_class: ?[]const u8 = null,
    /// "retried_ok" | "retried_failed" | "alert_sent" | null
    repair_action: ?[]const u8 = null,
    /// 0=unverified 1=ok 2=degraded 3=failed_verify
    verified: u8 = 0,
};

pub const CronJobSpec = struct {
    id: []const u8,
    job_type: JobType,
    command: []const u8,
    prompt: ?[]const u8,
    model: ?[]const u8,
    skill_name: ?[]const u8 = null,
    skill_args: ?[]const u8 = null,
    one_shot: bool,
    delete_after_run: bool,
    timeout_secs: ?u32,
    delivery: DeliveryConfig, // best_effort correctly loaded from DB
    session_target: SessionTarget,
    verification_mode: VerificationMode = .none,
    repair_policy: RepairPolicy = .none,
};

/// Result of an atomic dequeue+claim+snapshot operation.
pub const DequeueResult = struct {
    queue_row_id: i64,
    spec: CronJobSpec,
};

/// Raw output from a completed job run. Caller-owned, no JSON formatting.
pub const CronJobOutput = struct {
    status: []const u8, // "ok" | "error" | ""
    output: []const u8, // raw bytes
    last_run_secs: ?i64,
};

/// Typed summary row for the list path — excludes last_output to avoid large-column copies.
/// Strings are temporary: valid only during CronBackend.listRows visitor call.
pub const CronJobSummary = struct {
    id: []const u8,
    expression: []const u8,
    name: ?[]const u8,
    job_type: JobType,
    next_run_secs: i64,
    last_run_secs: ?i64,
    last_status: ?[]const u8,
    paused: bool,
    enabled: bool,
    one_shot: bool,
    delete_after_run: bool,
    delivery_mode: DeliveryMode,
    delivery_channel: ?[]const u8,
    delivery_to: ?[]const u8,
    created_at_s: i64,
    timeout_secs: ?u32,
    skill_name: ?[]const u8 = null,
    skill_args: ?[]const u8 = null,
    tz_offset_s: i32 = 0,
};

/// Parameters for adding a new job. All strings are caller-owned slices.
pub const NewJobSpec = struct {
    expression: []const u8,
    job_type: JobType = .shell,
    command: []const u8 = "",
    prompt: ?[]const u8 = null,
    name: ?[]const u8 = null,
    model: ?[]const u8 = null,
    skill_name: ?[]const u8 = null,
    skill_args: ?[]const u8 = null,
    one_shot: bool = false,
    delete_after_run: bool = false,
    enabled: bool = true,
    timeout_secs: ?u32 = null,
    delivery: DeliveryConfig = .{},
    session_target: SessionTarget = .isolated,
    created_at_s: i64 = 0,
    /// When non-zero, use this as next_run_secs instead of computing from expression.
    /// Required for @once: delay expressions where expression is not a valid cron pattern.
    next_run_secs_override: i64 = 0,
    tz_offset_s: i32 = 0,
    verification_mode: VerificationMode = .none,
    repair_policy: RepairPolicy = .none,
};
