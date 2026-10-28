//! Native task fixture report. v1/source1 is embedded Flash; v2/source2 is
//! the opt-in SD RPC fixture. Neither implies persistence qualification.
pub const Report = extern struct {
    version: u32 = 1,
    source: u32 = 1,
    status: u32 = 0,
    fixture_id: u32 = 0,
    parent_used: u32 = 0,
    parent_charged: u32 = 0,
    requests: u32 = 0,
    replies: u32 = 0,
    forced_exit: u32 = 0,
    cancelled: u32 = 0,
    discarded_requests: u32 = 0,
    discarded_replies: u32 = 0,
    rebound: u32 = 0,
    stale_epoch: u32 = 0,
    stale_handle: u32 = 0,
    stale_reply: u32 = 0,
    stale_exit: u32 = 0,
    bytes: u32 = 0,
    crc: u32 = 0,
    owner_stack: u32 = 0,
    client_stack: u32 = 0,
    parent_cleared: u32 = 0,
    recovered: u32 = 0,
};
pub const fields = .{ "version", "source", "status", "fixture_id", "parent_used", "parent_charged", "requests", "replies", "forced_exit", "cancelled", "discarded_requests", "discarded_replies", "rebound", "stale_epoch", "stale_handle", "stale_reply", "stale_exit", "bytes", "crc", "owner_stack", "client_stack", "parent_cleared", "recovered" };
