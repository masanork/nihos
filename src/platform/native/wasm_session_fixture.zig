//! Same common Session as native; actual WAMR renders on its leased task stack.
const app = @import("wasm_session.zig");
const options = @import("native_options");
const tasks = @import("native_tasks");
const console = @import("text_console");
const ui = @import("display_service").ui;
const clock = @import("timer_group").Timer.fromGroup(0x500c2000, 0).?;
extern fn nih_rom_rx_one_char(*u8) callconv(.c) i32;
var began: u64 = 0;
var free_before: usize = 0;
var charged: usize = 0;
var ticks: [2]u32 = .{ 0, 0 };
var presentations: u32 = 0;
var selected: u32 = 0;
var received: u32 = 0;
var rejected: u32 = 0;
var input_frames: u32 = 0;
var ended = false;
var result: i32 = 0;
var round: u32 = 0;
var auto_index: usize = 0;
var fail_present = false;
var previous_generation: u32 = 0;
pub var async_turns: u32 = 0;
pub var async_begin_us: u32 = 0;
var interactive_active = false;
var interactive_opening = false;
var interactive_free: usize = 0;
pub var interactive_round: u32 = 0;
pub var interactive_signature: u32 = 0;
pub var interactive_frames: u32 = 0;
var interactive_last_generation: u32 = 0;
var interactive_start_ticks: [2]u32 = .{ 0, 0 };
pub var foreground_open: u32 = 0;
pub var foreground_cancel: u32 = 0;
pub var foreground_active: u32 = 0;
pub var foreground_max_gap: u32 = 0;
pub var mock_items: u32 = 0;
pub var mock_digest: u32 = 2166136261;
pub var mock_sensor_sum: u32 = 0;
var foreground_previous: u64 = 0;
const hosted_station = @import("hosted_station");
const hosted_wire = hosted_station.wire;
var fixture_station: if (options.wasm_interactive_repeat) hosted_station.Client else void = if (options.wasm_interactive_repeat) .{} else {};
pub var station_completed: u32 = 0;
pub var station_stale: u32 = 0;
pub var station_errors: u32 = 0;
pub var station_opening: u32 = 0;
pub var station_cancelling: u32 = 0;
pub var station_active: u32 = 0;
// One deterministic station step per foreground turn. The synthetic peer
// returns a wrong-UID version reply before the matching response.
fn stationService() void {
    const step = (mock_items - 1) % 5;
    if (step == 0) {
        fixture_station.begin(.disabled, 0);
        // Model a prior transaction so the stale UID is nonzero and valid.
        fixture_station.uid = 1;
        fixture_station.receive(.{ .interface = 5, .payload = &.{ 0x22, 3, 0x12, 1, 13 } }, 1) catch {
            station_errors += 1;
            return;
        };
        if (!fixture_station.capabilities_pending or fixture_station.phase != .handshake) station_errors += 1;
    } else if (step == 1) {
        const bytes = fixture_station.tx(2) catch {
            station_errors += 1;
            return;
        };
        if (bytes.len <= 12 or bytes[0] != 5) {
            station_errors += 1;
            return;
        }
        fixture_station.sent(2);
        if (fixture_station.phase != .version) station_errors += 1;
    } else if (step == 2) {
        const bytes = fixture_station.tx(3) catch {
            station_errors += 1;
            return;
        };
        if (bytes.len <= 12 or bytes[0] != 3 or fixture_station.active_id != 350) {
            station_errors += 1;
            return;
        }
        fixture_station.sent(3);
    } else {
        var body_buffer: [32]u8 = undefined;
        var body = hosted_wire.Writer{ .out = &body_buffer };
        body.uint(2, 1) catch {
            station_errors += 1;
            return;
        };
        body.uint(3, 4) catch {
            station_errors += 1;
            return;
        };
        body.uint(4, 1) catch {
            station_errors += 1;
            return;
        };
        var payload: [128]u8 = undefined;
        const uid = fixture_station.uid - @as(u32, @intFromBool(step == 3));
        const response = hosted_wire.request(&payload, 606, uid, body.slice()) catch {
            station_errors += 1;
            return;
        };
        payload[13] = 2;
        fixture_station.receive(.{ .interface = 3, .payload = response }, 4) catch {
            station_errors += 1;
            return;
        };
        if (step == 3) {
            if (fixture_station.phase != .version or fixture_station.ignored_rpcs != 1 or fixture_station.version_known) {
                station_errors += 1;
                return;
            }
            station_stale += 1;
        } else {
            const pending = fixture_station.tx(5) catch {
                station_errors += 1;
                return;
            };
            if (fixture_station.phase != .done or !fixture_station.version_known or
                !@import("std").mem.eql(u32, &fixture_station.version, &.{ 1, 4, 1 }) or fixture_station.ignored_rpcs != 1 or
                fixture_station.dhcp_client != null or fixture_station.connected or pending.len != 0)
            {
                station_errors += 1;
                return;
            }
            station_completed += 1;
            switch (ui.wasmFixturePhase()) {
                1 => station_opening += 1,
                2 => station_cancelling += 1,
                3 => station_active += 1,
                else => station_errors += 1,
            }
        }
    }
}
var fixture_decoder: if (options.wasm_interactive_repeat) hosted_wire.Decoder else void = if (options.wasm_interactive_repeat) .{} else {};
pub var network_accepted: u32 = 0;
pub var network_rejected: u32 = 0;
pub var network_errors: u32 = 0;
pub var network_active_events: u32 = 0;
// A valid ESP-Hosted frame and a one-byte-corrupted variant, each fed in
// two foreground turns. This exercises the real decoder with synthetic input.
fn hostedService() void {
    const good = [_]u8{ 0x01, 0x00, 0x04, 0x00, 0x0c, 0x00, 0x23, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x12, 0x00, 0xff };
    const segment = (mock_items - 1) % 4;
    const bad = segment >= 2;
    const offset: usize = @intCast((segment % 2) * 8);
    for (0..8) |i| {
        const pos = offset + i;
        const byte = if (bad and pos == 15) good[pos] ^ 1 else good[pos];
        const maybe = fixture_decoder.push(byte) catch |err| {
            if (bad and pos == 15 and err == error.Checksum) {
                network_rejected += 1;
                if (ui.wasmFixturePhase() == 3) network_active_events += 1;
            } else network_errors += 1;
            fixture_decoder = .{};
            continue;
        };
        if (maybe) |frame| {
            if (bad or pos != 15 or frame.interface != 1 or !@import("std").mem.eql(u8, frame.payload, &.{ 1, 0x12, 0, 0xff })) {
                network_errors += 1;
            } else {
                network_accepted += 1;
                if (ui.wasmFixturePhase() == 3) network_active_events += 1;
            }
        }
    }
}
// Bounded deterministic work, not a camera, network, or storage driver.
fn mockService() void {
    mock_items += 1;
    hostedService();
    stationService();
    for (0..64) |index| {
        const byte: u8 = @truncate(mock_items *% 17 +% @as(u32, @intCast(index)) *% 29 +% interactive_round *% 7);
        mock_digest = (mock_digest ^ byte) *% 16777619;
    }
    for (0..16) |index| {
        const sample = (mock_items *% 31 +% @as(u32, @intCast(index)) *% 7 +% interactive_round *% 11) & 1023;
        mock_sensor_sum +%= sample;
    }
}
// Called once per normalReady loop after network/storage service entry and
// before UI service. Those real services are disabled in this test profile.
pub fn foregroundProbe() void {
    const now = clock.counter() orelse return;
    if (interactive_opening and foreground_previous != 0) {
        foreground_max_gap = @max(foreground_max_gap, @as(u32, @intCast(@min(now -| foreground_previous, 0xffffffff))));
    }
    foreground_previous = now;
    if (!interactive_opening) return;
    mockService();
    switch (ui.wasmFixturePhase()) {
        1 => foreground_open += 1,
        2 => foreground_cancel += 1,
        3 => foreground_active += 1,
        else => {},
    }
}
pub fn foregroundAfterUi() void {
    const now = clock.counter() orelse return;
    if (interactive_opening and foreground_previous != 0) {
        foreground_max_gap = @max(foreground_max_gap, @as(u32, @intCast(@min(now -| foreground_previous, 0xffffffff))));
    }
}

