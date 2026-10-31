//! Module 3: Allocation-Free UTF-8 Document, Extended Grapheme (IVS / Dakuten)
//! Cursor, Grouped Undo Log, Ruby Spans, and Non-Destructive SKK Preedit Overlay.
//!
//! Enforces the contracts in `docs/planning/editor-extension-language.md`:
//! - All cursor movement, insertion, and deletion operate on extended grapheme
//!   cluster boundaries (never splitting a multi-byte scalar, combining dakuten,
//!   or IVS sequence such as `葛` + `U+E0100`).
//! - Range operations check the document `revision` so stale ranges from Scheme
//!   or external hooks are rejected explicitly.
//! - Uncommitted SKK input (`▽...` / `▼...`) is held in a non-destructive
//!   preedit overlay and only enters the document and undo log upon commit.
const std = @import("std");
// Document mutations are foreground operations, including RAM learning drafts.
// Keep their shared device implementation out of the resident SRAM heap.
const mutation_section = if (@import("builtin").os.tag == .freestanding) ".flash.xytext" else if (@import("builtin").object_format == .macho) "__TEXT,__text" else ".text";

pub const Error = error{
    InvalidUtf8,
    StaleRevision,
    UnalignedBoundary,
    OutOfBounds,
    BufferFull,
    UndoFull,
    RubyFull,
    PreeditFull,
};

pub const Range = struct {
    revision: u32,
    start: u32,
    end: u32,
};

pub const RubySpan = extern struct {
    base_start: u32 = 0,
    base_end: u32 = 0,
    ruby_start: u32 = 0,
    ruby_end: u32 = 0,
};

pub const PreeditPhase = enum(u8) {
    none = 0,
    /// `▽` reading input in progress
    reading = 1,
    /// `▼` candidate selection in minibuffer
    selecting = 2,
};

pub const PreeditOverlay = struct {
    phase: PreeditPhase = .none,
    anchor_byte: u32 = 0,
    len: u16 = 0,
    bytes: [128]u8 = @splat(0),

    pub fn slice(self: *const PreeditOverlay) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn clear(self: *PreeditOverlay) void {
        self.* = .{};
    }
};

pub inline fn isVariationSelector(cp: u21) bool {
    return (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xE0100 and cp <= 0xE01EF);
}

pub inline fn isCombiningDakuten(cp: u21) bool {
    return cp == 0x3099 or cp == 0x309A;
}

pub inline fn isGraphemeContinuation(cp: u21) bool {
    return isVariationSelector(cp) or isCombiningDakuten(cp) or cp == 0x200D;
}

/// Returns the byte length of the extended grapheme cluster starting at `text[offset]`.
pub fn nextClusterEnd(text: []const u8, offset: usize) Error!usize {
    if (offset >= text.len) return text.len;
    const len0 = std.unicode.utf8ByteSequenceLength(text[offset]) catch return error.InvalidUtf8;
    if (offset + len0 > text.len) return error.InvalidUtf8;
    _ = std.unicode.utf8Decode(text[offset .. offset + len0]) catch return error.InvalidUtf8;
    var cur = offset + len0;

    while (cur < text.len) {
        const len1 = std.unicode.utf8ByteSequenceLength(text[cur]) catch return error.InvalidUtf8;
        if (cur + len1 > text.len) return error.InvalidUtf8;
        const cp = std.unicode.utf8Decode(text[cur .. cur + len1]) catch return error.InvalidUtf8;
        if (isGraphemeContinuation(cp)) {
            cur += len1;
            // If ZWJ (U+200D), also include the following base scalar in the cluster
            if (cp == 0x200D and cur < text.len) {
                const len2 = std.unicode.utf8ByteSequenceLength(text[cur]) catch return error.InvalidUtf8;
                if (cur + len2 > text.len) return error.InvalidUtf8;
                _ = std.unicode.utf8Decode(text[cur .. cur + len2]) catch return error.InvalidUtf8;
                cur += len2;
            }
        } else {
            break;
        }
    }
    return cur;
}

/// Returns the byte start of the extended grapheme cluster immediately preceding `offset`.
pub fn prevClusterStart(text: []const u8, offset: usize) Error!usize {
    if (offset == 0) return 0;
    if (offset > text.len) return error.OutOfBounds;

    var cur: usize = 0;
    var prev: usize = 0;
    while (cur < offset) {
        prev = cur;
        cur = try nextClusterEnd(text, cur);
    }
    if (cur != offset) return error.UnalignedBoundary;
    return prev;
}

