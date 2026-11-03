//! Bounded integer Scheme subset for editor extensions. No allocator or I/O.
//! Lexical closures persist across requests; mark/sweep runs between requests.
//! Not R7RS: no proper tail calls, macros, continuations, modules or exact tower.
const std = @import("std");
const decimal = @import("scheme_decimal.zig");
extern fn nih_xy_decimal_parse([*]const u8, usize, *u64) callconv(.c) i32;
extern fn nih_xy_decimal_format(u64, [*]u8, usize) callconv(.c) i32;
pub const code_section = if (@import("builtin").os.tag == .freestanding) ".flash.xytext" else if (@import("builtin").object_format == .macho) "__TEXT,__text" else ".text";
pub const data_section = if (@import("builtin").os.tag == .freestanding) ".flash.xyrodata" else if (@import("builtin").object_format == .macho) "__TEXT,__const" else ".rodata";
pub const view_config = @import("view_config");
pub const plot_config = @import("plot_config.zig");
pub const frame_step_limit = 256;
pub const frame_cell_reserve = 64;
pub const camera = @import("camera.zig");
pub const card = @import("card.zig");
pub const storage = @import("storage.zig");
pub const Error = storage.Error || camera.Error || card.Error || error{ Syntax, Depth, Budget, HeapFull, TextFull, Type, Arity, Unbound, Overflow, DivisionByZero, UnknownCommand, CommandFull, EditorFailure, Busy, AppUnavailable, CannotCompile };
pub const Ref = u16;
pub const cells = 4096;
comptime {
    if (cells > 0x4000) @compileError("heap references overlap immediate opcodes");
}
pub const text_bytes = 128;
pub const text_storage_bytes = 4096;
pub const depth_limit = 24;
pub const step_limit = 8192;
pub const EditorOp = enum { insert, move, undo, forget, log, memory, tasks };
const Tag = enum { free, nil, integer, boolean, symbol, string, pair, closure, native, keyword, rational, inexact };
const Op = enum(u8) { quote, if_, begin, define, lambda, set, let, let_star, letrec, letrec_star, and_, or_, cond, quasiquote, unquote, unquote_splicing, add, sub, mul, equal, less, greater, less_equal, greater_equal, cons, car, cdr, list, nullq, pairq, not, register, insert, move, undo, forget, log, memory, tasks, view_set, view_get, view_rollback, camera_capture, camera_info, camera_read, sql_query, sql_exec, sql_begin, sql_commit, sql_rollback, fs_open, fs_read, fs_write, fs_resize, fs_remove, fs_sync, fs_rollback, fs_snapshot, fs_restore, fs_release, fs_collect, fs_generation, fs_list, fs_close, fs_stat, fs_begin, sql_lookup, sql_check, fs_space, fs_verify, buffer_save, buffer_load, buffer_text, app_frame, app_pause, app_resume, app_stop, app_speed, app_ticks, plot_set, plot_get, plot_sine, card_read, card_info, card_dismiss, view_card, divide, apply_proc, length_proc, reverse_proc, append_proc, listq, numberq, complexq, realq, rationalq, integerq, exactq, inexactq, inexact_proc, exact_proc, abs_proc, floor_proc, ceiling_proc, truncate_proc, round_proc, zeroq, positiveq, negativeq, oddq, evenq, exact_integerq, finiteq, infiniteq, nanq, quotient_proc, remainder_proc, modulo_proc, floor_quotient_proc, floor_remainder_proc, truncate_quotient_proc, truncate_remainder_proc, gcd_proc, lcm_proc, numerator_proc, denominator_proc, square_proc, min_proc, max_proc, expt_proc, map_proc, eq_proc, eqv_proc, equal_proc, memq_proc, memv_proc, member_proc, cadr_proc, set_car_proc, set_cdr_proc, symbolq, stringq, booleanq, procedureq, for_each_proc, list_ref_proc, list_tail_proc, assoc_proc, assq_proc, assv_proc, caar_proc, cdar_proc, cddr_proc, caddr_proc, caadr_proc, cdadr_proc, cdddr_proc, cadddr_proc };
const vocabulary linksection(data_section) = "quote\x00if\x00begin\x00define\x00lambda\x00set!\x00let\x00let*\x00letrec\x00letrec*\x00and\x00or\x00cond\x00quasiquote\x00unquote\x00unquote-splicing\x00+\x00-\x00*\x00=\x00<\x00>\x00<=\x00>=\x00cons\x00car\x00cdr\x00list\x00null?\x00pair?\x00not\x00command/register!\x00buffer/insert!\x00buffer/move-graphemes!\x00buffer/undo!\x00buffer/forget-undo!\x00system/log\x00system/memory\x00system/tasks\x00view/set!\x00view/get\x00sys/config-rollback!\x00camera/capture!\x00camera/info\x00camera/read\x00sql/query\x00sql/exec!\x00sql/begin!\x00sql/commit!\x00sql/rollback!\x00fs/open\x00fs/read\x00fs/write!\x00fs/truncate!\x00fs/remove!\x00fs/sync!\x00fs/rollback!\x00fs/snapshot\x00fs/restore!\x00fs/release!\x00fs/collect!\x00fs/generation\x00fs/list\x00fs/close!\x00fs/stat\x00fs/begin!\x00q\x00sql/check\x00fs/space\x00fs/verify\x00buffer/save!\x00buffer/load!\x00buffer/text\x00app/on-frame!\x00app/pause!\x00app/resume!\x00app/stop!\x00app/speed!\x00app/ticks\x00plot/set!\x00plot/get\x00plot/sine\x00card/read!\x00card/info\x00card/dismiss!\x00view/card!\x00/\x00apply\x00length\x00reverse\x00append\x00list?\x00number?\x00complex?\x00real?\x00rational?\x00integer?\x00exact?\x00inexact?\x00inexact\x00exact\x00abs\x00floor\x00ceiling\x00truncate\x00round\x00zero?\x00positive?\x00negative?\x00odd?\x00even?\x00exact-integer?\x00finite?\x00infinite?\x00nan?\x00quotient\x00remainder\x00modulo\x00floor-quotient\x00floor-remainder\x00truncate-quotient\x00truncate-remainder\x00gcd\x00lcm\x00numerator\x00denominator\x00square\x00min\x00max\x00expt\x00map\x00eq?\x00eqv?\x00equal?\x00memq\x00memv\x00member\x00cadr\x00set-car!\x00set-cdr!\x00symbol?\x00string?\x00boolean?\x00procedure?\x00for-each\x00list-ref\x00list-tail\x00assoc\x00assq\x00assv\x00caar\x00cdar\x00cddr\x00caddr\x00caadr\x00cdadr\x00cdddr\x00cadddr\x00".*;
const plot_names linksection(data_section) = "amplitude\x00phase\x00color1\x00color2\x00".*;
pub const eval_stack_size = 128;
const int_bias: i32 = 16384;
// An invalid immediate opcode is an internal marker for recursive bindings.
const uninitialized_binding: Ref = 0x40ff;
comptime {
    if (@typeInfo(Op).@"enum".field_names.len >= 256) @compileError("recursive binding marker overlaps an opcode");
}

inline fn isImmediateInt(r: Ref) bool {
    return (r & 0x8000) != 0;
}
inline fn makeImmediateInt(n: i32) Ref {
    return @as(u16, @intCast(n + int_bias)) | 0x8000;
}
inline fn toImmediateInt(r: Ref) i32 {
    return @as(i32, r & 0x7FFF) - int_bias;
}
inline fn isImmediateOp(r: Ref) bool {
    return (r & 0xFF00) == 0x4000;
}
inline fn makeImmediateOp(op: Op) Ref {
    return 0x4000 | @as(u16, @backingInt(op));
}
inline fn decodeImmediateOp(comptime E: type, r: Ref) E {
    return @fromBackingInt(@intCast(@as(u8, @truncate(r & 0x00ff))));
}
inline fn toImmediateOp(r: Ref) Op {
    return decodeImmediateOp(Op, r);
}
inline fn isImmediate(r: Ref) bool {
    return (r & 0x8000) != 0 or (r & 0xFF00) == 0x4000;
}

pub const bytecode_capacity = 384;
pub const call_stack_capacity = 32;
pub const ast_root_frame_capacity = 96;

// Suspended AST expressions and their intermediate values are explicit roots.
// These frames do not yet represent native callbacks or enable arbitrary GC.
const AstRootFrame = struct {
    expression: Ref = 0,
    environment: Ref = 0,
    auxiliary: Ref = 0,
    values: [16]Ref = @splat(0),
    value_count: u8 = 0,
};

pub const BcOp = enum(u8) {
    const_val,
    pop,
    dup,
    load_local,
    store_local,
    load_global,
    def_global,
    jump,
    jump_if_false,
    add,
    sub,
    mul,
    equal,
    less,
    not,
    cons,
    car,
    cdr,
    null_p,
    pair_p,
    call,
    ret,
    halt,
};

pub fn toBcOp(raw: u8) linksection(code_section) ?BcOp {
    if (raw > @backingInt(BcOp.halt)) return null;
    return @fromBackingInt(raw);
}

pub const CallFrame = struct {
    return_ip: u16,
    fp: u8,
    env: Ref,
};

// The tag determines which fields are live: pair/closure references, text
// length/offset, and number bits never coexist. Keep the shared metadata
// behind these accessors so GC and the evaluator cannot mix their meanings.
const Cell = struct {
    tag: Tag,
    mark: bool,
    a: Ref,
    b: Ref,
    env: Ref,
    integer: i32,

    inline fn isText(self: *const Cell) bool {
        return self.tag == .symbol or self.tag == .keyword or self.tag == .string;
    }
    inline fn textLen(self: *const Cell) u16 {
        std.debug.assert(self.isText());
        return self.a;
    }
    inline fn textOffset(self: *const Cell) u16 {
        std.debug.assert(self.isText());
        return self.env;
    }
    inline fn setText(self: *Cell, len: u16, offset: u16) void {
        std.debug.assert(self.isText() and len <= text_bytes);
        self.a = len;
        self.env = offset;
    }
    inline fn setTextOffset(self: *Cell, offset: u16) void {
        std.debug.assert(self.isText());
        self.env = offset;
    }
    inline fn flagged(self: *const Cell) bool {
        std.debug.assert(self.tag == .pair or self.tag == .closure);
        return self.integer != 0;
    }
    inline fn setFlag(self: *Cell) void {
        std.debug.assert(self.tag == .pair or self.tag == .closure);
        self.integer = 1;
    }
};
const Command = struct { name: Ref, procedure: Ref };

