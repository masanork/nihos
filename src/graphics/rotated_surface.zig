//! Landscape view of the Tab5's portrait RGB565 surface. No second framebuffer.
const surface = @import("surface");
pub const Rotated = struct {
    physical: surface.Surface,
    width: usize,
    height: usize,
    pub fn init(physical: surface.Surface) Rotated {
        return .{ .physical = physical, .width = physical.height, .height = physical.width };
    }
    pub fn fillRect(self: Rotated, x: i32, y: i32, w: u32, h: u32, color: u16) bool {
        return self.physical.fillRect(y, @as(i32, @intCast(self.width)) - x - @as(i32, @intCast(w)), h, w, color);
    }
    pub fn blit(self: Rotated, mask: surface.Mask, x: i32, y: i32, color: u16) bool {
        return self.paint(mask, x, y, color, false);
    }
    pub fn blitLinear(self: Rotated, mask: surface.Mask, x: i32, y: i32, color: u16) bool {
        return self.paint(mask, x, y, color, true);
    }
    fn paint(self: Rotated, mask: surface.Mask, x: i32, y: i32, color: u16, linear: bool) bool {
        if (mask.height > 256 or mask.stride < mask.width or mask.bytes.len < mask.stride * mask.height) return false;
        var row: [256]u8 = @splat(0);
        for (0..mask.width) |column| {
            for (0..mask.height) |r| row[r] = mask.bytes[r * mask.stride + column];
            const rotated = surface.Mask{ .bytes = row[0..mask.height], .width = mask.height, .height = 1, .stride = mask.height };
            const py = @as(i32, @intCast(self.width)) - 1 - x - @as(i32, @intCast(column));
            const ok = if (linear) self.physical.blitLinear(rotated, y, py, color) else self.physical.blit(rotated, y, py, color);
            if (!ok) return false;
        }
        return true;
    }
};
