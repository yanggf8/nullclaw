//! Canary isolation — scratch memory safety boundary.
//! Commit 2 (RED): tests only; sanitizeConfigInPlace / assertScratchDbPath /
//! initScratchMemoryRuntime and MemoryRuntime.primaryDbPath() land in commit 3.

const std = @import("std");
const std_compat = @import("compat");
const build_options = @import("build_options");
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
