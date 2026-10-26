//! Trusted native qualification boundary; not an application syscall ABI.
pub const Report = extern struct {
    status: u32 = 0,
    old_api_denied: u32 = 0,
    metadata: u32 = 0,
    internal_bytes: u32 = 0,
    internal_free: u32 = 0,
    external_bytes: u32 = 0,
    external_free: u32 = 0,
    internal_floor: u32 = 0,
    external_floor: u32 = 0,
    requested4: u32 = 0,
    charged4: u32 = 0,
    requested8: u32 = 0,
    charged8: u32 = 0,
    client: u32 = 0,
    replacement: u32 = 0,
    requests: u32 = 0,
    responses: u32 = 0,
    rejected: u32 = 0,
    exits: u32 = 0,
    reaped: u32 = 0,
    pin_waited: u32 = 0,
    borrow_completed: u32 = 0,
    stale_identity: u32 = 0,
    stale_lease: u32 = 0,
    guards: u32 = 0,
    recovered: u32 = 0,
    client_stack: u32 = 0,
};
extern fn nih_broker_peer_quiet() callconv(.c) void;
extern fn nih_broker_ready() callconv(.c) u32;
extern fn nih_broker_quiet() callconv(.c) u32;
extern fn nih_broker_runtime_init(u32) callconv(.c) void;
extern fn nih_broker_runtime_poll() callconv(.c) void;
extern fn nih_broker_runtime_done() callconv(.c) u32;
extern fn nih_broker_runtime_finish(*Report) callconv(.c) void;
pub fn peerQuiet() void {
    nih_broker_peer_quiet();
}
pub fn ready() bool {
    return nih_broker_ready() == 1;
}
pub fn quiet() bool {
    return nih_broker_quiet() == 1;
}
pub fn init() void {
    nih_broker_runtime_init(4);
}
pub fn poll() void {
    nih_broker_runtime_poll();
}
pub fn done() bool {
    return nih_broker_runtime_done() == 1;
}
pub fn finish() Report {
    var r = Report{};
    nih_broker_runtime_finish(&r);
    return r;
}
