//! First target-side Zig entry point.
//!
//! ESP-IDF calls `app_main` in the C shim. The shim collects vendor-owned boot
//! facts and then crosses the stable ABI exactly once into this file.

const std = @import("std");
const abi = @import("abi");
const arena_module = @import("arena");
const native_trap = @import("native_trap");
const spsc_ring = @import("spsc_ring");
const test_pattern = @import("test_pattern");
const tick_counter = @import("tick_counter");

pub const panic = std.debug.no_panic;

extern fn nih_platform_console_write(data: [*]const u8, length: u32) i32;
extern fn nih_platform_memory_region(kind: u32, out: *abi.MemoryRegion) i32;
extern fn nih_platform_cache_sync(range: *const abi.DmaRange) i32;
extern fn nih_platform_dma_copy(copy: *abi.DmaCopy) i32;
extern fn nih_platform_display_init(out: *abi.DisplayInfo) i32;
extern fn nih_platform_display_present(present: *abi.DisplayPresent) i32;
extern fn nih_platform_display_wait_vsync(vsync: *abi.DisplayVsync) i32;
extern fn nih_platform_touch_init(out: *abi.TouchInfo) i32;
extern fn nih_platform_touch_sample(out: *abi.TouchSample) i32;
extern fn nih_platform_cpu_id() u32;
extern fn nih_platform_monotonic_us() u64;
extern fn nih_platform_cpu_start(
    cpu_id: u32,
    entry: *const fn (?*anyopaque) callconv(.c) void,
    argument: ?*anyopaque,
) i32;
extern fn nih_platform_timer_start(
    period_us: u32,
    entry: *const fn (?*anyopaque) callconv(.c) void,
    argument: ?*anyopaque,
) i32;
extern fn nih_platform_timer_stop() i32;

const MailboxMessage = struct {
    sequence: u32,
    payload: u32,
};
const MailboxRing = spsc_ring.SpscRing(MailboxMessage, 64);
const MailboxContext = struct {
    requests: MailboxRing,
    responses: MailboxRing,
    worker_cpu: std.atomic.Value(u32),
};

// SAFETY: CPU0 fully initializes this context before cpu_start publishes its
// address to CPU1, and the boot self-test starts only one worker at a time.
var mailbox_context: MailboxContext = undefined;
const mailbox_messages: u32 = 100_000;
const mailbox_transform: u32 = 0xa5a5_5a5a;
var timer_ticks: tick_counter.TickCounter = .{};

fn write(bytes: []const u8) void {
    if (bytes.len == 0) return;
    _ = nih_platform_console_write(bytes.ptr, @intCast(bytes.len));
}

fn writeU64(label: []const u8, value: u64) void {
    var digits: [20]u8 = undefined;
    var remaining = value;
    var start = digits.len;

    if (remaining == 0) {
        start -= 1;
        digits[start] = '0';
    } else {
        while (remaining != 0) {
            start -= 1;
            digits[start] = @intCast('0' + remaining % 10);
            remaining /= 10;
        }
    }

    write(label);
    write(digits[start..]);
    write("\r\n");
}

fn writeU32(label: []const u8, value: u32) void {
    writeU64(label, value);
}

fn mailboxPayload(sequence: u32) u32 {
    return sequence *% 2_654_435_761;
}

fn timerTick(_: ?*anyopaque) callconv(.c) void {
    _ = timer_ticks.noteInterrupt();
}

fn exerciseTimer() bool {
    const period_us: u32 = 1000;
    const target_ticks: u32 = 128;
    const timeout_us: u64 = 1_000_000;
    timer_ticks.reset();

    const started_us = nih_platform_monotonic_us();
    if (nih_platform_timer_start(period_us, &timerTick, null) != abi.Status.ok)
        return false;
    while (timer_ticks.pending() < target_ticks) {
        if (nih_platform_monotonic_us() - started_us >= timeout_us) {
            _ = nih_platform_timer_stop();
            return false;
        }
        std.atomic.spinLoopHint();
    }
    if (nih_platform_timer_stop() != abi.Status.ok) return false;

    const elapsed_us = nih_platform_monotonic_us() - started_us;
    const observed_ticks = timer_ticks.takePending();
    if (elapsed_us == 0 or observed_ticks < target_ticks) return false;
    writeU32("timer_period_us=", period_us);
    writeU32("timer_ticks=", observed_ticks);
    writeU64("timer_elapsed_us=", elapsed_us);
    return true;
}

