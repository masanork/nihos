//! Managed SQLite PERSIST/FULL host contract, 4096-byte aligned DB pages.
//! Not a generic VFS/WAL budget. Index/stack/DMA resources are separate.
const std = @import("std");
const map = @import("extent_map.zig");
pub const page_bytes: u64 = 4096;
pub const record_bytes: u64 = page_bytes + 8;
pub const Policy = struct {
    database_limit: u64,
    journal_limit: u64,
    pub fn pages(self: Policy, journal_length: u64) error{InvalidArgument}!u64 {
        if (self.database_limit == 0 or self.database_limit % page_bytes != 0 or self.journal_limit == 0 or journal_length > self.journal_limit) return error.InvalidArgument;
        const db_height = map.height(self.database_limit) catch return error.InvalidArgument;
        const journal_height = map.height(self.journal_limit) catch return error.InvalidArgument;
        const records = journal_length / record_bytes + @intFromBool(journal_length % record_bytes != 0);
        // Each replay record: one data + one map path. Resize may touch two
        // boundary paths and one partial tail; journal invalidation one path.
        const replay = std.math.mul(u64, records, @as(u64, db_height) + 2) catch return error.InvalidArgument;
        return std.math.add(u64, replay, 2 * (@as(u64, db_height) + 1) + 1 + @as(u64, journal_height) + 2) catch return error.InvalidArgument;
    }
};
test "recovery quota includes aligned journal records and both cleanup boundaries" {
    const policy = Policy{ .database_limit = 64 * page_bytes, .journal_limit = 4 * 1024 * 1024 };
    try std.testing.expectEqual(@as(u64, 6), try policy.pages(0));
    try std.testing.expectEqual(@as(u64, 8), try policy.pages(record_bytes));
    try std.testing.expectEqual(@as(u64, 10), try policy.pages(record_bytes + 1));
    const wide = Policy{ .database_limit = 16 * 1024 * 1024 * 1024, .journal_limit = policy.journal_limit };
    try std.testing.expectEqual(@as(u64, 5127), try wide.pages(wide.journal_limit));
    try std.testing.expect(try wide.pages(wide.journal_limit) * page_bytes < 32 * 1024 * 1024);
    try std.testing.expectError(error.InvalidArgument, policy.pages(policy.journal_limit + 1));
    try std.testing.expectError(error.InvalidArgument, (Policy{ .database_limit = 0, .journal_limit = 1 }).pages(0));
    try std.testing.expectError(error.InvalidArgument, (Policy{ .database_limit = 4097, .journal_limit = 1 }).pages(0));
}
