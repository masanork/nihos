//! Compile-only RV32 witness for the handoff API; not a firmware service.
const h = @import("handoff");
const std = @import("std");
export fn nih_handoff_size() usize {
    return @sizeOf(h.Handoff);
}
export fn nih_handoff_start(owner: *h.Handoff, epoch: u64, request: u64, now: u64, deadline: u64) bool {
    owner.start(.{ .epoch = epoch, .request = request }, now, deadline) catch return false;
    return true;
}
export fn nih_handoff_public(owner: *h.Handoff, epoch: u64, request: u64, now: u64, key: *const [1184]u8) bool {
    owner.publicComplete(.{ .epoch = epoch, .request = request }, now, key) catch return false;
    return true;
}
export fn nih_handoff_tick(owner: *h.Handoff, epoch: u64, request: u64, now: u64) bool {
    owner.tick(.{ .epoch = epoch, .request = request }, now) catch return false;
    return true;
}
export fn nih_handoff_take_public(owner: *h.Handoff, epoch: u64, request: u64, now: u64, key: *[1184]u8) bool {
    owner.takePublic(.{ .epoch = epoch, .request = request }, now, key) catch return false;
    return true;
}
export fn nih_handoff_reply(owner: *h.Handoff, epoch: u64, request: u64, now: u64, ct: *const [1088]u8) bool {
    owner.submitReply(.{ .epoch = epoch, .request = request }, now, ct) catch return false;
    return true;
}
export fn nih_handoff_take_ciphertext(owner: *h.Handoff, epoch: u64, request: u64, now: u64, ct: *[1088]u8) bool {
    owner.takeCiphertext(.{ .epoch = epoch, .request = request }, now, ct) catch return false;
    return true;
}
export fn nih_handoff_secret(owner: *h.Handoff, epoch: u64, request: u64, now: u64, secret: *const [32]u8) bool {
    owner.secretComplete(.{ .epoch = epoch, .request = request }, now, secret) catch return false;
    return true;
}
fn testVerifier(_: ?*anyopaque, secret: *const [32]u8) bool {
    return std.mem.allEqual(u8, secret, 7);
}
export fn nih_handoff_verify(owner: *h.Handoff, epoch: u64, request: u64, now: u64) bool {
    return owner.authenticate(.{ .epoch = epoch, .request = request }, now, null, &testVerifier) catch false;
}
export fn nih_handoff_reclaimable(owner: *const h.Handoff) bool {
    return owner.reclaimable();
}
export fn nih_handoff_abort(owner: *h.Handoff) void {
    owner.abort();
}
export fn nih_handoff_cancel_ack(owner: *h.Handoff, epoch: u64, request: u64) bool {
    owner.cancelAcknowledged(.{ .epoch = epoch, .request = request }) catch return false;
    return true;
}
