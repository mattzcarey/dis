//! ClientConnection — one per connected client WebSocket that's bound
//! to a session.
//!
//! Owns the outbound side of the client TCP stream (reads happen from
//! the client-WS forwarder task; they don't contend with writes). A
//! separate write mutex serialises writes coming from fan-out (multiple
//! connections, broadcast) against reads from the session.
//!
//! Lifecycle:
//!   - Created in the HTTP/WS upgrade handler after `ensureSession`.
//!   - Registered on the session's connection list.
//!   - The handler runs a read loop forwarding WsFrame tunnel messages
//!     to the runner.
//!   - On EOF/close, handler calls `session.removeConnection(conn)` and
//!     `conn.destroy()` before returning to the connection group.

const std = @import("std");
const log = @import("log").scoped("conn");

const ws_frame = @import("../ws/frame.zig");

const Io = std.Io;

pub const READ_BUF = 8 * 1024;
pub const PAYLOAD_BUF = 128 * 1024;
pub const WRITE_BUF = 16 * 1024;

pub const ClientConnection = struct {
    alloc: std.mem.Allocator,
    io: Io,

    /// 16-char hex id assigned at creation. Referenced from the SDK as
    /// the stable connection handle.
    id: [16]u8,

    /// Session this connection belongs to. Set at registration time.
    session_id_hex: [32]u8,

    stream: std.Io.net.Stream,
    read_buf: []u8,
    payload_buf: []u8,
    write_buf: []u8,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,

    write_mu: Io.Mutex = .init,
    dead: std.atomic.Value(bool) = .init(false),

    pub fn create(
        alloc: std.mem.Allocator,
        io: Io,
        stream: std.Io.net.Stream,
        id: [16]u8,
        session_id_hex: [32]u8,
    ) !*ClientConnection {
        const self = try alloc.create(ClientConnection);
        errdefer alloc.destroy(self);

        const rb = try alloc.alloc(u8, READ_BUF);
        errdefer alloc.free(rb);
        const pb = try alloc.alloc(u8, PAYLOAD_BUF);
        errdefer alloc.free(pb);
        const wb = try alloc.alloc(u8, WRITE_BUF);
        errdefer alloc.free(wb);

        self.* = .{
            .alloc = alloc,
            .io = io,
            .id = id,
            .session_id_hex = session_id_hex,
            .stream = stream,
            .read_buf = rb,
            .payload_buf = pb,
            .write_buf = wb,
            .reader = std.Io.net.Stream.Reader.init(stream, io, rb),
            .writer = undefined,
        };
        self.writer = std.Io.net.Stream.Writer.init(stream, io, wb);
        return self;
    }

    pub fn destroy(self: *ClientConnection) void {
        self.stream.close(self.io);
        self.alloc.free(self.read_buf);
        self.alloc.free(self.payload_buf);
        self.alloc.free(self.write_buf);
        self.alloc.destroy(self);
    }

    pub fn markDead(self: *ClientConnection) void {
        self.dead.store(true, .release);
    }

    /// Write a text or binary WS frame to the client. Serialised by
    /// `write_mu`. Returns false if the connection is already dead.
    pub fn writeWsFrame(self: *ClientConnection, is_text: bool, data: []const u8) bool {
        if (self.dead.load(.acquire)) return false;
        var scratch: [10]u8 = undefined;

        self.write_mu.lockUncancelable(self.io);
        defer self.write_mu.unlock(self.io);

        const w = &self.writer.interface;
        const opcode: ws_frame.Opcode = if (is_text) .text else .binary;
        ws_frame.writeFrame(w, &scratch, true, opcode, data) catch {
            self.markDead();
            return false;
        };
        w.flush() catch {
            self.markDead();
            return false;
        };
        return true;
    }

    /// Send a WS close frame to the client, best-effort.
    pub fn writeClose(self: *ClientConnection, code: u16, reason: []const u8) void {
        if (self.dead.load(.acquire)) return;
        var scratch: [10]u8 = undefined;
        var payload_buf: [128]u8 = undefined;
        const payload_len = 2 + @min(reason.len, payload_buf.len - 2);
        std.mem.writeInt(u16, payload_buf[0..2], code, .big);
        @memcpy(payload_buf[2..payload_len], reason[0 .. payload_len - 2]);

        self.write_mu.lockUncancelable(self.io);
        defer self.write_mu.unlock(self.io);

        const w = &self.writer.interface;
        ws_frame.writeFrame(w, &scratch, true, .close, payload_buf[0..payload_len]) catch {
            self.markDead();
            return;
        };
        w.flush() catch self.markDead();
    }
};

/// Build a 16-char lowercase hex id from 8 random bytes.
pub fn makeConnectionId(rand: *std.Random) [16]u8 {
    var bytes: [8]u8 = undefined;
    rand.bytes(&bytes);
    return bytesToHex(bytes);
}

fn bytesToHex(bytes: [8]u8) [16]u8 {
    var out: [16]u8 = undefined;
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0F];
    }
    return out;
}

// ─── tests ───────────────────────────────────────────────────────────

test "makeConnectionId produces lowercase hex" {
    var xoshiro = std.Random.Xoshiro256.init(42);
    var rand = xoshiro.random();
    const id = makeConnectionId(&rand);
    for (id) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(ok);
    }
}
