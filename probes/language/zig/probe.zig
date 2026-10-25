const Result = extern struct {
    abi_version: u32,
    checksum: u32,
    processed: u32,
    rejected: u32,
};

const abi_version: u32 = 1;
const ring_capacity: usize = 64;

fn consume(value: u8, result: *Result) void {
    result.checksum = (result.checksum ^ value) *% 16_777_619;
    result.processed +%= 1;
}

export fn nihos_probe_run(
    input: ?[*]const u8,
    length: usize,
    output: ?*Result,
) i32 {
    const result = output orelse return -1;
    if (input == null and length != 0) return -2;

    var ring: [ring_capacity]u8 = undefined;
    var head: usize = 0;
    var tail: usize = 0;
    var count: usize = 0;

    result.* = .{
        .abi_version = abi_version,
        .checksum = 2_166_136_261,
        .processed = 0,
        .rejected = 0,
    };

    var index: usize = 0;
    while (index < length) : (index += 1) {
        const value = input.?[index];
        if (value == 0xff) {
            result.rejected +%= 1;
            continue;
        }
        if (count == ring_capacity) {
            consume(ring[head], result);
            head = (head + 1) % ring_capacity;
            count -= 1;
        }
        ring[tail] = value;
        tail = (tail + 1) % ring_capacity;
        count += 1;
    }

    while (count != 0) {
        consume(ring[head], result);
        head = (head + 1) % ring_capacity;
        count -= 1;
    }
    return 0;
}
