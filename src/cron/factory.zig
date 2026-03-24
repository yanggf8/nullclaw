//! Factory for creating a CronBackend from configuration.
//!
//! Currently only DbCronBackend (SQLite) is supported.
//! MemoryCronBackend is available for test injection but not wired here
//! since tests bypass the factory.
const std = @import("std");
const build_options = @import("build_options");

const root = @import("root.zig");
const db_mod = @import("db.zig");

/// Create a DbCronBackend for the given db_path and return it as a CronBackend.
/// The caller owns the returned backend and MUST call backend.deinit() when done.
///
/// If SQLite is disabled at build time, returns error.SqliteDisabled.
pub fn createDbBackend(
    allocator: std.mem.Allocator,
    db_path: [:0]const u8,
) !db_mod.DbCronBackend {
    if (!build_options.enable_sqlite) return error.SqliteDisabled;
    return db_mod.DbCronBackend.init(allocator, db_path);
}
