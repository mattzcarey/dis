//! dis-engine HTTP entrypoint.
//!
//! One TCP listener. Each accepted connection is handed off to a
//! concurrent task from `rt.conn_group` so we can serve many runners
//! and clients in parallel.
//!
//! Routes:
//!   - WS upgrade /runner   → spawn a RunnerConn, run its reader loop
//!   - (future) WS upgrade /ws/:ns/:actor/:key → client router
//!   - GET /v1/health, /v1/node → canned JSON
//!
//! Anything else: 404.

const std = @import("std");
const log = @import("log").scoped("http");

const Runtime = @import("../runtime/runtime.zig").Runtime;
const request = @import("request.zig");
const handshake = @import("../ws/handshake.zig");
const ws_frame = @import("../ws/frame.zig");
const tunnel_frames = @import("../tunnel/frames.zig");
const RunnerConn = @import("../tunnel/runner_conn.zig").RunnerConn;
const hub_mod = @import("../tunnel/hub.zig");
const TunnelHub = hub_mod.TunnelHub;
const Session = hub_mod.Session;
const connection_mod = @import("../tunnel/connection.zig");
const ClientConnection = connection_mod.ClientConnection;
const messages = @import("../tunnel/messages.zig");
const route = @import("../util/route.zig");

const Io = std.Io;

const CANNED_OK =
    "HTTP/1.1 200 OK\r\n" ++
    "content-type: application/json\r\n" ++
    "content-length: 18\r\n" ++
    "connection: close\r\n" ++
    "\r\n" ++
    "{\"ok\":true,\"v\":0}";

const NOT_FOUND =
    "HTTP/1.1 404 Not Found\r\n" ++
    "content-type: text/plain\r\n" ++
    "content-length: 10\r\n" ++
    "connection: close\r\n" ++
    "\r\n" ++
    "not found\n";

const MAX_HEAD_LEN = 16 * 1024;

pub const Server = struct {
    alloc: std.mem.Allocator,
    io: Io,
    rt: *Runtime,
    listener: std.Io.net.Server,

    pub fn init(alloc: std.mem.Allocator, io: Io, rt: *Runtime) !Server {
        const addr = try parseBind(rt.cfg.bind);
        const listener = try std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true });
        log.info("listening on {s}", .{rt.cfg.bind});
        return .{ .alloc = alloc, .io = io, .rt = rt, .listener = listener };
    }

    pub fn deinit(self: *Server) void {
        self.listener.deinit(self.io);
    }

    pub fn serve(self: *Server) !void {
        while (true) {
            const stream = self.listener.accept(self.io) catch |e| {
                log.warn("accept: {}", .{e});
                continue;
            };
            // Spawn concurrently; we don't hold a Future.
            self.rt.conn_group.concurrent(
                self.io,
                handleConn,
                .{ self.rt, stream },
            ) catch |e| {
                log.warn("spawn handler: {}", .{e});
                stream.close(self.io);
            };
        }
    }
};

/// Per-connection handler. Spawned on the runtime's conn_group.
fn handleConn(rt: *Runtime, stream_in: std.Io.net.Stream) Io.Cancelable!void {
    var stream = stream_in;
    var stream_owned = true;
    defer if (stream_owned) stream.close(rt.io);

    var read_buf: [MAX_HEAD_LEN]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var reader = std.Io.net.Stream.Reader.init(stream, rt.io, &read_buf);
    var writer = std.Io.net.Stream.Writer.init(stream, rt.io, &write_buf);
    const r = &reader.interface;
    const w = &writer.interface;

    // Accumulate bytes until the head terminator appears in the buffer.
    var head_slice: []const u8 = undefined;
    while (true) {
        const buf = r.buffered();
        if (std.mem.indexOf(u8, buf, "\r\n\r\n")) |end_rel| {
            head_slice = buf[0 .. end_rel + 4];
            break;
        }
        if (buf.len >= MAX_HEAD_LEN) {
            log.warn("head exceeds {d} bytes", .{MAX_HEAD_LEN});
            return;
        }
        _ = r.peek(buf.len + 1) catch |e| {
            log.info("peek head end: {}", .{e});
            return;
        };
    }

    var req = request.parse(rt.alloc, head_slice) catch |e| {
        log.warn("parse: {}", .{e});
        w.writeAll("HTTP/1.1 400 Bad Request\r\nconnection: close\r\ncontent-length: 0\r\n\r\n") catch {};
        w.flush() catch {};
        return;
    };
    defer req.deinit(rt.alloc);
    r.toss(req.head_len);

    if (std.mem.eql(u8, req.target, "/runner")) {
        // WS upgrade: after this, the RunnerConn takes ownership of the
        // stream and runs until WS closes.
        stream_owned = false;
        handleRunnerUpgrade(rt, stream, req, w) catch |e| {
            log.warn("runner upgrade: {}", .{e});
        };
        return;
    }

    if (std.mem.startsWith(u8, req.target, "/v1/ws/")) {
        stream_owned = false;
        handleClientWs(rt, stream, req, w) catch |e| {
            log.warn("client ws: {}", .{e});
        };
        return;
    }

    if (std.mem.eql(u8, req.target, "/v1/health") or std.mem.eql(u8, req.target, "/v1/node")) {
        w.writeAll(CANNED_OK) catch {};
    } else {
        w.writeAll(NOT_FOUND) catch {};
    }
    w.flush() catch {};
}

