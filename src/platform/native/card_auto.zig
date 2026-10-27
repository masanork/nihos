//! Card insertion -> PIN-free application detection -> one local job -> removal.
//! Foreground only. Never logs identifiers, touch coordinates, PINs or values.
const card = @import("card");
const std = @import("std");
const usb = @import("usb_probe.zig");
const i2c = @import("boot_i2c");
const timer = @import("timer_group");
const Pins = @import("display_probe.zig").Pins;
const display = @import("display_runtime.zig");
const renderer = @import("keypad_display.zig");
const photo = @import("photo_runtime.zig");
const options = @import("native_options");
const Service = card.ServiceType(true, ".flash.photo");
const License = card.LicenseRecord.Parser(".flash.photo");
const LicenceSession = card.LicenseSession.Session(".flash.photo");
var licence = LicenceSession{};
var service = Service{};
var entry = card.Entry{};
var owner = card.Owner{};
var device: ?usb.Device = null;
var touch: ?card.Touch.Device = null;
var gate = card.Presence.Gate{};
pub var armed = false;
pub const Report = struct {
    job: u32 = 0,
    kind: u32 = 0,
    state: u32 = 0,
    fault: u32 = 0,
    sw: u32 = 0,
    pin_index: u32 = 0,
    pin1_remaining: u32 = 255,
    pin2_remaining: u32 = 255,
    pin1_verifies: u32 = 0,
    pin2_verifies: u32 = 0,
    fields: u32 = 0,
    photo_decoded: u32 = 0,
    photo_error: u32 = 0,
    shown: u32 = 0,
    missing: u32 = 0,
    truncated: u32 = 0,
    cleanup: u32 = 0,
    erased: u32 = 0,
    verification: u32 = 0,
    changes: u32 = 0,
};
pub var report = Report{};
pub noinline fn diagnostic() linksection(".flash.photo") Report {
    var result = report;
    if (report.kind == 2 or report.kind == 4) {
        result.state = @backingInt(if (licence.fault != .none) licence.fault_state else licence.state);
        result.fault = @backingInt(licence.fault);
    } else {
        result.state = @backingInt(if (service.fault != .none) service.fault_state else service.state);
        result.fault = @backingInt(service.fault);
    }
    if (device) |link| if (link.policy.profile != .detection) {
        result.pin1_verifies = link.policy.verifies;
        result.pin2_verifies = link.policy.surface_verifies;
    };
    return result;
}
fn frame() []u8 {
    return @as([*]u8, @ptrFromInt(0x48030000))[0 .. 720 * 1280 * 2];
}
pub noinline fn prepare(clock: timer.Timer, panel: u32) linksection(".flash.photo") !void {
    clock.start();
    clock.disarm();
    defer clock.stop();
    try photo.prepare();
    errdefer {
        _ = photo.close();
    }
    if (!options.card_auto_probe and !try photo.cryptoExecute(null)) return error.CryptoSelfTest;
    if (!photo.close()) return error.Cleanup;
    var bus = i2c.Master(Pins){ .pins = .{ .clock = clock } };
    const selected: card.Touch.Panel = switch (panel) {
        1 => .ili9881c,
        2 => .st7123,
        3 => .st7121,
        else => return error.Panel,
    };
    touch = try card.Touch.Device.identify(&bus, selected);
    if (touch.?.width != 720 or touch.?.height != 1280) return error.Geometry;
    renderer.static_frame = true;
    renderer.overview_frame = false;
    renderer.pin_kind = 0;
    try card.ResultScreen.notice(".flash.keypad.auto_font", frame(), AutoCaptions.get(0), AutoCaptions.get(1));
}
noinline fn redraw(clock: timer.Timer, panel: u32) linksection(".flash.photo") !void {
    const result = display.replace(clock, panel);
    clock.start();
    clock.disarm();
    if (result.status != 1) return error.Display;
}
noinline fn notice(clock: timer.Timer, panel: u32, title: []const u8, detail: []const u8) linksection(".flash.photo") !void {
    renderer.static_frame = true;
    renderer.overview_frame = false;
    renderer.pin_kind = 0;
    try card.ResultScreen.notice(".flash.keypad.auto_font", frame(), title, detail);
    try redraw(clock, panel);
}
noinline fn open(clock: timer.Timer) linksection(".flash.photo") !void {
    var enumeration = usb.Report{};
    device = try usb.Device.openAutomatic(clock, &enumeration);
    armed = true;
    if (enumeration.vid != 0x054c or enumeration.pid != 0x0dc9) return error.UnsupportedReader;
    owner = .{ .sequence = 3 };
}
noinline fn close() linksection(".flash.photo") !void {
    if (device) |*link| {
        if (!link.cut_verified) try link.powerCut();
        try link.close();
        device = null;
    }
}
pub noinline fn emergency() linksection(".flash.photo") bool {
    entry.clear();
    var clean = true;
    if (device) |*link| clean = link.emergency();
    device = null;
    licence.disconnected();
    licence.dismiss() catch {
        clean = false;
    };
    service.disconnected();
    service.dismiss() catch {
        clean = false;
    };
    if (!photo.close()) clean = false;
    if (!display.emergency()) clean = false;
    armed = false;
    return clean;
}
noinline fn detect() linksection(".flash.photo") !u3 {
    try service.startDetection();
    for (0..8) |_| {
        _ = try owner.stepWithPowerCut(&service, &device.?);
        if (service.state == .done) break;
    }
    const kind = service.detectedKind() orelse return error.Detection;
    try close();
    try service.dismiss();
    report.cleanup = 2;
    report.erased = 1;
    return kind;
}
noinline fn begin(clock: timer.Timer, kind: u3) linksection(".flash.photo") !void {
    report.cleanup = 0;
    report.erased = 0;
    try photo.prepare();
    if (kind == 1) {
        try open(clock);
        device.?.policy.profile = .mynumber;
        device.?.policy.probe_only = true;
        try service.startSurfaceProbe();
        for (0..8) |_| {
            _ = try owner.stepWithPowerCut(&service, &device.?);
            if (service.state == .done) break;
        }
        report.pin2_remaining = service.surface_remaining orelse 255;
        if (service.fault != .none or service.cleanup_failed) return error.Counter;
        try close();
        try service.dismiss();
        try open(clock);
        device.?.policy.profile = .mynumber;
        try service.startPortraitWith(card.Surface.Parser(".flash.photo"), photo.raw());
    } else {
        try open(clock);
        device.?.policy.profile = if (kind == 4) .myna_license else .license;
        try licence.start(if (kind == 4) .myna else .classic, photo.raw());
    }
}
fn choiceKey(_: u16, y: u16) ?card.Key {
    return if (y >= 400 and y < 640) .one else if (y >= 700 and y < 940) .two else null;
}
noinline fn selectJob(clock: timer.Timer, panel: u32) linksection(".flash.photo") !u32 {
    try open(clock);
    try card.ResultScreen.chooseLicense(".flash.keypad.auto_font", frame());
    try redraw(clock, panel);
    var bus = i2c.Master(Pins){ .pins = .{ .clock = clock } };
    var gesture = card.Contact{ .held = true };
    const until = (clock.counter() orelse return error.Timer) + 180_000_000;
    var next_slot: u64 = 0;
    while (true) {
        const now = clock.counter() orelse return error.Timer;
        if (now >= until) return error.Timeout;
        if (now >= next_slot) {
            if (try device.?.slotState(&owner.sequence) == 2) return error.Removed;
            next_slot = now + 250_000;
        }
        const sample = try touch.?.sample(&bus);
        if (sample == .fresh) {
            const p = sample.fresh;
            if (gesture.sample(true, p.contacts, p.x, p.y, choiceKey)) |key| {
                try close();
                return if (key == .one) 4 else 1;
            }
        }
        if (!bus.pins.delay(20_000)) return error.Timer;
    }
}
noinline fn input(clock: timer.Timer, panel: u32, log: anytype, job_service: anytype) linksection(".flash.photo") !void {
    const prompt = job_service.prompt() orelse return error.Prompt;
    entry.clear();
    entry.contact.held = true;
    entry.contact.disarm();
    renderer.static_frame = false;
    renderer.overview_frame = false;
    renderer.demo_frame = false;
    renderer.pin_kind = prompt.index;
    renderer.read_remaining = prompt.remaining;
    try redraw(clock, panel);
    report.pin_index = prompt.index;
    if (report.kind == 2 and prompt.index == 1) report.pin2_remaining = licence.counts[1];
    if (prompt.index == 2) report.pin2_remaining = prompt.remaining else report.pin1_remaining = prompt.remaining;
    report.pin1_verifies = device.?.policy.verifies;
    report.pin2_verifies = device.?.policy.surface_verifies;
    log.prompt(&report);
    var bus = i2c.Master(Pins){ .pins = .{ .clock = clock } };
    var queued: u8 = 0;
    const deadline = (clock.counter() orelse 0) + 180_000_000;
    var next_slot: u64 = 0;
    while (job_service.prompt() != null) {
        if (!device.?.connected()) return error.Disconnected;
        const now = clock.counter() orelse return error.Timer;
        if (now >= next_slot) {
            if (try device.?.slotState(&owner.sequence) != 0) return error.Removed;
            next_slot = now + 250_000;
        }
        const sample = try touch.?.sample(&bus);
        if (sample == .fresh) {
            const point = sample.fresh;
            entry.touchWide(job_service, point.contacts, point.x, point.y);
        }
        const view = entry.view(job_service);
        if (view.masked_digits != queued) {
            if (renderer.update(view.masked_digits)) |_| queued = view.masked_digits else |err| if (err != error.Busy) return err;
        }
        if (now >= deadline) job_service.cancel();
        if (!bus.pins.delay(20_000)) return error.Timer;
    }
    entry.clear();
}
noinline fn verifyLicense(raw: []const u8) linksection(".flash.photo") !card.LicenseRecord.Verification {
    if (licence.fault != .none) return .not_checked;
    const signed = License.envelope(raw, report.kind == 4) catch return .malformed;
    const key = card.LicenseTrust.Store(".flash.license.trust").find(signed.signature.key_id) orelse return .unknown_key;
    const request = card.LicenseCrypto.Request{ .modulus = key.modulus, .exponent = key.exponent, .signature = signed.signature.value, .data = signed.data.ptr, .length = signed.data.len };
    return if (try photo.cryptoExecute(&request)) .valid else .invalid;
}
fn resultKey(x: u16, y: u16) ?card.Key {
    if (y < 1080 or y >= 1280 or x >= 720) return null;
    return if (x < 240) .erase else if (x < 480) .submit else .cancel;
}
noinline fn historyLabel(tag: u8) linksection(".flash.photo") []const u8 {
    return if (tag >= 0xab) AutoCaptions.get(2) else if (tag < 0x60) AutoCaptions.get(3) else if (tag < 0x68) AutoCaptions.get(4) else if (tag < 0x70) AutoCaptions.get(5) else if (tag < 0x78) AutoCaptions.get(6) else if (tag < 0x80) AutoCaptions.get(7) else if (tag < 0x88) AutoCaptions.get(8) else if (tag < 0x90) AutoCaptions.get(9) else AutoCaptions.get(10);
}
noinline fn renderDetails(clock: timer.Timer, panel: u32, wanted: u32) linksection(".flash.photo") !u32 {
    const raw = licence.result() orelse return error.Result;
    var rows: [3]card.ResultScreen.DetailRow = undefined;
    var used: usize = 0;
    var page = wanted;
    const D = @import("card").LicenseRecord;
    if (report.kind == 2) {
        var history: [32]D.History = undefined;
        defer std.crypto.secureZero(u8, std.mem.asBytes(&history));
        const first = try License.history(raw[2967..3607], &history);
        const last = if (licence.fault == .none) try License.history(raw[4848..5104], history[first.len..]) else history[0..0];
        const count = first.len + last.len;
        const pages = @max(1, (count + 2) / 3);
        page = @intCast((wanted - 1) % pages + 1);
        const start = (page - 1) * 3;
        for (history[@min(count, start)..@min(count, start + 3)], 0..) |*entry_record, i| {
            const work = photo.raw()[10000 + i * 320 ..][0..320];
            const decoded = try card.License.decodeJis(entry_record.text, work[0..260]);
            const authority = try card.License.decodeJis(entry_record.authority, work[264..]);
            var length = decoded.text.len;
            work[length] = ' ';
            length += 1;
            @memmove(work[length..][0..authority.text.len], authority.text);
            length += authority.text.len;
            rows[i] = .{ .label = historyLabel(entry_record.tag), .value = work[0..length], .date = &entry_record.date };
            used += 1;
            report.missing = @max(report.missing, decoded.missing + authority.missing);
        }
        const paint = try card.ResultScreen.licensePage(".flash.keypad.auto_font", frame(), false, rows[0..used]);
        report.missing = @max(report.missing, paint.missing);
        report.truncated |= @intFromBool(paint.truncated);
    } else {
        const encoding = (try License.myna(raw[0..5845])).encoding;
        var iterator = D.ExtendedIterator{ .bytes = raw[0..5845], .encoding = encoding };
        var count: usize = 0;
        while (try iterator.next()) |field| if (isMynaText(field.tag) and field.value.len > 0) {
            count += 1;
        };
        const pages = @max(1, (count + 2) / 3);
        page = @intCast((wanted - 1) % pages + 1);
        const start = (page - 1) * 3;
        iterator = .{ .bytes = raw[0..5845], .encoding = encoding };
        count = 0;
        while (try iterator.next()) |field| if (isMynaText(field.tag) and field.value.len > 0) {
            if (count >= start and used < 3) {
                const work = photo.raw()[10000 + used * 320 ..][0..320];
                const decoded = try card.License.decodeJis(field.value, work);
                rows[used] = .{ .label = if (field.tag <= 0xd3) AutoCaptions.get(11) else if (field.tag <= 0xde) AutoCaptions.get(9) else AutoCaptions.get(12), .value = decoded.text };
                used += 1;
                report.missing = @max(report.missing, decoded.missing);
            }
            count += 1;
        };
        const paint = try card.ResultScreen.licensePage(".flash.keypad.auto_font", frame(), true, rows[0..used]);
        report.missing = @max(report.missing, paint.missing);
        report.truncated |= @intFromBool(paint.truncated);
    }
    renderer.static_frame = true;
    renderer.overview_frame = true;
    try redraw(clock, panel);
    return page;
}
fn isMynaText(tag: u16) bool {
    return (tag >= 0xc6 and tag <= 0xc9) or (tag >= 0xcc and tag <= 0xd3) or (tag >= 0xd7 and tag <= 0xe6);
}
noinline fn renderResult(clock: timer.Timer, panel: u32) linksection(".flash.photo") !void {
    var portrait: ?[]const u8 = null;
    const encoded_photo = if (report.kind == 1) service.portrait() else licence.portrait();
    if (encoded_photo) |encoded| portrait = photo.decode(encoded);
    report.photo_decoded = @intFromBool(portrait != null);
    report.photo_error = photo.report.error_code;
    var painted: card.ResultScreen.Paint = .{};
    var history_summary: u2 = 0;
    if (report.kind == 1) {
        if (service.attributesResult()) |attributes| {
            painted = try card.ResultScreen.automaticOverview(".flash.keypad.auto_font", frame(), .{ .name = attributes.name, .address = attributes.address, .birth_date = attributes.birth_date, .detail = attributes.gender }, portrait);
            report.fields = 15;
        }
    } else if (licence.result()) |raw| {
        report.verification = @backingInt(try verifyLicense(raw));
        if (report.kind == 2) {
            const attributes = try License.current(raw[0..880], raw[2967..3607], photo.raw()[8192..8704]);
            painted = try card.ResultScreen.automaticOverview(".flash.keypad.auto_font", frame(), .{ .name = attributes.name, .address = attributes.address, .birth_date = attributes.birth_date, .detail = attributes.number, .expiration = attributes.expiration, .external_missing = attributes.missing }, portrait);
            var history: [32]card.LicenseRecord.History = undefined;
            defer std.crypto.secureZero(u8, std.mem.asBytes(&history));
            const first = try License.history(raw[2967..3607], &history);
            report.changes = @intCast(first.len);
            if (licence.fault == .none) {
                const second = try License.history(raw[4848..5104], history[first.len..]);
                report.changes += @intCast(second.len);
            }
            report.fields = 31;
            history_summary = if (attributes.history_unresolved) 2 else if (report.changes != 0) 1 else 0;
        } else {
            var info = try License.myna(raw[0..5845]);
            defer std.crypto.secureZero(u8, std.mem.asBytes(&info));
            painted = try card.ResultScreen.mynaOverview(".flash.keypad.auto_font", frame(), info.number, &info.expiration, info.types, portrait);
            report.fields = 7;
        }
        try card.ResultScreen.licenseNote(".flash.keypad.auto_font", frame(), @fromBackingInt(@intCast(report.verification)), report.kind == 4, history_summary);
        try card.ResultScreen.resultControls(".flash.keypad.auto_font", frame(), report.kind == 4);
    }
    if (report.fields == 0) {
        try notice(clock, panel, AutoCaptions.get(13), AutoCaptions.get(14));
        return;
    }
    renderer.static_frame = true;
    renderer.overview_frame = true;
    try redraw(clock, panel);
    report.shown = painted.shown;
    report.missing = painted.missing;
    report.truncated = @intFromBool(painted.truncated);
}
noinline fn waitForDismiss(clock: timer.Timer, panel: u32) linksection(".flash.photo") !void {
    try open(clock); // Only slot status; the authenticated link is already cut.
    var bus = i2c.Master(Pins){ .pins = .{ .clock = clock } };
    var gesture = card.Contact{ .held = true };
    var absent: u8 = 0;
    var page: u32 = 0;
    var next_slot: u64 = 0;
    const until = (clock.counter() orelse 0) + 180_000_000;
    while (true) {
        const now = clock.counter() orelse return error.Timer;
        if (now >= next_slot) {
            absent = if (try device.?.slotState(&owner.sequence) == 2) absent + 1 else 0;
            if (absent >= 2) break;
            next_slot = now + 250_000;
        }
        const sample = try touch.?.sample(&bus);
        if (sample == .fresh) {
            const point = sample.fresh;
            const tapped = if (report.kind == 1) gesture.sample(true, point.contacts, point.x, point.y, anyTap) else gesture.sample(true, point.contacts, point.x, point.y, resultKey);
            if (tapped) |key| {
                if (report.kind == 1 or key == .cancel) break;
                if (key == .erase) {
                    page = 0;
                    try renderResult(clock, panel);
                } else {
                    page = try renderDetails(clock, panel, page + 1);
                }
            }
        }
        if (now >= until) break;
        if (!bus.pins.delay(20_000)) return error.Timer;
    }
    try close();
}
fn anyTap(_: u16, _: u16) ?card.Key {
    return .submit;
}
noinline fn job(clock: timer.Timer, panel: u32, log: anytype) linksection(".flash.photo") !void {
    try begin(clock, @intCast(report.kind));
    if (report.kind == 1) try drive(clock, panel, log, &service) else try drive(clock, panel, log, &licence);
}
noinline fn drive(clock: timer.Timer, panel: u32, log: anytype, job_service: anytype) linksection(".flash.photo") !void {
    for (0..180) |_| {
        if (job_service.state == .done) break;
        if (job_service.prompt() != null) try input(clock, panel, log, job_service) else {
            if (!device.?.connected()) return error.Disconnected;
            _ = try owner.stepWithPowerCut(job_service, &device.?);
        }
    }
    if (job_service.state != .done) return error.Exhausted;
    report.state = @backingInt(job_service.fault_state);
    report.fault = @backingInt(job_service.fault);
    report.sw = job_service.last_sw;
    report.pin1_verifies = device.?.policy.verifies;
    report.pin2_verifies = device.?.policy.surface_verifies;
    try close();
    if (job_service.cleanup_failed) return error.Cleanup;
    report.cleanup = 2;
    try renderResult(clock, panel);
    log.result(&report);
    if (report.fields != 0) try waitForDismiss(clock, panel);
    try job_service.dismiss();
    if (!photo.close()) return error.Cleanup;
    report.erased = 1;
    try notice(clock, panel, AutoCaptions.get(14), AutoCaptions.get(15));
    log.finish(&report);
}
pub noinline fn run(clock: timer.Timer, panel: u32, log: anytype) linksection(".flash.photo") void {
    clock.start();
    clock.disarm();
    var bus = i2c.Master(Pins){ .pins = .{ .clock = clock } };
    while (display.snapshot().frames < 32) if (!bus.pins.delay(20_000)) halt();
    const refreshed = display.snapshot();
    log.refresh(&refreshed);
    log.boot(&photo.report);
    while (true) {
        if (device == null) open(clock) catch {
            if (!emergency()) halt();
            notice(clock, panel, AutoCaptions.get(16), AutoCaptions.get(17)) catch {
                halt();
            };
            if (!bus.pins.delay(1_000_000)) halt();
            continue;
        };
        const slot = device.?.slotState(&owner.sequence) catch {
            if (!emergency()) halt();
            gate.finish();
            notice(clock, panel, AutoCaptions.get(16), AutoCaptions.get(18)) catch {
                halt();
            };
            continue;
        };
        const event = gate.observe(slot != 2);
        if (event == .removed) {
            notice(clock, panel, AutoCaptions.get(0), AutoCaptions.get(1)) catch {
                halt();
            };
            log.removed(gate.job);
        } else if (event == .detect) {
            report = .{ .job = gate.job };
            notice(clock, panel, AutoCaptions.get(19), AutoCaptions.get(20)) catch {
                halt();
            };
            const kind = detect() catch {
                report = diagnostic();
                if (report.fault == 0) report.fault = 0x80000000;
                log.abort(&report);
                if (!emergency()) halt();
                gate.finish();
                notice(clock, panel, AutoCaptions.get(21), AutoCaptions.get(14)) catch {
                    halt();
                };
                continue;
            };
            report.kind = kind;
            log.detected(&report);
            if (options.card_auto_probe) {
                notice(clock, panel, if (kind == 1) AutoCaptions.get(22) else if (kind == 2) AutoCaptions.get(23) else if (kind == 4) AutoCaptions.get(24) else AutoCaptions.get(25), AutoCaptions.get(26)) catch {
                    halt();
                };
            } else if (kind == 1 or kind == 2 or kind == 4) selectedJob(clock, panel, log) catch {
                report = diagnostic();
                if (report.fault == 0) report.fault = 0x80000000;
                log.abort(&report);
                if (!emergency()) halt();
                notice(clock, panel, AutoCaptions.get(13), AutoCaptions.get(14)) catch {
                    halt();
                };
            } else notice(clock, panel, AutoCaptions.get(25), AutoCaptions.get(14)) catch {
                halt();
            };
            gate.finish();
        }
        if (!bus.pins.delay(250_000)) halt();
    }
}
noinline fn selectedJob(clock: timer.Timer, panel: u32, log: anytype) linksection(".flash.photo") !void {
    if (report.kind == 4) report.kind = try selectJob(clock, panel);
    log.selected(&report);
    try job(clock, panel, log);
}
fn halt() noreturn {
    while (true) asm volatile ("wfi");
}