pub const Runtime = struct {
    heap: [cells]Cell,
    text_storage: [text_storage_bytes]u8,
    text_used: u16,
    queue: [cells]Ref,
    // Reused only during equality; Runtime lives in xy's PSRAM workspace.
    equality_work: [cells + 1]u32,
    commands: [16]Command,
    command_count: usize,
    global: Ref,
    yes: Ref,
    no: Ref,
    next: Ref,
    steps: u32,
    running: bool,
    step_budget: u32,
    app: plot_config.State,
    frame_callback: Ref,
    free_cells: u16,
    cell_reserve: u16,
    view: view_config.Config,
    view_history: [8]struct { config: view_config.Config, generation: u32 },
    view_history_count: u8,
    view_generation: u32,
    eval_stack: [eval_stack_size]Ref,
    eval_sp: u8,
    bytecode: [bytecode_capacity]u8,
    bytecode_len: u16,
    cached_proc: Ref,
    call_stack: [call_stack_capacity]CallFrame,
    call_sp: u8,
    ast_root_frames: [ast_root_frame_capacity]AstRootFrame,
    ast_root_frame_count: u8,

    inline fn pushEval(self: *Runtime, r: Ref) Error!void {
        if (self.eval_sp >= eval_stack_size) return error.Syntax;
        self.eval_stack[self.eval_sp] = r;
        self.eval_sp += 1;
    }

    inline fn pushAstRoots(self: *Runtime, expression: Ref, environment: Ref, auxiliary: Ref) Error!u8 {
        if (self.ast_root_frame_count >= self.ast_root_frames.len) return error.Depth;
        const index = self.ast_root_frame_count;
        self.ast_root_frame_count += 1;
        self.ast_root_frames[index] = .{ .expression = expression, .environment = environment, .auxiliary = auxiliary };
        return index;
    }

    inline fn evalRooted(self: *Runtime, expression: Ref, environment: Ref, depth: usize, host: anytype, pending: Ref, root_env: Ref, auxiliary: Ref) Error!Ref {
        const index = try self.pushAstRoots(pending, root_env, auxiliary);
        defer self.ast_root_frame_count = index;
        return self.eval(expression, environment, depth, host);
    }

    inline fn tagOf(self: *const Runtime, r: Ref) Tag {
        if (isImmediateInt(r)) return .integer;
        if (isImmediateOp(r)) return .native;
        if (r >= cells) return .free;
        return self.heap[r].tag;
    }

    pub fn initInPlace(self: *Runtime) linksection(code_section) void {
        @memset(std.mem.asBytes(self), 0);
        self.view = .{};
        self.app = .{};
        self.view_generation = 1;
        self.heap[0].tag = .nil;
        self.yes = 1;
        self.no = 2;
        self.global = 3;
        self.next = 4;
        self.free_cells = cells - 4;
        self.heap[1].tag = .boolean;
        self.heap[1].integer = 1;
        self.heap[2].tag = .boolean;
        self.heap[3].tag = .pair;
    }
    fn tick(self: *Runtime, depth: usize) linksection(code_section) Error!void {
        if (depth >= depth_limit) return error.Depth;
        if (self.steps >= self.step_budget) return error.Budget;
        self.steps += 1;
    }
    fn alloc(self: *Runtime, tag: Tag) linksection(code_section) Error!Ref {
        if (self.free_cells <= self.cell_reserve) return error.HeapFull;
        for (1..cells) |_| {
            const r = self.next;
            self.next = if (r + 1 == cells) 1 else r + 1;
            if (self.heap[r].tag != .free) continue;
            @memset(std.mem.asBytes(&self.heap[r]), 0);
            self.heap[r].tag = tag;
            self.free_cells -= 1;
            return r;
        }
        return error.HeapFull;
    }
    fn pair(self: *Runtime, a: Ref, b: Ref) linksection(code_section) Error!Ref {
        const r = try self.alloc(.pair);
        self.heap[r].a = a;
        self.heap[r].b = b;
        return r;
    }
    fn number(self: *Runtime, n: i32) linksection(code_section) Error!Ref {
        if (n >= -16384 and n <= 16383) {
            return makeImmediateInt(n);
        }
        const r = try self.alloc(.integer);
        self.heap[r].integer = n;
        return r;
    }
    const Fraction = struct { numerator: i32, denominator: i32 };
    fn normalizeFraction(numerator: i64, denominator: i64) linksection(code_section) Error!Fraction {
        if (denominator == 0) return error.DivisionByZero;
        var n = numerator;
        var d = denominator;
        if (d < 0) {
            n = -n;
            d = -d;
        }
        var a: u64 = @intCast(if (n < 0) -n else n);
        var b: u64 = @intCast(d);
        while (b != 0) {
            const r = a % b;
            a = b;
            b = r;
        }
        const divisor: i64 = @intCast(a);
        n = @divTrunc(n, divisor);
        d = @divTrunc(d, divisor);
        if (n < std.math.minInt(i32) or n > std.math.maxInt(i32) or d > std.math.maxInt(i32)) return error.Overflow;
        return .{ .numerator = @intCast(n), .denominator = @intCast(d) };
    }
    fn fraction(self: *const Runtime, r: Ref) linksection(code_section) Error!Fraction {
        if (self.tagOf(r) == .integer) return .{ .numerator = try self.integer(r), .denominator = 1 };
        if (self.tagOf(r) != .rational) return error.Type;
        const cell = self.heap[r];
        const den: u32 = @as(u32, cell.a) | (@as(u32, cell.b) << 16);
        return .{ .numerator = cell.integer, .denominator = @intCast(den) };
    }
    fn fractionNumber(self: *Runtime, value: Fraction) linksection(code_section) Error!Ref {
        if (value.denominator == 1) return self.number(value.numerator);
        const r = try self.alloc(.rational);
        const denominator: u32 = @intCast(value.denominator);
        self.heap[r].integer = value.numerator;
        self.heap[r].a = @truncate(denominator);
        self.heap[r].b = @truncate(denominator >> 16);
        return r;
    }
    fn parseInexact(token: []const u8) linksection(code_section) Error!f64 {
        if (comptime @import("builtin").os.tag == .freestanding) {
            var bits: u64 = 0;
            if (nih_xy_decimal_parse(token.ptr, token.len, &bits) != 0) return error.Syntax;
            return @bitCast(bits);
        } else return decimal.parse(token) catch error.Syntax;
    }
    fn formatInexact(value: f64, output: []u8) linksection(code_section) Error![]const u8 {
        if (comptime @import("builtin").os.tag == .freestanding) {
            const len = nih_xy_decimal_format(@bitCast(value), output.ptr, output.len);
            if (len < 0) return error.TextFull;
            return output[0..@intCast(len)];
        } else return decimal.format(value, output) catch error.TextFull;
    }
    fn radixInteger(bytes: []const u8, radix: u8, allow_sign: bool) linksection(code_section) Error!i64 {
        if (bytes.len == 0) return error.Syntax;
        var index: usize = 0;
        var negative = false;
        if (allow_sign and (bytes[0] == '+' or bytes[0] == '-')) {
            negative = bytes[0] == '-';
            index = 1;
        }
        if (index == bytes.len) return error.Syntax;
        var value: i64 = 0;
        for (bytes[index..]) |raw| {
            const c = std.ascii.toLower(raw);
            const digit: u8 = if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'f') c - 'a' + 10 else return error.Syntax;
            if (digit >= radix) return error.Syntax;
            value = std.math.mul(i64, value, radix) catch return error.Overflow;
            value = std.math.add(i64, value, digit) catch return error.Overflow;
        }
        return if (negative) -value else value;
    }
    fn exactDecimal(bytes: []const u8) linksection(code_section) Error!Fraction {
        var index: usize = 0;
        var negative = false;
        if (index < bytes.len and (bytes[index] == '+' or bytes[index] == '-')) {
            negative = bytes[index] == '-';
            index += 1;
        }
        const digits_start = index;
        var point = false;
        var digits: usize = 0;
        var fractional: i64 = 0;
        var trailing: i64 = 0;
        while (index < bytes.len) : (index += 1) {
            const c = bytes[index];
            if (c == '.' and !point) {
                point = true;
                continue;
            }
            if (!std.ascii.isDigit(c)) break;
            digits += 1;
            if (point) fractional += 1;
            if (c == '0') trailing += 1 else trailing = 0;
        }
        if (digits == 0) return error.Syntax;
        const end = index;
        var exponent: i64 = 0;
        if (index < bytes.len and (bytes[index] == 'e' or bytes[index] == 'E')) {
            index += 1;
            exponent = try radixInteger(bytes[index..], 10, true);
            index = bytes.len;
        }
        if (index != bytes.len) return error.Syntax;
        if (trailing == digits) return .{ .numerator = 0, .denominator = 1 };
        const significant = digits - @as(usize, @intCast(trailing));
        var coefficient: i64 = 0;
        var seen: usize = 0;
        for (bytes[digits_start..end]) |c| {
            if (c == '.') continue;
            if (seen == significant) break;
            seen += 1;
            coefficient = std.math.mul(i64, coefficient, 10) catch return error.Overflow;
            coefficient = std.math.add(i64, coefficient, c - '0') catch return error.Overflow;
        }
        const exp_adjusted = std.math.sub(i64, exponent, fractional) catch return error.Overflow;
        const scale = std.math.add(i64, exp_adjusted, trailing) catch return error.Overflow;
        if (scale < -18 or scale > 18) return error.Overflow;
        var power: i64 = 1;
        for (0..@as(usize, @intCast(@abs(scale)))) |_| power *= 10;
        if (scale > 0) coefficient = std.math.mul(i64, coefficient, power) catch return error.Overflow;
        if (negative) coefficient = -coefficient;
        return normalizeFraction(coefficient, if (scale < 0) power else 1);
    }
    fn prefixedNumber(self: *Runtime, token: []const u8) linksection(code_section) Error!Ref {
        var index: usize = 0;
        var radix: u8 = 10;
        var saw_radix = false;
        var exactness: enum { unspecified, exact, inexact } = .unspecified;
        while (index + 1 < token.len and token[index] == '#') : (index += 2) {
            switch (std.ascii.toLower(token[index + 1])) {
                'e', 'i' => |c| {
                    if (exactness != .unspecified) return error.Syntax;
                    exactness = if (c == 'e') .exact else .inexact;
                },
                'b', 'o', 'd', 'x' => |c| {
                    if (saw_radix) return error.Syntax;
                    saw_radix = true;
                    radix = switch (c) {
                        'b' => 2,
                        'o' => 8,
                        'x' => 16,
                        else => 10,
                    };
                },
                else => return error.Syntax,
            }
        }
        const body = token[index..];
        if (body.len == 0) return error.Syntax;
        if (radix == 10 and exactness != .exact) {
            if (std.ascii.eqlIgnoreCase(body, "+inf.0")) return self.inexactNumber(@bitCast(@as(u64, 0x7ff0000000000000)));
            if (std.ascii.eqlIgnoreCase(body, "-inf.0")) return self.inexactNumber(@bitCast(@as(u64, 0xfff0000000000000)));
            if (std.ascii.eqlIgnoreCase(body, "+nan.0") or std.ascii.eqlIgnoreCase(body, "-nan.0")) return self.inexactNumber(@bitCast(@as(u64, 0x7ff8000000000000)));
        }
        if (std.mem.indexOfScalar(u8, body, '/')) |slash| {
            const numerator = try radixInteger(body[0..slash], radix, true);
            const denominator = try radixInteger(body[slash + 1 ..], radix, false);
            if (denominator == 0) return error.DivisionByZero;
            if (exactness == .inexact) return self.inexactNumber(@as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(denominator)));
            return self.fractionNumber(try normalizeFraction(numerator, denominator));
        }
        if (radix == 10 and (std.mem.indexOfAny(u8, body, ".eE") != null)) {
            if (exactness == .exact) return self.fractionNumber(try exactDecimal(body));
            return self.inexactNumber(try parseInexact(body));
        }
        if (radix == 10 and exactness == .inexact) return self.inexactNumber(try parseInexact(body));
        const n = try radixInteger(body, radix, true);
        if (exactness == .inexact) return self.inexactNumber(@floatFromInt(n));
        if (n < std.math.minInt(i32) or n > std.math.maxInt(i32)) return error.Overflow;
        return self.number(@intCast(n));
    }
    fn inexactNumber(self: *Runtime, value: f64) linksection(code_section) Error!Ref {
        const bits: u64 = @bitCast(value);
        const r = try self.alloc(.inexact);
        self.heap[r].integer = @bitCast(@as(u32, @truncate(bits)));
        self.heap[r].a = @truncate(bits >> 32);
        self.heap[r].b = @truncate(bits >> 48);
        return r;
    }
    fn asInexact(self: *const Runtime, r: Ref) linksection(code_section) Error!f64 {
        if (self.tagOf(r) == .inexact) {
            const c = self.heap[r];
            const bits = @as(u64, @as(u32, @bitCast(c.integer))) | (@as(u64, c.a) << 32) | (@as(u64, c.b) << 48);
            return @bitCast(bits);
        }
        const v = try self.fraction(r);
        return @as(f64, @floatFromInt(v.numerator)) / @as(f64, @floatFromInt(v.denominator));
    }
    // Compare the exact rational with the represented binary64 value without
    // rounding the rational. The product uses at most 84 significant bits.
    fn compareExactInexact(exact: Fraction, value: f64) linksection(code_section) ?std.math.Order {
        const bits: u64 = @bitCast(value);
        const magnitude = bits & 0x7fffffffffffffff;
        const exp: u11 = @truncate(magnitude >> 52);
        const fraction_bits = magnitude & 0x000fffffffffffff;
        const negative = bits >> 63 != 0;
        if (exp == 0x7ff) {
            if (fraction_bits != 0) return null;
            return if (negative) .gt else .lt;
        }
        if (exact.numerator == 0 and magnitude == 0) return .eq;
        if (exact.numerator < 0 and (!negative or magnitude == 0)) return .lt;
        if (exact.numerator >= 0 and negative and magnitude != 0) return .gt;
        if (exact.numerator == 0) return if (negative) .gt else .lt;
        if (magnitude == 0) return if (exact.numerator < 0) .lt else .gt;
        const left: u128 = @intCast(if (exact.numerator < 0) -@as(i64, exact.numerator) else exact.numerator);
        const mantissa: u64 = fraction_bits | (if (exp == 0) @as(u64, 0) else @as(u64, 1) << 52);
        const right: u128 = @as(u128, mantissa) * @as(u128, @intCast(exact.denominator));
        const exponent: i32 = if (exp == 0) -1074 else @as(i32, exp) - 1075;
        const left_width: i32 = 128 - @as(i32, @intCast(@clz(left)));
        const right_width: i32 = 128 - @as(i32, @intCast(@clz(right))) + exponent;
        var order: std.math.Order = if (left_width < right_width) .lt else if (left_width > right_width) .gt else blk: {
            const l = if (exponent < 0) left << @as(u7, @intCast(-exponent)) else left;
            const r = if (exponent > 0) right << @as(u7, @intCast(exponent)) else right;
            break :blk std.math.order(l, r);
        };
        if (negative) order = order.invert();
        return order;
    }
    fn compareNumbers(self: *const Runtime, left: Ref, right: Ref) linksection(code_section) Error!?std.math.Order {
        const left_inexact = self.tagOf(left) == .inexact;
        const right_inexact = self.tagOf(right) == .inexact;
        if (left_inexact and right_inexact) {
            const a = try self.asInexact(left);
            const b = try self.asInexact(right);
            if (std.math.isNan(a) or std.math.isNan(b)) return null;
            return if (a < b) .lt else if (a > b) .gt else .eq;
        }
        if (left_inexact) {
            const order = compareExactInexact(try self.fraction(right), try self.asInexact(left));
            return if (order) |o| o.invert() else null;
        }
        if (right_inexact) return compareExactInexact(try self.fraction(left), try self.asInexact(right));
        const a = try self.fraction(left);
        const b = try self.fraction(right);
        return std.math.order(@as(i64, a.numerator) * b.denominator, @as(i64, b.numerator) * a.denominator);
    }
    fn roundInexact(value: f64, op: Op) linksection(code_section) f64 {
        const bits: u64 = @bitCast(value);
        const sign = bits & (@as(u64, 1) << 63);
        const magnitude = bits & 0x7fffffffffffffff;
        const exponent: u11 = @truncate(magnitude >> 52);
        if (exponent == 0x7ff or exponent >= 1075 or magnitude == 0) return value;
        if (exponent < 1023) {
            const increment = switch (op) {
                .floor_proc => sign != 0,
                .ceiling_proc => sign == 0,
                .round_proc => magnitude > 0x3fe0000000000000,
                else => false,
            };
            return @bitCast(sign | (if (increment) @as(u64, 0x3ff0000000000000) else 0));
        }
        const fraction_bits: u6 = @intCast(1075 - @as(u32, exponent));
        const mask = (@as(u64, 1) << fraction_bits) - 1;
        const fraction_part = magnitude & mask;
        var rounded = magnitude & ~mask;
        if (fraction_part != 0) {
            const half = @as(u64, 1) << (fraction_bits - 1);
            const increment = switch (op) {
                .floor_proc => sign != 0,
                .ceiling_proc => sign == 0,
                .round_proc => fraction_part > half or (fraction_part == half and ((rounded >> fraction_bits) & 1) != 0),
                else => false,
            };
            if (increment) rounded += @as(u64, 1) << fraction_bits;
        }
        return @bitCast(sign | rounded);
    }
    fn numericOdd(self: *const Runtime, r: Ref) linksection(code_section) Error!bool {
        if (self.tagOf(r) != .inexact) {
            const n = try self.integer(r);
            return @mod(n, 2) != 0;
        }
        const bits: u64 = @bitCast(try self.asInexact(r));
        const magnitude = bits & 0x7fffffffffffffff;
        const exponent: u11 = @truncate(magnitude >> 52);
        if (exponent == 0x7ff) return error.Type;
        if (exponent < 1023) {
            if (magnitude != 0) return error.Type;
            return false;
        }
        if (exponent > 1075) return false;
        const shift: u6 = @intCast(1075 - @as(u32, exponent));
        const mantissa = (magnitude & 0x000fffffffffffff) | (@as(u64, 1) << 52);
        if (shift != 0 and (mantissa & ((@as(u64, 1) << shift) - 1)) != 0) return error.Type;
        return ((mantissa >> shift) & 1) != 0;
    }
    fn boundedInteger(self: *const Runtime, r: Ref) linksection(code_section) Error!i64 {
        if (self.tagOf(r) != .inexact) return try self.integer(r);
        const value = try self.asInexact(r);
        if (!std.math.isFinite(value) or roundInexact(value, .truncate_proc) != value) return error.Type;
        if (value < -2147483648.0 or value > 2147483647.0) return error.Overflow;
        return @intFromFloat(value);
    }
    fn integerResult(self: *Runtime, value: i64, inexact: bool) linksection(code_section) Error!Ref {
        if (inexact) return self.inexactNumber(@floatFromInt(value));
        if (value < std.math.minInt(i32) or value > std.math.maxInt(i32)) return error.Overflow;
        return self.number(@intCast(value));
    }
    fn integerGcd(a0: i64, b0: i64) linksection(code_section) i64 {
        var a = if (a0 < 0) -a0 else a0;
        var b = if (b0 < 0) -b0 else b0;
        while (b != 0) {
            const r = @rem(a, b);
            a = b;
            b = r;
        }
        return a;
    }
    fn text(self: *Runtime, tag: Tag, bytes: []const u8) linksection(code_section) Error!Ref {
        if (bytes.len > text_bytes) return error.TextFull;
        if (tag == .symbol or tag == .keyword) {
            for (1..cells) |idx| {
                const r: Ref = @intCast(idx);
                const c = &self.heap[r];
                if (c.tag == tag and c.textLen() == bytes.len) {
                    if (std.mem.eql(u8, self.text_storage[c.textOffset()..][0..c.textLen()], bytes)) {
                        return r;
                    }
                }
            }
        }
        if (@as(usize, self.text_used) + bytes.len > text_storage_bytes) return error.TextFull;
        const r = try self.alloc(tag);
        const offset = self.text_used;
        @memcpy(self.text_storage[offset..][0..bytes.len], bytes);
        self.text_used += @intCast(bytes.len);
        self.heap[r].setText(@intCast(bytes.len), offset);
        return r;
    }
    fn string(self: *const Runtime, r: Ref) linksection(code_section) []const u8 {
        const offset = self.heap[r].textOffset();
        const len = self.heap[r].textLen();
        return self.text_storage[offset..][0..len];
    }
    fn findSymbol(self: *const Runtime, bytes: []const u8) linksection(code_section) ?Ref {
        for (1..cells) |idx| {
            const r: Ref = @intCast(idx);
            const c = &self.heap[r];
            if (c.tag == .symbol and c.textLen() == bytes.len) {
                if (std.mem.eql(u8, self.text_storage[c.textOffset()..][0..c.textLen()], bytes)) {
                    return r;
                }
            }
        }
        return null;
    }
    fn opcode(bytes: []const u8) linksection(code_section) ?Op {
        var pos: usize = 0;
        var index: u8 = 0;
        while (pos < vocabulary.len) : (index += 1) {
            const end = pos + (std.mem.indexOfScalar(u8, vocabulary[pos..], 0) orelse return null);
            if (std.mem.eql(u8, bytes, vocabulary[pos..end])) return @fromBackingInt(@intCast(index));
            pos = end + 1;
        }
        return null;
    }
    noinline fn collect(self: *Runtime) linksection(code_section) void {
        self.collectTail(0, 0);
    }
    // Called only at audited outermost AST boundaries, where these roots cover
    // live transient heap references. No argument or reader temporaries remain
    // live across this collection.
    noinline fn collectTail(self: *Runtime, expression: Ref, environment: Ref) linksection(code_section) void {
        var state = SliceCursor{};
        while (!self.collectSlice(&state, expression, environment, 64)) {}
    }
    // Kept as an independent oracle for the collector tests; unused by the
    // native image. Its quadratic text scan avoids sharing the indexed logic.
    noinline fn collectTailReference(self: *Runtime, expression: Ref, environment: Ref) linksection(code_section) void {
        var head: usize = 0;
        var tail: usize = 0;
        self.mark(self.global, &tail);
        self.mark(self.yes, &tail);
        self.mark(self.no, &tail);
        self.mark(self.frame_callback, &tail);
        self.mark(expression, &tail);
        self.mark(environment, &tail);
        for (self.commands[0..self.command_count]) |command| {
            self.mark(command.name, &tail);
            self.mark(command.procedure, &tail);
        }
        for (self.eval_stack[0..self.eval_sp]) |r| {
            self.mark(r, &tail);
        }
        for (self.call_stack[0..self.call_sp]) |frame| {
            self.mark(frame.env, &tail);
        }
        for (self.ast_root_frames[0..self.ast_root_frame_count]) |frame| {
            self.mark(frame.expression, &tail);
            self.mark(frame.environment, &tail);
            self.mark(frame.auxiliary, &tail);
            for (frame.values[0..frame.value_count]) |value| self.mark(value, &tail);
        }
        var bc_scan: usize = 0;
        while (bc_scan < self.bytecode_len) {
            const raw_op = self.bytecode[bc_scan];
            const op = toBcOp(raw_op) orelse break;
            bc_scan += 1;
            switch (op) {
                .const_val, .load_global, .def_global => {
                    if (bc_scan + 2 <= self.bytecode_len) {
                        const r = std.mem.readInt(u16, self.bytecode[bc_scan..][0..2], .little);
                        if (!isImmediate(r)) self.mark(r, &tail);
                        bc_scan += 2;
                    }
                },
                .load_local, .store_local, .call => {
                    bc_scan += 1;
                },
                .jump, .jump_if_false => {
                    bc_scan += 2;
                },
                else => {},
            }
        }
        while (head < tail) : (head += 1) {
            const c = self.heap[self.queue[head]];
            if (c.tag == .pair) {
                self.mark(c.a, &tail);
                self.mark(c.b, &tail);
                self.mark(c.env, &tail);
            } else if (c.tag == .closure) {
                if (c.flagged()) {
                    self.mark(c.env, &tail);
                } else {
                    self.mark(c.a, &tail);
                    self.mark(c.b, &tail);
                    self.mark(c.env, &tail);
                }
            }
        }
        // The code cache is weak: it must not keep an otherwise dead closure alive.
        if (self.cached_proc != 0 and !self.heap[self.cached_proc].mark) {
            self.cached_proc = 0;
            self.bytecode_len = 0;
        }
        for (1..cells) |idx| {
            const c = &self.heap[idx];
            if (c.mark and c.isText() and c.textLen() == 0) {
                c.setTextOffset(0);
            }
        }
        var new_offset: u16 = 0;
        while (true) {
            var best_offset: u16 = std.math.maxInt(u16);
            for (1..cells) |idx| {
                const c = &self.heap[idx];
                if (c.mark and c.isText() and c.textLen() > 0) {
                    if (c.textOffset() >= new_offset and c.textOffset() < best_offset) {
                        best_offset = c.textOffset();
                    }
                }
            }
            if (best_offset == std.math.maxInt(u16)) break;
            var best_len: u8 = 0;
            for (1..cells) |idx| {
                const c = &self.heap[idx];
                if (c.mark and c.isText() and c.textLen() > 0) {
                    if (c.textOffset() == best_offset) {
                        best_len = @intCast(c.textLen());
                        break;
                    }
                }
            }
            if (best_offset != new_offset) {
                std.mem.copyForwards(u8, self.text_storage[new_offset..][0..best_len], self.text_storage[best_offset..][0..best_len]);
                for (1..cells) |idx| {
                    const c = &self.heap[idx];
                    if (c.mark and c.isText()) {
                        if (c.textOffset() == best_offset) {
                            c.setTextOffset(new_offset);
                        }
                    }
                }
            }
            new_offset += best_len;
        }
        self.text_used = new_offset;
        self.free_cells = 0;
        for (self.heap[1..]) |*c| {
            if (!c.mark) c.tag = .free;
            c.mark = false;
            if (c.tag == .free) self.free_cells += 1;
        }
    }
    // Synchronous collector state. The VM remains stopped until all phases
    // finish; in particular, equalValues must not borrow equality_work here.
    comptime {
        if (text_storage_bytes > cells + 1) @compileError("GC text index exceeds the equality workspace");
    }
    const SlicePhase = enum { roots, commands, eval_roots, call_roots, ast_roots, bytecode, mark_queue, empty_text, clear_text_map, index_text, copy_text, remap_text, sweep, done };
    const SliceCursor = struct {
        phase: SlicePhase = .roots,
        index: usize = 0,
        subindex: usize = 0,
        head: usize = 0,
        tail: usize = 0,
        new_offset: u16 = 0,
        best_offset: u16 = std.math.maxInt(u16),
        best_len: u8 = 0,
    };
    noinline fn collectSlice(self: *Runtime, state: *SliceCursor, expression: Ref, environment: Ref, budget: usize) linksection(code_section) bool {
        var left = budget;
        while (left > 0 and state.phase != .done) : (left -= 1) {
            switch (state.phase) {
                .roots => {
                    const roots = [_]Ref{ self.global, self.yes, self.no, self.frame_callback, expression, environment };
                    if (state.index == roots.len) {
                        state.index = 0;
                        state.phase = .commands;
                        continue;
                    }
                    self.mark(roots[state.index], &state.tail);
                    state.index += 1;
                },
                .commands => {
                    if (state.index == self.command_count * 2) {
                        state.index = 0;
                        state.phase = .eval_roots;
                        continue;
                    }
                    const cmd = self.commands[state.index / 2];
                    self.mark(if (state.index % 2 == 0) cmd.name else cmd.procedure, &state.tail);
                    state.index += 1;
                },
                .eval_roots => {
                    if (state.index == self.eval_sp) {
                        state.index = 0;
                        state.phase = .call_roots;
                        continue;
                    }
                    self.mark(self.eval_stack[state.index], &state.tail);
                    state.index += 1;
                },
                .call_roots => {
                    if (state.index == self.call_sp) {
                        state.index = 0;
                        state.phase = .ast_roots;
                        continue;
                    }
                    self.mark(self.call_stack[state.index].env, &state.tail);
                    state.index += 1;
                },
                .ast_roots => {
                    if (state.index == self.ast_root_frame_count) {
                        state.index = 0;
                        state.phase = .bytecode;
                        continue;
                    }
                    const frame = self.ast_root_frames[state.index];
                    if (state.subindex == 3 + @as(usize, frame.value_count)) {
                        state.index += 1;
                        state.subindex = 0;
                        continue;
                    }
                    const r = switch (state.subindex) {
                        0 => frame.expression,
                        1 => frame.environment,
                        2 => frame.auxiliary,
                        else => frame.values[state.subindex - 3],
                    };
                    self.mark(r, &state.tail);
                    state.subindex += 1;
                },
                .bytecode => {
                    if (state.index >= self.bytecode_len) {
                        state.index = 0;
                        state.phase = .mark_queue;
                        continue;
                    }
                    const op = toBcOp(self.bytecode[state.index]) orelse {
                        state.index = 0;
                        state.phase = .mark_queue;
                        continue;
                    };
                    state.index += 1;
                    switch (op) {
                        .const_val, .load_global, .def_global => {
                            if (state.index + 2 <= self.bytecode_len) {
                                const r = std.mem.readInt(u16, self.bytecode[state.index..][0..2], .little);
                                if (!isImmediate(r)) self.mark(r, &state.tail);
                                state.index += 2;
                            }
                        },
                        .load_local, .store_local, .call => state.index += 1,
                        .jump, .jump_if_false => state.index += 2,
                        else => {},
                    }
                },
                .mark_queue => {
                    if (state.head == state.tail) {
                        // Compiled numeric cache is weak and must not retain a
                        // collected closure or reuse its bytecode after sweep.
                        if (self.cached_proc != 0 and !self.heap[self.cached_proc].mark) {
                            self.cached_proc = 0;
                            self.bytecode_len = 0;
                        }
                        state.index = 1;
                        state.phase = .empty_text;
                        continue;
                    }
                    const c = self.heap[self.queue[state.head]];
                    state.head += 1;
                    if (c.tag == .pair or (c.tag == .closure and !c.flagged())) {
                        self.mark(c.a, &state.tail);
                        self.mark(c.b, &state.tail);
                        self.mark(c.env, &state.tail);
                    } else if (c.tag == .closure) self.mark(c.env, &state.tail);
                },
                .empty_text => {
                    if (state.index == cells) {
                        if (state.best_len == 0) {
                            // No nonempty live text needs an index or copy.
                            self.text_used = 0;
                            self.free_cells = 0;
                            state.index = 1;
                            state.phase = .sweep;
                        } else {
                            state.index = 0;
                            state.phase = .clear_text_map;
                        }
                        continue;
                    }
                    const c = &self.heap[state.index];
                    if (c.mark and c.isText()) {
                        if (c.textLen() == 0) c.setTextOffset(0) else state.best_len = 1;
                    }
                    state.index += 1;
                },
                .clear_text_map => {
                    if (state.index == text_storage_bytes) {
                        state.index = 1;
                        state.phase = .index_text;
                        continue;
                    }
                    self.equality_work[state.index] = 0;
                    state.index += 1;
                },
                .index_text => {
                    if (state.index == cells) {
                        state.index = 0;
                        state.subindex = 0;
                        state.phase = .copy_text;
                        continue;
                    }
                    const c = &self.heap[state.index];
                    // Each occupied original byte offset indexes a packed
                    // length and, after copying, the new offset plus one.
                    if (c.mark and c.isText() and c.textLen() > 0 and self.equality_work[c.textOffset()] == 0) {
                        self.equality_work[c.textOffset()] = @as(u32, c.textLen()) << 16;
                    }
                    state.index += 1;
                },
                .copy_text => {
                    if (state.subindex != 0) {
                        const pos = state.subindex - 1;
                        if (pos == state.best_len) {
                            state.index = @as(usize, state.best_offset) + state.best_len;
                            state.new_offset += state.best_len;
                            state.subindex = 0;
                        } else {
                            self.text_storage[@as(usize, state.new_offset) + pos] = self.text_storage[@as(usize, state.best_offset) + pos];
                            state.subindex += 1;
                        }
                        continue;
                    }
                    if (state.index >= self.text_used) {
                        state.index = 1;
                        state.phase = .remap_text;
                        continue;
                    }
                    const info = self.equality_work[state.index];
                    if (info == 0) {
                        state.index += 1;
                        continue;
                    }
                    state.best_offset = @intCast(state.index);
                    state.best_len = @intCast(info >> 16);
                    self.equality_work[state.index] = info | (@as(u32, state.new_offset) + 1);
                    state.subindex = 1;
                },
                .remap_text => {
                    if (state.index == cells) {
                        self.text_used = state.new_offset;
                        self.free_cells = 0;
                        state.index = 1;
                        state.phase = .sweep;
                        continue;
                    }
                    const c = &self.heap[state.index];
                    if (c.mark and c.isText() and c.textLen() > 0) {
                        c.setTextOffset(@intCast((self.equality_work[c.textOffset()] & 0xffff) - 1));
                    }
                    state.index += 1;
                },
                .sweep => {
                    if (state.index == cells) {
                        state.phase = .done;
                        continue;
                    }
                    const c = &self.heap[state.index];
                    if (!c.mark) c.tag = .free;
                    c.mark = false;
                    if (c.tag == .free) self.free_cells += 1;
                    state.index += 1;
                },
                .done => unreachable,
            }
        }
        return state.phase == .done;
    }

    fn mark(self: *Runtime, r: Ref, tail: *usize) linksection(code_section) void {
        if (r == 0 or isImmediate(r) or self.heap[r].mark) return;
        self.heap[r].mark = true;
        self.queue[tail.*] = r;
        tail.* += 1;
    }
    fn space(source: []const u8, pos: *usize) linksection(code_section) void {
        while (pos.* < source.len) {
            const b = source[pos.*];
            if (b == ' ' or b == '\t' or b == '\n' or b == '\r') {
                pos.* += 1;
                continue;
            }
            if (b != ';') return;
            while (pos.* < source.len and source[pos.*] != '\n') pos.* += 1;
        }
    }
    fn delimiter(b: u8) linksection(code_section) bool {
        return b == '(' or b == ')' or b == '\'' or b == '`' or b == ',' or b == '"' or b == ';' or b == ' ' or b == '\t' or b == '\n' or b == '\r';
    }
    fn read(self: *Runtime, source: []const u8, pos: *usize, depth: usize) linksection(code_section) Error!Ref {
        try self.tick(depth);
        space(source, pos);
        if (pos.* == source.len) return error.Syntax;
        const first = source[pos.*];
        pos.* += 1;
        if (first == '(') {
            var result: Ref = 0;
            var tail: Ref = 0;
            while (true) {
                space(source, pos);
                if (pos.* == source.len) return error.Syntax;
                if (source[pos.*] == ')') {
                    pos.* += 1;
                    return result;
                }
                if (source[pos.*] == '.' and (pos.* + 1 == source.len or delimiter(source[pos.* + 1]))) {
                    if (tail == 0) return error.Syntax;
                    pos.* += 1;
                    const rest = try self.read(source, pos, depth + 1);
                    space(source, pos);
                    if (pos.* == source.len or source[pos.*] != ')') return error.Syntax;
                    pos.* += 1;
                    self.heap[tail].b = rest;
                    return result;
                }
                const item = try self.read(source, pos, depth + 1);
                const p = try self.pair(item, 0);
                if (tail == 0) result = p else self.heap[tail].b = p;
                tail = p;
            }
        }
        if (first == ')') return error.Syntax;
        if (first == '\'' or first == '`' or first == ',') {
            const spelling: []const u8 = if (first == '\'') "quote" else if (first == '`') "quasiquote" else if (pos.* < source.len and source[pos.*] == '@') splice: {
                pos.* += 1;
                break :splice "unquote-splicing";
            } else "unquote";
            const quoted = try self.read(source, pos, depth + 1);
            return self.pair(try self.text(.symbol, spelling), try self.pair(quoted, 0));
        }
        if (first == '"') {
            var bytes: [text_bytes]u8 = @splat(0);
            var len: usize = 0;
            while (pos.* < source.len) {
                var b = source[pos.*];
                pos.* += 1;
                if (b == '"') return self.text(.string, bytes[0..len]);
                if (b == '\\') {
                    if (pos.* == source.len) return error.Syntax;
                    b = source[pos.*];
                    pos.* += 1;
                    b = switch (b) {
                        'n' => '\n',
                        't' => '\t',
                        '"', '\\' => b,
                        else => return error.Syntax,
                    };
                }
                if (len == bytes.len) return error.TextFull;
                bytes[len] = b;
                len += 1;
            }
            return error.Syntax;
        }
        const token_start = pos.* - 1;
        while (pos.* < source.len and !delimiter(source[pos.*])) pos.* += 1;
        const token = source[token_start..pos.*];
        if (token.len >= 2 and token[0] == '#' and token[1] == ':') {
            if (token.len == 2) return error.Syntax;
            return self.text(.keyword, token[2..]);
        }
        if (std.mem.eql(u8, token, "#t")) return self.yes;
        if (std.mem.eql(u8, token, "#f")) return self.no;
        if (std.ascii.eqlIgnoreCase(token, "+inf.0")) return self.inexactNumber(@bitCast(@as(u64, 0x7ff0000000000000)));
        if (std.ascii.eqlIgnoreCase(token, "-inf.0")) return self.inexactNumber(@bitCast(@as(u64, 0xfff0000000000000)));
        if (std.ascii.eqlIgnoreCase(token, "+nan.0") or std.ascii.eqlIgnoreCase(token, "-nan.0")) return self.inexactNumber(@bitCast(@as(u64, 0x7ff8000000000000)));
        if (token.len >= 2 and token[0] == '#' and std.mem.indexOfScalar(u8, "eibodxEIBODX", token[1]) != null) return self.prefixedNumber(token);
        if (std.mem.eql(u8, token, ".")) return error.Syntax;
        if (token[0] == '.' and token.len > 1 and std.ascii.isDigit(token[1]) or token.len > 2 and (token[0] == '+' or token[0] == '-') and token[1] == '.' and std.ascii.isDigit(token[2])) {
            return self.inexactNumber(try parseInexact(token));
        }
        if ((token[0] >= '0' and token[0] <= '9') or (token.len > 1 and (token[0] == '-' or token[0] == '+') and token[1] >= '0' and token[1] <= '9')) {
            if (std.mem.indexOfAny(u8, token, ".eE") != null) return self.inexactNumber(try parseInexact(token));
            if (std.mem.indexOfScalar(u8, token, '/')) |slash| {
                const numerator = parseDecimal(token[0..slash]) catch return error.Overflow;
                const denominator = parseDecimal(token[slash + 1 ..]) catch return error.Overflow;
                if (denominator < 0) return error.Syntax;
                return self.fractionNumber(try normalizeFraction(numerator, denominator));
            }
            return self.number(parseDecimal(token) catch return error.Overflow);
        }
        return self.text(.symbol, token);
    }
    fn arguments(self: *const Runtime, list: Ref, out: []Ref) linksection(code_section) Error![]Ref {
        var p = list;
        var len: usize = 0;
        while (p != 0) {
            if (self.tagOf(p) != .pair) return error.Type;
            if (len == out.len) return error.Arity;
            out[len] = self.heap[p].a;
            len += 1;
            p = self.heap[p].b;
        }
        return out[0..len];
    }
    const ExpandedApply = struct { procedure: Ref, values: []Ref };
    fn expandApply(self: *const Runtime, args: []const Ref, storage_: []Ref) linksection(code_section) Error!ExpandedApply {
        if (args.len < 2) return error.Arity;
        var count: usize = 0;
        for (args[1 .. args.len - 1]) |value| {
            if (count == storage_.len) return error.Arity;
            storage_[count] = value;
            count += 1;
        }
        var cursor = args[args.len - 1];
        while (cursor != 0) {
            if (self.tagOf(cursor) != .pair) return error.Type;
            if (count == storage_.len) return error.Arity;
            storage_[count] = self.heap[cursor].a;
            count += 1;
            cursor = self.heap[cursor].b;
        }
        return .{ .procedure = args[0], .values = storage_[0..count] };
    }
    fn isApplyProcedure(self: *const Runtime, procedure: Ref) linksection(code_section) bool {
        if (isImmediateOp(procedure)) return toImmediateOp(procedure) == .apply_proc;
        if (isImmediate(procedure) or self.tagOf(procedure) != .native) return false;
        return self.heap[procedure].integer == @as(i32, @intCast(@backingInt(Op.apply_proc)));
    }
    fn lookup(self: *const Runtime, env: Ref, sym: Ref) linksection(code_section) Ref {
        var e = env;
        while (e != 0) : (e = self.heap[e].b) {
            var p = self.heap[e].a;
            while (p != 0) : (p = self.heap[p].b) {
                const binding = self.heap[p].a;
                if (self.heap[binding].a == sym) return binding;
            }
        }
        return 0;
    }
    inline fn canReuseFrame(self: *const Runtime, env: Ref, params: []const Ref) bool {
        if (self.heap[env].flagged()) return false;
        var node = self.heap[env].a;
        var i = params.len;
        while (i > 0) {
            i -= 1;
            if (node == 0) return false;
            const b = self.heap[node].a;
            if (self.heap[b].a != params[i]) return false;
            node = self.heap[node].b;
        }
        return node == 0;
    }
    inline fn updateFrameBindings(self: *Runtime, env: Ref, values: []const Ref) void {
        var node = self.heap[env].a;
        var i = values.len;
        while (i > 0) {
            i -= 1;
            const b = self.heap[node].a;
            self.heap[b].b = values[i];
            node = self.heap[node].b;
        }
    }
    fn define(self: *Runtime, env: Ref, name: Ref, value: Ref) linksection(code_section) Error!void {
        if (self.tagOf(name) != .symbol) return error.Type;
        var p = self.heap[env].a;
        while (p != 0) : (p = self.heap[p].b) {
            const binding = self.heap[p].a;
            if (self.heap[binding].a == name) {
                self.heap[binding].b = value;
                return;
            }
        }
        self.heap[env].a = try self.pair(try self.pair(name, value), self.heap[env].a);
    }
    const Formals = struct { fixed: [16]Ref = @splat(0), count: usize = 0, rest: Ref = 0 };
    fn formals(self: *const Runtime, params: Ref) linksection(code_section) Error!Formals {
        var result = Formals{};
        var cursor = params;
        while (self.tagOf(cursor) == .pair) {
            if (result.count == result.fixed.len) return error.Arity;
            const name = self.heap[cursor].a;
            if (self.tagOf(name) != .symbol) return error.Type;
            for (result.fixed[0..result.count]) |old| if (name == old) return error.Syntax;
            result.fixed[result.count] = name;
            result.count += 1;
            cursor = self.heap[cursor].b;
        }
        if (cursor != 0) {
            if (self.tagOf(cursor) != .symbol) return error.Type;
            for (result.fixed[0..result.count]) |old| if (cursor == old) return error.Syntax;
            result.rest = cursor;
        }
        return result;
    }
    fn bindFormals(self: *Runtime, local: Ref, parsed: Formals, args: []const Ref) linksection(code_section) Error!void {
        if (args.len < parsed.count or (parsed.rest == 0 and args.len != parsed.count)) return error.Arity;
        for (parsed.fixed[0..parsed.count], args[0..parsed.count]) |name, value| try self.define(local, name, value);
        if (parsed.rest != 0) {
            var rest: Ref = 0;
            var index = args.len;
            while (index > parsed.count) {
                index -= 1;
                rest = try self.pair(args[index], rest);
            }
            try self.define(local, parsed.rest, rest);
        }
    }
    fn closure(self: *Runtime, params: Ref, body: Ref, env: Ref) linksection(code_section) Error!Ref {
        if (body == 0) return error.Arity;
        _ = try self.formals(params);
        const r = try self.alloc(.closure);
        // Captured frames must retain their bindings for the closure's lifetime.
        var captured = env;
        while (captured != 0 and captured != self.global) : (captured = self.heap[captured].b) {
            self.heap[captured].setFlag();
        }
        self.heap[r].a = params;
        self.heap[r].b = body;
        self.heap[r].env = env;
        return r;
    }
    // Only the outer AST evaluator may call this: all pending expressions
    // and the environment must be reachable from these two roots.
    fn maybeCollectBoundary(self: *Runtime, depth: usize, pending: Ref, env: Ref, reclaim_at: *u16, ceiling: u16) linksection(code_section) void {
        if (depth == 0 and self.running and self.cell_reserve == 0 and self.eval_sp == 0 and self.call_sp == 0 and self.free_cells <= reclaim_at.*) {
            self.collectTail(pending, env);
            reclaim_at.* = if (self.free_cells > ceiling) ceiling else self.free_cells / 2;
        }
    }
    // Recognize syntax by interned spelling; user data is never evaluated here.
    fn quasiquoteKind(self: *const Runtime, value: Ref) linksection(code_section) ?Op {
        if (self.tagOf(value) != .pair) return null;
        const head = self.heap[value].a;
        if (self.tagOf(head) != .symbol) return null;
        const op = opcode(self.string(head)) orelse return null;
        return switch (op) {
            .quasiquote, .unquote, .unquote_splicing => op,
            else => null,
        };
    }
    fn quasiquote(self: *Runtime, template: Ref, env: Ref, nesting: usize, depth: usize, host: anytype) linksection(code_section) Error!Ref {
        try self.tick(depth);
        const frame = try self.pushAstRoots(template, env, 0);
        defer self.ast_root_frame_count = frame;
        if (self.quasiquoteKind(template)) |kind| {
            var fields: [1]Ref = @splat(0);
            const arguments_ = try self.arguments(self.heap[template].b, &fields);
            if (arguments_.len != 1) return error.Syntax;
            if (kind == .unquote and nesting == 1) return self.eval(arguments_[0], env, depth + 1, host);
            if (kind == .unquote_splicing and nesting == 1) return error.Syntax;
            const next = if (kind == .quasiquote) nesting + 1 else nesting - 1;
            const inner = try self.quasiquote(arguments_[0], env, next, depth + 1, host);
            const tail = try self.pair(inner, 0);
            return self.pair(self.heap[template].a, tail);
        }
        if (self.tagOf(template) != .pair) return template;
        var cursor = template;
        var head: Ref = 0;
        var tail: Ref = 0;
        while (self.tagOf(cursor) == .pair) {
            try self.tick(depth);
            // A dotted cdr may itself be an unquote form. It is structurally
            // identical to its equivalent list representation.
            if (cursor != template and self.quasiquoteKind(cursor) != null) break;
            const item = self.heap[cursor].a;
            if (nesting == 1 and self.quasiquoteKind(item) == .unquote_splicing) {
                var fields: [1]Ref = @splat(0);
                const arguments_ = try self.arguments(self.heap[item].b, &fields);
                if (arguments_.len != 1) return error.Syntax;
                var splice = try self.eval(arguments_[0], env, depth + 1, host);
                self.ast_root_frames[frame].values[0] = splice;
                self.ast_root_frames[frame].value_count = 1;
                var count: usize = 0;
                while (splice != 0) {
                    if (self.tagOf(splice) != .pair) return error.Type;
                    if (count >= cells) return error.Depth;
                    count += 1;
                    try self.tick(depth);
                    const node = try self.pair(self.heap[splice].a, 0);
                    if (head == 0) head = node else self.heap[tail].b = node;
                    tail = node;
                    self.ast_root_frames[frame].auxiliary = head;
                    splice = self.heap[splice].b;
                }
                self.ast_root_frames[frame].value_count = 0;
            } else {
                const value = try self.quasiquote(item, env, nesting, depth + 1, host);
                const node = try self.pair(value, 0);
                if (head == 0) head = node else self.heap[tail].b = node;
                tail = node;
                self.ast_root_frames[frame].auxiliary = head;
            }
            cursor = self.heap[cursor].b;
        }
        const rest = if (cursor == 0) @as(Ref, 0) else try self.quasiquote(cursor, env, nesting, depth + 1, host);
        if (head == 0) return rest;
        self.heap[tail].b = rest;
        return head;
    }
    fn sequence(self: *Runtime, list: Ref, env: Ref, depth: usize, host: anytype) linksection(code_section) Error!Ref {
        var p = list;
        var reclaim_at: u16 = 96;
        while (p != 0) {
            try self.tick(depth);
            self.maybeCollectBoundary(depth, p, env, &reclaim_at, 96);
            if (self.heap[p].b == 0) return self.eval(self.heap[p].a, env, depth, host);
            _ = try self.evalRooted(self.heap[p].a, env, depth + 1, host, p, env, 0);
            p = self.heap[p].b;
        }
        return 0;
    }
    fn eval(self: *Runtime, initial_r: Ref, initial_env: Ref, depth: usize, host: anytype) linksection(code_section) Error!Ref {
        var cur_r = initial_r;
        var cur_env = initial_env;
        var owned_frame: Ref = 0;
        var reclaim_at: u16 = 32;
        var body_reclaim_at: u16 = 96;
        var logic_reclaim_at: u16 = 96;
        var cond_test_reclaim_at: u16 = 96;
        var binding_reclaim_at: u16 = 96;
        while (true) {
            try self.tick(depth);
            self.maybeCollectBoundary(depth, cur_r, cur_env, &reclaim_at, 32);
            if (isImmediate(cur_r)) return cur_r;
            const c = &self.heap[cur_r];
            if (c.tag == .symbol) {
                const found = self.lookup(cur_env, cur_r);
                if (found != 0) {
                    const value = self.heap[found].b;
                    if (value == uninitialized_binding) return error.Unbound;
                    return value;
                }
                const op = opcode(self.string(cur_r)) orelse return error.Unbound;
                if (@backingInt(op) < @backingInt(Op.add)) return error.Unbound;
                return makeImmediateOp(op);
            }
            if (c.tag != .pair) return cur_r;
            var argument_storage: [16]Ref = @splat(0);
            var args = try self.arguments(c.b, &argument_storage);
            var tail_recipient: ?Ref = null;
            const special = if (self.tagOf(c.a) == .symbol) opcode(self.string(c.a)) else null;
            if (special) |op| switch (op) {
                .quote => {
                    if (args.len != 1) return error.Arity;
                    return args[0];
                },
                .quasiquote => {
                    if (args.len != 1) return error.Arity;
                    return self.quasiquote(args[0], cur_env, 1, depth + 1, host);
                },
                .unquote, .unquote_splicing => return error.Syntax,
                .if_ => {
                    if (args.len != 3) return error.Arity;
                    const condition = try self.evalRooted(args[0], cur_env, depth + 1, host, cur_r, cur_env, 0);
                    cur_r = args[if (condition == self.no) 2 else 1];
                    continue;
                },
                .begin => {
                    if (args.len == 0) return 0;
                    var begin_reclaim_at: u16 = 96;
                    var p = c.b;
                    while (self.heap[p].b != 0) : (p = self.heap[p].b) {
                        try self.tick(depth);
                        // The subsequent rooted evaluation still refers to
                        // cur_r; keep the entire form alive at this boundary.
                        self.maybeCollectBoundary(depth, cur_r, cur_env, &begin_reclaim_at, 96);
                        _ = try self.evalRooted(self.heap[p].a, cur_env, depth + 1, host, cur_r, cur_env, 0);
                    }
                    cur_r = self.heap[p].a;
                    continue;
                },
                .and_, .or_ => {
                    if (args.len == 0) return if (op == .and_) self.yes else self.no;
                    var i: usize = 0;
                    while (i + 1 < args.len) : (i += 1) {
                        if (self.steps < self.step_budget) self.maybeCollectBoundary(depth, cur_r, cur_env, &logic_reclaim_at, 96);
                        const value = try self.evalRooted(args[i], cur_env, depth + 1, host, cur_r, cur_env, 0);
                        if ((value == self.no) == (op == .and_)) return value;
                    }
                    cur_r = args[i];
                    continue;
                },
                .cond => {
                    for (args, 0..) |clause, index| {
                        var fields_storage: [16]Ref = @splat(0);
                        const fields = try self.arguments(clause, &fields_storage);
                        if (fields.len == 0) return error.Syntax;
                        const is_else = self.tagOf(fields[0]) == .symbol and std.mem.eql(u8, self.string(fields[0]), "else") and self.lookup(cur_env, fields[0]) == 0;
                        if (is_else and (index + 1 != args.len or fields.len == 1)) return error.Syntax;
                        if (!is_else and self.steps < self.step_budget) self.maybeCollectBoundary(depth, cur_r, cur_env, &cond_test_reclaim_at, 96);
                        const value = if (is_else) self.yes else try self.evalRooted(fields[0], cur_env, depth + 1, host, cur_r, cur_env, 0);
                        if (value == self.no) continue;
                        if (fields.len == 1) return value;
                        if (self.tagOf(fields[1]) == .symbol and std.mem.eql(u8, self.string(fields[1]), "=>") and self.lookup(cur_env, fields[1]) == 0) {
                            if (is_else or fields.len != 3) return error.Syntax;
                            tail_recipient = try self.evalRooted(fields[2], cur_env, depth + 1, host, cur_r, cur_env, value);
                            argument_storage[0] = value;
                            args = argument_storage[0..1];
                            break;
                        }
                        var clause_reclaim_at: u16 = 96;
                        for (fields[1 .. fields.len - 1]) |body| {
                            // The child root frame refers to the whole cond,
                            // including its selected clause.
                            if (self.steps < self.step_budget) self.maybeCollectBoundary(depth, cur_r, cur_env, &clause_reclaim_at, 96);
                            _ = try self.evalRooted(body, cur_env, depth + 1, host, cur_r, cur_env, 0);
                        }
                        cur_r = fields[fields.len - 1];
                        break;
                    } else return 0;
                    if (tail_recipient == null) continue;
                },
                .lambda => {
                    if (args.len < 2) return error.Arity;
                    return self.closure(args[0], self.heap[c.b].b, cur_env);
                },
                .define => {
                    if (args.len < 2) return error.Arity;
                    if (self.tagOf(args[0]) == .pair) {
                        const signature = self.heap[args[0]];
                        const value = try self.closure(signature.b, self.heap[c.b].b, cur_env);
                        try self.define(cur_env, signature.a, value);
                    } else {
                        if (args.len != 2) return error.Arity;
                        const value = try self.evalRooted(args[1], cur_env, depth + 1, host, cur_r, cur_env, 0);
                        try self.define(cur_env, args[0], value);
                    }
                    return 0;
                },
                .set => {
                    if (args.len != 2) return error.Arity;
                    if (self.tagOf(args[0]) != .symbol) return error.Type;
                    const found = self.lookup(cur_env, args[0]);
                    if (found == 0 or self.heap[found].b == uninitialized_binding) return error.Unbound;
                    self.heap[found].b = try self.evalRooted(args[1], cur_env, depth + 1, host, cur_r, cur_env, found);
                    return 0;
                },
                .letrec, .letrec_star => {
                    if (args.len < 2) return error.Arity;
                    var bindings_storage: [16]Ref = @splat(0);
                    const entries = try self.arguments(args[0], &bindings_storage);
                    var names: [16]Ref = @splat(0);
                    var initializers: [16]Ref = @splat(0);
                    for (entries, 0..) |entry, i| {
                        var fields: [2]Ref = @splat(0);
                        const binding = try self.arguments(entry, &fields);
                        if (binding.len != 2 or self.tagOf(binding[0]) != .symbol) return error.Syntax;
                        for (names[0..i]) |name| if (name == binding[0]) return error.Syntax;
                        names[i] = binding[0];
                        initializers[i] = binding[1];
                    }
                    const local = try self.pair(0, cur_env);
                    const roots = try self.pushAstRoots(cur_r, cur_env, local);
                    defer self.ast_root_frame_count = roots;
                    for (names[0..entries.len]) |name| try self.define(local, name, uninitialized_binding);
                    for (initializers[0..entries.len], 0..) |initializer, i| {
                        if (self.steps < self.step_budget) self.maybeCollectBoundary(depth, cur_r, local, &binding_reclaim_at, 96);
                        const value = try self.eval(initializer, local, depth + 1, host);
                        self.ast_root_frames[roots].values[i] = value;
                        self.ast_root_frames[roots].value_count = @intCast(i + 1);
                        if (op == .letrec_star) self.heap[self.lookup(local, names[i])].b = value;
                    }
                    if (op == .letrec) for (names[0..entries.len], 0..) |name, i| {
                        self.heap[self.lookup(local, name)].b = self.ast_root_frames[roots].values[i];
                    };
                    var body = self.heap[c.b].b;
                    var let_reclaim_at: u16 = 96;
                    while (self.heap[body].b != 0) : (body = self.heap[body].b) {
                        try self.tick(depth);
                        self.maybeCollectBoundary(depth, body, local, &let_reclaim_at, 96);
                        _ = try self.evalRooted(self.heap[body].a, local, depth + 1, host, body, local, 0);
                    }
                    cur_env = local;
                    owned_frame = local;
                    cur_r = self.heap[body].a;
                    continue;
                },
                .let, .let_star => named_let: {
                    if (op == .let and args.len >= 3 and self.tagOf(args[0]) == .symbol) {
                        const loop_name = args[0];
                        var entries_storage: [16]Ref = @splat(0);
                        const entries = try self.arguments(args[1], &entries_storage);
                        var names: [16]Ref = @splat(0);
                        var initializers: [16]Ref = @splat(0);
                        for (entries, 0..) |entry, i| {
                            var fields: [2]Ref = @splat(0);
                            const binding = try self.arguments(entry, &fields);
                            if (binding.len != 2 or self.tagOf(binding[0]) != .symbol) return error.Syntax;
                            for (names[0..i]) |name| if (name == binding[0]) return error.Syntax;
                            names[i] = binding[0];
                            initializers[i] = binding[1];
                        }
                        const roots = try self.pushAstRoots(cur_r, cur_env, 0);
                        defer self.ast_root_frame_count = roots;
                        for (initializers[0..entries.len], 0..) |initializer, i| {
                            if (self.steps < self.step_budget) self.maybeCollectBoundary(depth, cur_r, cur_env, &binding_reclaim_at, 96);
                            const value = try self.eval(initializer, cur_env, depth + 1, host);
                            self.ast_root_frames[roots].values[i] = value;
                            self.ast_root_frames[roots].value_count = @intCast(i + 1);
                            argument_storage[i] = value;
                        }
                        const local = try self.pair(0, cur_env);
                        self.ast_root_frames[roots].auxiliary = local;
                        var params: Ref = 0;
                        var i = entries.len;
                        while (i > 0) {
                            i -= 1;
                            params = try self.pair(names[i], params);
                        }
                        const body = self.heap[self.heap[c.b].b].b;
                        const proc = try self.closure(params, body, local);
                        try self.define(local, loop_name, proc);
                        tail_recipient = proc;
                        args = argument_storage[0..entries.len];
                        break :named_let;
                    }

                    if (args.len < 2) return error.Arity;
                    var local = try self.pair(0, cur_env);
                    var bindings: [16]Ref = @splat(0);
                    const entries = try self.arguments(args[0], &bindings);
                    for (entries) |entry| {
                        var fields: [2]Ref = @splat(0);
                        const binding = try self.arguments(entry, &fields);
                        if (binding.len != 2 or self.tagOf(binding[0]) != .symbol) return error.Syntax;
                        if (op == .let) {
                            var old = self.heap[local].a;
                            while (old != 0) : (old = self.heap[old].b) if (self.heap[self.heap[old].a].a == binding[0]) return error.Syntax;
                        }
                        // cur_r retains pending initializers; local retains the
                        // already initialized frames and their lexical parents.
                        if (self.steps < self.step_budget) self.maybeCollectBoundary(depth, cur_r, local, &binding_reclaim_at, 96);
                        const value = try self.evalRooted(binding[1], if (op == .let_star) local else cur_env, depth + 1, host, cur_r, cur_env, local);
                        // A fresh frame per let* binding preserves earlier
                        // captured bindings when the same name is shadowed.
                        if (op == .let_star) local = try self.pair(0, local);
                        try self.define(local, binding[0], value);
                    }
                    var body = self.heap[c.b].b;
                    var let_reclaim_at: u16 = 96;
                    if (body == 0) return 0;
                    while (self.heap[body].b != 0) : (body = self.heap[body].b) {
                        try self.tick(depth);
                        self.maybeCollectBoundary(depth, body, local, &let_reclaim_at, 96);
                        _ = try self.evalRooted(self.heap[body].a, local, depth + 1, host, body, local, 0);
                    }
                    cur_env = local;
                    owned_frame = local;
                    cur_r = self.heap[body].a;
                    continue;
                },
                else => {},
            };
            var procedure = if (tail_recipient) |recipient| recipient else blk: {
                const frame_index = try self.pushAstRoots(cur_r, cur_env, 0);
                defer self.ast_root_frame_count = frame_index;
                const proc = try self.eval(c.a, cur_env, depth + 1, host);
                self.ast_root_frames[frame_index].auxiliary = proc;
                for (args, 0..) |*arg, index| {
                    arg.* = try self.eval(arg.*, cur_env, depth + 1, host);
                    self.ast_root_frames[frame_index].values[index] = arg.*;
                    self.ast_root_frames[frame_index].value_count = @intCast(index + 1);
                }
                break :blk proc;
            };
            // `apply` in tail position must transfer control to its target,
            // including nested apply, instead of growing the Zig call stack.
            var expanded_storage: [16]Ref = @splat(0);
            while (self.isApplyProcedure(procedure)) {
                try self.tick(depth);
                const expanded = try self.expandApply(args, &expanded_storage);
                procedure = expanded.procedure;
                @memcpy(argument_storage[0..expanded.values.len], expanded.values);
                args = argument_storage[0..expanded.values.len];
            }
            if (self.tagOf(procedure) == .closure) {
                if (self.heap[procedure].flagged()) {
                    return self.apply(procedure, args, depth + 1, host);
                }
                const cl_params = self.heap[procedure].a;
                const cl_body = self.heap[procedure].b;
                const cl_env = self.heap[procedure].env;
                const parsed = try self.formals(cl_params);
                if (args.len < parsed.count or (parsed.rest == 0 and args.len != parsed.count)) return error.Arity;
                if (parsed.rest == 0 and cur_env == owned_frame and cur_env != cl_env and cur_env != self.global and self.heap[cur_env].b == cl_env and self.canReuseFrame(cur_env, parsed.fixed[0..parsed.count])) {
                    self.updateFrameBindings(cur_env, args);
                    var body = cl_body;
                    if (body == 0) return 0;
                    while (self.heap[body].b != 0) : (body = self.heap[body].b) {
                        try self.tick(depth);
                        self.maybeCollectBoundary(depth, body, cur_env, &body_reclaim_at, 96);
                        _ = try self.evalRooted(self.heap[body].a, cur_env, depth + 1, host, body, cur_env, 0);
                    }
                    cur_r = self.heap[body].a;
                    continue;
                }
                const local = try self.pair(0, cl_env);
                try self.bindFormals(local, parsed, args);
                var body = cl_body;
                if (body == 0) return 0;
                while (self.heap[body].b != 0) : (body = self.heap[body].b) {
                    try self.tick(depth);
                    self.maybeCollectBoundary(depth, body, local, &body_reclaim_at, 96);
                    _ = try self.evalRooted(self.heap[body].a, local, depth + 1, host, body, local, 0);
                }
                cur_env = local;
                owned_frame = local;
                cur_r = self.heap[body].a;
                continue;
            }
            return self.apply(procedure, args, depth + 1, host);
        }
    }

    pub fn runVm(self: *Runtime, start_ip: u16, host: anytype) linksection(code_section) Error!Ref {
        var ip = start_ip;
        var fp: u8 = if (self.call_sp > 0) self.call_stack[self.call_sp - 1].fp + 1 else 0;
        while (ip < self.bytecode_len) {
            try self.tick(self.call_sp);
            const raw_op = self.bytecode[ip];
            const op = toBcOp(raw_op) orelse return error.Syntax;
            ip += 1;
            switch (op) {
                .const_val => {
                    if (ip + 2 > self.bytecode_len) return error.Syntax;
                    const val = std.mem.readInt(u16, self.bytecode[ip..][0..2], .little);
                    ip += 2;
                    try self.pushEval(val);
                },
                .pop => {
                    if (self.eval_sp <= fp) return error.Syntax;
                    self.eval_sp -= 1;
                },
                .dup => {
                    if (self.eval_sp <= fp) return error.Syntax;
                    try self.pushEval(self.eval_stack[self.eval_sp - 1]);
                },
                .load_local => {
                    if (ip >= self.bytecode_len) return error.Syntax;
                    const slot = self.bytecode[ip];
                    ip += 1;
                    const idx = fp + slot;
                    if (idx >= self.eval_sp) return error.Syntax;
                    try self.pushEval(self.eval_stack[idx]);
                },
                .store_local => {
                    if (ip >= self.bytecode_len) return error.Syntax;
                    const slot = self.bytecode[ip];
                    ip += 1;
                    const idx = fp + slot;
                    if (self.eval_sp <= fp or idx >= self.eval_stack.len) return error.Syntax;
                    self.eval_sp -= 1;
                    self.eval_stack[idx] = self.eval_stack[self.eval_sp];
                },
                .load_global => {
                    if (ip + 2 > self.bytecode_len) return error.Syntax;
                    const sym = std.mem.readInt(u16, self.bytecode[ip..][0..2], .little);
                    ip += 2;
                    const found = self.lookup(self.global, sym);
                    if (found == 0) {
                        const op_code = opcode(self.string(sym)) orelse return error.Unbound;
                        if (@backingInt(op_code) < @backingInt(Op.add)) return error.Unbound;
                        try self.pushEval(makeImmediateOp(op_code));
                    } else {
                        try self.pushEval(self.heap[found].b);
                    }
                },
                .def_global => {
                    if (ip + 2 > self.bytecode_len) return error.Syntax;
                    const sym = std.mem.readInt(u16, self.bytecode[ip..][0..2], .little);
                    ip += 2;
                    if (self.eval_sp <= fp) return error.Syntax;
                    self.eval_sp -= 1;
                    const val = self.eval_stack[self.eval_sp];
                    try self.define(self.global, sym, val);
                    try self.pushEval(0);
                },
                .jump => {
                    if (ip + 2 > self.bytecode_len) return error.Syntax;
                    const offset: i16 = @bitCast(std.mem.readInt(u16, self.bytecode[ip..][0..2], .little));
                    ip += 2;
                    const next = @as(i32, ip) + offset;
                    if (next < 0 or next > self.bytecode_len) return error.Syntax;
                    ip = @as(u16, @intCast(next));
                },
                .jump_if_false => {
                    if (ip + 2 > self.bytecode_len) return error.Syntax;
                    const offset: i16 = @bitCast(std.mem.readInt(u16, self.bytecode[ip..][0..2], .little));
                    ip += 2;
                    if (self.eval_sp <= fp) return error.Syntax;
                    self.eval_sp -= 1;
                    const cond = self.eval_stack[self.eval_sp];
                    if (cond == self.no) {
                        const next = @as(i32, ip) + offset;
                        if (next < 0 or next > self.bytecode_len) return error.Syntax;
                        ip = @as(u16, @intCast(next));
                    }
                },
                .add => {
                    if (self.eval_sp < fp + 2) return error.Syntax;
                    const b = self.eval_stack[self.eval_sp - 1];
                    const a = self.eval_stack[self.eval_sp - 2];
                    const ia = try self.integer(a);
                    const ib = try self.integer(b);
                    const checked = @addWithOverflow(ia, ib);
                    if (checked[1] != 0) return error.Overflow;
                    self.eval_stack[self.eval_sp - 2] = try self.number(checked[0]);
                    self.eval_sp -= 1;
                },
                .sub => {
                    if (self.eval_sp < fp + 2) return error.Syntax;
                    const b = self.eval_stack[self.eval_sp - 1];
                    const a = self.eval_stack[self.eval_sp - 2];
                    const ia = try self.integer(a);
                    const ib = try self.integer(b);
                    const checked = @subWithOverflow(ia, ib);
                    if (checked[1] != 0) return error.Overflow;
                    self.eval_stack[self.eval_sp - 2] = try self.number(checked[0]);
                    self.eval_sp -= 1;
                },
                .mul => {
                    if (self.eval_sp < fp + 2) return error.Syntax;
                    const b = self.eval_stack[self.eval_sp - 1];
                    const a = self.eval_stack[self.eval_sp - 2];
                    const ia = try self.integer(a);
                    const ib = try self.integer(b);
                    const checked = @mulWithOverflow(ia, ib);
                    if (checked[1] != 0) return error.Overflow;
                    self.eval_stack[self.eval_sp - 2] = try self.number(checked[0]);
                    self.eval_sp -= 1;
                },
                .equal => {
                    if (self.eval_sp < fp + 2) return error.Syntax;
                    const b = self.eval_stack[self.eval_sp - 1];
                    const a = self.eval_stack[self.eval_sp - 2];
                    const is_eq = try self.integer(a) == try self.integer(b);
                    self.eval_stack[self.eval_sp - 2] = if (is_eq) self.yes else self.no;
                    self.eval_sp -= 1;
                },
                .less => {
                    if (self.eval_sp < fp + 2) return error.Syntax;
                    const b = self.eval_stack[self.eval_sp - 1];
                    const a = self.eval_stack[self.eval_sp - 2];
                    const ia = try self.integer(a);
                    const ib = try self.integer(b);
                    self.eval_stack[self.eval_sp - 2] = if (ia < ib) self.yes else self.no;
                    self.eval_sp -= 1;
                },
                .not => {
                    if (self.eval_sp <= fp) return error.Syntax;
                    const a = self.eval_stack[self.eval_sp - 1];
                    self.eval_stack[self.eval_sp - 1] = if (a == self.no) self.yes else self.no;
                },
                .cons => {
                    if (self.eval_sp < fp + 2) return error.Syntax;
                    const b = self.eval_stack[self.eval_sp - 1];
                    const a = self.eval_stack[self.eval_sp - 2];
                    const p = try self.pair(a, b);
                    self.eval_stack[self.eval_sp - 2] = p;
                    self.eval_sp -= 1;
                },
                .car => {
                    if (self.eval_sp <= fp) return error.Syntax;
                    const p = self.eval_stack[self.eval_sp - 1];
                    if (self.tagOf(p) != .pair) return error.Type;
                    self.eval_stack[self.eval_sp - 1] = self.heap[p].a;
                },
                .cdr => {
                    if (self.eval_sp <= fp) return error.Syntax;
                    const p = self.eval_stack[self.eval_sp - 1];
                    if (self.tagOf(p) != .pair) return error.Type;
                    self.eval_stack[self.eval_sp - 1] = self.heap[p].b;
                },
                .null_p => {
                    if (self.eval_sp <= fp) return error.Syntax;
                    const p = self.eval_stack[self.eval_sp - 1];
                    self.eval_stack[self.eval_sp - 1] = if (p == 0) self.yes else self.no;
                },
                .pair_p => {
                    if (self.eval_sp <= fp) return error.Syntax;
                    const p = self.eval_stack[self.eval_sp - 1];
                    self.eval_stack[self.eval_sp - 1] = if (self.tagOf(p) == .pair) self.yes else self.no;
                },
                .call => {
                    if (ip >= self.bytecode_len) return error.Syntax;
                    const argc = self.bytecode[ip];
                    ip += 1;
                    if (self.eval_sp < fp + argc + 1) return error.Syntax;
                    const proc_idx = self.eval_sp - 1 - argc;
                    const proc = self.eval_stack[proc_idx];
                    if (self.tagOf(proc) == .closure and self.heap[proc].flagged()) {
                        if (self.heap[proc].a != argc) return error.Arity;
                        if (self.call_sp >= call_stack_capacity) return error.Depth;
                        self.call_stack[self.call_sp] = .{
                            .return_ip = ip,
                            .fp = fp,
                            .env = self.heap[proc].env,
                        };
                        self.call_sp += 1;
                        fp = proc_idx + 1;
                        ip = self.heap[proc].b;
                    } else {
                        const args = self.eval_stack[proc_idx + 1 .. self.eval_sp];
                        const res = try self.apply(proc, args, self.call_sp + 1, host);
                        self.eval_stack[proc_idx] = res;
                        self.eval_sp = proc_idx + 1;
                    }
                },
                .ret => {
                    if (self.eval_sp < fp) return error.Syntax;
                    const ret_val = if (self.eval_sp > fp) self.eval_stack[self.eval_sp - 1] else 0;
                    if (self.call_sp == 0) return ret_val;
                    self.call_sp -= 1;
                    const frame = self.call_stack[self.call_sp];
                    ip = frame.return_ip;
                    self.eval_sp = if (fp > 0) fp - 1 else 0;
                    fp = frame.fp;
                    try self.pushEval(ret_val);
                    if (ip >= self.bytecode_len) return ret_val;
                },
                .halt => {
                    if (self.eval_sp <= fp) return 0;
                    return self.eval_stack[self.eval_sp - 1];
                },
            }
        }
        if (self.eval_sp > 0) return self.eval_stack[self.eval_sp - 1];
        return 0;
    }

    pub fn compile(self: *Runtime, expr: Ref) linksection(code_section) Error!u16 {
        const start_ip = self.bytecode_len;
        var compiler = Compiler{};
        try self.compileExpr(&compiler, expr, false);
        try self.emitBcOp(.halt);
        return start_ip;
    }

    pub fn compileSequence(self: *Runtime, forms: Ref) linksection(code_section) Error!u16 {
        const start_ip = self.bytecode_len;
        var compiler = Compiler{};
        var head = forms;
        if (head == 0) {
            try self.emitBcOp(.const_val);
            try self.emitBcU16(0);
            try self.emitBcOp(.halt);
            return start_ip;
        }
        while (head != 0) {
            const next_head = self.heap[head].b;
            const is_last = (next_head == 0);
            try self.compileExpr(&compiler, self.heap[head].a, is_last);
            if (!is_last) try self.emitBcOp(.pop);
            head = next_head;
        }
        try self.emitBcOp(.halt);
        return start_ip;
    }

    pub fn compileAndRun(self: *Runtime, expr: Ref, host: anytype) linksection(code_section) Error!Ref {
        const saved_eval_sp = self.eval_sp;
        const saved_call_sp = self.call_sp;
        defer self.eval_sp = saved_eval_sp;
        defer self.call_sp = saved_call_sp;
        const saved_bytecode_len = self.bytecode_len;
        const start_ip = self.compile(expr) catch |err| {
            self.bytecode_len = saved_bytecode_len;
            return err;
        };
        return self.runVm(start_ip, host);
    }

    const Compiler = struct {
        locals: [16]Ref = @splat(0),
        local_count: u8 = 0,
        fn_name: Ref = 0,
        fn_entry_ip: u16 = 0,

        inline fn resolveLocal(self: *const Compiler, sym: Ref) ?u8 {
            for (self.locals[0..self.local_count], 0..) |loc, i| {
                if (loc == sym) return @intCast(i);
            }
            return null;
        }
    };

    fn emitBcByte(self: *Runtime, b: u8) linksection(code_section) Error!void {
        if (self.bytecode_len >= bytecode_capacity) return error.Syntax;
        self.bytecode[self.bytecode_len] = b;
        self.bytecode_len += 1;
    }

    fn emitBcOp(self: *Runtime, op: BcOp) linksection(code_section) Error!void {
        try self.emitBcByte(@backingInt(op));
    }

    fn emitBcU16(self: *Runtime, val: u16) linksection(code_section) Error!void {
        if (self.bytecode_len + 2 > bytecode_capacity) return error.Syntax;
        std.mem.writeInt(u16, self.bytecode[self.bytecode_len..][0..2], val, .little);
        self.bytecode_len += 2;
    }

    fn emitBcI16(self: *Runtime, val: i16) linksection(code_section) Error!void {
        try self.emitBcU16(@as(u16, @bitCast(val)));
    }

    fn emitBcJumpPlaceholder(self: *Runtime) linksection(code_section) Error!u16 {
        const pos = self.bytecode_len;
        try self.emitBcI16(0);
        return pos;
    }

    fn patchBcJump(self: *Runtime, placeholder_pos: u16) linksection(code_section) Error!void {
        const target_pos = self.bytecode_len;
        const diff = @as(i32, target_pos) - @as(i32, placeholder_pos + 2);
        if (diff < -32768 or diff > 32767) return error.Syntax;
        std.mem.writeInt(u16, self.bytecode[placeholder_pos..][0..2], @as(u16, @bitCast(@as(i16, @intCast(diff)))), .little);
    }

    noinline fn compileExpr(self: *Runtime, c: *Compiler, expr: Ref, is_tail: bool) linksection(code_section) Error!void {
        if (isImmediate(expr)) {
            try self.emitBcOp(.const_val);
            try self.emitBcU16(expr);
            return;
        }
        const tag = self.tagOf(expr);
        if (tag == .symbol) {
            if (c.resolveLocal(expr)) |slot| {
                try self.emitBcOp(.load_local);
                try self.emitBcByte(slot);
            } else {
                try self.emitBcOp(.load_global);
                try self.emitBcU16(expr);
            }
            return;
        }
        if (tag != .pair) {
            try self.emitBcOp(.const_val);
            try self.emitBcU16(expr);
            return;
        }

        const head = self.heap[expr].a;
        const tail = self.heap[expr].b;
        var argument_storage: [16]Ref = @splat(0);
        const args = try self.arguments(tail, &argument_storage);

        const special = if (self.tagOf(head) == .symbol) opcode(self.string(head)) else null;
        if (special) |op| switch (op) {
            .lambda, .let, .let_star, .letrec, .letrec_star, .quasiquote, .unquote, .unquote_splicing, .and_, .or_ => return error.CannotCompile,
            .quote => {
                if (args.len != 1) return error.Arity;
                try self.emitBcOp(.const_val);
                try self.emitBcU16(args[0]);
                return;
            },
            .if_ => {
                if (args.len != 3) return error.Arity;
                try self.compileExpr(c, args[0], false);
                try self.emitBcOp(.jump_if_false);
                const else_placeholder = try self.emitBcJumpPlaceholder();
                try self.compileExpr(c, args[1], is_tail);
                try self.emitBcOp(.jump);
                const end_placeholder = try self.emitBcJumpPlaceholder();
                try self.patchBcJump(else_placeholder);
                try self.compileExpr(c, args[2], is_tail);
                try self.patchBcJump(end_placeholder);
                return;
            },
            .begin => {
                if (args.len == 0) {
                    try self.emitBcOp(.const_val);
                    try self.emitBcU16(0);
                    return;
                }
                for (args[0 .. args.len - 1]) |arg| {
                    try self.compileExpr(c, arg, false);
                    try self.emitBcOp(.pop);
                }
                try self.compileExpr(c, args[args.len - 1], is_tail);
                return;
            },
            .define => {
                if (args.len < 2) return error.Arity;
                if (self.tagOf(args[0]) == .pair) {
                    const sig_name = self.heap[args[0]].a;
                    const sig_params = self.heap[args[0]].b;
                    var param_storage: [16]Ref = @splat(0);
                    const params = try self.arguments(sig_params, &param_storage);

                    try self.emitBcOp(.jump);
                    const body_skip = try self.emitBcJumpPlaceholder();

                    const entry_ip = self.bytecode_len;
                    var sub_compiler = Compiler{
                        .fn_name = sig_name,
                        .fn_entry_ip = entry_ip,
                    };
                    for (params) |p| {
                        sub_compiler.locals[sub_compiler.local_count] = p;
                        sub_compiler.local_count += 1;
                    }

                    var cur_body = self.heap[tail].b;
                    while (cur_body != 0) {
                        const next_body = self.heap[cur_body].b;
                        const is_last = (next_body == 0);
                        try self.compileExpr(&sub_compiler, self.heap[cur_body].a, is_last);
                        if (!is_last) try self.emitBcOp(.pop);
                        cur_body = next_body;
                    }
                    try self.emitBcOp(.ret);

                    try self.patchBcJump(body_skip);

                    const cl = try self.alloc(.closure);
                    self.heap[cl].setFlag();
                    self.heap[cl].a = @intCast(params.len);
                    self.heap[cl].b = entry_ip;
                    self.heap[cl].env = self.global;

                    try self.emitBcOp(.const_val);
                    try self.emitBcU16(cl);
                    try self.emitBcOp(.def_global);
                    try self.emitBcU16(sig_name);
                    return;
                } else {
                    if (args.len != 2) return error.Arity;
                    try self.compileExpr(c, args[1], false);
                    try self.emitBcOp(.def_global);
                    try self.emitBcU16(args[0]);
                    return;
                }
            },
            .set => {
                if (args.len != 2) return error.Arity;
                try self.compileExpr(c, args[1], false);
                if (c.resolveLocal(args[0])) |slot| {
                    try self.emitBcOp(.store_local);
                    try self.emitBcByte(slot);
                    try self.emitBcOp(.const_val);
                    try self.emitBcU16(0);
                } else {
                    try self.emitBcOp(.def_global);
                    try self.emitBcU16(args[0]);
                }
                return;
            },
            .add => {
                if (args.len == 2) {
                    try self.compileExpr(c, args[0], false);
                    try self.compileExpr(c, args[1], false);
                    try self.emitBcOp(.add);
                    return;
                }
            },
            .sub => {
                if (args.len == 2) {
                    try self.compileExpr(c, args[0], false);
                    try self.compileExpr(c, args[1], false);
                    try self.emitBcOp(.sub);
                    return;
                }
            },
            .mul => {
                if (args.len == 2) {
                    try self.compileExpr(c, args[0], false);
                    try self.compileExpr(c, args[1], false);
                    try self.emitBcOp(.mul);
                    return;
                }
            },
            .equal => {
                if (args.len == 2) {
                    try self.compileExpr(c, args[0], false);
                    try self.compileExpr(c, args[1], false);
                    try self.emitBcOp(.equal);
                    return;
                }
            },
            .less => {
                if (args.len == 2) {
                    try self.compileExpr(c, args[0], false);
                    try self.compileExpr(c, args[1], false);
                    try self.emitBcOp(.less);
                    return;
                }
            },
            .not => {
                if (args.len == 1) {
                    try self.compileExpr(c, args[0], false);
                    try self.emitBcOp(.not);
                    return;
                }
            },
            .cons => {
                if (args.len == 2) {
                    try self.compileExpr(c, args[0], false);
                    try self.compileExpr(c, args[1], false);
                    try self.emitBcOp(.cons);
                    return;
                }
            },
            .car => {
                if (args.len == 1) {
                    try self.compileExpr(c, args[0], false);
                    try self.emitBcOp(.car);
                    return;
                }
            },
            .cdr => {
                if (args.len == 1) {
                    try self.compileExpr(c, args[0], false);
                    try self.emitBcOp(.cdr);
                    return;
                }
            },
            .nullq => {
                if (args.len == 1) {
                    try self.compileExpr(c, args[0], false);
                    try self.emitBcOp(.null_p);
                    return;
                }
            },
            .pairq => {
                if (args.len == 1) {
                    try self.compileExpr(c, args[0], false);
                    try self.emitBcOp(.pair_p);
                    return;
                }
            },
            else => {},
        };

        if (c.fn_name != 0 and head == c.fn_name and is_tail and args.len == c.local_count) {
            for (args) |arg| {
                try self.compileExpr(c, arg, false);
            }
            var i: usize = args.len;
            while (i > 0) {
                i -= 1;
                try self.emitBcOp(.store_local);
                try self.emitBcByte(@intCast(i));
            }
            try self.emitBcOp(.jump);
            const diff = @as(i32, c.fn_entry_ip) - @as(i32, self.bytecode_len + 2);
            try self.emitBcI16(@intCast(diff));
            return;
        }

        try self.compileExpr(c, head, false);
        for (args) |arg| {
            try self.compileExpr(c, arg, false);
        }
        try self.emitBcOp(.call);
        try self.emitBcByte(@intCast(args.len));
    }

    fn integer(self: *const Runtime, r: Ref) linksection(code_section) Error!i32 {
        if (isImmediateInt(r)) return toImmediateInt(r);
        if (r >= cells or self.heap[r].tag != .integer) return error.Type;
        return self.heap[r].integer;
    }
    // eq? chooses the eqv? result for numeric objects, which R7RS permits.
    fn equivalent(self: *const Runtime, a: Ref, b: Ref) linksection(code_section) Error!bool {
        if (a == b) return true;
        const ta = self.tagOf(a);
        const tb = self.tagOf(b);
        const exact_a = ta == .integer or ta == .rational;
        const exact_b = tb == .integer or tb == .rational;
        if (exact_a and exact_b) {
            const x = try self.fraction(a);
            const y = try self.fraction(b);
            return @as(i64, x.numerator) * y.denominator == @as(i64, y.numerator) * x.denominator;
        }
        if (ta != tb) return false;
        return switch (ta) {
            .inexact => @as(u64, @bitCast(try self.asInexact(a))) == @as(u64, @bitCast(try self.asInexact(b))),
            .symbol => std.mem.eql(u8, self.string(a), self.string(b)),
            else => false,
        };
    }

    // Congruence closure over heap pairs. Each union decreases the number
    // of disjoint pair classes, so at most cells-1 unions can occur even for
    // cyclic graphs. GC cannot run inside this helper: borrow its mark queue
    // for union-find parents and the PSRAM-resident work array for edges.
    fn equalValues(self: *Runtime, left: Ref, right: Ref, depth: usize) linksection(code_section) Error!bool {
        @memset(&self.queue, 0);
        var used: usize = 1;
        self.equality_work[0] = @as(u32, left) | (@as(u32, right) << 16);
        while (used != 0) {
            try self.tick(depth);
            used -= 1;
            const work = self.equality_work[used];
            const a: Ref = @truncate(work);
            const b: Ref = @truncate(work >> 16);
            if (try self.equivalent(a, b)) continue;
            const ta = self.tagOf(a);
            const tb = self.tagOf(b);
            if (ta != tb) return false;
            if (ta == .string) {
                if (!std.mem.eql(u8, self.string(a), self.string(b))) return false;
                continue;
            }
            if (ta != .pair) return false;
            var root_a = a;
            while (self.queue[root_a] != 0) root_a = self.queue[root_a];
            var root_b = b;
            while (self.queue[root_b] != 0) root_b = self.queue[root_b];
            if (root_a == root_b) continue;
            self.queue[root_a] = root_b;
            if (used + 2 > self.equality_work.len) return error.Depth;
            self.equality_work[used] = @as(u32, self.heap[a].b) | (@as(u32, self.heap[b].b) << 16);
            self.equality_work[used + 1] = @as(u32, self.heap[a].a) | (@as(u32, self.heap[b].a) << 16);
            used += 2;
        }
        return true;
    }
    fn apply(self: *Runtime, procedure: Ref, args: []const Ref, depth: usize, host: anytype) linksection(code_section) Error!Ref {
        try self.tick(depth);
        const op: Op = if (isImmediateOp(procedure))
            toImmediateOp(procedure)
        else blk: {
            if (isImmediate(procedure)) return error.Type;
            const c = &self.heap[procedure];
            if (c.tag == .closure) {
                if (c.flagged()) {
                    if (c.a != args.len) return error.Arity;
                    const saved_eval_sp = self.eval_sp;
                    const saved_call_sp = self.call_sp;
                    defer self.eval_sp = saved_eval_sp;
                    defer self.call_sp = saved_call_sp;
                    try self.pushEval(procedure);
                    for (args) |arg| try self.pushEval(arg);
                    if (self.call_sp >= call_stack_capacity) return error.Depth;
                    self.call_stack[self.call_sp] = .{
                        .return_ip = self.bytecode_len,
                        .fp = saved_eval_sp,
                        .env = c.env,
                    };
                    self.call_sp += 1;
                    const res = try self.runVm(c.b, host);
                    return res;
                }
                const parsed = try self.formals(c.a);
                if (args.len < parsed.count or (parsed.rest == 0 and args.len != parsed.count)) return error.Arity;
                const local = try self.pair(0, c.env);
                try self.bindFormals(local, parsed, args);
                return self.sequence(c.b, local, depth, host);
            }
            if (c.tag != .native) return error.Type;
            break :blk @fromBackingInt(@intCast(c.integer));
        };
        switch (op) {
            .add, .sub, .mul, .divide => {
                if ((op == .sub or op == .divide) and args.len == 0) return error.Arity;
                var has_inexact = false;
                for (args) |arg| if (self.tagOf(arg) == .inexact) {
                    has_inexact = true;
                };
                if (has_inexact) {
                    var value: f64 = if (op == .mul or op == .divide) 1 else 0;
                    for (args, 0..) |arg, index| {
                        const current = try self.asInexact(arg);
                        if ((op == .sub or op == .divide) and index == 0 and args.len != 1) {
                            value = current;
                            continue;
                        }
                        if (op == .divide and current == 0) {
                            if (self.tagOf(arg) != .inexact) return error.DivisionByZero;
                            const numerator_bits: u64 = @bitCast(value);
                            const denominator_bits: u64 = @bitCast(current);
                            const sign = (numerator_bits ^ denominator_bits) & (@as(u64, 1) << 63);
                            value = if (value == 0 or std.math.isNan(value)) @bitCast(@as(u64, 0x7ff8000000000000)) else @bitCast(sign | @as(u64, 0x7ff0000000000000));
                            continue;
                        }
                        if (op == .sub and args.len == 1) {
                            value = -current;
                            continue;
                        }
                        value = switch (op) {
                            .add => value + current,
                            .sub => value - current,
                            .mul => value * current,
                            .divide => value / current,
                            else => unreachable,
                        };
                    }
                    return self.inexactNumber(value);
                }
                var n = Fraction{ .numerator = if (op == .mul or op == .divide) 1 else 0, .denominator = 1 };
                for (args, 0..) |arg, index| {
                    const v = try self.fraction(arg);
                    if ((op == .sub or op == .divide) and index == 0 and args.len != 1) {
                        n = v;
                        continue;
                    }
                    const an: i64 = n.numerator;
                    const ad: i64 = n.denominator;
                    const bn: i64 = v.numerator;
                    const bd: i64 = v.denominator;
                    n = switch (op) {
                        .add => try normalizeFraction(an * bd + bn * ad, ad * bd),
                        .sub => try normalizeFraction(an * bd - bn * ad, ad * bd),
                        .mul => try normalizeFraction(an * bn, ad * bd),
                        .divide => try normalizeFraction(an * bd, ad * bn),
                        else => unreachable,
                    };
                }
                return self.fractionNumber(n);
            },
            .equal, .less, .greater, .less_equal, .greater_equal => {
                if (args.len < 2) return error.Arity;
                var matches = true;
                for (args[1..], 0..) |current, index| {
                    const order = try self.compareNumbers(args[index], current);
                    const pair_matches = if (order) |o| switch (op) {
                        .equal => o == .eq,
                        .less => o == .lt,
                        .greater => o == .gt,
                        .less_equal => o != .gt,
                        .greater_equal => o != .lt,
                        else => unreachable,
                    } else false;
                    matches = matches and pair_matches;
                }
                return if (matches) self.yes else self.no;
            },
            .numberq, .complexq, .realq, .rationalq, .integerq, .exactq, .inexactq => {
                if (args.len != 1) return error.Arity;
                const tag = self.tagOf(args[0]);
                const numeric = tag == .integer or tag == .rational or tag == .inexact;
                if (!numeric and (op == .exactq or op == .inexactq)) return error.Type;
                var result = numeric;
                if (numeric) switch (op) {
                    .exactq => result = tag != .inexact,
                    .inexactq => result = tag == .inexact,
                    .rationalq => if (tag == .inexact) {
                        result = std.math.isFinite(try self.asInexact(args[0]));
                    },
                    .integerq => if (tag == .rational) {
                        result = false;
                    } else if (tag == .inexact) {
                        const bits: u64 = @bitCast(try self.asInexact(args[0]));
                        const magnitude = bits & 0x7fffffffffffffff;
                        const exponent: u11 = @truncate(magnitude >> 52);
                        if (exponent == 0x7ff) result = false else if (exponent < 1023) result = magnitude == 0 else if (exponent >= 1075) result = true else {
                            const fractional_bits: u6 = @intCast(1075 - @as(u32, exponent));
                            result = (magnitude & ((@as(u64, 1) << fractional_bits) - 1)) == 0;
                        }
                    },
                    else => {},
                };
                return if (result) self.yes else self.no;
            },
            .expt_proc => {
                if (args.len != 2) return error.Arity;
                const exponent = try self.boundedInteger(args[1]);
                var power: u32 = @intCast(if (exponent < 0) -exponent else exponent);
                const inexact = self.tagOf(args[0]) == .inexact or self.tagOf(args[1]) == .inexact;
                if (inexact) {
                    var factor = try self.asInexact(args[0]);
                    if (exponent < 0) {
                        if (factor == 0) return error.DivisionByZero;
                        factor = 1.0 / factor;
                    }
                    var result: f64 = 1.0;
                    while (power != 0) {
                        if ((power & 1) != 0) result *= factor;
                        power >>= 1;
                        if (power != 0) factor *= factor;
                    }
                    return self.inexactNumber(result);
                }
                var factor = try self.fraction(args[0]);
                if (exponent < 0) factor = try normalizeFraction(factor.denominator, factor.numerator);
                var result = Fraction{ .numerator = 1, .denominator = 1 };
                while (power != 0) {
                    if ((power & 1) != 0) result = try normalizeFraction(@as(i64, result.numerator) * factor.numerator, @as(i64, result.denominator) * factor.denominator);
                    power >>= 1;
                    if (power != 0) factor = try normalizeFraction(@as(i64, factor.numerator) * factor.numerator, @as(i64, factor.denominator) * factor.denominator);
                }
                return self.fractionNumber(result);
            },
            .min_proc, .max_proc => {
                if (args.len == 0) return error.Arity;
                var selected: Ref = 0;
                var nan: Ref = 0;
                var any_inexact = false;
                var negative_zero = false;
                var positive_zero = false;
                for (args) |arg| {
                    const self_order = try self.compareNumbers(arg, arg);
                    const inexact = self.tagOf(arg) == .inexact;
                    any_inexact = any_inexact or inexact;
                    if (self_order == null) {
                        nan = arg;
                        continue;
                    }
                    if (inexact) {
                        const bits: u64 = @bitCast(try self.asInexact(arg));
                        if ((bits & 0x7fffffffffffffff) == 0) {
                            if (bits >> 63 != 0) negative_zero = true else positive_zero = true;
                        }
                    } else {
                        const value = try self.fraction(arg);
                        if (value.numerator == 0) positive_zero = true;
                    }
                    if (selected == 0) {
                        selected = arg;
                        continue;
                    }
                    const order = (try self.compareNumbers(arg, selected)).?;
                    if ((op == .min_proc and order == .lt) or (op == .max_proc and order == .gt)) selected = arg;
                }
                if (nan != 0) return nan;
                if (!any_inexact) return selected;
                const result = try self.asInexact(selected);
                if (result == 0) {
                    const sign: u64 = if (op == .min_proc and negative_zero or op == .max_proc and !positive_zero and negative_zero) @as(u64, 1) << 63 else 0;
                    return self.inexactNumber(@bitCast(sign));
                }
                if (self.tagOf(selected) == .inexact) return selected;
                return self.inexactNumber(result);
            },
            .numerator_proc, .denominator_proc => {
                if (args.len != 1) return error.Arity;
                if (self.tagOf(args[0]) != .inexact) {
                    const v = try self.fraction(args[0]);
                    return self.number(if (op == .numerator_proc) v.numerator else v.denominator);
                }
                const value = try self.asInexact(args[0]);
                const bits: u64 = @bitCast(value);
                const magnitude = bits & 0x7fffffffffffffff;
                const exponent: u11 = @truncate(magnitude >> 52);
                if (exponent == 0x7ff) return error.Type;
                if (magnitude == 0) return self.inexactNumber(if (op == .numerator_proc) 0.0 else 1.0);
                var significand: u64 = magnitude & 0x000fffffffffffff;
                var shift: i32 = if (exponent == 0) -1074 else @as(i32, exponent) - 1075;
                if (exponent != 0) significand |= @as(u64, 1) << 52;
                while ((significand & 1) == 0) {
                    significand >>= 1;
                    shift += 1;
                }
                if (shift >= 0) return if (op == .numerator_proc) args[0] else self.inexactNumber(1.0);
                if (op == .numerator_proc) {
                    const n: f64 = @floatFromInt(significand);
                    return self.inexactNumber(if (bits >> 63 == 0) n else -n);
                }
                if (shift < -1023) return error.Overflow;
                const denominator_bits: u64 = @as(u64, @intCast(1023 - shift)) << 52;
                return self.inexactNumber(@bitCast(denominator_bits));
            },
            .square_proc => {
                if (args.len != 1) return error.Arity;
                return self.apply(makeImmediateOp(.mul), &.{ args[0], args[0] }, depth + 1, host);
            },
            .quotient_proc, .remainder_proc, .modulo_proc, .floor_quotient_proc, .floor_remainder_proc, .truncate_quotient_proc, .truncate_remainder_proc => {
                if (args.len != 2) return error.Arity;
                const a = try self.boundedInteger(args[0]);
                const b = try self.boundedInteger(args[1]);
                if (b == 0) return error.DivisionByZero;
                const inexact = self.tagOf(args[0]) == .inexact or self.tagOf(args[1]) == .inexact;
                const truncate = @divTrunc(a, b);
                const remainder = @rem(a, b);
                const use_floor = op == .modulo_proc or op == .floor_quotient_proc or op == .floor_remainder_proc;
                const adjust = use_floor and remainder != 0 and ((a < 0) != (b < 0));
                const result = switch (op) {
                    .quotient_proc, .truncate_quotient_proc => truncate,
                    .floor_quotient_proc => truncate - @as(i64, @intFromBool(adjust)),
                    .remainder_proc, .truncate_remainder_proc => remainder,
                    .modulo_proc, .floor_remainder_proc => if (adjust) remainder + b else remainder,
                    else => unreachable,
                };
                return self.integerResult(result, inexact);
            },
            .gcd_proc, .lcm_proc => {
                var value: i64 = if (op == .gcd_proc) 0 else 1;
                var inexact = false;
                for (args) |arg| {
                    const n = try self.boundedInteger(arg);
                    inexact = inexact or self.tagOf(arg) == .inexact;
                    if (op == .gcd_proc) value = integerGcd(value, n) else if (value == 0 or n == 0) {
                        value = 0;
                    } else {
                        const factor = @divExact(value, integerGcd(value, n));
                        const product = std.math.mul(i64, factor, n) catch return error.Overflow;
                        if (product == std.math.minInt(i64)) return error.Overflow;
                        value = if (product < 0) -product else product;
                    }
                }
                return self.integerResult(value, inexact);
            },
            .zeroq, .positiveq, .negativeq => {
                if (args.len != 1) return error.Arity;
                const order = try self.compareNumbers(args[0], makeImmediateInt(0));
                const result = if (order) |o| switch (op) {
                    .zeroq => o == .eq,
                    .positiveq => o == .gt,
                    .negativeq => o == .lt,
                    else => unreachable,
                } else false;
                return if (result) self.yes else self.no;
            },
            .oddq, .evenq => {
                if (args.len != 1) return error.Arity;
                const odd = try self.numericOdd(args[0]);
                return if (odd == (op == .oddq)) self.yes else self.no;
            },
            .exact_integerq => {
                if (args.len != 1) return error.Arity;
                return if (self.tagOf(args[0]) == .integer) self.yes else self.no;
            },
            .finiteq, .infiniteq, .nanq => {
                if (args.len != 1) return error.Arity;
                const value = try self.asInexact(args[0]);
                const result = switch (op) {
                    .finiteq => std.math.isFinite(value),
                    .infiniteq => std.math.isInf(value),
                    .nanq => std.math.isNan(value),
                    else => unreachable,
                };
                return if (result) self.yes else self.no;
            },
            .abs_proc => {
                if (args.len != 1) return error.Arity;
                if (self.tagOf(args[0]) == .inexact) {
                    const bits: u64 = @bitCast(try self.asInexact(args[0]));
                    return self.inexactNumber(@bitCast(bits & 0x7fffffffffffffff));
                }
                const v = try self.fraction(args[0]);
                return self.fractionNumber(try normalizeFraction(if (v.numerator < 0) -@as(i64, v.numerator) else v.numerator, v.denominator));
            },
            .floor_proc, .ceiling_proc, .truncate_proc, .round_proc => {
                if (args.len != 1) return error.Arity;
                if (self.tagOf(args[0]) == .inexact) return self.inexactNumber(roundInexact(try self.asInexact(args[0]), op));
                const v = try self.fraction(args[0]);
                const n: i64 = v.numerator;
                const d: i64 = v.denominator;
                var quotient = @divTrunc(n, d);
                const remainder = @rem(n, d);
                const distance = if (remainder < 0) -remainder else remainder;
                const increment = if (remainder == 0) false else switch (op) {
                    .floor_proc => n < 0,
                    .ceiling_proc => n > 0,
                    .round_proc => distance * 2 > d or (distance * 2 == d and @rem(quotient, 2) != 0),
                    else => false,
                };
                if (increment) quotient += if (n < 0) @as(i64, -1) else 1;
                if (quotient < std.math.minInt(i32) or quotient > std.math.maxInt(i32)) return error.Overflow;
                return self.number(@intCast(quotient));
            },
            .inexact_proc => {
                if (args.len != 1) return error.Arity;
                if (self.tagOf(args[0]) == .inexact) return args[0];
                return self.inexactNumber(try self.asInexact(args[0]));
            },
            .exact_proc => {
                if (args.len != 1) return error.Arity;
                const tag = self.tagOf(args[0]);
                if (tag == .integer or tag == .rational) return args[0];
                if (tag != .inexact) return error.Type;
                const bits: u64 = @bitCast(try self.asInexact(args[0]));
                const magnitude = bits & 0x7fffffffffffffff;
                const exponent: u11 = @truncate(magnitude >> 52);
                if (exponent == 0x7ff) return error.Overflow;
                if (magnitude == 0) return self.number(0);
                var significand: u64 = magnitude & 0x000fffffffffffff;
                var shift: i32 = if (exponent == 0) -1074 else @as(i32, exponent) - 1075;
                if (exponent != 0) significand |= @as(u64, 1) << 52;
                while ((significand & 1) == 0) {
                    significand >>= 1;
                    shift += 1;
                }
                if (shift > 31 or shift < -30) return error.Overflow;
                if (shift > 0 and significand > (@as(u64, 2147483648) >> @as(u6, @intCast(shift)))) return error.Overflow;
                if (significand > 2147483648) return error.Overflow;
                const numerator: i64 = if (shift > 0) @intCast(significand << @as(u6, @intCast(shift))) else @intCast(significand);
                if (numerator > 2147483648) return error.Overflow;
                const denominator: i64 = if (shift < 0) @as(i64, 1) << @as(u6, @intCast(-shift)) else 1;
                return self.fractionNumber(try normalizeFraction(if (bits >> 63 != 0) -numerator else numerator, denominator));
            },
            .apply_proc => {
                var expanded_storage: [16]Ref = @splat(0);
                const expanded = try self.expandApply(args, &expanded_storage);
                const frame = try self.pushAstRoots(0, 0, expanded.procedure);
                defer self.ast_root_frame_count = frame;
                @memcpy(self.ast_root_frames[frame].values[0..expanded.values.len], expanded.values);
                self.ast_root_frames[frame].value_count = @intCast(expanded.values.len);
                return self.apply(expanded.procedure, expanded.values, depth + 1, host);
            },
            .map_proc, .for_each_proc => {
                if (args.len < 2) return error.Arity;
                var cursors: [15]Ref = @splat(0);
                var values: [15]Ref = @splat(0);
                const count = args.len - 1;
                @memcpy(cursors[0..count], args[1..]);
                const cursor_frame = try self.pushAstRoots(0, 0, args[0]);
                defer self.ast_root_frame_count = cursor_frame;
                const values_frame = try self.pushAstRoots(0, 0, 0);
                self.ast_root_frames[cursor_frame].value_count = @intCast(count);
                self.ast_root_frames[values_frame].value_count = @intCast(count);
                @memcpy(self.ast_root_frames[cursor_frame].values[0..count], cursors[0..count]);
                var result: Ref = 0;
                var tail: Ref = 0;
                var iterations: usize = 0;
                while (true) {
                    try self.tick(depth);
                    var ended: usize = 0;
                    for (cursors[0..count], 0..) |cursor, i| {
                        if (cursor == 0) {
                            ended += 1;
                        } else {
                            if (self.tagOf(cursor) != .pair) return error.Type;
                            values[i] = self.heap[cursor].a;
                        }
                    }
                    if (ended == count) return result;
                    if (ended != 0) return error.Type;
                    if (iterations >= cells) return error.Depth;
                    for (cursors[0..count]) |*cursor| cursor.* = self.heap[cursor.*].b;
                    // A callback may mutate the input: keep both saved next
                    // cursors and current values independently reachable.
                    @memcpy(self.ast_root_frames[cursor_frame].values[0..count], cursors[0..count]);
                    @memcpy(self.ast_root_frames[values_frame].values[0..count], values[0..count]);
                    self.ast_root_frames[values_frame].expression = result;
                    self.ast_root_frames[values_frame].environment = tail;
                    const value = try self.apply(args[0], values[0..count], depth + 1, host);
                    if (op == .map_proc) {
                        const next = try self.pair(value, 0);
                        if (tail == 0) result = next else self.heap[tail].b = next;
                        tail = next;
                    }
                    iterations += 1;
                }
            },
            .eq_proc, .eqv_proc, .equal_proc => {
                if (args.len != 2) return error.Arity;
                const same = if (op == .equal_proc) try self.equalValues(args[0], args[1], depth) else try self.equivalent(args[0], args[1]);
                return if (same) self.yes else self.no;
            },
            .memq_proc, .memv_proc, .member_proc => {
                if (args.len != 2) return error.Arity;
                var cursor = args[1];
                var count: usize = 0;
                while (cursor != 0) {
                    try self.tick(depth);
                    if (self.tagOf(cursor) != .pair) return error.Type;
                    if (count >= cells) return error.Depth;
                    const item = self.heap[cursor].a;
                    const same = if (op == .member_proc) try self.equalValues(args[0], item, depth) else try self.equivalent(args[0], item);
                    if (same) return cursor;
                    cursor = self.heap[cursor].b;
                    count += 1;
                }
                return self.no;
            },
            .cadr_proc => {
                if (args.len != 1) return error.Arity;
                if (self.tagOf(args[0]) != .pair) return error.Type;
                const tail = self.heap[args[0]].b;
                if (self.tagOf(tail) != .pair) return error.Type;
                return self.heap[tail].a;
            },
            .symbolq, .stringq, .booleanq, .procedureq => {
                if (args.len != 1) return error.Arity;
                const tag = self.tagOf(args[0]);
                const result = switch (op) {
                    .symbolq => tag == .symbol,
                    .stringq => tag == .string,
                    .booleanq => tag == .boolean,
                    .procedureq => tag == .closure or tag == .native,
                    else => unreachable,
                };
                return if (result) self.yes else self.no;
            },
            .list_ref_proc, .list_tail_proc => {
                if (args.len != 2) return error.Arity;
                const offset = try self.integer(args[1]);
                if (offset < 0) return error.Type;
                var current = args[0];
                var i: i32 = 0;
                while (i < offset) : (i += 1) {
                    try self.tick(depth);
                    if (self.tagOf(current) != .pair) return error.Type;
                    current = self.heap[current].b;
                }
                if (op == .list_tail_proc) return current;
                if (self.tagOf(current) != .pair) return error.Type;
                return self.heap[current].a;
            },
            .assoc_proc, .assq_proc, .assv_proc => {
                if (args.len != 2) return error.Arity;
                var current = args[1];
                var count: usize = 0;
                while (current != 0) {
                    try self.tick(depth);
                    if (self.tagOf(current) != .pair) return error.Type;
                    if (count >= cells) return error.Depth;
                    const entry = self.heap[current].a;
                    if (self.tagOf(entry) != .pair) return error.Type;
                    const key = self.heap[entry].a;
                    const same = if (op == .assoc_proc) try self.equalValues(args[0], key, depth) else try self.equivalent(args[0], key);
                    if (same) return entry;
                    current = self.heap[current].b;
                    count += 1;
                }
                return self.no;
            },
            .caar_proc, .cdar_proc, .cddr_proc, .caddr_proc, .caadr_proc, .cdadr_proc, .cdddr_proc, .cadddr_proc => {
                if (args.len != 1) return error.Arity;
                const path: u8 = switch (op) {
                    .caar_proc => 0,
                    .cdar_proc => 2,
                    .cddr_proc => 3,
                    .caddr_proc => 3,
                    .caadr_proc => 1,
                    .cdadr_proc => 5,
                    .cdddr_proc => 7,
                    .cadddr_proc => 7,
                    else => unreachable,
                };
                const length: u3 = switch (op) {
                    .caar_proc, .cdar_proc, .cddr_proc => 2,
                    .cadddr_proc => 4,
                    else => 3,
                };
                var value = args[0];
                for (0..length) |i| {
                    if (self.tagOf(value) != .pair) return error.Type;
                    value = if ((path & (@as(u8, 1) << @as(u3, @intCast(i)))) != 0) self.heap[value].b else self.heap[value].a;
                }
                return value;
            },
            .set_car_proc, .set_cdr_proc => {
                if (args.len != 2) return error.Arity;
                if (self.tagOf(args[0]) != .pair) return error.Type;
                if (op == .set_car_proc) self.heap[args[0]].a = args[1] else self.heap[args[0]].b = args[1];
                return 0;
            },
            .length_proc, .reverse_proc, .listq => {
                if (args.len != 1) return error.Arity;
                if (op == .listq) {
                    // Floyd's cycle detection needs no mutable marks and does
                    // not allocate or inspect beyond an improper tail.
                    var slow = args[0];
                    var fast = args[0];
                    while (fast != 0) {
                        try self.tick(depth);
                        if (self.tagOf(fast) != .pair) return self.no;
                        fast = self.heap[fast].b;
                        if (fast == 0) return self.yes;
                        if (self.tagOf(fast) != .pair) return self.no;
                        fast = self.heap[fast].b;
                        slow = self.heap[slow].b;
                        if (fast == slow) return self.no;
                    }
                    return self.yes;
                }
                var cursor = args[0];
                var count: usize = 0;
                var reversed: Ref = 0;
                while (cursor != 0) {
                    if (self.tagOf(cursor) != .pair) {
                        if (op == .listq) return self.no;
                        return error.Type;
                    }
                    if (count >= cells) return error.Depth;
                    if (op == .reverse_proc) reversed = try self.pair(self.heap[cursor].a, reversed);
                    count += 1;
                    cursor = self.heap[cursor].b;
                }
                if (op == .listq) return self.yes;
                if (op == .reverse_proc) return reversed;
                return self.number(@intCast(count));
            },
            .append_proc => {
                if (args.len == 0) return 0;
                var result: Ref = 0;
                var tail: Ref = 0;
                for (args[0 .. args.len - 1]) |arg| {
                    var cursor = arg;
                    var count: usize = 0;
                    while (cursor != 0) {
                        if (self.tagOf(cursor) != .pair) return error.Type;
                        if (count >= cells) return error.Depth;
                        const next = try self.pair(self.heap[cursor].a, 0);
                        if (tail == 0) result = next else self.heap[tail].b = next;
                        tail = next;
                        count += 1;
                        cursor = self.heap[cursor].b;
                    }
                }
                if (tail == 0) return args[args.len - 1];
                self.heap[tail].b = args[args.len - 1];
                return result;
            },
            .cons => {
                if (args.len != 2) return error.Arity;
                return self.pair(args[0], args[1]);
            },
            .car, .cdr => {
                if (args.len != 1) return error.Arity;
                if (self.tagOf(args[0]) != .pair) return error.Type;
                return if (op == .car) self.heap[args[0]].a else self.heap[args[0]].b;
            },
            .list => {
                var value: Ref = 0;
                var index = args.len;
                while (index != 0) {
                    index -= 1;
                    value = try self.pair(args[index], value);
                }
                return value;
            },
            .nullq, .pairq, .not => {
                if (args.len != 1) return error.Arity;
                const yes = switch (op) {
                    .nullq => args[0] == 0,
                    .pairq => self.tagOf(args[0]) == .pair,
                    else => args[0] == self.no,
                };
                return if (yes) self.yes else self.no;
            },
            .register => {
                if (args.len != 2) return error.Arity;
                if (self.tagOf(args[0]) != .string or self.tagOf(args[1]) != .closure or self.heap[args[1]].a != 0 or self.string(args[0]).len == 0) return error.Type;
                for (self.commands[0..self.command_count]) |*command| if (std.mem.eql(u8, self.string(command.name), self.string(args[0]))) {
                    command.* = .{ .name = args[0], .procedure = args[1] };
                    return self.yes;
                };
                if (self.command_count == self.commands.len) return error.CommandFull;
                self.commands[self.command_count] = .{ .name = args[0], .procedure = args[1] };
                self.command_count += 1;
                return self.yes;
            },
            .buffer_text => {
                if (args.len != 0) return error.Arity;
                if (comptime @hasDecl(@TypeOf(host.*), "documentText")) return self.text(.string, host.documentText());
                return error.EditorFailure;
            },
            .buffer_save => {
                if (args.len != 1) return error.Arity;
                const name = try self.storageText(args[0]);
                if (comptime @hasDecl(@TypeOf(host.*), "saveDocument")) {
                    try host.saveDocument(name);
                    return self.yes;
                }
                return error.StorageUnavailable;
            },
            .buffer_load => {
                if (args.len != 1) return error.Arity;
                const name = try self.storageText(args[0]);
                if (comptime @hasDecl(@TypeOf(host.*), "loadDocument")) {
                    try host.loadDocument(name);
                    return self.yes;
                }
                return error.StorageUnavailable;
            },
            .app_frame, .app_pause, .app_resume, .app_stop, .app_speed, .app_ticks, .plot_set, .plot_get, .plot_sine => return self.applyApp(op, args),
            .view_set, .view_get, .view_rollback => return self.applyView(op, args),
            .sql_query, .sql_exec, .sql_begin, .sql_commit, .sql_rollback, .fs_open, .fs_read, .fs_write, .fs_resize, .fs_remove, .fs_sync, .fs_rollback, .fs_snapshot, .fs_restore, .fs_release, .fs_collect, .fs_generation, .fs_list, .fs_close, .fs_stat, .fs_begin, .sql_lookup, .sql_check, .fs_space, .fs_verify => return self.applyStorage(op, args, host),
            .card_read, .card_info, .card_dismiss, .view_card => return self.applyCard(op, args, host),
            .insert => {
                if (args.len != 1) return error.Arity;
                if (self.tagOf(args[0]) != .string) return error.Type;
                try host.schemeCall(.insert, self.string(args[0]), 0);
                return self.yes;
            },
            .move => {
                if (args.len != 1) return error.Arity;
                try host.schemeCall(.move, "", try self.integer(args[0]));
                return self.yes;
            },
            .camera_capture => {
                if (args.len != 0) return error.Arity;
                if (comptime @hasDecl(@TypeOf(host.*), "cameraCapture")) return self.number(try host.cameraCapture());
                return error.CameraUnavailable;
            },
            .camera_info => {
                if (args.len != 1) return error.Arity;
                const handle = try self.integer(args[0]);
                if (comptime @hasDecl(@TypeOf(host.*), "cameraInfo")) {
                    const info = try host.cameraInfo(handle);
                    const state = try self.text(.symbol, @tagName(info.state));
                    const w = try self.number(@intCast(info.width));
                    const h = try self.number(@intCast(info.height));
                    const bytes = try self.number(@intCast(info.bytes));
                    return self.pair(state, try self.pair(w, try self.pair(h, try self.pair(bytes, 0))));
                }
                return error.CameraUnavailable;
            },
            .camera_read => {
                if (args.len != 3) return error.Arity;
                const handle = try self.integer(args[0]);
                const offset = try self.integer(args[1]);
                const count = try self.integer(args[2]);
                if (offset < 0 or count < 0 or count > camera.max_read) return error.InvalidCameraRange;
                if (comptime @hasDecl(@TypeOf(host.*), "cameraRead")) {
                    return self.cameraRead(host, handle, @intCast(offset), @intCast(count));
                }
                return error.CameraUnavailable;
            },
            .undo, .forget, .log, .memory, .tasks => {
                if (args.len != 0) return error.Arity;
                try host.schemeCall(switch (op) {
                    .undo => .undo,
                    .forget => .forget,
                    .log => .log,
                    .memory => .memory,
                    else => .tasks,
                }, "", 0);
                return self.yes;
            },
            else => return error.Type,
        }
    }
    noinline fn applyApp(self: *Runtime, op: Op, args: []const Ref) linksection(code_section) Error!Ref {
        if (!self.app.enabled) return error.AppUnavailable;
        switch (op) {
            .app_frame => {
                if (args.len != 1) return error.Arity;
                const callback = args[0];
                if (callback == self.no) {
                    self.frame_callback = 0;
                    return self.yes;
                }
                if (self.tagOf(callback) != .closure) return error.Type;
                var parameters: [16]Ref = @splat(0);
                if ((try self.arguments(self.heap[callback].a, &parameters)).len != 1) return error.Arity;
                self.frame_callback = callback;
                return self.yes;
            },
            .app_pause, .app_resume, .app_stop => {
                if (args.len != 0) return error.Arity;
                self.app.paused = op != .app_resume;
                if (op == .app_stop) self.frame_callback = 0;
                return self.yes;
            },
            .app_speed => {
                if (args.len != 1) return error.Arity;
                const speed = try self.integer(args[0]);
                if (speed < 1 or speed > 8) return error.Type;
                self.app.speed = @intCast(speed);
                return self.yes;
            },
            .app_ticks => {
                if (args.len != 0) return error.Arity;
                return self.number(self.app.ticks);
            },
            .plot_set, .plot_get => {
                if (args.len == 0 or (op == .plot_set and args.len % 2 != 0) or (op == .plot_get and args.len != 1)) return error.Arity;
                var next = self.app.plot;
                var i: usize = 0;
                while (i < args.len) : (i += 2) {
                    const key = try self.viewKey(args[i]);
                    var offset: usize = 0;
                    var index: usize = 0;
                    while (true) : (index += 1) {
                        if (offset >= plot_names.len) return error.Type;
                        var end = offset;
                        while (end < plot_names.len and plot_names[end] != 0) end += 1;
                        if (end == plot_names.len) return error.Type;
                        if (sameText(key, plot_names[offset..end])) break;
                        offset = end + 1;
                    }
                    if (op == .plot_get) return self.number(switch (index) {
                        0 => next.amplitude,
                        1 => next.phase,
                        2 => @intCast(next.color1),
                        else => @intCast(next.color2),
                    });
                    const value = try self.integer(args[i + 1]);
                    if (value < 0 or value > switch (index) {
                        0 => @as(i32, 100),
                        1 => 255,
                        else => 0xffffff,
                    }) return error.Type;
                    switch (index) {
                        0 => next.amplitude = @intCast(value),
                        1 => next.phase = @intCast(value),
                        2 => next.color1 = @intCast(value),
                        else => next.color2 = @intCast(value),
                    }
                }
                self.app.plot = next;
                return self.yes;
            },
            .plot_sine => {
                if (args.len != 2) return error.Arity;
                const phase = try self.integer(args[0]);
                const amplitude = try self.integer(args[1]);
                if (amplitude < 0 or amplitude > 100) return error.Type;
                const sample: usize = @intCast(@mod(phase, 256));
                // Index the declared Flash object by address. Indexing the
                // constant array value emits an anonymous copy in SRAM.
                return self.number(@divTrunc(@as(i32, (&plot_config.sine)[sample]) * amplitude, 30_000));
            },
            else => return error.Type,
        }
    }
    fn nonnegative(self: *Runtime, r: Ref) linksection(code_section) Error!u32 {
        const n = try self.integer(r);
        if (n < 0) return error.Type;
        return @intCast(n);
    }
    fn storageText(self: *Runtime, r: Ref) linksection(code_section) Error![]const u8 {
        if (self.tagOf(r) != .string) return error.Type;
        return self.string(r);
    }
    fn sameText(left: []const u8, right: []const u8) linksection(code_section) bool {
        if (left.len != right.len) return false;
        for (left, right) |a, b| if (a != b) return false;
        return true;
    }
    fn parseDecimal(token: []const u8) linksection(code_section) error{Overflow}!i32 {
        if (token.len == 0) return error.Overflow;
        var index: usize = 0;
        var negative = false;
        if (token[0] == '+' or token[0] == '-') {
            negative = token[0] == '-';
            index = 1;
        }
        if (index == token.len) return error.Overflow;
        var magnitude: u32 = 0;
        while (index < token.len) : (index += 1) {
            const c = token[index];
            if (c < '0' or c > '9') return error.Overflow;
            const digit: u32 = c - '0';
            if (magnitude > (std.math.maxInt(u32) - digit) / 10) return error.Overflow;
            magnitude = magnitude * 10 + digit;
        }
        if (!negative) {
            if (magnitude > std.math.maxInt(i32)) return error.Overflow;
            return @intCast(magnitude);
        }
        if (magnitude > @as(u32, std.math.maxInt(i32)) + 1) return error.Overflow;
        if (magnitude == @as(u32, std.math.maxInt(i32)) + 1) return std.math.minInt(i32);
        return -@as(i32, @intCast(magnitude));
    }

    fn parseHex(token: []const u8) linksection(code_section) error{Overflow}!i32 {
        if (token.len == 0) return error.Overflow;
        var magnitude: u32 = 0;
        for (token) |c| {
            const digit: u32 = if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'f') c - 'a' + 10 else if (c >= 'A' and c <= 'F') c - 'A' + 10 else return error.Overflow;
            if (magnitude > 0x0FFFFFFF) return error.Overflow;
            magnitude = (magnitude << 4) | digit;
        }
        if (magnitude > std.math.maxInt(i32)) return error.Overflow;
        return @intCast(magnitude);
    }
    noinline fn applyStorage(self: *Runtime, op: Op, args: []const Ref, host: anytype) linksection(code_section) Error!Ref {
        var request = storage.Request{ .operation = @fromBackingInt(@intCast(@backingInt(op) - @backingInt(Op.sql_query) + 1)) };
        var binary: [64]u8 = undefined;
        switch (op) {
            .sql_query, .sql_exec => {
                if (args.len != 1) return error.Arity;
                request.text = try self.storageText(args[0]);
            },
            .fs_open => {
                if (args.len < 1 or args.len > 2) return error.Arity;
                request.text = try self.storageText(args[0]);
                if (args.len == 2) {
                    if (args[1] != self.yes and args[1] != self.no) return error.Type;
                    request.offset = if (args[1] == self.yes) 1 else 0;
                }
            },
            .fs_read, .fs_write => {
                if (args.len != 3) return error.Arity;
                request.handle = try self.nonnegative(args[0]);
                request.offset = try self.nonnegative(args[1]);
                if (op == .fs_read) {
                    request.count = try self.nonnegative(args[2]);
                    if (request.count > 64) return error.StorageLimit;
                } else if (self.tagOf(args[2]) == .string) {
                    request.text = self.string(args[2]);
                } else {
                    var p = args[2];
                    var n: usize = 0;
                    while (p != 0) {
                        if (self.tagOf(p) != .pair) return error.Type;
                        if (n == binary.len) return error.StorageLimit;
                        const b = try self.nonnegative(self.heap[p].a);
                        if (b > 255) return error.Type;
                        binary[n] = @intCast(b);
                        n += 1;
                        p = self.heap[p].b;
                    }
                    request.text = binary[0..n];
                }
            },
            .fs_resize => {
                if (args.len != 2) return error.Arity;
                request.handle = try self.nonnegative(args[0]);
                request.offset = try self.nonnegative(args[1]);
            },
            .fs_remove, .fs_restore, .fs_release, .fs_close, .fs_stat, .fs_verify => {
                if (args.len != 1) return error.Arity;
                request.handle = try self.nonnegative(args[0]);
            },
            .sql_lookup => {
                if (args.len == 0 or args.len % 2 == 0) return error.Arity;
                if (self.tagOf(args[0]) != .symbol) return error.Type;
                request.text = self.string(args[0]);
                request.count = 8;
                var i: usize = 1;
                while (i < args.len) : (i += 2) {
                    if (self.tagOf(args[i]) != .keyword) return error.Type;
                    const name = self.string(args[i]);
                    if (sameText(name, "where")) request.argument = try self.storageText(args[i + 1]) else if (sameText(name, "limit")) request.count = try self.nonnegative(args[i + 1]) else return error.Type;
                }
            },
            else => if (args.len != 0) return error.Arity,
        }
        // Parse returned DATA without evaluating it. No arbitrary Scheme code
        // can run from a DB cell. Providers must return one bounded expression.
        if (comptime @hasDecl(@TypeOf(host.*), "storageCall")) {
            var buffer: [1024]u8 = undefined;
            const source = try host.storageCall(request, &buffer);
            if (!storage.validUtf8(source)) return error.StorageFailed;
            var pos: usize = 0;
            const result = try self.read(source, &pos, 0);
            space(source, &pos);
            if (pos != source.len) return error.StorageFailed;
            return result;
        }
        return error.StorageUnavailable;
    }
    noinline fn applyView(self: *Runtime, op: Op, args: []const Ref) linksection(code_section) Error!Ref {
        switch (op) {
            .view_set => {
                if (args.len == 0 or args.len % 2 != 0) return error.Arity;
                var next = self.view;
                var i: usize = 0;
                while (i < args.len) : (i += 2) {
                    const name = try self.viewKey(args[i]);
                    const val_tag = self.tagOf(args[i + 1]);
                    const value: view_config.Value = switch (val_tag) {
                        .integer => .{ .number = try self.integer(args[i + 1]) },
                        .symbol, .string => .{ .symbol = self.string(args[i + 1]) },
                        .boolean => .{ .boolean = args[i + 1] == self.yes },
                        else => return error.Type,
                    };
                    next.set(name, value) catch return error.Type;
                }
                next.validate() catch return error.Type;
                // Allocate the result before committing: HeapFull cannot hide a change.
                const generation = if (self.view_generation == 0x7fffffff) 1 else self.view_generation + 1;
                const result = try self.number(@intCast(generation));
                if (self.view_history_count == self.view_history.len) {
                    std.mem.copyForwards(@TypeOf(self.view_history[0]), self.view_history[0..7], self.view_history[1..8]);
                    self.view_history_count -= 1;
                }
                self.view_history[self.view_history_count] = .{ .config = self.view, .generation = self.view_generation };
                self.view_history_count += 1;
                self.view = next;
                self.view_generation = generation;
                return result;
            },
            .view_get => {
                if (args.len != 1) return error.Arity;
                const value = self.view.get(try self.viewKey(args[0])) catch return error.Type;
                return switch (value) {
                    .number => |n| self.number(n),
                    .symbol => |name| self.text(.symbol, name),
                    .boolean => |b| if (b) self.yes else self.no,
                };
            },
            .view_rollback => {
                if (args.len != 0) return error.Arity;
                if (self.view_history_count == 0) return error.EditorFailure;
                const previous = self.view_history[self.view_history_count - 1];
                const result = try self.number(@intCast(previous.generation));
                self.view_history_count -= 1;
                self.view = previous.config;
                self.view_generation = previous.generation;
                return result;
            },
            else => return error.Type,
        }
    }
    fn viewKey(self: *const Runtime, r: Ref) linksection(code_section) Error![]const u8 {
        if (self.tagOf(r) != .symbol and self.tagOf(r) != .keyword) return error.Type;
        return self.string(r);
    }
    noinline fn applyCard(self: *Runtime, op: Op, args: []const Ref, host: anytype) linksection(code_section) Error!Ref {
        switch (op) {
            .card_read => {
                if (args.len != 0) return error.Arity;
                if (comptime @hasDecl(@TypeOf(host.*), "cardRead")) {
                    const handle = try host.cardRead();
                    return self.number(handle);
                }
                return error.CardUnavailable;
            },
            .card_info => {
                if (args.len != 1) return error.Arity;
                const handle = try self.integer(args[0]);
                if (comptime @hasDecl(@TypeOf(host.*), "cardInfo")) {
                    const info = try host.cardInfo(handle);
                    const name_len = @min(info.name.len, text_bytes);
                    const name_sym = try self.text(.symbol, "name");
                    const name_val = try self.text(.string, info.name[0..name_len]);
                    const name_pair = try self.pair(name_sym, name_val);

                    const addr_len = @min(info.address.len, text_bytes);
                    const addr_sym = try self.text(.symbol, "address");
                    const addr_val = try self.text(.string, info.address[0..addr_len]);
                    const addr_pair = try self.pair(addr_sym, addr_val);

                    const birth_len = @min(info.birth.len, text_bytes);
                    const birth_sym = try self.text(.symbol, "birth");
                    const birth_val = try self.text(.string, info.birth[0..birth_len]);
                    const birth_pair = try self.pair(birth_sym, birth_val);

                    const gender_len = @min(info.gender.len, text_bytes);
                    const gender_sym = try self.text(.symbol, "gender");
                    const gender_val = try self.text(.string, info.gender[0..gender_len]);
                    const gender_pair = try self.pair(gender_sym, gender_val);

                    var result: Ref = 0;
                    result = try self.pair(gender_pair, result);
                    result = try self.pair(birth_pair, result);
                    result = try self.pair(addr_pair, result);
                    result = try self.pair(name_pair, result);
                    return result;
                }
                return error.CardUnavailable;
            },
            .card_dismiss => {
                if (args.len != 1) return error.Arity;
                const handle = try self.integer(args[0]);
                if (comptime @hasDecl(@TypeOf(host.*), "cardDismiss")) {
                    try host.cardDismiss(handle);
                    return self.yes;
                }
                return error.CardUnavailable;
            },
            .view_card => {
                if (args.len != 1) return error.Arity;
                const handle = try self.integer(args[0]);
                if (comptime @hasDecl(@TypeOf(host.*), "showCardView")) {
                    try host.showCardView(handle);
                    return self.yes;
                }
                return error.CardUnavailable;
            },
            else => return error.Type,
        }
    }
    noinline fn cameraRead(self: *Runtime, host: anytype, camera_handle: i32, offset: u32, count: usize) linksection(code_section) Error!Ref {
        var bytes: [camera.max_read]u8 = @splat(0);
        try host.cameraRead(camera_handle, offset, bytes[0..count]);
        var encoded: [camera.max_read * 2]u8 = @splat(0);
        const digits = "0123456789abcdef";
        for (bytes[0..count], 0..) |byte, index| {
            encoded[index * 2] = digits[byte >> 4];
            encoded[index * 2 + 1] = digits[byte & 15];
        }
        return self.text(.string, encoded[0 .. count * 2]);
    }
    fn start(self: *Runtime) linksection(code_section) Error!void {
        return self.startBudget(step_limit);
    }
    fn startBudget(self: *Runtime, budget: u32) linksection(code_section) Error!void {
        if (self.running) return error.Busy;
        self.step_budget = budget;
        self.cell_reserve = 0;
        // Previous request stacks are dead before the between-request GC.
        self.eval_sp = 0;
        self.call_sp = 0;
        self.collect();
        self.steps = 0;
        self.running = true;
    }
    pub fn evaluate(self: *Runtime, source: []const u8, host: anytype, output: []u8) linksection(code_section) Error![]const u8 {
        try self.start();
        defer self.running = false;
        if (source.len > 4096 or std.mem.indexOfScalar(u8, source, 0) != null or !storage.validUtf8(source)) return error.Syntax;
        // Copy every token into the heap before host callbacks can edit source.
        var pos: usize = 0;
        var forms: Ref = 0;
        var tail: Ref = 0;
        while (true) {
            space(source, &pos);
            if (pos == source.len) break;
            const expr = try self.read(source, &pos, 0);
            const p = try self.pair(expr, 0);
            if (tail == 0) forms = p else self.heap[tail].b = p;
            tail = p;
        }
        // An effect-free global numeric function may use a weak one-function
        // cache. Admission is checked on every call, including current bindings.
        if (self.numericCall(forms)) |call| {
            if (self.prepareNumeric(call.proc, call.name, call.params[0..call.count])) {
                const body_len = self.bytecode_len;
                const old_eval_sp = self.eval_sp;
                const old_call_sp = self.call_sp;
                if (self.numericWrapper(call.proc, call.args[0..call.count])) |ip| {
                    const result = self.runVm(ip, host);
                    self.bytecode_len = body_len;
                    self.eval_sp = old_eval_sp;
                    self.call_sp = old_call_sp;
                    return self.format(try result, output);
                } else |_| {
                    self.bytecode_len = body_len;
                    self.eval_sp = old_eval_sp;
                    self.call_sp = old_call_sp;
                }
            }
        }
        // Only closed, side-effect-free arithmetic is eligible for compilation.
        // The experimental compiler cannot yet preserve arbitrary lexical
        // bindings, mutation, or persistent function lifetimes. Keep those
        // forms on the interpreter until it can do so.
        if (self.safeArithmeticSequence(forms)) {
            const saved_bytecode_len = self.bytecode_len;
            const saved_eval_sp = self.eval_sp;
            const saved_call_sp = self.call_sp;
            if (self.compileSequence(forms)) |start_ip| {
                const result = self.runVm(start_ip, host);
                self.bytecode_len = saved_bytecode_len;
                self.eval_sp = saved_eval_sp;
                self.call_sp = saved_call_sp;
                return self.format(try result, output);
            } else |_| {
                self.bytecode_len = saved_bytecode_len;
                self.eval_sp = saved_eval_sp;
                self.call_sp = saved_call_sp;
            }
        }
        const result = try self.sequence(forms, self.global, 0, host);
        return self.format(result, output);
    }
    const NumericCall = struct {
        proc: Ref,
        name: Ref,
        params: [16]Ref,
        args: [16]Ref,
        count: u8,
    };
    noinline fn numericCall(self: *Runtime, forms: Ref) linksection(code_section) ?NumericCall {
        if (forms == 0 or self.heap[forms].b != 0) return null;
        const expr = self.heap[forms].a;
        if (self.tagOf(expr) != .pair) return null;
        const name = self.heap[expr].a;
        if (self.tagOf(name) != .symbol or opcode(self.string(name)) != null) return null;
        const binding = self.lookup(self.global, name);
        if (binding == 0) return null;
        const proc = self.heap[binding].b;
        if (self.tagOf(proc) != .closure or self.heap[proc].flagged() or self.heap[proc].env != self.global) return null;
        var call = NumericCall{ .proc = proc, .name = name, .params = @splat(0), .args = @splat(0), .count = 0 };
        const params = self.arguments(self.heap[proc].a, &call.params) catch return null;
        const args = self.arguments(self.heap[expr].b, &call.args) catch return null;
        if (params.len != args.len) return null;
        for (args) |arg| if (!isImmediateInt(arg)) return null;
        for (params) |param| if (param == name or opcode(self.string(param)) != null) return null;
        call.count = @intCast(params.len);
        var body = self.heap[proc].b;
        if (body == 0) return null;
        while (body != 0) : (body = self.heap[body].b) {
            if (!self.safeNumericExpr(self.heap[body].a, name, params, self.heap[body].b == 0, 0)) return null;
        }
        return call;
    }
    noinline fn safeNumericExpr(self: *const Runtime, expr: Ref, name: Ref, params: []const Ref, tail: bool, depth: usize) linksection(code_section) bool {
        if (depth >= depth_limit) return false;
        if (isImmediateInt(expr) or expr == self.yes or expr == self.no) return true;
        if (self.tagOf(expr) == .symbol) {
            for (params) |param| if (param == expr) return true;
            return false;
        }
        if (self.tagOf(expr) != .pair) return false;
        const head = self.heap[expr].a;
        if (self.tagOf(head) != .symbol) return false;
        var arg_storage: [16]Ref = @splat(0);
        const args = self.arguments(self.heap[expr].b, &arg_storage) catch return false;
        if (head == name) {
            if (!tail or args.len != params.len) return false;
            for (args) |arg| if (!self.safeNumericExpr(arg, name, params, false, depth + 1)) return false;
            return true;
        }
        const op = opcode(self.string(head)) orelse return false;
        switch (op) {
            .if_ => {
                if (args.len != 3) return false;
                return self.safeNumericExpr(args[0], name, params, false, depth + 1) and
                    self.safeNumericExpr(args[1], name, params, tail, depth + 1) and
                    self.safeNumericExpr(args[2], name, params, tail, depth + 1);
            },
            .begin => {
                if (args.len == 0) return false;
                for (args, 0..) |arg, i| if (!self.safeNumericExpr(arg, name, params, tail and i + 1 == args.len, depth + 1)) return false;
                return true;
            },
            .add, .sub, .mul, .equal, .less, .not => {
                if (self.lookup(self.global, head) != 0) return false;
                if (args.len != (if (op == .not) @as(usize, 1) else 2)) return false;
                for (args) |arg| if (!self.safeNumericExpr(arg, name, params, false, depth + 1)) return false;
                return true;
            },
            else => return false,
        }
    }
    noinline fn prepareNumeric(self: *Runtime, proc: Ref, name: Ref, params: []const Ref) linksection(code_section) bool {
        if (self.cached_proc == proc) return true;
        self.cached_proc = 0;
        self.bytecode_len = 0;
        var compiler = Compiler{ .fn_name = name, .fn_entry_ip = 0 };
        for (params) |param| {
            compiler.locals[compiler.local_count] = param;
            compiler.local_count += 1;
        }
        var body = self.heap[proc].b;
        while (body != 0) {
            const next = self.heap[body].b;
            self.compileExpr(&compiler, self.heap[body].a, next == 0) catch {
                self.bytecode_len = 0;
                return false;
            };
            if (next != 0) self.emitBcOp(.pop) catch {
                self.bytecode_len = 0;
                return false;
            };
            body = next;
        }
        self.emitBcOp(.ret) catch {
            self.bytecode_len = 0;
            return false;
        };
        self.cached_proc = proc;
        return true;
    }
    noinline fn numericWrapper(self: *Runtime, proc: Ref, args: []const Ref) linksection(code_section) Error!u16 {
        const entry = self.bytecode_len;
        const temporary = try self.alloc(.closure);
        self.heap[temporary].setFlag();
        self.heap[temporary].a = @intCast(args.len);
        self.heap[temporary].b = 0;
        self.heap[temporary].env = self.heap[proc].env;
        try self.emitBcOp(.const_val);
        try self.emitBcU16(temporary);
        for (args) |arg| {
            try self.emitBcOp(.const_val);
            try self.emitBcU16(arg);
        }
        try self.emitBcOp(.call);
        try self.emitBcByte(@intCast(args.len));
        try self.emitBcOp(.halt);
        return entry;
    }
    fn safeArithmeticSequence(self: *const Runtime, forms: Ref) bool {
        var cursor = forms;
        while (cursor != 0) : (cursor = self.heap[cursor].b) {
            if (!self.safeArithmetic(self.heap[cursor].a, 0)) return false;
        }
        return true;
    }
    fn safeArithmetic(self: *const Runtime, expr: Ref, depth: usize) bool {
        if (depth >= depth_limit) return false;
        if (isImmediateInt(expr) or expr == self.yes or expr == self.no) return true;
        if (self.tagOf(expr) == .integer) return true;
        if (self.tagOf(expr) != .pair) return false;
        const head = self.heap[expr].a;
        if (self.tagOf(head) != .symbol) return false;
        const op = opcode(self.string(head)) orelse return false;
        switch (op) {
            .add, .sub, .mul, .equal, .less, .not => {
                // These names are ordinary, rebindable procedures.
                if (self.lookup(self.global, head) != 0) return false;
            },
            .if_, .begin => {},
            else => return false,
        }
        var p = self.heap[expr].b;
        while (p != 0) : (p = self.heap[p].b) {
            if (self.tagOf(p) != .pair or !self.safeArithmetic(self.heap[p].a, depth + 1)) return false;
        }
        return true;
    }
    pub fn runCommand(self: *Runtime, name: []const u8, host: anytype, output: []u8) linksection(code_section) Error![]const u8 {
        try self.start();
        defer self.running = false;
        var procedure: Ref = 0;
        for (self.commands[0..self.command_count]) |command| if (std.mem.eql(u8, name, self.string(command.name))) {
            procedure = command.procedure;
            break;
        };
        if (procedure == 0) {
            const sym = self.findSymbol(name) orelse return error.UnknownCommand;
            const binding = self.lookup(self.global, sym);
            if (binding == 0) return error.UnknownCommand;
            procedure = self.heap[binding].b;
            if (self.tagOf(procedure) != .closure or self.heap[procedure].a != 0) return error.UnknownCommand;
        }
        const result = try self.apply(procedure, &.{}, 0, host);
        return self.format(result, output);
    }
    /// One coalesced frame, no parsing or output formatting. GC roots include
    /// the callback and lexical environment; no GC runs during evaluation.
    pub fn runFrame(self: *Runtime, ticks: i32, host: anytype) linksection(code_section) Error!void {
        if (!self.app.enabled) return error.AppUnavailable;
        if (self.frame_callback == 0) return;
        try self.startBudget(frame_step_limit);
        defer self.running = false;
        self.cell_reserve = frame_cell_reserve;
        defer self.cell_reserve = 0;
        self.app.ticks = ticks;
        const argument = try self.number(ticks);
        _ = try self.apply(self.frame_callback, &.{argument}, 0, host);
    }
    pub fn clearFrame(self: *Runtime) linksection(code_section) void {
        self.frame_callback = 0;
        self.app.paused = true;
    }
    fn format(self: *const Runtime, r: Ref, output: []u8) linksection(code_section) Error![]const u8 {
        var pos: usize = 0;
        try self.print(r, output, &pos, 0);
        return output[0..pos];
    }
    fn emit(output: []u8, pos: *usize, bytes: []const u8) linksection(code_section) Error!void {
        if (pos.* + bytes.len > output.len) return error.TextFull;
        @memcpy(output[pos.*..][0..bytes.len], bytes);
        pos.* += bytes.len;
    }
    fn emitInteger(output: []u8, pos: *usize, value: i32) linksection(code_section) Error!void {
        var bytes: [11]u8 = @splat(0);
        var rest: u32 = if (value < 0) @intCast(-@as(i64, value)) else @intCast(value);
        var start_index = bytes.len;
        while (true) {
            start_index -= 1;
            bytes[start_index] = @as(u8, @intCast(rest % 10)) + '0';
            rest /= 10;
            if (rest == 0) break;
        }
        if (value < 0) {
            start_index -= 1;
            bytes[start_index] = '-';
        }
        try emit(output, pos, bytes[start_index..]);
    }
    fn print(self: *const Runtime, r: Ref, output: []u8, pos: *usize, depth: usize) linksection(code_section) Error!void {
        if (depth >= depth_limit) return error.Depth;
        if (isImmediateInt(r)) {
            const val = toImmediateInt(r);
            var bytes: [11]u8 = @splat(0);
            var rest: u32 = if (val < 0) @intCast(-@as(i64, val)) else @intCast(val);
            var start_index = bytes.len;
            while (true) {
                start_index -= 1;
                bytes[start_index] = @as(u8, @intCast(rest % 10)) + '0';
                rest /= 10;
                if (rest == 0) break;
            }
            if (val < 0) {
                start_index -= 1;
                bytes[start_index] = '-';
            }
            return emit(output, pos, bytes[start_index..]);
        }
        if (isImmediateOp(r)) {
            return emit(output, pos, "#<procedure>");
        }
        const c = &self.heap[r];
        switch (c.tag) {
            .nil => try emit(output, pos, "()"),
            .boolean => try emit(output, pos, if (r == self.no) "#f" else "#t"),
            .integer => {
                var bytes: [11]u8 = @splat(0);
                var rest: u32 = if (c.integer < 0) @intCast(-@as(i64, c.integer)) else @intCast(c.integer);
                var start_index = bytes.len;
                while (true) {
                    start_index -= 1;
                    bytes[start_index] = @as(u8, @intCast(rest % 10)) + '0';
                    rest /= 10;
                    if (rest == 0) break;
                }
                if (c.integer < 0) {
                    start_index -= 1;
                    bytes[start_index] = '-';
                }
                try emit(output, pos, bytes[start_index..]);
            },
            .inexact => {
                var bytes: [64]u8 = undefined;
                const value = try self.asInexact(r);
                if (std.math.isNan(value)) try emit(output, pos, "+nan.0") else if (std.math.isInf(value)) try emit(output, pos, if (value < 0) "-inf.0" else "+inf.0") else try emit(output, pos, try formatInexact(value, &bytes));
            },
            .rational => {
                try emitInteger(output, pos, c.integer);
                try emit(output, pos, "/");
                const den: u32 = @as(u32, c.a) | (@as(u32, c.b) << 16);
                try emitInteger(output, pos, @intCast(den));
            },
            .symbol => try emit(output, pos, self.string(r)),
            .keyword => {
                try emit(output, pos, "#:");
                try emit(output, pos, self.string(r));
            },
            .string => {
                try emit(output, pos, "\"");
                for (self.string(r)) |byte| switch (byte) {
                    '\n' => try emit(output, pos, "\\n"),
                    '\t' => try emit(output, pos, "\\t"),
                    '"' => try emit(output, pos, "\\\""),
                    '\\' => try emit(output, pos, "\\\\"),
                    else => try emit(output, pos, &.{byte}),
                };
                try emit(output, pos, "\"");
            },
            .pair => {
                try emit(output, pos, "(");
                var p = r;
                var count: usize = 0;
                while (p != 0) {
                    if (count >= cells) return error.Depth;
                    if (self.tagOf(p) != .pair) {
                        try emit(output, pos, " . ");
                        try self.print(p, output, pos, depth + 1);
                        break;
                    }
                    if (count != 0) try emit(output, pos, " ");
                    try self.print(self.heap[p].a, output, pos, depth + 1);
                    p = self.heap[p].b;
                    count += 1;
                }
                try emit(output, pos, ")");
            },
            .closure, .native => try emit(output, pos, "#<procedure>"),
            .free => return error.Type,
        }
    }
};

