//! Standalone compile/link probe; not a bootable firmware image.
extern fn nih_photo_decode([*]const u8, usize, [*]u8, usize, [*]u8, usize) callconv(.c) c_int;
export fn photo_probe(input: [*]const u8, length: usize, pixels: [*]u8, scratch: [*]u8) callconv(.c) c_int {
    return nih_photo_decode(input,length,pixels,96*128*2,scratch,4*1024*1024);
}
