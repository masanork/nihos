//! Compile-only service ownership/queue layout; external functions are not drivers.
const api = @import("checkpoint_service");
const model = api.model;
const timer_group = @import("timer_group");
extern fn service_media_read(offset: u64, bytes: [*]u8, length: usize) c_int;
extern fn service_media_write(offset: u64, bytes: [*]const u8, length: usize) c_int;
extern fn service_media_sync() c_int;
const Device = struct {
    pub const capacity: u64 = 16 * 1024 * 1024 * 1024;
    pub fn read(_: *@This(), offset: u64, bytes: []u8) error{Io}!void {
        if (service_media_read(offset, bytes.ptr, bytes.len) != 0) return error.Io;
    }
    pub fn write(_: *@This(), offset: u64, bytes: []const u8) error{Io}!void {
        if (service_media_write(offset, bytes.ptr, bytes.len) != 0) return error.Io;
    }
    pub fn sync(_: *@This()) error{Io}!void {
        if (service_media_sync() != 0) return error.Io;
    }
};
const Store = model.Store(Device, .{ .leaf_cache_pages = 128 });
const Owner = api.Owner(Store);
const Queues = api.Queues(@import("spsc_ring"));
const Gate = api.dispatch_gate.Gate(Store, Owner, Queues);
const Readers = api.lifetime_budget.Readers(Store);
var store = Store{};
var device = Device{};
var queues = Queues{};
var owner = Owner{ .store = &store, .client = 11, .last_durable_generation = 0 };
// SAFETY: the exports check gate_initialized before using the coordinator.
var gate: Gate = undefined;
var gate_initialized = false;
var readers: ?Readers = null;
var operation_budget: ?api.lifetime_budget.Operation = null;
var reader_drain: api.reader_drain.Drain = .{};
var deadline: ?api.deadline.Deadline = null;
var lease_clock: ?api.deadline.Clock = null;
pub export const service_lease_clock_bytes: u32 = @sizeOf(api.deadline.Clock);
pub export fn service_lease_clock_init(sample_us: u64) c_int {
    if (!reader_drain.canRelease()) return -1;
    if (readers) |book| for (book.entries) |entry| {
        if (entry.state != .empty) return -1;
    };
    lease_clock = api.deadline.Clock.init(sample_us) catch return -1;
    return 0;
}
pub export fn service_lease_clock_ms(sample_us: u64, valid: bool, now_ms: *u64) c_int {
    now_ms.* = 0;
    if (lease_clock) |*clock| {
        now_ms.* = clock.milliseconds(if (valid) sample_us else null) catch {
            if (readers) |*book| book.failClock();
            if (!reader_drain.canRelease()) reader_drain.requestStop(reader_drain.worker, reader_drain.generation) catch return -1;
            return -1;
        };
        return 0;
    }
    return -1;
}
pub export const service_deadline_bytes: u32 = @sizeOf(api.deadline.Deadline);
pub export fn service_deadline_init(sample_us: u64, duration_us: u64) c_int {
    deadline = api.deadline.Deadline.init(sample_us, duration_us) catch return -1;
    return 0;
}
pub export fn service_deadline_poll(sample_us: u64, valid: bool) c_int {
    if (deadline) |*value| return @backingInt(value.poll(if (valid) sample_us else null));
    return -1;
}
/// Compile-only example. Caller leases/serializes an already clocked 1 MHz
/// count-up channel; this does not acquire it or configure its clock tree.
pub export fn service_deadline_timer_poll(group_address: u32, channel_id: u32) c_int {
    if (deadline) |*value| {
        const timer = timer_group.Timer.fromGroup(group_address, channel_id) orelse return @backingInt(value.poll(null));
        const config = timer.channel.config;
        const valid = config & (timer_group.counter_enable | timer_group.count_up) == (timer_group.counter_enable | timer_group.count_up) and config & timer_group.auto_reload == 0;
        return @backingInt(value.poll(if (valid) timer.counter() else null));
    }
    return -1;
}
comptime {
    if (@sizeOf(usize) != 4 or @sizeOf(Store) + @sizeOf(Owner) + @sizeOf(Queues) > 2 * 1024 * 1024) @compileError("service envelope exceeds its RV32 budget");
}
pub export const service_store_bytes: u32 = @sizeOf(Store);
pub export const service_owner_bytes: u32 = @sizeOf(Owner);
pub export const service_queues_bytes: u32 = @sizeOf(Queues);
pub export const service_request_bytes: u32 = @sizeOf(api.Request);
pub export const service_response_bytes: u32 = @sizeOf(api.Response);
pub export const service_protected_index_upper_bound: u32 = Store.max_protected_index_pages;
pub export const service_dispatch_gate_bytes: u32 = @sizeOf(Gate);
pub export const service_reader_budget_bytes: u32 = @sizeOf(Readers);
pub export const service_operation_budget_bytes: u32 = @sizeOf(api.lifetime_budget.Operation);
pub export const service_reader_drain_bytes: u32 = @sizeOf(api.reader_drain.Drain);
pub export fn service_drain_begin(worker: u64, generation: *u64) c_int {
    generation.* = reader_drain.begin(worker) catch return -1;
    return 0;
}
pub export fn service_drain_enter(worker: u64, generation: u64, slot: *u8, token: *u64) c_int {
    const ticket = reader_drain.enter(worker, generation) catch return -1;
    slot.* = ticket.slot;
    token.* = ticket.token;
    return 0;
}
pub export fn service_drain_complete(worker: u64, generation: u64, slot: u8, token: u64) c_int {
    reader_drain.complete(worker, generation, .{ .slot = slot, .token = token }) catch return -1;
    return 0;
}
pub export fn service_drain_stop(worker: u64, generation: u64) c_int {
    reader_drain.requestStop(worker, generation) catch return -1;
    return 0;
}
pub export fn service_drain_ack(worker: u64, generation: u64, clean: bool) c_int {
    return @intFromBool(reader_drain.acknowledgeStopped(worker, generation, clean) catch return -1);
}
pub export fn service_drain_finish(worker: u64, generation: u64) c_int {
    reader_drain.finish(worker, generation) catch return -1;
    return @intFromBool(reader_drain.canRelease());
}
pub export fn service_reader_init(limit_bytes: u64, now_ms: u64) c_int {
    readers = Readers.init(&store, limit_bytes, now_ms) catch return -1;
    return 0;
}
pub export fn service_reader_begin(actor: u64, now_ms: u64, duration_ms: u64, limit_bytes: u64, result: *model.Reader) c_int {
    if (readers) |*book| {
        result.* = book.begin(actor, now_ms, duration_ms, limit_bytes) catch return -1;
        return 0;
    }
    return -1;
}
pub export fn service_reader_begin_object(actor: u64, key: u32, now_ms: u64, duration_ms: u64, limit_bytes: u64, result: *model.Reader) c_int {
    if (readers) |*book| {
        result.* = book.beginObject(actor, key, now_ms, duration_ms, limit_bytes) catch return -1;
        return 0;
    }
    return -1;
}
pub export fn service_reader_step(actor: u64, reader: *const model.Reader, now_ms: u64) c_int {
    if (readers) |*book| return @intFromBool(book.step(actor, reader.*, now_ms, 8) catch return -1);
    return -1;
}
pub export fn service_reader_poll(now_ms: u64) c_int {
    if (readers) |*book| {
        book.poll(now_ms) catch return -1;
        return 0;
    }
    return -1;
}
pub export fn service_reader_read(actor: u64, reader: *const model.Reader, key: u32, offset: u64, bytes: [*]u8, length: usize, now_ms: u64) c_int {
    if (readers) |*book| return @intCast(book.read(actor, reader.*, key, offset, bytes[0..length], now_ms) catch return -1);
    return -1;
}
pub export fn service_reader_stopped(actor: u64, reader: *const model.Reader) c_int {
    if (readers) |*book| {
        book.requestStop(actor, reader.*) catch return -1;
        book.stopped(actor, reader.*) catch return -1;
        return 0;
    }
    return -1;
}
pub export fn service_budget_init(span: u64, duration_ms: u64, now_ms: u64) c_int {
    operation_budget = api.lifetime_budget.Operation.init(.{ .journal_span_bytes = span, .duration_ms = duration_ms }, now_ms) catch return -1;
    return 0;
}
pub export fn service_budget_journal(end: u64) c_int {
    if (operation_budget) |*operation| return @intFromBool(operation.journalWrite(end));
    return -1;
}
pub export fn service_budget_poll(now_ms: u64) c_int {
    if (operation_budget) |*operation| return @backingInt(operation.poll(now_ms));
    return -1;
}
pub export fn service_format() c_int {
    store.format(&device) catch return -1;
    owner = Owner.init(&store, 11) catch return -1;
    return 0;
}
pub export fn service_recover() c_int {
    store.recover(&device) catch return -1;
    owner = Owner.init(&store, 11) catch return -1;
    return 0;
}
pub export fn service_grant(key: u32, writable: bool, handle: *api.Handle) c_int {
    handle.* = owner.grant(key, writable) catch return -1;
    return 0;
}
pub export fn service_submit(request: *const api.Request) c_int {
    return if (queues.requests.tryPush(request.*)) 0 else -1;
}
pub export fn service_step() c_int {
    return @backingInt(owner.step(&queues, .{}));
}
pub export fn service_reply(reply: *api.Response) c_int {
    reply.* = queues.responses.tryPop() orelse return -1;
    return 0;
}
pub export fn service_exit(client: u64) c_int {
    return @backingInt(owner.clientExited(client, &queues) catch return -1);
}
pub export fn service_rebind(client: u64) c_int {
    return if (owner.rebind(client, &queues)) 0 else -1;
}
pub export fn service_admission(payload_pages: u64, index_pages: u32) c_int {
    if (owner.pending) return -1;
    owner.payload_headroom = payload_pages;
    owner.index_headroom = index_pages;
    return 0;
}
pub export fn service_retire_previous() c_int {
    _ = owner.retirePrevious(&queues) catch return -1;
    return 0;
}
pub export fn service_gate_init(epoch: u64) c_int {
    if (gate_initialized) return -1;
    gate = Gate.init(&owner, &queues, epoch, 2) catch return -1;
    gate_initialized = true;
    return 0;
}
pub export fn service_gate_recovered() c_int {
    if (!gate_initialized) return -1;
    gate.recoveryComplete() catch return -1;
    return 0;
}
pub export fn service_gate_submit(actor: u64, operation: u64, ticket: *api.dispatch_gate.Ticket) c_int {
    if (!gate_initialized) return -1;
    ticket.* = gate.submit(actor, operation) catch return -1;
    return 0;
}
pub export fn service_gate_take(worker: u64, intent: *api.dispatch_gate.Intent) c_int {
    if (!gate_initialized) return -1;
    intent.* = (gate.take(worker) catch return -1) orelse return -1;
    return 0;
}
pub export fn service_gate_cancel(actor: u64, epoch: u64, sequence: u64) c_int {
    if (!gate_initialized) return -1;
    return @backingInt(gate.cancel(actor, .{ .epoch = epoch, .sequence = sequence }));
}
pub export fn service_gate_finish(actor: u64, epoch: u64, sequence: u64) c_int {
    if (!gate_initialized) return -1;
    return @backingInt(gate.finish(actor, .{ .epoch = epoch, .sequence = sequence }) catch return -1);
}
pub export fn service_gate_gc() c_int {
    if (!gate_initialized) return -1;
    gate.requestMaintenance() catch return -1;
    _ = gate.stepMaintenance() catch return -1;
    return 0;
}
