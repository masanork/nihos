//! Board-independent card API plus the separately owned Tab5 touch adapter.
pub const Service = @import("card/service.zig").Service;
pub const Owner = @import("card/ccid_owner.zig").Owner;
pub const Entry = @import("card/pin_entry.zig").Entry;
pub const Touch = @import("board/tab5/touch.zig");
pub const TouchFeedback = @import("board/tab5/touch_feedback.zig");
pub const KeypadDemo = @import("card/keypad_demo.zig");
pub const PinScreen = @import("graphics/card_pin.zig");
pub const KeypadPlan = @import("graphics/keypad_plan.zig");
pub const BootScreen = @import("graphics/card_splash.zig");
pub const KeypadAtlas = @import("graphics/keypad_atlas.zig");
pub const ResultScreen = @import("graphics/card_read_result.zig");
pub const WirePolicy = @import("card/wire_policy.zig").Policy;
pub const Contact = @import("card/pin_entry.zig").Contact;
pub const Key = @import("card/pin_entry.zig").Key;
pub const Surface = @import("card/surface.zig");
pub const PhotoFixture = @import("graphics/photo_fixture.zig");

pub const License = @import("card/license.zig");
pub const ServiceType = @import("card/service.zig").ServiceType;
pub const ExtendedService = @import("card/service.zig").ExtendedService;
pub const Presence = @import("card/presence.zig");
pub const WirePolicyType = @import("card/wire_policy.zig").PolicyType;
pub const LicenseSession = @import("card/license_session.zig");
pub const LicenseRecord = @import("card/license_record.zig");
pub const LicenseCrypto = @import("card/license_crypto.zig");
pub const LicenseTrust = @import("card/license_trust.zig");
