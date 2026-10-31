//! Bounded integer Scheme subset for editor extensions. No allocator or I/O.
//! Lexical closures persist across requests; mark/sweep runs between requests.
//! Not R7RS: no proper tail calls, macros, continuations, modules or exact tower.
const std = @import("std");
pub const code_section = if (@import("builtin").os.tag == .freestanding) ".flash.xytext" else if (@import("builtin").object_format == .macho) "__TEXT,__text" else ".text";
pub const data_section = if (@import("builtin").os.tag == .freestanding) ".flash.xyrodata" else if (@import("builtin").object_format == .macho) "__TEXT,__const" else ".rodata";
pub const view_config = @import("view_config");
pub const camera = @import("camera.zig");
pub const storage = @import("storage.zig");
pub const Error = storage.Error || camera.Error || error{ Syntax, Depth, Budget, HeapFull, TextFull, Type, Arity, Unbound, Overflow, UnknownCommand, CommandFull, EditorFailure, Busy };
pub const Ref = u16;
pub const cells = 256;
pub const text_bytes = 64;
pub const depth_limit = 24;
pub const step_limit = 1024;
pub const EditorOp = enum { insert, move, undo, forget, log, memory, tasks };
const Tag = enum { free, nil, integer, boolean, symbol, string, pair, closure, native, keyword };
const Op = enum { quote, if_, begin, define, lambda, set, let, and_, or_, add, sub, mul, equal, less, cons, car, cdr, list, nullq, pairq, not, register, insert, move, undo, forget, log, memory, tasks, view_set, view_get, view_rollback, camera_capture, camera_info, camera_read, sql_query, sql_exec, sql_begin, sql_commit, sql_rollback, fs_open, fs_read, fs_write, fs_resize, fs_remove, fs_sync, fs_rollback, fs_snapshot, fs_restore, fs_release, fs_collect, fs_generation, fs_list, fs_close, fs_stat, fs_begin, sql_lookup, sql_check, fs_space, fs_verify, buffer_save, buffer_load, buffer_text };
const vocabulary linksection(data_section) = "quote\x00if\x00begin\x00define\x00lambda\x00set!\x00let\x00and\x00or\x00+\x00-\x00*\x00=\x00<\x00cons\x00car\x00cdr\x00list\x00null?\x00pair?\x00not\x00command/register!\x00buffer/insert!\x00buffer/move-graphemes!\x00buffer/undo!\x00buffer/forget-undo!\x00system/log\x00system/memory\x00system/tasks\x00view/set!\x00view/get\x00sys/config-rollback!\x00camera/capture!\x00camera/info\x00camera/read\x00sql/query\x00sql/exec!\x00sql/begin!\x00sql/commit!\x00sql/rollback!\x00fs/open\x00fs/read\x00fs/write!\x00fs/truncate!\x00fs/remove!\x00fs/sync!\x00fs/rollback!\x00fs/snapshot\x00fs/restore!\x00fs/release!\x00fs/collect!\x00fs/generation\x00fs/list\x00fs/close!\x00fs/stat\x00fs/begin!\x00q\x00sql/check\x00fs/space\x00fs/verify\x00buffer/save!\x00buffer/load!\x00buffer/text\x00".*;
const Cell = struct {
    tag: Tag,
    mark: bool,
    a: Ref,
    b: Ref,
    env: Ref,
    integer: i32,
    length: u8,
    text: [text_bytes]u8,
};
const Command = struct { name: Ref, procedure: Ref };

