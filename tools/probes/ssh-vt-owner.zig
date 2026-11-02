//! RV32 codegen only; never execute with synthetic credentials or padding.
const hosted = @import("hosted_station");
const bridge = @import("ssh_terminal_session");
const layout = @import("sqld_layout");
const console = @import("text_console");
const Ui = bridge.Session(hosted.ssh_session_owner.Owner, 80, 24, 8);
comptime {
    if (@sizeOf(Ui) > layout.ssh_ui_experiment_bytes) @compileError("SSH VT exceeds PSRAM reservation");
    if (layout.ssh_ui_experiment % @alignOf(Ui) != 0) @compileError("SSH VT reservation misaligned");
}
export fn nih_ssh_vt_init_compile_probe(ui: *Ui, owner: *hosted.ssh_session_owner.Owner) void {
    ui.initInPlace(owner, "SSH");
}
export fn nih_ssh_vt_attach_compile_probe(ui: *Ui, model: *console.scratch.Model) bool {
    if (!model.attachTerminal(ui.port(console.scratch.TerminalPort))) return false;
    model.detachTerminal();
    return true;
}
export fn nih_ssh_vt_compile_probe(ui: *Ui, now: u64, pad: *const [32]u8, seed: *const [32]u8) u32 {
    ui.key(.enter, null) catch return 0;
    _ = ui.poll(now, pad, "probe", seed.*) catch return 0;
    const view = ui.view();
    return view.cells[0].codepoint;
}