const TestHost = struct {
    bytes: [256]u8 = @splat(0),
    length: usize = 0,
    pub fn schemeCall(self: *TestHost, op: EditorOp, bytes: []const u8, _: i32) Error!void {
        if (op != .insert) return;
        if (self.length + bytes.len > self.bytes.len) return error.EditorFailure;
        @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
        self.length += bytes.len;
    }
};
fn expectValue(vm: *Runtime, host: *TestHost, source: []const u8, expected: []const u8) !void {
    var output: [128]u8 = @splat(0);
    try std.testing.expectEqualStrings(expected, try vm.evaluate(source, host, &output));
}
test "control boundary retains the form referenced by the next child frame" {
    const Host = struct {
        vm: *Runtime,
        calls: usize = 0,
        pub fn schemeCall(self: *@This(), op: EditorOp, _: []const u8, _: i32) Error!void {
            if (op != .log) return error.EditorFailure;
            self.calls += 1;
            if (self.calls == 1) {
                while (self.vm.free_cells > 90) _ = try self.vm.pair(0, 0);
            } else {
                const count = self.vm.ast_root_frame_count;
                if (count == 0 or self.vm.tagOf(self.vm.ast_root_frames[count - 1].expression) != .pair) return error.EditorFailure;
            }
        }
    };
    for ([_][]const u8{
        "(begin (system/log) (system/log) 'ok)",
        "(cond (#t (system/log) (system/log) 'ok))",
    }) |source| {
        var vm: Runtime = undefined;
        vm.initInPlace();
        var host = Host{ .vm = &vm };
        var out: [128]u8 = undefined;
        try std.testing.expectEqualStrings("ok", try vm.evaluate(source, &host, &out));
        try std.testing.expectEqual(@as(usize, 2), host.calls);
        try std.testing.expect(vm.free_cells > 90);
    }
}
test "application operand frames retain evaluated values and unwind on error" {
    const Host = struct {
        vm: *Runtime,
        collections: u32 = 0,
        pub fn schemeCall(self: *@This(), op: EditorOp, _: []const u8, _: i32) Error!void {
            if (op != .log) return error.EditorFailure;
            // This controlled test has no unregistered outer AST locals.
            // Production evaluation does not enable collection here yet.
            self.vm.collect();
            self.collections += 1;
        }
    };
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = Host{ .vm = &vm };
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings("((11 22) #t)", try vm.evaluate("(list (list 11 22) (system/log))", &host, &out));
    try std.testing.expectEqualStrings("#t", try vm.evaluate("((lambda (x) x) (system/log))", &host, &out));
    try std.testing.expectEqual(@as(u32, 2), host.collections);
    try std.testing.expectEqual(@as(u8, 0), vm.ast_root_frame_count);
    try std.testing.expectError(error.Unbound, vm.evaluate("(list (list 1) missing)", &host, &out));
    try std.testing.expectEqual(@as(u8, 0), vm.ast_root_frame_count);
    try std.testing.expectEqualStrings("42", try vm.evaluate("(+ 20 22)", &host, &out));
}
test "compiled closure restores VM stacks after errors and success" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    try vm.start();
    defer vm.running = false;
    const proc = try vm.alloc(.closure);
    vm.heap[proc].setFlag();
    vm.heap[proc].a = 0;
    vm.heap[proc].b = 0;
    vm.heap[proc].env = vm.global;
    vm.bytecode[0] = @backingInt(BcOp.const_val);
    std.mem.writeInt(u16, vm.bytecode[1..3], makeImmediateInt(42), .little);
    vm.bytecode[3] = @backingInt(BcOp.car);
    vm.bytecode[4] = @backingInt(BcOp.ret);
    vm.bytecode_len = 5;
    try vm.pushEval(vm.yes);
    for (0..64) |_| {
        try std.testing.expectError(error.Type, vm.apply(proc, &.{}, 0, &host));
        try std.testing.expectEqual(@as(u8, 1), vm.eval_sp);
        try std.testing.expectEqual(@as(u8, 0), vm.call_sp);
        try std.testing.expectEqual(vm.yes, vm.eval_stack[0]);
    }
    vm.bytecode[3] = @backingInt(BcOp.ret);
    const result = try vm.apply(proc, &.{}, 0, &host);
    try std.testing.expectEqual(@as(i32, 42), try vm.integer(result));
    try std.testing.expectEqual(@as(u8, 1), vm.eval_sp);
    try std.testing.expectEqual(@as(u8, 0), vm.call_sp);
    vm.heap[proc].a = 1;
    vm.eval_sp = eval_stack_size - 1;
    try std.testing.expectError(error.Syntax, vm.apply(proc, &.{vm.yes}, 0, &host));
    try std.testing.expectEqual(@as(u8, eval_stack_size - 1), vm.eval_sp);
    try std.testing.expectEqual(@as(u8, 0), vm.call_sp);
    vm.eval_sp = 1;
    vm.heap[proc].a = 0;
    vm.call_sp = call_stack_capacity;
    try std.testing.expectError(error.Depth, vm.apply(proc, &.{}, 0, &host));
    try std.testing.expectEqual(@as(u8, 1), vm.eval_sp);
    try std.testing.expectEqual(@as(u8, call_stack_capacity), vm.call_sp);
}
test "compileAndRun restores transient stacks and rolls back failed compilation" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    try vm.start();
    defer vm.running = false;
    try vm.pushEval(vm.yes);
    var pos: usize = 0;
    const arithmetic = try vm.read("(+ 20 22)", &pos, 0);
    const value = try vm.compileAndRun(arithmetic, &host);
    try std.testing.expectEqual(@as(i32, 42), try vm.integer(value));
    try std.testing.expectEqual(@as(u8, 1), vm.eval_sp);
    try std.testing.expectEqual(@as(u8, 0), vm.call_sp);
    const saved_len = vm.bytecode_len;
    pos = 0;
    const unsupported = try vm.read("(begin 1 (lambda (x) x))", &pos, 0);
    try std.testing.expectError(error.CannotCompile, vm.compileAndRun(unsupported, &host));
    try std.testing.expectEqual(saved_len, vm.bytecode_len);
    try std.testing.expectEqual(@as(u8, 1), vm.eval_sp);
    pos = 0;
    const type_error = try vm.read("(car 5)", &pos, 0);
    try std.testing.expectError(error.Type, vm.compileAndRun(type_error, &host));
    try std.testing.expectEqual(@as(u8, 1), vm.eval_sp);
    try std.testing.expectEqual(@as(u8, 0), vm.call_sp);
    try std.testing.expectEqual(vm.yes, vm.eval_stack[0]);
    // Runtime errors may follow already-published compiled definitions; their
    // code must remain available rather than rolling back the whole program.
    pos = 0;
    const partial = try vm.read("(begin (define (inc x) (+ x 1)) (car 5))", &pos, 0);
    try std.testing.expectError(error.Type, vm.compileAndRun(partial, &host));
    try std.testing.expectEqual(@as(u8, 1), vm.eval_sp);
    pos = 0;
    const call = try vm.read("(inc 41)", &pos, 0);
    try std.testing.expectEqual(@as(i32, 42), try vm.integer(try vm.compileAndRun(call, &host)));
    try std.testing.expectEqual(@as(u8, 1), vm.eval_sp);
}
test "collector boundaries reject live VM and reserved-cell states" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    try vm.start();
    defer vm.running = false;
    const garbage = try vm.pair(makeImmediateInt(7), 0);
    var threshold: u16 = cells;
    vm.eval_stack[0] = 0;
    vm.eval_sp = 1;
    vm.maybeCollectBoundary(0, 0, vm.global, &threshold, cells);
    try std.testing.expectEqual(Tag.pair, vm.tagOf(garbage));
    vm.eval_sp = 0;
    vm.call_stack[0] = .{ .return_ip = 0, .fp = 0, .env = vm.global };
    vm.call_sp = 1;
    vm.maybeCollectBoundary(0, 0, vm.global, &threshold, cells);
    try std.testing.expectEqual(Tag.pair, vm.tagOf(garbage));
    vm.call_sp = 0;
    vm.cell_reserve = 1;
    vm.maybeCollectBoundary(0, 0, vm.global, &threshold, cells);
    try std.testing.expectEqual(Tag.pair, vm.tagOf(garbage));
    vm.cell_reserve = 0;
    vm.maybeCollectBoundary(1, 0, vm.global, &threshold, cells);
    try std.testing.expectEqual(Tag.pair, vm.tagOf(garbage));
    vm.maybeCollectBoundary(0, 0, vm.global, &threshold, cells);
    try std.testing.expectEqual(Tag.free, vm.tagOf(garbage));
}
test "pending control forms and initialized bindings survive controlled collection" {
    const Host = struct {
        vm: *Runtime,
        pub fn schemeCall(self: *@This(), op: EditorOp, _: []const u8, _: i32) Error!void {
            if (op != .log) return error.EditorFailure;
            // Only these explicitly tested paths are instrumented; this does
            // not enable collection at arbitrary production call sites.
            self.vm.collect();
        }
    };
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = Host{ .vm = &vm };
    var out: [128]u8 = undefined;
    for ([_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "(if (system/log) '(yes) '(no))", .expected = "(yes)" },
        .{ .source = "(begin (system/log) '(later))", .expected = "(later)" },
        .{ .source = "(and (system/log) '(ok))", .expected = "(ok)" },
        .{ .source = "(cond ((system/log) '(ok)) (else '(no)))", .expected = "(ok)" },
        .{ .source = "(cond ((list 7) => (begin (system/log) (lambda (v) (car v)))))", .expected = "7" },
        .{ .source = "(let ((x '(alpha)) (y (system/log))) (list x y))", .expected = "((alpha) #t)" },
        .{ .source = "(let* ((x '(alpha)) (y (system/log))) (list x y))", .expected = "((alpha) #t)" },
        .{ .source = "(letrec ((x '(alpha)) (f (begin (system/log) (lambda () x)))) (f))", .expected = "(alpha)" },
        .{ .source = "`(a ,(begin (system/log) (list 'x)) ,@(begin (system/log) (list 'y 'z)) ,(begin (system/log) 'w))", .expected = "(a (x) y z w)" },
        .{ .source = "(letrec* ((x '(alpha)) (y (begin (system/log) x))) y)", .expected = "(alpha)" },
        .{ .source = "(let loop ((x '(alpha)) (y (system/log))) (list x y))", .expected = "((alpha) #t)" },
        .{ .source = "((lambda () (system/log) '(survives)))", .expected = "(survives)" },
        .{ .source = "(system/log) '(later)", .expected = "(later)" },
        .{ .source = "(define held (begin (system/log) '(saved)))", .expected = "()" },
        .{ .source = "(set! held (begin (system/log) '(changed)))", .expected = "()" },
        .{ .source = "held", .expected = "(changed)" },
    }) |case| {
        try std.testing.expectEqualStrings(case.expected, try vm.evaluate(case.source, &host, &out));
        try std.testing.expectEqual(@as(u8, 0), vm.ast_root_frame_count);
    }
    try std.testing.expectError(error.Unbound, vm.evaluate("(if missing '(yes) '(no))", &host, &out));
    try std.testing.expectEqual(@as(u8, 0), vm.ast_root_frame_count);
    try std.testing.expectEqualStrings("42", try vm.evaluate("(+ 20 22)", &host, &out));
}
test "map and for-each state survives controlled collection in callbacks" {
    const Host = struct {
        vm: *Runtime,
        pub fn schemeCall(self: *@This(), op: EditorOp, _: []const u8, _: i32) Error!void {
            if (op != .log) return error.EditorFailure;
            // The collection is deliberately forced only in this test.
            self.vm.collect();
        }
    };
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = Host{ .vm = &vm };
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings("((1) (2) (3))", try vm.evaluate("(map (lambda (x) (begin (system/log) (list x))) '(1 2 3))", &host, &out));
    try std.testing.expectEqualStrings("(((a) (1)) ((b) (2)))", try vm.evaluate("(map (lambda (x y) (begin (system/log) (list x y))) '((a) (b)) '((1) (2)))", &host, &out));
    // The callback detaches the saved next cursor before forcing GC.
    try std.testing.expectEqualStrings("(1 2 3)", try vm.evaluate("(let ((xs (list 1 2 3))) (map (lambda (x) (begin (if (= x 1) (set-cdr! xs '()) #f) (system/log) x)) xs))", &host, &out));
    try std.testing.expectEqualStrings("(3 2 1)", try vm.evaluate("(let ((seen '())) (for-each (lambda (x) (begin (system/log) (set! seen (cons x seen)))) '(1 2 3)) seen)", &host, &out));
    try std.testing.expectEqual(@as(u8, 0), vm.ast_root_frame_count);
    try std.testing.expectError(error.Type, vm.evaluate("(map (lambda (x) (begin (system/log) (car x))) '(1))", &host, &out));
    try std.testing.expectEqual(@as(u8, 0), vm.ast_root_frame_count);
    try std.testing.expectEqualStrings("42", try vm.evaluate("(+ 20 22)", &host, &out));
}
test "lexical closures mutation recursion and GC persist across requests" {
    // SAFETY: runtime initializes all cells and metadata in place.
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    try expectValue(&vm, &host, "(define (make x) (lambda (y) (+ x y))) (define add7 (make 7))", "()");
    for (0..600) |_| try expectValue(&vm, &host, "(let ((x 99)) (add7 3))", "10");
    try expectValue(&vm, &host, "(define counter (let ((n 0)) (lambda () (set! n (+ n 1)) n))) (counter)", "1");
    try expectValue(&vm, &host, "(counter)", "2");
    try expectValue(&vm, &host, "(define (fact n) (if (< n 2) 1 (* n (fact (- n 1))))) (fact 5)", "120");
    try expectValue(&vm, &host, "(define x 5) (let ((x 2) (y x)) (+ x y))", "7");
    try expectValue(&vm, &host, "(if '() 42 0)", "42");
}

