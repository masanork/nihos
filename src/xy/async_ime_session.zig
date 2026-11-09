//! Host-only scheduler prototype for a workspace IME composition. The caller
//! serializes input and completions, keeps the dictionary pinned, and drains
//! outstanding producer buffers before detaching. No native worker is installed.
const std = @import("std");
pub const ime_code = if (@import("builtin").os.tag == .freestanding) ".flash.xytext" else if (@import("builtin").object_format == .macho) "__TEXT,__text" else ".text";
const conv = @import("conv.zig");
const ime = @import("standard_ime.zig");
const async_conversion = @import("async_conversion.zig");
const pages = @import("../storage/async_page.zig");

pub const Session = struct {
    pub const Progress = enum { idle, pending, need_page, complete, draining };
    const Phase = enum { idle, converting, lookup, draining };
    phase: Phase = .idle,
    cursor: conv.SlicedConversion = .{},
    reading: [72]u8 = @splat(0),
    length: usize = 0,
    revision: u32 = 0,
    document_cursor: u32 = 0,

    pub fn start(self: *Session, state: *ime.State, doc: anytype, adapter: *async_conversion.Adapter) linksection(ime_code) !void {
        if (self.phase != .idle or adapter.lookup_state != null) return error.Busy;
        if (!try state.prepareAsync(doc)) return error.NotReady;
        self.length = state.length;
        @memcpy(self.reading[0..self.length], state.reading[0..self.length]);
        self.revision = doc.revision;
        self.document_cursor = doc.cursor;
        self.cursor.begin(&state.engine, adapter, self.reading[0..self.length]);
        self.phase = .converting;
    }
    fn current(self: *const Session, state: *const ime.State, doc: anytype) linksection(ime_code) bool {
        return state.active and !state.converting and state.romaji.len == 0 and state.length == self.length and
            std.mem.eql(u8, state.reading[0..state.length], self.reading[0..self.length]) and
            doc.revision == self.revision and doc.cursor == self.document_cursor and
            doc.preedit.anchor_byte == self.document_cursor and std.mem.eql(u8, doc.preedit.slice(), self.reading[0..self.length]);
    }
    pub fn cancel(self: *Session, state: *ime.State, adapter: *async_conversion.Adapter) linksection(ime_code) !void {
        if (self.phase == .idle) return;
        self.cursor.cancel(&state.engine);
        try adapter.cancel();
        self.phase = if (adapter.lookup_state == null) .idle else .draining;
    }
    pub fn request(self: *const Session, adapter: *const async_conversion.Adapter) linksection(ime_code) ?pages.Request {
        if (self.phase != .lookup and self.phase != .draining) return null;
        return adapter.request();
    }
    pub fn supply(self: *Session, adapter: *async_conversion.Adapter, req: pages.Request, data: ?[]const u8) linksection(ime_code) !void {
        if (self.phase != .lookup and self.phase != .draining) return error.Denied;
        try adapter.supply(req, data);
        if (self.phase == .draining and adapter.lookup_state == null) self.phase = .idle;
    }
    pub fn step(self: *Session, state: *ime.State, doc: anytype, adapter: *async_conversion.Adapter, budget: usize) linksection(ime_code) !Progress {
        if (self.phase == .idle) return .idle;
        if (self.phase == .draining) return .draining;
        if (!self.current(state, doc)) {
            // Input may already have reused the engine for a new conversion.
            self.cursor.abandon();
            try adapter.cancel();
            self.phase = if (adapter.lookup_state == null) .idle else .draining;
            return error.StaleInput;
        }
        switch (self.phase) {
            .converting => switch (self.cursor.step(&state.engine, adapter, budget) catch |err| {
                try self.cancel(state, adapter);
                return err;
            }) {
                .pending => return .pending,
                .waiting => {
                    self.phase = .lookup;
                    return .pending;
                },
                .cancelled => {
                    self.phase = .idle;
                    return .idle;
                },
                .complete => {
                    state.publishAsync(doc) catch |err| {
                        try self.cancel(state, adapter);
                        return err;
                    };
                    self.phase = .idle;
                    return .complete;
                },
            },
            .lookup => switch (adapter.step(budget) catch |err| {
                try self.cancel(state, adapter);
                return err;
            }) {
                .pending => return .pending,
                .need_page => return .need_page,
                .complete => {
                    self.phase = .converting;
                    return .pending;
                },
                .cancelled => {
                    self.phase = if (adapter.lookup_state == null) .idle else .draining;
                    return if (self.phase == .idle) .idle else .draining;
                },
            },
            else => unreachable,
        }
    }
};

