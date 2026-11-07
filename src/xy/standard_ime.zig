//! Bounded conventional romaji composition and bunsetsu conversion.
const std = @import("std");
const omni = @import("ime_omni.zig");
const conv = @import("conv.zig");
const document = @import("document.zig");
pub const code_section = omni.code_section;

pub const State = struct {
    romaji: omni.RomajiAutomaton = .{},
    reading: [72]u8 = @splat(0),
    length: u8 = 0,
    active: bool = false,
    converting: bool = false,
    focus: u8 = 0,
    engine: conv.Engine = .{},

    fn overlay(self: *State, doc: anytype) linksection(code_section) !void {
        var buf: [128]u8 = undefined;
        var len: usize = 0;
        if (self.converting) {
            for (0..self.engine.segment_count) |i| {
                const s = self.engine.candidateText(i, self.engine.segments[i].selected);
                if (s.len > buf.len - len) return error.PreeditFull;
                @memcpy(buf[len..][0..s.len], s);
                len += s.len;
            }
        } else {
            len = self.length;
            @memcpy(buf[0..len], self.reading[0..len]);
            const pending = self.romaji.pendingSlice();
            @memcpy(buf[len..][0..pending.len], pending);
            len += pending.len;
        }
        if (!self.active) doc.preedit.clear() else try doc.setPreedit(if (self.converting) .selecting else .reading, buf[0..len]);
    }
    fn flush(self: *State) linksection(code_section) !void {
        const pending = self.romaji;
        const required: usize = if (pending.len == 1 and pending.pending[0] == 'n') 3 else pending.len;
        if (required > self.reading.len - self.length) return error.PreeditFull;
        if (self.romaji.flushTrailingN(false)) |n| {
            @memcpy(self.reading[self.length..][0..n.len], n);
            self.length += @intCast(n.len);
        } else if (pending.len != 0) {
            @memcpy(self.reading[self.length..][0..pending.len], pending.pendingSlice());
            self.length += pending.len;
        }
    }
    /// Prepare an immutable reading for an externally scheduled conversion.
    pub fn prepareAsync(self: *State, doc: anytype) linksection(code_section) !bool {
        if (!self.active or self.converting) return false;
        try self.flush();
        try self.overlay(doc);
        return self.length != 0;
    }
    /// Called only after a scheduler has validated the original composition.
    pub fn publishAsync(self: *State, doc: anytype) linksection(code_section) !void {
        if (!self.active or self.converting or self.engine.segment_count == 0) return error.PreeditFull;
        for (self.engine.segments[0..self.engine.segment_count]) |segment| {
            if (segment.cand_count == 0) return error.PreeditFull;
        }
        self.converting = true;
        self.focus = 0;
        self.overlay(doc) catch |err| {
            self.converting = false;
            try self.overlay(doc);
            return err;
        };
    }
    pub fn cancel(self: *State, doc: anytype) linksection(code_section) !void {
        if (self.converting) {
            self.converting = false;
        } else {
            self.active = false;
            self.length = 0;
            self.romaji.clear();
        }
        try self.overlay(doc);
    }
    pub fn commit(self: *State, doc: anytype) linksection(code_section) !void {
        if (!self.active) return;
        try self.flush();
        var text: [128]u8 = undefined;
        var length: usize = 0;
        if (self.converting) {
            for (0..self.engine.segment_count) |i| {
                const candidate = self.engine.candidateText(i, self.engine.segments[i].selected);
                if (candidate.len > text.len - length) return error.PreeditFull;
                @memcpy(text[length..][0..candidate.len], candidate);
                length += candidate.len;
            }
        } else {
            length = self.length;
            @memcpy(text[0..length], self.reading[0..length]);
        }
        try doc.commitPreedit(text[0..length]);
        self.active = false;
        self.converting = false;
        self.length = 0;
        self.romaji.clear();
    }
    pub fn key(self: *State, doc: anytype, dict: anytype, key_byte: u8) linksection(code_section) !void {
        if (key_byte == 0x07) return self.cancel(doc);
        if (key_byte == '\n') return self.commit(doc);
        if (key_byte == 0x7f) {
            if (self.converting) {
                self.converting = false;
            } else if (self.romaji.len > 0) {
                self.romaji.len -= 1;
            } else if (self.length > 0) {
                self.length = @intCast(try document.prevClusterStart(self.reading[0..self.length], self.length));
            } else if (!self.active) {
                _ = try doc.deleteBackwardGrapheme();
            }
            if (self.length == 0 and self.romaji.len == 0) self.active = false;
            return self.overlay(doc);
        }
        if (key_byte == ' ') {
            if (!self.active) return doc.insertUtf8(" ");
            if (self.converting) {
                self.engine.nextCandidate(self.focus);
            } else {
                try self.flush();
                if (self.length == 0) {
                    self.active = false;
                    return self.overlay(doc);
                }
                if (@hasDecl(@TypeOf(dict.*), "beginConversion")) dict.beginConversion();
                self.engine.convert(dict, self.reading[0..self.length]);
                if (@hasDecl(@TypeOf(dict.*), "conversionError")) dict.conversionError() catch |err| {
                    self.engine.segment_count = 0;
                    try self.overlay(doc);
                    return err;
                };
                if (self.engine.segment_count == 0) return error.PreeditFull;
                for (self.engine.segments[0..self.engine.segment_count]) |segment| {
                    if (segment.cand_count == 0) return error.PreeditFull;
                }
                self.converting = true;
                self.focus = 0;
            }
            self.overlay(doc) catch |err| {
                self.converting = false;
                try self.overlay(doc);
                return err;
            };
            return;
        }
        if (self.converting) try self.commit(doc);
        const lower = std.ascii.toLower(key_byte);
        if (!std.ascii.isAlphabetic(lower) and lower != '-' and lower != '.' and lower != ',' and lower != '[' and lower != ']' and lower != '\'') {
            try self.flush();
            if (self.length == self.reading.len) return error.PreeditFull;
            self.reading[self.length] = key_byte;
            self.length += 1;
            self.active = true;
            return self.overlay(doc);
        }
        const previous = self.romaji;
        const fed = self.romaji.feed(lower, false);
        if (fed.emitted_len > self.reading.len - self.length) {
            self.romaji = previous;
            return error.PreeditFull;
        }
        if (fed.emitted_len > 0) {
            @memcpy(self.reading[self.length..][0..fed.emitted_len], fed.slice());
            self.length += fed.emitted_len;
        }
        self.active = self.length != 0 or self.romaji.len != 0;
        try self.overlay(doc);
    }
    pub fn move(self: *State, doc: anytype, delta: i8, candidate: bool) linksection(code_section) !void {
        if (!self.converting or self.engine.segment_count == 0) return;
        if (candidate) {
            if (delta > 0) self.engine.nextCandidate(self.focus) else self.engine.prevCandidate(self.focus);
        } else if (delta > 0) {
            if (self.focus + 1 < self.engine.segment_count) self.focus += 1;
        } else if (self.focus > 0) self.focus -= 1;
        try self.overlay(doc);
    }
};
