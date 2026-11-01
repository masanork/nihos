//! Planning only: one complete Hosted packet in one C6 SDIO receive buffer.
//! This does not issue CMD53, own DMA, or establish the peer's buffer profile.
pub const block_bytes: usize = 512;
pub const peer_buffer_bytes: usize = 1536;
pub const fifo_end: u32 = 0x1f800;
pub const Error = error{InvalidLength};

pub const Plan = struct {
    logical: usize,
    wire: usize,
    fifo_address: u32,
    blocks: u16,
    credits: u8,
};

/// For long frames use one block-mode transaction, including zero padding.
/// Small frames are left to the existing byte-mode/single-block transport.
pub fn longPacket(length: usize) Error!Plan {
    if (length <= block_bytes or length > peer_buffer_bytes) return error.InvalidLength;
    const blocks: u16 = @intCast((length + block_bytes - 1) / block_bytes);
    return .{
        .logical = length,
        .wire = @as(usize, blocks) * block_bytes,
        .fifo_address = fifo_end - @as(u32, @intCast(length)),
        .blocks = blocks,
        .credits = 1,
    };
}
