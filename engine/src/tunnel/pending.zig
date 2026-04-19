//! A single in-flight RPC awaiting a reply from the peer on the other
//! end of a tunnel.
//!
//! An engine-initiated request (e.g. ActorStart → runner) allocates a
//! `Pending` keyed by its correlation tag, sends the frame, then blocks
//! on `wait()` until the reader loop calls `deliver()` with the reply
//! body. The body payload is owned by Pending from `deliver()` onward.
//!
//! Thread-safe: `wait()` and `deliver()` may run on different tasks.
//!
//! Uses `std.Io.Mutex` / `std.Io.Condition` so this works with whichever
//! Io implementation the engine is booted with (threaded, fibers, etc.).

const std = @import("std");

pub const DeliveryKind = enum { ok, err, cancelled };

pub const Pending = struct {
    alloc: std.mem.Allocator,

    mu: std.Io.Mutex = .init,
    cv: std.Io.Condition = .init,
    delivered: bool = false,

    kind: DeliveryKind = .ok,
    /// Body payload copied on `deliver()`. Caller of `waitTake()` takes
    /// ownership; otherwise `deinit()` frees it.
    body: ?[]u8 = null,

    pub fn init(alloc: std.mem.Allocator) Pending {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Pending) void {
        if (self.body) |b| self.alloc.free(b);
    }

    /// Called by the reader loop. Takes an owned copy of `body`.
    /// Second and subsequent calls are ignored.
    pub fn deliver(self: *Pending, io: std.Io, kind: DeliveryKind, body: []const u8) !void {
        const copied = try self.alloc.dupe(u8, body);
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        if (self.delivered) {
            self.alloc.free(copied);
            return;
        }
        self.kind = kind;
        self.body = copied;
        self.delivered = true;
        self.cv.broadcast(io);
    }

    /// Cancel without a body (e.g. tunnel closed). Wakes any waiter.
    pub fn cancel(self: *Pending, io: std.Io) void {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        if (self.delivered) return;
        self.kind = .cancelled;
        self.delivered = true;
        self.cv.broadcast(io);
    }

    /// Block until delivered or cancelled. Returns the delivery kind.
    /// Caller then reads `body` (or uses `waitTake` to consume it).
    /// Uncancelable — wraps `error.Canceled` away for simpler call sites.
    pub fn wait(self: *Pending, io: std.Io) DeliveryKind {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        while (!self.delivered) self.cv.waitUncancelable(io, &self.mu);
        return self.kind;
    }

    /// Wait and take ownership of the body.
    pub fn waitTake(self: *Pending, io: std.Io) struct { kind: DeliveryKind, body: ?[]u8 } {
        const kind = self.wait(io);
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        const b = self.body;
        self.body = null;
        return .{ .kind = kind, .body = b };
    }
};

// ─── tests ───────────────────────────────────────────────────────────
// Tests run on the single-threaded Io (the default for `zig test`), so
// concurrent delivery across threads isn't exercised here; it's covered
// by the integration tests once we have them.

const test_io = std.Io.Threaded.global_single_threaded.io();

test "deliver then wait (same task)" {
    const alloc = std.testing.allocator;
    var p = Pending.init(alloc);
    defer p.deinit();
    try p.deliver(test_io, .ok, "hi");
    const got = p.waitTake(test_io);
    try std.testing.expectEqual(DeliveryKind.ok, got.kind);
    try std.testing.expect(got.body != null);
    try std.testing.expectEqualStrings("hi", got.body.?);
    alloc.free(got.body.?);
}

test "cancel wakes waiter" {
    const alloc = std.testing.allocator;
    var p = Pending.init(alloc);
    defer p.deinit();
    p.cancel(test_io);
    try std.testing.expectEqual(DeliveryKind.cancelled, p.wait(test_io));
}

test "deliver twice: second is ignored" {
    const alloc = std.testing.allocator;
    var p = Pending.init(alloc);
    defer p.deinit();
    try p.deliver(test_io, .ok, "first");
    try p.deliver(test_io, .err, "second"); // silently dropped
    try std.testing.expectEqual(DeliveryKind.ok, p.wait(test_io));
    try std.testing.expectEqualStrings("first", p.body.?);
}
