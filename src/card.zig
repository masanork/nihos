//! Board-independent card API plus the separately owned Tab5 touch adapter.
pub const Service = @import("card/service.zig").Service;
pub const Owner = @import("card/ccid_owner.zig").Owner;
pub const Entry = @import("card/pin_entry.zig").Entry;
pub const Touch = @import("board/tab5/touch.zig");
pub const TouchFeedback = @import("board/tab5/touch_feedback.zig");
