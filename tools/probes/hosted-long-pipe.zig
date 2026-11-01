//! Share transport types with the long sender in the native Bus fixture.
const sender = @import("hosted_long_sender");
pub const Stream = sender.Stream;
pub const ProfileStream = sender.ProfileStream;
