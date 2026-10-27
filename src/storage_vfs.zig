//! Module boundary shared by host and RV32 qualification; no runtime startup.
pub const fatfs = @import("fs/fatfs_backend.zig");
pub const rpc = @import("fs/vfs_rpc.zig");
pub const memory = @import("fs/vfs_memory.zig");
pub const development = @import("kernel/development_memory.zig");
pub const spsc = @import("kernel/spsc_ring.zig");

pub const event_latch = @import("kernel/event_latch.zig");