test "buffer persistence dispatches save and load separately" {
    try std.testing.expectEqual(Op.buffer_save, Runtime.opcode("buffer/save!").?);
    try std.testing.expectEqual(Op.buffer_load, Runtime.opcode("buffer/load!").?);
    const Host = struct {
        saved: bool = false,
        loaded: bool = false,
        pub fn saveDocument(self: *@This(), _: []const u8) Error!void {
            self.saved = true;
        }
        pub fn loadDocument(self: *@This(), _: []const u8) Error!void {
            self.loaded = true;
        }
        pub fn schemeCall(_: *@This(), _: EditorOp, _: []const u8, _: i32) Error!void {
            return error.EditorFailure;
        }
    };
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = Host{};
    var output: [64]u8 = undefined;
    _ = try vm.evaluate("(buffer/save! \"draft\")", &host, &output);
    try std.testing.expect(host.saved and !host.loaded);
    _ = try vm.evaluate("(buffer/load! \"draft\")", &host, &output);
    try std.testing.expect(host.saved and host.loaded);
}

test "unbound storage reports unavailable and provider responses are data" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var output: [128]u8 = undefined;
    try std.testing.expectError(error.StorageUnavailable, vm.evaluate("(fs/list)", &host, &output));
    const ProviderHost = struct {
        pub fn storageCall(_: *@This(), _: storage.Request, bytes: []u8) Error![]const u8 {
            const encoded = "(buffer/insert! \"must stay data\")";
            @memcpy(bytes[0..encoded.len], encoded);
            return bytes[0..encoded.len];
        }
        pub fn schemeCall(_: *@This(), _: EditorOp, _: []const u8, _: i32) Error!void {
            return error.EditorFailure;
        }
    };
    var provider = ProviderHost{};
    try std.testing.expectEqualStrings("(buffer/insert! \"must stay data\")", try vm.evaluate("(fs/list)", &provider, &output));
}
test "registered closures survive GC and command replacement is live" {
    // SAFETY: initialized before use.
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    try expectValue(&vm, &host, "(command/register! \"hello\" (lambda () (buffer/insert! \"日本\")))", "#t");
    for (0..600) |_| try expectValue(&vm, &host, "(+ 1 2)", "3");
    var output: [128]u8 = @splat(0);
    _ = try vm.runCommand("hello", &host, &output);
    try std.testing.expectEqualStrings("日本", host.bytes[0..host.length]);
    try expectValue(&vm, &host, "(command/register! \"hello\" (lambda () (buffer/insert! \"!\")))", "#t");
    _ = try vm.runCommand("hello", &host, &output);
    try std.testing.expectEqualStrings("日本!", host.bytes[0..host.length]);
    try std.testing.expectError(error.UnknownCommand, vm.runCommand("hello) (buffer/insert! \"bad\")", &host, &output));
}
test "reader stages all forms and errors return without destroying definitions" {
    // SAFETY: initialized before use.
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = @splat(0);
    try expectValue(&vm, &host, "(define keep 17)", "()");
    try std.testing.expectError(error.Syntax, vm.evaluate("(buffer/insert! \"bad\") (", &host, &out));
    try std.testing.expectEqual(@as(usize, 0), host.length);
    try std.testing.expectError(error.Overflow, vm.evaluate("(+ 2147483647 1)", &host, &out));
    try std.testing.expectError(error.Arity, vm.evaluate("(car)", &host, &out));
    try std.testing.expectError(error.Depth, vm.evaluate("(define (loop) (+ 1 (loop))) (loop)", &host, &out));
    try expectValue(&vm, &host, "keep", "17");
    try expectValue(&vm, &host, "; comment\n(list '日本 \"a\\n\\\"b\")", "(日本 \"a\\n\\\"b\")");
    try std.testing.expectError(error.Syntax, vm.evaluate(&.{0xff}, &host, &out));
    try std.testing.expectError(error.Syntax, vm.evaluate("(let ((x 1) (x 2)) x)", &host, &out));
    try expectValue(&vm, &host, "(and #f missing)", "#f");
    try expectValue(&vm, &host, "(or 0 missing)", "0");
}
test "bounded malformed requests do not trap or retain ephemeral garbage" {
    // SAFETY: initialized before use.
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var output: [128]u8 = @splat(0);
    var random = std.Random.DefaultPrng.init(0x736368656d65);
    const alphabet = "()'\";\\+-#tf xyz012\n";
    for (0..2500) |_| {
        var source: [48]u8 = @splat(' ');
        for (&source) |*byte| byte.* = alphabet[random.random().uintLessThan(usize, alphabet.len)];
        _ = vm.evaluate(&source, &host, &output) catch {};
    }
    try expectValue(&vm, &host, "(+ 20 22)", "42");
}

