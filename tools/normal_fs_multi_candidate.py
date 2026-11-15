"""Generate a host-only normal-FS owner substitution for differential probes.

Never compile or link the output into firmware. Exact source anchors force a
review when the real task changes; this is not a native integration.
"""


def replace_one(source, before, after):
    if source.count(before) != 1:
        raise ValueError('normal FS candidate anchor changed: ' + before[:80])
    return source.replace(before, after, 1)


def generate(source):
    source = replace_one(source, 'const Owner = rpc.Owner(Backend);', '''const multi = storage.multi;
const reader = storage.multi_reader;
comptime {
    if (@import("builtin").os.tag == .freestanding) @compileError("multi-owner candidate is host-only");
}
const Owner = multi.Service(Backend);
const Frames = struct { request: multi.Request = .{}, response: multi.Response = .{} };
// Host-only candidate: this trusted issuer outlives reconstructed State.
var candidate_issuer = multi.Issuer{};''')
    source = replace_one(source, '''    queues: rpc.Queues,
    frames: rpc.ClientFrames,
    notifications: rpc.Notifications,''', '''    queues: [2]multi.Queues,
    frames: Frames,
    reader: reader.Reader,
    candidate_bound: bool,
    candidate_epoch: u32,''')
    source = replace_one(source, '''        s.owner.revoke(&s.queues) catch return false;''', '''        if (s.owner.mount != null) {
            s.owner.markRemoved() catch return false;
            if (s.candidate_bound) {
                s.owner.stop(&s.queues[0], 0, s.client) catch return false;
                s.candidate_bound = false;
            }
            s.owner.shutdown() catch return false;
        }''')
    source = replace_one(source, '    s.sequence = 1;\n    s.report.generation', '    s.sequence = 0;\n    s.report.generation')
    source = replace_one(source, '''    s.queues = .{};
    s.owner = .{ .notifications = &s.notifications, .client = s.client, .epoch = s.epoch };
    s.root = s.owner.start(&s.backend) catch {
        phase(s, .rejected);
        return;
    };''', '''    s.queues = .{ .{}, .{} };
    s.owner = .{};
    s.candidate_bound = false;
    s.owner.startReadOnly(&s.backend, s.epoch, &candidate_issuer) catch {
        phase(s, .rejected);
        return;
    };
    s.candidate_epoch = s.owner.bind(0, s.client, &s.queues[0], .{ .read = true }) catch {
        phase(s, .rejected);
        return;
    };
    s.candidate_bound = true;''')
    start = source.index('fn exchange(s: *State,')
    end = source.index('fn readCommand(s: *State,', start)
    source = source[:start] + source[end:]
    start = source.index('    if (!exchange(s, .open,', source.index('fn readCommand('))
    end = source.index('\n}\nfn stepOnce()', start)
    source = source[:start] + '''    s.reader = .{};
    if (!s.reader.begin(s.epoch, s.candidate_epoch, s.sequence, command.path[0..command.length], &s.result, &s.frames.request)) {
        if (!unmount(s)) quarantine(s);
        phase(s, .rejected);
        return;
    }
    while (true) {
        if (!s.owner.submit(&s.queues[0], 0, s.client, &s.frames.request) or
            s.owner.step(&s.queues) != 0 or !s.queues[0].responses.tryPopInto(&s.frames.response) or
            s.host_generation != host.generation()) {
            _ = s.reader.abort();
            if (!unmount(s)) quarantine(s);
            phase(s, .rejected);
            return;
        }
        const previous_op = s.frames.request.operation;
        const result = s.reader.accept(&s.frames.response, &s.frames.request);
        s.sequence = s.reader.sequence;
        switch (result) {
            .request => {},
            .complete => {
                s.report.bytes = @intCast(s.reader.bytes);
                s.report.crc = sd.crc32(s.result[0..s.reader.bytes]);
                s.report.eof = @intFromBool(s.reader.eof);
                s.report.error_code = 0;
                return;
            },
            .stop_lane => {
                // A rejected open has no file to clean up. Rebind this stopped
                // producer to preserve the normal task's retry behavior.
                const code: i32 = if (previous_op == .open) switch (s.frames.response.result) {
                    .failure => |err| switch (err) {
                        error.NotFound => -2,
                        error.InvalidName, error.InvalidArgument => -22,
                        error.TooLarge => -27,
                        error.PermissionDenied => -13,
                        else => -5,
                    },
                    else => -5,
                } else -5;
                if (code != -5 and s.host_generation == host.generation()) {
                    s.owner.stop(&s.queues[0], 0, s.client) catch {
                        if (!unmount(s)) quarantine(s);
                        phase(s, .rejected);
                        return;
                    };
                    s.candidate_bound = false;
                    s.candidate_epoch = s.owner.bind(0, s.client, &s.queues[0], .{ .read = true }) catch {
                        if (!unmount(s)) quarantine(s);
                        phase(s, .rejected);
                        return;
                    };
                    s.candidate_bound = true;
                    s.sequence = 0;
                    s.report.error_code = code;
                    return;
                }
                if (!unmount(s)) quarantine(s);
                phase(s, .rejected);
                return;
            },
        }
    }''' + source[end:]
    source = replace_one(source, '''    s.notifications = .{};
    s.commands = .init();
    s.owner = .{ .notifications = &s.notifications, .client = client };
    s.queues = .{};''', '''    s.commands = .init();
    s.owner = .{};
    s.queues = .{ .{}, .{} };
    s.candidate_bound = false;''')
    return source
