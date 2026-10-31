//! Synthetic independently generated DHCP packets; see README.md for inputs.
pub const offer = @embedFile("dhcp-offer.bin");
pub const ack = @embedFile("dhcp-ack.bin");
