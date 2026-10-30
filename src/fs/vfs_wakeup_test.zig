//! Host interleavings of actual RPC queues, resident latch and kernel policy.
//! No instruction execution, MMIO/IPI delivery, weak-memory or DMA claim.
const std = @import("std");
const rpc = @import("vfs_rpc.zig");
const event = @import("../kernel/event_latch.zig");
const scheduler = @import("../kernel/scheduler.zig");
const call = @import("../kernel/task_control.zig");
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const Policy = scheduler.Scheduler(2, 2);
const Mode = enum { request, reply, credit };
const Backend = struct {
    stopped: ?*Policy = null,
    client: scheduler.TaskHandle = .{ .slot = 0, .generation = 0 },
    notifications: ?*rpc.Notifications = null,
    closes: u32 = 0,
    pub fn lookupBeneath(_: *@This(), _: u64, _: []const u8) rpc.api.Error!u64 {
        return 7;
    }
    pub fn open(_: *@This(), _: u64, _: rpc.api.Rights) rpc.api.Error!u64 {
        return 9;
    }
    pub fn close(self: *@This(), _: u64) rpc.api.Error!void {
        self.closes += 1;
    }
    pub fn readAt(self: *@This(), _: u64, _: u64, output: []u8) rpc.api.Transfer {
        @memset(output, 0x42);
        if (self.stopped) |policy| {
            std.debug.assert(policy.terminate(self.client, -98));
            // The runtime hook is authorized only AFTER the kernel stop.
            std.debug.assert(self.notifications.?.notifyExit(call.encodeHandle(self.client), 1));
            // A delayed IPI may never revive this exact stopped generation.
            std.debug.assert(policy.notify(self.client, 1) == null);
        }
        return .{ .transferred = output.len };
    }
    pub fn writeAt(_: *@This(), _: u64, _: u64, _: []const u8) rpc.api.Transfer {
        unreachable;
    }
    pub fn syncFile(_: *@This(), _: u64) rpc.api.Error!void {
        unreachable;
    }
    pub fn syncVolume(_: *@This(), _: u64) rpc.api.Error!void {
        unreachable;
    }
};
const Service = rpc.Owner(Backend);

fn progress(mode: Mode, service: *Service, queues: *rpc.Queues, frame: *rpc.Response) bool {
    return if (mode == .reply) queues.responses.tryPopInto(frame) else service.step(queues);
}

// Enumerate all 10 merges of publish -> latch -> IRQ and check -> wait.
// This includes the check-to-wait gap and IRQ delivery before wait registers.
fn interleave(mode: Mode, check_at: usize, wait_at: usize, forward_irq: bool) !bool {
    var policy = Policy{};
    const receiver = policy.add(0).?;
    _ = policy.add(1).?;
    try equal(receiver, policy.schedule().?);
    var latch = event.Latch{};
    var notifications = rpc.Notifications{};
    var backend = Backend{};
    var service = Service{ .notifications = &notifications, .client = call.encodeHandle(receiver) };
    var queues = rpc.Queues{};
    const root = try service.start(&backend);
    var request = rpc.Request{ .epoch = 1, .sequence = 1, .operation = 3, .token = root, .path_length = 1 };
    request.path[0] = 'a';
    var response = rpc.Response{};
    if (mode != .request) try expect(service.submit(&queues, service.client, &request));
    if (mode == .credit) {
        try expect(queues.responses.tryPushFrom(&response));
        try expect(queues.responses.tryPushFrom(&response));
    }
    var stage: usize = 0;
    var handled = false;
    var waiting = false;
    for (0..5) |at| {
        if (at == check_at) {
            handled = progress(mode, &service, &queues, &response);
        } else if (at == wait_at) {
            if (!handled) {
                const reply = call.dispatch(&policy, @backingInt(call.Number.wait_events), 1);
                try equal(@as(u32, 0), reply.high);
                try equal(@as(u32, if (reply.reschedule) 0 else 1), reply.low);
                waiting = reply.reschedule;
            }
        } else {
            switch (stage) {
                0 => switch (mode) {
                    .request => try expect(service.submit(&queues, service.client, &request)),
                    .reply => try expect(service.step(&queues)),
                    .credit => try expect(queues.responses.tryPopInto(&response)),
                },
                1 => latch.notify(),
                2 => {
                    const bits = latch.take();
                    try equal(@as(u32, 1), bits);
                    if (forward_irq) _ = policy.notify(receiver, bits).?;
                },
                else => unreachable,
            }
            stage += 1;
        }
    }
    if (waiting) {
        if (policy.snapshot(receiver).?.state == .waiting) return false;
        try equal(receiver, policy.schedule().?);
        try equal(@as(?u32, 1), policy.takeEventResult(receiver));
        try expect(policy.takeEventResult(receiver) == null);
    }
    if (!handled) try expect(progress(mode, &service, &queues, &response));
    if (mode == .reply) try expect(rpc.responseMatches(&response, 1, 1));
    try expect(notifications.notifyExit(service.client, 1));
    try expect(service.step(&queues));
    try service.shutdown(&queues);
    return true;
}