/// Verifies that `offset` sits on an extended grapheme cluster boundary in `text`.
pub fn isClusterBoundary(text: []const u8, offset: usize) bool {
    if (offset == 0 or offset == text.len) return true;
    if (offset > text.len) return false;
    var cur: usize = 0;
    while (cur < offset) {
        cur = nextClusterEnd(text, cur) catch return false;
    }
    return cur == offset;
}

const UndoOp = struct {
    group_id: u32 = 0,
    pos: u32 = 0,
    inserted_len: u32 = 0,
    deleted_offset: u32 = 0,
    deleted_len: u32 = 0,
    cursor_before: u32 = 0,
};

pub fn Document(
    comptime max_bytes: usize,
    comptime max_undo_ops: usize,
    comptime max_undo_bytes: usize,
    comptime max_ruby_spans: usize,
    comptime max_ruby_bytes: usize,
) type {
    return struct {
        const Self = @This();

        bytes: [max_bytes]u8 = @splat(0),
        len: u32 = 0,
        cursor: u32 = 0,
        selection_anchor: ?u32 = null,
        revision: u32 = 1,

        // Grouped undo stack
        active_group_id: u32 = 0,
        next_group_id: u32 = 1,
        undo_count: u32 = 0,
        undo_bytes_used: u32 = 0,
        undo_ops: [max_undo_ops]UndoOp = @splat(.{}),
        undo_arena: [max_undo_bytes]u8 = @splat(0),

        // Ruby annotation table
        ruby_count: u32 = 0,
        ruby_bytes_used: u32 = 0,
        ruby_spans: [max_ruby_spans]RubySpan = @splat(.{}),
        ruby_arena: [max_ruby_bytes]u8 = @splat(0),

        // Non-destructive SKK preedit overlay
        preedit: PreeditOverlay = .{},

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
            self.cursor = 0;
            self.revision +%= 1;
            if (self.revision == 0) self.revision = 1;
            self.active_group_id = 0;
            self.undo_count = 0;
            self.undo_bytes_used = 0;
            self.ruby_count = 0;
            self.ruby_bytes_used = 0;
            self.preedit.clear();
        }

        pub fn beginUndoGroup(self: *Self) u32 {
            if (self.active_group_id == 0) {
                self.active_group_id = self.next_group_id;
                self.next_group_id +%= 1;
                if (self.next_group_id == 0) self.next_group_id = 1;
            }
            return self.active_group_id;
        }

        pub fn endUndoGroup(self: *Self) void {
            self.active_group_id = 0;
        }

        /// Explicitly discard bounded undo history without changing the text,
        /// cursor, annotations, preedit or document revision.
        pub fn forgetUndoHistory(self: *Self) void {
            self.active_group_id = 0;
            self.undo_count = 0;
            self.undo_bytes_used = 0;
        }

        /// Move cursor by `delta` extended grapheme clusters (negative = left, positive = right).
        pub fn moveGraphemes(self: *Self, delta: i32) Error!u32 {
            var pos: usize = self.cursor;
            if (delta > 0) {
                var rem: usize = @intCast(delta);
                while (rem > 0 and pos < self.len) : (rem -= 1) {
                    pos = try nextClusterEnd(self.slice(), pos);
                }
            } else if (delta < 0) {
                var rem: usize = @intCast(-@as(i64, delta));
                while (rem > 0 and pos > 0) : (rem -= 1) {
                    pos = try prevClusterStart(self.slice(), pos);
                }
            }
            self.cursor = @intCast(pos);
            return self.cursor;
        }

        /// Move cursor by `delta` logical lines (`\n`-delimited), preserving grapheme column index.
        pub fn moveLines(self: *Self, delta: i32) linksection(mutation_section) Error!u32 {
            if (delta == 0) return self.cursor;
            const txt = self.slice();

            // Find start of current line and count grapheme column index
            var line_start: usize = self.cursor;
            while (line_start > 0 and txt[line_start - 1] != '\n') : (line_start -= 1) {}
            var col: usize = 0;
            var scan: usize = line_start;
            while (scan < self.cursor) : (col += 1) {
                scan = try nextClusterEnd(txt, scan);
            }

            var target_line_start = line_start;
            if (delta < 0) {
                var rem: usize = @intCast(-@as(i64, delta));
                while (rem > 0 and target_line_start > 0) : (rem -= 1) {
                    target_line_start -= 1; // step over '\n'
                    while (target_line_start > 0 and txt[target_line_start - 1] != '\n') : (target_line_start -= 1) {}
                }
            } else {
                var rem: usize = @intCast(delta);
                while (rem > 0) : (rem -= 1) {
                    if (std.mem.indexOfScalarPos(u8, txt, target_line_start, '\n')) |nl| {
                        target_line_start = nl + 1;
                    } else {
                        break;
                    }
                }
            }

            var target_line_end = std.mem.indexOfScalarPos(u8, txt, target_line_start, '\n') orelse txt.len;
            var pos = target_line_start;
            var c: usize = 0;
            while (c < col and pos < target_line_end) : (c += 1) {
                const next_pos = try nextClusterEnd(txt, pos);
                if (next_pos > target_line_end) break;
                pos = next_pos;
            }
            _ = &target_line_end;
            self.cursor = @intCast(pos);
            return self.cursor;
        }

        fn adjustRubyOnSplice(self: *Self, pos: u32, deleted_len: u32, inserted_len: u32) void {
            const del_end = pos + deleted_len;
            const delta: i64 = @as(i64, inserted_len) - @as(i64, deleted_len);
            var write_idx: usize = 0;
            for (self.ruby_spans[0..self.ruby_count]) |span| {
                if (span.base_end <= pos) {
                    self.ruby_spans[write_idx] = span;
                    write_idx += 1;
                } else if (span.base_start >= del_end) {
                    self.ruby_spans[write_idx] = .{
                        .base_start = @intCast(@as(i64, span.base_start) + delta),
                        .base_end = @intCast(@as(i64, span.base_end) + delta),
                        .ruby_start = span.ruby_start,
                        .ruby_end = span.ruby_end,
                    };
                    write_idx += 1;
                }
                // Spans overlapping the modified range are dropped cleanly
            }
            self.ruby_count = @intCast(write_idx);
        }

        fn applySpliceInternal(
            self: *Self,
            pos: u32,
            del_len: u32,
            ins_bytes: []const u8,
            record_undo: bool,
        ) linksection(mutation_section) Error!void {
            const ins_len: u32 = @intCast(ins_bytes.len);
            if (self.len - del_len + ins_len > max_bytes) return error.BufferFull;

            if (record_undo) {
                if (self.undo_count >= max_undo_ops or self.undo_bytes_used + del_len > max_undo_bytes)
                    return error.UndoFull;
                const grp = if (self.active_group_id != 0) self.active_group_id else blk: {
                    const g = self.next_group_id;
                    self.next_group_id +%= 1;
                    if (self.next_group_id == 0) self.next_group_id = 1;
                    break :blk g;
                };
                const del_off = self.undo_bytes_used;
                if (del_len > 0) {
                    @memcpy(self.undo_arena[del_off .. del_off + del_len], self.bytes[pos .. pos + del_len]);
                    self.undo_bytes_used += del_len;
                }
                self.undo_ops[self.undo_count] = .{
                    .group_id = grp,
                    .pos = pos,
                    .inserted_len = ins_len,
                    .deleted_offset = del_off,
                    .deleted_len = del_len,
                    .cursor_before = self.cursor,
                };
                self.undo_count += 1;
            }

            const tail_start = pos + del_len;
            const tail_len = self.len - tail_start;
            if (ins_len < del_len and tail_len > 0) {
                std.mem.copyForwards(
                    u8,
                    self.bytes[pos + ins_len .. pos + ins_len + tail_len],
                    self.bytes[tail_start .. tail_start + tail_len],
                );
            } else if (ins_len > del_len and tail_len > 0) {
                std.mem.copyBackwards(
                    u8,
                    self.bytes[pos + ins_len .. pos + ins_len + tail_len],
                    self.bytes[tail_start .. tail_start + tail_len],
                );
            }
            if (ins_len > 0) {
                @memcpy(self.bytes[pos .. pos + ins_len], ins_bytes);
            }
            self.len = self.len - del_len + ins_len;
            self.cursor = pos + ins_len;
            self.revision +%= 1;
            if (self.revision == 0) self.revision = 1;
            self.adjustRubyOnSplice(pos, del_len, ins_len);
        }

        /// Insert validated UTF-8 text at the current cursor position.
        pub fn insertUtf8(self: *Self, text: []const u8) linksection(mutation_section) Error!void {
            if (text.len == 0) return;
            if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
            // Disallow inserting an orphan variation selector/combining mark at offset 0
            const first_len = std.unicode.utf8ByteSequenceLength(text[0]) catch return error.InvalidUtf8;
            const first_cp = std.unicode.utf8Decode(text[0..first_len]) catch return error.InvalidUtf8;
            if (self.cursor == 0 and isGraphemeContinuation(first_cp)) return error.UnalignedBoundary;

            try self.applySpliceInternal(self.cursor, 0, text, true);
        }

        /// Delete one full extended grapheme cluster before the cursor (`Backspace`).
        pub fn deleteBackwardGrapheme(self: *Self) Error!bool {
            if (self.cursor == 0) return false;
            const start: u32 = @intCast(try prevClusterStart(self.slice(), self.cursor));
            const del_len = self.cursor - start;
            try self.applySpliceInternal(start, del_len, "", true);
            return true;
        }

        /// Delete one full extended grapheme cluster after the cursor (`Delete`).
        pub fn deleteForwardGrapheme(self: *Self) Error!bool {
            if (self.cursor >= self.len) return false;
            const end: u32 = @intCast(try nextClusterEnd(self.slice(), self.cursor));
            const del_len = end - self.cursor;
            try self.applySpliceInternal(self.cursor, del_len, "", true);
            return true;
        }

        /// Replace a revision-checked range on grapheme boundaries with `replacement`.
        pub fn replaceRange(self: *Self, range: Range, replacement: []const u8) Error!Range {
            if (range.revision != self.revision) return error.StaleRevision;
            if (range.start > range.end or range.end > self.len) return error.OutOfBounds;
            if (!isClusterBoundary(self.slice(), range.start) or !isClusterBoundary(self.slice(), range.end))
                return error.UnalignedBoundary;
            if (!std.unicode.utf8ValidateSlice(replacement)) return error.InvalidUtf8;

            try self.applySpliceInternal(range.start, range.end - range.start, replacement, true);
            return .{
                .revision = self.revision,
                .start = range.start,
                .end = range.start + @as(u32, @intCast(replacement.len)),
            };
        }

        /// Revert the latest undo group atomically.
        pub fn undo(self: *Self) linksection(mutation_section) Error!bool {
            if (self.undo_count == 0) return false;
            const target_group = self.undo_ops[self.undo_count - 1].group_id;
            while (self.undo_count > 0 and self.undo_ops[self.undo_count - 1].group_id == target_group) {
                self.undo_count -= 1;
                const op = self.undo_ops[self.undo_count];
                const restored = self.undo_arena[op.deleted_offset .. op.deleted_offset + op.deleted_len];
                try self.applySpliceInternal(op.pos, op.inserted_len, restored, false);
                self.undo_bytes_used = op.deleted_offset;
                self.cursor = op.cursor_before;
            }
            return true;
        }

        /// Set or update the non-destructive SKK preedit overlay at the current cursor.
        pub fn setPreedit(self: *Self, phase: PreeditPhase, text: []const u8) Error!void {
            if (text.len > self.preedit.bytes.len) return error.PreeditFull;
            if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
            self.preedit.phase = phase;
            self.preedit.anchor_byte = self.cursor;
            self.preedit.len = @intCast(text.len);
            @memcpy(self.preedit.bytes[0..text.len], text);
        }

        /// Commit the active SKK preedit by clearing the overlay and inserting `committed` as one undoable edit.
        pub fn commitPreedit(self: *Self, committed: []const u8) Error!void {
            self.preedit.clear();
            try self.insertUtf8(committed);
        }

        /// Attach a ruby reading to a grapheme-aligned base range `[base_start, base_end)`.
        pub fn addRuby(self: *Self, base_start: u32, base_end: u32, reading: []const u8) Error!void {
            if (base_start >= base_end or base_end > self.len) return error.OutOfBounds;
            if (!isClusterBoundary(self.slice(), base_start) or !isClusterBoundary(self.slice(), base_end))
                return error.UnalignedBoundary;
            if (!std.unicode.utf8ValidateSlice(reading) or reading.len == 0) return error.InvalidUtf8;
            if (self.ruby_count >= max_ruby_spans or self.ruby_bytes_used + reading.len > max_ruby_bytes)
                return error.RubyFull;

            const r_start = self.ruby_bytes_used;
            @memcpy(self.ruby_arena[r_start .. r_start + reading.len], reading);
            self.ruby_bytes_used += @intCast(reading.len);
            self.ruby_spans[self.ruby_count] = .{
                .base_start = base_start,
                .base_end = base_end,
                .ruby_start = r_start,
                .ruby_end = self.ruby_bytes_used,
            };
            self.ruby_count += 1;
        }
    };
}

