//! Resumable, allocation-free NFST lookup over an externally completed page
//! coordinator. One step processes at most one byte or one state transition.
//! The caller serializes access and retains the same immutable object pin.
const std = @import("std");
const pages = @import("async_page.zig");
const nfst = @import("nfst_reader.zig");

pub const Error = pages.Error || error{ Corrupt, InvalidKey };
pub const Progress = enum { pending, need_page, complete, cancelled };
const Phase = enum { header, node_len, edge, node_fields, child_table, children, child_edge_len, child_first, cand_count, cand_entry, cand_text, complete, cancelled, failed };

pub const Lookup = struct {
    coordinator: *pages.Coordinator,
    phase: Phase = .header,
    pending: ?pages.Request = null,
    key: [nfst.max_key_bytes]u8 = @splat(0),
    key_len: usize = 0,
    key_pos: usize = 0,
    header: [36]u8 = @splat(0),
    pos: usize = 0,
    trie: u64 = 0,
    trie_len: u32 = 0,
    cand: u64 = 0,
    cand_len: u32 = 0,
    arena: u64 = 0,
    arena_len: u32 = 0,
    node: u64 = 0,
    edge_len: u8 = 0,
    fields: [5]u8 = @splat(0),
    children_at: u64 = 0,
    child_count: u8 = 0,
    child_table: [255 * 4]u8 = @splat(0),
    child_index: usize = 0,
    child: u32 = 0,
    candidate_offset: u32 = 0,
    candidate_count: u8 = 0,
    candidate_index: usize = 0,
    candidate_entry: u32 = 0,
    result: nfst.Candidates = .{},

    pub fn begin(coordinator: *pages.Coordinator, key: []const u8) Error!Lookup {
        if (key.len == 0 or key.len > nfst.max_key_bytes or !std.unicode.utf8ValidateSlice(key)) return error.InvalidKey;
        if (coordinator.pin == 0) return error.NotReady;
        if (coordinator.state == .failed) return error.Io;
        if (coordinator.state != .idle and coordinator.state != .ready) return error.Busy;
        var self = Lookup{ .coordinator = coordinator, .key_len = key.len };
        @memcpy(self.key[0..key.len], key);
        return self;
    }
    fn fits(offset: u64, n: u64, limit: u64) bool {
        return offset <= limit and n <= limit - offset;
    }
    fn get(self: *Lookup, offset: u64) Error!?u8 {
        if (offset >= self.coordinator.length) return error.Corrupt;
        if (self.pending != null) return null;
        const base = offset - offset % pages.page_bytes;
        const active = self.coordinator.active;
        if (self.coordinator.state == .ready and active.generation == self.coordinator.generation and active.offset == base) {
            var out: [1]u8 = undefined;
            try self.coordinator.copy(active, @intCast(offset - base), &out);
            return out[0];
        }
        self.pending = try self.coordinator.request(base);
        return null;
    }
    pub fn request(self: *const Lookup) ?pages.Request {
        return self.pending;
    }
    pub fn supply(self: *Lookup, req: pages.Request, data: ?[]const u8) Error!void {
        const expected = self.pending orelse return error.Denied;
        if (!std.meta.eql(expected, req)) return error.Denied;
        self.coordinator.complete(req, data) catch |err| {
            self.pending = null;
            self.phase = .failed;
            return err;
        };
        self.pending = null;
    }
    pub fn cancel(self: *Lookup) Error!void {
        if (self.pending) |req| try self.coordinator.cancel(req);
        self.result.count = 0;
        self.phase = .cancelled;
    }
    pub fn candidates(self: *const Lookup) Error!nfst.Candidates {
        if (self.phase != .complete) return error.NotReady;
        return self.result;
    }
    fn consume(self: *Lookup) Error!void {
        switch (self.phase) {
            .header => {
                const byte = (try self.get(self.pos)) orelse return;
                self.header[self.pos] = byte;
                self.pos += 1;
                if (self.pos != 36) return;
                if (!std.mem.eql(u8, self.header[0..4], "NFST") or std.mem.readInt(u16, self.header[4..6], .little) != 1 or std.mem.readInt(u16, self.header[6..8], .little) != 0) return error.Corrupt;
                self.trie = std.mem.readInt(u32, self.header[12..16], .little);
                self.trie_len = std.mem.readInt(u32, self.header[16..20], .little);
                self.cand = std.mem.readInt(u32, self.header[20..24], .little);
                self.cand_len = std.mem.readInt(u32, self.header[24..28], .little);
                self.arena = std.mem.readInt(u32, self.header[28..32], .little);
                self.arena_len = std.mem.readInt(u32, self.header[32..36], .little);
                if (self.trie != 36 or self.trie_len < 6 or self.cand != self.trie + self.trie_len or self.arena != self.cand + self.cand_len or self.arena + self.arena_len != self.coordinator.length) return error.Corrupt;
                self.phase = .node_len;
            },
            .node_len => {
                if (!fits(self.node, 1, self.trie_len)) return error.Corrupt;
                self.edge_len = (try self.get(self.trie + self.node)) orelse return;
                if (!fits(self.node, @as(u64, self.edge_len) + 6, self.trie_len)) return error.Corrupt;
                if (self.edge_len > self.key_len - self.key_pos) {
                    self.phase = .complete;
                    return;
                }
                self.pos = 0;
                self.phase = .edge;
            },
            .edge => {
                if (self.pos == self.edge_len) {
                    self.key_pos += self.edge_len;
                    self.pos = 0;
                    self.phase = .node_fields;
                    return;
                }
                const byte = (try self.get(self.trie + self.node + 1 + self.pos)) orelse return;
                if (byte != self.key[self.key_pos + self.pos]) {
                    self.phase = .complete;
                    return;
                }
                self.pos += 1;
            },
            .node_fields => {
                const byte = (try self.get(self.trie + self.node + 1 + self.edge_len + self.pos)) orelse return;
                self.fields[self.pos] = byte;
                self.pos += 1;
                if (self.pos != 5) return;
                self.candidate_offset = std.mem.readInt(u32, self.fields[0..4], .little);
                self.child_count = self.fields[4];
                self.children_at = self.node + @as(u64, self.edge_len) + 6;
                if (!fits(self.children_at, @as(u64, self.child_count) * 4, self.trie_len)) return error.Corrupt;
                self.pos = 0;
                if (self.key_pos == self.key_len) {
                    if (self.candidate_offset == 0xffffffff) {
                        self.phase = .complete;
                        return;
                    }
                    if (!fits(self.candidate_offset, 1, self.cand_len)) return error.Corrupt;
                    self.phase = .cand_count;
                } else {
                    self.child_index = 0;
                    self.child = 0;
                    self.phase = .child_table;
                }
            },
            .child_table => {
                if (self.pos == @as(usize, self.child_count) * 4) {
                    self.pos = 0;
                    self.phase = .children;
                    return;
                }
                const byte = (try self.get(self.trie + self.children_at + self.pos)) orelse return;
                self.child_table[self.pos] = byte;
                self.pos += 1;
            },
            .children => {
                if (self.child_index == self.child_count) {
                    self.phase = .complete;
                    return;
                }
                self.child = std.mem.readInt(u32, self.child_table[self.child_index * 4 ..][0..4], .little);
                if (self.child <= self.node or !fits(self.child, 2, self.trie_len)) return error.Corrupt;
                self.phase = .child_edge_len;
            },
            .child_edge_len => {
                const byte = (try self.get(self.trie + self.child)) orelse return;
                if (byte == 0) return error.Corrupt;
                self.phase = .child_first;
            },
            .child_first => {
                const byte = (try self.get(self.trie + self.child + 1)) orelse return;
                if (byte == self.key[self.key_pos]) {
                    self.node = self.child;
                    self.phase = .node_len;
                } else {
                    self.child_index += 1;
                    self.child = 0;
                    self.phase = .children;
                }
            },
            .cand_count => {
                self.candidate_count = (try self.get(self.cand + self.candidate_offset)) orelse return;
                if (!fits(@as(u64, self.candidate_offset) + 1, @as(u64, self.candidate_count) * 4, self.cand_len)) return error.Corrupt;
                self.result.truncated = self.candidate_count > nfst.max_candidates;
                self.candidate_index = 0;
                self.candidate_entry = 0;
                self.pos = 0;
                self.phase = .cand_entry;
            },
            .cand_entry => {
                if (self.candidate_index == @min(self.candidate_count, nfst.max_candidates)) {
                    self.phase = .complete;
                    return;
                }
                const byte = (try self.get(self.cand + self.candidate_offset + 1 + self.candidate_index * 4 + self.pos)) orelse return;
                self.candidate_entry |= @as(u32, byte) << @intCast(8 * self.pos);
                self.pos += 1;
                if (self.pos == 4) {
                    const n: u8 = @truncate(self.candidate_entry >> 24);
                    if (n == 0 or !fits(self.candidate_entry & 0xffffff, n, self.arena_len)) return error.Corrupt;
                    self.result.lengths[self.candidate_index] = n;
                    self.pos = 0;
                    self.phase = .cand_text;
                }
            },
            .cand_text => {
                const n = self.result.lengths[self.candidate_index];
                const byte = (try self.get(self.arena + (self.candidate_entry & 0xffffff) + self.pos)) orelse return;
                self.result.bytes[self.candidate_index][self.pos] = byte;
                self.pos += 1;
                if (self.pos == n) {
                    if (!std.unicode.utf8ValidateSlice(self.result.slice(self.candidate_index))) return error.Corrupt;
                    self.result.count += 1;
                    self.candidate_index += 1;
                    self.candidate_entry = 0;
                    self.pos = 0;
                    self.phase = .cand_entry;
                }
            },
            .complete, .cancelled, .failed => {},
        }
    }
    pub fn step(self: *Lookup, budget: usize) Error!Progress {
        for (0..budget) |_| {
            if (self.phase == .cancelled) return .cancelled;
            if (self.phase == .failed) return error.Io;
            if (self.phase == .complete) return .complete;
            if (self.pending != null) return .need_page;
            self.consume() catch |err| {
                self.phase = .failed;
                self.result.count = 0;
                return err;
            };
        }
        if (self.phase == .complete) return .complete;
        if (self.phase == .cancelled) return .cancelled;
        if (self.pending != null) return .need_page;
        return .pending;
    }
};

