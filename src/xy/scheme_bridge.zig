//! Module 5: Allocation-Free Scheme × `sqld` × `xy` Bridge (`src/xy/scheme_bridge.zig`)
//!
//! Connects the live S-expression evaluator to:
//! 1. `ViewStyle` (`(view/set! #:font 'bunsen-mincho #:size 28 #:direction 'vertical)`)
//!    for zero-SD-I/O live typography and orientation switching.
//! 2. `Document` (`(buffer/insert! ...)`, `(buffer/move-graphemes! ...)`, `(buffer/add-ruby! ...)`,
//!    `(buffer/with-undo-group ...)`, `(buffer/undo!)`) for grapheme-safe buffer editing.
//! 3. `sqld` (`(q 'table #:where ... #:limit ...)` and versioned `sys_config` with
//!    `(sys/config-set! ...)` / `(sys/config-rollback!)`).
//! 4. `OmniIme` (`(ime/register-prefix! "#" ...)` and live `▽(...)` SKK Program Conversion).
//! 5. C-ABI Display List generation (`PlacedGlyph`) for dual-target `nihos` (Tab5 RGB565)
//!    and macOS/PC (`GPUI`) rendering.

const std = @import("std");
pub const viewport_layout = @import("viewport_layout");
pub const document = @import("document.zig");
pub const ime_omni = @import("ime_omni.zig");

pub const ViewStyle = viewport_layout.ViewStyle;
pub const PlacedGlyph = viewport_layout.PlacedGlyph;

pub const EvalError = error{
    SyntaxError,
    UnexpectedEof,
    ArenaFull,
    UnknownForm,
    TypeMismatch,
    ArityMismatch,
    NoPreviousConfigGeneration,
} || document.Error;

// ============================================================================
// Allocation-Free S-Expression Value & Arena
// ============================================================================

pub const ValueTag = enum(u8) {
    nil = 0,
    boolean = 1,
    int = 2,
    symbol = 3,
    keyword = 4,
    string = 5,
    pair = 6,
};

pub const PairCell = struct {
    car: u16,
    cdr: u16,
};

pub const Value = union(ValueTag) {
    nil: void,
    boolean: bool,
    int: i64,
    symbol: []const u8,
    keyword: []const u8,
    string: []const u8,
    pair: PairCell,
};

pub const SexpArena = struct {
    nodes: [256]Value = @splat(.{ .nil = {} }),
    node_count: u16 = 0,
    str_buf: [2048]u8 = @splat(0),
    str_used: u16 = 0,

    pub fn reset(self: *SexpArena) void {
        self.node_count = 0;
        self.str_used = 0;
    }

    pub fn allocNode(self: *SexpArena, val: Value) EvalError!u16 {
        if (self.node_count >= self.nodes.len) return error.ArenaFull;
        const idx = self.node_count;
        self.nodes[idx] = val;
        self.node_count += 1;
        return idx;
    }

    pub fn allocString(self: *SexpArena, bytes: []const u8) EvalError![]const u8 {
        if (self.str_used + bytes.len > self.str_buf.len) return error.ArenaFull;
        const start = self.str_used;
        @memcpy(self.str_buf[start .. start + bytes.len], bytes);
        self.str_used += @intCast(bytes.len);
        return self.str_buf[start .. start + bytes.len];
    }

    pub fn cons(self: *SexpArena, car_idx: u16, cdr_idx: u16) EvalError!u16 {
        return self.allocNode(.{ .pair = .{ .car = car_idx, .cdr = cdr_idx } });
    }

    /// Format a `Value` into a caller-supplied buffer as canonical S-expression text.
    pub fn formatValue(self: *const SexpArena, val: Value, out_buf: []u8) []const u8 {
        var pos: usize = 0;
        self.writeValue(val, out_buf, &pos);
        return out_buf[0..pos];
    }

    fn writeValue(self: *const SexpArena, val: Value, out_buf: []u8, pos: *usize) void {
        switch (val) {
            .nil => appendSlice(out_buf, pos, "()"),
            .boolean => |b| appendSlice(out_buf, pos, if (b) "#t" else "#f"),
            .int => |n| {
                const s = std.fmt.bufPrint(out_buf[pos.*..], "{d}", .{n}) catch "";
                pos.* += s.len;
            },
            .symbol => |sym| appendSlice(out_buf, pos, sym),
            .keyword => |kw| {
                appendSlice(out_buf, pos, "#:");
                appendSlice(out_buf, pos, kw);
            },
            .string => |str| {
                appendSlice(out_buf, pos, "\"");
                appendSlice(out_buf, pos, str);
                appendSlice(out_buf, pos, "\"");
            },
            .pair => |cell| {
                appendSlice(out_buf, pos, "(");
                var cur_car = cell.car;
                var cur_cdr = cell.cdr;
                var first = true;
                while (true) {
                    if (!first) appendSlice(out_buf, pos, " ");
                    first = false;
                    self.writeValue(self.nodes[cur_car], out_buf, pos);
                    switch (self.nodes[cur_cdr]) {
                        .nil => break,
                        .pair => |next_cell| {
                            cur_car = next_cell.car;
                            cur_cdr = next_cell.cdr;
                        },
                        else => |tail| {
                            appendSlice(out_buf, pos, " . ");
                            self.writeValue(tail, out_buf, pos);
                            break;
                        },
                    }
                }
                appendSlice(out_buf, pos, ")");
            },
        }
    }

    /// Extract the plain insertion string for SKK Program Conversion (`string` unquoted, others formatted).
    pub fn valueToInsertText(self: *const SexpArena, val: Value, out_buf: []u8) []const u8 {
        return switch (val) {
            .string => |s| blk: {
                const n = @min(s.len, out_buf.len);
                @memcpy(out_buf[0..n], s[0..n]);
                break :blk out_buf[0..n];
            },
            else => self.formatValue(val, out_buf),
        };
    }
};

