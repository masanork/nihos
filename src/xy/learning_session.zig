//! Bounded RAM lessons. Owns drafts/notes and a VM separate from editor extensions.
//! Caller retains immutable catalogue bytes. No file, SQL, editor or device access.
const std = @import("std");
pub const catalog = @import("learning_catalog.zig");
pub const scheme = @import("scheme_runtime.zig");
const document = @import("document.zig");
pub const navigation = @import("navigation.zig");
pub const Doc = document.Document(4096, 256, 2048, 1, 64);
pub const capacity = 24;
const errors linksection(scheme.data_section) = "InvalidPack\x00Range\x00InvalidUtf8\x00StaleRevision\x00UnalignedBoundary\x00OutOfBounds\x00BufferFull\x00UndoFull\x00RubyFull\x00PreeditFull\x00NotReady\x00Full\x00Unsupported\x00".*;
pub const Error = catalog.Error || document.Error || error{ NotReady, Full, Unsupported };
pub const Slot = struct {
    used: bool,
    snippet: u32,
    code: Doc,
    notes: Doc,
    result: [256]u8,
    result_len: usize,
    result_revision: u32,
    failed: bool,
};
const Host = struct {
    pub fn schemeCall(_: *@This(), _: scheme.EditorOp, _: []const u8, _: i32) linksection(scheme.code_section) scheme.Error!void {
        return error.EditorFailure;
    }
};
pub const Session = struct {
    pack: catalog.Pack,
    ready: bool,
    page_valid: bool,
    page_section: u32,
    page_start: u32,
    page_end: u32,
    selected: u32,
    slots: [capacity]Slot,
    active_slot: ?u8,
    vm_slot: ?u8,
    active_vm: scheme.Runtime,
    candidate_vm: scheme.Runtime,
    editing_notes: bool,
    message: [256]u8,
    message_len: usize,

    pub fn initInPlace(self: *Session) linksection(scheme.code_section) void {
        @memset(std.mem.asBytes(self), 0);
        self.active_slot = null;
        self.vm_slot = null;
        self.active_vm.initInPlace();
    }
    pub fn bind(self: *Session, bytes: []const u8) linksection(scheme.code_section) Error!void {
        if (self.ready) {
            if (self.pack.bytes.ptr != bytes.ptr or self.pack.bytes.len != bytes.len) return error.NotReady;
            return;
        }
        self.pack = try catalog.Pack.init(bytes);
        self.ready = true;
    }
    pub fn setPage(self: *Session, section: u32, start: u32, end: u32) linksection(scheme.code_section) Error!void {
        if (!self.ready) return error.NotReady;
        if (start > end or end > (try self.pack.section(section)).text_bytes) return error.Range;
        if (!self.page_valid or self.page_section != section or self.page_start != start or self.page_end != end) self.selected = 0;
        self.page_section = section;
        self.page_start = start;
        self.page_end = end;
        self.page_valid = true;
    }
    pub fn choice(self: *const Session, ordinal: u32) linksection(scheme.code_section) Error!?catalog.Snippet {
        if (!self.ready or !self.page_valid) return null;
        return self.pack.onPage(self.page_section, self.page_start, self.page_end, ordinal);
    }
    pub fn count(self: *const Session) linksection(scheme.code_section) Error!u32 {
        var n: u32 = 0;
        while (try self.choice(n) != null) : (n += 1) {}
        return n;
    }
    pub fn slot(self: *Session) linksection(scheme.code_section) ?*Slot {
        return &self.slots[self.active_slot orelse return null];
    }
    pub fn doc(self: *Session) linksection(scheme.code_section) ?*Doc {
        const s = self.slot() orelse return null;
        return if (self.editing_notes) &s.notes else &s.code;
    }
    pub fn supported(self: *const Session, snippet: u32) linksection(scheme.code_section) Error!bool {
        for (0..self.pack.experiment_count) |i| {
            const e = try self.pack.experiment(@intCast(i));
            if (e.editable != snippet) continue;
            // This first executable profile is tested on the nine integer examples.
            return std.mem.eql(u8, e.features, "integer") and e.invocation == snippet and e.plan_count == 1;
        }
        return false;
    }
    pub fn open(self: *Session, ordinal: u32) linksection(scheme.code_section) Error!void {
        const item = (try self.choice(ordinal)) orelse return error.Range;
        const index = (try self.pack.findSnippet(item.id)) orelse return error.Range;
        self.message_len = 0;
        var free: ?u8 = null;
        for (&self.slots, 0..) |*s, i| {
            if (s.used and s.snippet == index) {
                self.active_slot = @intCast(i);
                self.editing_notes = false;
                return;
            }
            if (!s.used and free == null) free = @intCast(i);
        }
        const at = free orelse return error.Full;
        const s = &self.slots[at];
        @memset(std.mem.asBytes(s), 0);
        s.code.revision = 1;
        s.code.next_group_id = 1;
        s.notes.revision = 1;
        s.notes.next_group_id = 1;
        try s.code.insertUtf8(item.code);
        s.code.forgetUndoHistory();
        s.used = true;
        s.snippet = index;
        self.active_slot = at;
        self.editing_notes = false;
    }
    pub fn replace(self: *Session, bytes: []const u8) linksection(scheme.code_section) Error!void {
        const d = self.doc() orelse return error.NotReady;
        _ = try d.replaceRange(.{ .revision = d.revision, .start = 0, .end = d.len }, bytes);
    }
    pub fn insert(self: *Session, bytes: []const u8) linksection(scheme.code_section) Error!void {
        try (self.doc() orelse return error.NotReady).insertUtf8(bytes);
    }
    pub fn resetVm(self: *Session) linksection(scheme.code_section) void {
        self.active_vm.initInPlace();
        self.vm_slot = self.active_slot;
    }
    pub fn restore(self: *Session) linksection(scheme.code_section) Error!void {
        const s = self.slot() orelse return error.NotReady;
        const original = try self.pack.snippet(s.snippet);
        _ = try s.code.replaceRange(.{ .revision = s.code.revision, .start = 0, .end = s.code.len }, original.code);
    }
    pub fn run(self: *Session) linksection(scheme.code_section) Error!void {
        const s = self.slot() orelse return error.NotReady;
        if (!try self.supported(s.snippet)) return error.Unsupported;
        if (self.vm_slot != self.active_slot) self.resetVm();
        self.candidate_vm = self.active_vm;
        var host = Host{};
        s.result_revision = s.code.revision;
        const result = self.candidate_vm.evaluate(s.code.slice(), &host, &s.result) catch |err| {
            const text = scheme.message(err);
            @memcpy(s.result[0..text.len], text);
            s.result_len = text.len;
            s.failed = true;
            return;
        };
        self.active_vm = self.candidate_vm;
        s.result_len = result.len;
        s.failed = false;
    }
    pub fn notice(self: *Session, err: Error) linksection(scheme.code_section) void {
        const wanted: usize = switch (err) {
            error.InvalidPack => 0,
            error.Range => 1,
            error.InvalidUtf8 => 2,
            error.StaleRevision => 3,
            error.UnalignedBoundary => 4,
            error.OutOfBounds => 5,
            error.BufferFull => 6,
            error.UndoFull => 7,
            error.RubyFull => 8,
            error.PreeditFull => 9,
            error.NotReady => 10,
            error.Full => 11,
            error.Unsupported => 12,
        };
        var pos: usize = 0;
        var index: usize = 0;
        while (index < wanted) : (index += 1) pos += (std.mem.indexOfScalar(u8, errors[pos..], 0) orelse 0) + 1;
        const text = errors[pos..][0 .. std.mem.indexOfScalar(u8, errors[pos..], 0) orelse 0];
        @memcpy(self.message[0..text.len], text);
        self.message_len = text.len;
    }
    pub fn handle(self: *Session, nav: *navigation.State, key: navigation.Key) linksection(scheme.code_section) void {
        self.message_len = 0;
        if (key == .escape or key == .cancel) {
            nav.screen = .reading;
            return;
        }
        if (nav.screen == .examples) {
            const n = self.count() catch 0;
            switch (key) {
                .up, .left => self.selected -|= 1,
                .down, .right => if (n != 0) {
                    self.selected = @min(n - 1, self.selected + 1);
                },
                .enter => {
                    self.open(self.selected) catch |err| {
                        self.notice(err);
                        return;
                    };
                    nav.screen = .exercise;
                },
                else => {},
            }
            return;
        }
        const d = self.doc() orelse return;
        switch (key) {
            .clear => self.run() catch |err| self.notice(err), // Ctrl-L, without stealing typed letters
            .text => |b| self.insert(&.{b}) catch |err| self.notice(err),
            .enter => self.insert("\n") catch |err| self.notice(err),
            .backspace => {
                _ = d.deleteBackwardGrapheme() catch |err| {
                    self.notice(err);
                    return;
                };
            },
            .eof => {
                _ = d.deleteForwardGrapheme() catch |err| {
                    self.notice(err);
                    return;
                };
            },
            .undo => {
                _ = d.undo() catch |err| {
                    self.notice(err);
                    return;
                };
            },
            .left => {
                _ = d.moveGraphemes(-1) catch |err| {
                    self.notice(err);
                    return;
                };
            },
            .right => {
                _ = d.moveGraphemes(1) catch |err| {
                    self.notice(err);
                    return;
                };
            },
            .up => {
                _ = d.moveLines(-1) catch |err| {
                    self.notice(err);
                    return;
                };
            },
            .down => {
                _ = d.moveLines(1) catch |err| {
                    self.notice(err);
                    return;
                };
            },
            .escape, .cancel => unreachable,
        }
    }
    pub fn touch(self: *Session, nav: *navigation.State, x: u32, y: u32) linksection(scheme.code_section) void {
        if (x >= 1280 or y >= 720) return;
        if (nav.screen == .examples) {
            if (y >= 648) {
                nav.screen = .reading;
                return;
            }
            const row = if (y >= 132) (y - 132) / 72 else 6;
            if (row < 6) {
                self.selected = self.selected / 6 * 6 + row;
                self.handle(nav, .enter);
            }
            return;
        }
        if (y < 648) return;
        self.message_len = 0;
        if (x < 200) nav.screen = .reading else if (x < 450) self.run() catch |err| self.notice(err) else if (x < 700) self.resetVm() else if (x < 950) self.restore() catch |err| self.notice(err) else self.editing_notes = !self.editing_notes;
    }
};