test "RPC request reply and response credit cannot lose a check-to-wait wakeup" {
    var cases: usize = 0;
    for ([_]Mode{ .request, .reply, .credit }) |mode| {
        for (0..4) |check_at| for (check_at + 1..5) |wait_at| {
            try expect(try interleave(mode, check_at, wait_at, true));
            cases += 1;
        };
    }
    try equal(@as(usize, 30), cases);
}

test "omitting the IRQ-to-kernel notification reproduces a lost wakeup" {
    for ([_]Mode{ .request, .reply, .credit }) |mode|
        try expect(!try interleave(mode, 0, 4, false));
}

test "coalesced doorbells preserve both queued requests across a registered wait" {
    var policy = Policy{};
    const receiver = policy.add(0).?;
    _ = policy.add(1).?;
    try equal(receiver, policy.schedule().?);
    const reply = call.dispatch(&policy, @backingInt(call.Number.wait_events), 1);
    try expect(reply.reschedule);
    var latch = event.Latch{};
    var notifications = rpc.Notifications{};
    var backend = Backend{};
    var service = Service{ .notifications = &notifications, .client = call.encodeHandle(receiver) };
    var queues = rpc.Queues{};
    const root = try service.start(&backend);
    var request = rpc.Request{ .epoch = 1, .sequence = 1, .operation = 3, .token = root, .path_length = 1 };
    request.path[0] = 'a';
    try expect(service.submit(&queues, service.client, &request));
    latch.notify();
    request.sequence = 2;
    try expect(service.submit(&queues, service.client, &request));
    latch.notify();
    try expect(policy.notify(receiver, latch.take()).?);
    try equal(@as(u32, 0), latch.take());
    try equal(receiver, policy.schedule().?);
    try equal(@as(?u32, 1), policy.takeEventResult(receiver));
    try expect(service.step(&queues));
    try expect(service.step(&queues));
    try equal(@as(usize, 0), queues.requests.countApprox());
    try equal(@as(usize, 2), queues.responses.countApprox());
    try expect(notifications.notifyExit(service.client, 1));
    try expect(service.step(&queues));
    try service.shutdown(&queues);
}

