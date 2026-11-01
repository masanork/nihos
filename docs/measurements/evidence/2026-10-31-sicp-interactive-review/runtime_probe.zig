const std = @import("std");
const scheme = @import("runtime");
const Host = struct { pub fn schemeCall(_: *@This(), _: scheme.EditorOp, _: []const u8, _: i32) scheme.Error!void { return error.EditorFailure; } };
pub fn main() void {
    var vm: scheme.Runtime = undefined;
    var host = Host{};
    var out: [256]u8 = undefined;
    const cases = [_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "integer-add", .source = "(+ 137 349)" },
        .{ .name = "division", .source = "(/ 10 5)" },
        .{ .name = "decimal", .source = "(+ 2.7 10)" },
        .{ .name = "comparison", .source = "(> 6 5)" },
        .{ .name = "conditional", .source = "(cond ((= 1 1) 7) (else 9))" },
        .{ .name = "flattened-code-with-stale-output", .source = "(+ 137 350)\n486" },
        .{ .name = "loop", .source = "(define (loop) (loop)) (loop)" },
        .{ .name = "factorial-1", .source = "(define (factorial n) (if (= n 1) 1 (* n (factorial (- n 1)))))\n(factorial 1)" },
        .{ .name = "factorial-2", .source = "(define (factorial n) (if (= n 1) 1 (* n (factorial (- n 1)))))\n(factorial 2)" },
        .{ .name = "factorial-3", .source = "(define (factorial n) (if (= n 1) 1 (* n (factorial (- n 1)))))\n(factorial 3)" },
        .{ .name = "factorial-4", .source = "(define (factorial n) (if (= n 1) 1 (* n (factorial (- n 1)))))\n(factorial 4)" },
        .{ .name = "factorial-5", .source = "(define (factorial n) (if (= n 1) 1 (* n (factorial (- n 1)))))\n(factorial 5)" },
        .{ .name = "factorial-6", .source = "(define (factorial n) (if (= n 1) 1 (* n (factorial (- n 1)))))\n(factorial 6)" },
        .{ .name = "iterative-original", .source = "(define (factorial n) (fact-iter 1 1 n)) (define (fact-iter product counter max-count) (if (> counter max-count) product (fact-iter (* counter product) (+ counter 1) max-count))) (factorial 6)" },
    };
    for (cases) |case| {
        vm.initInPlace();
        const result = vm.evaluate(case.source, &host, &out) catch |err| {
            std.debug.print("{s}: ERROR {s} (steps={d})\n", .{case.name, @errorName(err), vm.steps});
            const recovery = vm.evaluate("(+ 1 2)", &host, &out) catch |recovery_err| {
                std.debug.print("recovery: ERROR {s}\n", .{@errorName(recovery_err)});
                continue;
            };
            std.debug.print("recovery: {s}\n", .{recovery});
            continue;
        };
        std.debug.print("{s}: {s} (steps={d})\n", .{case.name, result, vm.steps});
    }
}
