//! Internal borrowed render request. No ownership crosses the C boundary.
pub const Config = @import("view_config").Config;
pub const Request = extern struct {
    workspace: *anyopaque,
    frame: [*]u8,
    frame_length: usize,
    config: *const Config,
    text: [*]const u8,
    text_length: usize,
    cursor: usize,
    status: [*]const u8,
    status_length: usize,
    show_cursor: u32,
};
