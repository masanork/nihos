//! Compile/link proof only: same integer Scheme callback path on RV32.
const scheme = @import("scheme_runtime");
// SAFETY: ready gates use; first entry initializes the complete VM.
var vm: scheme.Runtime = undefined;
var ready = false;
const Host = struct {
    pub fn schemeCall(_: *@This(), _: scheme.EditorOp, _: []const u8, _: i32) scheme.Error!void {
        return error.EditorFailure;
    }
};
export fn nih_scheme_frame(ticks: i32) callconv(.c) i32 {
    var host = Host{};
    if (!ready) {
        vm.initInPlace();
        vm.app.enabled = true;
        var out: [32]u8 = undefined;
        _ = vm.evaluate("(app/on-frame! (lambda (t) (plot/set! #:amplitude (+ 50 (plot/sine t 25)))))", &host, &out) catch return -1;
        ready = true;
    }
    vm.runFrame(ticks, &host) catch return -2;
    return vm.app.plot.amplitude;
}
