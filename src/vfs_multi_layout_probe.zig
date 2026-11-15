//! RV32 compile-only size probe for the host multi-client VFS prototype.
//! Symbols are arrays so the ELF symbol sizes record the target layouts.
const multi = @import("fs/vfs_multi_writer.zig");
const reader = @import("fs/vfs_multi_read_client.zig");
const Backend = struct { tag: u32 = 0 };
const Combined = struct {
    owner: multi.Service(Backend),
    queues: [2]multi.Queues,
    issuer: multi.Issuer,
};
pub export var nih_multi_request_size: [@sizeOf(multi.Request)]u8 = undefined;
pub export var nih_multi_response_size: [@sizeOf(multi.Response)]u8 = undefined;
pub export var nih_multi_queues_size: [@sizeOf(multi.Queues)]u8 = undefined;
pub export var nih_multi_owner_size: [@sizeOf(multi.Service(Backend))]u8 = undefined;
pub export var nih_multi_issuer_size: [@sizeOf(multi.Issuer)]u8 = undefined;
pub export var nih_multi_reader_size: [@sizeOf(reader.Reader)]u8 = undefined;
pub export var nih_multi_combined_size: [@sizeOf(Combined)]u8 = undefined;
pub export var nih_multi_combined_alignment: [@alignOf(Combined)]u8 = undefined;
