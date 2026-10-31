//! Internal borrowed render request. No ownership crosses the C boundary.
pub const Config = @import("view_config").Config;
pub const RubySpan = @import("document.zig").RubySpan;
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
    page_mode: u32 = 0, // pre-fitted read-only page; no caret-following crop
    ruby_text: [*]const u8 = "",
    ruby_text_length: usize = 0,
    ruby_spans: ?[*]const RubySpan = null,
    ruby_count: usize = 0,
};