fn handleRunnerUpgrade(
    rt: *Runtime,
    stream: std.Io.net.Stream,
    req: request.Request,
    w: *std.Io.Writer,
) !void {
    const accept = handshake.acceptKey(rt.alloc, req) catch |e| {
        log.warn("ws handshake reject: {}", .{e});
        w.writeAll("HTTP/1.1 400 Bad Request\r\nconnection: close\r\ncontent-length: 0\r\n\r\n") catch {};
        w.flush() catch {};
        stream.close(rt.io);
        return;
    };
    defer rt.alloc.free(accept);

    const response = try handshake.renderResponse(rt.alloc, accept);
    defer rt.alloc.free(response);
    try w.writeAll(response);
    try w.flush();

    // Create the RunnerConn. It takes ownership of `stream`.
    const rc = try RunnerConn.create(rt.alloc, rt.io, rt.hub.asRef(), stream);

    rc.on_ready = onRunnerReady;
    rc.on_ready_ctx = @ptrCast(rt);

    rc.on_close = onRunnerClose;
    rc.on_close_ctx = @ptrCast(rt);

    log.info("runner ws accepted; running reader loop", .{});
    rc.runReaderLoop();

    // Reader loop exited — tear down.
    if (rc.on_close) |cb| cb(rc, rc.on_close_ctx);
    rc.destroy();
}

// ─── Client WS ──────────────────────────────────────────────────────

fn handleClientWs(
    rt: *Runtime,
    stream: std.Io.net.Stream,
    req: request.Request,
    w: *std.Io.Writer,
) !void {
    // Parse the route: /v1/ws/:actor (optionally ?sid=<hex>)
    var scratch: [256]u8 = undefined;
    const r = route.parseWs(req.target, &scratch) catch |e| {
        log.warn("route parse: {}", .{e});
        w.writeAll("HTTP/1.1 400 Bad Request\r\nconnection: close\r\ncontent-length: 0\r\n\r\n") catch {};
        w.flush() catch {};
        stream.close(rt.io);
        return;
    };

    // Resume or mint.
    var sess: *hub_mod.Session = undefined;
    var resumed = false;
    if (r.sid) |sid_hex| {
        sess = rt.hub.sessionByHex(sid_hex) orelse {
            log.warn("sid not found: {s}", .{sid_hex});
            w.writeAll("HTTP/1.1 404 Not Found\r\ncontent-type: application/json\r\ncontent-length: 36\r\nconnection: close\r\n\r\n{\"error\":\"session not found\"}\n") catch {};
            w.flush() catch {};
            stream.close(rt.io);
            return;
        };
        if (!std.mem.eql(u8, sess.actor_name, r.actor)) {
            log.warn("sid actor mismatch: got {s} want {s}", .{ sess.actor_name, r.actor });
            w.writeAll("HTTP/1.1 409 Conflict\r\nconnection: close\r\ncontent-length: 0\r\n\r\n") catch {};
            w.flush() catch {};
            stream.close(rt.io);
            return;
        }
        resumed = true;
    } else {
        sess = rt.hub.newSession(r.actor) catch |e| {
            log.warn("newSession: {}", .{e});
            w.writeAll("HTTP/1.1 503 Service Unavailable\r\nconnection: close\r\ncontent-length: 0\r\n\r\n") catch {};
            w.flush() catch {};
            stream.close(rt.io);
            return;
        };
    }

    // Complete the WS handshake with the client.
    const accept = handshake.acceptKey(rt.alloc, req) catch |e| {
        log.warn("client ws reject: {}", .{e});
        w.writeAll("HTTP/1.1 400 Bad Request\r\nconnection: close\r\ncontent-length: 0\r\n\r\n") catch {};
        w.flush() catch {};
        stream.close(rt.io);
        return;
    };
    defer rt.alloc.free(accept);

    const response = try handshake.renderResponse(rt.alloc, accept);
    defer rt.alloc.free(response);
    try w.writeAll(response);
    try w.flush();

    // Allocate a connection id + ClientConnection, attach to session.
    const connection_id = allocConnectionId(rt);
    const conn = try ClientConnection.create(rt.alloc, rt.io, stream, connection_id, sess.id_hex);
    defer conn.destroy();

    rt.hub.attachConnection(sess, conn) catch |e| {
        log.warn("attachConnection: {}", .{e});
        return;
    };
    defer rt.hub.detachConnection(sess, conn);

    log.info("client ws attached: sid={s} cid={s} resumed={}", .{
        sess.id_hex[0..16], conn.id, resumed,
    });

    // Send the OpenAI-style `session.created` / `session.resumed` event
    // as the very first WS message so clients can capture the sid.
    sendSessionEvent(conn, &sess.id_hex, sess.actor_name, resumed);

    // Run the inbound forward loop on this task.
    runClientReadLoop(rt, sess, conn) catch |e| {
        log.info("client ws loop end: {}", .{e});
    };
}