fn interactiveFinish(cancelled: bool) bool {
    if (app.active() or app.observed.reaped != 1 or app.observed.recovered != 1 or
        app.observed.wiped != @intFromBool(!cancelled) or app.observed.detached != 1 or app.observed.guards != 1 or
        !ui.wasmFixtureDirty() or app.observed.generation <= interactive_last_generation or
        (tasks.memory.reusable.localUsage() orelse return false).free != interactive_free or
        tasks.report(0).ticks == interactive_start_ticks[0] or tasks.report(1).ticks == interactive_start_ticks[1]) return false;
    interactive_last_generation = app.observed.generation;
    interactive_frames = presentations;
    interactive_active = false;
    interactive_opening = false;
    presentations = 0;
    return true;
}
pub fn interactiveBegin(log: anytype) bool {
    interactive_free = (tasks.memory.reusable.localUsage() orelse return false).free;
    presentations = 0;
    fail_present = false;
    app.setFault(0);
    ui.wasmFixtureSetPresenter(&present);
    ui.wasmInteractiveBegin(log);
    return true;
}
// 0=waiting, 1=active, 2=completed, 3=invalid, 4=cancelled, 5=opening.
pub fn interactiveService(log: anytype) u32 {
    if (!options.wasm_interactive_repeat) ui.wasmInteractivePoll(log);
    if (app.active() and !interactive_active) {
        interactive_active = true;
        return 1;
    }
    if (ui.wasmFixtureReserved() and !interactive_opening) {
        interactive_opening = true;
        if (options.wasm_interactive_repeat) {
            interactive_round += 1;
            interactive_signature = 0;
            interactive_frames = 0;
            foreground_open = 0;
            foreground_cancel = 0;
            foreground_active = 0;
            foreground_max_gap = 0;
            foreground_previous = 0;
            mock_items = 0;
            mock_digest = 2166136261;
            mock_sensor_sum = 0;
            fixture_decoder = .{};
            network_accepted = 0;
            network_rejected = 0;
            network_errors = 0;
            network_active_events = 0;
            fixture_station = .{};
            station_completed = 0;
            station_stale = 0;
            station_errors = 0;
            station_opening = 0;
            station_cancelling = 0;
            station_active = 0;
            interactive_start_ticks = .{ tasks.report(0).ticks, tasks.report(1).ticks };
            ui.wasmFixtureClearDirty();
        }
        return 5;
    }
    if (interactive_opening and !interactive_active and !ui.wasmFixtureReserved()) {
        if (options.wasm_interactive_repeat) return if (presentations == 0 and interactiveFinish(true)) 4 else 3;
        if (app.active() or presentations != 0 or !ui.wasmFixtureDirty() or
            app.observed.reaped != 1 or app.observed.recovered != 1 or
            (tasks.memory.reusable.localUsage() orelse return 3).free != interactive_free) return 3;
        return 4;
    }
    if (interactive_active and !ui.wasmFixtureReserved()) {
        if (options.wasm_interactive_repeat) return if (presentations > 0 and app.frames() == presentations and interactiveFinish(false)) 2 else 3;
        if (app.active() or app.frames() != 4 or presentations != 4 or selected != 0 or
            !ui.wasmFixtureDirty() or app.observed.reaped != 1 or app.observed.recovered != 1 or
            (tasks.memory.reusable.localUsage() orelse return 3).free != interactive_free) return 3;
        return 2;
    }
    return 0;
}

