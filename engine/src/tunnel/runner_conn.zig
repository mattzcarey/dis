//! One per connected runner process.
//!
//! Owns the long-lived WS stream + buffered Reader/Writer, runs the
//! frame-read loop, serialises outbound writes with a mutex, and keeps
//! a correlation-tag map for engine-initiated RPCs awaiting replies.
//!
//! Concurrency model:
//!   - The reader loop owns the Reader; only the loop thread/task reads.
//!   - Any task may send outbound frames via `sendOneWay` / `rpc`; they
//!     all take `write_mu` before touching the Writer so frames don't
//!     interleave at the byte level.
//!   - Pending map is protected by `pending_mu`. Inserts happen on the
//!     sender task; deletes + wakeups happen on the reader task.
//!   - `dead` is an atomic bool checked by senders to short-circuit once
//!     the connection has been torn down.

const std = @import("std");
const log = @import("log").scoped("runner");

const ws_frame = @import("../ws/frame.zig");
const frames = @import("frames.zig");
const messages = @import("messages.zig");
const cbor = @import("cbor");
const Pending = @import("pending.zig").Pending;
const DeliveryKind = @import("pending.zig").DeliveryKind;
const gen_stub = @import("../generate/stub.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Opcode = frames.Opcode;

pub const RunnerError = error{
    Dead,
    TagInUse,
    WriteFailed,
    OutOfMemory,
};

pub const RpcResult = struct {
    kind: DeliveryKind,
    body: ?[]u8, // caller must free via `alloc`
};

const READ_BUF = 16 * 1024; // Reader's internal buffer (header + staging)
const PAYLOAD_BUF = 256 * 1024; // WS frame payload destination
const WRITE_BUF = 16 * 1024;

/// Forward-declared: full hub lives in hub.zig. Only the back-pointer
/// matters here; we don't call into it from RunnerConn while holding
/// our own locks, to keep lock ordering simple (hub → runner, never
/// runner → hub under our lock).
pub const HubRef = opaque {};

/// Thin v-table for the subset of hub functions RunnerConn calls on
/// inbound runner-initiated frames. Breaks the import cycle between
/// runner_conn.zig and hub.zig.
pub const HubCalls = struct {
    routeConnectionMessage: *const fn (
        ref: *HubRef,
        sid_hex: []const u8,
        connection_id: []const u8,
        is_text: bool,
        data: []const u8,
        except_ids: []const []const u8,
    ) void,
};

var hub_calls: HubCalls = undefined;
var hub_calls_installed: bool = false;

/// Call once at runtime startup to wire in the hub dispatch functions.
pub fn installHubCalls(calls: HubCalls) void {
    hub_calls = calls;
    hub_calls_installed = true;
}

pub const RunnerConn = struct {
    alloc: Allocator,
    io: Io,
    hub: *HubRef,

    // ── Stream + buffered reader/writer ────────────────────────────
    stream: std.Io.net.Stream,
    read_buf: []u8, // Reader's internal buffer
    payload_buf: []u8, // WS frame payload destination (separate — can't alias read_buf)
    write_buf: []u8,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,

    // ── Registration (filled on RunnerReady) ───────────────────────
    actors: [][]const u8 = &.{}, // owned; each string heap-duped
    max_slots: u32 = 0,
    registered: bool = false,

    // ── Write path ─────────────────────────────────────────────────
    write_mu: Io.Mutex = .init,

    // ── Pending RPCs ───────────────────────────────────────────────
    pending_mu: Io.Mutex = .init,
    pending: std.AutoHashMapUnmanaged(u32, *Pending) = .empty,
    next_tag: std.atomic.Value(u32) = .init(1),

    // ── Lifecycle ──────────────────────────────────────────────────
    dead: std.atomic.Value(bool) = .init(false),

    /// Holds per-inbound-op worker tasks (stub generators, etc.) so the
    /// reader loop never blocks on long-running work.
    work_group: Io.Group = .init,

    /// Callback invoked by the reader loop on RunnerReady, before the
    /// loop continues. Lets the hub register the connection under its
    /// namespace and kick off any bootstrap actions. Runs on the reader
    /// task. Returning an error terminates the loop.
    on_ready: ?*const fn (rc: *RunnerConn, ctx: ?*anyopaque) anyerror!void = null,
    on_ready_ctx: ?*anyopaque = null,

    /// Callback invoked when the reader loop exits (graceful or error).
    /// Lets the hub unregister. After this returns, the connection is
    /// destroyed.
    on_close: ?*const fn (rc: *RunnerConn, ctx: ?*anyopaque) void = null,
    on_close_ctx: ?*anyopaque = null,

    // ── Construction / destruction ─────────────────────────────────

    pub fn create(
        alloc: Allocator,
        io: Io,
        hub: *HubRef,
        stream: std.Io.net.Stream,
    ) !*RunnerConn {
        const self = try alloc.create(RunnerConn);
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
            .hub = hub,
            .stream = stream,
            .read_buf = rb,
            .payload_buf = pb,
            .write_buf = wb,
            .reader = std.Io.net.Stream.Reader.init(stream, io, rb),
            .writer = undefined, // set below — Writer type not available here as a zero-arg init
        };
        // Initialise Writer in-place. Writer.init returns a value; we set
        // it on the struct after the reader so the Reader's interface
        // fieldParentPtr targets a stable address.
        self.writer = streamWriter(stream, io, wb);
        return self;
    }

    pub fn destroy(self: *RunnerConn) void {
        // Drain any outstanding worker tasks (e.g. in-flight stub
        // generators) so they don't run after we free the connection.
        self.work_group.await(self.io) catch {};

        // Cancel any pending RPCs still waiting.
        self.cancelAllPending();
        // Free the pending map (keys & values are already drained).
        self.pending.deinit(self.alloc);

        for (self.actors) |a| self.alloc.free(a);
        if (self.actors.len > 0) self.alloc.free(self.actors);

        self.stream.close(self.io);
        self.alloc.free(self.read_buf);
        self.alloc.free(self.payload_buf);
        self.alloc.free(self.write_buf);
        self.alloc.destroy(self);
    }

    // ── Writes ─────────────────────────────────────────────────────

    pub fn allocTag(self: *RunnerConn) u32 {
        while (true) {
            const t = self.next_tag.fetchAdd(1, .monotonic);
            if (t != 0) return t;
        }
    }

    /// Send a single tunnel frame, no reply expected. Thread-safe.
    pub fn sendOneWay(
        self: *RunnerConn,
        kind: Opcode,
        tag: u32,
        body: []const u8,
    ) RunnerError!void {
        if (self.dead.load(.acquire)) return RunnerError.Dead;

        const frame_bytes = frames.encode(self.alloc, kind, tag, body) catch return RunnerError.OutOfMemory;
        defer self.alloc.free(frame_bytes);

        var scratch: [10]u8 = undefined;

        self.write_mu.lockUncancelable(self.io);
        defer self.write_mu.unlock(self.io);

        const w = &self.writer.interface;
        ws_frame.writeFrame(w, &scratch, true, .binary, frame_bytes) catch {
            self.markDead();
            return RunnerError.WriteFailed;
        };
        w.flush() catch {
            self.markDead();
            return RunnerError.WriteFailed;
        };
    }

    /// Send a frame with a freshly-allocated tag, register a Pending,
    /// and block until the reply arrives. Returned body (if any) is
    /// heap-allocated; caller frees via `self.alloc`.
    pub fn rpc(self: *RunnerConn, kind: Opcode, body: []const u8) RunnerError!RpcResult {
        if (self.dead.load(.acquire)) return RunnerError.Dead;

        const tag = self.allocTag();
        const p = try self.alloc.create(Pending);
        p.* = Pending.init(self.alloc);

        {
            self.pending_mu.lockUncancelable(self.io);
            defer self.pending_mu.unlock(self.io);
            // Tags are u32-wide and wrap; in-flight duplicate is astronomically unlikely.
            const existing = self.pending.fetchPut(self.alloc, tag, p) catch {
                p.deinit();
                self.alloc.destroy(p);
                return RunnerError.OutOfMemory;
            };
            if (existing != null) {
                p.deinit();
                self.alloc.destroy(p);
                return RunnerError.TagInUse;
            }
        }

        // Send the frame. On send-failure, we must remove from pending
        // before returning so nobody tries to deliver to a freed Pending.
        self.sendOneWay(kind, tag, body) catch |e| {
            self.removePending(tag);
            p.deinit();
            self.alloc.destroy(p);
            return e;
        };

        const got = p.waitTake(self.io);
        // Reader already removed us from pending when it delivered.
        p.deinit();
        self.alloc.destroy(p);
        return .{ .kind = got.kind, .body = got.body };
    }

    fn removePending(self: *RunnerConn, tag: u32) void {
        self.pending_mu.lockUncancelable(self.io);
        defer self.pending_mu.unlock(self.io);
        _ = self.pending.remove(tag);
    }

    fn takePending(self: *RunnerConn, tag: u32) ?*Pending {
        self.pending_mu.lockUncancelable(self.io);
        defer self.pending_mu.unlock(self.io);
        if (self.pending.fetchRemove(tag)) |kv| return kv.value;
        return null;
    }

    fn cancelAllPending(self: *RunnerConn) void {
        // Drain the map under the lock, wake waiters outside.
        var victims: std.ArrayList(*Pending) = .empty;
        defer victims.deinit(self.alloc);

        {
            self.pending_mu.lockUncancelable(self.io);
            defer self.pending_mu.unlock(self.io);
            var it = self.pending.iterator();
            while (it.next()) |kv| {
                victims.append(self.alloc, kv.value_ptr.*) catch {
                    // Best-effort: we can't allocate, still try to cancel in place.
                    kv.value_ptr.*.cancel(self.io);
                };
            }
            self.pending.clearRetainingCapacity();
        }

        for (victims.items) |p| p.cancel(self.io);
    }

    fn markDead(self: *RunnerConn) void {
        self.dead.store(true, .release);
    }

    // ── Reader loop ────────────────────────────────────────────────

    /// Run the read loop until the connection dies. Caller spawned this
    /// on the accept handler task; on return the caller should
    /// `destroy()` the RunnerConn (or not — depends on who owns it).
    pub fn runReaderLoop(self: *RunnerConn) void {
        // Send Hello immediately so the runner's WsTunnel.ready()
        // unblocks.
        const hello_body = messages.encodeHello(self.alloc, .{
            .version = 1,
            .node_label = 1,
            .protocol = "dis/v0",
        }) catch |e| {
            log.warn("encode hello: {}", .{e});
            self.markDead();
            return;
        };
        defer self.alloc.free(hello_body);

        self.sendOneWay(.hello, 0, hello_body) catch |e| {
            log.warn("send hello: {}", .{e});
            self.markDead();
            return;
        };

        const r = &self.reader.interface;

        while (true) {
            const wsf = ws_frame.readFrame(r, self.payload_buf) catch |e| {
                log.info("runner ws read end: {}", .{e});
                self.markDead();
                return;
            };

            switch (wsf.opcode) {
                .close => {
                    log.info("runner sent close", .{});
                    self.markDead();
                    return;
                },
                .ping => {
                    // Echo pong, best-effort.
                    var scratch: [10]u8 = undefined;
                    self.write_mu.lockUncancelable(self.io);
                    defer self.write_mu.unlock(self.io);
                    const w = &self.writer.interface;
                    ws_frame.writeFrame(w, &scratch, true, .pong, wsf.payload) catch {
                        self.markDead();
                        return;
                    };
                    w.flush() catch {
                        self.markDead();
                        return;
                    };
                },
                .pong => {},
                .binary => self.dispatchInbound(wsf.payload),
                else => log.warn("unexpected runner opcode: {d}", .{@intFromEnum(wsf.opcode)}),
            }
        }
    }

    fn dispatchInbound(self: *RunnerConn, payload: []const u8) void {
        const tf = frames.decode(payload) catch |e| {
            log.warn("tunnel decode: {}", .{e});
            return;
        };

        switch (tf.kind) {
            .runner_ready => self.handleRunnerReady(tf.body),
            .ack, .result => self.deliverReply(tf.tag, .ok, tf.body),
            .err => self.deliverReply(tf.tag, .err, tf.body),
            .connection_message => self.handleConnectionMessage(tf.body),
            .connection_close => self.handleConnectionClose(tf.body),
            .generate => self.handleGenerate(tf.tag, tf.body),
            else => {
                // Other runner-initiated op (state, schedule, etc.). For
                // v0 we don't implement these yet; log and ack so the
                // runner doesn't wedge.
                log.info("runner-initiated op 0x{x:0>2} tag={d} (no handler yet)", .{
                    @intFromEnum(tf.kind), tf.tag,
                });
                const ack_body = [_]u8{0xF6}; // CBOR null
                self.sendOneWay(.ack, tf.tag, &ack_body) catch |e| {
                    log.warn("ack send failed: {}", .{e});
                };
            },
        }
    }

    fn handleGenerate(self: *RunnerConn, tag: u32, body: []const u8) void {
        const m = messages.decodeGenerate(body) catch |e| {
            log.warn("decode generate: {}", .{e});
            const err_body = messages.encodeError(self.alloc, .{
                .code = "DECODE_FAILED",
                .message = @errorName(e),
            }) catch return;
            defer self.alloc.free(err_body);
            self.sendOneWay(.err, tag, err_body) catch {};
            return;
        };

        // Caller needs owned copies — the CBOR body's byte slices live
        // in the reader's payload buffer and will be reused on the next
        // frame.
        const prompt = self.alloc.dupe(u8, m.prompt) catch {
            const err_body = messages.encodeError(self.alloc, .{
                .code = "OOM",
                .message = "dupe prompt",
            }) catch return;
            defer self.alloc.free(err_body);
            self.sendOneWay(.err, tag, err_body) catch {};
            return;
        };

        self.work_group.concurrent(self.io, runGenerateTask, .{
            self, tag, prompt, m.max_tokens,
        }) catch |e| {
            log.warn("spawn generate: {}", .{e});
            self.alloc.free(prompt);
            const err_body = messages.encodeError(self.alloc, .{
                .code = "SPAWN_FAILED",
                .message = @errorName(e),
            }) catch return;
            defer self.alloc.free(err_body);
            self.sendOneWay(.err, tag, err_body) catch {};
        };
    }

    fn handleConnectionMessage(self: *RunnerConn, body: []const u8) void {
        if (!hub_calls_installed) {
            log.warn("connection_message arrived but hub_calls not installed", .{});
            return;
        }
        var m = messages.decodeConnectionMessage(self.alloc, body) catch |e| {
            log.warn("decode connection_message: {}", .{e});
            return;
        };
        defer m.deinit(self.alloc);
        hub_calls.routeConnectionMessage(
            self.hub,
            m.session_id,
            m.connection_id,
            m.kind == .text,
            m.data,
            m.except_ids,
        );
    }

    fn handleConnectionClose(self: *RunnerConn, body: []const u8) void {
        const m = messages.decodeConnectionClose(body) catch |e| {
            log.warn("decode connection_close: {}", .{e});
            return;
        };
        _ = self; // v0: close dispatch not yet wired; lives in hub later.
        log.info("connection_close: sid={s} cid={s} code={d}", .{ m.session_id, m.connection_id, m.code });
    }

    fn deliverReply(self: *RunnerConn, tag: u32, kind: DeliveryKind, body: []const u8) void {
        const p = self.takePending(tag) orelse {
            log.warn("reply for unknown tag {d} (kind={s})", .{ tag, @tagName(kind) });
            return;
        };
        p.deliver(self.io, kind, body) catch |e| {
            log.warn("deliver pending: {}", .{e});
            p.cancel(self.io);
        };
    }

    fn handleRunnerReady(self: *RunnerConn, body: []const u8) void {
        if (self.registered) {
            log.warn("duplicate RunnerReady ignored", .{});
            return;
        }

        var decoded = messages.decodeRunnerReady(self.alloc, body) catch |e| {
            log.warn("decode RunnerReady: {}", .{e});
            return;
        };
        errdefer decoded.deinit(self.alloc);

        var actor_names = self.alloc.alloc([]const u8, decoded.actors.len) catch |e| {
            log.warn("alloc actor list: {}", .{e});
            return;
        };
        var filled: usize = 0;
        errdefer {
            for (actor_names[0..filled]) |a| self.alloc.free(a);
            self.alloc.free(actor_names);
        }
        for (decoded.actors, 0..) |a, i| {
            actor_names[i] = self.alloc.dupe(u8, a) catch |e| {
                log.warn("dupe actor: {}", .{e});
                return;
            };
            filled = i + 1;
        }
        decoded.deinit(self.alloc);

        self.actors = actor_names;
        self.max_slots = decoded.max_slots;
        self.registered = true;

        log.info("runner registered: actors={d} max_slots={d}", .{
            self.actors.len, self.max_slots,
        });

        if (self.on_ready) |cb| {
            cb(self, self.on_ready_ctx) catch |e| {
                log.warn("on_ready callback error: {}", .{e});
            };
        }
    }
};

// ─── Stream.Writer init helper ───────────────────────────────────────
// std.Io.net.Stream exposes an inline method but to avoid shape churn
// we wrap a small call here.

fn streamWriter(stream: std.Io.net.Stream, io: Io, buf: []u8) std.Io.net.Stream.Writer {
    return std.Io.net.Stream.Writer.init(stream, io, buf);
}

// ─── Generate task ────────────────────────────────────────────────────

fn runGenerateTask(
    rc: *RunnerConn,
    tag: u32,
    prompt: []u8,
    max_tokens: u32,
) Io.Cancelable!void {
    defer rc.alloc.free(prompt);
    gen_stub.streamStub(rc, rc.io, tag, prompt, max_tokens, gen_stub.DEFAULT_DELAY_MS);
}

// ─── tests ────────────────────────────────────────────────────────────

test "allocTag skips zero on wrap" {
    const alloc = std.testing.allocator;
    var rc: RunnerConn = undefined;
    rc.alloc = alloc;
    rc.next_tag = .init(std.math.maxInt(u32));
    const first = rc.allocTag();
    // fetchAdd returned maxInt(u32), next call wraps to 0, should skip.
    const second = rc.allocTag();
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), first);
    try std.testing.expectEqual(@as(u32, 1), second);
}