fn mailboxWorker(argument: ?*anyopaque) callconv(.c) void {
    const context: *MailboxContext = @ptrCast(@alignCast(argument.?));
    context.worker_cpu.store(nih_platform_cpu_id(), .release);

    var completed: u32 = 0;
    while (completed < mailbox_messages) {
        const request = context.requests.tryPop() orelse {
            std.atomic.spinLoopHint();
            continue;
        };
        const response = MailboxMessage{
            .sequence = request.sequence,
            .payload = request.payload ^ mailbox_transform,
        };
        while (!context.responses.tryPush(response))
            std.atomic.spinLoopHint();
        completed += 1;
    }
}

fn exerciseSmpMailbox(cpu_count: u32) bool {
    if (cpu_count < 2 or nih_platform_cpu_id() != 0) return false;
    mailbox_context = .{
        .requests = MailboxRing.init(),
        .responses = MailboxRing.init(),
        .worker_cpu = .init(std.math.maxInt(u32)),
    };

    const started_us = nih_platform_monotonic_us();
    if (nih_platform_cpu_start(1, &mailboxWorker, &mailbox_context) !=
        abi.Status.ok)
    {
        return false;
    }

    var sent: u32 = 0;
    var received: u32 = 0;
    var request_full: u64 = 0;
    var response_empty: u64 = 0;
    while (received < mailbox_messages) {
        while (sent < mailbox_messages) {
            const request = MailboxMessage{
                .sequence = sent,
                .payload = mailboxPayload(sent),
            };
            if (!mailbox_context.requests.tryPush(request)) {
                request_full += 1;
                break;
            }
            sent += 1;
        }

        const response = mailbox_context.responses.tryPop() orelse {
            response_empty += 1;
            std.atomic.spinLoopHint();
            continue;
        };
        if (response.sequence != received or
            response.payload != mailboxPayload(received) ^ mailbox_transform)
        {
            return false;
        }
        received += 1;
    }

    const elapsed_us = nih_platform_monotonic_us() - started_us;
    const worker_cpu = mailbox_context.worker_cpu.load(.acquire);
    if (worker_cpu != 1 or elapsed_us == 0) return false;

    writeU32("smp_caller_cpu=", nih_platform_cpu_id());
    writeU32("smp_worker_cpu=", worker_cpu);
    writeU32("smp_mailbox_messages=", mailbox_messages);
    writeU64("smp_mailbox_elapsed_us=", elapsed_us);
    writeU64("smp_mailbox_roundtrips_per_second=", (@as(u64, mailbox_messages) * 1_000_000) / elapsed_us);
    writeU64("smp_request_full_observations=", request_full);
    writeU64("smp_response_empty_observations=", response_empty);
    return true;
}

fn syncRange(bytes: []u8, direction: u32) bool {
    const range = abi.DmaRange{
        .address = @intCast(@intFromPtr(bytes.ptr)),
        .length = @intCast(bytes.len),
        .direction = direction,
        .flags = 0,
    };
    return nih_platform_cache_sync(&range) == abi.Status.ok;
}

fn fillPattern(bytes: []u8, seed: u8) void {
    var value = seed;
    for (bytes) |*byte| {
        byte.* = value;
        value +%= 17;
    }
}

fn runDmaPath(label: []const u8, source: []u8, destination: []u8) bool {
    const rounds: u32 = 8;
    var elapsed_us: u64 = 0;

    for (0..rounds) |round| {
        fillPattern(source, @intCast(round + 1));
        @memset(destination, 0);
        if (!syncRange(source, abi.DmaDirection.to_device)) return false;
        if (!syncRange(destination, abi.DmaDirection.bidirectional)) return false;

        var copy = abi.DmaCopy{
            .source_address = @intCast(@intFromPtr(source.ptr)),
            .destination_address = @intCast(@intFromPtr(destination.ptr)),
            .length = @intCast(source.len),
            .flags = 0,
            .elapsed_us = 0,
        };
        if (nih_platform_dma_copy(&copy) != abi.Status.ok) return false;
        elapsed_us += copy.elapsed_us;
        if (!syncRange(destination, abi.DmaDirection.from_device)) return false;
        if (!std.mem.eql(u8, source, destination)) return false;
    }

    write(label);
    writeU64("", elapsed_us);
    return true;
}