const messages linksection(data_section) = "Nesting limit\x00Evaluation budget\x00Scheme heap full\x00Unknown command\x00Invalid syntax\x00Wrong argument type\x00Wrong argument count\x00Unbound name\x00Integer overflow\x00Text/result too long\x00Command registry full\x00Editor operation failed\x00Evaluator busy\x00Camera unavailable\x00Camera busy\x00Invalid camera handle\x00Invalid camera range\x00Camera failed\x00App unavailable\x00Storage unavailable\x00Storage busy\x00Storage permission denied\x00Stale storage handle\x00Storage full\x00File not found\x00Storage request/result limit\x00Storage commit outcome unknown\x00Storage operation failed\x00Card unavailable\x00Card busy\x00Invalid card handle\x00Invalid card range\x00Card failed\x00Card locked\x00PIN entry cancelled\x00Cannot compile\x00Division by zero\x00".*;
pub fn message(err: Error) linksection(code_section) []const u8 {
    const wanted: usize = switch (err) {
        error.Depth => 0,
        error.Budget => 1,
        error.HeapFull => 2,
        error.UnknownCommand => 3,
        error.Syntax => 4,
        error.Type => 5,
        error.Arity => 6,
        error.Unbound => 7,
        error.Overflow => 8,
        error.TextFull => 9,
        error.CommandFull => 10,
        error.EditorFailure => 11,
        error.Busy => 12,
        error.CameraUnavailable => 13,
        error.CameraBusy => 14,
        error.InvalidCameraHandle => 15,
        error.InvalidCameraRange => 16,
        error.CameraFailed => 17,
        error.AppUnavailable => 18,
        error.StorageUnavailable => 19,
        error.StorageBusy => 20,
        error.StorageDenied => 21,
        error.StorageStale => 22,
        error.StorageFull => 23,
        error.StorageNotFound => 24,
        error.StorageLimit => 25,
        error.StorageOutcomeUnknown => 26,
        error.StorageFailed => 27,
        error.CardUnavailable => 28,
        error.CardBusy => 29,
        error.InvalidCardHandle => 30,
        error.InvalidCardRange => 31,
        error.CardFailed => 32,
        error.CardLocked => 33,
        error.PinCancelled => 34,
        error.CannotCompile => 35,
        error.DivisionByZero => 36,
    };
    var pos: usize = 0;
    var index: usize = 0;
    while (index < wanted) : (index += 1) pos += (std.mem.indexOfScalar(u8, messages[pos..], 0) orelse 0) + 1;
    const end = pos + (std.mem.indexOfScalar(u8, messages[pos..], 0) orelse 0);
    return messages[pos..end];
}

test "real work hits evaluation budget and exhausted heap recovers on next request" {
    // SAFETY: initialized before use.
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var output: [128]u8 = @splat(0);
    try expectValue(&vm, &host, "(define (spin n) (if (= n 0) 0 (spin (- n 1))))", "()");
    try expectValue(&vm, &host, &repeat("0 ", 300), "0");
    try std.testing.expectError(error.Budget, vm.evaluate("(spin 10000)", &host, &output));
    try expectValue(&vm, &host, "(define heap-test-root '())", "()");
    const root_name = vm.findSymbol("heap-test-root").?;
    vm.collect();
    var retained: Ref = 0;
    while (vm.free_cells > 0) retained = try vm.pair(0, retained);
    try vm.define(vm.global, root_name, retained);
    try std.testing.expectError(error.HeapFull, vm.evaluate("(+ 20 22)", &host, &output));
    try vm.define(vm.global, root_name, 0);
    try expectValue(&vm, &host, "(+ 20 22)", "42");
}

fn repeat(comptime text_value: []const u8, comptime count: usize) [text_value.len * count]u8 {
    var result: [text_value.len * count]u8 = @splat(0);
    for (0..count) |index| @memcpy(result[index * text_value.len ..][0..text_value.len], text_value);
    return result;
}

test "view options share an atomic typed contract and survive GC" {
    // SAFETY: initialized before use.
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var output: [128]u8 = @splat(0);
    try expectValue(&vm, &host, "#:foreground", "#:foreground");
    try std.testing.expectError(error.Syntax, vm.evaluate("#:", &host, &output));
    try expectValue(&vm, &host, "(view/set! #:font 'gothic #:size 36 #:foreground #x234567 #:cursor-width 4)", "2");
    try expectValue(&vm, &host, "(view/get #:foreground)", "2311527");
    try std.testing.expectEqual(@as(u8, 36), vm.view.style.body_px);
    try std.testing.expectError(error.Type, vm.evaluate("(view/set! #:size 48 #:foreground -1)", &host, &output));
    try expectValue(&vm, &host, "(view/get #:size)", "36");
    try std.testing.expectEqual(@as(u32, 2), vm.view_generation);
    for (0..12) |_| try expectValue(&vm, &host, "(+ 1 2)", "3");
    try expectValue(&vm, &host, "(sys/config-rollback!)", "1");
    try expectValue(&vm, &host, "(view/get #:font)", "bunsen-mincho");
    try expectValue(&vm, &host, "(view/set! #:linear-blend #t #:margin-x 32)", "2");
    try expectValue(&vm, &host, "(view/get #:linear-blend)", "#t");
}

test "app capability, callback roots, replacement and atomic plot options" {
    // SAFETY: initialized before use.
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var output: [128]u8 = undefined;
    try std.testing.expectError(error.AppUnavailable, vm.evaluate("(app/on-frame! (lambda (t) t))", &host, &output));
    vm.app.enabled = true;
    try expectValue(&vm, &host, "(app/on-frame! (let ((n 0)) (lambda (t) (set! n (+ n 1)) (plot/set! #:phase n))))", "#t");
    for (1..201) |n| {
        try vm.runFrame(@intCast(n), &host);
        try std.testing.expectEqual(@as(u8, @intCast(n)), vm.app.plot.phase);
        try expectValue(&vm, &host, "(+ 1 2)", "3");
    }
    try expectValue(&vm, &host, "(app/on-frame! (lambda (t) (plot/set! #:phase 7)))", "#t");
    try vm.runFrame(200, &host);
    try std.testing.expectEqual(@as(u8, 7), vm.app.plot.phase);
    try expectValue(&vm, &host, "(app/ticks)", "200");
    try std.testing.expectError(error.Arity, vm.evaluate("(app/on-frame! (lambda () #t))", &host, &output));
    try std.testing.expectError(error.Type, vm.evaluate("(plot/set! #:phase 9 #:amplitude 101)", &host, &output));
    try std.testing.expectEqual(@as(u8, 7), vm.app.plot.phase);
    try expectValue(&vm, &host, "(plot/sine -64 25)", "-25");
    try expectValue(&vm, &host, "(plot/sine 64 25)", "25");
    try expectValue(&vm, &host, "(app/on-frame! #f)", "#t");
    try vm.runFrame(201, &host);
    try std.testing.expectEqual(@as(u8, 7), vm.app.plot.phase);
    try expectValue(&vm, &host, "(app/stop!)", "#t");
    try std.testing.expect(vm.app.paused and vm.frame_callback == 0);
}

test "scheme runtime memory footprint and tail call execution" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;

    // 1. Structure Sizes & Memory Footprint assertions
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(Cell));
    try std.testing.expectEqual(@as(usize, cells * 12), @sizeOf(@TypeOf(vm.heap)));
    // Equality's bounded work queue resides in the PSRAM-owned runtime.
    try std.testing.expect(@sizeOf(Runtime) <= 82 * 1024);

    // 2. Symbol Interning & Heap Density
    _ = try vm.evaluate("(define a 1) (define b 2) (define c 3) (define d 4) (define e 5)", &host, &out);
    for (0..30) |_| {
        _ = try vm.evaluate("(+ a (+ b (+ c (+ d e))))", &host, &out);
    }
    try std.testing.expect(vm.free_cells > 200);

    // 3. Tail Call Optimization (TCO)
    vm.initInPlace();
    _ = try vm.evaluate(
        \\(define (sum-iter n acc)
        \\  (if (= n 0)
        \\      acc
        \\      (sum-iter (- n 1) (+ acc n))))
    , &host, &out);
    vm.step_budget = 50000;
    const tco_res = try vm.evaluate("(sum-iter 50 0)", &host, &out);
    try std.testing.expectEqualStrings("1275", tco_res);
}

