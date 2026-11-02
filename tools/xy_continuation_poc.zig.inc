// Host-only prototype appended to a temporary copy of scheme_runtime.zig.
// It is not linked into the product. Frames are caller-owned, bounded storage.
const ContinuationProbe = struct {
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
    frames: [capacity]Frame = undefined,
    count: usize = 0,
    expression: Ref,
    environment: Ref,
    value: Ref = 0,
    returning: bool = false,
    completed: bool = false,
    published: bool = false,
    collections: usize = 0,
    peak_frames: usize = 0,

    fn push(self: *@This(), frame: Frame) Error!void {
        if (self.count == capacity) return error.Depth;
        self.frames[self.count] = frame;
        self.count += 1;
        self.peak_frames = @max(self.peak_frames, self.count);
    }
    // Synchronize at the only locations where this prototype may collect.
    // The expression roots the cursor (a tail of its original argument list).
    fn collect(self: *@This(), vm: *Runtime) void {
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
    fn publishRoots(self: *@This(), vm: *Runtime) void {
        std.debug.assert(vm.ast_root_frame_count == 0);
        for (self.frames[0..self.count], 0..) |frame, i| {
            vm.ast_root_frames[i] = .{ .expression = frame.expression, .environment = frame.environment, .auxiliary = frame.procedure, .values = frame.values, .value_count = frame.count };
        }
        vm.ast_root_frames[self.count] = .{ .expression = if (self.returning) self.value else self.expression, .environment = self.environment };
        vm.ast_root_frame_count = @intCast(self.count + 1);
        self.published = true;
    }
    fn release(self: *@This(), vm: *Runtime) void {
        if (self.published) {
            vm.ast_root_frame_count = 0;
            self.published = false;
        }
    }
    fn sequence(self: *@This(), vm: *Runtime, body: Ref, env: Ref) Error!void {
        if (body == 0) { self.value = 0; self.returning = true; return; }
        if (vm.tagOf(body) != .pair) return error.Syntax;
        const first = vm.heap[body];
        if (first.b != 0) try self.push(.{ .kind = .sequence, .expression = body, .environment = env, .cursor = first.b });
        self.expression = first.a;
        self.environment = env;
        self.returning = false;
    }
    fn condClause(self: *@This(), vm: *Runtime, clauses: Ref, env: Ref, original: Ref) Error!void {
        if (clauses == 0) { self.value = 0; self.returning = true; return; }
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
        self.expression = parts[0]; self.environment = env; self.returning = false;
    }
    fn run(self: *@This(), vm: *Runtime, host: anytype, quantum: usize, force_gc: bool) Error!bool {
        if (self.completed) return true;
        self.release(vm);
        errdefer self.release(vm);
        for (0..quantum) |_| {
            if (force_gc) self.collect(vm);
            try vm.tick(0);
            if (!self.returning) {
                const r = self.expression;
                if (isImmediate(r)) { self.value = r; self.returning = true; continue; }
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
                if (c.tag != .pair) { self.value = r; self.returning = true; continue; }
                const special = if (vm.tagOf(c.a) == .symbol) Runtime.opcode(vm.string(c.a)) else null;
                if (special == .quote) {
                    var a: [16]Ref = @splat(0);
                    const args = try vm.arguments(c.b, &a);
                    if (args.len != 1) return error.Arity;
                    self.value = args[0]; self.returning = true; continue;
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
            if (self.count == 0) { self.completed = true; return true; }
            const frame = &self.frames[self.count - 1];
            if (frame.kind == .branch) {
                var a: [16]Ref = @splat(0);
                const args = try vm.arguments(vm.heap[frame.expression].b, &a);
                self.expression = args[if (self.value == vm.no) 2 else 1];
                self.environment = frame.environment;
                self.count -= 1; self.returning = false; continue;
            }
            if (frame.kind == .sequence) {
                if (vm.tagOf(frame.cursor) != .pair) return error.Syntax;
                const next = vm.heap[frame.cursor];
                self.expression = next.a; self.environment = frame.environment;
                if (next.b == 0) self.count -= 1 else frame.cursor = next.b;
                self.returning = false; continue;
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
                    self.expression = next[1]; self.environment = frame.environment; self.returning = false;
                } else {
                    const body = vm.heap[vm.heap[frame.expression].b].b;
                    const local = frame.procedure;
                    self.count -= 1;
                    try self.sequence(vm, body, local);
                }
                continue;
            }
            if (!frame.operator_done) { frame.procedure = self.value; frame.operator_done = true; }
            else {
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
                self.returning = false; continue;
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
                .add, .sub, .mul, .equal, .less, .greater, .less_equal, .greater_equal,
                .quotient_proc, .remainder_proc, .modulo_proc, .evenq, .cons, .car, .cdr, .nullq, .pairq, .not => {},
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
    var state = ContinuationProbe{ .expression = expression, .environment = vm.global };
    var yields: usize = 0;
    while (!try state.run(&vm, &host, 7, true)) { yields += 1; vm.collect(); }
    try std.testing.expectEqualStrings("60", try vm.format(state.value, &out));
    try std.testing.expect(yields > 1 and state.collections > 1 and state.peak_frames > depth_limit);
    try std.testing.expectEqual(@as(u8, 0), vm.ast_root_frame_count);
    std.debug.print("CONTINUATION size={d} frame={d} peak={d} yields={d} collections={d}\n", .{ @sizeOf(ContinuationProbe), @sizeOf(ContinuationProbe.Frame), state.peak_frames, yields, state.collections });
    vm.running = false;
    try vm.startBudget(20000);
    pos = 0;
    const bad = try vm.read("(and #t #t)", &pos, 0);
    var unsupported = ContinuationProbe{ .expression = bad, .environment = vm.global };
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
        var sample_state = ContinuationProbe{ .expression = sample_expr, .environment = vm.global };
        while (!try sample_state.run(&vm, &host, 11, true)) vm.collect();
        try std.testing.expectEqualStrings(sample.expected, try vm.format(sample_state.value, &out));
        vm.running = false;
    }

    // A compound result must survive while the remaining operands execute.
    _ = try vm.evaluate("(define (wrap x) (cons x x))", &host, &out);
    try vm.startBudget(20000);
    pos = 0;
    const shared = try vm.read("(cons (wrap (cons 1 2)) (wrap (cons 3 4)))", &pos, 0);
    var shared_state = ContinuationProbe{ .expression = shared, .environment = vm.global };
    while (!try shared_state.run(&vm, &host, 1, true)) vm.collect();
    try std.testing.expectEqualStrings("(((1 . 2) 1 . 2) (3 . 4) 3 . 4)", try vm.format(shared_state.value, &out));
    vm.running = false;

    try vm.startBudget(20000);
    pos = 0;
    const deep = try vm.read("(count 120)", &pos, 0);
    var exhausted = ContinuationProbe{ .expression = deep, .environment = vm.global };
    try std.testing.expectError(error.Depth, exhausted.run(&vm, &host, 20000, true));
    try std.testing.expectEqual(@as(usize, ContinuationProbe.capacity), exhausted.peak_frames);
    try std.testing.expectEqual(@as(u8, 0), vm.ast_root_frame_count);
    vm.running = false;
    try std.testing.expectEqualStrings("42", try vm.evaluate("(+ 20 22)", &host, &out));

    // Cancellation here means discarding a yielded host-only state. No UI or
    // asynchronous cancellation mechanism is implemented by this prototype.
    try vm.startBudget(20000);
    pos = 0;
    const cancelled = try vm.read("(count 60)", &pos, 0);
    var cancelled_state = ContinuationProbe{ .expression = cancelled, .environment = vm.global };
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
    var bounded_state = ContinuationProbe{ .expression = bounded, .environment = vm.global };
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
        var state = ContinuationProbe{ .expression = expr, .environment = vm.global };
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
        var state = ContinuationProbe{ .expression = expr, .environment = vm.global };
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
    var state = ContinuationProbe{ .expression = expr, .environment = vm.global };
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

    fn isLocal(self: *const @This(), symbol: Ref) bool {
        for (self.locals[0..self.local_count]) |name| if (name == symbol) return true;
        return false;
    }
    fn addLocal(self: *@This(), symbol: Ref) bool {
        if (self.local_count == self.locals.len) return false;
        self.locals[self.local_count] = symbol;
        self.local_count += 1;
        return true;
    }
    fn closure(self: *@This(), vm: *const Runtime, procedure: Ref, depth: usize) bool {
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
        defer { self.locals = saved_locals; self.local_count = saved; }
        for (formals.fixed[0..formals.count]) |name| if (!self.addLocal(name)) return false;
        return self.sequence(vm, c.b, depth + 1);
    }
    fn sequence(self: *@This(), vm: *const Runtime, list: Ref, depth: usize) bool {
        var items: [16]Ref = @splat(0);
        const expressions = vm.arguments(list, &items) catch return false;
        for (expressions) |expr| if (!self.expression(vm, expr, depth + 1)) return false;
        return true;
    }
    fn expression(self: *@This(), vm: *const Runtime, expr: Ref, depth: usize) bool {
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
                .add, .sub, .mul, .equal, .less, .greater, .less_equal, .greater_equal,
                .quotient_proc, .remainder_proc, .modulo_proc, .evenq, .cons, .car, .cdr, .nullq, .pairq, .not => {},
                else => return false,
            }
        }
        for (args) |arg| if (!self.expression(vm, arg, depth + 1)) return false;
        return true;
    }
};

test "continuation prototype conservative admission and fallback" {
    const Harness = struct {
        fn admit(vm: *Runtime, source: []const u8) Error!bool {
            try vm.start();
            defer vm.running = false;
            var pos: usize = 0;
            const expr = try vm.read(source, &pos, 0);
            Runtime.space(source, &pos);
            if (pos != source.len) return false;
            var admission = ContinuationAdmission{};
            return admission.expression(vm, expr, 0);
        }
        fn route(vm: *Runtime, host: *TestHost, source: []const u8, out: []u8, used_continuation: *bool) Error![]const u8 {
            try vm.start();
            var pos: usize = 0;
            const expr = vm.read(source, &pos, 0) catch |err| { vm.running = false; return err; };
            Runtime.space(source, &pos);
            var admission = ContinuationAdmission{};
            used_continuation.* = pos == source.len and admission.expression(vm, expr, 0);
            if (!used_continuation.*) {
                vm.running = false;
                return vm.evaluate(source, host, out);
            }
            defer vm.running = false;
            var state = ContinuationProbe{ .expression = expr, .environment = vm.global };
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
const ContinuationLeaseProbe = struct {
    state: ContinuationProbe = undefined,
    owner: ?*Runtime = null,

    fn begin(self: *@This(), vm: *Runtime, source: []const u8) Error!bool {
        if (self.owner != null) return error.Busy;
        try vm.start();
        errdefer vm.running = false;
        if (source.len > 4096 or std.mem.indexOfScalar(u8, source, 0) != null or !storage.validUtf8(source)) return error.Syntax;
        var pos: usize = 0;
        Runtime.space(source, &pos);
        if (pos == source.len) { vm.running = false; return false; }
        const expr = try vm.read(source, &pos, 0);
        Runtime.space(source, &pos);
        var admission = ContinuationAdmission{};
        if (pos != source.len or !admission.expression(vm, expr, 0)) { vm.running = false; return false; }
        self.state = .{ .expression = expr, .environment = vm.global };
        self.owner = vm;
        return true;
    }
    fn cancel(self: *@This()) void {
        if (self.owner) |vm| {
            self.state.release(vm);
            vm.running = false;
            self.owner = null;
        }
    }
    fn poll(self: *@This(), host: anytype, quantum: usize, output: []u8) Error!?[]const u8 {
        const vm = self.owner orelse return error.Syntax;
        if (quantum == 0) { self.cancel(); return error.Syntax; }
        const done = self.state.run(vm, host, quantum, false) catch |err| { self.cancel(); return err; };
        if (!done) return null;
        const result = vm.format(self.state.value, output) catch |err| { self.cancel(); return err; };
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
    var slot = ContinuationLeaseProbe{};
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
    slot.cancel(); slot.cancel();
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
    std.debug.print("LEASE bytes={d} yields={d} cancellation=ok errors=ok reentry=busy\n", .{ @sizeOf(ContinuationLeaseProbe), yields });
}