test "resumable NFST lookup matches synchronous candidates and drains cancellation" {
    const bytes = @embedFile("../xy/fixtures/jisyo_s_nfst.bin");
    const Reader = struct {
        pub fn read(_: *@This(), offset: u64, out: []u8) error{Io}!usize {
            if (offset > bytes.len or out.len > bytes.len - offset) return error.Io;
            @memcpy(out, bytes[@intCast(offset)..][0..out.len]);
            return out.len;
        }
    };
    var source = Reader{};
    var reference = try nfst.Dictionary(Reader).init(&source, bytes.len);
    var page: pages.Coordinator = .{};
    try page.attach(1, bytes.len);
    for ([_][]const u8{ "かんじ", "にほん", "とうきょう", "そんざいしないことば" }) |key| {
        var expected: nfst.Candidates = .{};
        try reference.lookup(key, &expected);
        var lookup = try Lookup.begin(&page, key);
        var pending_count: usize = 0;
        while (true) {
            switch (try lookup.step(1)) {
                .pending => {},
                .need_page => {
                    const req = lookup.request().?;
                    try std.testing.expectError(error.NotReady, lookup.candidates());
                    try lookup.supply(req, bytes[@intCast(req.offset)..][0..req.length]);
                    pending_count += 1;
                },
                .complete => break,
                .cancelled => return error.TestUnexpectedResult,
            }
        }
        try std.testing.expect(pending_count > 0 or page.active.offset == 0);
        const actual = try lookup.candidates();
        try std.testing.expectEqual(expected.count, actual.count);
        try std.testing.expectEqual(expected.truncated, actual.truncated);
        for (0..expected.count) |i| try std.testing.expectEqualStrings(expected.slice(i), actual.slice(i));
    }
    var lookup = try Lookup.begin(&page, "かんじ");
    while (try lookup.step(1) != .need_page) {}
    const old = lookup.request().?;
    try lookup.cancel();
    try std.testing.expectError(error.Busy, page.detach());
    try std.testing.expectEqual(Progress.cancelled, try lookup.step(1));
    try std.testing.expectError(error.NotReady, lookup.candidates());
    try lookup.supply(old, bytes[@intCast(old.offset)..][0..old.length]);
    try std.testing.expectError(error.Denied, lookup.supply(old, null));
    try page.detach();
}