fn appendSlice(buf: []u8, pos: *usize, s: []const u8) void {
    const rem = buf.len - pos.*;
    const n = @min(rem, s.len);
    @memcpy(buf[pos.* .. pos.* + n], s[0..n]);
    pos.* += n;
}

// ============================================================================
// S-Expression Reader (Parser)
// ============================================================================

pub const Reader = struct {
    src: []const u8,
    pos: usize = 0,
    arena: *SexpArena,

    fn isDelimiter(ch: u8) bool {
        return switch (ch) {
            ' ', '\t', '\n', '\r', '(', ')', '"', ';' => true,
            else => false,
        };
    }

    pub fn skipWhitespaceAndComments(self: *Reader) void {
        while (self.pos < self.src.len) {
            const ch = self.src[self.pos];
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                self.pos += 1;
            } else if (ch == ';') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') : (self.pos += 1) {}
            } else {
                break;
            }
        }
    }

    pub fn readExpr(self: *Reader) EvalError!?u16 {
        self.skipWhitespaceAndComments();
        if (self.pos >= self.src.len) return null;

        const ch = self.src[self.pos];
        if (ch == ')') return error.SyntaxError;

        if (ch == '(') {
            self.pos += 1;
            return try self.readList();
        }

        if (ch == '\'') {
            self.pos += 1;
            const quoted = (try self.readExpr()) orelse return error.UnexpectedEof;
            const nil_idx = try self.arena.allocNode(.{ .nil = {} });
            const tail_idx = try self.arena.cons(quoted, nil_idx);
            const quote_sym = try self.arena.allocNode(.{ .symbol = "quote" });
            return try self.arena.cons(quote_sym, tail_idx);
        }

        if (ch == '"') {
            return try self.readString();
        }

        // Token: keyword (`#:...`), boolean (`#t`, `#f`), integer, or symbol
        const start = self.pos;
        while (self.pos < self.src.len and !isDelimiter(self.src[self.pos])) : (self.pos += 1) {}
        const tok = self.src[start..self.pos];
        if (tok.len == 0) return error.SyntaxError;

        if (std.mem.eql(u8, tok, "#t")) return try self.arena.allocNode(.{ .boolean = true });
        if (std.mem.eql(u8, tok, "#f")) return try self.arena.allocNode(.{ .boolean = false });
        if (std.mem.startsWith(u8, tok, "#:")) {
            if (tok.len <= 2) return error.SyntaxError;
            return try self.arena.allocNode(.{ .keyword = tok[2..] });
        }
        if (std.mem.startsWith(u8, tok, "#x")) return try self.arena.allocNode(.{ .int = std.fmt.parseInt(i64, tok[2..], 16) catch return error.SyntaxError });
        if (std.fmt.parseInt(i64, tok, 10)) |num| {
            return try self.arena.allocNode(.{ .int = num });
        } else |_| {}

        return try self.arena.allocNode(.{ .symbol = tok });
    }

    fn readList(self: *Reader) EvalError!u16 {
        var items: [64]u16 = undefined;
        var count: usize = 0;

        while (true) {
            self.skipWhitespaceAndComments();
            if (self.pos >= self.src.len) return error.UnexpectedEof;
            if (self.src[self.pos] == ')') {
                self.pos += 1;
                break;
            }
            if (count >= items.len) return error.ArenaFull;
            const elem = (try self.readExpr()) orelse return error.UnexpectedEof;
            items[count] = elem;
            count += 1;
        }

        var list_idx = try self.arena.allocNode(.{ .nil = {} });
        var i: usize = count;
        while (i > 0) {
            i -= 1;
            list_idx = try self.arena.cons(items[i], list_idx);
        }
        return list_idx;
    }

    fn readString(self: *Reader) EvalError!u16 {
        self.pos += 1; // skip opening '"'
        var tmp: [512]u8 = undefined;
        var len: usize = 0;

        while (self.pos < self.src.len) {
            const ch = self.src[self.pos];
            self.pos += 1;
            if (ch == '"') {
                const stored = try self.arena.allocString(tmp[0..len]);
                return try self.arena.allocNode(.{ .string = stored });
            }
            if (ch == '\\') {
                if (self.pos >= self.src.len) return error.UnexpectedEof;
                const esc = self.src[self.pos];
                self.pos += 1;
                const decoded: u8 = switch (esc) {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    '"' => '"',
                    '\\' => '\\',
                    else => esc,
                };
                if (len >= tmp.len) return error.ArenaFull;
                tmp[len] = decoded;
                len += 1;
            } else {
                if (len >= tmp.len) return error.ArenaFull;
                tmp[len] = ch;
                len += 1;
            }
        }
        return error.UnexpectedEof;
    }
};

