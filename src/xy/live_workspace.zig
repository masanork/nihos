//! Shared, bounded live-definition lifecycle. Persistence belongs to the host.
//! Prepare is side-effect-free; activation is infallible after durable commit.
const std = @import("std");
pub const scheme = @import("scheme_runtime.zig");
pub const default_source = @embedFile("bootstrap.scm");
pub const source_limit = 4096;

const DefinitionHost = struct {
    pub fn schemeCall(_: *@This(), _: scheme.EditorOp, _: []const u8, _: i32) scheme.Error!void {
        return error.EditorFailure;
    }
};

pub fn Session(comptime Workspace: type) type {
    return struct {
        const Self = @This();
        active: scheme.Runtime,
        candidate: scheme.Runtime,
        backup_doc: Workspace.DocType = .{},
        prepared: bool = false,
        storage_client: scheme.storage.Client = .{},
        load_scratch: @FieldType(Workspace.DocType, "bytes") = @splat(0),

        pub fn init(self: *Self) void {
            self.active.initInPlace();
            self.prepared = false;
            self.storage_client = .{};
        }
        pub fn prepare(self: *Self, source: []const u8, output: []u8) scheme.Error![]const u8 {
            self.prepared = false;
            self.candidate.initInPlace();
            var host = DefinitionHost{};
            const result = try self.candidate.evaluate(source, &host, output);
            self.prepared = true;
            return result;
        }
        pub fn activate(self: *Self) bool {
            if (!self.prepared) return false;
            self.active = self.candidate;
            self.prepared = false;
            return true;
        }
        pub fn discard(self: *Self) void {
            self.prepared = false;
        }
        const Adapter = struct {
            ws: *Workspace,
            storage_client: scheme.storage.Client,
            load_scratch: []u8,
            pub fn documentText(self: *@This()) []const u8 {
                return self.ws.doc.slice();
            }
            pub fn saveDocument(self: *@This(), name: []const u8) scheme.Error!void {
                try self.storage_client.save(name, self.ws.doc.slice());
            }
            pub fn loadDocument(self: *@This(), name: []const u8) scheme.Error!void {
                const text = try self.storage_client.load(name, self.load_scratch);
                self.ws.doc.clear();
                self.ws.doc.insertUtf8(text) catch return error.EditorFailure;
            }
            pub fn storageCall(self: *@This(), request: scheme.storage.Request, output: []u8) scheme.Error![]const u8 {
                return self.storage_client.call(request, output);
            }
            pub fn schemeCall(self: *@This(), op: scheme.EditorOp, text: []const u8, number: i32) scheme.Error!void {
                switch (op) {
                    .insert => self.ws.doc.insertUtf8(text) catch return error.EditorFailure,
                    .move => {
                        // Avoid signed-negation overflow in older Document revisions.
                        const bound: i32 = @intCast(self.ws.doc.len);
                        _ = self.ws.doc.moveGraphemes(std.math.clamp(number, -bound, bound)) catch return error.EditorFailure;
                    },
                    .undo => {
                        _ = self.ws.doc.undo() catch return error.EditorFailure;
                    },
                    // System snapshots and explicit undo discard need a separate host contract.
                    else => return error.EditorFailure,
                }
            }
        };
        pub fn run(self: *Self, ws: *Workspace, source: []const u8, named: bool, output: []u8) scheme.Error![]const u8 {
            // A pending commit must not be invalidated by interactive evaluation.
            if (self.prepared) return error.Busy;
            if (comptime @hasField(Workspace, "appearance")) {
                self.active.view = .{ .style = ws.style, .appearance = ws.appearance };
            }
            self.candidate = self.active;
            self.backup_doc = ws.doc;
            const old_dirty = ws.layout_dirty;
            _ = ws.doc.beginUndoGroup();
            var adapter = Adapter{ .ws = ws, .storage_client = self.storage_client, .load_scratch = &self.load_scratch };
            const result = (if (named) self.active.runCommand(source, &adapter, output) else self.active.evaluate(source, &adapter, output)) catch |err| {
                self.active = self.candidate;
                ws.doc = self.backup_doc;
                ws.layout_dirty = old_dirty;
                return err;
            };
            if (comptime @hasField(Workspace, "appearance")) {
                ws.style = self.active.view.style;
                ws.appearance = self.active.view.appearance;
            }
            ws.doc.endUndoGroup();
            ws.layout_dirty = true;
            return result;
        }
    };
}

const Document = @import("document.zig");
const TestWorkspace = struct {
    pub const DocType = Document.Document(4096, 32, 1024, 8, 64);
    doc: DocType = .{},
    layout_dirty: bool = false,
};
test "prepare rejects effects, swaps commands without stale closures, and removes deleted definitions" {
    // SAFETY: init initializes the runtime before any operation.
    var live: Session(TestWorkspace) = undefined;
    live.init();
    var ws = TestWorkspace{};
    var out: [256]u8 = undefined;
    _ = try live.prepare(default_source, &out);
    try std.testing.expect(live.activate());
    _ = try live.run(&ws, "stamp", true, &out);
    try std.testing.expectEqualStrings("Hello from Scheme!\n", ws.doc.slice());
    _ = try live.prepare("(define (stamp) (buffer/insert! \"new\"))", &out);
    try std.testing.expectError(error.Busy, live.run(&ws, "stamp", true, &out));
    try std.testing.expect(live.activate());
    _ = try live.run(&ws, "stamp", true, &out);
    try std.testing.expectEqualStrings("Hello from Scheme!\nnew", ws.doc.slice());
    try std.testing.expectError(error.EditorFailure, live.prepare("(buffer/insert! \"bad\")", &out));
    try std.testing.expect(!live.activate());
    _ = try live.run(&ws, "stamp", true, &out);
    _ = try live.prepare("(define value 7)", &out);
    try std.testing.expect(live.activate());
    try std.testing.expectError(error.UnknownCommand, live.run(&ws, "stamp", true, &out));
}
test "failed evaluation restores definitions and document; repeated loads and extreme movement recover" {
    // SAFETY: init initializes the runtime before any operation.
    var live: Session(TestWorkspace) = undefined;
    live.init();
    var ws = TestWorkspace{};
    var out: [256]u8 = undefined;
    _ = try live.run(&ws, "(define value 7)", false, &out);
    try std.testing.expectError(error.Unbound, live.run(&ws, "(set! value 9) (buffer/insert! \"bad\") missing", false, &out));
    try std.testing.expectEqualStrings("", ws.doc.slice());
    try std.testing.expectEqualStrings("7", try live.run(&ws, "value", false, &out));
    _ = try live.run(&ws, "(buffer/insert! \"葛󠄀が\") (buffer/move-graphemes! -2147483648)", false, &out);
    try std.testing.expectEqual(@as(u32, 0), ws.doc.cursor);
    for (0..100) |_| {
        _ = try live.prepare(default_source, &out);
        try std.testing.expect(live.activate());
    }
}
