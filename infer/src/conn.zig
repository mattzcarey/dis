//! Per-connection read/dispatch loop for dis-infer.
//!
//! Each accepted unix-socket connection runs one of these. The engine
//! is the only expected peer; the server is nevertheless written as a
//! multi-accept loop so we can reconnect transparently during dev (and
//! run multiple engines against one infer process in future).
//!
//! Layout:
//!   - `Conn.run` owns the TCP stream. It reads frames in a tight loop
//!     and feeds them to `handlers.dispatch`.
//!   - `StreamSink` is backed by `Conn.writeFrameLocked`, which takes
//!     `write_mu` so streaming token frames don't interleave with an
//!     unrelated reply.
//!
//! Lifecycle: the loop exits on read/write error or peer EOF; `main.zig`
//! reaps it and keeps accepting.

const std = @import("std");
const log = @import("log").scoped("infer.conn");

const frames = @import("frames.zig");
const handlers = @import("handlers.zig");
const messages = @import("messages.zig");

const Io = std.Io;

pub const READ_BUF = 64 * 1024;
pub const WRITE_BUF = 64 * 1024;
/// Hard cap on the body payload buffer (scratch) we keep per-conn.
/// Requests above this land in a one-shot malloc.
pub const PAYLOAD_SCRATCH = 256 * 1024;

pub const Conn = struct {
    alloc: std.mem.Allocator,
    io: Io,
    stream: std.Io.net.Stream,

    read_buf: []u8,
    write_buf: []u8,
    payload_scratch: []u8,

    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,

    write_mu: Io.Mutex = .init,
    dead: std.atomic.Value(bool) = .init(false),

    state: handlers.State,

    pub fn create(alloc: std.mem.Allocator, io: Io, stream: std.Io.net.Stream) !*Conn {
        const self = try alloc.create(Conn);
        errdefer alloc.destroy(self);

        const rb = try alloc.alloc(u8, READ_BUF);
        errdefer alloc.free(rb);
        const wb = try alloc.alloc(u8, WRITE_BUF);
        errdefer alloc.free(wb);
        const ps = try alloc.alloc(u8, PAYLOAD_SCRATCH);
        errdefer alloc.free(ps);

        self.* = .{
            .alloc = alloc,
            .io = io,
            .stream = stream,
            .read_buf = rb,
            .write_buf = wb,
            .payload_scratch = ps,
            .reader = std.Io.net.Stream.Reader.init(stream, io, rb),
            .writer = undefined,
            .state = handlers.State.init(alloc),
        };
        self.writer = std.Io.net.Stream.Writer.init(stream, io, wb);
        return self;
    }

    pub fn destroy(self: *Conn) void {
        self.stream.close(self.io);
        self.state.deinit();
        self.alloc.free(self.read_buf);
        self.alloc.free(self.write_buf);
        self.alloc.free(self.payload_scratch);
        self.alloc.destroy(self);
    }

    /// Run the read/dispatch loop to completion. Returns on peer EOF,
    /// read/write error, or unrecoverable framing violation.
    pub fn run(self: *Conn) void {
        var sink_state: SinkState = .{ .conn = self };
        var sink: handlers.StreamSink = .{
            .ctx = @ptrCast(&sink_state),
            .writeFrameFn = SinkState.writeThunk,
        };

        const r = &self.reader.interface;

        while (true) {
            const hdr = frames.readHeader(r) catch |e| {
                // EndOfStream on a clean disconnect is expected.
                if (e != frames.FrameError.ShortRead) {
                    log.warn("read header: {}", .{e});
                }
                return;
            };

            // Acquire body buffer — use scratch if it fits, else one-off.
            var owned_body: ?[]u8 = null;
            defer if (owned_body) |b| self.alloc.free(b);
            const body: []u8 = if (hdr.len == 0)
                &.{}
            else if (hdr.len <= self.payload_scratch.len)
                self.payload_scratch[0..hdr.len]
            else blk: {
                const b = self.alloc.alloc(u8, hdr.len) catch {
                    log.warn("oom allocating {d}B body", .{hdr.len});
                    return;
                };
                owned_body = b;
                break :blk b;
            };

            frames.readBody(r, body) catch |e| {
                log.warn("read body: {}", .{e});
                return;
            };

            const handled = handlers.dispatch(&self.state, &sink, hdr.kind, hdr.tag, body) catch |e| {
                log.warn("handler error: {}", .{e});
                self.writeError(hdr.tag, "internal", @errorName(e));
                continue;
            };
            if (!handled) {
                log.warn("unknown opcode 0x{X:0>2} (tag={d})", .{ @intFromEnum(hdr.kind), hdr.tag });
                self.writeError(hdr.tag, "unknown_op", "opcode not implemented");
            }
        }
    }

    /// Write a single framed message. Serialised by `write_mu` so
    /// concurrent streamers don't interleave bytes mid-frame.
    pub fn writeFrameLocked(
        self: *Conn,
        kind: frames.Opcode,
        tag: u32,
        body: []const u8,
    ) !void {
        if (self.dead.load(.acquire)) return error.ConnectionDead;
        self.write_mu.lockUncancelable(self.io);
        defer self.write_mu.unlock(self.io);
        const w = &self.writer.interface;
        frames.writeFrame(w, kind, tag, body) catch |e| {
            self.dead.store(true, .release);
            return e;
        };
    }

    fn writeError(self: *Conn, tag: u32, code: []const u8, msg: []const u8) void {
        const body = messages.encodeError(self.alloc, .{ .code = code, .message = msg }) catch return;
        defer self.alloc.free(body);
        self.writeFrameLocked(.err, tag, body) catch |e| {
            log.warn("write error frame: {}", .{e});
        };
    }
};

/// Adapter from `handlers.StreamSink` → `Conn.writeFrameLocked`.
/// Lives on the stack of `Conn.run` (lifetime scoped to the loop).
const SinkState = struct {
    conn: *Conn,

    fn writeThunk(ctx: *anyopaque, kind: frames.Opcode, tag: u32, body: []const u8) anyerror!void {
        const self: *SinkState = @ptrCast(@alignCast(ctx));
        return self.conn.writeFrameLocked(kind, tag, body);
    }
};