// ============================================================================
// Versioned `sys_config` + `sqld` Declarative Query Bridge
// ============================================================================

pub const view_config = @import("view_config");
pub const ConfigSnapshot = struct {
    appearance: view_config.Appearance = .{},
    generation: u32 = 1,
    style: ViewStyle = .{},
};

pub const SqlQueryRequest = struct {
    table: []const u8,
    where_clause: []const u8 = "",
    limit: u16 = 16,
};

pub const SqlQueryHook = *const fn (
    ctx: *anyopaque,
    req: SqlQueryRequest,
    arena: *SexpArena,
) EvalError!Value;

pub const CustomPrefixBinding = struct {
    prefix_char: u8 = 0,
    expansion_buf: [64]u8 = @splat(0),
    expansion_len: u8 = 0,
    active: bool = false,
};

// ============================================================================
// Unified `XyWorkspace`: Document + ViewStyle + OmniIme + Scheme Evaluator
// ============================================================================

pub fn XyWorkspace(
    comptime max_doc_bytes: usize,
    comptime max_undo_ops: usize,
    comptime max_undo_bytes: usize,
    comptime max_ruby_spans: usize,
    comptime max_ruby_bytes: usize,
) type {
    return struct {
        const Self = @This();
        pub const DocType = document.Document(
            max_doc_bytes,
            max_undo_ops,
            max_undo_bytes,
            max_ruby_spans,
            max_ruby_bytes,
        );

        doc: DocType = .{},
        style: ViewStyle = .{},
        appearance: view_config.Appearance = .{},
        ime: ime_omni.OmniIme = .{},
        arena: SexpArena = .{},

        /// Set to `true` whenever `style` or `doc` changes so the host knows to re-layout.
        layout_dirty: bool = true,

        /// Transactional `sys_config` generation history (supports instant rollback).
        config_generation: u32 = 1,
        config_history: [8]ConfigSnapshot = @splat(.{}),
        config_history_count: u8 = 0,

        /// Custom prefix expansions registered from Scheme via `(ime/register-prefix! "#" "...")`.
        custom_bindings: [8]CustomPrefixBinding = @splat(.{}),

        /// Optional `sqld` query hook for `(q 'table #:where ... #:limit ...)` and non-Scheme omni queries.
        sql_ctx: ?*anyopaque = null,
        sql_query_hook: ?SqlQueryHook = null,
        ext_omni_provider: ?ime_omni.OmniProvider = null,

        fn pushConfigSnapshot(self: *Self) void {
            if (self.config_history_count < self.config_history.len) {
                self.config_history[self.config_history_count] = .{
                    .generation = self.config_generation,
                    .style = self.style,
                    .appearance = self.appearance,
                };
                self.config_history_count += 1;
            } else {
                std.mem.copyForwards(
                    ConfigSnapshot,
                    self.config_history[0 .. self.config_history.len - 1],
                    self.config_history[1..self.config_history.len],
                );
                self.config_history[self.config_history.len - 1] = .{
                    .generation = self.config_generation,
                    .style = self.style,
                    .appearance = self.appearance,
                };
            }
            self.config_generation +%= 1;
            if (self.config_generation == 0) self.config_generation = 1;
        }

        /// Roll back `sys_config` to the previous generation and restore `ViewStyle`.
        pub fn rollbackConfig(self: *Self) EvalError!u32 {
            if (self.config_history_count == 0) return error.NoPreviousConfigGeneration;
            self.config_history_count -= 1;
            const snap = self.config_history[self.config_history_count];
            self.style = snap.style;
            self.appearance = snap.appearance;
            self.config_generation = snap.generation;
            self.layout_dirty = true;
            return self.config_generation;
        }

        /// Evaluate one or more S-expressions in `source` against this workspace.
        pub fn evalStr(self: *Self, source: []const u8) EvalError!Value {
            self.arena.reset();
            var reader = Reader{
                .src = source,
                .arena = &self.arena,
            };
            var last_val: Value = .{ .nil = {} };
            while (try reader.readExpr()) |expr_idx| {
                last_val = try self.evalNode(expr_idx);
            }
            return last_val;
        }

        fn evalNode(self: *Self, idx: u16) EvalError!Value {
            const val = self.arena.nodes[idx];
            return switch (val) {
                .nil, .boolean, .int, .keyword, .string => val,
                .symbol => |sym| blk: {
                    if (std.mem.eql(u8, sym, "*config-generation*")) {
                        break :blk .{ .int = @intCast(self.config_generation) };
                    }
                    break :blk val;
                },
                .pair => |cell| try self.evalList(cell),
            };
        }

        fn collectArgs(self: *const Self, cdr_idx: u16, out: *[32]u16) EvalError!usize {
            var count: usize = 0;
            var cur = cdr_idx;
            while (true) {
                switch (self.arena.nodes[cur]) {
                    .nil => break,
                    .pair => |c| {
                        if (count >= out.len) return error.ArenaFull;
                        out[count] = c.car;
                        count += 1;
                        cur = c.cdr;
                    },
                    else => return error.SyntaxError,
                }
            }
            return count;
        }

        fn evalSymbolOrSelf(self: *Self, idx: u16) EvalError![]const u8 {
            const v = try self.evalNode(idx);
            return switch (v) {
                .symbol, .string, .keyword => |s| s,
                else => error.TypeMismatch,
            };
        }

        fn evalInt(self: *Self, idx: u16) EvalError!i64 {
            const v = try self.evalNode(idx);
            return switch (v) {
                .int => |n| n,
                else => error.TypeMismatch,
            };
        }

        fn evalList(self: *Self, cell: PairCell) EvalError!Value {
            const head_node = self.arena.nodes[cell.car];
            const op = switch (head_node) {
                .symbol => |s| s,
                else => return error.SyntaxError,
            };

            var arg_idxs: [32]u16 = undefined;
            const argc = try self.collectArgs(cell.cdr, &arg_idxs);
            const args = arg_idxs[0..argc];

            // 1. Special form: `(quote x)`
            if (std.mem.eql(u8, op, "quote")) {
                if (args.len != 1) return error.ArityMismatch;
                return self.arena.nodes[args[0]];
            }

            // 2. Special form: `(begin e1 e2 ...)`
            if (std.mem.eql(u8, op, "begin")) {
                var last: Value = .{ .nil = {} };
                for (args) |a| {
                    last = try self.evalNode(a);
                }
                return last;
            }

            // 3. Arithmetic & String primitives: `+`, `-`, `*`, `=`, `string-append`
            if (std.mem.eql(u8, op, "+")) {
                var sum: i64 = 0;
                for (args) |a| sum += try self.evalInt(a);
                return .{ .int = sum };
            }
            if (std.mem.eql(u8, op, "-")) {
                if (args.len == 0) return error.ArityMismatch;
                var acc = try self.evalInt(args[0]);
                if (args.len == 1) return .{ .int = -acc };
                for (args[1..]) |a| acc -= try self.evalInt(a);
                return .{ .int = acc };
            }
            if (std.mem.eql(u8, op, "*")) {
                var prod: i64 = 1;
                for (args) |a| prod *= try self.evalInt(a);
                return .{ .int = prod };
            }
            if (std.mem.eql(u8, op, "=")) {
                if (args.len != 2) return error.ArityMismatch;
                const a = try self.evalInt(args[0]);
                const b = try self.evalInt(args[1]);
                return .{ .boolean = (a == b) };
            }
            if (std.mem.eql(u8, op, "string-append")) {
                var tmp: [512]u8 = undefined;
                var pos: usize = 0;
                for (args) |a| {
                    const s = try self.evalSymbolOrSelf(a);
                    appendSlice(&tmp, &pos, s);
                }
                const stored = try self.arena.allocString(tmp[0..pos]);
                return .{ .string = stored };
            }

            // 4. Live Viewport & Typography control: `(view/set! #:font ... #:size ... #:direction ... #:line-gap ...)`
            if (std.mem.eql(u8, op, "view/set!")) {
                if (args.len == 0 or args.len % 2 != 0) return error.ArityMismatch;
                var next = view_config.Config{ .style = self.style, .appearance = self.appearance };
                var i: usize = 0;
                while (i < args.len) : (i += 2) {
                    const key_name = try self.evalSymbolOrSelf(args[i]);
                    const val = try self.evalNode(args[i + 1]);
                    const value: view_config.Value = switch (val) {
                        .int => |n| .{ .number = std.math.cast(i32, n) orelse return error.TypeMismatch },
                        .symbol, .string => |name| .{ .symbol = name },
                        .boolean => |yes| .{ .boolean = yes },
                        else => return error.TypeMismatch,
                    };
                    next.set(key_name, value) catch return error.TypeMismatch;
                }
                next.validate() catch return error.TypeMismatch;
                self.pushConfigSnapshot();
                self.style = next.style;
                self.appearance = next.appearance;
                self.layout_dirty = true;
                return .{ .int = @intCast(self.config_generation) };
            }

            if (std.mem.eql(u8, op, "view/get")) {
                if (args.len != 1) return error.ArityMismatch;
                const key_name = try self.evalSymbolOrSelf(args[0]);
                const config = view_config.Config{ .style = self.style, .appearance = self.appearance };
                const value = config.get(key_name) catch return error.UnknownForm;
                return switch (value) {
                    .number => |n| .{ .int = n },
                    .symbol => |name| .{ .symbol = name },
                    .boolean => |yes| .{ .boolean = yes },
                };
            }

            // 5. Transactional OS Config rollback: `(sys/config-rollback!)`
            if (std.mem.eql(u8, op, "sys/config-rollback!")) {
                const gen = try self.rollbackConfig();
                return .{ .int = @intCast(gen) };
            }

            // 6. Document & Ruby primitives (`buffer/...`)
            if (std.mem.eql(u8, op, "buffer/insert!")) {
                if (args.len != 1) return error.ArityMismatch;
                const text = try self.evalSymbolOrSelf(args[0]);
                try self.doc.insertUtf8(text);
                self.layout_dirty = true;
                return .{ .int = @intCast(self.doc.cursor) };
            }
            if (std.mem.eql(u8, op, "buffer/clear!")) {
                self.doc.clear();
                self.layout_dirty = true;
                return .{ .nil = {} };
            }
            if (std.mem.eql(u8, op, "buffer/move-graphemes!")) {
                if (args.len != 1) return error.ArityMismatch;
                const delta: i32 = @intCast(try self.evalInt(args[0]));
                const pos = try self.doc.moveGraphemes(delta);
                return .{ .int = @intCast(pos) };
            }
            if (std.mem.eql(u8, op, "buffer/delete-backward!")) {
                const deleted = try self.doc.deleteBackwardGrapheme();
                self.layout_dirty = true;
                return .{ .boolean = deleted };
            }
            if (std.mem.eql(u8, op, "buffer/add-ruby!")) {
                if (args.len != 3) return error.ArityMismatch;
                const start: u32 = @intCast(try self.evalInt(args[0]));
                const end: u32 = @intCast(try self.evalInt(args[1]));
                const reading = try self.evalSymbolOrSelf(args[2]);
                try self.doc.addRuby(start, end, reading);
                self.layout_dirty = true;
                return .{ .int = @intCast(self.doc.ruby_count) };
            }
            if (std.mem.eql(u8, op, "buffer/undo!")) {
                const ok = try self.doc.undo();
                self.layout_dirty = true;
                return .{ .boolean = ok };
            }
            if (std.mem.eql(u8, op, "buffer/with-undo-group")) {
                _ = self.doc.beginUndoGroup();
                defer self.doc.endUndoGroup();
                var last: Value = .{ .nil = {} };
                for (args) |a| {
                    last = try self.evalNode(a);
                }
                self.layout_dirty = true;
                return last;
            }
            if (std.mem.eql(u8, op, "buffer/text")) {
                return .{ .string = self.doc.slice() };
            }
            if (std.mem.eql(u8, op, "buffer/cursor")) {
                return .{ .int = @intCast(self.doc.cursor) };
            }

            // 7. Declarative SQLite query: `(q 'table #:where "..." #:limit N)`
            if (std.mem.eql(u8, op, "q")) {
                if (args.len < 1) return error.ArityMismatch;
                const table_name = try self.evalSymbolOrSelf(args[0]);
                var req = SqlQueryRequest{ .table = table_name };
                var i: usize = 1;
                while (i + 1 < args.len) : (i += 2) {
                    const kw = try self.evalSymbolOrSelf(args[i]);
                    if (std.mem.eql(u8, kw, "where")) {
                        req.where_clause = try self.evalSymbolOrSelf(args[i + 1]);
                    } else if (std.mem.eql(u8, kw, "limit")) {
                        req.limit = @intCast(std.math.clamp(try self.evalInt(args[i + 1]), 1, 256));
                    }
                }
                if (self.sql_query_hook) |hook| {
                    return try hook(self.sql_ctx.?, req, &self.arena);
                }
                return .{ .nil = {} };
            }

            // 8. SKK Omni-Completion custom prefix registration: `(ime/register-prefix! "#" "expansion")`
            if (std.mem.eql(u8, op, "ime/register-prefix!")) {
                if (args.len != 2) return error.ArityMismatch;
                const prefix_str = try self.evalSymbolOrSelf(args[0]);
                const expansion = try self.evalSymbolOrSelf(args[1]);
                if (prefix_str.len != 1 or expansion.len > 64) return error.TypeMismatch;
                const p_ch = prefix_str[0];
                if (!self.ime.registerCustomPrefix(p_ch)) return error.ArenaFull;
                for (&self.custom_bindings) |*slot| {
                    if (!slot.active or slot.prefix_char == p_ch) {
                        slot.active = true;
                        slot.prefix_char = p_ch;
                        @memcpy(slot.expansion_buf[0..expansion.len], expansion);
                        slot.expansion_len = @intCast(expansion.len);
                        break;
                    }
                }
                return .{ .boolean = true };
            }

            return error.UnknownForm;
        }

        // ====================================================================
        // Integrated `OmniProvider` routing `▽(...)` to `evalStr` and others to `ext_omni_provider`
        // ====================================================================

        fn workspaceOmniQuery(
            ctx: *anyopaque,
            kind: ime_omni.PrefixKind,
            prefix_char: u8,
            query_key: []const u8,
            out: *ime_omni.CandidateList,
        ) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (kind == .scheme) {
                const val = self.evalStr(query_key) catch return;
                var buf: [256]u8 = undefined;
                const text = self.arena.valueToInsertText(val, &buf);
                _ = out.append(text, "Scheme eval");
                return;
            }
            if (kind == .custom) {
                for (self.custom_bindings) |slot| {
                    if (slot.active and slot.prefix_char == prefix_char) {
                        _ = out.append(slot.expansion_buf[0..slot.expansion_len], query_key);
                        return;
                    }
                }
            }
            if (self.ext_omni_provider) |ext| {
                ext.queryFn(ext.ctx, kind, prefix_char, query_key, out);
            }
        }

        fn workspaceOmniLearn(ctx: *anyopaque, query_key: []const u8, committed_stem: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.ext_omni_provider) |ext| {
                if (ext.learnFn) |learn| {
                    learn(ext.ctx, query_key, committed_stem);
                }
            }
        }

        pub fn omniProvider(self: *Self) ime_omni.OmniProvider {
            return .{
                .ctx = self,
                .queryFn = workspaceOmniQuery,
                .learnFn = workspaceOmniLearn,
            };
        }

        /// Feed a key event into the workspace's `OmniIme` (with live Scheme evaluation & `sqld` lookup).
        pub fn handleKey(self: *Self, key: u8) !void {
            const rev_before = self.doc.revision;
            try self.ime.handleKey(&self.doc, self.omniProvider(), key);
            if (self.doc.revision != rev_before) {
                self.layout_dirty = true;
            }
        }

        /// Produce the C-ABI `PlacedGlyph` Display List for the current `Document` + `ViewStyle`,
        /// using the 2-tier outline/bitmap cache (`TwoTierCache`) so live `(view/set! ...)`
        /// size and orientation changes execute with zero SD card reads on cached glyphs.
        pub fn renderDisplayList(
            self: *Self,
            comptime max_lines: usize,
            comptime max_body_glyphs: usize,
            comptime max_ruby_glyphs: usize,
            comptime CacheType: type,
            cache: *CacheType,
            family: viewport_layout.ttf.Family,
            glyph_scratch: []u8,
            out_placed: []PlacedGlyph,
        ) viewport_layout.Error![]const PlacedGlyph {
            var ann_buf: [max_ruby_spans]viewport_layout.ruby.Annotation = undefined;
            for (self.doc.ruby_spans[0..self.doc.ruby_count], 0..) |s, idx| {
                ann_buf[idx] = .{
                    .base = .{ .start = s.base_start, .end = s.base_end },
                    .ruby = .{ .start = s.ruby_start, .end = s.ruby_end },
                };
            }
            const placed = try viewport_layout.layoutParagraph(
                max_lines,
                max_body_glyphs,
                max_ruby_glyphs,
                CacheType,
                cache,
                family,
                self.style,
                self.doc.slice(),
                self.doc.ruby_arena[0..self.doc.ruby_bytes_used],
                ann_buf[0..self.doc.ruby_count],
                glyph_scratch,
                out_placed,
            );
            self.layout_dirty = false;
            return placed;
        }
    };
}

