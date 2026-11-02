//! RV32 codegen only; never execute with synthetic credentials or padding.
const hosted = @import("hosted_station");
const bridge = @import("ssh_terminal_session");
const Ui = bridge.Session(hosted.ssh_session_owner.Owner, 80, 24, 8);
export fn nih_ssh_vt_compile_probe(ui: *Ui, now: u64, pad: *const [32]u8, seed: *const [32]u8) u32 {
    ui.key(.enter, null) catch return 0;
    _ = ui.poll(now, pad, "probe", seed.*) catch return 0;
    const view = ui.view();
    return view.cells[0].codepoint;
}
