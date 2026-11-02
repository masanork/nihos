//! Compile-only layout markers and caller-provided-storage initialization.
//! These objects are not linked into a firmware image.
const sender = @import("hosted_udp_sender.zig");
const hosted = @import("hosted.zig");
const dma = @import("hosted_long_dma.zig");
const std = @import("std");
const Lease = std.meta.fieldInfo(sender.Sender, .binding).type;
const StatePointer = std.meta.fieldInfo(sender.Sender, .state).type;

export var udp_layout_sender: [@sizeOf(sender.Sender)]u8 align(@alignOf(sender.Sender)) = undefined;
export var udp_layout_lease: [@sizeOf(Lease)]u8 align(@alignOf(Lease)) = undefined;
export var udp_layout_decoder: [@sizeOf(hosted.Decoder)]u8 align(@alignOf(hosted.Decoder)) = undefined;
export var udp_layout_dma: [@sizeOf(dma.Buffer)]u8 align(@alignOf(dma.Buffer)) = undefined;

export fn udp_layout_init_into(out: *sender.Sender, state: StatePointer, binding: *const Lease) u32 {
    out.* = sender.Sender.init(state, binding.*) catch return 0;
    return 1;
}