// ============================================================================
// Unit Tests
// ============================================================================

fn mockSqlHook(ctx: *anyopaque, req: SqlQueryRequest, arena: *SexpArena) EvalError!Value {
    _ = ctx;
    if (std.mem.eql(u8, req.table, "gjs") and std.mem.eql(u8, req.where_clause, "葛")) {
        const s1 = try arena.allocNode(.{ .string = "MJ023642:葛\u{E0100}" });
        const s2 = try arena.allocNode(.{ .string = "MJ023643:葛\u{E0101}" });
        const nil_idx = try arena.allocNode(.{ .nil = {} });
        const l2 = try arena.cons(s2, nil_idx);
        const l1 = try arena.cons(s1, l2);
        return arena.nodes[l1];
    }
    return .{ .nil = {} };
}

test "Scheme (view/set! ...) live-switches font, size, and vertical orientation with config rollback" {
    const WsType = XyWorkspace(2048, 32, 512, 16, 256);
    var ws: WsType = .{};

    // Initial defaults: Bunsen Mincho (0), 24px, horizontal (0)
    try std.testing.expectEqual(@as(u8, 0), ws.style.style_id);
    try std.testing.expectEqual(@as(u8, 24), ws.style.body_px);
    try std.testing.expectEqual(@as(u8, 0), ws.style.axis);

    // Live-switch via S-expression to Bunsen Gothic, 32px, vertical typesetting!
    const gen_val = try ws.evalStr("(view/set! #:font 'bunsen-gothic #:size 32 #:direction 'vertical #:line-gap 16)");
    try std.testing.expectEqual(@as(i64, 2), gen_val.int);
    try std.testing.expectEqual(@as(u8, 1), ws.style.style_id);
    try std.testing.expectEqual(@as(u8, 32), ws.style.body_px);
    try std.testing.expectEqual(@as(u8, 16), ws.style.ruby_px);
    try std.testing.expectEqual(@as(u8, 1), ws.style.axis);
    try std.testing.expectEqual(@as(u8, 16), ws.style.line_gap_px);
    try std.testing.expect(ws.layout_dirty);

    // Query back via `(view/get ...)`
    const dir_val = try ws.evalStr("(view/get #:direction)");
    try std.testing.expectEqualStrings("vertical", dir_val.symbol);

    // Roll back `sys_config` to generation 1 and verify restoration of 24px horizontal Mincho
    const rb_val = try ws.evalStr("(sys/config-rollback!)");
    try std.testing.expectEqual(@as(i64, 1), rb_val.int);
    try std.testing.expectEqual(@as(u8, 0), ws.style.style_id);
    try std.testing.expectEqual(@as(u8, 24), ws.style.body_px);
    try std.testing.expectEqual(@as(u8, 0), ws.style.axis);
}