test "real kernel termination during dispatch drains RPC before generation reuse" {
    for (0..3) |stop_state| {
        var policy = Policy{};
        const client = policy.add(0).?;
        _ = policy.add(1).?;
        try equal(client, policy.schedule().?);
        var notifications = rpc.Notifications{};
        var backend = Backend{ .stopped = &policy, .client = client, .notifications = &notifications };
        var service = Service{ .notifications = &notifications, .client = call.encodeHandle(client) };
        var queues = rpc.Queues{};
        const root = try service.start(&backend);
        var request = rpc.Request{ .epoch = 1, .sequence = 1, .operation = 3, .token = root, .path_length = 1 };
        request.path[0] = 'a';
        try expect(service.submit(&queues, service.client, &request) and service.step(&queues));
        var response = rpc.Response{};
        try expect(queues.responses.tryPopInto(&response));
        const old_file = response.token;
        request = .{ .epoch = 1, .sequence = 2, .operation = 4, .token = old_file, .length = 4096 };
        try expect(service.submit(&queues, service.client, &request));
        request.sequence = 3;
        try expect(service.submit(&queues, service.client, &request));
        if (stop_state != 0) {
            const wait_reply = call.dispatch(&policy, @backingInt(call.Number.wait_events), 1);
            try expect(wait_reply.reschedule);
            if (stop_state == 2) try expect(policy.notify(client, 1).?);
        }
        try expect(service.step(&queues));
        try equal(scheduler.TaskState.exited, policy.snapshot(client).?.state);
        try equal(@as(i32, -98), policy.snapshot(client).?.exit_code);
        try expect(policy.takeEventResult(client) == null);
        try expect(!service.alive and service.rebind_ready);
        try equal(@as(u32, 1), service.discarded_requests);
        try equal(@as(u32, 1), service.discarded_responses);
        try equal(@as(u32, 1), backend.closes);
        try expect(policy.remove(client));
        const replacement = policy.add(0).?;
        try equal(client.slot, replacement.slot);
        try expect(client.generation != replacement.generation);
        try expect(service.rebind(&queues, call.encodeHandle(replacement)));
        try expect(policy.notify(client, 1) == null);
        try expect(!notifications.notifyExit(call.encodeHandle(client), 1));
        request.epoch = 2;
        request.sequence = 1;
        request.token = old_file;
        try expect(service.submit(&queues, service.client, &request) and service.step(&queues));
        try expect(queues.responses.tryPopInto(&response));
        try equal(@as(i32, -9), response.status);
        try expect(notifications.notifyExit(service.client, 2));
        try expect(service.step(&queues));
        try service.shutdown(&queues);
    }
}

// MMIO doorbell is modeled as a sticky pending bit. The current IRQ tail
// acknowledges it BEFORE exchanging the latch. A notification already in
// flight can otherwise be cleared after a new producer rings the same bell.
fn bellInterleave(signal_at: usize, bell_at: usize, ack_first: bool) !bool {
    var policy = Policy{};
    const receiver = policy.add(0).?;
    _ = policy.add(1).?;
    try equal(receiver, policy.schedule().?);
    try expect(call.dispatch(&policy, @backingInt(call.Number.wait_events), 1).reschedule);
    var latch = event.Latch{};
    var hardware_pending = true; // An earlier coalesced interrupt is in flight.
    var irq_stage: usize = 0;
    for (0..4) |at| {
        if (at == signal_at) {
            latch.notify(); // Queue publication is already complete.
        } else if (at == bell_at) {
            hardware_pending = true;
        } else {
            if ((irq_stage == 0) == ack_first) {
                hardware_pending = false;
            } else {
                const bits = latch.take();
                if (bits != 0) _ = policy.notify(receiver, bits).?;
            }
            irq_stage += 1;
        }
    }
    if (hardware_pending) {
        hardware_pending = false;
        const bits = latch.take();
        if (bits != 0) _ = policy.notify(receiver, bits).?;
    }
    return policy.snapshot(receiver).?.state != .waiting;
}

test "acknowledging before latch exchange preserves a concurrently coalesced IPI" {
    var cases: usize = 0;
    var reversed_loses: usize = 0;
    for (0..3) |signal_at| for (signal_at + 1..4) |bell_at| {
        try expect(try bellInterleave(signal_at, bell_at, true));
        if (!try bellInterleave(signal_at, bell_at, false)) reversed_loses += 1;
        cases += 1;
    };
    try equal(@as(usize, 6), cases);
    try equal(@as(usize, 1), reversed_loses);
}