pub fn asyncProbe(log: anytype) bool {
    const before = (tasks.memory.reusable.localUsage() orelse return false).free;
    const start_ticks = .{ tasks.report(0).ticks, tasks.report(1).ticks };
    app.setFault(0);
    ui.wasmFixtureSetPresenter(&present);
    const initial_repaints = ui.wasmFixtureRepaints();
    if (ui.wasmFixtureStart(false, true, &present) != -3 or ui.wasmFixtureStart(true, false, &present) != -3) return false;
    if (!ui.wasmFixtureCameraStart() or ui.wasmFixtureShellStart(log) or
        (tasks.memory.reusable.localUsage() orelse return false).free != before) return false;
    ui.wasmFixtureCameraReset();
    const started = clock.counter() orelse return false;
    if (!ui.wasmFixtureShellStart(log) or !ui.wasmFixtureReserved() or app.start(&present) != -3) return false;
    ui.wasmFixtureShellKey(.{ .text = 'c' }, log);
    if (!ui.wasmFixtureReserved() or !ui.wasmFixtureCameraIdle()) return false;
    var serial: console.session.input.Serial = .{};
    const key = serial.feed('q', started) orelse return false;
    switch (key) {
        .text => |byte| if (byte != 'q') return false,
        else => return false,
    }
    ui.wasmFixtureShellKey(key, log);
    ui.wasmFixtureClearDirty();
    async_begin_us = @intCast((clock.counter() orelse return false) -| started);
    if ((tasks.memory.reusable.localUsage() orelse return false).free >= before) return false;
    var turns: u32 = 0;
    while (true) {
        turns += 1;
        const update = ui.wasmFixtureServiceUi();
        if (update == .stopped) break;
        if (update != .waiting or !ui.wasmFixtureReserved()) return false;
        tasks.idleOnce(0);
    }
    if (turns < 2 or !ui.wasmFixtureDirty() or ui.wasmFixtureRepaints() != initial_repaints + 1 or ui.wasmFixtureReserved() or app.active() or app.observed.reaped != 1 or app.observed.recovered != 1 or
        (tasks.memory.reusable.localUsage() orelse return false).free != before or
        tasks.report(0).ticks == start_ticks[0] or tasks.report(1).ticks == start_ticks[1]) return false;
    async_turns = turns;
    if (!ui.wasmFixtureShellStart(log)) return false;
    while (true) {
        const update = ui.wasmFixtureServiceUi();
        if (update == .started) break;
        if (update != .waiting or !ui.wasmFixtureReserved()) return false;
        tasks.idleOnce(0);
    }
    ui.wasmFixtureShellKey(.{ .text = '0' }, log);
    ui.wasmFixtureShellKey(.{ .text = '1' }, log);
    ui.wasmFixtureShellKey(.{ .text = '0' }, log);
    if (app.frames() != 4) return false;
    const repaints = ui.wasmFixtureRepaints();
    ui.wasmFixtureClearDirty();
    ui.wasmFixtureShellKey(.escape, log);
    if (!ui.wasmFixtureDirty() or ui.wasmFixtureRepaints() != repaints + 1 or ui.wasmFixtureReserved() or app.active() or
        (tasks.memory.reusable.localUsage() orelse return false).free != before) return false;
    app.setFault(1);
    if (app.beginAsync(&present) != 0) return false;
    while (true) {
        if (app.pollAsync()) |status| {
            if (status != -41) return false;
            break;
        }
        tasks.idleOnce(0);
    }
    if (app.pollAsync() != -41 or app.active() or app.observed.reaped != 1 or app.observed.recovered != 1 or
        (tasks.memory.reusable.localUsage() orelse return false).free != before) return false;
    app.setFault(3);
    if (app.beginAsync(&present) != 0) return false;
    while (true) {
        if (app.pollAsync()) |status| {
            if (status != -4) return false;
            break;
        }
        tasks.idleOnce(0);
    }
    if (app.pollAsync() != -4 or app.active() or app.observed.reaped != 1 or app.observed.recovered != 1 or
        (tasks.memory.reusable.localUsage() orelse return false).free != before) return false;
    app.setFault(5);
    if (app.beginAsync(&present) != 0 or !app.cancelAsync()) return false;
    while (true) {
        if (app.pollAsync()) |status| {
            if (status != -90) return false;
            break;
        }
        tasks.idleOnce(0);
    }
    if (app.pollAsync() != -90 or app.observed.reaped != 1 or app.observed.recovered != 1 or
        (tasks.memory.reusable.localUsage() orelse return false).free != before) return false;
    app.setFault(0);
    return true;
}

