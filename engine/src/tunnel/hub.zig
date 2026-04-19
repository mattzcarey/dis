//! TunnelHub — shared registry of connected runners and live sessions.
//!
//! Thread-safe: protected by `mu`. Callers take the lock only for
//! short bookkeeping updates; long-running tasks (sending frames to a
//! runner, awaiting replies) happen OUTSIDE the hub lock. Lock order
//! is always hub → runner/session, never the reverse.
//!
//! Session identity:
//!   - `sid` (16 bytes, 32-char lowercase hex) is the sole session key.
//!   - Engine mints a fresh sid on `newSession(actor)`.
//!   - Clients resume by passing the hex sid back via `?sid=…` — the
//!     engine looks it up in `sessions` by `Id128` key.
//!
//! There is no namespace and no user-provided "composite key". User
//! identity (once we add it) will come from the bearer token in the
//! HTTP upgrade request, not from the URL.

const std = @import("std");
const log = @import("log").scoped("hub");

const RunnerConn = @import("runner_conn.zig").RunnerConn;
const HubRef = @import("runner_conn.zig").HubRef;
const ClientConnection = @import("connection.zig").ClientConnection;
const frames = @import("frames.zig");
const messages = @import("messages.zig");
const pending = @import("pending.zig");
const cbor = @import("cbor");
const idmod = @import("../util/id.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Id128 = idmod.Id128;

pub const HubError = error{
    NoRunnerForActor,
    SessionNotFound,
    RunnerDead,
    ActorStartFailed,
    OutOfMemory,
};

pub const Session = struct {
    id: Id128,
    id_hex: [32]u8,

    actor_name: []const u8, // owned
    runner: *RunnerConn,
    state: State = .starting,

    /// Attached client connections. Protected by `connections_mu`.
    connections: std.ArrayListUnmanaged(*ClientConnection) = .empty,
    connections_mu: Io.Mutex = .init,

    pub const State = enum { starting, ready, stopping, dead };

    fn destroy(self: *Session, alloc: Allocator) void {
        self.connections.deinit(alloc);
        alloc.free(self.actor_name);
        alloc.destroy(self);
    }
};

pub const TunnelHub = struct {
    alloc: Allocator,
    io: Io,

    mu: Io.Mutex = .init,

    runners: std.ArrayListUnmanaged(*RunnerConn) = .empty,
    sessions: std.AutoHashMapUnmanaged(Id128, *Session) = .empty,

    prng: *std.Random.Xoshiro256,

    pub fn init(
        alloc: Allocator,
        io: Io,
        prng: *std.Random.Xoshiro256,
    ) TunnelHub {
        return .{ .alloc = alloc, .io = io, .prng = prng };
    }

    pub fn deinit(self: *TunnelHub) void {
        var it = self.sessions.iterator();
        while (it.next()) |kv| kv.value_ptr.*.destroy(self.alloc);
        self.sessions.deinit(self.alloc);
        self.runners.deinit(self.alloc);
    }

    pub fn asRef(self: *TunnelHub) *HubRef {
        return @ptrCast(self);
    }

    pub fn fromRef(ref: *HubRef) *TunnelHub {
        return @ptrCast(@alignCast(ref));
    }

    // ─── Runner lifecycle ──────────────────────────────────────────

    pub fn registerRunner(self: *TunnelHub, rc: *RunnerConn) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        try self.runners.append(self.alloc, rc);
        log.info("runner registered ({d} total)", .{self.runners.items.len});
    }

    pub fn unregisterRunner(self: *TunnelHub, rc: *RunnerConn) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.runners.items, 0..) |r, i| {
            if (r == rc) {
                _ = self.runners.orderedRemove(i);
                log.info("runner unregistered", .{});
                return;
            }
        }
    }

    // ─── Session lookup ────────────────────────────────────────────

    /// Resume an existing session by hex sid. Returns null if no match.
    pub fn sessionByHex(self: *TunnelHub, hex: []const u8) ?*Session {
        if (hex.len != 32) return null;
        var id: Id128 = undefined;
        _ = std.fmt.hexToBytes(&id, hex) catch return null;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.sessions.get(id);
    }

    // ─── Session creation ──────────────────────────────────────────

    /// Find a live runner that handles `actor`. Caller must hold hub mu.
    fn findRunnerLocked(self: *TunnelHub, actor: []const u8) ?*RunnerConn {
        for (self.runners.items) |rc| {
            if (!rc.registered) continue;
            if (rc.dead.load(.acquire)) continue;
            for (rc.actors) |a| {
                if (std.mem.eql(u8, a, actor)) return rc;
            }
        }
        return null;
    }

    /// Mint a fresh session for `actor`. Picks the first live runner
    /// that handles the actor class, allocates an id, and blocks
    /// awaiting the runner's ActorStart reply. The returned Session
    /// lives for the runner's lifetime and is owned by the hub.
    pub fn newSession(self: *TunnelHub, actor: []const u8) HubError!*Session {
        var rc: *RunnerConn = undefined;
        var id: Id128 = undefined;
        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            rc = self.findRunnerLocked(actor) orelse return HubError.NoRunnerForActor;
            var rng = self.prng.random();
            id = idmod.generate(self.io, &rng);
        }

        // Allocate Session outside the hub lock.
        var sess_slot: ?*Session = self.alloc.create(Session) catch return HubError.OutOfMemory;
        defer if (sess_slot) |s| self.alloc.destroy(s);

        var actor_slot: ?[]u8 = self.alloc.dupe(u8, actor) catch return HubError.OutOfMemory;
        defer if (actor_slot) |s| self.alloc.free(s);

        const sess = sess_slot.?;
        sess.* = .{
            .id = id,
            .id_hex = undefined,
            .actor_name = actor_slot.?,
            .runner = rc,
            .state = .starting,
        };
        writeHex(&sess.id_hex, id);

        // Send ActorStart and block on reply.
        const body = messages.encodeActorStart(self.alloc, .{
            .session_id = &sess.id_hex,
            .actor_name = sess.actor_name,
            .reason = .create,
        }) catch return HubError.OutOfMemory;
        defer self.alloc.free(body);

        const result = rc.rpc(.actor_start, body) catch |e| {
            log.warn("actor_start rpc: {}", .{e});
            return HubError.ActorStartFailed;
        };
        defer if (result.body) |b| self.alloc.free(b);
        if (result.kind != .ok) return HubError.ActorStartFailed;

        sess.state = .ready;

        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            try self.sessions.put(self.alloc, id, sess);
        }

        log.info("session started: actor={s} sid={s}", .{ sess.actor_name, sess.id_hex[0..16] });

        // Ownership transferred.
        actor_slot = null;
        sess_slot = null;
        return sess;
    }

    // ─── Connection lifecycle ──────────────────────────────────────

    pub fn attachConnection(self: *TunnelHub, sess: *Session, conn: *ClientConnection) !void {
        sess.connections_mu.lockUncancelable(self.io);
        defer sess.connections_mu.unlock(self.io);
        try sess.connections.append(self.alloc, conn);
        log.info("connection attached: sid={s} cid={s} total={d}", .{
            sess.id_hex[0..16], conn.id, sess.connections.items.len,
        });
    }

    pub fn detachConnection(self: *TunnelHub, sess: *Session, conn: *ClientConnection) void {
        sess.connections_mu.lockUncancelable(self.io);
        defer sess.connections_mu.unlock(self.io);
        for (sess.connections.items, 0..) |c, i| {
            if (c == conn) {
                _ = sess.connections.orderedRemove(i);
                log.info("connection detached: sid={s} cid={s} remaining={d}", .{
                    sess.id_hex[0..16], conn.id, sess.connections.items.len,
                });
                return;
            }
        }
    }

    /// Route a runner-originated ConnectionMessage to the right client
    /// connection(s). When `connection_id == "*"`, fan out to all
    /// connections whose id is not listed in `except_ids`; otherwise
    /// deliver to the single matching connection.
    pub fn routeConnectionMessage(
        self: *TunnelHub,
        sid_hex: []const u8,
        connection_id: []const u8,
        is_text: bool,
        data: []const u8,
        except_ids: []const []const u8,
    ) void {
        const sess = self.sessionByHex(sid_hex) orelse {
            log.warn("routeConnectionMessage: unknown sid={s}", .{sid_hex});
            return;
        };

        var snapshot: std.ArrayListUnmanaged(*ClientConnection) = .empty;
        defer snapshot.deinit(self.alloc);

        {
            sess.connections_mu.lockUncancelable(self.io);
            defer sess.connections_mu.unlock(self.io);
            snapshot.ensureTotalCapacity(self.alloc, sess.connections.items.len) catch return;
            for (sess.connections.items) |c| snapshot.appendAssumeCapacity(c);
        }

        const broadcast = std.mem.eql(u8, connection_id, "*");
        var sent: usize = 0;
        for (snapshot.items) |c| {
            if (broadcast) {
                if (isExcluded(&c.id, except_ids)) continue;
            } else {
                if (!std.mem.eql(u8, connection_id, &c.id)) continue;
            }
            if (c.writeWsFrame(is_text, data)) sent += 1;
        }
        log.info("routeConnectionMessage sid={s} cid={s} delivered={d}", .{
            sid_hex[0..16], connection_id, sent,
        });
    }
};