test "Scheme buffer editing, IVS grapheme safety, atomic undo group, and SKK live (eval)" {
    const WsType = XyWorkspace(2048, 32, 512, 16, 256);
    var ws: WsType = .{};
    var dummy_ctx: u8 = 0;
    ws.sql_ctx = &dummy_ctx;
    ws.sql_query_hook = mockSqlHook;

    // 1. Atomic multi-step edit via `(buffer/with-undo-group ...)`
    _ = try ws.evalStr(
        \\(buffer/with-undo-group
        \\  (buffer/insert! "葛\u{E0100}飾北斎")
        \\  (buffer/add-ruby! 0 10 "かつしか"))
    );
    // Note: in S-expression string literal above, let's insert actual UTF-8 IVS via buffer/insert!
    ws.doc.clear();
    _ = try ws.evalStr(
        "(buffer/with-undo-group (buffer/insert! \"葛\u{E0100}飾\") (buffer/insert! \"北斎\") (buffer/add-ruby! 0 10 \"かつしか\"))",
    );
    try std.testing.expectEqualStrings("葛\u{E0100}飾北斎", ws.doc.slice());
    try std.testing.expectEqual(@as(u32, 1), ws.doc.ruby_count);

    // Move left by 2 graphemes ("北", "斎") -> lands at byte 10, then 1 more ("飾") -> lands at byte 7 (right after "葛\u{E0100}")
    const cur_pos = try ws.evalStr("(buffer/move-graphemes! -3)");
    try std.testing.expectEqual(@as(i64, 7), cur_pos.int);

    // Single `(buffer/undo!)` reverts the entire `buffer/with-undo-group` transaction!
    const undone = try ws.evalStr("(buffer/undo!)");
    try std.testing.expect(undone.boolean);
    try std.testing.expectEqualStrings("", ws.doc.slice());

    // 2. Live SKK Program Conversion `▽(+ 100 28)` -> evaluates inside `ws` and commits `"128"`!
    for ("(+ 100 28) \n") |ch| {
        try ws.handleKey(ch);
    }
    try std.testing.expectEqualStrings("128", ws.doc.slice());

    // 3. Live SKK `(view/set! #:size 36)` from inside `▽(...)`!
    ws.doc.clear();
    for ("(view/set! #:size 36) \n") |ch| {
        try ws.handleKey(ch);
    }
    try std.testing.expectEqual(@as(u8, 36), ws.style.body_px);

    // 4. Declarative `(q 'gjs #:where "葛" #:limit 2)` query to `sqld`
    const q_res = try ws.evalStr("(q 'gjs #:where \"葛\" #:limit 2)");
    var fmt_buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "(\"MJ023642:葛\u{E0100}\" \"MJ023643:葛\u{E0101}\")",
        ws.arena.formatValue(q_res, &fmt_buf),
    );
}

