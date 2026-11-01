//! Experimental CPU0-only WAMR owner: one PSRAM lease, two buddy arenas and a
//! private native stack. This is an emulator fixture, not a general task API.
const timer_group = @import("timer_group");
const memory = @import("native_tasks").memory;

pub const runtime_bytes = 128 * 1024;
pub const linear_bytes = 256 * 1024;
pub const module_bytes = 4 * 1024;
pub const module_count = 2;
pub const stack_bytes = 64 * 1024;
pub const surface_bytes = 32 * 1024;
pub const package_max_bytes = 4096;
pub const lease_bytes = runtime_bytes + linear_bytes + module_count * module_bytes + stack_bytes + surface_bytes;

pub const Report = extern struct {
    status: u32 = 0,
    calls: u32 = 0,
    trapped: u32 = 0,
    metered: u32 = 0,
    bad_text: u32 = 0,
    cycles: u32 = 0,
    cycle_recovered: u32 = 0,
    recovered: u32 = 0,
    runtime_peak: u32 = 0,
    linear_peak: u32 = 0,
    runtime_free: u32 = 0,
    linear_free: u32 = 0,
    export_count: u32 = 0,
    stack_used: u32 = 0,
    lease_bytes: u32 = lease_bytes,
    policy_status: u32 = 0,
    services: u32 = 0,
    sdk_abi: u32 = 0,
    origin: u32 = 0,
    attestation: u32 = 0,
    module_tag: u32 = 0,
    digest_tag: u32 = 0,
    instruction_budget: u32 = 0,
    signature_status: u32 = 0,
    boot_admission_cycles: u32 = 0,
    boot_admission_stack_used: u32 = 0,
    package_trust: u32 = 0,
    package_sequence_low: u32 = 0,
    package_sequence_high: u32 = 0,
    package_rejected: u32 = 0,
    boot_recovered: u32 = 0,
    trust_epoch_low: u32 = 0,
    trust_epoch_high: u32 = 0,
    initial_sequence_low: u32 = 0,
    initial_sequence_high: u32 = 0,
    installed_sequence_low: u32 = 0,
    installed_sequence_high: u32 = 0,
    package_syncs: u32 = 0,
    simulated_reboot: u32 = 0,
    interrupted_update_recovered: u32 = 0,
    owner_checks: u32 = 0,
    owners_released: u32 = 0,
    surface_checks: u32 = 0,
    event_checks: u32 = 0,
    event_frames: u32 = 0,
    uart_status: u32 = 0,
    uart_bytes: u32 = 0,
    uart_frames: u32 = 0,
    uart_rejected: u32 = 0,
    surface_width: u32 = 0,
    surface_height: u32 = 0,
    surface_stride: u32 = 0,
    surface_bytes: u32 = 0,
    surface_capacity: u32 = 0,
};

extern fn nih_wamr_call(
    runtime: [*]u8,
    linear: [*]u8,
    wasm_first: [*]u8,
    wasm_second: [*]u8,
    wasm_length: u32,
    report: *Report,
    stack_top: usize,
) callconv(.c) c_int;

var active_stack_low: usize = 0;
var active_surface: ?[]u8 = null;

pub fn bindTaskStorage(stack: []u8, surface: []u8) bool {
    if (active_stack_low != 0 or active_surface != null or stack.len != stack_bytes or surface.len != surface_bytes) return false;
    active_stack_low = @intFromPtr(stack.ptr);
    active_surface = surface;
    return true;
}
pub fn detachTaskStorage() void {
    active_stack_low = 0;
    active_surface = null;
}

export fn nih_wamr_surface_storage(length: *u32) callconv(.c) ?[*]u8 {
    const surface = active_surface orelse {
        length.* = 0;
        return null;
    };
    length.* = @intCast(surface.len);
    return surface.ptr;
}

export fn nih_wamr_monotonic_us() callconv(.c) u64 {
    return timer_group.Timer.fromGroup(0x500c2000, 0).?.counter() orelse 0;
}

export fn nih_wamr_stack_boundary() callconv(.c) ?[*]u8 {
    return if (active_stack_low == 0) null else @ptrFromInt(active_stack_low);
}

pub noinline fn run() Report {
    var report = Report{};
    const allocation = memory.allocExternal(lease_bytes, 64) catch {
        report.status = 100;
        return report;
    };
    const runtime = allocation.bytes[0..runtime_bytes];
    const linear = allocation.bytes[runtime_bytes..][0..linear_bytes];
    const modules = allocation.bytes[runtime_bytes + linear_bytes ..][0 .. module_count * module_bytes];
    const module_first = modules[0..module_bytes];
    const module_second = modules[module_bytes..][0..module_bytes];
    const stack = allocation.bytes[runtime_bytes + linear_bytes + module_count * module_bytes ..][0..stack_bytes];
    active_surface = allocation.bytes[runtime_bytes + linear_bytes + module_count * module_bytes + stack_bytes ..][0..surface_bytes];
    defer active_surface = null;
    @memset(stack, 0xa5);
    active_stack_low = @intFromPtr(stack.ptr);
    defer active_stack_low = 0;
    // The RV32 boot boundary copies linked journal fixtures to private mutable
    // media, installs sequence 2, recovers it through a fresh coordinator, then
    // copies only the admitted payload into these writable buffers. WAMR's
    // loader rewrites names, so journal media is never passed directly.
    @memset(modules, 0);
    const status = nih_wamr_call(
        runtime.ptr,
        linear.ptr,
        module_first.ptr,
        module_second.ptr,
        package_max_bytes,
        &report,
        @intFromPtr(stack.ptr) + stack.len,
    );
    var first: usize = 128;
    while (first < stack.len and stack[first] == 0xa5) : (first += 1) {}
    report.stack_used = @intCast(stack.len - first);
    for (stack[0..128]) |byte| if (byte != 0xa5) {
        report.status = 103;
    };
    @memset(stack, 0);
    if (status != 0 and report.status == 0) report.status = @intCast(status);
    report.lease_bytes = lease_bytes;
    release(allocation, &report);
    return report;
}

fn release(allocation: memory.reusable.Allocation, report: *Report) void {
    @memset(allocation.bytes, 0);
    memory.freeExternal(allocation) catch {
        report.status = 101;
    };
}
