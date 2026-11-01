//! Bounds a C6 time sample before it can be applied to the P4 RTC.
//! SNTP is unauthenticated. This is a freshness/range policy, not trust.
const time = @import("hosted_c6_time.zig");
const sntp = @import("sntp.zig");
pub const retry_unavailable: u64 = 5_000_000;
pub const retry_rejected: u64 = 60_000_000;
pub const max_sync_age: u32 = 6 * 60 * 60;
pub const Decision = struct { sample: ?sntp.Sample, delay: u64, rejected: bool };
pub fn decide(sample: ?time.Sample, now: u64) Decision {
    const value = sample orelse return .{ .sample = null, .delay = retry_unavailable, .rejected = false };
    if (value.age_seconds > max_sync_age or value.seconds < 946_684_800 or value.seconds >= 4_102_444_800)
        return .{ .sample = null, .delay = retry_rejected, .rejected = true };
    return .{ .sample = .{ .unix_us = value.seconds * 1_000_000, .received = now, .stratum = 0, .rtt_us = 0 }, .delay = sntp.resync, .rejected = false };
}
pub fn take(slot: *?sntp.Sample, now: u64, current_generation: bool) ?sntp.Sample {
    const value = slot.* orelse return null;
    slot.* = null;
    if (!current_generation or now < value.received or now - value.received > 5_000_000) return null;
    return value;
}