fn exerciseDma() bool {
    // SAFETY: Successful platform calls initialize the complete out values;
    // the function returns without inspecting them on any error.
    var internal_region: abi.MemoryRegion = undefined;
    // SAFETY: Same out-parameter contract as internal_region above.
    var psram_region: abi.MemoryRegion = undefined;
    if (nih_platform_memory_region(abi.MemoryKind.internal, &internal_region) !=
        abi.Status.ok or
        nih_platform_memory_region(abi.MemoryKind.psram, &psram_region) !=
            abi.Status.ok)
    {
        return false;
    }
    if ((internal_region.flags & abi.MemoryFlags.dma_data) == 0 or
        (psram_region.flags & abi.MemoryFlags.dma_data) == 0)
    {
        return false;
    }

    // SAFETY: The platform keeps both transferred regions exclusively owned
    // by the Zig boot arenas for the lifetime of the firmware.
    const internal_base: [*]u8 = @ptrFromInt(internal_region.address);
    const psram_base: [*]u8 = @ptrFromInt(psram_region.address);
    var internal_arena = arena_module.Arena.init(
        internal_base[0..@intCast(internal_region.length)],
    );
    var psram_arena = arena_module.Arena.init(
        psram_base[0..@intCast(psram_region.length)],
    );

    const transfer_bytes: usize = 16 * 1024;
    const internal_source = internal_arena.alloc(transfer_bytes, 128) orelse
        return false;
    const internal_destination = internal_arena.alloc(transfer_bytes, 128) orelse
        return false;
    const psram_source = psram_arena.alloc(transfer_bytes, 128) orelse
        return false;
    const psram_destination = psram_arena.alloc(transfer_bytes, 128) orelse
        return false;

    writeU32("dma_bytes_per_path=", @intCast(transfer_bytes * 8));
    if (!runDmaPath("dma_internal_to_internal_us=", internal_source, internal_destination))
        return false;
    if (!runDmaPath("dma_internal_to_psram_us=", internal_source, psram_destination))
        return false;
    if (!runDmaPath("dma_psram_to_internal_us=", psram_source, internal_destination))
        return false;
    if (!runDmaPath("dma_psram_to_psram_us=", psram_source, psram_destination))
        return false;
    return true;
}

fn exerciseDisplay() bool {
    // SAFETY: display_init initializes the complete value on success, and the
    // error path returns before any field is inspected.
    var info: abi.DisplayInfo = undefined;
    if (nih_platform_display_init(&info) != abi.Status.ok) return false;
    if (info.width == 0 or info.height == 0 or
        info.stride_bytes != info.width * 2 or
        info.pixel_format != abi.DisplayPixelFormat.rgb565_le or
        info.framebuffer_address == 0 or
        info.framebuffer_bytes < info.stride_bytes * info.height or
        (info.framebuffer_flags & abi.DisplayFrameFlags.writable) == 0 or
        (info.framebuffer_flags & abi.DisplayFrameFlags.scanout) == 0)
    {
        return false;
    }

    // SAFETY: display_init lends this fixed-size writable scanout buffer until
    // shutdown. The Zig side never retains a view beyond that platform lease.
    const base: [*]u8 = @ptrFromInt(info.framebuffer_address);
    const framebuffer = base[0..@intCast(info.framebuffer_bytes)];
    if (!test_pattern.paintRgb565Le(
        framebuffer,
        @intCast(info.width),
        @intCast(info.height),
        @intCast(info.stride_bytes),
    )) return false;

    var present = abi.DisplayPresent{
        .framebuffer_address = info.framebuffer_address,
        .framebuffer_bytes = info.framebuffer_bytes,
        .flags = 0,
        .elapsed_us = 0,
        .vsync_count = 0,
    };
    if (nih_platform_display_present(&present) != abi.Status.ok) return false;

    const samples: u32 = 60;
    var total_us: u64 = 0;
    var last_count = present.vsync_count;
    for (0..samples) |_| {
        var vsync = abi.DisplayVsync{
            .timeout_ms = 100,
            .flags = 0,
            .elapsed_us = 0,
            .vsync_count = 0,
        };
        if (nih_platform_display_wait_vsync(&vsync) != abi.Status.ok)
            return false;
        if (vsync.vsync_count == last_count) return false;
        last_count = vsync.vsync_count;
        total_us += vsync.elapsed_us;
    }

    writeU32("display_width=", info.width);
    writeU32("display_height=", info.height);
    writeU32("display_stride_bytes=", info.stride_bytes);
    writeU32("display_framebuffer_bytes=", info.framebuffer_bytes);
    writeU32("display_present_us=", present.elapsed_us);
    writeU32("display_vsync_samples=", samples);
    writeU64("display_vsync_elapsed_us=", total_us);
    if (total_us == 0) return false;
    writeU64("display_refresh_millihz=", (@as(u64, samples) * 1_000_000_000) / total_us);
    return true;
}

