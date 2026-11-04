//! Experimental owner-serialized adapter: retain the existing short DMA path
//! for register reads and small packets; route long writes to private storage.
//! A shared Short bus must expose `shared_host`, `lease` and `ownsSlot`; this
//! adapter pins that lease across preparation and completion. Its caller must
//! keep the shared host lease for the whole controller operation and call
//! retire on timeout, reset or any other ambiguous failure. Retirement does not
//! stop DMA or make its storage safe to free. This adapter is not wired into
//! the normal network provider.
const std = @import("std");
const dma = @import("hosted_long_dma.zig");
pub const Buffer = dma.Buffer;
pub const Active = enum { none, short, long, retired };

pub fn Bus(comptime Short: type, comptime Cache: type) type {
    const ShortDecl = switch (@typeInfo(Short)) {
        .pointer => |pointer| pointer.child,
        else => Short,
    };
    const shared = @hasDecl(ShortDecl, "shared_host") and ShortDecl.shared_host;
    const Lease = if (shared) std.meta.fieldInfo(ShortDecl, .lease).type else void;
    return struct {
        short: Short,
        buffer: *Buffer,
        cache: Cache,
        active: Active = .none,
        active_lease: ?Lease = null,

        fn owns(self: *@This()) bool {
            if (comptime shared) return self.short.ownsSlot(1);
            return true;
        }

        fn sameLease(self: *@This()) bool {
            if (comptime shared) return self.active_lease != null and self.owns() and std.meta.eql(self.active_lease.?, self.short.lease);
            return true;
        }

        /// Quarantines storage without claiming the controller or DMA stopped.
        /// Its owner must retain this object until hardware quiescence is proved.
        pub fn retire(self: *@This()) void {
            self.buffer.retire();
            self.active = .retired;
            self.active_lease = null;
        }

        pub fn read(self: *@This(), address: usize) u32 {
            return self.short.read(address);
        }
        pub fn write(self: *@This(), address: usize, value: u32) void {
            self.short.write(address, value);
        }
        pub fn delay(self: *@This(), us: u32) void {
            self.short.delay(us);
        }
        pub fn fourBitPins(self: *@This()) void {
            self.short.fourBitPins();
        }

        pub fn prepareDma(self: *@This(), writing: bool, source: []const u8, length: usize) ?u32 {
            if (self.active != .none) {
                if (self.active != .retired and !self.sameLease()) self.retire();
                return null;
            }
            if (self.buffer.state == .retired or !self.owns()) return null;
            const initial_lease: Lease = if (shared) self.short.lease else {};
            if (length == 0 or length % 4 != 0 or
                (writing and source.len != length) or (!writing and source.len != 0)) return null;
            if (length <= 512) {
                const descriptor = self.short.prepareDma(writing, source, length) orelse return null;
                self.active = .short;
                if (comptime shared) self.active_lease = initial_lease;
                if (!self.sameLease()) {
                    self.retire();
                    return null;
                }
                return descriptor;
            }
            if (!writing or source.len != length) return null;
            const descriptor = self.buffer.prepare(source, &self.cache) orelse {
                if (self.buffer.state == .retired) self.active = .retired;
                return null;
            };
            self.active = .long;
            if (comptime shared) self.active_lease = initial_lease;
            if (!self.sameLease()) {
                self.retire();
                return null;
            }
            return descriptor;
        }

        /// Controller must stop DMA before calling this. Timeout paths skip
        /// this call and retain active storage; the owner must retire the host.
        pub fn finishDma(self: *@This(), writing: bool, destination: []u8) bool {
            if (self.active == .none or self.active == .retired) return false;
            if (!self.sameLease()) {
                self.retire();
                return false;
            }
            const ok = switch (self.active) {
                .short => self.short.finishDma(writing, destination),
                .long => writing and destination.len == 0 and self.buffer.finish(&self.cache),
                else => return false,
            };
            if (!ok or !self.sameLease()) {
                self.retire();
                return false;
            }
            self.active = .none;
            self.active_lease = null;
            return true;
        }
    };
}
