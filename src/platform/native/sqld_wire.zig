pub const Request = extern struct {
    epoch: u32 = 0,
    sequence: u32 = 0,
    operation: u32 = 0,
    handle: u32 = 0,
    offset: u32 = 0,
    length: u32 = 0,
    count: u32 = 0,
    text: [512]u8 = @splat(0),
    argument: [64]u8 = @splat(0),
};
pub const Response = extern struct {
    epoch: u32 = 0,
    sequence: u32 = 0,
    status: i32 = 0,
    sqlite_code: i32 = 0,
    outcome: u32 = 0,
    length: u32 = 0,
    text: [1024]u8 = @splat(0),
};
pub const Report = extern struct {
    phase: u32 = 0,
    error_code: i32 = 0,
    sectors: u32 = 0,
    cid_crc: u32 = 0,
    requests: u32 = 0,
    completed: u32 = 0,
    io_reads: u32 = 0,
    io_writes: u32 = 0,
    syncs: u32 = 0,
    generation: u32 = 0,
    stack_used: u32 = 0,
    heap_used: u32 = 0,
};