fn exerciseTouch() bool {
    // SAFETY: touch_init initializes the complete value on success, and the
    // error path returns before any field is inspected.
    var info: abi.TouchInfo = undefined;
    if (nih_platform_touch_init(&info) != abi.Status.ok) return false;
    if (info.width == 0 or info.height == 0 or
        info.max_points != abi.touch_max_points or info.flags != 0)
    {
        return false;
    }

    const samples: u32 = 8;
    var points_observed: u32 = 0;
    var last_sequence: u32 = 0;
    for (0..samples) |_| {
        // SAFETY: touch_sample initializes the complete value on success, and
        // the error path returns before any field is inspected.
        var sample: abi.TouchSample = undefined;
        if (nih_platform_touch_sample(&sample) != abi.Status.ok) return false;
        if (sample.point_count > abi.touch_max_points or
            sample.sequence <= last_sequence or sample.flags != 0)
        {
            return false;
        }
        last_sequence = sample.sequence;
        points_observed += sample.point_count;
        for (sample.points[0..@intCast(sample.point_count)]) |point| {
            if (point.x >= info.width or point.y >= info.height) return false;
        }

        var vsync = abi.DisplayVsync{
            .timeout_ms = 100,
            .flags = 0,
            .elapsed_us = 0,
            .vsync_count = 0,
        };
        if (nih_platform_display_wait_vsync(&vsync) != abi.Status.ok)
            return false;
    }

    writeU32("touch_width=", info.width);
    writeU32("touch_height=", info.height);
    writeU32("touch_max_points=", info.max_points);
    writeU32("touch_samples=", samples);
    writeU32("touch_points_observed=", points_observed);
    return true;
}

fn exerciseMemory(kind: u32) bool {
    // SAFETY: memory_region initializes the complete value on success, and
    // the error path returns before any field is inspected.
    var region: abi.MemoryRegion = undefined;
    if (nih_platform_memory_region(kind, &region) != abi.Status.ok) return false;
    if (region.kind != kind or region.length == 0 or
        region.cache_line_bytes == 0 or
        (region.flags & abi.MemoryFlags.writable) == 0)
    {
        return false;
    }

    // SAFETY: The platform transfers exclusive ownership of this writable
    // region to the Zig boot arena for the lifetime of the firmware.
    const base: [*]u8 = @ptrFromInt(region.address);
    var arena = arena_module.Arena.init(base[0..@intCast(region.length)]);
    const small = arena.alloc(37, 8) orelse return false;
    const cache_line: usize = @intCast(region.cache_line_bytes);
    const aligned = arena.alloc(cache_line, cache_line) orelse return false;
    if (@intFromPtr(aligned.ptr) % cache_line != 0) return false;

    @memset(small, 0x3c);
    @memset(aligned, 0xa5);

    if (kind == abi.MemoryKind.psram) {
        if ((region.flags & abi.MemoryFlags.cacheable) == 0) return false;
        var range = abi.DmaRange{
            .address = @intCast(@intFromPtr(aligned.ptr)),
            .length = @intCast(aligned.len),
            .direction = abi.DmaDirection.to_device,
            .flags = 0,
        };
        if (nih_platform_cache_sync(&range) != abi.Status.ok) return false;
        range.direction = abi.DmaDirection.from_device;
        if (nih_platform_cache_sync(&range) != abi.Status.ok) return false;
        for (aligned) |byte| {
            if (byte != 0xa5) return false;
        }
    }

    writeU32(if (kind == abi.MemoryKind.internal)
        "internal_arena_bytes="
    else
        "psram_arena_bytes=", region.length);
    return true;
}

