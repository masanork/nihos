//! CPU0 foreground smartcard access for xy. A handle names one ephemeral
//! verified card read session. All sensitive attribute copies are bounded and zeroed on dismiss.
const std = @import("std");

pub const Error = error{
    CardUnavailable,
    CardBusy,
    InvalidCardHandle,
    InvalidCardRange,
    CardFailed,
    CardLocked,
    PinCancelled,
};

pub const State = enum { pending, ready, failed, dismissed };

pub const Info = struct {
    state: State = .ready,
    name: []const u8 = "",
    address: []const u8 = "",
    birth: []const u8 = "",
    gender: []const u8 = "",
    photo_width: u32 = 0,
    photo_height: u32 = 0,
    photo_bytes: u32 = 0,
};

pub const max_photo_read = 64;

pub const Provider = struct {
    read_input_support: *const fn () Error!i32,
    info: *const fn (i32) Error!Info,
    dismiss: *const fn (i32) Error!void,
    read_photo: *const fn (i32, u32, []u8) Error!void,
};

pub const Client = struct {
    provider: ?*const Provider = null,

    pub inline fn readInputSupport(self: Client) Error!i32 {
        return (self.provider orelse return error.CardUnavailable).read_input_support();
    }

    pub inline fn info(self: Client, handle: i32) Error!Info {
        if (handle <= 0) return error.InvalidCardHandle;
        return (self.provider orelse return error.CardUnavailable).info(handle);
    }

    pub inline fn dismiss(self: Client, handle: i32) Error!void {
        if (handle <= 0) return error.InvalidCardHandle;
        return (self.provider orelse return error.CardUnavailable).dismiss(handle);
    }

    pub inline fn readPhoto(self: Client, handle: i32, offset: u32, output: []u8) Error!void {
        if (output.len > max_photo_read) return error.InvalidCardRange;
        const observed = try self.info(handle);
        switch (observed.state) {
            .pending => return error.CardBusy,
            .failed => return error.CardFailed,
            .dismissed => return error.InvalidCardHandle,
            .ready => {},
        }
        if (offset > observed.photo_bytes or output.len > observed.photo_bytes - offset) return error.InvalidCardRange;
        return (self.provider orelse return error.CardUnavailable).read_photo(handle, offset, output);
    }
};

/// In-memory mock card provider for testing and host simulation without card hardware.
pub const MockStore = struct {
    handle_seq: i32 = 1,
    active: bool = false,
    name_buf: [64]u8 = @splat(0),
    name_len: usize = 0,
    addr_buf: [128]u8 = @splat(0),
    addr_len: usize = 0,
    birth_buf: [16]u8 = @splat(0),
    birth_len: usize = 0,
    gender_buf: [8]u8 = @splat(0),
    gender_len: usize = 0,
    photo_width: u32 = 192,
    photo_height: u32 = 256,
    photo_bytes: u32 = 192 * 256 * 2,

    pub fn set(self: *MockStore, name: []const u8, addr: []const u8, birth: []const u8, gender: []const u8) void {
        self.active = true;
        @memcpy(self.name_buf[0..name.len], name);
        self.name_len = name.len;
        @memcpy(self.addr_buf[0..addr.len], addr);
        self.addr_len = addr.len;
        @memcpy(self.birth_buf[0..birth.len], birth);
        self.birth_len = birth.len;
        @memcpy(self.gender_buf[0..gender.len], gender);
        self.gender_len = gender.len;
    }

    pub fn dismiss(self: *MockStore) void {
        self.active = false;
        @memset(&self.name_buf, 0);
        @memset(&self.addr_buf, 0);
        @memset(&self.birth_buf, 0);
        @memset(&self.gender_buf, 0);
        self.name_len = 0;
        self.addr_len = 0;
        self.birth_len = 0;
        self.gender_len = 0;
    }
};

test "unbound card client errors gracefully" {
    const client = Client{};
    try std.testing.expectError(error.CardUnavailable, client.readInputSupport());
    try std.testing.expectError(error.InvalidCardHandle, client.info(0));
    try std.testing.expectError(error.CardUnavailable, client.info(1));
    try std.testing.expectError(error.InvalidCardHandle, client.dismiss(0));
    try std.testing.expectError(error.CardUnavailable, client.dismiss(1));
}
