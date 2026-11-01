# xy Scheme: guarded numeric function cache

Candidate built on `09cf790e`. This is a bounded first stage, not a full Scheme compiler.

The AST evaluator only recycles a frame it created in the current evaluator invocation, with the same lexical parent and matching parameters. Creating a closure marks each captured non-global ancestor as ineligible for recycling. These conservative flags survive until the frame is collected. Tests cover an escaped closure, different lexical parents, and a non-tail call that must not modify the caller's parameters.

A one-entry, weak function-code cache accelerates a single top-level call to an AST closure whose parent is global. Admission is rechecked on every invocation: all arguments must be immediate integers, the body is limited to local parameters, immediate literals, conditionals, sequencing, selected integer primitives and direct self tail calls. Primitive names must currently be unbound, so rebinding them falls back to the interpreter. Other forms, calls, captured closures, side effects, large code or full code storage fall back to the AST evaluator. A temporary wrapper is discarded after every request; the body code is retained in the existing 192-byte area. The cache does not root its owning closure; GC drops dead cached code. Switching eligible functions evicts the old body. Numeric equality checks integer types in both execution modes.

Focused tests compare VM and interpreter results for inputs 0 through 25, verify error types, exercise 100 repeated cache calls, primitive rebinding, and unreachable-function collection. The reference AST evaluator and bytecode path have different tick accounting; equality of tick counts is not required.

## Bounded host measurement

On the local macOS host, ReleaseSafe, with other builds running: define `(sum-iter n acc)` as `(if (= n 0) acc (sum-iter (- n 1) (+ acc n)))`, warm up once, then call `(sum-iter 50 0)` 2,000 times through `evaluate`, including source reading, GC, evaluation and formatting. The timer was `mach_absolute_time` converted using `mach_timebase_info`. Both returned `1275` every time.

| Run | AST baseline `09cf790e` | Candidate |
| --- | ---: | ---: |
| First mean per request | 231,442 ns | 5,524 ns |
| Second mean per request | 76,962 ns | 5,079 ns |
| Last evaluation ticks | 916 | 666 |
| Free cells immediately after evaluation | 214 | 218 |
| Host `@sizeOf(Runtime)` | 7,632 B | 7,632 B |
| Retained bytecode | 0 B | 33 B |

The large variation shows contention; neither host timing ratio is a Tab5 performance claim. The test does not measure cold-cache compilation, other programs, or real-time deadlines.

The ordinary connected native candidate built and passed the image auditor with 49,728 B primary heap against the 49,152 B floor. The four added foreground functions are explicitly approved in the Flash audit; the native-image Python tests retain negative checks for unapproved functions. No candidate was flashed. Tab5 execution, timings, worst-case Scheme stack watermark, and physical recovery remain unverified.