export fn nihos_zig_main(info: *const abi.BootInfo) void {
    write("\r\nnihos: Zig kernel entry\r\n");
    if (info.abi_version != abi.version) {
        write("nihos: platform ABI mismatch\r\n");
        return;
    }

    writeU32("abi=", info.abi_version);
    writeU32("chip_revision=", info.chip_revision);
    writeU32("cpu_count=", info.cpu_count);
    writeU32("internal_heap_bytes=", info.internal_heap_bytes);
    writeU32("psram_heap_bytes=", info.psram_heap_bytes);
    writeU32("flash_bytes=", info.flash_bytes);

    if (!exerciseMemory(abi.MemoryKind.internal)) {
        write("nihos: internal arena failed\r\n");
        return;
    }
    write("internal_allocator=ok\r\n");

    if (!exerciseMemory(abi.MemoryKind.psram)) {
        write("nihos: PSRAM arena or cache sync failed\r\n");
        return;
    }
    write("psram_allocator=ok\r\n");
    write("psram_cache_sync=ok\r\n");

    if (!exerciseSmpMailbox(info.cpu_count)) {
        write("nihos: SMP mailbox failed\r\n");
        return;
    }
    write("smp_mailbox=ok\r\n");

    if (!exerciseTimer()) {
        write("nihos: periodic timer failed\r\n");
        return;
    }
    write("periodic_timer=ok\r\n");

    if (!native_trap.exerciseContextSwitchRoundTrip()) {
        write("nihos: native context switch failed\r\n");
        return;
    }
    write("native_context_switch=ok\r\n");
    for (0..2) |run| {
        const native_timer = native_trap.exerciseNativeTimer() orelse {
            write("nihos: native timer failed\r\n");
            return;
        };
        writeU32("native_timer_run=", @intCast(run + 1));
        writeU32("native_timer_ticks=", native_timer.ticks);
        writeU64("native_timer_elapsed_us=", native_timer.elapsed_us);
        writeU32("native_timer_interrupt_id=", native_timer.interrupt_id);
        writeU32("native_timer_mcause=", native_timer.raw_mcause);
    }
    const preempted = native_trap.exerciseNativePreemption() orelse {
        write("nihos: native preemption failed\r\n");
        return;
    };
    writeU64("preemption_elapsed_ticks=", preempted.elapsed_ticks);
    writeU32("preemption_interrupts=", preempted.interrupts);
    writeU64("preemption_caught_up_ticks=", preempted.caught_up_ticks);
    writeU64("preemption_elapsed_us=", preempted.elapsed_us);
    writeU64("preemption_bootstrap_runtime_ticks=", preempted.bootstrap_runtime_ticks);
    for (0..2) |worker| {
        writeU32("preemption_worker=", @intCast(worker));
        writeU32("preemption_iterations=", preempted.worker_iterations[worker]);
        writeU32("preemption_selections=", preempted.worker_selections[worker]);
        writeU64("preemption_runtime_ticks=", preempted.worker_runtime_ticks[worker]);
    }
    write("native_preemption=ok\r\n");
    writeU32("integer_preemption_fpu_saves=", preempted.floating_saves);
    writeU32("integer_preemption_fpu_restores=", preempted.floating_restores);
    const floating = native_trap.exerciseNativeFloatingPreemption() orelse {
        write("nihos: floating preemption failed\r\n");
        return;
    };
    writeU64("fpu_preemption_elapsed_ticks=", floating.elapsed_ticks);
    writeU32("fpu_preemption_interrupts=", floating.interrupts);
    writeU32("fpu_preemption_saves=", floating.floating_saves);
    writeU32("fpu_preemption_restores=", floating.floating_restores);
    for (0..2) |worker| {
        writeU32("fpu_preemption_worker=", @intCast(worker));
        writeU32("fpu_register_checks=", floating.floating_checks[worker]);
    }
    write("fpu_boundary_restore=ok\r\n");
    write("native_fpu_preemption=ok\r\n");
    const lifecycle = native_trap.exerciseNativeLifecycle() orelse {
        write("nihos: native lifecycle failed\r\n");
        return;
    };
    writeU32("task_sleep_started=", lifecycle.sleep_started);
    writeU32("task_sleep_deadline=", lifecycle.sleep_deadline);
    writeU32("task_sleep_resumed=", lifecycle.sleep_resumed);
    writeU32("task_explicit_wakes=", lifecycle.explicit_wakes);
    writeU32("task_exit_code_0=", @bitCast(lifecycle.exits[0]));
    writeU32("task_exit_code_1=", @bitCast(lifecycle.exits[1]));
    writeU32("task_syscalls=", lifecycle.calls);
    writeU32("task_timer_interrupts=", lifecycle.interrupts);
    writeU64("task_idle_runtime_ticks=", lifecycle.idle_runtime_ticks);
    writeU32("task_reaped=", lifecycle.reaped);
    writeU32("task_old_generation=", lifecycle.old_generation);
    writeU32("task_replacement_generation=", lifecycle.replacement_generation);
    write("task_stale_handle_rejected=ok\r\n");
    write("native_lifecycle=ok\r\n");
    const events = native_trap.exerciseNativeEvents() orelse {
        write("nihos: native events failed\r\n");
        return;
    };
    writeU32("event_immediate_receives=", events.immediate_events);
    writeU32("event_blocked_waits=", events.blocked_events);
    writeU32("event_deferred_deliveries=", events.delivered_events);
    writeU32("event_syscalls=", events.calls);
    writeU32("event_timer_interrupts=", events.interrupts);
    writeU64("event_idle_runtime_ticks=", events.idle_runtime_ticks);
    writeU32("event_exit_code_0=", @bitCast(events.exits[0]));
    writeU32("event_exit_code_1=", @bitCast(events.exits[1]));
    writeU32("event_reaped=", events.reaped);
    writeU32("event_replacement_generation=", events.replacement_generation);
    write("event_stale_handle_rejected=1\r\n");
    write("native_events=ok\r\n");
    const ipc_tasks = native_trap.exerciseNativeIpc() orelse {
        write("nihos: native IPC failed\r\n");
        return;
    };
    const ipc = ipc_tasks.ipc orelse return;
    writeU32("ipc_messages=", ipc.messages);
    writeU32("ipc_full_rejections=", ipc.full_rejections);
    writeU32("ipc_readable_waits=", ipc.readable_waits);
    writeU32("ipc_writable_waits=", ipc.writable_waits);
    writeU32("ipc_checksum=", ipc.checksum);
    writeU32("ipc_counters_wrapped=", @intFromBool(ipc.counters_wrapped));
    writeU32("ipc_syscalls=", ipc_tasks.calls);
    writeU32("ipc_timer_interrupts=", ipc_tasks.interrupts);
    writeU64("ipc_idle_runtime_ticks=", ipc_tasks.idle_runtime_ticks);
    writeU32("ipc_exit_code_0=", @bitCast(ipc_tasks.exits[0]));
    writeU32("ipc_exit_code_1=", @bitCast(ipc_tasks.exits[1]));
    writeU32("ipc_reaped=", ipc_tasks.reaped);
    write("native_ipc=ok\r\n");
    const remote_tasks = native_trap.exerciseNativeRemoteEvents() orelse {
        write("nihos: native remote events failed\r\n");
        return;
    };
    const remote = remote_tasks.remote orelse return;
    writeU32("remote_messages=", remote.messages);
    writeU32("remote_worker_cpu=", remote.worker_cpu);
    writeU32("remote_registered_waits=", remote.registered_waits);
    writeU32("remote_ipi_interrupts=", remote.ipi_interrupts);
    writeU32("remote_delivered=", remote.delivered);
    writeU32("remote_rejected=", remote.rejected);
    writeU32("remote_woken=", remote.woken);
    writeU32("remote_checksum=", remote.checksum);
    writeU32("remote_syscalls=", remote_tasks.calls);
    writeU32("remote_timer_interrupts=", remote_tasks.interrupts);
    writeU32("remote_exit_code_0=", @bitCast(remote_tasks.exits[0]));
    writeU32("remote_exit_code_1=", @bitCast(remote_tasks.exits[1]));
    writeU32("remote_reaped=", remote_tasks.reaped);
    write("remote_host_scheduler_restored=1\r\n");
    write("native_remote_events=ok\r\n");
    // Reusing the IDF timer after the native leases checks cleanup and that
    // the restored IDF vector/threshold/interrupt mask delivers callbacks.
    if (!exerciseTimer()) {
        write("nihos: timer restoration failed\r\n");
        return;
    }
    write("timer_restoration=ok\r\n");
    write("native_timer=ok\r\n");
    write("nihos: core smoke complete\r\n");

    if (!exerciseDma()) {
        write("nihos: AXI-GDMA copy failed\r\n");
        return;
    }
    write("axi_gdma_copy=ok\r\n");

    if (!exerciseDisplay()) {
        write("nihos: display scanout or vsync failed\r\n");
        return;
    }
    write("display_scanout=ok\r\n");
    write("display_vsync=ok\r\n");

    if (!exerciseTouch()) {
        write("nihos: touch initialization or sampling failed\r\n");
        return;
    }
    write("touch_sampling=ok\r\n");
    write("nihos: bootstrap complete\r\n");
}
