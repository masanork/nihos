//! CPU0 foreground camera access. A handle names one immutable, boot-retained
//! JPEG; clients receive bounded copies, never DMA addresses or owning slices.
pub const Error = error{ CameraUnavailable, CameraBusy, InvalidCameraHandle, InvalidCameraRange, CameraFailed };
pub const State = enum { pending, ready, failed };
pub const Info = struct { state: State, width: u32 = 1280, height: u32 = 720, bytes: u32 = 0 };
pub const max_read = 32;
pub const Provider = struct {
    capture: *const fn () Error!i32,
    info: *const fn (i32) Error!Info,
    read: *const fn (i32, u32, []u8) Error!void,
};

pub const Client = struct {
    provider: ?*const Provider = null,
    pub inline fn capture(self: Client) Error!i32 {
        return (self.provider orelse return error.CameraUnavailable).capture();
    }
    pub inline fn info(self: Client, handle: i32) Error!Info {
        if (handle <= 0) return error.InvalidCameraHandle;
        return (self.provider orelse return error.CameraUnavailable).info(handle);
    }
    pub inline fn read(self: Client, handle: i32, offset: u32, output: []u8) Error!void {
        if (output.len > max_read) return error.InvalidCameraRange;
        const observed = try self.info(handle);
        switch (observed.state) {
            .pending => return error.CameraBusy,
            .failed => return error.CameraFailed,
            .ready => {},
        }
        if (offset > observed.bytes or output.len > observed.bytes - offset) return error.InvalidCameraRange;
        return self.provider.?.read(handle, offset, output);
    }
};

test "unbound camera does not allocate or expose an address" {
    const std = @import("std");
    const client = Client{};
    try std.testing.expectError(error.CameraUnavailable, client.capture());
    try std.testing.expectError(error.InvalidCameraHandle, client.info(0));
    try std.testing.expectError(error.CameraUnavailable, client.info(1));
}
