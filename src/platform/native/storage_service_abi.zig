//! Internal C-shaped link boundary for the separately compiled service object.
pub const Report = extern struct {
    status: u32 = 0,
    requests: u32 = 0,
    responses: u32 = 0,
    queue_full: u32 = 0,
    rejected: u32 = 0,
    bytes: u32 = 0,
    crc: u32 = 0,
    owner: u32 = 0,
    exit_seen: u32 = 0,
    released: u32 = 0,
    stale_rejected: u32 = 0,
    owner_stack: u32 = 0,
    client_stack: u32 = 0,
    peer_polls: u32 = 0,
    elapsed_us: u32 = 0,
    clock_ok: u32 = 0,
    fs_cleared: u32 = 0,
    ipc_cleared: u32 = 0,
    forced_exit: u32 = 0,
    inflight_completed: u32 = 0,
    discarded_requests: u32 = 0,
    discarded_responses: u32 = 0,
    rebound: u32 = 0,
    replacement_owner: u32 = 0,
    old_epoch_rejected: u32 = 0,
    old_reply_rejected: u32 = 0,
    old_handle_rejected: u32 = 0,
    old_exit_rejected: u32 = 0,
    replacement_exit: u32 = 0,
    replacement_bytes: u32 = 0,
    replacement_crc: u32 = 0,
};
extern fn nih_storage_runtime_init() callconv(.c) void;
extern fn nih_storage_runtime_poll(u32) callconv(.c) void;
extern fn nih_storage_runtime_finished() callconv(.c) u32;
extern fn nih_storage_runtime_finish(*Report) callconv(.c) void;
pub fn init() void {
    nih_storage_runtime_init();
}
pub fn poll(hart: u32) void {
    nih_storage_runtime_poll(hart);
}
pub fn finished() bool {
    return nih_storage_runtime_finished() == 1;
}
pub fn finish() Report {
    var result = Report{};
    nih_storage_runtime_finish(&result);
    return result;
}