// ============================================================================
// Unit Tests
// ============================================================================

test "grapheme cursor and backspace never split IVS or combining dakuten" {
    const DocType = Document(1024, 32, 512, 16, 256);
    var doc: DocType = .{};

    // Insert "葛" + U+E0100 (7 bytes) and "か" + U+3099 (6 bytes)
    try doc.insertUtf8("葛\u{E0100}か\u{3099}");
    try std.testing.expectEqual(@as(u32, 13), doc.len);
    try std.testing.expectEqual(@as(u32, 13), doc.cursor);

    // Move left by 1 grapheme: jumps over all 6 bytes of "か\u{3099}" to byte 7
    _ = try doc.moveGraphemes(-1);
    try std.testing.expectEqual(@as(u32, 7), doc.cursor);

    // Move left by 1 grapheme: jumps over all 7 bytes of "葛\u{E0100}" to byte 0
    _ = try doc.moveGraphemes(-1);
    try std.testing.expectEqual(@as(u32, 0), doc.cursor);

    // Move right by 1 grapheme -> byte 7, then Backspace deletes "葛\u{E0100}" as 1 unit!
    _ = try doc.moveGraphemes(1);
    try std.testing.expectEqual(@as(u32, 7), doc.cursor);
    try std.testing.expect(try doc.deleteBackwardGrapheme());
    try std.testing.expectEqualStrings("か\u{3099}", doc.slice());
    try std.testing.expectEqual(@as(u32, 0), doc.cursor);

    // Undo restores "葛\u{E0100}" at the front!
    try std.testing.expect(try doc.undo());
    try std.testing.expectEqualStrings("葛\u{E0100}か\u{3099}", doc.slice());
}

