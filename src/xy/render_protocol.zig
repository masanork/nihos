//! Internal borrowed render request. No ownership crosses the C boundary.
pub const Config = @import("view_config").Config;
pub const RubySpan = @import("document.zig").RubySpan;
pub const Request = extern struct {
    workspace: *anyopaque,
    learning: ?*@import("learning_session.zig").Session = null,
    navigation: ?*@import("navigation.zig").State = null,
    frame: [*]u8,
    frame_length: usize,
    config: *const Config,
    text: [*]const u8,
    text_length: usize,
    cursor: usize,
    status: [*]const u8,
    status_length: usize,
    show_cursor: u32,
    reserved_bottom_px: u16 = 0,
    book_prose: u32 = 0,
    code_spans: ?[*]const @import("view_config").CodeSpan = null,
    code_count: usize = 0,
    page_mode: u32 = 0, // pre-fitted read-only page; no caret-following crop
    ruby_text: [*]const u8 = "",
    ruby_text_length: usize = 0,
    ruby_spans: ?[*]const RubySpan = null,
    ruby_count: usize = 0,
};