test "bytecode VM execution: arithmetic, control flow, and local loop" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};

    // 1. Arithmetic: 10 + 20 * 2 = 50 -> (10 + (20 * 2))
    vm.bytecode_len = 0;
    vm.eval_sp = 0;
    var ip: usize = 0;
    vm.bytecode[ip] = @backingInt(BcOp.const_val);
    std.mem.writeInt(u16, vm.bytecode[ip + 1 ..][0..2], makeImmediateInt(10), .little);
    ip += 3;
    vm.bytecode[ip] = @backingInt(BcOp.const_val);
    std.mem.writeInt(u16, vm.bytecode[ip + 1 ..][0..2], makeImmediateInt(20), .little);
    ip += 3;
    vm.bytecode[ip] = @backingInt(BcOp.const_val);
    std.mem.writeInt(u16, vm.bytecode[ip + 1 ..][0..2], makeImmediateInt(2), .little);
    ip += 3;
    vm.bytecode[ip] = @backingInt(BcOp.mul);
    ip += 1;
    vm.bytecode[ip] = @backingInt(BcOp.add);
    ip += 1;
    vm.bytecode[ip] = @backingInt(BcOp.halt);
    ip += 1;
    vm.bytecode_len = @intCast(ip);

    vm.step_budget = 1000;
    const res1 = try vm.runVm(0, &host);
    try std.testing.expectEqual(@as(i32, 50), try vm.integer(res1));

    // 2. Control flow: (if (< 15 20) 42 99) -> 42
    vm.bytecode_len = 0;
    vm.eval_sp = 0;
    ip = 0;
    vm.bytecode[ip] = @backingInt(BcOp.const_val);
    std.mem.writeInt(u16, vm.bytecode[ip + 1 ..][0..2], makeImmediateInt(15), .little);
    ip += 3;
    vm.bytecode[ip] = @backingInt(BcOp.const_val);
    std.mem.writeInt(u16, vm.bytecode[ip + 1 ..][0..2], makeImmediateInt(20), .little);
    ip += 3;
    vm.bytecode[ip] = @backingInt(BcOp.less);
    ip += 1;
    vm.bytecode[ip] = @backingInt(BcOp.jump_if_false);
    std.mem.writeInt(u16, vm.bytecode[ip + 1 ..][0..2], @as(u16, @bitCast(@as(i16, 4))), .little);
    ip += 3;
    vm.bytecode[ip] = @backingInt(BcOp.const_val);
    std.mem.writeInt(u16, vm.bytecode[ip + 1 ..][0..2], makeImmediateInt(42), .little);
    ip += 3;
    vm.bytecode[ip] = @backingInt(BcOp.halt);
    ip += 1;
    vm.bytecode[ip] = @backingInt(BcOp.const_val);
    std.mem.writeInt(u16, vm.bytecode[ip + 1 ..][0..2], makeImmediateInt(99), .little);
    ip += 3;
    vm.bytecode[ip] = @backingInt(BcOp.halt);
    ip += 1;
    vm.bytecode_len = @intCast(ip);

    vm.step_budget = 1000;
    const res2 = try vm.runVm(0, &host);
    try std.testing.expectEqual(@as(i32, 42), try vm.integer(res2));

    // 3. Fast local loop in VM: sum 1..10 = 55
    vm.bytecode_len = 0;
    vm.eval_sp = 0;
    try vm.pushEval(makeImmediateInt(10)); // slot 0
    try vm.pushEval(makeImmediateInt(0)); // slot 1
    ip = 0;
    vm.bytecode[ip] = @backingInt(BcOp.load_local);
    vm.bytecode[ip + 1] = 0;
    ip += 2;
    vm.bytecode[ip] = @backingInt(BcOp.const_val);
    std.mem.writeInt(u16, vm.bytecode[ip + 1 ..][0..2], makeImmediateInt(0), .little);
    ip += 3;
    vm.bytecode[ip] = @backingInt(BcOp.equal);
    ip += 1;
    vm.bytecode[ip] = @backingInt(BcOp.jump_if_false);
    std.mem.writeInt(u16, vm.bytecode[ip + 1 ..][0..2], @as(u16, @bitCast(@as(i16, 3))), .little);
    ip += 3;
    vm.bytecode[ip] = @backingInt(BcOp.load_local);
    vm.bytecode[ip + 1] = 1;
    ip += 2;
    vm.bytecode[ip] = @backingInt(BcOp.halt);
    ip += 1;
    vm.bytecode[ip] = @backingInt(BcOp.load_local);
    vm.bytecode[ip + 1] = 1;
    ip += 2;
    vm.bytecode[ip] = @backingInt(BcOp.load_local);
    vm.bytecode[ip + 1] = 0;
    ip += 2;
    vm.bytecode[ip] = @backingInt(BcOp.add);
    ip += 1;
    vm.bytecode[ip] = @backingInt(BcOp.store_local);
    vm.bytecode[ip + 1] = 1;
    ip += 2;
    vm.bytecode[ip] = @backingInt(BcOp.load_local);
    vm.bytecode[ip + 1] = 0;
    ip += 2;
    vm.bytecode[ip] = @backingInt(BcOp.const_val);
    std.mem.writeInt(u16, vm.bytecode[ip + 1 ..][0..2], makeImmediateInt(1), .little);
    ip += 3;
    vm.bytecode[ip] = @backingInt(BcOp.sub);
    ip += 1;
    vm.bytecode[ip] = @backingInt(BcOp.store_local);
    vm.bytecode[ip + 1] = 0;
    ip += 2;
    vm.bytecode[ip] = @backingInt(BcOp.jump);
    const jump_offset: i16 = -@as(i16, @intCast(ip + 3));
    std.mem.writeInt(u16, vm.bytecode[ip + 1 ..][0..2], @as(u16, @bitCast(jump_offset)), .little);
    ip += 3;
    vm.bytecode_len = @intCast(ip);

    vm.step_budget = 10000;
    const initial_free_cells = vm.free_cells;
    const res3 = try vm.runVm(0, &host);
    try std.testing.expectEqual(@as(i32, 55), try vm.integer(res3));
    try std.testing.expectEqual(initial_free_cells, vm.free_cells);
}

test "compiler and bytecode VM execution: AST to bytecode" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    try vm.start();
    vm.step_budget = 50000;
    var host = TestHost{};

    // 1. Simple expression: (+ 12 34)
    var pos: usize = 0;
    const expr1 = try vm.read("(+ 12 34)", &pos, 0);
    const res1 = try vm.compileAndRun(expr1, &host);
    try std.testing.expectEqual(@as(i32, 46), try vm.integer(res1));

    // 2. Conditionals: (if (< 10 20) 100 200)
    pos = 0;
    const expr2 = try vm.read("(if (< 10 20) 100 200)", &pos, 0);
    const res2 = try vm.compileAndRun(expr2, &host);
    try std.testing.expectEqual(@as(i32, 100), try vm.integer(res2));

    // 3. Define function and call via compileAndRun
    pos = 0;
    const def_fn = try vm.read(
        \\(define (sum-iter n acc)
        \\  (if (= n 0)
        \\      acc
        \\      (sum-iter (- n 1) (+ acc n))))
    , &pos, 0);
    _ = try vm.compileAndRun(def_fn, &host);

    // Call (sum-iter 50 0) compiled into bytecode!
    pos = 0;
    const call_fn = try vm.read("(sum-iter 50 0)", &pos, 0);
    const initial_free_cells = vm.free_cells;
    const res3 = try vm.compileAndRun(call_fn, &host);
    try std.testing.expectEqual(@as(i32, 1275), try vm.integer(res3));

    // Verify 0 cells allocated during the 50 recursive iterations in VM!
    try std.testing.expectEqual(initial_free_cells, vm.free_cells);
}

test "compiler and bytecode VM execution: transparent evaluate" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = @splat(0);

    _ = try vm.evaluate(
        \\(define (sum-iter n acc)
        \\  (if (= n 0)
        \\      acc
        \\      (sum-iter (- n 1) (+ acc n))))
    , &host, &out);

    vm.collect();
    const initial_free = vm.free_cells;
    const res = try vm.evaluate("(sum-iter 50 0)", &host, &out);
    try std.testing.expectEqualStrings("1275", res);
    vm.collect();
    try std.testing.expectEqual(initial_free, vm.free_cells);
}

test "temporary bytecode is reclaimed and compiler respects mutable bindings" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    for (0..1000) |_| {
        try std.testing.expectEqualStrings("3", try vm.evaluate("(+ 1 2)", &host, &out));
        try std.testing.expectEqual(@as(u16, 0), vm.bytecode_len);
    }
    try std.testing.expectError(error.Unbound, vm.evaluate("(set! absent 1)", &host, &out));
    try std.testing.expectEqualStrings("9", try vm.evaluate("(define + (lambda (a b) 9)) (+ 1 2)", &host, &out));
    try std.testing.expectEqualStrings("9", try vm.evaluate("(+ 1 2)", &host, &out));
    try std.testing.expectEqualStrings("7", try vm.evaluate("(set! + (lambda (a b) 7)) (+ 1 2)", &host, &out));
    try std.testing.expectEqualStrings("7", try vm.evaluate("(+ 1 2)", &host, &out));
    try std.testing.expectEqual(@as(u16, 0), vm.bytecode_len);
}

test "collection compacts live text in allocation order" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    _ = try vm.evaluate("(define a \"first\") (define b \"second\")", &host, &out);
    for (0..200) |_| {
        _ = try vm.evaluate("(list \"discard\" \"more garbage\")", &host, &out);
        try std.testing.expectEqualStrings("(\"first\" \"second\")", try vm.evaluate("(list a b)", &host, &out));
    }
}

test "tail calls preserve captured frames and lexical parents" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    const source = "(define saved #f) (define (f x) (if (= x 2) (set! saved (lambda () x)) #f) (if (= x 0) (saved) (f (- x 1)))) (f 2)";
    try std.testing.expectEqualStrings("2", try vm.evaluate(source, &host, &out));
    try std.testing.expectEqualStrings("2", try vm.evaluate("(saved)", &host, &out));
    vm.initInPlace();
    const lexical = "(define a (let ((z 11)) (lambda (x) z))) (define b (let ((z 22)) (lambda (x) (a x)))) (b 1)";
    try std.testing.expectEqualStrings("11", try vm.evaluate(lexical, &host, &out));
}

test "numeric function cache respects rebinding and collects dead code" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    _ = try vm.evaluate("(define (sum-iter n acc) (if (= n 0) acc (sum-iter (- n 1) (+ acc n))))", &host, &out);
    for (0..100) |_| {
        try std.testing.expectEqualStrings("1275", try vm.evaluate("(sum-iter 50 0)", &host, &out));
        try std.testing.expect(vm.cached_proc != 0);
        try std.testing.expect(vm.bytecode_len > 0);
    }
    _ = try vm.evaluate("(set! sum-iter #f)", &host, &out);
    _ = try vm.evaluate("0", &host, &out);
    try std.testing.expectEqual(@as(Ref, 0), vm.cached_proc);
    try std.testing.expectEqual(@as(u16, 0), vm.bytecode_len);
    vm.initInPlace();
    _ = try vm.evaluate("(define (f x) (+ x 1))", &host, &out);
    try std.testing.expectEqualStrings("3", try vm.evaluate("(f 2)", &host, &out));
    try std.testing.expect(vm.cached_proc != 0);
    _ = try vm.evaluate("(define + (lambda (a b) 77))", &host, &out);
    try std.testing.expectEqualStrings("77", try vm.evaluate("(f 2)", &host, &out));
    try std.testing.expectError(error.Type, vm.evaluate("(= #t #t)", &host, &out));
}

test "sliced GC clears a dead weak numeric cache before cell reuse" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    _ = try vm.evaluate("(define (f x) (+ x 1))", &host, &out);
    try std.testing.expectEqualStrings("3", try vm.evaluate("(f 2)", &host, &out));
    try std.testing.expect(vm.cached_proc != 0 and vm.bytecode_len != 0);
    _ = try vm.evaluate("(set! f #f)", &host, &out);
    try std.testing.expect(vm.cached_proc != 0);
    var cursor = Runtime.SliceCursor{};
    while (!vm.collectSlice(&cursor, 0, 0, 1)) {}
    try std.testing.expectEqual(@as(Ref, 0), vm.cached_proc);
    try std.testing.expectEqual(@as(u16, 0), vm.bytecode_len);
    _ = try vm.evaluate("(define (f x) (+ x 2))", &host, &out);
    try std.testing.expectEqualStrings("4", try vm.evaluate("(f 2)", &host, &out));
}

test "non-tail calls cannot overwrite the caller frame" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    const src = "(define (g x) (+ x 1)) (define (f x) (+ (g 9) x)) (f 3)";
    try std.testing.expectEqualStrings("13", try vm.evaluate(src, &host, &out));
}

test "numeric cache matches interpreter across inputs and errors" {
    var fast: Runtime = undefined;
    var slow: Runtime = undefined;
    fast.initInPlace();
    slow.initInPlace();
    var host = TestHost{};
    var output: [128]u8 = undefined;
    var reference: [128]u8 = undefined;
    const definition = "(define (sum-iter n acc) (if (= n 0) acc (sum-iter (- n 1) (+ acc n))))";
    _ = try fast.evaluate(definition, &host, &output);
    _ = try slow.evaluate(definition, &host, &output);
    for (0..26) |n| {
        var source: [64]u8 = undefined;
        const input = try std.fmt.bufPrint(&source, "(sum-iter {d} 0)", .{n});
        const actual = try fast.evaluate(input, &host, &output);
        try slow.start();
        var pos: usize = 0;
        const expr = try slow.read(input, &pos, 0);
        const expected_ref = try slow.eval(expr, slow.global, 0, &host);
        const expected = try slow.format(expected_ref, &reference);
        slow.running = false;
        try std.testing.expectEqualStrings(expected, actual);
        try std.testing.expect(fast.cached_proc != 0);
    }
    try std.testing.expectError(error.Type, fast.evaluate("(= #t #t)", &host, &output));
}

fn nowNs() u64 {
    if (comptime @import("builtin").os.tag == .macos) {
        const DarwinTime = struct {
            extern "c" fn mach_absolute_time() u64;
        };
        return DarwinTime.mach_absolute_time();
    }
    return 0;
}

test "benchmark Phase 4: AST Interpreter vs Bytecode VM" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};

    const sum_fn =
        \\(define (sum-iter n acc)
        \\  (if (= n 0)
        \\      acc
        \\      (sum-iter (- n 1) (+ acc n))))
    ;

    // --- Benchmark 1: Recursive loop (50 iterations per call, 5,000 runs = 250,000 steps) ---
    // 1A: Bytecode VM compiled
    try vm.start();
    vm.step_budget = 100_000_000;
    var pos: usize = 0;
    const compiled_definition = try vm.read(sum_fn, &pos, 0);
    _ = try vm.compileAndRun(compiled_definition, &host);
    pos = 0;
    const call_expr = try vm.read("(sum-iter 50 0)", &pos, 0);
    const start_ip = try vm.compile(call_expr);

    // Warmup
    _ = try vm.runVm(start_ip, &host);

    const initial_free_bc = vm.free_cells;
    const saved_sp = vm.eval_sp;
    const t0_bc = nowNs();
    const bc_repeats: usize = 30;
    var i: usize = 0;
    var bc_sum: i32 = 0;
    while (i < bc_repeats) : (i += 1) {
        vm.steps = 0;
        const res = try vm.runVm(start_ip, &host);
        bc_sum += try vm.integer(res);
        vm.eval_sp = saved_sp;
    }
    const t1_bc = nowNs();
    try std.testing.expectEqual(@as(i32, 1275 * bc_repeats), bc_sum);
    const bc_time_ns = t1_bc - t0_bc;
    const cells_used_bc = initial_free_bc - vm.free_cells;

    // 1B: AST Interpreter
    // Define AST closure by clearing VM and eval
    vm.initInPlace();
    vm.step_budget = 100_000_000;
    pos = 0;
    const def_ast = try vm.read(sum_fn, &pos, 0);
    _ = try vm.eval(def_ast, vm.global, 0, &host);

    pos = 0;
    const call_ast = try vm.read("(sum-iter 50 0)", &pos, 0);
    try vm.pushEval(call_ast);

    // Warmup
    const res_ast_warmup = try vm.eval(call_ast, vm.global, 0, &host);
    try std.testing.expectEqual(@as(i32, 1275), try vm.integer(res_ast_warmup));

    vm.collect();
    const initial_free_ast = vm.free_cells;
    const t0_ast = nowNs();
    i = 0;
    var ast_sum: i32 = 0;
    while (i < bc_repeats) : (i += 1) {
        vm.steps = 0;
        const res = try vm.eval(call_ast, vm.global, 0, &host);
        ast_sum += try vm.integer(res);
    }
    const t1_ast = nowNs();
    try std.testing.expectEqual(@as(i32, 1275 * bc_repeats), ast_sum);
    const ast_time_ns = t1_ast - t0_ast;
    const cells_used_ast = initial_free_ast - vm.free_cells;

    // --- Benchmark 2: Arithmetic expression (+ (* 12 34) (- 56 78)) x 20,000 runs ---
    const arith_src = "(+ (* 12 34) (- 56 78))";
    pos = 0;
    const arith_expr = try vm.read(arith_src, &pos, 0);
    const arith_ip = try vm.compile(arith_expr);

    const arith_repeats: usize = 20_000;
    const arith_saved_sp = vm.eval_sp;
    const t0_arith_bc = nowNs();
    i = 0;
    while (i < arith_repeats) : (i += 1) {
        vm.steps = 0;
        _ = try vm.runVm(arith_ip, &host);
        vm.eval_sp = arith_saved_sp;
    }
    const t1_arith_bc = nowNs();
    const arith_bc_ns = t1_arith_bc - t0_arith_bc;

    const t0_arith_ast = nowNs();
    i = 0;
    while (i < arith_repeats) : (i += 1) {
        vm.steps = 0;
        _ = try vm.eval(arith_expr, vm.global, 0, &host);
    }
    const t1_arith_ast = nowNs();
    const arith_ast_ns = t1_arith_ast - t0_arith_ast;

    std.debug.print("\n\n================ Phase 4 Performance Benchmark ================\n", .{});
    std.debug.print("1. Recursive Loop (sum-iter 50 0) x {d} runs (250,000 iterations total):\n", .{bc_repeats});
    std.debug.print("   - AST Interpreter: {d:.2} ms ({d:.1} ns/step), heap cells: {d}\n", .{
        @as(f64, @floatFromInt(ast_time_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(ast_time_ns)) / @as(f64, @floatFromInt(bc_repeats * 50)),
        cells_used_ast,
    });
    std.debug.print("   - Bytecode VM:     {d:.2} ms ({d:.1} ns/step), heap cells: {d}\n", .{
        @as(f64, @floatFromInt(bc_time_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(bc_time_ns)) / @as(f64, @floatFromInt(bc_repeats * 50)),
        cells_used_bc,
    });
    std.debug.print("   => Speedup:        {d:.2}x faster!\n", .{
        @as(f64, @floatFromInt(ast_time_ns)) / @as(f64, @floatFromInt(bc_time_ns)),
    });

    std.debug.print("\n2. Arithmetic Expression (+ (* 12 34) (- 56 78)) x {d} runs:\n", .{arith_repeats});
    std.debug.print("   - AST Interpreter: {d:.2} ms ({d:.1} ns/eval)\n", .{
        @as(f64, @floatFromInt(arith_ast_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(arith_ast_ns)) / @as(f64, @floatFromInt(arith_repeats)),
    });
    std.debug.print("   - Bytecode VM:     {d:.2} ms ({d:.1} ns/eval)\n", .{
        @as(f64, @floatFromInt(arith_bc_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(arith_bc_ns)) / @as(f64, @floatFromInt(arith_repeats)),
    });
    std.debug.print("   => Speedup:        {d:.2}x faster!\n", .{
        @as(f64, @floatFromInt(arith_ast_ns)) / @as(f64, @floatFromInt(arith_bc_ns)),
    });

    std.debug.print("\n3. SRAM Footprint:\n", .{});
    std.debug.print("   - Phase 2 (Tagged Unions Baseline):  8,248 bytes\n", .{});
    std.debug.print("   - Phase 3 (Immediate Tags & In-Place): 7,336 bytes\n", .{});
    std.debug.print("   - Runtime footprint: {d} bytes\n", .{@sizeOf(Runtime)});
    std.debug.print("=================================================================\n\n", .{});
}

test "captured and non-tail environments retain lexical bindings" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    _ = try vm.evaluate("(define saved #f) (define (f x) (if (= x 2) (set! saved (lambda () x)) #f) (if (= x 0) (saved) (f (- x 1))))", &host, &out);
    try std.testing.expectEqualStrings("2", try vm.evaluate("(f 2)", &host, &out));
    try std.testing.expectEqualStrings("2", try vm.evaluate("(saved)", &host, &out));
    vm.initInPlace();
    _ = try vm.evaluate("(define a (let ((z 11)) (lambda (x) z))) (define b (let ((z 22)) (lambda (x) (a x))))", &host, &out);
    try std.testing.expectEqualStrings("11", try vm.evaluate("(b 1)", &host, &out));
    vm.initInPlace();
    _ = try vm.evaluate("(define (g x) (+ x 1)) (define (f x) (+ (g 9) x))", &host, &out);
    try std.testing.expectEqualStrings("13", try vm.evaluate("(f 3)", &host, &out));
}

test "evaluation respects unbound set and redefined numeric procedures" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    try std.testing.expectError(error.Unbound, vm.evaluate("(set! missing 1)", &host, &out));
    _ = try vm.evaluate("(define + (lambda (a b) 9))", &host, &out);
    try std.testing.expectEqualStrings("9", try vm.evaluate("(+ 1 2)", &host, &out));
}

test "list quasiquote observes nesting splicing dotted tails and errors" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [256]u8 = undefined;
    try expectValue(&vm, &host, "(let ((x 2)) `(1 ,x 3))", "(1 2 3)");
    try expectValue(&vm, &host, "`(a ,(+ 1 2) ,@(list 4 5) . ,(+ 2 5))", "(a 3 4 5 . 7)");
    try expectValue(&vm, &host, "(let ((x 2)) `(a `(b ,x ,,x) ,x))", "(a (quasiquote (b (unquote x) (unquote 2))) 2)");
    try expectValue(&vm, &host, "`(a ,@(list) b)", "(a b)");
    try expectValue(&vm, &host, "`(a unquote (+ 1 2))", "(a . 3)");
    try expectValue(&vm, &host, "(let ((x '(9 8))) `(1 ,@x 3))", "(1 9 8 3)");
    try expectValue(&vm, &host, "`(quasiquote (a (unquote (+ 1 2))))", "(quasiquote (a (unquote (+ 1 2))))");
    try expectValue(&vm, &host, "`(0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25)", "(0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25)");
    try std.testing.expectError(error.Type, vm.evaluate("`(a ,@3)", &host, &out));
    try std.testing.expectError(error.Syntax, vm.evaluate(",x", &host, &out));
    try std.testing.expectError(error.Syntax, vm.evaluate("`,@(list 1 2)", &host, &out));
    try expectValue(&vm, &host, "(+ 20 22)", "42");
}

test "recursive bindings and named let preserve scope and recover" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [256]u8 = undefined;
    try expectValue(&vm, &host, "(letrec ((even (lambda (n) (if (= n 0) #t (odd (- n 1))))) (odd (lambda (n) (if (= n 0) #f (even (- n 1)))))) (even 100))", "#t");
    try expectValue(&vm, &host, "(letrec* ((x 1) (y (+ x 2))) y)", "3");
    try std.testing.expectError(error.Unbound, vm.evaluate("(letrec ((x 1) (y x)) y)", &host, &out));
    try std.testing.expectError(error.Unbound, vm.evaluate("(letrec ((x x)) x)", &host, &out));
    try std.testing.expectError(error.Unbound, vm.evaluate("(letrec ((x (begin (set! x 1) 2))) x)", &host, &out));
    try std.testing.expectError(error.Syntax, vm.evaluate("(letrec ((x 1) (x 2)) x)", &host, &out));
    try std.testing.expectError(error.Syntax, vm.evaluate("(let loop ((x 1) (x 2)) x)", &host, &out));
    try expectValue(&vm, &host, "(let ((loop 7)) (let loop ((x loop)) x))", "7");
    try expectValue(&vm, &host, "(let loop ((n 100) (a 0)) (if (= n 0) a (loop (- n 1) (+ a 1))))", "100");
    try expectValue(&vm, &host, "(let loop () 42)", "42");
    try expectValue(&vm, &host, "(+ 20 22)", "42");
}

test "ordered integer comparisons support multiple operands" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings("#t", try vm.evaluate("(> 5 4 2)", &host, &out));
    try std.testing.expectEqualStrings("#f", try vm.evaluate("(<= 1 3 2)", &host, &out));
    try std.testing.expectEqualStrings("#t", try vm.evaluate("(>= 3 3 2)", &host, &out));
    try std.testing.expectEqualStrings("#t", try vm.evaluate("(= 2 2 2)", &host, &out));
    try std.testing.expectError(error.Type, vm.evaluate("(= #t #t)", &host, &out));
}

test "cond evaluates clauses in order and returns selected values" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings("4", try vm.evaluate("(cond ((> 1 2) 9) ((+ 1 3)))", &host, &out));
    try std.testing.expectEqualStrings("7", try vm.evaluate("(cond (#f 9) (else 7))", &host, &out));
    try std.testing.expectEqualStrings("5", try vm.evaluate("(cond ((+ 1 3) => (lambda (x) (+ x 1))))", &host, &out));
    try std.testing.expectError(error.Syntax, vm.evaluate("(cond (else 1) (#t 2))", &host, &out));
    try std.testing.expectEqualStrings("ok", try vm.evaluate("(let ((=> #f)) (cond (#t => 'ok)))", &host, &out));
}

test "exact bounded fractions normalize and interoperate with integers" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    try expectValue(&vm, &host, "(/ 6 4)", "3/2");
    try expectValue(&vm, &host, "(/ -6 4)", "-3/2");
    try expectValue(&vm, &host, "(/ 2)", "1/2");
    try expectValue(&vm, &host, "(+ 1/3 1/2)", "5/6");
    try expectValue(&vm, &host, "(* 4/9 3/2)", "2/3");
    try expectValue(&vm, &host, "(- 1/3 1/2)", "-1/6");
    try expectValue(&vm, &host, "(= 2/4 1/2)", "#t");
    try expectValue(&vm, &host, "(< -2/3 -1/2 1)", "#t");
    try expectValue(&vm, &host, "(list 4/2 0/7 6/8)", "(2 0 3/4)");
    try expectValue(&vm, &host, "(/ -2147483648 -2147483648)", "1");
    try expectValue(&vm, &host, "(+ 2147483647/2147483646 -2147483647/2147483646)", "0");
    try expectValue(&vm, &host, "(define pi-frac 355/113)", "()");
    for (0..10) |_| try expectValue(&vm, &host, "(+ pi-frac 0)", "355/113");
    try std.testing.expectError(error.DivisionByZero, vm.evaluate("(/ 1 0)", &host, &out));
    try std.testing.expectError(error.DivisionByZero, vm.evaluate("(/ 0)", &host, &out));
    try std.testing.expectError(error.DivisionByZero, vm.evaluate("1/0", &host, &out));
    try std.testing.expectError(error.Overflow, vm.evaluate("(/ -2147483648 -1)", &host, &out));
    try expectValue(&vm, &host, "(+ 1/3 1/6)", "1/2");
}

test "list operations and apply honor bounded arguments and recover from errors" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    try expectValue(&vm, &host, "(apply + 1 2 '(3 4))", "10");
    try expectValue(&vm, &host, "(apply (lambda (a b) (- a b)) '(9 4))", "5");
    try expectValue(&vm, &host, "(length '(1 2 3))", "3");
    try expectValue(&vm, &host, "(reverse '(1 2 3))", "(3 2 1)");
    try expectValue(&vm, &host, "(append '(1 2) '() '(3 4))", "(1 2 3 4)");
    try expectValue(&vm, &host, "(list? (cons 1 2))", "#f");
    try expectValue(&vm, &host, "(list? '(1 2))", "#t");
    try expectValue(&vm, &host, "(append '(1 2) 3)", "(1 2 . 3)");
    try std.testing.expectError(error.Type, vm.evaluate("(apply + (cons 1 2))", &host, &out));
    try std.testing.expectError(error.Type, vm.evaluate("(length (cons 1 2))", &host, &out));
    try std.testing.expectError(error.Type, vm.evaluate("(append (cons 1 2) '())", &host, &out));
    try expectValue(&vm, &host, "(+ 1 2)", "3");
}

test "map applies closures across lists and recovers from bounded errors" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    try expectValue(&vm, &host, "(map (lambda (x) (* x x)) '(1 2 3))", "(1 4 9)");
    try expectValue(&vm, &host, "(map + '(1 2 3) '(10 20 30))", "(11 22 33)");
    try expectValue(&vm, &host, "(map (lambda (x) x) '())", "()");
    try expectValue(&vm, &host, "(let ((n 2)) (map (lambda (x) (+ n x)) '(1 2)))", "(3 4)");
    try std.testing.expectError(error.Type, vm.evaluate("(map + '(1) '(2 3))", &host, &out));
    try std.testing.expectError(error.Type, vm.evaluate("(map + (cons 1 2))", &host, &out));
    try std.testing.expectError(error.Arity, vm.evaluate("(map +)", &host, &out));
    try expectValue(&vm, &host, "(+ 20 22)", "42");
}

test "let star initializes sequentially with distinct lexical bindings" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    try expectValue(&vm, &host, "(let* ((x 1) (y (+ x 2))) (+ x y))", "4");
    try expectValue(&vm, &host, "(let* ((x 1) (f (lambda () x)) (x 2)) (f))", "1");
    try expectValue(&vm, &host, "(let* ((x 1) (x (+ x 1))) x)", "2");
    try expectValue(&vm, &host, "(let* () 7)", "7");
    try expectValue(&vm, &host, "(let ((x 4)) (let* ((x 2) (y x)) (+ x y)))", "4");
    try expectValue(&vm, &host, "(define d '(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0))", "()");
    const pressure = "(let* ((x 7) (f (lambda () x)) " ++ repeat("(tmp (begin (append d d d d d d) 1)) ", 9) ++ "(x 8)) (f))";
    try expectValue(&vm, &host, pressure, "7");
    try std.testing.expectError(error.Syntax, vm.evaluate("(let* ((1 2)) 3)", &host, &out));
    try std.testing.expectError(error.Unbound, vm.evaluate("(let ((x 1) (y x)) y)", &host, &out));
    try expectValue(&vm, &host, "(+ 20 22)", "42");
}

test "bounded structural equality and list membership" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    try expectValue(&vm, &host, "(equal? '(a (b c)) '(a (b c)))", "#t");
    try expectValue(&vm, &host, "(equal? '(a (b c)) '(a (b d)))", "#f");
    try expectValue(&vm, &host, "(equal? \"abc\" \"abc\")", "#t");
    try expectValue(&vm, &host, "(equal? 2 2.0)", "#f");
    try expectValue(&vm, &host, "(equal? 0.0 -0.0)", "#f");
    try expectValue(&vm, &host, "(eqv? 100000 100000)", "#t");
    try expectValue(&vm, &host, "(eq? (cons 1 2) (cons 1 2))", "#f");
    try expectValue(&vm, &host, "(memq 'red '((red shoes) red blue))", "(red blue)");
    try expectValue(&vm, &host, "(member '(a b) '((x) (a b) (y)))", "((a b) (y))");
    try expectValue(&vm, &host, "(cadr '((a) (b)))", "(b)");
    try expectValue(&vm, &host, "(begin (define (many n a) (if (= n 0) a (many (- n 1) (cons 1 a)))) (equal? (many 129 '()) (many 129 '())))", "#t");
    try std.testing.expectError(error.Type, vm.evaluate("(memq 'x (cons 'y 1))", &host, &out));
    try expectValue(&vm, &host, "(+ 20 22)", "42");
}

test "structural equality terminates on cyclic pair graphs" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    vm.step_budget = step_limit;
    const a = try vm.pair(makeImmediateInt(1), 0);
    vm.heap[a].b = a;
    const b = try vm.pair(makeImmediateInt(1), 0);
    const c = try vm.pair(makeImmediateInt(1), b);
    vm.heap[b].b = c;
    try std.testing.expect(try vm.equalValues(a, b, 1));
    vm.heap[c].a = makeImmediateInt(2);
    try std.testing.expect(!try vm.equalValues(a, b, 1));
    var x: Ref = 0;
    var y: Ref = 0;
    for (0..400) |_| {
        x = try vm.pair(makeImmediateInt(1), x);
        y = try vm.pair(makeImmediateInt(1), y);
    }
    try std.testing.expect(try vm.equalValues(x, y, 1));
}

test "equality agrees with a visited-pair oracle for cyclic graphs" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    vm.step_budget = step_limit;
    const count = 12;
    var nodes: [count]Ref = undefined;
    for (&nodes) |*node| node.* = try vm.pair(0, 0);
    var seed: u32 = 0x98cdef12;
    for (0..80) |_| {
        for (nodes) |node| {
            seed = seed *% 1664525 +% 1013904223;
            const a: usize = (seed >> 8) % (count + 4);
            seed = seed *% 1664525 +% 1013904223;
            const b: usize = (seed >> 8) % (count + 4);
            vm.heap[node].a = if (a < count) nodes[a] else if (a == count) 0 else makeImmediateInt(@intCast(a - count));
            vm.heap[node].b = if (b < count) nodes[b] else if (b == count) 0 else makeImmediateInt(@intCast(b - count));
        }
        for (nodes) |left| for (nodes) |right| {
            const Pair = struct { a: Ref, b: Ref };
            var todo: [count * count * 2 + 1]Pair = undefined;
            var seen: [count][count]bool = @splat(@splat(false));
            var used: usize = 1;
            todo[0] = .{ .a = left, .b = right };
            var expected = true;
            while (used > 0) {
                used -= 1;
                const item = todo[used];
                if (item.a == item.b) continue;
                if (vm.tagOf(item.a) != .pair or vm.tagOf(item.b) != .pair) {
                    expected = false;
                    break;
                }
                const i = item.a - nodes[0];
                const j = item.b - nodes[0];
                if (seen[i][j]) continue;
                seen[i][j] = true;
                todo[used] = .{ .a = vm.heap[item.a].a, .b = vm.heap[item.b].a };
                todo[used + 1] = .{ .a = vm.heap[item.a].b, .b = vm.heap[item.b].b };
                used += 2;
            }
            vm.steps = 0;
            try std.testing.expectEqual(expected, try vm.equalValues(left, right, 1));
        };
    }
}

test "variadic procedure formals bind positional and rest arguments" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    try expectValue(&vm, &host, "((lambda xs xs) 1 2 3)", "(1 2 3)");
    try expectValue(&vm, &host, "((lambda (x y . rest) (list x y rest)) 1 2 3 4)", "(1 2 (3 4))");
    try expectValue(&vm, &host, "((lambda (x . rest) rest) 1)", "()");
    try expectValue(&vm, &host, "(apply (lambda (x . rest) (cons x rest)) '(1 2 3))", "(1 2 3)");
    try std.testing.expectError(error.Arity, vm.evaluate("((lambda (x y . rest) x) 1)", &host, &out));
    try std.testing.expectError(error.Syntax, vm.evaluate("(lambda (x . x) x)", &host, &out));
    try std.testing.expectError(error.Syntax, vm.evaluate("(lambda (x x . rest) x)", &host, &out));
    try std.testing.expectError(error.Type, vm.evaluate("(lambda (x . 1) x)", &host, &out));
    try expectValue(&vm, &host, "(define saved-rest (let ((x 17)) (lambda xs (+ x (car xs)))))", "()");
    try expectValue(&vm, &host, "(saved-rest 25)", "42");
    try expectValue(&vm, &host, "(define (walk n . xs) (if (= n 0) (car xs) (walk (- n 1) (car xs))))", "()");
    try expectValue(&vm, &host, "(walk 120 42)", "42");
    try expectValue(&vm, &host, "(saved-rest 25)", "42");
    try expectValue(&vm, &host, "(+ 20 22)", "42");
}

test "mutable pairs preserve sharing cycles and collection roots" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    try expectValue(&vm, &host, "(define x (list 'a 'b)) (define y x) (set-car! x 'z) (car y)", "z");
    try expectValue(&vm, &host, "(set-cdr! x (list 7 8)) (cdr y)", "(7 8)");
    try expectValue(&vm, &host, "(define circle (list 'a)) (set-cdr! circle circle) (list? circle)", "#f");
    try expectValue(&vm, &host, "(define other (list 'a)) (set-cdr! other other) (equal? circle other)", "#t");
    try expectValue(&vm, &host, "(set-car! other 'b) (equal? circle other)", "#f");
    try expectValue(&vm, &host, "(let* ((x (list 'a)) (y (list 'a 'a))) (set-cdr! x x) (set-cdr! (cdr y) y) (equal? x y))", "#t");
    try expectValue(&vm, &host, "(let* ((x (list 'a 'b 'c)) (y (cdr x))) (set-cdr! (cdr y) y) (list? x))", "#f");
    try expectValue(&vm, &host, "(list? (cons 1 (cons 2 3)))", "#f");
    try expectValue(&vm, &host, "(list? (list 1 2 3))", "#t");
    try std.testing.expectError(error.Type, vm.evaluate("(set-car! 1 2)", &host, &out));
    try std.testing.expectError(error.Arity, vm.evaluate("(set-cdr! x)", &host, &out));
    try std.testing.expectError(error.TextFull, vm.evaluate("circle", &host, &out));
    try expectValue(&vm, &host, "(eq? (cdr circle) circle)", "#t");
    try expectValue(&vm, &host, "(+ 20 22)", "42");
}

