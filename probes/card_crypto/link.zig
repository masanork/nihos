const crypto = @import("crypto");
export fn nih_card_crypto(request: ?*const crypto.Request) callconv(.c) c_int {
    if (request) |value| {
        crypto.verify(value) catch return 1;
        return 0;
    }
    return if (crypto.selftest()) 0 else 2;
}
