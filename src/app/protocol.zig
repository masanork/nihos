//! Versioned, synchronous app boundary. Native structs are not Wasm memory.
const std = @import("std");
pub const version: u32 = 1;
pub const max_stride: u32 = 8192;
pub const Status = enum(i32) { ok = 0, changed = 1, invalid = -1, unsupported_version = -2, closed = -3, render_failed = -4, inactive = -5 };
pub const Kind = enum(u32) { tick, key_down, key_up, focus_lost, focus_gained, cancel };
pub const Format = enum(u32) { rgb565le = 1, bgra8 = 2 };
pub const Pane = enum(u32) { graph, editor };
pub const Event = extern struct {
    size: u32 = @sizeOf(Event),
    abi_version: u32 = version,
    monotonic_us: u64 = 0,
    kind: u32 = @backingInt(Kind.tick),
    code: u32 = 0,
    value: u32 = 0,
    reserved: u32 = 0,

    pub fn validate(self: Event) Status {
        if (self.abi_version != version) return .unsupported_version;
        if (self.size != @sizeOf(Event) or self.reserved != 0 or self.value != 0) return .invalid;
        const kind = std.enums.fromInt(Kind, self.kind) orelse return .invalid;
        if (kind == .key_down or kind == .key_up) {
            if (self.code >= 32) return .invalid;
        } else if (self.code != 0) return .invalid;
        return .ok;
    }
};
pub const Info = extern struct {
    size: u32 = @sizeOf(Info),
    abi_version: u32 = version,
    min_width: u32 = 240,
    min_height: u32 = 180,
    max_width: u32 = 1280,
    max_height: u32 = 720,
    stride_limit: u32 = max_stride,
    frame_bytes_limit: u32 = max_stride * 720,
    format_mask: u32 = (1 << @backingInt(Format.rgb565le)) | (1 << @backingInt(Format.bgra8)),
    key_count: u32 = 32,
    step_us: u32 = 16_667,
    catch_up_steps: u32 = 4,
};
pub const Snapshot = extern struct {
    size: u32 = @sizeOf(Snapshot),
    abi_version: u32 = version,
    ticks: u64 = 0,
    phase: u64 = 0,
    generation: u64 = 1,
    dropped_us: u64 = 0,
    paused: u32 = 0,
    speed: u32 = 2,
    held: u32 = 0,
    pressed: u32 = 0,
    released: u32 = 0,
    stopped: u32 = 0,
    focused: u32 = 1,
    reserved: u32 = 0,
};
pub const FrameRequest = extern struct {
    size: u32 = @sizeOf(FrameRequest),
    abi_version: u32 = version,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    format: u32 = @backingInt(Format.bgra8),
    pane: u32 = @backingInt(Pane.graph),
    reserved: u32 = 0,

    pub fn validate(self: FrameRequest) Status {
        if (self.abi_version != version) return .unsupported_version;
        if (self.size != @sizeOf(FrameRequest) or self.reserved != 0) return .invalid;
        const format = std.enums.fromInt(Format, self.format) orelse return .invalid;
        _ = std.enums.fromInt(Pane, self.pane) orelse return .invalid;
        if (self.width < 240 or self.width > 1280 or self.height < 180 or self.height > 720) return .invalid;
        const row = self.width * @as(u32, if (format == .rgb565le) 2 else 4);
        if (self.stride < row or self.stride > max_stride) return .invalid;
        return .ok;
    }
    /// Only call after validation. Even the last row's padding is reserved.
    pub fn byteLength(self: FrameRequest) u32 {
        return self.height * self.stride;
    }
};
pub const FrameInfo = extern struct {
    size: u32 = @sizeOf(FrameInfo),
    abi_version: u32 = version,
    generation: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    format: u32 = 0,
    byte_length: u32 = 0,
    reserved: u32 = 0,
};

comptime {
    // Also evaluated by the RV32 standalone link probe.
    std.debug.assert(@sizeOf(Event) == 32 and @offsetOf(Event, "monotonic_us") == 8);
    std.debug.assert(@sizeOf(Info) == 48);
    std.debug.assert(@sizeOf(Snapshot) == 72 and @offsetOf(Snapshot, "held") == 48);
    std.debug.assert(@sizeOf(FrameRequest) == 32);
    std.debug.assert(@sizeOf(FrameInfo) == 40 and @offsetOf(FrameInfo, "generation") == 8);
}

test "v1 rejects unknown versions, short structs and unbounded frame requests" {
    try std.testing.expectEqual(Status.unsupported_version, (Event{ .abi_version = 2 }).validate());
    try std.testing.expectEqual(Status.invalid, (Event{ .size = 4 }).validate());
    try std.testing.expectEqual(Status.invalid, (Event{ .kind = 99 }).validate());
    try std.testing.expectEqual(Status.invalid, (Event{ .kind = 1, .code = 32 }).validate());
    try std.testing.expectEqual(Status.invalid, (Event{ .code = 1 }).validate());
    try std.testing.expectEqual(Status.invalid, (Event{ .reserved = 1 }).validate());
    const valid = FrameRequest{ .width = 1280, .height = 720, .stride = max_stride };
    try std.testing.expectEqual(Status.ok, valid.validate());
    try std.testing.expectEqual((Info{}).frame_bytes_limit, valid.byteLength());
    var bad = valid;
    bad.stride = std.math.maxInt(u32);
    try std.testing.expectEqual(Status.invalid, bad.validate());
    bad = valid;
    bad.width = std.math.maxInt(u32);
    try std.testing.expectEqual(Status.invalid, bad.validate());
}
