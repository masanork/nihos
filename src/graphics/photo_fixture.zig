//! Synthetic gradient, never a real person or card. See probes/photo/fixtures/provenance.json.
pub const pixels = @embedFile("photo_fixture.rgb565");
pub const encoded: [@embedFile("photo_fixture.jp2").len]u8 align(64) linksection(".flash.photo.fixture") = @embedFile("photo_fixture.jp2").*;
pub const expected: u32 = 0x4f7df2a8;
