//! Host prototype connecting resumable NFST lookup to sliced conversion.
//! A stalled phrase is replayed from its start using bounded, copied results.
//! Caller serializes all access, keeps the object pinned, drives the lookup,
//! and drains an outstanding page request before releasing any resources.
const std = @import("std");
pub const ime_code = if (@import("builtin").os.tag == .freestanding) ".flash.xytext" else if (@import("builtin").object_format == .macho) "__TEXT,__text" else ".text";
const pages = @import("../storage/async_page.zig");
const nfst = @import("../storage/async_nfst.zig");
const candidates = @import("../storage/nfst_reader.zig").Candidates;

pub const Adapter = struct {
    const Key = struct {
        bytes: [64]u8 = @splat(0),
        len: u8 = 0,
        fn matches(self: *const Key, key: []const u8) linksection(ime_code) bool {
            return std.mem.eql(u8, self.bytes[0..self.len], key);
        }
        fn set(self: *Key, key: []const u8) linksection(ime_code) void {
            @memcpy(self.bytes[0..key.len], key);
            self.len = @intCast(key.len);
        }
    };
    const Answer = struct { key: Key = .{}, found: bool = false };
    const Full = struct { key: Key = .{}, result: candidates = .{} };
    coordinator: *pages.Coordinator,
    lookup_state: ?nfst.Lookup = null,
    query: Key = .{},
    query_full: bool = false,
    answers: [128]Answer = @splat(.{}),
    answer_count: usize = 0,
    full: [8]Full = @splat(.{}),
    full_count: usize = 0,
    failure: ?anyerror = null,
    cancelled: bool = false,

    pub fn beginConversion(self: *Adapter) linksection(ime_code) void {
        if (self.lookup_state != null) {
            self.failure = error.Busy;
            return;
        }
        self.failure = null;
        self.cancelled = false;
        self.answer_count = 0;
        self.full_count = 0;
    }
    pub fn conversionError(self: *const Adapter) linksection(ime_code) anyerror!void {
        if (self.failure) |err| return err;
        if (self.lookup_state != null) return error.WouldBlock;
    }
    fn start(self: *Adapter, key: []const u8, full: bool) linksection(ime_code) void {
        if (self.failure != null or self.lookup_state != null) return;
        if (key.len == 0 or key.len > 64) {
            self.failure = error.Capacity;
            return;
        }
        if ((full and self.full_count == self.full.len) or (!full and self.answer_count == self.answers.len)) {
            self.failure = error.Capacity;
            return;
        }
        self.query.set(key);
        self.query_full = full;
        self.lookup_state = nfst.Lookup.begin(self.coordinator, key) catch |err| {
            self.failure = err;
            return;
        };
    }
    pub fn contains(self: *Adapter, key: []const u8) linksection(ime_code) bool {
        if (self.failure != null or self.lookup_state != null) return false;
        for (self.answers[0..self.answer_count]) |*a| if (a.key.matches(key)) return a.found;
        for (self.full[0..self.full_count]) |*a| if (a.key.matches(key)) return a.result.count != 0;
        self.start(key, false);
        return false;
    }
    pub fn lookup(self: *Adapter, key: []const u8, out: [][]const u8) linksection(ime_code) usize {
        if (self.failure != null or self.lookup_state != null) return 0;
        for (self.full[0..self.full_count]) |*a| if (a.key.matches(key)) {
            const count = @min(out.len, a.result.count);
            for (0..count) |i| out[i] = a.result.slice(i);
            return count;
        };
        self.start(key, true);
        return 0;
    }
    pub fn step(self: *Adapter, budget: usize) linksection(ime_code) anyerror!nfst.Progress {
        if (self.failure) |err| return err;
        const l = if (self.lookup_state) |*value| value else return error.NotReady;
        const state = l.step(budget) catch |err| {
            self.failure = err;
            return err;
        };
        if (state == .complete) {
            const result = try l.candidates();
            if (self.query_full) {
                self.full[self.full_count] = .{ .key = self.query, .result = result };
                self.full_count += 1;
            } else {
                self.answers[self.answer_count] = .{ .key = self.query, .found = result.count != 0 };
                self.answer_count += 1;
            }
            self.lookup_state = null;
        } else if (state == .cancelled and l.request() == null) {
            self.lookup_state = null;
        }
        return state;
    }
    pub fn request(self: *const Adapter) linksection(ime_code) ?pages.Request {
        if (self.lookup_state) |*value| return value.request();
        return null;
    }
    pub fn supply(self: *Adapter, req: pages.Request, bytes: ?[]const u8) linksection(ime_code) anyerror!void {
        const l = if (self.lookup_state) |*value| value else return error.Denied;
        l.supply(req, bytes) catch |err| {
            self.failure = err;
            return err;
        };
        if (self.cancelled) self.lookup_state = null;
    }
    pub fn cancel(self: *Adapter) linksection(ime_code) anyerror!void {
        self.cancelled = true;
        if (self.lookup_state) |*value| {
            try value.cancel();
            if (value.request() == null) self.lookup_state = null;
        }
    }
};

