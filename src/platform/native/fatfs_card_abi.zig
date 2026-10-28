pub const Report = extern struct {
    status: u32 = 0,
    generation: u32 = 0,
    sectors: u32 = 0,
    kind: u32 = 0,
    partition: u32 = 0,
    first: u32 = 0,
    count: u32 = 0,
    bytes: u32 = 0,
    crc: u32 = 0,
    repeated_crc: u32 = 0,
    file_name_crc: u32 = 0,
    reads: u32 = 0,
    destroyed: u32 = 0,
    charged: u32 = 0,
    cleared: u32 = 0,
    recovered: u32 = 0,
};
pub const fields = .{ "status", "generation", "sectors", "kind", "partition", "first", "count", "bytes", "crc", "repeated_crc", "file_name_crc", "reads", "destroyed", "charged", "cleared", "recovered" };
pub extern fn nih_fatfs_card_attempt(*Report) callconv(.c) u32;
pub extern fn nih_fatfs_card_rpc_report(*Report) callconv(.c) void;