fn writeHex(dst: *[32]u8, id: Id128) void {
    const hex_chars = "0123456789abcdef";
    for (id, 0..) |b, i| {
        dst[i * 2] = hex_chars[b >> 4];
        dst[i * 2 + 1] = hex_chars[b & 0x0F];
    }
}

fn isExcluded(connection_id_hex: []const u8, except_ids: []const []const u8) bool {
    for (except_ids) |ex| {
        if (std.mem.eql(u8, ex, connection_id_hex)) return true;
    }
    return false;
}

// ─── tests ────────────────────────────────────────────────────────────

test "newSession with no runner: NoRunnerForActor" {
    const alloc = std.testing.allocator;
    var xoshiro = std.Random.Xoshiro256.init(1);
    var hub = TunnelHub.init(alloc, std.Io.Threaded.global_single_threaded.io(), &xoshiro);
    defer hub.deinit();

    try std.testing.expectError(HubError.NoRunnerForActor, hub.newSession("echo"));
}

test "sessionByHex returns null for unknown sid" {
    const alloc = std.testing.allocator;
    var xoshiro = std.Random.Xoshiro256.init(1);
    var hub = TunnelHub.init(alloc, std.Io.Threaded.global_single_threaded.io(), &xoshiro);
    defer hub.deinit();
    try std.testing.expect(hub.sessionByHex("00000000000000000000000000000000") == null);
}

test "sessionByHex rejects malformed hex" {
    const alloc = std.testing.allocator;
    var xoshiro = std.Random.Xoshiro256.init(1);
    var hub = TunnelHub.init(alloc, std.Io.Threaded.global_single_threaded.io(), &xoshiro);
    defer hub.deinit();
    try std.testing.expect(hub.sessionByHex("not hex at all") == null);
    try std.testing.expect(hub.sessionByHex("deadbeef") == null);
}

test "writeHex produces lowercase" {
    var dst: [32]u8 = undefined;
    writeHex(&dst, [_]u8{ 0xAB, 0xCD } ++ [_]u8{0} ** 14);
    try std.testing.expectEqualStrings("abcd", dst[0..4]);
}
