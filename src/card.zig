//! Board-independent card API plus the separately owned Tab5 touch adapter.
pub const Service = @import("card/service.zig").Service;
pub const Owner = @import("card/ccid_owner.zig").Owner;
pub const Entry = @import("card/pin_entry.zig").Entry;
pub const Touch = @import("board/tab5/touch.zig");
pub const TouchFeedback = @import("board/tab5/touch_feedback.zig");
pub const KeypadDemo = @import("card/keypad_demo.zig");
pub const PinScreen = @import("graphics/card_pin.zig");
pub const KeypadPlan = @import("graphics/keypad_plan.zig");
pub const KeypadAtlas = @import("graphics/keypad_atlas.zig");
pub const ResultScreen = @import("graphics/card_read_result.zig");
pub const WirePolicy = @import("card/wire_policy.zig").Policy;
pub const Contact = @import("card/pin_entry.zig").Contact;
pub const Key = @import("card/pin_entry.zig").Key;