test "standard predicates selectors and ordered for-each" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    try expectValue(&vm, &host, "(list (symbol? 'x) (symbol? 1) (string? \"x\") (boolean? #f) (procedure? +))", "(#t #f #t #t #t)");
    try expectValue(&vm, &host, "(list (caar '((1 2))) (cddr '(1 2 3)) (caddr '(1 2 3)))", "(1 (3) 3)");
    try expectValue(&vm, &host, "(list (caadr '(a (b c))) (cdadr '(a (b c))) (cadddr '(1 2 3 4)))", "(b (c) 4)");
    try expectValue(&vm, &host, "(list (list-ref '(a b c) 1) (list-tail '(a b c) 2))", "(b (c))");
    try expectValue(&vm, &host, "(assoc '(a b) '(((x) . 1) ((a b) . 2)))", "((a b) . 2)");
    try expectValue(&vm, &host, "(begin (define seen '()) (for-each (lambda (x y) (set! seen (append seen (list (+ x y))))) '(1 2) '(10 20)) seen)", "(11 22)");
    try std.testing.expectError(error.Type, vm.evaluate("(for-each + '(1) (cons 2 3))", &host, &out));
    try std.testing.expectError(error.Type, vm.evaluate("(list-ref '(a) 3)", &host, &out));
    try expectValue(&vm, &host, "(+ 20 22)", "42");
}

test "dotted datum syntax validates tails and prints immediate values safely" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    try expectValue(&vm, &host, "'(a b . 3)", "(a b . 3)");
    try expectValue(&vm, &host, "'(1 . (2 . ()))", "(1 2)");
    try expectValue(&vm, &host, "(cdr '(a . 5/2))", "5/2");
    try std.testing.expectError(error.Syntax, vm.evaluate("'(. 1)", &host, &out));
    try std.testing.expectError(error.Syntax, vm.evaluate("'(1 . 2 3)", &host, &out));
    try std.testing.expectError(error.Syntax, vm.evaluate("'(1 .)", &host, &out));
    try expectValue(&vm, &host, "(+ 20 22)", "42");
}

test "larger text and heap bounds remain enforced" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [256]u8 = undefined;
    const long_string = "\"" ++ repeat("a", 100) ++ "\"";
    try expectValue(&vm, &host, long_string, long_string);
    const too_long = "\"" ++ repeat("a", text_bytes + 1) ++ "\"";
    try std.testing.expectError(error.TextFull, vm.evaluate(too_long, &host, &out));
    try expectValue(&vm, &host, "(+ 20 22)", "42");
}

test "inexact decimals interoperate and survive requests" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    try expectValue(&vm, &host, "(+ 2.7 10)", "12.7");
    try expectValue(&vm, &host, "0.001", "0.001");
    try expectValue(&vm, &host, "1e20", "1e20");
    try expectValue(&vm, &host, "1e-20", "1e-20");
    try expectValue(&vm, &host, "(+ 1/2 0.25)", "0.75");
    try expectValue(&vm, &host, "(* .5 2)", "1.0");
    try expectValue(&vm, &host, "(- 1e1 2.5)", "7.5");
    try expectValue(&vm, &host, "(< 1/2 0.75 1)", "#t");
    try expectValue(&vm, &host, "(define pi-inexact 3.125)", "()");
    for (0..8) |_| try expectValue(&vm, &host, "(+ pi-inexact .5)", "3.625");
    try expectValue(&vm, &host, "9406149299205461e-16", "0.9406149299205461");
    try expectValue(&vm, &host, "1e-23", "1e-23");
    try expectValue(&vm, &host, "(/ 1.0 0.0)", "+inf.0");
    try expectValue(&vm, &host, "(+ 1.0 2)", "3.0");
}

test "numeric predicates conversions and nonfinite values" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    try expectValue(&vm, &host, "(number? 'x)", "#f");
    try expectValue(&vm, &host, "(real? +inf.0)", "#t");
    try expectValue(&vm, &host, "(rational? +inf.0)", "#f");
    try expectValue(&vm, &host, "(integer? 2.0)", "#t");
    try expectValue(&vm, &host, "(integer? 1/2)", "#f");
    try expectValue(&vm, &host, "(exact? 1/2)", "#t");
    try expectValue(&vm, &host, "(inexact? 1.0)", "#t");
    try expectValue(&vm, &host, "(inexact 1/2)", "0.5");
    try expectValue(&vm, &host, "(exact 0.5)", "1/2");
    try expectValue(&vm, &host, "(exact -0.0)", "0");
    try expectValue(&vm, &host, "(- 0.0)", "-0.0");
    try expectValue(&vm, &host, "(/ -1.0 0.0)", "-inf.0");
    try expectValue(&vm, &host, "(/ 0.0 0.0)", "+nan.0");
    try expectValue(&vm, &host, "(= +nan.0 +nan.0)", "#f");
    try std.testing.expectError(error.Overflow, vm.evaluate("(exact 0.1)", &host, &out));
    try std.testing.expectError(error.Overflow, vm.evaluate("(exact +inf.0)", &host, &out));
    try std.testing.expectError(error.Type, vm.evaluate("(exact? 'x)", &host, &out));
}

test "numeric literal exactness and radix prefixes" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    try expectValue(&vm, &host, "#e0.1", "1/10");
    try expectValue(&vm, &host, "#e0.0000000005", "1/2000000000");
    try expectValue(&vm, &host, "#i+INF.0", "+inf.0");
    try expectValue(&vm, &host, "#E12.50e-1", "5/4");
    try expectValue(&vm, &host, "#e100000000000000000000.0000000e-20", "1");
    try expectValue(&vm, &host, "#i3/2", "1.5");
    try expectValue(&vm, &host, "#i4000000000", "4000000000.0");
    try expectValue(&vm, &host, "#b101101", "45");
    try expectValue(&vm, &host, "#o-17", "-15");
    try expectValue(&vm, &host, "#x#e-ff", "-255");
    try expectValue(&vm, &host, "#I#XFF/2", "127.5");
    try expectValue(&vm, &host, "#x#i10", "16.0");
    try expectValue(&vm, &host, "#d#e.125", "1/8");
    try std.testing.expectError(error.Syntax, vm.evaluate("#b2", &host, &out));
    try std.testing.expectError(error.Syntax, vm.evaluate("#e#i1", &host, &out));
    try std.testing.expectError(error.Syntax, vm.evaluate("#x#d10", &host, &out));
    try std.testing.expectError(error.DivisionByZero, vm.evaluate("#i1/0", &host, &out));
    try std.testing.expectError(error.Overflow, vm.evaluate("#e1e-30", &host, &out));
}

test "mixed exact and inexact comparisons preserve transitivity" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    try expectValue(&vm, &host, "(= 1/10 0.1)", "#f");
    try expectValue(&vm, &host, "(< 1/10 0.1)", "#t");
    try expectValue(&vm, &host, "(> -1/10 -0.1)", "#t");
    try expectValue(&vm, &host, "(= 1/2 0.5)", "#t");
    try expectValue(&vm, &host, "(= -0.0 0)", "#t");
    try expectValue(&vm, &host, "(< 0 5e-324 1/2147483647)", "#t");
    try expectValue(&vm, &host, "(< -inf.0 -2147483648 0 +inf.0)", "#t");
    try expectValue(&vm, &host, "(= +nan.0 0)", "#f");
    try std.testing.expectError(error.Type, vm.evaluate("(< +nan.0 'x)", &host, &out));
    try std.testing.expectError(error.DivisionByZero, vm.evaluate("(/ 1.0 0)", &host, &out));
    try expectValue(&vm, &host, "(/ 1.0 0.0)", "+inf.0");
}

test "numeric signs parity and unbiased rounding" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    try expectValue(&vm, &host, "(list (floor -7/2) (ceiling -7/2) (truncate -7/2) (round -7/2))", "(-4 -3 -3 -4)");
    try expectValue(&vm, &host, "(list (round 5/2) (round 7/2) (round -5/2) (round -7/2))", "(2 4 -2 -4)");
    try expectValue(&vm, &host, "(list (round 2.5) (round 3.5) (round -2.5) (round -3.5))", "(2.0 4.0 -2.0 -4.0)");
    try expectValue(&vm, &host, "(list (floor -0.2) (ceiling -0.2) (round -0.2))", "(-1.0 -0.0 -0.0)");
    try expectValue(&vm, &host, "(abs -1/3)", "1/3");
    try expectValue(&vm, &host, "(abs -0.0)", "0.0");
    try expectValue(&vm, &host, "(list (zero? -0.0) (positive? +inf.0) (negative? +nan.0))", "(#t #t #f)");
    try expectValue(&vm, &host, "(list (odd? -3) (even? 4.0) (odd? 9007199254740992.0))", "(#t #t #f)");
    try expectValue(&vm, &host, "(list (exact-integer? 4) (exact-integer? 4.0) (exact-integer? 'x))", "(#t #f #f)");
    try expectValue(&vm, &host, "(list (finite? 4) (infinite? -inf.0) (nan? +nan.0))", "(#t #t #t)");
    try std.testing.expectError(error.Type, vm.evaluate("(odd? 1.5)", &host, &out));
    try std.testing.expectError(error.Overflow, vm.evaluate("(abs -2147483648)", &host, &out));
}

test "integer division and gcd respect signs and exactness" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    try expectValue(&vm, &host, "(list (quotient -5 2) (remainder -5 2) (modulo -5 2))", "(-2 -1 1)");
    try expectValue(&vm, &host, "(list (quotient 5 -2) (remainder 5 -2) (modulo 5 -2))", "(-2 1 -1)");
    try expectValue(&vm, &host, "(list (floor-quotient -5 2) (floor-remainder -5 2) (truncate-quotient -5 2) (truncate-remainder -5 2))", "(-3 1 -2 -1)");
    try expectValue(&vm, &host, "(list (quotient -5.0 2) (modulo -5 2.0) (gcd 32 -36) (lcm 32.0 -36))", "(-2.0 1.0 4 288.0)");
    try expectValue(&vm, &host, "(list (gcd) (lcm) (gcd 0 0) (lcm 0 0))", "(0 1 0 0)");
    try expectValue(&vm, &host, "(quotient -2147483648.0 -1)", "2147483648.0");
    try expectValue(&vm, &host, "(modulo -2147483648 -1)", "0");
    try std.testing.expectError(error.Overflow, vm.evaluate("(quotient -2147483648 -1)", &host, &out));
    try std.testing.expectError(error.DivisionByZero, vm.evaluate("(remainder 1 0)", &host, &out));
    try std.testing.expectError(error.Type, vm.evaluate("(gcd 1.5 3)", &host, &out));
    try std.testing.expectError(error.Overflow, vm.evaluate("(lcm 2147483647 2147483646 2147483645)", &host, &out));
    try expectValue(&vm, &host, "(gcd 24 36)", "12");
}

test "opcode immediate decoder retains all eight payload bits" {
    const Wide = enum(u8) { first = 0, low_boundary = 127, high_boundary = 128, last = 255 };
    try std.testing.expectEqual(Wide.first, decodeImmediateOp(Wide, 0x4000));
    try std.testing.expectEqual(Wide.low_boundary, decodeImmediateOp(Wide, 0x407f));
    try std.testing.expectEqual(Wide.high_boundary, decodeImmediateOp(Wide, 0x4080));
    try std.testing.expectEqual(Wide.last, decodeImmediateOp(Wide, 0x40ff));
    try std.testing.expect(isImmediateOp(0x4080));
    try std.testing.expect(!isImmediateOp(0x4100));
}

test "numerator denominator and square preserve exactness" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    try expectValue(&vm, &host, "(list (numerator -6/4) (denominator -6/4))", "(-3 2)");
    try expectValue(&vm, &host, "(list (numerator 1.5) (denominator 1.5))", "(3.0 2.0)");
    try expectValue(&vm, &host, "(list (numerator 0.1) (denominator 0.1))", "(3602879701896397.0 3.602879701896397e16)");
    try expectValue(&vm, &host, "(list (numerator -0.0) (denominator -0.0))", "(0.0 1.0)");
    try expectValue(&vm, &host, "(numerator 5e-324)", "1.0");
    try expectValue(&vm, &host, "(list (square 2/3) (square -0.5))", "(4/9 0.25)");
    try std.testing.expectError(error.Overflow, vm.evaluate("(denominator 5e-324)", &host, &out));
    try std.testing.expectError(error.Type, vm.evaluate("(numerator +inf.0)", &host, &out));
    try std.testing.expectError(error.Arity, vm.evaluate("(square 1 2)", &host, &out));
    try expectValue(&vm, &host, "(square 12)", "144");
}

test "numeric extrema respect exactness infinities and signed zero" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    try expectValue(&vm, &host, "(list (min 3 1/2 -1) (max 3 1/2 -1))", "(-1 3)");
    try expectValue(&vm, &host, "(list (min 3 4.0) (max 3.0 4))", "(3.0 4.0)");
    try expectValue(&vm, &host, "(list (min 0.0 -0.0) (max -0.0 0.0))", "(-0.0 0.0)");
    try expectValue(&vm, &host, "(list (min -0.0 -0.0) (max -0.0 -0.0))", "(-0.0 -0.0)");
    try expectValue(&vm, &host, "(list (min +inf.0 3 -inf.0) (max -inf.0 3 +inf.0))", "(-inf.0 +inf.0)");
    try expectValue(&vm, &host, "(min 4 +nan.0 1)", "+nan.0");
    try expectValue(&vm, &host, "(min 1/10 0.1)", "0.1");
    try expectValue(&vm, &host, "(max 7)", "7");
    try std.testing.expectError(error.Type, vm.evaluate("(min +nan.0 'x)", &host, &out));
    try std.testing.expectError(error.Arity, vm.evaluate("(max)", &host, &out));
    try expectValue(&vm, &host, "(max -2 3)", "3");
}

test "integer powers preserve exactness and bounds" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    try expectValue(&vm, &host, "(list (expt 2 10) (expt 2 -3) (expt -2 5) (expt -2 31))", "(1024 1/8 -32 -2147483648)");
    try expectValue(&vm, &host, "(list (expt 2.0 -3) (expt 2 3.0) (expt 0 0) (expt 0.0 0))", "(0.125 8.0 1 1.0)");
    try expectValue(&vm, &host, "(list (expt 2/3 3) (expt 2/3 -2) (expt -0.0 3))", "(8/27 9/4 -0.0)");
    try expectValue(&vm, &host, "(expt 1 -2147483648)", "1");
    try std.testing.expectError(error.DivisionByZero, vm.evaluate("(expt 0 -1)", &host, &out));
    try std.testing.expectError(error.DivisionByZero, vm.evaluate("(expt 0.0 -1)", &host, &out));
    try std.testing.expectError(error.Overflow, vm.evaluate("(expt 2 31)", &host, &out));
    try std.testing.expectError(error.Type, vm.evaluate("(expt 4 0.5)", &host, &out));
    try expectValue(&vm, &host, "(expt 3 3)", "27");
}

test "tail apply transfers without growing evaluator depth" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    _ = try vm.evaluate("(define (walk n) (if (= n 0) 7 (apply walk (list (- n 1)))))", &host, &out);
    try expectValue(&vm, &host, "(walk 150)", "7");
    _ = try vm.evaluate("(define (nest n) (if (= n 0) 8 (apply apply (list nest (list (- n 1))))))", &host, &out);
    try expectValue(&vm, &host, "(nest 60)", "8");
    _ = try vm.evaluate("(define saved #f) (define (capture n) (if (= n 2) (set! saved (lambda () n)) #f) (if (= n 0) (saved) (apply capture (list (- n 1)))))", &host, &out);
    try expectValue(&vm, &host, "(capture 2)", "2");
    try expectValue(&vm, &host, "(saved)", "2");
    try expectValue(&vm, &host, "(let ((apply (lambda (a b) 99))) (apply 1 2))", "99");
    try expectValue(&vm, &host, "(apply + 1 '(2 3))", "6");
    try expectValue(&vm, &host, "(apply apply (list + '(1 2)))", "3");
    try expectValue(&vm, &host, "(let ((my-apply apply)) (my-apply + '(4 5)))", "9");
    _ = try vm.evaluate("(define (not-tail n) (if (= n 0) 0 (+ 1 (apply not-tail (list (- n 1))))))", &host, &out);
    try expectValue(&vm, &host, "(not-tail 5)", "5");
    try std.testing.expectError(error.Depth, vm.evaluate("(not-tail 40)", &host, &out));
    try std.testing.expectError(error.Type, vm.evaluate("(apply + '(1 . 2))", &host, &out));
    try std.testing.expectError(error.Arity, vm.evaluate("(apply + '(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17))", &host, &out));
    _ = try vm.evaluate("(define stable '(0)) (define (forever n) (apply forever stable))", &host, &out);
    try std.testing.expectError(error.Budget, vm.evaluate("(forever 0)", &host, &out));
    try expectValue(&vm, &host, "(+ 20 22)", "42");
}

test "cond recipient tail calls reuse evaluation frame" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    _ = try vm.evaluate("(define (walk n) (cond ((= n 0) 7) ((- n 1) => walk)))", &host, &out);
    try expectValue(&vm, &host, "(walk 300)", "7");
    _ = try vm.evaluate("(define saved #f) (define (capture n) (if (= n 2) (set! saved (lambda () n)) #f) (cond ((= n 0) (saved)) ((- n 1) => capture)))", &host, &out);
    try expectValue(&vm, &host, "(capture 2)", "2");
    try expectValue(&vm, &host, "(saved)", "2");
    _ = try vm.evaluate("(define (not-tail n) (if (= n 0) 0 (+ 1 (cond ((- n 1) => not-tail)))))", &host, &out);
    try expectValue(&vm, &host, "(not-tail 5)", "5");
    try std.testing.expectError(error.Depth, vm.evaluate("(not-tail 40)", &host, &out));
    try expectValue(&vm, &host, "(cond ((+ 1 3) => (lambda (x) (+ x 1))))", "5");
    try expectValue(&vm, &host, "(cond (4 => square))", "16");
    try expectValue(&vm, &host, "(begin (define seen 0) (list (cond ((begin (set! seen (+ seen 1)) 3) => (lambda (x) (+ x seen)))) seen))", "(4 1)");
    try expectValue(&vm, &host, "(let ((=> #f)) (cond (#t => 'ok)))", "ok");
    _ = try vm.evaluate("(define (forever n) (cond (#t => forever)))", &host, &out);
    try std.testing.expectError(error.Budget, vm.evaluate("(forever 0)", &host, &out));
    try expectValue(&vm, &host, "(+ 20 22)", "42");
}

test "outer tail boundaries reclaim temporary lists and preserve live closures" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    _ = try vm.evaluate("(define (walk n) (if (= n 0) 7 (apply walk (list (- n 1)))))", &host, &out);
    try expectValue(&vm, &host, "(walk 450)", "7");
    _ = try vm.evaluate("(define saved #f) (define (capture n dummy) (if (= n 200) (set! saved (lambda () n)) #f) (if (= n 0) (saved) (apply capture (list (- n 1) dummy))))", &host, &out);
    try expectValue(&vm, &host, "(capture 280 1)", "200");
    try expectValue(&vm, &host, "(saved)", "200");
    _ = try vm.evaluate("(define (keep n text) (if (= n 0) text (apply keep (list (- n 1) text))))", &host, &out);
    try expectValue(&vm, &host, "(keep 220 \"payload\")", "\"payload\"");
    try expectValue(&vm, &host, "(command/register! \"retained\" (lambda () 42))", "#t");
    try expectValue(&vm, &host, "(walk 450)", "7");
    try std.testing.expectEqualStrings("42", try vm.runCommand("retained", &host, &out));
    try expectValue(&vm, &host, "(+ 20 22)", "42");
}

test "outer sequences reclaim temporaries while preserving pending forms" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    const form = "(list 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0) ";
    const source = "(define (remember) \"alive\") (define seen 0) " ++ repeat(form, 10) ++ "(set! seen (+ seen 1)) " ++ repeat(form, 10) ++ "(list seen (remember))";
    try expectValue(&vm, &host, source, "(1 \"alive\")");
    const begin_source = "(begin " ++ repeat(form, 15) ++ "\"end\")";
    try expectValue(&vm, &host, begin_source, "\"end\"");
    try expectValue(&vm, &host, "(remember)", "\"alive\"");
    const append_form = "(append d d d d d d) ";
    const large_begin = "(begin (define d '(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)) " ++ repeat(append_form, 6) ++ "31)";
    try expectValue(&vm, &host, large_begin, "31");
}

test "outer closure body boundaries retain local and captured values" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    const form = "(append d d d d d d) ";
    const captured_source = "(define saved #f) (define d '(41 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)) (define (worker d) (set! saved (lambda () (car d))) " ++ repeat(form, 6) ++ "(saved)) (worker d)";
    try expectValue(&vm, &host, captured_source, "41");
    try expectValue(&vm, &host, "(saved)", "41");
    vm.initInPlace();
    const reused_source = "(define d '(41 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)) (define (worker n d) " ++ repeat(form, 6) ++ "(if (= n 0) (car d) (worker (- n 1) d))) (worker 3 d)";
    try expectValue(&vm, &host, reused_source, "41");
    try expectValue(&vm, &host, "(+ 20 22)", "42");
}

test "outer let and selected cond boundaries retain local and pending values" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    const xform = "(append x x x x x x) ";
    const dform = "(append d d d d d d) ";
    try expectValue(&vm, &host, "(define d '(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0))", "()");
    const let_source = "(let ((x d)) " ++ repeat(xform, 6) ++ "(+ 37 (car x)))";
    try expectValue(&vm, &host, let_source, "37");
    const cond_source = "(cond (#f 'wrong) (#t " ++ repeat(dform, 6) ++ "(+ 39 (car d))))";
    try expectValue(&vm, &host, cond_source, "39");
    try expectValue(&vm, &host, "(define saved #f)", "()");
    const capture_source = "(let ((x d)) (set! saved (lambda () (car x))) " ++ repeat(xform, 6) ++ "(saved))";
    try expectValue(&vm, &host, capture_source, "0");
    try expectValue(&vm, &host, "(saved)", "0");
    try expectValue(&vm, &host, "(cond ((+ 1 3) => (lambda (x) (+ x 1))))", "5");
    try expectValue(&vm, &host, "(+ 20 22)", "42");
}

test "outer logic boundaries retain pending forms and short circuit" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    try expectValue(&vm, &host, "(define d '(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0))", "()");
    const and_source = "(and " ++ repeat("(append d d d d d d) ", 6) ++ "41)";
    try expectValue(&vm, &host, and_source, "41");
    const or_source = "(or " ++ repeat("(begin (append d d d d d d) #f) ", 6) ++ "43)";
    try expectValue(&vm, &host, or_source, "43");
    try expectValue(&vm, &host, "(define flag 0)", "()");
    try expectValue(&vm, &host, "(and #f (set! flag 1))", "#f");
    try expectValue(&vm, &host, "(or 7 (set! flag 2))", "7");
    try expectValue(&vm, &host, "flag", "0");
    try expectValue(&vm, &host, "(and)", "#t");
    try expectValue(&vm, &host, "(or)", "#f");
    try expectValue(&vm, &host, "(and 1 2 3)", "3");
    try expectValue(&vm, &host, "(or #f 'ok)", "ok");
    try expectValue(&vm, &host, "(define saved #f)", "()");
    const local_source = "(let ((x d)) (set! saved (lambda () (car x))) (and " ++ repeat("(append x x x x x x) ", 6) ++ "(saved)))";
    try expectValue(&vm, &host, local_source, "0");
    try expectValue(&vm, &host, "(saved)", "0");
    try expectValue(&vm, &host, "(+ 20 22)", "42");
}

test "outer cond tests and let initializers reclaim while preserving roots" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    try expectValue(&vm, &host, "(define d '(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0))", "()");
    const cond_source = "(cond " ++ repeat("((begin (append d d d d d d) #f) 0) ", 6) ++ "(else 47))";
    try expectValue(&vm, &host, cond_source, "47");
    const let_source = "(let ((a (list 49)) " ++ repeat("(b (begin (append d d d d d d) 1)) ", 1) ++ "(c (begin (append d d d d d d) 1)) (e (begin (append d d d d d d) 1)) (f (begin (append d d d d d d) 1)) (g (begin (append d d d d d d) 1)) (h (begin (append d d d d d d) 1))) (car a))";
    try expectValue(&vm, &host, let_source, "49");
    try expectValue(&vm, &host, "(let ((d 11) (x d)) (car x))", "0");
    try expectValue(&vm, &host, "(define flag 0)", "()");
    try expectValue(&vm, &host, "(cond ((begin (set! flag (+ flag 1)) #f) 0) ((begin (set! flag (+ flag 1)) 5) => (lambda (v) (+ v flag))))", "7");
    try expectValue(&vm, &host, "flag", "2");
    try expectValue(&vm, &host, "(+ 20 22)", "42");
}

test "sliced collection matches original and resumes at every phase" {
    var initial: Runtime = undefined;
    initial.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    _ = try initial.evaluate("(define q (cons \"kept\" '())) (set-cdr! q q) (define (id x) x) (define empty \"\")", &host, &out);
    // Give the compactor holes and distinct live text, plus roots from every
    // evaluator stack; none of these temporary roots are in the global env.
    _ = try initial.text(.string, "discard-first");
    const stack_text = try initial.text(.string, "stack");
    _ = try initial.text(.string, "discard-second");
    const frame_text = try initial.text(.string, "frame-value");
    const alias = try initial.alloc(.string);
    initial.heap[alias].setText(initial.heap[frame_text].textLen(), initial.heap[frame_text].textOffset());
    const code_text = try initial.text(.string, "bytecode-value");
    const expression = try initial.pair(frame_text, stack_text);
    initial.eval_stack[0] = stack_text;
    initial.eval_sp = 1;
    initial.call_stack[0] = .{ .return_ip = 0, .fp = 0, .env = expression };
    initial.call_sp = 1;
    _ = try initial.pushAstRoots(expression, initial.global, frame_text);
    initial.ast_root_frames[0].values[0] = frame_text;
    initial.ast_root_frames[0].values[1] = alias;
    initial.ast_root_frames[0].value_count = 2;
    initial.bytecode[0] = @backingInt(BcOp.const_val);
    std.mem.writeInt(u16, initial.bytecode[1..3], code_text, .little);
    initial.bytecode_len = 3;
    var expected = initial;
    expected.collectTailReference(expression, initial.global);
    for ([_]usize{ 1, 7, 64, 4096 }) |quantum| {
        var actual = initial;
        var cursor = Runtime.SliceCursor{};
        var count: usize = 0;
        var phases: u16 = 0;
        while (true) {
            phases |= @as(u16, 1) << @intCast(@backingInt(cursor.phase));
            const done = actual.collectSlice(&cursor, expression, initial.global, quantum);
            count += 1;
            if (done) break;
            try std.testing.expect(count < 2000000);
        }
        try std.testing.expectEqual(expected.free_cells, actual.free_cells);
        try std.testing.expectEqual(expected.text_used, actual.text_used);
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected.heap), std.mem.asBytes(&actual.heap));
        try std.testing.expectEqualSlices(u8, expected.text_storage[0..expected.text_used], actual.text_storage[0..actual.text_used]);
        try std.testing.expectEqualStrings("stack", actual.string(stack_text));
        try std.testing.expectEqualStrings("frame-value", actual.string(frame_text));
        try std.testing.expectEqualStrings("frame-value", actual.string(alias));
        try std.testing.expectEqualStrings("bytecode-value", actual.string(code_text));
        actual.eval_sp = 0;
        actual.call_sp = 0;
        actual.ast_root_frame_count = 0;
        actual.bytecode_len = 0;
        try std.testing.expectEqualStrings("(\"kept\" #t)", try actual.evaluate("(list (car q) (eq? (cdr q) q))", &host, &out));
        try std.testing.expectEqualStrings("#t", try actual.evaluate("(equal? '((1 2) (3)) '((1 2) (3)))", &host, &out));
        if (quantum == 1) {
            try std.testing.expect(phases & (@as(u16, 1) << @intCast(@backingInt(Runtime.SlicePhase.copy_text))) != 0);
            try std.testing.expect(phases & (@as(u16, 1) << @intCast(@backingInt(Runtime.SlicePhase.remap_text))) != 0);
        }
        std.debug.print("SLICED quantum={d} calls={d} phase_mask={x} cursor_bytes={d}\n", .{ quantum, count, phases, @sizeOf(Runtime.SliceCursor) });
    }
}
test "sliced collector randomized heap graphs match original" {
    var random = std.Random.DefaultPrng.init(0x5a17ed);
    var host = TestHost{};
    var output: [128]u8 = undefined;
    var calls_total: usize = 0;
    var calls_max: usize = 0;
    for (0..12) |fixture| {
        var initial: Runtime = undefined;
        initial.initInPlace();
        _ = try initial.evaluate("(define saved (list \"global\" 42))", &host, &output);
        var graph: Ref = 0;
        var text_buffer: [32]u8 = undefined;
        for (0..80) |i| {
            const label = try std.fmt.bufPrint(&text_buffer, "text-{d}-{d}", .{ fixture, i });
            const text_ref = try initial.text(.string, label);
            if (random.random().boolean()) graph = try initial.pair(text_ref, graph);
            if (random.random().uintLessThan(u8, 5) == 0) _ = try initial.pair(text_ref, 0);
        }
        // A cycle and an extra stack-only root exercise graph sharing and
        // roots that do not occur in the Scheme global environment.
        if (graph != 0) initial.heap[graph].env = graph;
        initial.eval_stack[0] = graph;
        initial.eval_sp = 1;
        const extra = try initial.text(.string, "only-in-frame");
        _ = try initial.pushAstRoots(graph, initial.global, extra);
        var expected = initial;
        expected.collectTailReference(graph, initial.global);
        for ([_]usize{ 37, 256 }) |quantum| {
            var actual = initial;
            var cursor = Runtime.SliceCursor{};
            var calls: usize = 0;
            while (!actual.collectSlice(&cursor, graph, initial.global, quantum)) {
                calls += 1;
                try std.testing.expect(calls < 2000000);
            }
            if (quantum == 256) {
                calls_total += calls + 1;
                calls_max = @max(calls_max, calls + 1);
            }
            try std.testing.expectEqual(expected.free_cells, actual.free_cells);
            try std.testing.expectEqual(expected.text_used, actual.text_used);
            try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected.heap), std.mem.asBytes(&actual.heap));
            try std.testing.expectEqualSlices(u8, expected.text_storage[0..expected.text_used], actual.text_storage[0..actual.text_used]);
            try std.testing.expectEqualStrings("only-in-frame", actual.string(extra));
        }
    }
    std.debug.print("SLICED_RANDOM fixtures=12 quantum=256 calls_total={d} calls_max={d}\n", .{ calls_total, calls_max });
}
test "sliced collector preserves dense live text and bounded exhausted heap recovery" {
    var initial: Runtime = undefined;
    initial.initInPlace();
    var graph: Ref = 0;
    var text_buffer: [64]u8 = undefined;
    for (0..300) |i| {
        const label = try std.fmt.bufPrint(&text_buffer, "v{d:0>3}", .{i});
        const value = try initial.text(.string, label);
        if (i % 3 != 0) graph = try initial.pair(value, graph);
    }
    const empty = try initial.text(.string, "");
    const expression = try initial.pair(empty, graph);
    _ = try initial.pushAstRoots(expression, initial.global, graph);
    while (initial.free_cells > 3) _ = try initial.pair(0, 0);
    var expected = initial;
    expected.collectTailReference(expression, initial.global);
    for ([_]usize{ 1, 64, 256 }) |quantum| {
        var actual = initial;
        var state = Runtime.SliceCursor{};
        while (!actual.collectSlice(&state, expression, initial.global, quantum)) {}
        try std.testing.expectEqual(expected.free_cells, actual.free_cells);
        try std.testing.expectEqual(expected.text_used, actual.text_used);
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected.heap), std.mem.asBytes(&actual.heap));
        try std.testing.expectEqualSlices(u8, expected.text_storage[0..expected.text_used], actual.text_storage[0..actual.text_used]);
        try std.testing.expect(actual.free_cells > 3000);
        try std.testing.expectEqualStrings("", actual.string(empty));
        var host = TestHost{};
        var output: [128]u8 = undefined;
        actual.ast_root_frame_count = 0;
        try std.testing.expectEqualStrings("42", try actual.evaluate("(+ 20 22)", &host, &output));
    }
}

test "collector skips the text index when only empty text survives" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    _ = try vm.text(.string, "dead text");
    const empty = try vm.text(.string, "");
    const root = try vm.pair(empty, 0);
    var expected = vm;
    expected.collectTailReference(root, vm.global);
    vm.collectTail(root, vm.global);
    try std.testing.expectEqual(@as(u16, 0), vm.text_used);
    try std.testing.expectEqual(expected.free_cells, vm.free_cells);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected.heap), std.mem.asBytes(&vm.heap));
    try std.testing.expectEqualStrings("", vm.string(empty));
}