test "async conversion waits for pages and matches synchronous candidates" {
    const conv = @import("conv.zig");
    const dictmod = @import("dict.zig");
    const bytes = @embedFile("fixtures/jisyo_s_nfst.bin");
    const reference_dict = try dictmod.NfstDict.init(bytes);
    var reference: conv.Engine = .{};
    reference.convert(&reference_dict, "かんじ");
    var coordinator: pages.Coordinator = .{};
    try coordinator.attach(1, bytes.len);
    var adapter = Adapter{ .coordinator = &coordinator };
    var engine: conv.Engine = .{};
    var cursor: conv.SlicedConversion = .{};
    cursor.begin(&engine, &adapter, "かんじ");
    var waits: usize = 0;
    var steps: usize = 0;
    while (true) {
        steps += 1;
        try std.testing.expect(steps < 200000);
        switch (try cursor.step(&engine, &adapter, 1)) {
            .pending => {},
            .waiting => {
                waits += 1;
                try std.testing.expectEqual(@as(usize, 0), engine.segment_count);
                while (true) {
                    switch (try adapter.step(64)) {
                        .pending => {},
                        .need_page => {
                            const req = adapter.request().?;
                            try adapter.supply(req, bytes[@intCast(req.offset)..][0..req.length]);
                        },
                        .complete => break,
                        .cancelled => return error.TestUnexpectedResult,
                    }
                }
            },
            .complete => break,
            .cancelled => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expect(waits > 1);
    try std.testing.expectEqual(reference.segment_count, engine.segment_count);
    for (0..reference.segment_count) |i| {
        try std.testing.expectEqual(reference.segments[i].cand_count, engine.segments[i].cand_count);
        for (0..reference.segments[i].cand_count) |j| try std.testing.expectEqualStrings(reference.candidateText(i, j), engine.candidateText(i, j));
    }
    std.debug.print("ASYNC_CONVERSION waits={d} steps={d} adapter_bytes={d}\n", .{ waits, steps, @sizeOf(Adapter) });
    cursor.begin(&engine, &adapter, "かんじ");
    while (try cursor.step(&engine, &adapter, 1) != .waiting) {}
    while (try adapter.step(1) != .need_page) {}
    const pending = adapter.request().?;
    try adapter.cancel();
    cursor.cancel(&engine);
    try std.testing.expectError(error.Busy, coordinator.detach());
    try std.testing.expectEqual(@as(usize, 0), engine.segment_count);
    try adapter.supply(pending, bytes[@intCast(pending.offset)..][0..pending.length]);
    try std.testing.expectError(error.Denied, adapter.supply(pending, null));
    try coordinator.detach();
}

test "async conversion cache exhaustion fails without publishing results" {
    const conv = @import("conv.zig");
    var coordinator: pages.Coordinator = .{};
    try coordinator.attach(1, 4096);
    var adapter = Adapter{ .coordinator = &coordinator };
    var engine: conv.Engine = .{};
    var cursor: conv.SlicedConversion = .{};
    cursor.begin(&engine, &adapter, "かんじ");
    adapter.answer_count = adapter.answers.len;
    try std.testing.expectError(error.Capacity, cursor.step(&engine, &adapter, 100));
    try std.testing.expectEqual(@as(usize, 0), engine.segment_count);
    try std.testing.expectEqual(conv.SlicedConversion.Progress.cancelled, try cursor.step(&engine, &adapter, 1));
    try coordinator.detach();
}