test "End-to-end 5-module integration: Scheme live-switches horizontal to vertical Display List with zero outline misses" {
    const ttf = viewport_layout.ttf;
    const WsType = XyWorkspace(2048, 32, 512, 16, 256);
    var ws: WsType = .{};

    var font_buf: [512]u8 = undefined;
    const bytes = viewport_layout.ttf_test_helper(&font_buf);
    const face = try ttf.Face.init(ttf.SliceReader.fromSlice(&bytes));
    const family = ttf.Family{ .faces = &[_]ttf.Face{face} };

    const CacheType = ttf.TwoTierCache(16, 64, 32, 64 * 64);
    var cache: CacheType = .{};
    var scratch: [256]u8 = undefined;
    var dl: [32]PlacedGlyph = undefined;

    // 1. Populate document + ruby via Scheme S-expression
    _ = try ws.evalStr(
        "(begin (buffer/insert! \"葛\u{E0100}か\") (buffer/add-ruby! 0 7 \"かつ\"))",
    );

    // 2. Render horizontal Display List (default 24px)
    const list_h = try ws.renderDisplayList(32, 64, 64, CacheType, &cache, family, &scratch, &dl);
    try std.testing.expectEqual(@as(usize, 4), list_h.len);
    try std.testing.expect(!ws.layout_dirty);
    const misses_after_h = cache.outline_misses;

    // 3. Evaluate `(view/set! #:size 32 #:direction 'vertical)` and re-render Display List
    _ = try ws.evalStr("(view/set! #:size 32 #:direction 'vertical)");
    try std.testing.expect(ws.layout_dirty);
    const list_v = try ws.renderDisplayList(32, 64, 64, CacheType, &cache, family, &scratch, &dl);
    try std.testing.expectEqual(@as(usize, 4), list_v.len);
    try std.testing.expectEqual(misses_after_h, cache.outline_misses); // Zero new SD/outline fetches!
    try std.testing.expect(list_v[1].cell_y_px > list_v[0].cell_y_px); // Vertical downward flow
    try std.testing.expect(list_v[2].cell_x_px > list_v[0].cell_x_px); // Ruby on the right side
}

test "appearance changes and rollback are atomic with typography" {
    var ws: XyWorkspace(256, 8, 128, 2, 64) = .{};
    _ = try ws.evalStr("(view/set! #:foreground #x234567 #:size 36 #:cursor-width 4)");
    try std.testing.expectEqual(@as(u32, 0x234567), ws.appearance.foreground);
    try std.testing.expectError(error.TypeMismatch, ws.evalStr("(view/set! #:background 0 #:size 0)"));
    try std.testing.expectEqual(@as(u32, 0xfaf6ee), ws.appearance.background);
    try std.testing.expectEqual(@as(u32, 2), ws.config_generation);
    _ = try ws.evalStr("(sys/config-rollback!)");
    try std.testing.expectEqual(@as(u8, 24), ws.style.body_px);
    try std.testing.expectEqual(@as(u32, 0x1c1c1e), ws.appearance.foreground);
}
