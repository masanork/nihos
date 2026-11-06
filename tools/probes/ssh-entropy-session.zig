//! RV32 code generation only; fixed bytes are not a qualified entropy source.
const sessions = @import("ssh_entropy_session");
const Source = struct {
    held: bool = false,
    pub fn begin(self: *@This()) !void {
        self.held = true;
    }
    pub fn owned(self: *@This()) bool {
        return self.held;
    }
    pub fn sample(_: *@This()) !?u8 {
        return 0;
    }
    pub fn release(self: *@This()) bool {
        self.held = false;
        return true;
    }
};
const S = sessions.Session(Source);
export fn nih_ssh_entropy_session_compile_probe(session: *S, source: *Source, generations: *sessions.Generations, now: u64, out: *[32]u8) bool {
    session.* = S.init(source, generations);
    session.begin(now, 100_000) catch return false;
    session.poll(now);
    if (session.available()) session.fill(out) catch return false;
    session.cancel();
    session.poll(now);
    return session.state == .idle;
}