pub const Runtime = struct {
    heap: [cells]Cell,
    queue: [cells]Ref,
    commands: [16]Command,
    command_count: usize,
    global: Ref,
    yes: Ref,
    no: Ref,
    next: Ref,
    steps: u32,
    running: bool,
    view: view_config.Config,
    view_history: [8]struct { config: view_config.Config, generation: u32 },
    view_history_count: u8,
    view_generation: u32,

    pub fn initInPlace(self: *Runtime) linksection(code_section) void {
        @memset(std.mem.asBytes(self), 0);
        self.view = .{};
        self.view_generation = 1;
        self.heap[0].tag = .nil;
        self.yes = 1;
        self.no = 2;
        self.global = 3;
        self.next = 4;
        self.heap[1].tag = .boolean;
        self.heap[1].integer = 1;
        self.heap[2].tag = .boolean;
        self.heap[3].tag = .pair;
    }
    fn tick(self: *Runtime, depth: usize) linksection(code_section) Error!void {
        if (depth >= depth_limit) return error.Depth;
        if (self.steps >= step_limit) return error.Budget;
        self.steps += 1;
    }
    fn alloc(self: *Runtime, tag: Tag) linksection(code_section) Error!Ref {
        for (1..cells) |_| {
            const r = self.next;
            self.next = if (r + 1 == cells) 1 else r + 1;
            if (self.heap[r].tag != .free) continue;
            @memset(std.mem.asBytes(&self.heap[r]), 0);
            self.heap[r].tag = tag;
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
        const r = try self.alloc(.integer);
        self.heap[r].integer = n;
        return r;
    }
    fn text(self: *Runtime, tag: Tag, bytes: []const u8) linksection(code_section) Error!Ref {
        if (bytes.len > text_bytes) return error.TextFull;
        const r = try self.alloc(tag);
        self.heap[r].length = @intCast(bytes.len);
        @memcpy(self.heap[r].text[0..bytes.len], bytes);
        return r;
    }
    fn string(self: *const Runtime, r: Ref) linksection(code_section) []const u8 {
        return self.heap[r].text[0..self.heap[r].length];
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
        var head: usize = 0;
        var tail: usize = 0;
        self.mark(self.global, &tail);
        self.mark(self.yes, &tail);
        self.mark(self.no, &tail);
        for (self.commands[0..self.command_count]) |command| {
            self.mark(command.name, &tail);
            self.mark(command.procedure, &tail);
        }
        while (head < tail) : (head += 1) {
            const c = self.heap[self.queue[head]];
            if (c.tag == .pair or c.tag == .closure) {
                self.mark(c.a, &tail);
                self.mark(c.b, &tail);
                self.mark(c.env, &tail);
            }
        }
        for (self.heap[1..]) |*c| {
            if (!c.mark) c.tag = .free;
            c.mark = false;
        }
    }
    fn mark(self: *Runtime, r: Ref, tail: *usize) linksection(code_section) void {
        if (r == 0 or self.heap[r].mark) return;
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
        return b == '(' or b == ')' or b == '\'' or b == '"' or b == ';' or b == ' ' or b == '\t' or b == '\n' or b == '\r';
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
                const item = try self.read(source, pos, depth + 1);
                const p = try self.pair(item, 0);
                if (tail == 0) result = p else self.heap[tail].b = p;
                tail = p;
            }
        }
        if (first == ')') return error.Syntax;
        if (first == '\'') {
            const quoted = try self.read(source, pos, depth + 1);
            return self.pair(try self.text(.symbol, vocabulary[0..5]), try self.pair(quoted, 0));
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
        if (std.mem.startsWith(u8, token, "#x")) return self.number(std.fmt.parseInt(i32, token[2..], 16) catch return error.Overflow);
        if (std.mem.eql(u8, token, ".")) return error.Syntax;
        if ((token[0] >= '0' and token[0] <= '9') or (token.len > 1 and (token[0] == '-' or token[0] == '+') and token[1] >= '0' and token[1] <= '9'))
            return self.number(std.fmt.parseInt(i32, token, 10) catch return error.Overflow);
        return self.text(.symbol, token);
    }
    fn arguments(self: *const Runtime, list: Ref, out: *[16]Ref) linksection(code_section) Error![]Ref {
        var p = list;
        var len: usize = 0;
        while (p != 0) {
            if (self.heap[p].tag != .pair) return error.Type;
            if (len == out.len) return error.Arity;
            out[len] = self.heap[p].a;
            len += 1;
            p = self.heap[p].b;
        }
        return out[0..len];
    }
    fn lookup(self: *const Runtime, env: Ref, name: []const u8) linksection(code_section) Ref {
        var e = env;
        while (e != 0) : (e = self.heap[e].b) {
            var p = self.heap[e].a;
            while (p != 0) : (p = self.heap[p].b) {
                const binding = self.heap[p].a;
                if (std.mem.eql(u8, self.string(self.heap[binding].a), name)) return binding;
            }
        }
        return 0;
    }
    fn define(self: *Runtime, env: Ref, name: Ref, value: Ref) linksection(code_section) Error!void {
        if (self.heap[name].tag != .symbol) return error.Type;
        var p = self.heap[env].a;
        while (p != 0) : (p = self.heap[p].b) {
            const binding = self.heap[p].a;
            if (std.mem.eql(u8, self.string(self.heap[binding].a), self.string(name))) {
                self.heap[binding].b = value;
                return;
            }
        }
        self.heap[env].a = try self.pair(try self.pair(name, value), self.heap[env].a);
    }
    fn closure(self: *Runtime, params: Ref, body: Ref, env: Ref) linksection(code_section) Error!Ref {
        if (body == 0) return error.Arity;
        var argument_storage: [16]Ref = @splat(0);
        const args = try self.arguments(params, &argument_storage);
        for (args, 0..) |arg, index| {
            if (self.heap[arg].tag != .symbol) return error.Type;
            for (args[0..index]) |old| if (std.mem.eql(u8, self.string(arg), self.string(old))) return error.Syntax;
        }
        const r = try self.alloc(.closure);
        self.heap[r].a = params;
        self.heap[r].b = body;
        self.heap[r].env = env;
        return r;
    }
    fn sequence(self: *Runtime, list: Ref, env: Ref, depth: usize, host: anytype) linksection(code_section) Error!Ref {
        var p = list;
        var value: Ref = 0;
        while (p != 0) : (p = self.heap[p].b) {
            try self.tick(depth);
            value = try self.eval(self.heap[p].a, env, depth + 1, host);
        }
        return value;
    }
    fn eval(self: *Runtime, r: Ref, env: Ref, depth: usize, host: anytype) linksection(code_section) Error!Ref {
        try self.tick(depth);
        const c = &self.heap[r];
        if (c.tag == .symbol) {
            const found = self.lookup(env, self.string(r));
            if (found != 0) return self.heap[found].b;
            const op = opcode(self.string(r)) orelse return error.Unbound;
            if (@backingInt(op) < @backingInt(Op.add)) return error.Unbound;
            const native = try self.alloc(.native);
            self.heap[native].integer = @backingInt(op);
            return native;
        }
        if (c.tag != .pair) return r;
        var argument_storage: [16]Ref = @splat(0);
        const args = try self.arguments(c.b, &argument_storage);
        const special = if (self.heap[c.a].tag == .symbol) opcode(self.string(c.a)) else null;
        if (special) |op| switch (op) {
            .quote => {
                if (args.len != 1) return error.Arity;
                return args[0];
            },
            .if_ => {
                if (args.len != 3) return error.Arity;
                const condition = try self.eval(args[0], env, depth + 1, host);
                return self.eval(args[if (condition == self.no) 2 else 1], env, depth + 1, host);
            },
            .begin => return self.sequence(c.b, env, depth, host),
            .and_, .or_ => {
                var value = if (op == .and_) self.yes else self.no;
                for (args) |arg| {
                    value = try self.eval(arg, env, depth + 1, host);
                    if ((value == self.no) == (op == .and_)) break;
                }
                return value;
            },
            .lambda => {
                if (args.len < 2) return error.Arity;
                return self.closure(args[0], self.heap[c.b].b, env);
            },
            .define => {
                if (args.len < 2) return error.Arity;
                if (self.heap[args[0]].tag == .pair) {
                    const signature = self.heap[args[0]];
                    const value = try self.closure(signature.b, self.heap[c.b].b, env);
                    try self.define(env, signature.a, value);
                } else {
                    if (args.len != 2) return error.Arity;
                    try self.define(env, args[0], try self.eval(args[1], env, depth + 1, host));
                }
                return 0;
            },
            .set => {
                if (args.len != 2) return error.Arity;
                if (self.heap[args[0]].tag != .symbol) return error.Type;
                const found = self.lookup(env, self.string(args[0]));
                if (found == 0) return error.Unbound;
                self.heap[found].b = try self.eval(args[1], env, depth + 1, host);
                return 0;
            },
            .let => {
                if (args.len < 2) return error.Arity;
                const local = try self.pair(0, env);
                var bindings: [16]Ref = @splat(0);
                const entries = try self.arguments(args[0], &bindings);
                for (entries) |entry| {
                    var fields: [16]Ref = @splat(0);
                    const binding = try self.arguments(entry, &fields);
                    if (binding.len != 2 or self.heap[binding[0]].tag != .symbol) return error.Syntax;
                    var old = self.heap[local].a;
                    while (old != 0) : (old = self.heap[old].b) if (std.mem.eql(u8, self.string(self.heap[self.heap[old].a].a), self.string(binding[0]))) return error.Syntax;
                    try self.define(local, binding[0], try self.eval(binding[1], env, depth + 1, host));
                }
                return self.sequence(self.heap[c.b].b, local, depth, host);
            },
            else => {},
        };
        const procedure = try self.eval(c.a, env, depth + 1, host);
        for (args) |*arg| arg.* = try self.eval(arg.*, env, depth + 1, host);
        return self.apply(procedure, args, depth + 1, host);
    }
    fn integer(self: *const Runtime, r: Ref) linksection(code_section) Error!i32 {
        if (self.heap[r].tag != .integer) return error.Type;
        return self.heap[r].integer;
    }
    fn apply(self: *Runtime, procedure: Ref, args: []const Ref, depth: usize, host: anytype) linksection(code_section) Error!Ref {
        try self.tick(depth);
        const c = &self.heap[procedure];
        if (c.tag == .closure) {
            var argument_storage: [16]Ref = @splat(0);
            const params = try self.arguments(c.a, &argument_storage);
            if (params.len != args.len) return error.Arity;
            const local = try self.pair(0, c.env);
            for (params, args) |name, value| try self.define(local, name, value);
            return self.sequence(c.b, local, depth, host);
        }
        if (c.tag != .native) return error.Type;
        const op: Op = @fromBackingInt(@intCast(c.integer));
        switch (op) {
            .add, .sub, .mul => {
                if (op == .sub and args.len == 0) return error.Arity;
                var n: i32 = if (op == .mul) 1 else 0;
                for (args, 0..) |arg, index| {
                    const value = try self.integer(arg);
                    if (op == .sub and index == 0 and args.len != 1) {
                        n = value;
                        continue;
                    }
                    const checked = switch (op) {
                        .add => @addWithOverflow(n, value),
                        .sub => @subWithOverflow(n, value),
                        else => @mulWithOverflow(n, value),
                    };
                    if (checked[1] != 0) return error.Overflow;
                    n = checked[0];
                }
                return self.number(n);
            },
            .equal, .less => {
                if (args.len != 2) return error.Arity;
                const a = try self.integer(args[0]);
                const b = try self.integer(args[1]);
                return if (if (op == .equal) a == b else a < b) self.yes else self.no;
            },
            .cons => {
                if (args.len != 2) return error.Arity;
                return self.pair(args[0], args[1]);
            },
            .car, .cdr => {
                if (args.len != 1) return error.Arity;
                if (self.heap[args[0]].tag != .pair) return error.Type;
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
                    .pairq => self.heap[args[0]].tag == .pair,
                    else => args[0] == self.no,
                };
                return if (yes) self.yes else self.no;
            },
            .register => {
                if (args.len != 2) return error.Arity;
                if (self.heap[args[0]].tag != .string or self.heap[args[1]].tag != .closure or self.heap[args[1]].a != 0 or self.string(args[0]).len == 0) return error.Type;
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
            .view_set, .view_get, .view_rollback => return self.applyView(op, args),
            .sql_query, .sql_exec, .sql_begin, .sql_commit, .sql_rollback, .fs_open, .fs_read, .fs_write, .fs_resize, .fs_remove, .fs_sync, .fs_rollback, .fs_snapshot, .fs_restore, .fs_release, .fs_collect, .fs_generation, .fs_list, .fs_close, .fs_stat, .fs_begin, .sql_lookup, .sql_check, .fs_space, .fs_verify => return self.applyStorage(op, args, host),
            .insert => {
                if (args.len != 1) return error.Arity;
                if (self.heap[args[0]].tag != .string) return error.Type;
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
    fn nonnegative(self: *Runtime, r: Ref) linksection(code_section) Error!u32 {
        const n = try self.integer(r);
        if (n < 0) return error.Type;
        return @intCast(n);
    }
    fn storageText(self: *Runtime, r: Ref) linksection(code_section) Error![]const u8 {
        if (self.heap[r].tag != .string) return error.Type;
        return self.string(r);
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
                } else if (self.heap[args[2]].tag == .string) {
                    request.text = self.string(args[2]);
                } else {
                    var p = args[2];
                    var n: usize = 0;
                    while (p != 0) {
                        if (self.heap[p].tag != .pair) return error.Type;
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
                if (self.heap[args[0]].tag != .symbol) return error.Type;
                request.text = self.string(args[0]);
                request.count = 8;
                var i: usize = 1;
                while (i < args.len) : (i += 2) {
                    if (self.heap[args[i]].tag != .keyword) return error.Type;
                    const name = self.string(args[i]);
                    if (std.mem.eql(u8, name, "where")) request.argument = try self.storageText(args[i + 1]) else if (std.mem.eql(u8, name, "limit")) request.count = try self.nonnegative(args[i + 1]) else return error.Type;
                }
            },
            else => if (args.len != 0) return error.Arity,
        }
        // Parse returned DATA without evaluating it. No arbitrary Scheme code
        // can run from a DB cell. Providers must return one bounded expression.
        if (comptime @hasDecl(@TypeOf(host.*), "storageCall")) {
            var buffer: [1024]u8 = undefined;
            const source = try host.storageCall(request, &buffer);
            if (!std.unicode.utf8ValidateSlice(source)) return error.StorageFailed;
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
                    const val = self.heap[args[i + 1]];
                    const value: view_config.Value = switch (val.tag) {
                        .integer => .{ .number = val.integer },
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
        if (self.heap[r].tag != .symbol and self.heap[r].tag != .keyword) return error.Type;
        return self.string(r);
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
        if (self.running) return error.Busy;
        self.collect();
        self.steps = 0;
        self.running = true;
    }
    pub fn evaluate(self: *Runtime, source: []const u8, host: anytype, output: []u8) linksection(code_section) Error![]const u8 {
        try self.start();
        defer self.running = false;
        if (source.len > 4096 or std.mem.indexOfScalar(u8, source, 0) != null or !std.unicode.utf8ValidateSlice(source)) return error.Syntax;
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
        const result = try self.sequence(forms, self.global, 0, host);
        return self.format(result, output);
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
            const binding = self.lookup(self.global, name);
            if (binding == 0) return error.UnknownCommand;
            procedure = self.heap[binding].b;
            if (self.heap[procedure].tag != .closure or self.heap[procedure].a != 0) return error.UnknownCommand;
        }
        const result = try self.apply(procedure, &.{}, 0, host);
        return self.format(result, output);
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
    fn print(self: *const Runtime, r: Ref, output: []u8, pos: *usize, depth: usize) linksection(code_section) Error!void {
        if (depth >= depth_limit) return error.Depth;
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
                    if (self.heap[p].tag != .pair) {
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
    try std.testing.expectError(error.Depth, vm.evaluate("(define (loop) (loop)) (loop)", &host, &out));
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

const messages linksection(data_section) = "Nesting limit\x00Evaluation budget\x00Scheme heap full\x00Unknown command\x00Invalid syntax\x00Wrong argument type\x00Wrong argument count\x00Unbound name\x00Integer overflow\x00Text/result too long\x00Command registry full\x00Editor operation failed\x00Evaluator busy\x00Camera unavailable\x00Camera busy\x00Invalid camera handle\x00Invalid camera range\x00Camera failed\x00Storage unavailable\x00Storage busy\x00Storage permission denied\x00Stale storage handle\x00Storage full\x00File not found\x00Storage request/result limit\x00Storage commit outcome unknown\x00Storage operation failed\x00".*;
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
        error.StorageUnavailable => 18,
        error.StorageBusy => 19,
        error.StorageDenied => 20,
        error.StorageStale => 21,
        error.StorageFull => 22,
        error.StorageNotFound => 23,
        error.StorageLimit => 24,
        error.StorageOutcomeUnknown => 25,
        error.StorageFailed => 26,
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
    const work = "(define (work) " ++ repeat("(if #t #t #t) ", 12) ++ ")";
    try expectValue(&vm, &host, work, "()");
    try std.testing.expectError(error.Budget, vm.evaluate(&repeat("(work) ", 30), &host, &output));
    try std.testing.expectError(error.HeapFull, vm.evaluate(&repeat("0 ", 256), &host, &output));
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