test "grouped undo reverts multi-step transaction and rejects stale or unaligned ranges" {
    const DocType = Document(1024, 32, 512, 16, 256);
    var doc: DocType = .{};
    try doc.insertUtf8("吾輩は猫である");
    const rev_before = doc.revision;

    // Reject unaligned byte boundary (byte 1 is inside "吾")
    try std.testing.expectError(
        error.UnalignedBoundary,
        doc.replaceRange(.{ .revision = rev_before, .start = 1, .end = 3 }, "私"),
    );

    // Grouped transaction: replace "吾輩" -> "私" and append "。"
    _ = doc.beginUndoGroup();
    _ = try doc.replaceRange(.{ .revision = doc.revision, .start = 0, .end = 6 }, "私");
    doc.cursor = doc.len;
    try doc.insertUtf8("。");
    doc.endUndoGroup();

    try std.testing.expectEqualStrings("私は猫である。", doc.slice());

    // Old revision is rejected
    try std.testing.expectError(
        error.StaleRevision,
        doc.replaceRange(.{ .revision = rev_before, .start = 0, .end = 3 }, "君"),
    );

    // Single undo reverts both edits in the group!
    try std.testing.expect(try doc.undo());
    try std.testing.expectEqualStrings("吾輩は猫である", doc.slice());
}

