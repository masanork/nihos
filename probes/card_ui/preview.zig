//! Host-only synthetic UI renders. No card connection or real identity data.
const std = @import("std");
const card = @import("card");
extern "c" fn fopen([*:0]const u8, [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite([*]const u8, usize, usize, *anyopaque) usize;
extern "c" fn fclose(*anyopaque) c_int;
var frame: [720 * 1280 * 2]u8 = undefined;
var portrait: [card.ResultScreen.portrait_bytes]u8 = undefined;
const font = if (@import("builtin").os.tag == .macos) "__TEXT,__auto_font" else ".rodata.auto_font";
fn save(path: [*:0]const u8) !void {
    const file = fopen(path, "wb") orelse return error.Open;
    defer _ = fclose(file);
    if (fwrite(&frame, 1, frame.len, file) != frame.len) return error.Write;
}
pub fn main() !void {
    for (0..card.ResultScreen.portrait_height) |y| for (0..card.ResultScreen.portrait_width) |x| {
        std.mem.writeInt(u16, portrait[(y * card.ResultScreen.portrait_width + x) * 2 ..][0..2], @intCast((x * 317 + y * 113) & 65535), .little);
    };
    _ = try card.ResultScreen.automaticOverview(font, &frame, .{ .name = "山田　太郎", .address = "東京都千代田区一丁目（架空）", .birth_date = "19900101", .detail = "000000000000", .expiration = "20300101" }, &portrait);
    try card.ResultScreen.licenseNote(font, &frame, .unknown_key, false, 1);
    try card.ResultScreen.resultControls(font, &frame, false);
    try save("build/license-v2-ui/synthetic-classic.rgb565");
    _ = try card.ResultScreen.mynaOverview(font, &frame, "000000000000", "20300101", 0x7fff, &portrait);
    try card.ResultScreen.licenseNote(font, &frame, .unknown_key, true, 0);
    try card.ResultScreen.resultControls(font, &frame, true);
    try save("build/license-v2-ui/synthetic-myna.rgb565");
    _ = try card.ResultScreen.licensePage(font, &frame, false, &.{ .{ .label = "氏名の変更", .date = "20260101", .value = "山田　太郎（架空）" }, .{ .label = "住所の変更", .date = "20260201", .value = "東京都千代田区一丁目（架空）" }, .{ .label = "免許条件の解除", .date = "20260301", .value = "テスト用の記録です" } });
    try save("build/license-v2-ui/synthetic-history.rgb565");
}