fn sendSessionEvent(conn: *ClientConnection, sid_hex: *const [32]u8, actor: []const u8, resumed: bool) void {
    var buf: [160]u8 = undefined;
    const ev = if (resumed) "session.resumed" else "session.created";
    const body = std.fmt.bufPrint(&buf, "{{\"type\":\"{s}\",\"sid\":\"{s}\",\"actor\":\"{s}\"}}", .{
        ev, sid_hex[0..], actor,
    }) catch return;
    _ = conn.writeWsFrame(true, body);
}

fn runClientReadLoop(rt: *Runtime, sess: *Session, conn: *ClientConnection) !void {
    const reader = &conn.reader.interface;
    while (true) {
        const wsf = ws_frame.readFrame(reader, conn.payload_buf) catch |e| {
            log.info("client read end: {}", .{e});
            conn.markDead();
            return;
        };
        switch (wsf.opcode) {
            .close => {
                log.info("client close frame", .{});
                conn.markDead();
                return;
            },
            .ping => {
                var scratch: [10]u8 = undefined;
                conn.write_mu.lockUncancelable(rt.io);
                defer conn.write_mu.unlock(rt.io);
                const wi = &conn.writer.interface;
                ws_frame.writeFrame(wi, &scratch, true, .pong, wsf.payload) catch {
                    conn.markDead();
                    return;
                };
                wi.flush() catch {
                    conn.markDead();
                    return;
                };
            },
            .pong => {},
            .text, .binary, .continuation => {
                // Forward to runner as a WsFrame tunnel message.
                const kind: messages.WsFrameKind = if (wsf.opcode == .text) .text else .binary;
                const body = try messages.encodeWsFrame(rt.alloc, .{
                    .session_id = &sess.id_hex,
                    .connection_id = &conn.id,
                    .kind = kind,
                    .data = wsf.payload,
                });
                defer rt.alloc.free(body);
                sess.runner.sendOneWay(.ws_frame, 0, body) catch |e| {
                    log.warn("forward to runner: {}", .{e});
                    // Runner is likely dead; bail.
                    conn.markDead();
                    return;
                };
            },
            else => log.warn("client unexpected opcode: {d}", .{@intFromEnum(wsf.opcode)}),
        }
    }
}

fn allocConnectionId(rt: *Runtime) [16]u8 {
    // Connection ids don't need to be globally unique — just unique
    // within a session. Use the runtime PRNG under the hub's mutex to
    // serialise.
    rt.hub.mu.lockUncancelable(rt.io);
    defer rt.hub.mu.unlock(rt.io);
    var rand = rt.prng.random();
    return connection_mod.makeConnectionId(&rand);
}

// ─── Runner lifecycle callbacks ─────────────────────────────────────

fn onRunnerReady(rc: *RunnerConn, ctx: ?*anyopaque) anyerror!void {
    const rt: *Runtime = @ptrCast(@alignCast(ctx.?));
    try rt.hub.registerRunner(rc);

    // Optional bootstrap: mint one session up-front. Spawned on a
    // separate task because newSession() blocks on a reply that arrives
    // on *this* (reader) task — would deadlock if called inline.
    if (rt.cfg.bootstrap_actor) |actor| {
        rt.conn_group.concurrent(rt.io, bootstrapTask, .{ rt, actor }) catch |e| {
            log.warn("spawn bootstrap: {}", .{e});
        };
    }
}

fn onRunnerClose(rc: *RunnerConn, ctx: ?*anyopaque) void {
    const rt: *Runtime = @ptrCast(@alignCast(ctx.?));
    rt.hub.unregisterRunner(rc);
}

fn bootstrapTask(rt: *Runtime, actor: []const u8) Io.Cancelable!void {
    log.info("bootstrap: minting session for actor={s}", .{actor});
    const sess = rt.hub.newSession(actor) catch |e| {
        log.warn("bootstrap newSession: {}", .{e});
        return;
    };
    log.info("bootstrap: sid={s}", .{sess.id_hex[0..16]});
}

// ─── Helpers ────────────────────────────────────────────────────────

fn parseBind(bind: []const u8) !std.Io.net.IpAddress {
    const last_colon = std.mem.lastIndexOfScalar(u8, bind, ':') orelse return error.InvalidBind;
    const host = bind[0..last_colon];
    const port = try std.fmt.parseInt(u16, bind[last_colon + 1 ..], 10);
    return std.Io.net.IpAddress.parse(host, port);
}

// ── tests ─────────────────────────────────────────────────────────────

test "parseBind localhost" {
    const addr = try parseBind("127.0.0.1:7070");
    _ = addr;
}

test "parseBind rejects missing port" {
    try std.testing.expectError(error.InvalidBind, parseBind("localhost"));
}