test "non-destructive SKK preedit overlay and ruby span shifting on edit" {
    const DocType = Document(1024, 32, 512, 16, 256);
    var doc: DocType = .{};
    try doc.insertUtf8("日本");
    try doc.addRuby(0, 6, "にほん");

    // Preedit overlay at start does not alter document bytes or revision
    doc.cursor = 0;
    const rev = doc.revision;
    try doc.setPreedit(.reading, "▽うつくしい");
    try std.testing.expectEqual(rev, doc.revision);
    try std.testing.expectEqualStrings("日本", doc.slice());
    try std.testing.expectEqualStrings("▽うつくしい", doc.preedit.slice());

    // Committing preedit clears overlay, inserts "美しい" (9 bytes), and shifts ruby span of "日本" from [0..6) to [9..15)!
    try doc.commitPreedit("美しい");
    try std.testing.expectEqual(PreeditPhase.none, doc.preedit.phase);
    try std.testing.expectEqualStrings("美しい日本", doc.slice());
    try std.testing.expectEqual(@as(u32, 9), doc.ruby_spans[0].base_start);
    try std.testing.expectEqual(@as(u32, 15), doc.ruby_spans[0].base_end);
}

test "extreme signed movements clamp without overflowing negation" {
    var doc = Document(128, 8, 128, 1, 16){};
    try doc.insertUtf8("葛\u{e0100}\nか\u{3099}");
    _ = try doc.moveGraphemes(std.math.minInt(i32));
    try std.testing.expectEqual(@as(u32, 0), doc.cursor);
    _ = try doc.moveGraphemes(std.math.maxInt(i32));
    try std.testing.expectEqual(doc.len, doc.cursor);
    _ = try doc.moveLines(std.math.minInt(i32));
    try std.testing.expect(doc.cursor < doc.len);
}