fn present(bytes: [*]const u8, len: u32) callconv(.c) i32 {
    if (fail_present) return -49;
    if (len != 25600) return -1;
    const pressed = bytes[0] == 0x0c;
    if (options.wasm_interactive_repeat) {
        if (presentations < 32 and pressed) interactive_signature |= @as(u32, 1) << @as(u5, @intCast(presentations));
    } else if (options.wasm_interactive) {
        const expected = [_]bool{ false, false, true, false };
        if (presentations >= expected.len or pressed != expected[presentations]) return -51;
    }
    const ready = [_][8]u8{
        .{ 0x3f, 0x66, 0x66, 0x3e, 0x36, 0x66, 0x67, 0 }, .{ 0, 0, 0x1e, 0x33, 0x3f, 0x03, 0x1e, 0 },
        .{ 0, 0, 0x1e, 0x30, 0x3e, 0x33, 0x6e, 0 },       .{ 0x38, 0x30, 0x30, 0x3e, 0x33, 0x33, 0x6e, 0 },
        .{ 0, 0, 0x33, 0x33, 0x33, 0x3e, 0x30, 0x1f },
    };
    const down = [_][8]u8{
        .{ 0x3f, 0x66, 0x66, 0x3e, 0x06, 0x06, 0x0f, 0 }, .{ 0, 0, 0x3b, 0x6e, 0x66, 0x06, 0x0f, 0 },
        .{ 0, 0, 0x1e, 0x33, 0x3f, 0x03, 0x1e, 0 },       .{ 0, 0, 0x3e, 0x03, 0x1e, 0x30, 0x1f, 0 },
        .{ 0, 0, 0x3e, 0x03, 0x1e, 0x30, 0x1f, 0 },       .{ 0, 0, 0x1e, 0x33, 0x3f, 0x03, 0x1e, 0 },
        .{ 0x38, 0x30, 0x30, 0x3e, 0x33, 0x33, 0x6e, 0 },
    };
    const glyphs: []const [8]u8 = if (pressed) &down else &ready;
    for (0..80) |y| for (0..160) |x| {
        var expected: u16 = if (pressed) 0x220c else 0x1082;
        if (y >= 8 and y < 16 and x >= 8 and (x - 8) / 8 < glyphs.len and
            glyphs[(x - 8) / 8][y - 8] & (@as(u8, 1) << @as(u3, @intCast((x - 8) % 8))) != 0) expected = 0xffff;
        const i = (y * 160 + x) * 2;
        if (bytes[i] != @as(u8, @truncate(expected)) or bytes[i + 1] != @as(u8, @truncate(expected >> 8))) return -50;
    };
    selected = @intFromBool(pressed);
    presentations += 1;
    return 0;
}
pub fn start() bool {
    round += 1;
    presentations = 0;
    received = 0;
    rejected = 0;
    input_frames = 0;
    auto_index = 0;
    ended = false;
    result = 0;
    fail_present = false;
    app.setFault(0);
    free_before = (tasks.memory.reusable.localUsage() orelse return false).free;
    ticks = .{ tasks.report(0).ticks, tasks.report(1).ticks };
    if (app.start(&present) != 0) return false;
    if (app.start(&present) != -3) return false;
    charged = free_before - (tasks.memory.reusable.localUsage() orelse return false).free;
    began = clock.counter() orelse return false;
    return true;
}
pub fn service(log: anytype) bool {
    const now = clock.counter() orelse return false;
    if (!ended) {
        var byte: u8 = 0;
        var available = false;
        if (round > 1 and auto_index < 5) {
            byte = "0x10q"[auto_index];
            auto_index += 1;
            available = true;
        } else available = nih_rom_rx_one_char(&byte) == 0;
        if (available) {
            received += 1;
            const before = app.frames();
            if (byte == 'c') {
                result = app.cancel();
                if (result == 0) result = -45;
            } else if (byte == 't' or byte == 'p') {
                if (byte == 't') app.setFault(2) else fail_present = true;
                result = app.input('1');
            } else {
                result = app.input(byte);
                if (byte == 'x') {
                    const valid = result == -1 and app.frames() == before;
                    rejected += 1;
                    result = if (valid) 0 else -44;
                } else if (byte == '0' or byte == '1') {
                    if (result != 0 or input_frames >= 3 or selected != ([_]u32{ 0, 1, 0 })[input_frames]) result = -44;
                    input_frames += 1;
                } else if (byte != 'q' or result != 0 or input_frames != 3 or rejected != 1) result = -44;
            }
            if (received > 16) result = -43;
        }
        if (now - began > 500_000) result = -42;
        if (result != 0 or !app.active()) {
            _ = app.cancel();
            ended = true;
        }
        return true;
    }
    const free_after = (tasks.memory.reusable.localUsage() orelse return false).free;
    const m = app.observed;
    const Record = extern struct {
        round: u32,
        status: u32,
        bytes: u32,
        frames: u32,
        presentations: u32,
        rejected: u32,
        requested: u32,
        charged: u32,
        recovered: u32,
        reaped: u32,
        wiped: u32,
        detached: u32,
        guards: u32,
        stack_used: u32,
        captures: u32,
        timers: u32,
        waits: u32,
        calls: u32,
        denied: u32,
        generation: u32,
        ticks0: u32,
        ticks1: u32,
        open_us: u32,
        render_max_us: u32,
        close_us: u32,
    };
    const record: Record = .{ .round = round, .status = @bitCast(result), .bytes = received, .frames = input_frames, .presentations = presentations, .rejected = rejected, .requested = 499712 + 32768, .charged = @intCast(charged), .recovered = @intFromBool(m.recovered == 1 and free_before == free_after), .reaped = m.reaped, .wiped = m.wiped, .detached = m.detached, .guards = m.guards, .stack_used = m.stack_used, .captures = m.captures, .timers = m.timers, .waits = m.waits, .calls = m.calls, .denied = m.denied, .generation = m.generation, .ticks0 = tasks.report(0).ticks -% ticks[0], .ticks1 = tasks.report(1).ticks -% ticks[1], .open_us = m.open_us, .render_max_us = m.render_max_us, .close_us = m.close_us };
    log.record("NIHOS_WASM_SESSION", null, .{ "round", "status", "bytes", "frames", "presentations", "rejected", "requested", "charged", "recovered", "reaped", "wiped", "detached", "guards", "stack_used", "captures", "timers", "waits", "calls", "denied", "generation", "ticks0", "ticks1", "open_us", "render_max_us", "close_us" }, &record);
    if (round == 2) return false;
    previous_generation = m.generation;
    // Partial-open failure must close/reap the worker before frame release.
    app.setFault(1);
    fail_present = false;
    if (app.start(&present) != -41 or app.active() or app.observed.recovered != 1 or
        app.observed.reaped != 1 or app.observed.wiped != 1 or
        app.observed.guards != 1 or app.observed.detached != 1 or
        (tasks.memory.reusable.localUsage() orelse return false).free != free_before) return false;
    const partial: extern struct { recovered: u32, generation: u32 } = .{ .recovered = 1, .generation = app.observed.generation };
    log.record("NIHOS_WASM_SESSION_PARTIAL", null, .{ "recovered", "generation" }, &partial);
    if (!start() or app.observed.generation <= previous_generation) return false;
    return true;
}