test "resumable NFST rejects corrupt headers and failed page completion" {
    var page: pages.Coordinator = .{};
    try page.attach(1, 36);
    var lookup = try Lookup.begin(&page, "あ");
    try std.testing.expectEqual(Progress.need_page, try lookup.step(1));
    const req = lookup.request().?;
    const corrupt: [36]u8 = @splat(0);
    try lookup.supply(req, &corrupt);
    var detected = false;
    for (0..100) |_| {
        _ = lookup.step(1) catch |err| {
            try std.testing.expectEqual(error.Corrupt, err);
            detected = true;
            break;
        };
    }
    try std.testing.expect(detected);
    try std.testing.expectError(error.NotReady, lookup.candidates());
    try page.detach();
    try page.attach(2, 36);
    lookup = try Lookup.begin(&page, "あ");
    try std.testing.expectEqual(Progress.need_page, try lookup.step(1));
    const fresh = lookup.request().?;
    try std.testing.expectError(error.Denied, lookup.supply(req, &corrupt));
    try std.testing.expectError(error.Io, lookup.supply(fresh, corrupt[0..1]));
    try std.testing.expectError(error.Io, lookup.step(1));
    try std.testing.expectError(error.NotReady, lookup.candidates());
    try page.detach();
}

test "child table spans pages and cancellation drains before reuse" {
    var bytes: [5244]u8 = @splat(0);
    @memcpy(bytes[0..4], "NFST");
    std.mem.writeInt(u16, bytes[4..6], 1, .little);
    std.mem.writeInt(u32, bytes[12..16], 36, .little);
    std.mem.writeInt(u32, bytes[16..20], 5200, .little);
    std.mem.writeInt(u32, bytes[20..24], 5236, .little);
    std.mem.writeInt(u32, bytes[24..28], 5, .little);
    std.mem.writeInt(u32, bytes[28..32], 5241, .little);
    std.mem.writeInt(u32, bytes[32..36], 3, .little);
    bytes[36] = 0;
    std.mem.writeInt(u32, bytes[37..41], 0xffffffff, .little);
    bytes[41] = 1;
    std.mem.writeInt(u32, bytes[42..46], 4049, .little);
    bytes[4085] = 1;
    bytes[4086] = 'a';
    std.mem.writeInt(u32, bytes[4087..4091], 0xffffffff, .little);
    bytes[4091] = 2;
    std.mem.writeInt(u32, bytes[4092..4096], 4964, .little);
    std.mem.writeInt(u32, bytes[4096..4100], 5064, .little);
    bytes[5000] = 1;
    bytes[5001] = 'x';
    std.mem.writeInt(u32, bytes[5002..5006], 0xffffffff, .little);
    bytes[5100] = 1;
    bytes[5101] = 'b';
    std.mem.writeInt(u32, bytes[5102..5106], 0, .little);
    bytes[5236] = 1;
    std.mem.writeInt(u32, bytes[5237..5241], 3 << 24, .little);
    @memcpy(bytes[5241..5244], "漢");
    var page: pages.Coordinator = .{};
    try page.attach(1, bytes.len);
    var lookup = try Lookup.begin(&page, "ab");
    var crossed = false;
    for (0..10000) |_| {
        switch (try lookup.step(1)) {
            .pending => {},
            .need_page => {
                const req = lookup.request().?;
                if (lookup.phase == .child_table and req.offset == 4096) {
                    crossed = true;
                    try lookup.cancel();
                    try std.testing.expectError(error.Busy, page.detach());
                    try lookup.supply(req, bytes[@intCast(req.offset)..][0..req.length]);
                    break;
                }
                try lookup.supply(req, bytes[@intCast(req.offset)..][0..req.length]);
            },
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expect(crossed);
    try page.detach();
    try page.attach(2, bytes.len);
    lookup = try Lookup.begin(&page, "ab");
    var complete = false;
    for (0..10000) |_| {
        switch (try lookup.step(1)) {
            .pending => {},
            .need_page => {
                const req = lookup.request().?;
                try lookup.supply(req, bytes[@intCast(req.offset)..][0..req.length]);
            },
            .complete => {
                complete = true;
                break;
            },
            .cancelled => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expect(complete);
    const result = try lookup.candidates();
    try std.testing.expectEqual(@as(u8, 1), result.count);
    try std.testing.expectEqualStrings("漢", result.slice(0));
    try page.detach();
}
