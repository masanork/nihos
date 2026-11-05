//! Compile-only receiver witness; no live networking or firmware linkage.
const stream = @import("stream");
const full = @import("study_options").full;
const D = if (full) stream.Decoder else stream.InitialDecoder;
export fn nih_stream_size() usize {
    return @sizeOf(D);
}
export fn nih_stream_feed(decoder: *D, input: [*]const u8, n: usize) usize {
    return decoder.feed(input[0..n]) catch 0;
}
export fn nih_stream_release(decoder: *D) void {
    decoder.release();
}
export fn nih_stream_keys(decoder: *D, key: *const [16]u8, iv: *const [16]u8, mac: *const [32]u8) bool {
    decoder.enableEncryption(stream.Cipher.init(key.*, iv.*), mac.*) catch return false;
    return true;
}