const AutoCaptions = struct {
    const text = "カードを置いてください\x00" ++ "マイナンバーカード・IC運転免許証\x00" ++ "本籍の変更\x00" ++ "公安委員会\x00" ++ "氏名の変更\x00" ++ "呼び名の変更\x00" ++ "住所の変更\x00" ++ "免許条件の追加\x00" ++ "免許条件の解除\x00" ++ "備考\x00" ++ "追加の記載事項\x00" ++ "免許の条件\x00" ++ "予備の記録\x00" ++ "読み取りを中止しました\x00" ++ "カードを取り外してください\x00" ++ "取り外し後、次のカードを検知します\x00" ++ "リーダーを確認してください\x00" ++ "USB-Aにカードリーダーを接続してください\x00" ++ "カードを取り外してから接続してください\x00" ++ "カードを確認しています\x00" ++ "しばらくお待ちください\x00" ++ "カードを判定できませんでした\x00" ++ "マイナンバーカードを検知しました\x00" ++ "IC運転免許証を検知しました\x00" ++ "免許情報対応カードを検知しました\x00" ++ "対応するカードではありません\x00" ++ "PINは送信しません・取り外して次へ\x00";
    const placement = if (@import("builtin").os.tag == .freestanding) ".flash.rodata.card_pin" else if (@import("builtin").os.tag == .macos) "__TEXT,__const" else ".rodata";
    const data: [text.len]u8 align(4) linksection(placement) = text.*;
    inline fn get(index: usize) []const u8 {
        const live: [*]const volatile u8 = @ptrCast(&data);
        var offset: usize = 0;
        for (0..index) |_| {
            while (live[offset] != 0) : (offset += 1) {}
            offset += 1;
        }
        var end = offset;
        while (live[end] != 0) : (end += 1) {}
        return data[offset..end];
    }
};
