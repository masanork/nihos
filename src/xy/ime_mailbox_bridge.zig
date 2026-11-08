//! Foreground-only IME client for the serialized dictionary mailbox. The
//! caller owns a stable workspace and backend until shutdown has completed.
const std = @import("std");
const wire = @import("../platform/native/sqld_ime_mailbox.zig");
const pages = @import("../storage/async_page.zig");
const conversion = @import("async_conversion.zig");
const session = @import("async_ime_session.zig");
const Model = @import("scratch.zig").Model;
pub const Request = wire.Request;
pub const Response = wire.Response;

pub const Bridge = struct {
    pub const Phase = enum { idle, opening, active, reading, closing, closed, fenced };
    phase: Phase = .idle,
    stopping: bool = false,
    attached: bool = false,
    page: pages.Coordinator = .{},
    adapter: conversion.Adapter,
    runtime: session.Runtime,
    port: @import("scratch.zig").AsyncImePort,
    ticket: wire.Request = .{},
    pending: ?pages.Request = null,
    response: wire.Response = .{},

    pub fn init() Bridge {
        // SAFETY: The opening phase initializes these self-referential fields
        // in place before the active or reading phase can access them.
        return .{ .adapter = undefined, .runtime = undefined, .port = undefined };
    }

    /// Backend.submit copies the request and assigns a sequence. The backend
    /// must have exactly one producer and must not be shared with other users.
    pub fn open(self: *Bridge, backend: anytype) i32 {
        if (self.phase != .idle) return -16;
        self.ticket = .{ .operation = 1 };
        const rc = backend.submit(&self.ticket);
        if (rc == 0) self.phase = .opening;
        return rc;
    }
    pub fn stop(self: *Bridge, model: *Model) void {
        self.stopping = true;
        if (self.phase == .active or self.phase == .reading) self.port.cancel(self.port.context, model);
    }
    fn matches(self: *const Bridge) bool {
        return std.meta.eql(self.ticket, self.response.request);
    }
    /// Does at most one mailbox exchange per call. Returns false only on an
    /// unknown/mismatched result, where reuse/release must remain fenced.
    pub fn poll(self: *Bridge, model: *Model, backend: anytype, budget: usize) bool {
        if (self.attached and model.async_ime != &self.port) return self.fence();
        switch (self.phase) {
            .idle, .closed => return true,
            .fenced => return false,
            .opening => {
                const result = backend.take(&self.response);
                if (result == 0) return true;
                if (result != 1 or !self.matches()) return self.fence();
                if (self.response.status != 0) {
                    self.phase = .closed;
                    return true;
                }
                if (self.response.size == 0) {
                    self.stopping = true;
                } else {
                    self.page.attach(1, self.response.size) catch return self.fence();
                    self.adapter = .{ .coordinator = &self.page };
                    self.runtime = .{ .adapter = &self.adapter };
                    self.port = self.runtime.port();
                    if (!self.stopping) {
                        self.attached = model.attachAsyncIme(&self.port);
                        if (!self.attached) self.stopping = true;
                    }
                }
                self.phase = .active;
            },
            .reading => {
                const result = backend.take(&self.response);
                if (result == 0) return true;
                if (result != 1 or !self.matches()) return self.fence();
                const request = self.pending orelse return self.fence();
                const bytes: ?[]const u8 = if (self.response.status == 0 and self.response.length == request.length)
                    self.response.bytes[0..request.length]
                else
                    null;
                self.pending = null;
                self.phase = .active;
                self.runtime.supply(request, bytes) catch {
                    self.stopping = true;
                    self.port.cancel(self.port.context, model);
                };
            },
            .closing => {
                const result = backend.take(&self.response);
                if (result == 0) return true;
                if (result != 1 or !self.matches() or self.response.status != 0) return self.fence();
                self.phase = .closed;
                return true;
            },
            .active => {},
        }
        if (self.stopping) {
            if (self.page.pin != 0) {
                if (self.attached) {
                    self.port.cancel(self.port.context, model);
                    // A request that could not be submitted has no producer
                    // to drain. Complete its cancelled coordinator locally.
                    if (self.runtime.request()) |request| self.runtime.supply(request, null) catch return self.fence();
                    if (self.port.busy(self.port.context)) return true;
                    if (!model.detachAsyncIme()) return self.fence();
                    self.attached = false;
                }
                self.page.detach() catch return self.fence();
            }
            self.ticket = .{ .operation = 3 };
            const rc = backend.submit(&self.ticket);
            if (rc == -16) return true;
            if (rc != 0) return self.fence();
            self.phase = .closing;
            return true;
        }
        model.pollAsyncIme(budget);
        if (self.runtime.request()) |request| {
            self.ticket = .{ .operation = 2, .offset = request.offset, .length = @intCast(request.length) };
            const rc = backend.submit(&self.ticket);
            if (rc == -16) return true;
            if (rc != 0) {
                // No backend owns a buffer on submit failure.
                self.runtime.supply(request, null) catch |err| {
                    if (err != error.Io) return self.fence();
                };
                self.stopping = true;
                self.port.cancel(self.port.context, model);
                return true;
            }
            self.pending = request;
            self.phase = .reading;
        }
        return true;
    }
    fn fence(self: *Bridge) bool {
        self.phase = .fenced;
        return false;
    }
};
