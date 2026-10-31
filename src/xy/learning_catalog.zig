//! Borrowed, allocation-free XYLAB001 catalogue. No evaluation or JSON parsing.
//! Source positions are UTF-8 bytes in the matching section, never page numbers.
const std = @import("std");
pub const code_section = if (@import("builtin").os.tag == .freestanding) ".flash.xytext" else if (@import("builtin").object_format == .macho) "__TEXT,__text" else ".text";
pub const Error = error{ InvalidPack, Range, InvalidUtf8 };
pub const none = std.math.maxInt(u32);
pub const Section = struct { id: []const u8, text_bytes: u32, text_sha256: []const u8 };
pub const Anchor = struct { start: u32, end: u32 };
pub const Snippet = struct {
    id: []const u8,
    section: u32,
    code: []const u8,
    reference_output: []const u8,
    upstream_expected: []const u8,
    upstream_name: []const u8,
    requires_start: u32,
    requires_count: u32,
    example: ?u32,
    hidden: bool,
    eval_disabled: bool,
    definition: bool,
    anchor: ?Anchor,
};
pub const Experiment = struct {
    id: []const u8,
    editable: u32,
    invocation: u32,
    plan_start: u32,
    plan_count: u32,
    reference_text: []const u8,
    features: []const u8, // newline-delimited feature names, not executable text
    // Version 1 publishes source recipes only, never execution/grade approval.
    execution_qualified: bool = false,
    reference_approved: bool = false,
};
pub const Pack = struct {
    bytes: []const u8,
    section_count: u32,
    snippet_count: u32,
    experiment_count: u32,
    refs_count: u32,
    strings_at: u32,

    pub fn init(bytes: []const u8) linksection(code_section) Error!Pack {
        if (bytes.len < 128 or bytes.len > 16 * 1024 * 1024 or
            !std.mem.eql(u8, bytes[0..8], "XYLAB001") or read(bytes, 8) != 1 or
            read(bytes, 12) != bytes.len or read(bytes, 28) != 0) return error.InvalidPack;
        const p = Pack{ .bytes = bytes, .section_count = read(bytes, 16), .snippet_count = read(bytes, 20), .experiment_count = read(bytes, 24), .refs_count = read(bytes, 48), .strings_at = read(bytes, 52) };
        if (p.section_count == 0 or p.section_count > 256 or p.snippet_count == 0 or
            p.snippet_count > 4096 or p.experiment_count > 4096 or p.refs_count > 65536) return error.InvalidPack;
        const snippet_at = 128 + p.section_count * 44;
        const experiment_at = snippet_at + p.snippet_count * 68;
        const refs_at = experiment_at + p.experiment_count * 40;
        if (read(bytes, 32) != 128 or read(bytes, 36) != snippet_at or
            read(bytes, 40) != experiment_at or read(bytes, 44) != refs_at or
            p.strings_at != refs_at + p.refs_count * 4 or p.strings_at > bytes.len) return error.InvalidPack;
        _ = try p.credits();
        for (0..p.section_count) |i| _ = try p.section(@intCast(i));
        for (0..p.snippet_count) |i| _ = try p.snippet(@intCast(i));
        for (0..p.experiment_count) |i| _ = try p.experiment(@intCast(i));
        for (0..p.refs_count) |i| if (try p.reference(0, p.refs_count, @intCast(i)) >= p.snippet_count) return error.Range;
        return p;
    }
    pub fn matchesLibrary(self: Pack, hash: []const u8) linksection(code_section) bool {
        return hash.len == 32 and std.mem.eql(u8, self.bytes[64..96], hash);
    }
    pub fn credits(self: Pack) linksection(code_section) Error![]const u8 {
        return self.string(56, 4096);
    }
    fn text(self: Pack, offset: u32, len: u32) linksection(code_section) Error![]const u8 {
        if (offset < self.strings_at or offset > self.bytes.len or len > self.bytes.len - offset) return error.Range;
        const result = self.bytes[offset..][0..len];
        if (!std.unicode.utf8ValidateSlice(result)) return error.InvalidUtf8;
        return result;
    }
    fn string(self: Pack, at: usize, limit: u32) linksection(code_section) Error![]const u8 {
        if (read(self.bytes, at + 4) > limit) return error.Range;
        return self.text(read(self.bytes, at), read(self.bytes, at + 4));
    }
    fn references(self: Pack, start: u32, count: u32) linksection(code_section) Error!void {
        if (start > self.refs_count or count > self.refs_count - start) return error.Range;
    }
    pub fn reference(self: Pack, start: u32, count: u32, index: u32) linksection(code_section) Error!u32 {
        try self.references(start, count);
        if (index >= count) return error.Range;
        return read(self.bytes, read(self.bytes, 44) + @as(usize, start + index) * 4);
    }
    pub fn section(self: Pack, index: u32) linksection(code_section) Error!Section {
        if (index >= self.section_count) return error.Range;
        const at: usize = 128 + @as(usize, index) * 44;
        const id = try self.string(at, 128);
        if (id.len == 0) return error.InvalidPack;
        return .{ .id = id, .text_bytes = read(self.bytes, at + 8), .text_sha256 = self.bytes[at + 12 ..][0..32] };
    }
    pub fn snippet(self: Pack, index: u32) linksection(code_section) Error!Snippet {
        if (index >= self.snippet_count) return error.Range;
        const at: usize = read(self.bytes, 36) + @as(usize, index) * 68;
        const flags = read(self.bytes, at + 56);
        const section_index = read(self.bytes, at + 8);
        const example = read(self.bytes, at + 52);
        if (section_index >= self.section_count or flags & ~@as(u32, 15) != 0 or
            (example != none and example >= self.snippet_count)) return error.Range;
        const start = read(self.bytes, at + 60);
        const end = read(self.bytes, at + 64);
        const anchor: ?Anchor = if (flags & 8 != 0) .{ .start = start, .end = end } else null;
        if (anchor != null) {
            if (flags & 1 != 0 or start >= end or end > (try self.section(section_index)).text_bytes) return error.Range;
        } else if (start != none or end != none) return error.Range;
        const rs = read(self.bytes, at + 44);
        const rc = read(self.bytes, at + 48);
        try self.references(rs, rc);
        const id = try self.string(at, 128);
        const code = try self.string(at + 12, 4096);
        if (id.len == 0 or code.len == 0) return error.InvalidPack;
        return .{ .id = id, .section = section_index, .code = code, .reference_output = try self.string(at + 20, 4096), .upstream_expected = try self.string(at + 28, 1024), .upstream_name = try self.string(at + 36, 128), .requires_start = rs, .requires_count = rc, .example = if (example == none) null else example, .hidden = flags & 1 != 0, .eval_disabled = flags & 2 != 0, .definition = flags & 4 != 0, .anchor = anchor };
    }
    pub fn experiment(self: Pack, index: u32) linksection(code_section) Error!Experiment {
        if (index >= self.experiment_count) return error.Range;
        const at: usize = read(self.bytes, 40) + @as(usize, index) * 40;
        const editable = read(self.bytes, at + 8);
        const invocation = read(self.bytes, at + 12);
        const start = read(self.bytes, at + 16);
        const count = read(self.bytes, at + 20);
        if (editable >= self.snippet_count or invocation >= self.snippet_count or count == 0) return error.Range;
        try self.references(start, count);
        const id = try self.string(at, 128);
        if (id.len == 0) return error.InvalidPack;
        return .{ .id = id, .editable = editable, .invocation = invocation, .plan_start = start, .plan_count = count, .reference_text = try self.string(at + 24, 4096), .features = try self.string(at + 32, 1024) };
    }
    pub fn findSnippet(self: Pack, id: []const u8) linksection(code_section) Error!?u32 {
        for (0..self.snippet_count) |i| {
            if (std.mem.eql(u8, (try self.snippet(@intCast(i))).id, id)) return @intCast(i);
        }
        return null;
    }
    /// Only code anchors intersecting this page are candidates. Return full code.
    pub fn onPage(self: Pack, section_index: u32, start: u32, end: u32, ordinal: u32) linksection(code_section) Error!?Snippet {
        if (start > end or end > (try self.section(section_index)).text_bytes) return error.Range;
        if (start == end) return null;
        var found: u32 = 0;
        for (0..self.snippet_count) |i| {
            const s = try self.snippet(@intCast(i));
            const anchor = s.anchor orelse continue;
            if (s.section != section_index or s.hidden or s.eval_disabled or anchor.start >= end or anchor.end <= start) continue;
            if (found == ordinal) return s;
            found += 1;
        }
        return null;
    }
};
fn read(bytes: []const u8, at: usize) linksection(code_section) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

test "learning catalogue rejects truncated headers" {
    try std.testing.expectError(error.InvalidPack, Pack.init("XYLAB001"));
}