// Resumable evaluator for conservatively admitted expressions.
// Frames are caller-owned bounded storage and remain rooted while suspended.
const ContinuationState = struct {
    // One additional root slot is needed for the current expression/value
    // while control is yielded to the caller.
    const capacity = 95;
    const Frame = struct {
        kind: enum { branch, call, sequence, cond_test, let_init },
        expression: Ref,
        environment: Ref,
        cursor: Ref = 0,
        procedure: Ref = 0,
        values: [16]Ref = @splat(0),
        count: u8 = 0,
        operator_done: bool = false,
    };
    frames: [capacity]Frame = @splat(.{ .kind = .branch, .expression = 0, .environment = 0 }),
    count: usize = 0,
    expression: Ref = 0,
    environment: Ref = 0,
    value: Ref = 0,
    returning: bool = false,
    completed: bool = false,
    published: bool = false,
    collections: usize = 0,
    peak_frames: usize = 0,

    fn push(self: *@This(), frame: Frame) linksection(code_section) Error!void {
        if (self.count == capacity) return error.Depth;
        self.frames[self.count] = frame;
        self.count += 1;
        self.peak_frames = @max(self.peak_frames, self.count);
    }
    // Synchronize at the only locations where this prototype may collect.
    // The expression roots the cursor (a tail of its original argument list).
    fn collect(self: *@This(), vm: *Runtime) linksection(code_section) void {
        std.debug.assert(vm.ast_root_frame_count == 0);
        for (self.frames[0..self.count], 0..) |frame, i| {
            vm.ast_root_frames[i] = .{
                .expression = frame.expression,
                .environment = frame.environment,
                .auxiliary = frame.procedure,
                .values = frame.values,
                .value_count = frame.count,
            };
        }
        vm.ast_root_frame_count = @intCast(self.count);
        vm.collectTail(if (self.returning) self.value else self.expression, self.environment);
        vm.ast_root_frame_count = 0;
        self.collections += 1;
    }
    fn publishRoots(self: *@This(), vm: *Runtime) linksection(code_section) void {
        std.debug.assert(vm.ast_root_frame_count == 0);
        for (self.frames[0..self.count], 0..) |frame, i| {
            vm.ast_root_frames[i] = .{ .expression = frame.expression, .environment = frame.environment, .auxiliary = frame.procedure, .values = frame.values, .value_count = frame.count };
        }
        vm.ast_root_frames[self.count] = .{ .expression = if (self.returning) self.value else self.expression, .environment = self.environment };
        vm.ast_root_frame_count = @intCast(self.count + 1);
        self.published = true;
    }
    fn release(self: *@This(), vm: *Runtime) linksection(code_section) void {
        if (self.published) {
            vm.ast_root_frame_count = 0;
            self.published = false;
        }
    }
    fn sequence(self: *@This(), vm: *Runtime, body: Ref, env: Ref) linksection(code_section) Error!void {
        if (body == 0) {
            self.value = 0;
            self.returning = true;
            return;
        }
        if (vm.tagOf(body) != .pair) return error.Syntax;
        const first = vm.heap[body];
        if (first.b != 0) try self.push(.{ .kind = .sequence, .expression = body, .environment = env, .cursor = first.b });
        self.expression = first.a;
        self.environment = env;
        self.returning = false;
    }
    fn condClause(self: *@This(), vm: *Runtime, clauses: Ref, env: Ref, original: Ref) linksection(code_section) Error!void {
        if (clauses == 0) {
            self.value = 0;
            self.returning = true;
            return;
        }
        if (vm.tagOf(clauses) != .pair) return error.Syntax;
        const clause = vm.heap[clauses].a;
        var fields: [16]Ref = @splat(0);
        const parts = try vm.arguments(clause, &fields);
        if (parts.len == 0) return error.Syntax;
        const is_else = vm.tagOf(parts[0]) == .symbol and std.mem.eql(u8, vm.string(parts[0]), "else") and vm.lookup(env, parts[0]) == 0;
        if (is_else) {
            if (vm.heap[clauses].b != 0 or parts.len == 1) return error.Syntax;
            return self.sequence(vm, vm.heap[clause].b, env);
        }
        if (parts.len >= 2 and vm.tagOf(parts[1]) == .symbol and std.mem.eql(u8, vm.string(parts[1]), "=>") and vm.lookup(env, parts[1]) == 0) return error.CannotCompile;
        try self.push(.{ .kind = .cond_test, .expression = original, .environment = env, .cursor = clauses });
        self.expression = parts[0];
        self.environment = env;
        self.returning = false;
    }
    fn run(self: *@This(), vm: *Runtime, host: anytype, quantum: usize, force_gc: bool) linksection(code_section) Error!bool {
        if (self.completed) return true;
        self.release(vm);
        errdefer self.release(vm);
        for (0..quantum) |_| {
            if (force_gc) self.collect(vm);
            try vm.tick(0);
            if (!self.returning) {
                const r = self.expression;
                if (isImmediate(r)) {
                    self.value = r;
                    self.returning = true;
                    continue;
                }
                const c = vm.heap[r];
                if (c.tag == .symbol) {
                    const found = vm.lookup(self.environment, r);
                    if (found != 0) self.value = vm.heap[found].b else {
                        const op = Runtime.opcode(vm.string(r)) orelse return error.Unbound;
                        if (@backingInt(op) < @backingInt(Op.add)) return error.Unbound;
                        self.value = makeImmediateOp(op);
                    }
                    self.returning = true;
                    continue;
                }
                if (c.tag != .pair) {
                    self.value = r;
                    self.returning = true;
                    continue;
                }
                const special = if (vm.tagOf(c.a) == .symbol) Runtime.opcode(vm.string(c.a)) else null;
                if (special == .quote) {
                    var a: [16]Ref = @splat(0);
                    const args = try vm.arguments(c.b, &a);
                    if (args.len != 1) return error.Arity;
                    self.value = args[0];
                    self.returning = true;
                    continue;
                }
                if (special == .if_) {
                    var a: [16]Ref = @splat(0);
                    const args = try vm.arguments(c.b, &a);
                    if (args.len != 3) return error.Arity;
                    try self.push(.{ .kind = .branch, .expression = r, .environment = self.environment });
                    self.expression = args[0];
                    continue;
                }
                if (special == .begin) {
                    try self.sequence(vm, c.b, self.environment);
                    continue;
                }
                if (special == .cond) {
                    try self.condClause(vm, c.b, self.environment, r);
                    continue;
                }
                if (special == .let) {
                    var a: [16]Ref = @splat(0);
                    const args = try vm.arguments(c.b, &a);
                    if (args.len < 2) return error.Arity;
                    const local = try vm.pair(0, self.environment);
                    if (args[0] == 0) {
                        try self.sequence(vm, vm.heap[c.b].b, local);
                        continue;
                    }
                    if (vm.tagOf(args[0]) != .pair) return error.Syntax;
                    const entry = vm.heap[args[0]].a;
                    var bindings: [2]Ref = @splat(0);
                    const pair = try vm.arguments(entry, &bindings);
                    if (pair.len != 2 or vm.tagOf(pair[0]) != .symbol) return error.Syntax;
                    try self.push(.{ .kind = .let_init, .expression = r, .environment = self.environment, .cursor = args[0], .procedure = local });
                    self.expression = pair[1];
                    continue;
                }
                // Reject unsupported special forms before any part executes.
                if (special) |op| if (@backingInt(op) < @backingInt(Op.add)) return error.CannotCompile;
                try self.push(.{ .kind = .call, .expression = r, .environment = self.environment, .cursor = c.b });
                self.expression = c.a;
                continue;
            }
            if (self.count == 0) {
                self.completed = true;
                return true;
            }
            const frame = &self.frames[self.count - 1];
            if (frame.kind == .branch) {
                var a: [16]Ref = @splat(0);
                const args = try vm.arguments(vm.heap[frame.expression].b, &a);
                self.expression = args[if (self.value == vm.no) 2 else 1];
                self.environment = frame.environment;
                self.count -= 1;
                self.returning = false;
                continue;
            }
            if (frame.kind == .sequence) {
                if (vm.tagOf(frame.cursor) != .pair) return error.Syntax;
                const next = vm.heap[frame.cursor];
                self.expression = next.a;
                self.environment = frame.environment;
                if (next.b == 0) self.count -= 1 else frame.cursor = next.b;
                self.returning = false;
                continue;
            }
            if (frame.kind == .cond_test) {
                const clauses = frame.cursor;
                const clause = vm.heap[clauses].a;
                const env = frame.environment;
                const original = frame.expression;
                self.count -= 1;
                if (self.value == vm.no) {
                    try self.condClause(vm, vm.heap[clauses].b, env, original);
                } else if (vm.heap[clause].b != 0) {
                    try self.sequence(vm, vm.heap[clause].b, env);
                }
                continue;
            }
            if (frame.kind == .let_init) {
                const entry = vm.heap[frame.cursor].a;
                var fields: [2]Ref = @splat(0);
                const binding = try vm.arguments(entry, &fields);
                if (binding.len != 2 or vm.tagOf(binding[0]) != .symbol) return error.Syntax;
                var old = vm.heap[frame.procedure].a;
                while (old != 0) : (old = vm.heap[old].b) if (vm.heap[vm.heap[old].a].a == binding[0]) return error.Syntax;
                try vm.define(frame.procedure, binding[0], self.value);
                frame.cursor = vm.heap[frame.cursor].b;
                if (frame.cursor != 0) {
                    if (vm.tagOf(frame.cursor) != .pair) return error.Syntax;
                    var next_fields: [2]Ref = @splat(0);
                    const next = try vm.arguments(vm.heap[frame.cursor].a, &next_fields);
                    if (next.len != 2 or vm.tagOf(next[0]) != .symbol) return error.Syntax;
                    self.expression = next[1];
                    self.environment = frame.environment;
                    self.returning = false;
                } else {
                    const body = vm.heap[vm.heap[frame.expression].b].b;
                    const local = frame.procedure;
                    self.count -= 1;
                    try self.sequence(vm, body, local);
                }
                continue;
            }
            if (!frame.operator_done) {
                frame.procedure = self.value;
                frame.operator_done = true;
            } else {
                if (frame.count == frame.values.len) return error.Arity;
                frame.values[frame.count] = self.value;
                frame.count += 1;
            }
            if (frame.cursor != 0) {
                if (vm.tagOf(frame.cursor) != .pair) return error.Type;
                const next = vm.heap[frame.cursor];
                frame.cursor = next.b;
                self.expression = next.a;
                self.environment = frame.environment;
                self.returning = false;
                continue;
            }
            const procedure = frame.procedure;
            if (vm.tagOf(procedure) == .closure) {
                const closure = vm.heap[procedure];
                if (closure.flagged()) return error.CannotCompile;
                const params = try vm.formals(closure.a);
                if (frame.count < params.count or (params.rest == 0 and frame.count != params.count)) return error.Arity;
                if (vm.tagOf(closure.b) != .pair) return error.Syntax;
                const local = try vm.pair(0, closure.env);
                try vm.bindFormals(local, params, frame.values[0..frame.count]);
                self.count -= 1;
                try self.sequence(vm, closure.b, local);
                continue;
            }
            if (!isImmediateOp(procedure)) return error.Type;
            switch (toImmediateOp(procedure)) {
                .add, .sub, .mul, .equal, .less, .greater, .less_equal, .greater_equal, .quotient_proc, .remainder_proc, .modulo_proc, .evenq, .cons, .car, .cdr, .nullq, .pairq, .not => {},
                else => return error.CannotCompile,
            }
            self.value = try vm.apply(procedure, frame.values[0..frame.count], 0, host);
            self.environment = frame.environment;
            self.count -= 1;
        }
        self.publishRoots(vm);
        return false;
    }
};

test "continuation prototype yields, roots frames, rejects unsupported and unwinds" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    _ = try vm.evaluate("(define (count n) (if (= n 0) 0 (+ 1 (count (- n 1)))))", &host, &out);
    try std.testing.expectError(error.Depth, vm.evaluate("(count 60)", &host, &out));
    try vm.startBudget(20000);
    var pos: usize = 0;
    const expression = try vm.read("(count 60)", &pos, 0);
    var state = ContinuationState{ .expression = expression, .environment = vm.global };
    var yields: usize = 0;
    while (!try state.run(&vm, &host, 7, true)) {
        yields += 1;
        vm.collect();
    }
    try std.testing.expectEqualStrings("60", try vm.format(state.value, &out));
    try std.testing.expect(yields > 1 and state.collections > 1 and state.peak_frames > depth_limit);
    try std.testing.expectEqual(@as(u8, 0), vm.ast_root_frame_count);
    std.debug.print("CONTINUATION size={d} frame={d} peak={d} yields={d} collections={d}\n", .{ @sizeOf(ContinuationState), @sizeOf(ContinuationState.Frame), state.peak_frames, yields, state.collections });
    vm.running = false;
    try vm.startBudget(20000);
    pos = 0;
    const bad = try vm.read("(and #t #t)", &pos, 0);
    var unsupported = ContinuationState{ .expression = bad, .environment = vm.global };
    try std.testing.expectError(error.CannotCompile, unsupported.run(&vm, &host, 100, true));
    try std.testing.expectEqual(@as(u8, 0), vm.ast_root_frame_count);
    vm.running = false;
    try std.testing.expectEqualStrings("42", try vm.evaluate("(+ 20 22)", &host, &out));

    // SICP 1.11 recursive process, supported subset. Compare the normal
    // evaluator before testing yielded and forcibly collected evaluation.
    _ = try vm.evaluate("(define (f n) (if (< n 3) n (+ (f (- n 1)) (* 2 (f (- n 2))) (* 3 (f (- n 3))))))", &host, &out);
    const samples = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "(f 4)", .expected = "11" },
        .{ .source = "(f 5)", .expected = "25" },
        .{ .source = "(f 6)", .expected = "59" },
    };
    for (samples) |sample| {
        try std.testing.expectEqualStrings(sample.expected, try vm.evaluate(sample.source, &host, &out));
        try vm.startBudget(20000);
        pos = 0;
        const sample_expr = try vm.read(sample.source, &pos, 0);
        var sample_state = ContinuationState{ .expression = sample_expr, .environment = vm.global };
        while (!try sample_state.run(&vm, &host, 11, true)) vm.collect();
        try std.testing.expectEqualStrings(sample.expected, try vm.format(sample_state.value, &out));
        vm.running = false;
    }

    // A compound result must survive while the remaining operands execute.
    _ = try vm.evaluate("(define (wrap x) (cons x x))", &host, &out);
    try vm.startBudget(20000);
    pos = 0;
    const shared = try vm.read("(cons (wrap (cons 1 2)) (wrap (cons 3 4)))", &pos, 0);
    var shared_state = ContinuationState{ .expression = shared, .environment = vm.global };
    while (!try shared_state.run(&vm, &host, 1, true)) vm.collect();
    try std.testing.expectEqualStrings("(((1 . 2) 1 . 2) (3 . 4) 3 . 4)", try vm.format(shared_state.value, &out));
    vm.running = false;

    try vm.startBudget(20000);
    pos = 0;
    const deep = try vm.read("(count 120)", &pos, 0);
    var exhausted = ContinuationState{ .expression = deep, .environment = vm.global };
    try std.testing.expectError(error.Depth, exhausted.run(&vm, &host, 20000, true));
    try std.testing.expectEqual(@as(usize, ContinuationState.capacity), exhausted.peak_frames);
    try std.testing.expectEqual(@as(u8, 0), vm.ast_root_frame_count);
    vm.running = false;
    try std.testing.expectEqualStrings("42", try vm.evaluate("(+ 20 22)", &host, &out));

    // Cancellation here means discarding a yielded host-only state. No UI or
    // asynchronous cancellation mechanism is implemented by this prototype.
    try vm.startBudget(20000);
    pos = 0;
    const cancelled = try vm.read("(count 60)", &pos, 0);
    var cancelled_state = ContinuationState{ .expression = cancelled, .environment = vm.global };
    try std.testing.expect(!try cancelled_state.run(&vm, &host, 40, true));
    try std.testing.expect(cancelled_state.count > 0);
    try std.testing.expect(vm.ast_root_frame_count > 0);
    cancelled_state.release(&vm);
    try std.testing.expectEqual(@as(u8, 0), vm.ast_root_frame_count);
    vm.running = false;
    try std.testing.expectEqualStrings("42", try vm.evaluate("(+ 20 22)", &host, &out));

    try vm.startBudget(10);
    pos = 0;
    const bounded = try vm.read("(count 60)", &pos, 0);
    var bounded_state = ContinuationState{ .expression = bounded, .environment = vm.global };
    try std.testing.expectError(error.Budget, bounded_state.run(&vm, &host, 100, true));
    try std.testing.expectEqual(@as(u8, 0), vm.ast_root_frame_count);
    vm.running = false;
    try std.testing.expectEqualStrings("42", try vm.evaluate("(+ 20 22)", &host, &out));
}

test "continuation prototype cond let and SICP 1.27" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    const setup = "(define (expmod base exp m) (cond ((= exp 0) 1) ((even? exp) (let ((x (expmod base (quotient exp 2) m))) (remainder (* x x) m))) (else (remainder (* base (expmod base (- exp 1) m)) m)))) (define (fermat? a n) (= (expmod a n n) a))";
    _ = try vm.evaluate(setup, &host, &out);
    const samples = [_][]const u8{
        "(fermat? 2 2465)", "(fermat? 3 2465)", "(fermat? 10 2465)",
        "(fermat? 2 2821)", "(fermat? 3 2821)", "(fermat? 10 2821)",
        "(fermat? 2 6601)", "(fermat? 3 6601)", "(fermat? 10 6601)",
    };
    var total_gc: usize = 0;
    var max_frames: usize = 0;
    for (samples) |source| {
        try std.testing.expectError(error.Depth, vm.evaluate(source, &host, &out));
        try vm.startBudget(step_limit);
        var pos: usize = 0;
        const expr = try vm.read(source, &pos, 0);
        var state = ContinuationState{ .expression = expr, .environment = vm.global };
        while (!try state.run(&vm, &host, 13, true)) vm.collect();
        try std.testing.expectEqualStrings("#t", try vm.format(state.value, &out));
        total_gc += state.collections;
        max_frames = @max(max_frames, state.peak_frames);
        vm.running = false;
    }
    const forms = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "(let ((x 10)) (let ((x 1) (y x)) (cond ((= x 2) 1) (else (+ x y)))))", .expected = "11" },
        .{ .source = "(cond ((+ 1 2)) (else 9))", .expected = "3" },
        .{ .source = "(begin (+ 1 2) (+ 3 4))", .expected = "7" },
        .{ .source = "(let () 1 2 3)", .expected = "3" },
    };
    for (forms) |form| {
        try std.testing.expectEqualStrings(form.expected, try vm.evaluate(form.source, &host, &out));
        try vm.startBudget(step_limit);
        var pos: usize = 0;
        const expr = try vm.read(form.source, &pos, 0);
        var state = ContinuationState{ .expression = expr, .environment = vm.global };
        while (!try state.run(&vm, &host, 1, true)) vm.collect();
        try std.testing.expectEqualStrings(form.expected, try vm.format(state.value, &out));
        vm.running = false;
    }
    std.debug.print("SICP_1_27 matched={d} nested_gc={d} peak_frames={d}\n", .{ samples.len, total_gc, max_frames });
}

test "continuation prototype let root under reuse" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    try vm.startBudget(step_limit);
    var pos: usize = 0;
    const expr = try vm.read("(let ((x (cons 1 2))) (car x))", &pos, 0);
    var state = ContinuationState{ .expression = expr, .environment = vm.global };
    while (true) {
        try std.testing.expect(!try state.run(&vm, &host, 1, true));
        if (state.count != 0 and state.frames[state.count - 1].kind == .let_init) break;
    }
    const local = state.frames[state.count - 1].procedure;
    vm.collect();
    // Simulate the normal allocator's wrap to this index while suspended.
    vm.next = local;
    const allocated = try vm.pair(0, 0);
    try std.testing.expect(allocated != local);
    while (!try state.run(&vm, &host, 1, true)) vm.collect();
    try std.testing.expectEqualStrings("1", try vm.format(state.value, &out));
    vm.running = false;
}

// Conservative, read-only host admission experiment. It proves a restricted
// closed call graph; it is not wired into Runtime.evaluate.
const ContinuationAdmission = struct {
    const max_symbols = 64;
    locals: [max_symbols]Ref = @splat(0),
    local_count: usize = 0,
    visited: [max_symbols]Ref = @splat(0),
    visited_count: usize = 0,
    nodes: usize = 0,

    fn isLocal(self: *const @This(), symbol: Ref) linksection(code_section) bool {
        for (self.locals[0..self.local_count]) |name| if (name == symbol) return true;
        return false;
    }
    fn addLocal(self: *@This(), symbol: Ref) linksection(code_section) bool {
        if (self.local_count == self.locals.len) return false;
        self.locals[self.local_count] = symbol;
        self.local_count += 1;
        return true;
    }
    fn closure(self: *@This(), vm: *const Runtime, procedure: Ref, depth: usize) linksection(code_section) bool {
        for (self.visited[0..self.visited_count]) |old| if (old == procedure) return true;
        if (self.visited_count == self.visited.len or depth >= 32) return false;
        const c = vm.heap[procedure];
        // Captured locals require lexical binding provenance, not global lookup.
        if (c.flagged() or c.env != vm.global) return false;
        const formals = vm.formals(c.a) catch return false;
        if (formals.rest != 0) return false;
        self.visited[self.visited_count] = procedure;
        self.visited_count += 1;
        const saved = self.local_count;
        const saved_locals = self.locals;
        self.local_count = 0;
        defer {
            self.locals = saved_locals;
            self.local_count = saved;
        }
        for (formals.fixed[0..formals.count]) |name| if (!self.addLocal(name)) return false;
        return self.sequence(vm, c.b, depth + 1);
    }
    fn sequence(self: *@This(), vm: *const Runtime, list: Ref, depth: usize) linksection(code_section) bool {
        var items: [16]Ref = @splat(0);
        const expressions = vm.arguments(list, &items) catch return false;
        for (expressions) |expr| if (!self.expression(vm, expr, depth + 1)) return false;
        return true;
    }
    fn expression(self: *@This(), vm: *const Runtime, expr: Ref, depth: usize) linksection(code_section) bool {
        if (depth >= 32 or self.nodes >= 4096) return false;
        self.nodes += 1;
        if (isImmediate(expr)) return !isImmediateOp(expr);
        switch (vm.tagOf(expr)) {
            .nil, .integer, .boolean, .string, .rational, .inexact => return true,
            .symbol => return self.isLocal(expr) or vm.lookup(vm.global, expr) != 0,
            .pair => {},
            else => return false,
        }
        const pair = vm.heap[expr];
        if (vm.tagOf(pair.a) != .symbol) return false;
        var args_storage: [16]Ref = @splat(0);
        const args = vm.arguments(pair.b, &args_storage) catch return false;
        const op = Runtime.opcode(vm.string(pair.a));
        if (op) |special| switch (special) {
            .quote => return args.len == 1,
            .if_ => return args.len == 3 and self.expression(vm, args[0], depth + 1) and self.expression(vm, args[1], depth + 1) and self.expression(vm, args[2], depth + 1),
            .begin => return self.sequence(vm, pair.b, depth + 1),
            .cond => {
                for (args, 0..) |clause, i| {
                    var fields: [16]Ref = @splat(0);
                    const parts = vm.arguments(clause, &fields) catch return false;
                    if (parts.len == 0) return false;
                    const is_else = vm.tagOf(parts[0]) == .symbol and std.mem.eql(u8, vm.string(parts[0]), "else") and !self.isLocal(parts[0]) and vm.lookup(vm.global, parts[0]) == 0;
                    if (is_else) {
                        if (i + 1 != args.len or parts.len == 1) return false;
                    } else if (!self.expression(vm, parts[0], depth + 1)) return false;
                    if (parts.len > 1 and vm.tagOf(parts[1]) == .symbol and std.mem.eql(u8, vm.string(parts[1]), "=>") and !self.isLocal(parts[1]) and vm.lookup(vm.global, parts[1]) == 0) return false;
                    for (parts[1..]) |body| if (!self.expression(vm, body, depth + 1)) return false;
                }
                return true;
            },
            .let => {
                if (args.len < 2) return false;
                var bindings_storage: [16]Ref = @splat(0);
                const bindings = vm.arguments(args[0], &bindings_storage) catch return false;
                const saved = self.local_count;
                defer self.local_count = saved;
                var names: [16]Ref = @splat(0);
                for (bindings, 0..) |entry, i| {
                    var b: [2]Ref = @splat(0);
                    const fields = vm.arguments(entry, &b) catch return false;
                    if (fields.len != 2 or vm.tagOf(fields[0]) != .symbol) return false;
                    for (names[0..i]) |name| if (name == fields[0]) return false;
                    names[i] = fields[0];
                    // Parallel let initializers see the outer scope only.
                    if (!self.expression(vm, fields[1], depth + 1)) return false;
                }
                for (names[0..bindings.len]) |name| if (!self.addLocal(name)) return false;
                for (args[1..]) |body| if (!self.expression(vm, body, depth + 1)) return false;
                return true;
            },
            else => if (@backingInt(special) < @backingInt(Op.add)) return false,
        };
        if (self.isLocal(pair.a)) return false; // Dynamic procedure parameter.
        const binding = vm.lookup(vm.global, pair.a);
        if (binding != 0) {
            const procedure = vm.heap[binding].b;
            if (vm.tagOf(procedure) != .closure or !self.closure(vm, procedure, depth + 1)) return false;
        } else {
            const builtin = op orelse return false;
            switch (builtin) {
                .add, .sub, .mul, .equal, .less, .greater, .less_equal, .greater_equal, .quotient_proc, .remainder_proc, .modulo_proc, .evenq, .cons, .car, .cdr, .nullq, .pairq, .not => {},
                else => return false,
            }
        }
        for (args) |arg| if (!self.expression(vm, arg, depth + 1)) return false;
        return true;
    }
};

test "continuation prototype conservative admission and fallback" {
    const Harness = struct {
        fn admit(vm: *Runtime, source: []const u8) linksection(code_section) Error!bool {
            try vm.start();
            defer vm.running = false;
            var pos: usize = 0;
            const expr = try vm.read(source, &pos, 0);
            Runtime.space(source, &pos);
            if (pos != source.len) return false;
            var admission = ContinuationAdmission{};
            return admission.expression(vm, expr, 0);
        }
        fn route(vm: *Runtime, host: *TestHost, source: []const u8, out: []u8, used_continuation: *bool) linksection(code_section) Error![]const u8 {
            try vm.start();
            var pos: usize = 0;
            const expr = vm.read(source, &pos, 0) catch |err| {
                vm.running = false;
                return err;
            };
            Runtime.space(source, &pos);
            var admission = ContinuationAdmission{};
            used_continuation.* = pos == source.len and admission.expression(vm, expr, 0);
            if (!used_continuation.*) {
                vm.running = false;
                return vm.evaluate(source, host, out);
            }
            defer vm.running = false;
            var state = ContinuationState{ .expression = expr, .environment = vm.global };
            while (!try state.run(vm, host, 13, true)) vm.collect();
            return vm.format(state.value, out);
        }
    };
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    _ = try vm.evaluate("(define (expmod base exp m) (cond ((= exp 0) 1) ((even? exp) (let ((x (expmod base (quotient exp 2) m))) (remainder (* x x) m))) (else (remainder (* base (expmod base (- exp 1) m)) m)))) (define (fermat? a n) (= (expmod a n n) a)) (define marker 0)", &host, &out);
    try std.testing.expect(try Harness.admit(&vm, "(fermat? 2 2465)"));
    var routed: bool = false;
    try std.testing.expectEqualStrings("#t", try Harness.route(&vm, &host, "(fermat? 2 2465)", &out, &routed));
    try std.testing.expect(routed);
    try std.testing.expect(try Harness.admit(&vm, "(let ((x 10)) (let ((x 1) (y x)) (+ x y)))"));
    try std.testing.expect(try Harness.admit(&vm, "(let ((x 4)) (cons (fermat? 2 2465) x))"));
    try std.testing.expect(!try Harness.admit(&vm, "(begin (set! marker (+ marker 1)) (+ marker 2))"));
    try std.testing.expectEqualStrings("0", try vm.evaluate("marker", &host, &out));
    // The caller chooses the old evaluator before doing any continuation work.
    try std.testing.expectEqualStrings("3", try Harness.route(&vm, &host, "(begin (set! marker (+ marker 1)) (+ marker 2))", &out, &routed));
    try std.testing.expect(!routed);
    try std.testing.expectEqualStrings("1", try vm.evaluate("marker", &host, &out));
    _ = try vm.evaluate("(define (danger x) (set! marker 99) x)", &host, &out);
    try std.testing.expect(!try Harness.admit(&vm, "(danger 3)"));
    try std.testing.expect(!try Harness.admit(&vm, "(system/log)"));
    try std.testing.expect(!try Harness.admit(&vm, "(let ((+ (lambda (x y) 7))) (+ 1 2))"));
    _ = try vm.evaluate("(define (bad-shadow +) (+ 1 2))", &host, &out);
    try std.testing.expect(!try Harness.admit(&vm, "(bad-shadow 1)"));
    try std.testing.expect(!try Harness.admit(&vm, "(cond ((+ 1 2) => (lambda (x) x)))"));
    try std.testing.expect(!try Harness.admit(&vm, "(unknown 1)"));
    _ = try vm.evaluate("(define (+ a b) (set! marker 33) a)", &host, &out);
    try std.testing.expect(!try Harness.admit(&vm, "(+ 1 2)"));
    try std.testing.expectEqualStrings("1", try vm.evaluate("marker", &host, &out));
    std.debug.print("ADMISSION pure_recursion=accepted mutation_callback_shadowing=rejected fallback_once=ok\n", .{});
}

// Caller-owned prototype slot. Its owner must keep both slot and runtime in a
// stable location and prevent direct access to Runtime's low-level VM methods.
pub const ContinuationLease = struct {
    state: ContinuationState = .{},
    owner: ?*Runtime = null,

    pub fn begin(self: *@This(), vm: *Runtime, source: []const u8) linksection(code_section) Error!bool {
        if (self.owner != null) return error.Busy;
        try vm.start();
        errdefer vm.running = false;
        if (source.len > 4096 or std.mem.indexOfScalar(u8, source, 0) != null or !storage.validUtf8(source)) return error.Syntax;
        var pos: usize = 0;
        Runtime.space(source, &pos);
        if (pos == source.len) {
            vm.running = false;
            return false;
        }
        const expr = try vm.read(source, &pos, 0);
        Runtime.space(source, &pos);
        var admission = ContinuationAdmission{};
        if (pos != source.len or !admission.expression(vm, expr, 0)) {
            vm.running = false;
            return false;
        }
        self.state = .{ .expression = expr, .environment = vm.global };
        self.owner = vm;
        return true;
    }
    pub fn cancel(self: *@This()) linksection(code_section) void {
        if (self.owner) |vm| {
            self.state.release(vm);
            vm.running = false;
            self.owner = null;
        }
    }
    pub fn poll(self: *@This(), host: anytype, quantum: usize, output: []u8) linksection(code_section) Error!?[]const u8 {
        const vm = self.owner orelse return error.Syntax;
        if (quantum == 0) {
            self.cancel();
            return error.Syntax;
        }
        const done = self.state.run(vm, host, quantum, false) catch |err| {
            self.cancel();
            return err;
        };
        if (!done) return null;
        const result = vm.format(self.state.value, output) catch |err| {
            self.cancel();
            return err;
        };
        self.cancel();
        return result;
    }
};

test "continuation prototype leased lifecycle and cancellation" {
    var vm: Runtime = undefined;
    vm.initInPlace();
    var host = TestHost{};
    var out: [128]u8 = undefined;
    _ = try vm.evaluate("(define marker 0) (define (count n) (if (= n 0) 0 (+ 1 (count (- n 1)))))", &host, &out);
    var slot = ContinuationLease{};
    var input = "(count 60)".*;
    try std.testing.expect(try slot.begin(&vm, &input));
    try std.testing.expect((try slot.poll(&host, 7, &out)) == null);
    try std.testing.expectError(error.Busy, vm.evaluate("(set! marker 99)", &host, &out));
    try std.testing.expectError(error.Busy, vm.runCommand("missing", &host, &out));
    try std.testing.expectError(error.Busy, slot.begin(&vm, "42"));
    @memset(&input, 'x'); // Tokens, including pending expression, were copied.
    var yields: usize = 1;
    while (true) {
        vm.collect();
        if (try slot.poll(&host, 7, &out)) |result| {
            try std.testing.expectEqualStrings("60", result);
            break;
        }
        yields += 1;
    }
    try std.testing.expect(yields > 1 and !vm.running and slot.owner == null);
    try std.testing.expectEqual(@as(u8, 0), vm.ast_root_frame_count);
    try std.testing.expectEqualStrings("0", try vm.evaluate("marker", &host, &out));

    try std.testing.expect(try slot.begin(&vm, "(count 60)"));
    try std.testing.expect((try slot.poll(&host, 7, &out)) == null);
    try std.testing.expect(vm.ast_root_frame_count != 0);
    slot.cancel();
    slot.cancel();
    try std.testing.expect(!vm.running and slot.owner == null);
    try std.testing.expectEqual(@as(u8, 0), vm.ast_root_frame_count);
    try std.testing.expectEqualStrings("42", try vm.evaluate("42", &host, &out));

    try std.testing.expect(!try slot.begin(&vm, "(begin (set! marker 1) marker)"));
    try std.testing.expect(!vm.running and slot.owner == null);
    try std.testing.expectEqualStrings("0", try vm.evaluate("marker", &host, &out));
    try std.testing.expectEqualStrings("1", try vm.evaluate("(begin (set! marker 1) marker)", &host, &out));
    try std.testing.expectError(error.Syntax, slot.begin(&vm, "("));
    try std.testing.expect(!vm.running and slot.owner == null);
    try std.testing.expect(try slot.begin(&vm, "(count 120)"));
    try std.testing.expectError(error.Depth, slot.poll(&host, 8192, &out));
    try std.testing.expect(!vm.running and slot.owner == null);
    try std.testing.expect(try slot.begin(&vm, "42"));
    var tiny: [0]u8 = .{};
    try std.testing.expectError(error.TextFull, slot.poll(&host, 8192, &tiny));
    try std.testing.expect(!vm.running and slot.owner == null);
    try std.testing.expectEqualStrings("42", try vm.evaluate("42", &host, &out));
    std.debug.print("LEASE bytes={d} yields={d} cancellation=ok errors=ok reentry=busy\n", .{ @sizeOf(ContinuationLease), yields });
}

// Retain the VM and published roots until sliced collection completes,
// including after cancellation has been requested.
pub const SlicedContinuation = struct {
    lease: ContinuationLease = .{},
    cursor: ?Runtime.SliceCursor = null,
    reclaim_at: u16 = 512,
    collections: usize = 0,
    slices: usize = 0,
    cancel_pending: bool = false,

    pub fn begin(self: *@This(), vm: *Runtime, source: []const u8) linksection(code_section) Error!bool {
        if (self.lease.owner != null) return error.Busy;
        self.cursor = null;
        self.reclaim_at = 512;
        self.collections = 0;
        self.slices = 0;
        self.cancel_pending = false;
        return self.lease.begin(vm, source);
    }
    pub fn cancel(self: *@This()) linksection(code_section) void {
        if (self.cursor != null) {
            self.cancel_pending = true;
        } else {
            self.lease.cancel();
        }
    }
    pub fn poll(self: *@This(), host: anytype, quantum: usize, budget: usize, out: []u8) linksection(code_section) Error!?[]const u8 {
        const vm = self.lease.owner orelse return error.Syntax;
        if (quantum == 0 or budget == 0) return error.Syntax;
        if (self.cursor) |*cursor| {
            self.slices += 1;
            if (vm.collectSlice(cursor, 0, 0, budget)) {
                self.cursor = null;
                self.collections += 1;
                self.reclaim_at = if (vm.free_cells > 512) 512 else vm.free_cells / 2;
                if (self.cancel_pending) {
                    self.lease.cancel();
                    self.cancel_pending = false;
                }
            }
            return null;
        }
        const done = self.lease.state.run(vm, host, quantum, false) catch |err| {
            self.lease.cancel();
            return err;
        };
        if (!done) {
            if (vm.free_cells <= self.reclaim_at) self.cursor = .{};
            return null;
        }
        const result = vm.format(self.lease.state.value, out) catch |err| {
            self.lease.cancel();
            return err;
        };
        self.lease.cancel();
        return result;
    }
};

fn slicedSetup(vm: *Runtime, host: *TestHost, out: []u8) !void {
    vm.initInPlace();
    var input: [256]u8 = undefined;
    var f = std.Io.Writer.fixed(&input);
    try f.writeAll("(define retained '( ");
    for (0..50) |_| try f.writeAll("0 ");
    try f.writeAll("))");
    _ = try vm.evaluate(f.buffered(), host, out);
    for (0..6) |_| _ = try vm.evaluate("(set! retained (append retained retained))", host, out);
    _ = try vm.evaluate("(define (churn n acc) (if (= n 0) acc (churn (- n 1) (cons n acc)))) (define (nth xs n) (if (= n 0) (car xs) (nth (cdr xs) (- n 1))))", host, out);
}

test "continuation sliced GC pressure and recovery" {
    var vm: Runtime = undefined;
    var host = TestHost{};
    var out: [128]u8 = undefined;
    try slicedSetup(&vm, &host, &out);
    var lease = SlicedContinuation{};
    try std.testing.expect(try lease.begin(&vm, "(nth (churn 180 '()) 20)"));
    var calls: usize = 0;
    var result: ?[]const u8 = null;
    while (result == null and calls < 20000) : (calls += 1) result = try lease.poll(&host, 16, 64, &out);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("21", result.?);
    try std.testing.expect(lease.collections > 0 and lease.slices > lease.collections);
    try std.testing.expectEqualStrings("3200", try vm.evaluate("(length retained)", &host, &out));
    try std.testing.expectEqualStrings("42", try vm.evaluate("(+ 20 22)", &host, &out));
    std.debug.print("SLICED_PRESSURE collections={d} slices={d} polls={d}\n", .{ lease.collections, lease.slices, calls });
}

test "continuation sliced GC deferred cancel at every phase" {
    const phases = [_]Runtime.SlicePhase{ .roots, .commands, .eval_roots, .call_roots, .ast_roots, .bytecode, .mark_queue, .empty_text, .clear_text_map, .index_text, .copy_text, .remap_text, .sweep };
    var tested: usize = 0;
    for (phases) |phase| {
        var vm: Runtime = undefined;
        var host = TestHost{};
        var out: [128]u8 = undefined;
        try slicedSetup(&vm, &host, &out);
        var lease = SlicedContinuation{};
        try std.testing.expect(try lease.begin(&vm, "(nth (churn 180 '()) 20)"));
        var calls: usize = 0;
        while (calls < 100000) : (calls += 1) {
            if (lease.cursor) |cursor| {
                if (cursor.phase == phase) break;
            }
            _ = try lease.poll(&host, 16, 1, &out);
        }
        try std.testing.expect(calls < 100000);
        lease.cancel();
        try std.testing.expect(lease.cancel_pending and vm.running and vm.ast_root_frame_count > 0);
        try std.testing.expectError(error.Busy, vm.evaluate("42", &host, &out));
        try std.testing.expectError(error.Busy, lease.begin(&vm, "42"));
        while (lease.lease.owner != null and calls < 150000) : (calls += 1) {
            _ = try lease.poll(&host, 16, 64, &out);
        }
        try std.testing.expect(lease.lease.owner == null and !vm.running and vm.ast_root_frame_count == 0);
        try std.testing.expectEqualStrings("3200", try vm.evaluate("(length retained)", &host, &out));
        try std.testing.expectEqualStrings("42", try vm.evaluate("(+ 20 22)", &host, &out));
        tested += 1;
    }
    std.debug.print("SLICED_CANCEL phases={d} busy=ok roots=retained recovery=ok\n", .{tested});
}