test "workspace composition waits for async dictionary then cycles and commits" {
    const scratch = @import("scratch.zig");
    const bytes = @embedFile("fixtures/jisyo_s_nfst.bin");
    var model: scratch.Model = undefined;
    model.initInPlace();
    model.ime.mode = .hiragana;
    for ("kanji") |c| model.handle(.{ .text = c });
    try std.testing.expectEqualStrings("かんじ", model.doc.preedit.slice());
    var page: pages.Coordinator = .{};
    try page.attach(1, bytes.len);
    var adapter = async_conversion.Adapter{ .coordinator = &page };
    var session: Session = .{};
    try session.start(&model.standard_input, &model.doc, &adapter);
    var count: usize = 0;
    while (true) {
        count += 1;
        try std.testing.expect(count < 100000);
        switch (try session.step(&model.standard_input, &model.doc, &adapter, 128)) {
            .pending => try std.testing.expectEqualStrings("かんじ", model.doc.preedit.slice()),
            .need_page => {
                const req = session.request(&adapter).?;
                try std.testing.expectEqualStrings("", model.doc.slice());
                try session.supply(&adapter, req, bytes[@intCast(req.offset)..][0..req.length]);
            },
            .complete => break,
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expectEqualStrings("漢字", model.doc.preedit.slice());
    model.handle(.{ .text = ' ' });
    try std.testing.expectEqualStrings("幹事", model.doc.preedit.slice());
    model.handle(.enter);
    try std.testing.expectEqualStrings("幹事", model.doc.slice());
    try page.detach();
}

test "workspace input changes cancel stale conversion and drain its request" {
    const scratch = @import("scratch.zig");
    const bytes = @embedFile("fixtures/jisyo_s_nfst.bin");
    var model: scratch.Model = undefined;
    model.initInPlace();
    model.ime.mode = .hiragana;
    for ("kanji") |c| model.handle(.{ .text = c });
    var page: pages.Coordinator = .{};
    try page.attach(1, bytes.len);
    var adapter = async_conversion.Adapter{ .coordinator = &page };
    var session: Session = .{};
    try session.start(&model.standard_input, &model.doc, &adapter);
    var req: ?pages.Request = null;
    for (0..10000) |_| {
        if (try session.step(&model.standard_input, &model.doc, &adapter, 128) == .need_page) {
            req = session.request(&adapter);
            break;
        }
    }
    const old = req orelse return error.TestUnexpectedResult;
    model.handle(.{ .text = 'a' });
    try std.testing.expectEqualStrings("かんじあ", model.doc.preedit.slice());
    try std.testing.expectError(error.StaleInput, session.step(&model.standard_input, &model.doc, &adapter, 128));
    try std.testing.expectError(error.Busy, page.detach());
    try session.supply(&adapter, old, bytes[@intCast(old.offset)..][0..old.length]);
    try std.testing.expectEqualStrings("かんじあ", model.doc.preedit.slice());
    try std.testing.expectEqualStrings("", model.doc.slice());
    try std.testing.expectError(error.Denied, session.supply(&adapter, old, null));
    try page.detach();
}

test "stale async work preserves a newer synchronous conversion" {
    const scratch = @import("scratch.zig");
    const bytes = @embedFile("fixtures/jisyo_s_nfst.bin");
    var model: scratch.Model = undefined;
    model.initInPlace();
    model.ime.mode = .hiragana;
    for ("kanji") |c| model.handle(.{ .text = c });
    var page: pages.Coordinator = .{};
    try page.attach(1, bytes.len);
    var adapter = async_conversion.Adapter{ .coordinator = &page };
    var session: Session = .{};
    try session.start(&model.standard_input, &model.doc, &adapter);
    var request: ?pages.Request = null;
    for (0..10000) |_| {
        if (try session.step(&model.standard_input, &model.doc, &adapter, 128) == .need_page) {
            request = session.request(&adapter);
            break;
        }
    }
    const old = request orelse return error.TestUnexpectedResult;
    model.handle(.{ .text = ' ' });
    try std.testing.expectEqualStrings("漢字", model.doc.preedit.slice());
    try std.testing.expectError(error.StaleInput, session.step(&model.standard_input, &model.doc, &adapter, 128));
    try session.supply(&adapter, old, bytes[@intCast(old.offset)..][0..old.length]);
    model.handle(.enter);
    try std.testing.expectEqualStrings("漢字", model.doc.slice());
    try page.detach();
}

/// Opt-in workspace port. The owner must call Model.pollAsyncIme and route
/// page completions; this type never submits I/O or authenticates a pin.
pub const Runtime = struct {
    session: Session = .{},
    adapter: *async_conversion.Adapter,

    pub fn initInPlace(self: *Runtime, adapter: *async_conversion.Adapter) linksection(ime_code) void {
        @memset(std.mem.asBytes(self), 0);
        self.adapter = adapter;
        self.session.cursor.resetInPlace();
    }

    pub fn port(self: *Runtime) linksection(ime_code) @import("scratch.zig").AsyncImePort {
        return .{ .context = self, .busy = isBusy, .start = startPort, .cancel = cancelPort, .poll = pollPort };
    }
    fn from(ctx: *anyopaque) linksection(ime_code) *Runtime {
        return @ptrCast(@alignCast(ctx));
    }
    fn isBusy(ctx: *anyopaque) linksection(ime_code) bool {
        return from(ctx).session.phase != .idle;
    }
    fn startPort(ctx: *anyopaque, model: *@import("scratch.zig").Model) linksection(ime_code) bool {
        const self = from(ctx);
        self.session.start(&model.standard_input, &model.doc, self.adapter) catch return false;
        return true;
    }
    fn cancelPort(ctx: *anyopaque, model: *@import("scratch.zig").Model) linksection(ime_code) void {
        const self = from(ctx);
        if (self.session.phase == .draining) return;
        self.session.cancel(&model.standard_input, self.adapter) catch {
            model.status = .invalid_input;
        };
    }
    fn pollPort(ctx: *anyopaque, model: *@import("scratch.zig").Model, budget: usize) linksection(ime_code) bool {
        const self = from(ctx);
        if (model.mode != .edit or model.nav.screen != .document or model.ime.mode == .direct or model.skk_input) {
            cancelPort(ctx, model);
            return false;
        }
        const progress = self.session.step(&model.standard_input, &model.doc, self.adapter, budget) catch {
            model.status = .invalid_input;
            return true;
        };
        return progress == .complete;
    }
    pub fn request(self: *const Runtime) linksection(ime_code) ?pages.Request {
        return self.session.request(self.adapter);
    }
    pub fn supply(self: *Runtime, req: pages.Request, data: ?[]const u8) linksection(ime_code) !void {
        try self.session.supply(self.adapter, req, data);
    }
};

test "workspace dispatcher cancels and drains before detaching async port" {
    const scratch = @import("scratch.zig");
    const bytes = @embedFile("fixtures/jisyo_s_nfst.bin");
    var model: scratch.Model = undefined;
    model.initInPlace();
    model.ime.mode = .hiragana;
    var page: pages.Coordinator = .{};
    try page.attach(1, bytes.len);
    var adapter = async_conversion.Adapter{ .coordinator = &page };
    var runtime = Runtime{ .adapter = &adapter };
    const port = runtime.port();
    try std.testing.expect(model.attachAsyncIme(&port));
    for ("kanji") |c| model.handle(.{ .text = c });
    model.handle(.{ .text = ' ' });
    const revision = model.revision;
    var req: ?pages.Request = null;
    for (0..10000) |_| {
        model.pollAsyncIme(128);
        try std.testing.expectEqual(revision, model.revision);
        if (runtime.request()) |r| {
            req = r;
            break;
        }
    }
    const pending = req orelse return error.TestUnexpectedResult;
    try std.testing.expect(!model.detachAsyncIme());
    model.handle(.{ .text = 'a' });
    try std.testing.expectEqualStrings("かんじあ", model.doc.preedit.slice());
    try std.testing.expect(!model.detachAsyncIme());
    model.handle(.{ .text = ' ' }); // Busy while the cancelled page drains.
    try std.testing.expectEqualStrings("かんじあ", model.doc.preedit.slice());
    try runtime.supply(pending, bytes[@intCast(pending.offset)..][0..pending.length]);
    try std.testing.expect(model.detachAsyncIme());
    try std.testing.expectEqualStrings("かんじあ", model.doc.preedit.slice());
    try page.detach();
}

test "workspace dispatcher can commit reading while cancelled page drains" {
    const scratch = @import("scratch.zig");
    const bytes = @embedFile("fixtures/jisyo_s_nfst.bin");
    var model: scratch.Model = undefined;
    model.initInPlace();
    model.ime.mode = .hiragana;
    var page: pages.Coordinator = .{};
    try page.attach(1, bytes.len);
    var adapter = async_conversion.Adapter{ .coordinator = &page };
    var runtime = Runtime{ .adapter = &adapter };
    const port = runtime.port();
    try std.testing.expect(model.attachAsyncIme(&port));
    for ("kanji") |c| model.handle(.{ .text = c });
    model.handle(.{ .text = ' ' });
    var req: ?pages.Request = null;
    for (0..10000) |_| {
        model.pollAsyncIme(128);
        if (runtime.request()) |r| {
            req = r;
            break;
        }
    }
    const pending = req orelse return error.TestUnexpectedResult;
    model.handle(.enter);
    try std.testing.expectEqualStrings("かんじ", model.doc.slice());
    try std.testing.expect(!model.detachAsyncIme());
    try runtime.supply(pending, bytes[@intCast(pending.offset)..][0..pending.length]);
    try std.testing.expectEqualStrings("かんじ", model.doc.slice());
    try std.testing.expect(model.detachAsyncIme());
    try page.detach();
}
