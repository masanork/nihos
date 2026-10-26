//! Typed commands for the first ESP-AT client profile. No raw command entry.
const std = @import("std");
const at = @import("esp_at.zig");

pub const Command = union(enum) {
    version,
    memory,
    wifi_join: struct { ssid: []const u8, password: []const u8 },
    tcp_connect: struct { link: u8, host: []const u8, port: u16 },
    socket_close: u8,
    socket_read: struct { link: u8, limit: u16 },
    socket_send: struct { link: u8, bytes: []const u8 },
    ble_scan: ?u8,
    ble_connect: struct { link: u8, address: []const u8 },
    ble_disconnect: u8,
    ble_services: u8,
    ble_characteristics: struct { link: u8, service: u16 },
    ble_write: struct { link: u8, service: u16, characteristic: u16, descriptor: ?u16 = null, bytes: []const u8 },
};

pub const Kind = enum { simple, read, socket_send, ble_write };
pub const Encoded = struct {
    bytes: []const u8,
    kind: Kind = .simple,
    link: u8 = 0,
    read_limit: u16 = 0,
    payload: []const u8 = &.{},
};
pub const Error = error{ InvalidArgument, CommandTooLong };

const Writer = struct {
    buffer: []u8,
    len: usize = 0,

    fn put(self: *Writer, text: []const u8) Error!void {
        if (text.len > self.buffer.len - self.len) return error.CommandTooLong;
        @memcpy(self.buffer[self.len..][0..text.len], text);
        self.len += text.len;
    }

    fn decimal(self: *Writer, value: anytype) Error!void {
        const bytes = std.fmt.bufPrint(self.buffer[self.len..], "{d}", .{value}) catch return error.CommandTooLong;
        self.len += bytes.len;
    }

    fn quoted(self: *Writer, text: []const u8) Error!void {
        try self.put("\"");
        for (text) |byte| {
            if (byte < 0x20 or byte == 0x7f) return error.InvalidArgument;
            if (byte == '"' or byte == '\\' or byte == ',') try self.put("\\");
            try self.put(&.{byte});
        }
        try self.put("\"");
    }

    fn index(self: *Writer, prefix: []const u8, value: u8, max: u8) Error!void {
        if (value > max) return error.InvalidArgument;
        try self.put(prefix);
        try self.decimal(value);
    }
};

/// Header borrows output; payload borrows the caller only during submission.
pub fn encode(output: []u8, command: Command) Error!Encoded {
    var writer = Writer{ .buffer = output };
    var result = Encoded{ .bytes = &.{} };
    switch (command) {
        .version => try writer.put("AT+GMR"),
        .memory => try writer.put("AT+SYSRAM?"),
        .wifi_join => |join| {
            if (join.ssid.len == 0 or join.ssid.len > 32 or join.password.len > 64) return error.InvalidArgument;
            try writer.put("AT+CWJAP=");
            try writer.quoted(join.ssid);
            try writer.put(",");
            try writer.quoted(join.password);
        },
        .tcp_connect => |connect| {
            if (connect.host.len == 0 or connect.host.len > 253 or connect.port == 0) return error.InvalidArgument;
            try writer.index("AT+CIPSTART=", connect.link, 4);
            try writer.put(",\"TCP\",");
            try writer.quoted(connect.host);
            try writer.put(",");
            try writer.decimal(connect.port);
        },
        .socket_close => |link| try writer.index("AT+CIPCLOSE=", link, 4),
        .socket_read => |read| {
            if (read.limit == 0 or read.limit > at.payload_capacity) return error.InvalidArgument;
            try writer.index("AT+CIPRECVDATA=", read.link, 4);
            try writer.put(",");
            try writer.decimal(read.limit);
            result.kind = .read;
            result.link = read.link;
            result.read_limit = read.limit;
        },
        .socket_send => |send| {
            if (send.bytes.len == 0 or send.bytes.len > at.payload_capacity) return error.InvalidArgument;
            try writer.index("AT+CIPSEND=", send.link, 4);
            try writer.put(",");
            try writer.decimal(send.bytes.len);
            result.kind = .socket_send;
            result.link = send.link;
            result.payload = send.bytes;
        },
        .ble_scan => |seconds| {
            if (seconds) |duration| {
                if (duration == 0 or duration > 60) return error.InvalidArgument;
                try writer.put("AT+BLESCAN=1,");
                try writer.decimal(duration);
            } else try writer.put("AT+BLESCAN=0");
        },
        .ble_connect => |connect| {
            if (connect.address.len != 17) return error.InvalidArgument;
            for (connect.address, 0..) |byte, i| {
                if (i % 3 == 2) {
                    if (byte != ':') return error.InvalidArgument;
                } else if (!std.ascii.isHex(byte)) return error.InvalidArgument;
            }
            try writer.index("AT+BLECONN=", connect.link, 2);
            try writer.put(",");
            try writer.quoted(connect.address);
        },
        .ble_disconnect => |link| try writer.index("AT+BLEDISCONN=", link, 2),
        .ble_services => |link| try writer.index("AT+BLEGATTCPRIMSRV=", link, 2),
        .ble_characteristics => |discover| {
            if (discover.service == 0) return error.InvalidArgument;
            try writer.index("AT+BLEGATTCCHAR=", discover.link, 2);
            try writer.put(",");
            try writer.decimal(discover.service);
        },
        .ble_write => |write| {
            if (write.service == 0 or write.characteristic == 0 or write.descriptor == 0 or
                write.bytes.len == 0 or write.bytes.len > at.ble_payload_limit) return error.InvalidArgument;
            try writer.index("AT+BLEGATTCWR=", write.link, 2);
            try writer.put(",");
            try writer.decimal(write.service);
            try writer.put(",");
            try writer.decimal(write.characteristic);
            try writer.put(",");
            if (write.descriptor) |descriptor| try writer.decimal(descriptor);
            try writer.put(",");
            try writer.decimal(write.bytes.len);
            result.kind = .ble_write;
            result.link = write.link;
            result.payload = write.bytes;
        },
    }
    try writer.put("\r\n");
    result.bytes = output[0..writer.len];
    return result;
}
