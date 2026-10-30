//! CPU0 owner-local PSRAM frame lease and bounded cache handoff.
//! Not linked into normal firmware. DMA capability and stop-before-release
//! must be established by the service integrator.
const memory = @import("native_tasks").memory;
const workspace = @import("camera_workspace");
const preview = @import("camera_preview");
const frame_bytes = 1280 * 720;
const cache_chunk = 1024;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;
extern fn nih_rom_cache_invalidate(u32, u32, u32) callconv(.c) i32;
pub const Backend = struct {
    pub const Allocation = memory.reusable.Pin;
    pub fn allocate(_: *Backend, length: usize, alignment: usize) ?Allocation {
        // Allocation and pin are published atomically against task close.
        const bytes_needed = if (@import("native_options").camera_diagnostics) length else length * 2;
        return memory.reusable.allocPinnedTask(bytes_needed, alignment) catch null;
    }
    pub fn bytes(_: *Backend, allocation: Allocation) []u8 {
        return allocation.allocation.bytes;
    }
    fn sync(data: []u8, invalidate_op: bool) bool {
        const chunk_address: u32 = @intCast(@intFromPtr(data.ptr));
        const length: u32 = @intCast(data.len);
        const previous = asm volatile ("csrrci %[previous], mstatus, 8"
            : [previous] "=r" (-> u32),
            :
            : .{ .memory = true });
        defer if (previous & 8 != 0) {
            asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
        };
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        const status = if (invalidate_op) nih_rom_cache_invalidate((1 << 4) | (1 << 5), chunk_address, length) else nih_rom_cache_writeback((1 << 4) | (1 << 5), chunk_address, length);
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        return status == 0;
    }
    pub fn writeback(_: *Backend, data: []u8) bool {
        return sync(data, false);
    }
    pub fn invalidate(_: *Backend, data: []u8) bool {
        return sync(data, true);
    }
    pub fn release(_: *Backend, allocation: Allocation) bool {
        memory.reusable.releasePinnedTask(allocation) catch return false;
        return true;
    }
};
pub const FrameWorkspace = workspace.Workspace(Backend, frame_bytes, cache_chunk);
var backend: Backend = .{};
var frame: FrameWorkspace = .{};
var stream_second_offset: usize = 0;
pub fn prepareStreamSecond() ?bool {
    const allocation = frame.allocation orelse return null;
    const data = allocation.allocation.bytes;
    if (data.len < frame_bytes * 2) return null;
    if (stream_second_offset == frame_bytes) return true;
    const bytes = data[frame_bytes + stream_second_offset ..][0..cache_chunk];
    @memset(bytes, 0);
    if (!backend.writeback(bytes) or !backend.invalidate(bytes)) return null;
    stream_second_offset += cache_chunk;
    return stream_second_offset == frame_bytes;
}
pub fn streamSecondAddress() ?u32 {
    if (stream_second_offset != frame_bytes) return null;
    return (address() orelse return null) + frame_bytes;
}
pub fn streamPreviewRow(address_value: u32, row: usize) ?[preview.width]u8 {
    if (row >= preview.height or (address_value != address() and address_value != streamSecondAddress())) return null;
    // Caller holds the completed slot's generation; IRQ never writes that slot
    // until release. The original frame and second allocation remain pinned.
    const data = @as([*]u8, @ptrFromInt(address_value))[0..frame_bytes];
    const start = row * 16 * preview.frame_width;
    for (0..4) |part| if (!backend.invalidate(data[start + part * 640 ..][0..640])) return null;
    return preview.row(data, row);
}
pub fn begin() bool {
    return frame.begin(&backend);
}
pub fn poll() void {
    frame.poll(&backend);
}
pub fn startDma() bool {
    return frame.beginDma();
}
/// Prototype only: caller retains the same successful capture/channel, checks
/// stopped hardware, and invalidates every chunk before overwriting this frame.
/// Never called after uncertain cleanup; no allocator release is involved.
pub fn restartRetainedDma(identity: u64) bool {
    if (frame.phase != .pinned or frame.leaseIdentity() != identity) return false;
    frame.phase = .dma;
    return true;
}
pub fn finishDma(clean: bool) bool {
    return frame.finishDma(clean);
}
pub fn erase() bool {
    return frame.beginErase();
}
pub fn abortPreparation() bool {
    return frame.abortPreparation();
}
pub fn pin() void {
    frame.pin();
}
pub fn phase() FrameWorkspace.Phase {
    return frame.phase;
}
/// Identity of the live DMA-owned frame, for the serialized CPU0 owner.
/// A pinned, stopped, or CPU-owned frame is not eligible for a new stop probe.
pub fn dmaLeaseIdentity() ?u64 {
    if (frame.phase != .dma) return null;
    return frame.leaseIdentity();
}
/// Valid only while the workspace holds its lease. Caller must check state.
pub fn address() ?u32 {
    const allocation = frame.allocation orelse return null;
    return @intCast(@intFromPtr(allocation.allocation.bytes.ptr));
}
/// Diagnostic only: read one aligned chunk of a pinned frame. The caller
/// must separately confirm stopped DMA and retain the domain/channel lease.
/// A checksum comparison cannot prove quiescence or detect every change.
pub fn readChunk(identity: u64, index: usize) ?[]const u8 {
    if (frame.phase != .pinned or frame.leaseIdentity() != identity or index >= frame_bytes / cache_chunk) return null;
    const allocation = frame.allocation orelse return null;
    const data = backend.bytes(allocation);
    if (data.len < frame_bytes) return null;
    const chunk = data[index * cache_chunk ..][0..cache_chunk];
    if (!backend.invalidate(chunk)) return null;
    return chunk;
}
/// Zero an exclusively pinned diagnostic chunk. Caller confirms stopped DMA;
/// this does not release it or prove that future DMA writes cannot arrive.
pub fn zeroChunk(identity: u64, index: usize) bool {
    if (frame.phase != .pinned or frame.leaseIdentity() != identity or index >= frame_bytes / cache_chunk) return false;
    const allocation = frame.allocation orelse return false;
    const data = backend.bytes(allocation);
    if (data.len < frame_bytes) return false;
    const chunk = data[index * cache_chunk ..][0..cache_chunk];
    if (!backend.invalidate(chunk)) return false;
    @memset(chunk, 0);
    if (!backend.writeback(chunk) or !backend.invalidate(chunk)) return false;
    for (chunk) |byte| if (byte != 0) return false;
    return true;
}
/// Explicit negative control on a pinned, incomplete diagnostic frame. Caller
/// confirms stopped channel and domain ownership; never use for application data.
pub fn flipChunkByte(identity: u64, index: usize) bool {
    if (frame.phase != .pinned or frame.leaseIdentity() != identity or index >= frame_bytes / cache_chunk) return false;
    const allocation = frame.allocation orelse return false;
    const data = backend.bytes(allocation);
    if (data.len < frame_bytes) return false;
    const chunk = data[index * cache_chunk ..][0..cache_chunk];
    if (!backend.invalidate(chunk)) return false;
    const changed = chunk[0] ^ 1;
    chunk[0] = changed;
    if (!backend.writeback(chunk) or !backend.invalidate(chunk)) return false;
    return chunk[0] == changed;
}
/// Read-only diagnostic sampling, only while the entire DMA lease is pinned.
/// The caller must separately establish the completed and stopped capture.
pub fn previewRow(identity: u64, row: usize) ?[preview.width]u8 {
    if (frame.phase != .pinned or frame.leaseIdentity() != identity or row >= preview.height) return null;
    const allocation = frame.allocation orelse return null;
    const data = backend.bytes(allocation);
    if (data.len < preview.frame_bytes) return null;
    const start = row * 16 * preview.frame_width;
    // Invalidate only the two sampled rows in aligned, bounded chunks.
    for (0..4) |part| if (!backend.invalidate(data[start + part * 640 ..][0..640])) return null;
    return preview.row(data, row);
}
