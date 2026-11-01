//! Native Card Provider binding xy Scheme runtime to hardware card service.
const console = @import("text_console");
const card_type = console.scratch.card;

var active_handle: i32 = 0;
var cached_name: [64]u8 = @splat(0);
var cached_name_len: usize = 0;
var cached_addr: [128]u8 = @splat(0);
var cached_addr_len: usize = 0;
var cached_birth: [16]u8 = @splat(0);
var cached_birth_len: usize = 0;
var cached_gender: [8]u8 = @splat(0);
var cached_gender_len: usize = 0;

fn nativeReadInputSupport() card_type.Error!i32 {
    // Return active session handle if already reading, or initiate hardware read
    active_handle = 1;
    return active_handle;
}

fn nativeInfo(handle: i32) card_type.Error!card_type.Info {
    if (handle != active_handle or active_handle == 0) return error.InvalidCardHandle;
    return .{
        .state = .ready,
        .name = cached_name[0..cached_name_len],
        .address = cached_addr[0..cached_addr_len],
        .birth = cached_birth[0..cached_birth_len],
        .gender = cached_gender[0..cached_gender_len],
        .photo_width = 192,
        .photo_height = 256,
        .photo_bytes = 0,
    };
}

fn nativeDismiss(handle: i32) card_type.Error!void {
    if (handle != active_handle or active_handle == 0) return error.InvalidCardHandle;
    active_handle = 0;
    cached_name_len = 0;
    cached_addr_len = 0;
    cached_birth_len = 0;
    cached_gender_len = 0;
}

fn nativeReadPhoto(handle: i32, offset: u32, output: []u8) card_type.Error!void {
    _ = handle;
    _ = offset;
    _ = output;
}

pub const provider = card_type.Provider{
    .read_input_support = nativeReadInputSupport,
    .info = nativeInfo,
    .dismiss = nativeDismiss,
    .read_photo = nativeReadPhoto,
};

/// Set card result from native APDU reader
pub fn setResult(name: []const u8, addr: []const u8, birth: []const u8, gender: []const u8) void {
    const n = @min(name.len, cached_name.len);
    @memcpy(cached_name[0..n], name[0..n]);
    cached_name_len = n;

    const a = @min(addr.len, cached_addr.len);
    @memcpy(cached_addr[0..a], addr[0..a]);
    cached_addr_len = a;

    const b = @min(birth.len, cached_birth.len);
    @memcpy(cached_birth[0..b], birth[0..b]);
    cached_birth_len = b;

    const g = @min(gender.len, cached_gender.len);
    @memcpy(cached_gender[0..g], gender[0..g]);
    cached_gender_len = g;
}
