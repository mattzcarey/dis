//! Opcode dispatch. Each inbound request frame is routed here by
//! `conn.zig`'s reader loop. Handlers return owned response bodies
//! (caller frees) or stream via the provided `StreamSink`.
//!
//! Prefill / decode_token drive real inference via `LlamaHost`.
//! Sessionless bookkeeping ops (alloc_seq, free_seq, kv_remove_range)
//! maintain an in-memory seq table so the engine can cross-reference
//! allocations, even though llama.cpp's sequence ids themselves are
//! currently managed inside a single context.

const std = @import("std");
const log = @import("log").scoped("infer.handle");
const cbor = @import("cbor");

const frames = @import("frames.zig");
const messages = @import("messages.zig");
const llama = @import("llama.zig");

const Opcode = frames.Opcode;
const Io = std.Io;

/// Per-connection state owned by `Conn`. Handlers mutate fields here
/// (seq table, loaded-model flag) but not the socket itself — writes
/// are funneled through `StreamSink.write*`.
pub const State = struct {
    alloc: std.mem.Allocator,
    llama: llama.LlamaHost,

    /// Next synthetic seq id. Real llama allocator is per-session in M2.
    next_seq_id: i32 = 1,
    /// Live synthetic seq ids, for validating FreeSeq / KvRemoveRange.
    live_seqs: std.AutoHashMapUnmanaged(i32, void) = .empty,

    pub fn init(alloc: std.mem.Allocator) State {
        return .{
            .alloc = alloc,
            .llama = llama.LlamaHost.init(alloc),
        };
    }

    pub fn deinit(self: *State) void {
        self.live_seqs.deinit(self.alloc);
        self.llama.deinit();
    }

    fn allocSeq(self: *State) !i32 {
        const id = self.next_seq_id;
        self.next_seq_id += 1;
        try self.live_seqs.put(self.alloc, id, {});
        return id;
    }

    fn freeSeq(self: *State, id: i32) bool {
        return self.live_seqs.remove(id);
    }

    fn hasSeq(self: *State, id: i32) bool {
        return self.live_seqs.contains(id);
    }
};

/// Abstract sink for streaming responses. A real `Conn` implements
/// this against the outbound socket writer (with write-mutex); tests
/// use an in-memory capture. Keeps handlers decoupled from the wire.
pub const StreamSink = struct {
    ctx: *anyopaque,
    /// Write a single non-streaming frame (result/ack/error).
    writeFrameFn: *const fn (ctx: *anyopaque, kind: Opcode, tag: u32, body: []const u8) anyerror!void,

    pub fn writeFrame(self: *StreamSink, kind: Opcode, tag: u32, body: []const u8) !void {
        return self.writeFrameFn(self.ctx, kind, tag, body);
    }

    pub fn writeResult(self: *StreamSink, tag: u32, body: []const u8) !void {
        return self.writeFrame(.result, tag, body);
    }

    pub fn writeAck(self: *StreamSink, tag: u32) !void {
        return self.writeFrame(.ack, tag, &.{});
    }

    pub fn writeError(self: *StreamSink, alloc: std.mem.Allocator, tag: u32, code: []const u8, msg: []const u8) !void {
        const body = try messages.encodeError(alloc, .{ .code = code, .message = msg });
        defer alloc.free(body);
        return self.writeFrame(.err, tag, body);
    }
};

/// Top-level dispatch. Returns true if the opcode was handled (even
/// if it produced an error frame); false for unknown opcodes so the
/// caller can log and drop the frame.
pub fn dispatch(
    state: *State,
    sink: *StreamSink,
    kind: Opcode,
    tag: u32,
    body: []const u8,
) !bool {
    switch (kind) {
        .load_model     => try handleLoadModel(state, sink, tag, body),
        .alloc_seq      => try handleAllocSeq(state, sink, tag, body),
        .free_seq       => try handleFreeSeq(state, sink, tag, body),
        .tokenize       => try handleTokenize(state, sink, tag, body),
        .apply_template => try handleApplyTemplate(state, sink, tag, body),
        .prefill        => try handlePrefill(state, sink, tag, body),
        .decode_token   => try handleDecodeToken(state, sink, tag, body),
        .abort_generate => try handleAbortGenerate(state, sink, tag, body),
        .kv_remove_range => try handleKvRemoveRange(state, sink, tag, body),
        .snapshot_seq   => try handleSnapshotSeq(state, sink, tag, body),
        .restore_seq    => try handleRestoreSeq(state, sink, tag, body),
        .stats          => try handleStats(state, sink, tag, body),
        else => return false,
    }
    return true;
}

// ── Individual handlers ─────────────────────────────────────────────

fn handleLoadModel(state: *State, sink: *StreamSink, tag: u32, body: []const u8) !void {
    const req = messages.decodeLoadModel(body) catch |e| {
        return sink.writeError(state.alloc, tag, "bad_request", @errorName(e));
    };
    log.info("load_model path={s} nCtx={d} nGpuLayers={d}", .{
        req.path, req.n_ctx, req.n_gpu_layers,
    });
    state.llama.loadModel(req.path, req.n_ctx, req.n_gpu_layers) catch |e| {
        return sink.writeError(state.alloc, tag, "model_load_failed", @errorName(e));
    };
    const reply = try messages.encodeLoadModelResult(state.alloc, .{
        .model_id = state.llama.model_id,
        .n_ctx = state.llama.n_ctx,
        .n_embd = state.llama.n_embd,
        .n_vocab = state.llama.n_vocab,
    });
    defer state.alloc.free(reply);
    try sink.writeResult(tag, reply);
}

fn handleAllocSeq(state: *State, sink: *StreamSink, tag: u32, body: []const u8) !void {
    _ = messages.decodeAllocSeq(body) catch |e| {
        return sink.writeError(state.alloc, tag, "bad_request", @errorName(e));
    };
    const id = state.allocSeq() catch |e| {
        return sink.writeError(state.alloc, tag, "oom", @errorName(e));
    };
    const reply = try messages.encodeAllocSeqResult(state.alloc, id);
    defer state.alloc.free(reply);
    try sink.writeResult(tag, reply);
}

fn handleFreeSeq(state: *State, sink: *StreamSink, tag: u32, body: []const u8) !void {
    const req = messages.decodeFreeSeq(body) catch |e| {
        return sink.writeError(state.alloc, tag, "bad_request", @errorName(e));
    };
    _ = state.freeSeq(req.seq_id);
    try sink.writeAck(tag);
}

fn handleTokenize(state: *State, sink: *StreamSink, tag: u32, body: []const u8) !void {
    const req = messages.decodeTokenize(body) catch |e| {
        return sink.writeError(state.alloc, tag, "bad_request", @errorName(e));
    };
    if (!state.llama.loaded) {
        return sink.writeError(state.alloc, tag, "no_model", "load_model before tokenize");
    }
    const toks = state.llama.tokenize(req.text) catch |e| {
        return sink.writeError(state.alloc, tag, "tokenize_failed", @errorName(e));
    };
    defer state.alloc.free(toks);
    const reply = try messages.encodeTokensResult(state.alloc, toks);
    defer state.alloc.free(reply);
    try sink.writeResult(tag, reply);
}

fn handleApplyTemplate(state: *State, sink: *StreamSink, tag: u32, body: []const u8) !void {
    var req = messages.decodeApplyTemplate(state.alloc, body) catch |e| {
        return sink.writeError(state.alloc, tag, "bad_request", @errorName(e));
    };
    defer req.deinit(state.alloc);
    // Stub: concat all contents, tokenize.
    var joined = std.ArrayListUnmanaged(u8).empty;
    defer joined.deinit(state.alloc);
    for (req.turns) |t| {
        if (joined.items.len > 0) try joined.append(state.alloc, ' ');
        try joined.appendSlice(state.alloc, t.content);
    }
    var tokens = std.ArrayListUnmanaged(i32).empty;
    defer tokens.deinit(state.alloc);
    var it = std.mem.tokenizeAny(u8, joined.items, " \t\n\r");
    var next_tok: i32 = 1;
    while (it.next()) |_| {
        try tokens.append(state.alloc, next_tok);
        next_tok += 1;
    }
    const reply = try messages.encodeTokensResult(state.alloc, tokens.items);
    defer state.alloc.free(reply);
    try sink.writeResult(tag, reply);
}

fn handlePrefill(state: *State, sink: *StreamSink, tag: u32, body: []const u8) !void {
    var req = messages.decodePrefill(state.alloc, body) catch |e| {
        return sink.writeError(state.alloc, tag, "bad_request", @errorName(e));
    };
    defer req.deinit(state.alloc);

    if (!state.hasSeq(req.seq_id)) {
        return sink.writeError(state.alloc, tag, "unknown_seq", "seq_id not allocated");
    }
    if (!state.llama.loaded) {
        return sink.writeError(state.alloc, tag, "no_model", "load_model before prefill");
    }
    try streamRealTokens(state, sink, tag, req.tokens, req.opts);
}

fn handleDecodeToken(state: *State, sink: *StreamSink, tag: u32, body: []const u8) !void {
    const req = messages.decodeDecodeToken(body) catch |e| {
        return sink.writeError(state.alloc, tag, "bad_request", @errorName(e));
    };
    if (!state.hasSeq(req.seq_id)) {
        return sink.writeError(state.alloc, tag, "unknown_seq", "seq_id not allocated");
    }
    if (!state.llama.loaded) {
        return sink.writeError(state.alloc, tag, "no_model", "load_model before decode_token");
    }
    // Continuation: empty prompt, sample from current context. Future
    // work: track n_past so multi-turn resumes from the right position.
    try streamRealTokens(state, sink, tag, &.{}, req.opts);
}

fn handleAbortGenerate(state: *State, sink: *StreamSink, tag: u32, body: []const u8) !void {
    _ = messages.decodeAbortGenerate(body) catch |e| {
        return sink.writeError(state.alloc, tag, "bad_request", @errorName(e));
    };
    // Stubs generate synchronously within the handler call, so there's
    // nothing to cancel. Real impl tracks in-flight streams by tag.
    try sink.writeAck(tag);
}

fn handleKvRemoveRange(state: *State, sink: *StreamSink, tag: u32, body: []const u8) !void {
    const req = messages.decodeKvRemoveRange(body) catch |e| {
        return sink.writeError(state.alloc, tag, "bad_request", @errorName(e));
    };
    if (!state.hasSeq(req.seq_id)) {
        return sink.writeError(state.alloc, tag, "unknown_seq", "seq_id not allocated");
    }
    try sink.writeAck(tag);
}

fn handleSnapshotSeq(state: *State, sink: *StreamSink, tag: u32, body: []const u8) !void {
    const req = messages.decodeSnapshotSeq(body) catch |e| {
        return sink.writeError(state.alloc, tag, "bad_request", @errorName(e));
    };
    if (!state.hasSeq(req.seq_id)) {
        return sink.writeError(state.alloc, tag, "unknown_seq", "seq_id not allocated");
    }
    // Stub: don't actually write anything. M2 calls llama_state_seq_save_file.
    const reply = try messages.encodeSnapshotResult(state.alloc, 0);
    defer state.alloc.free(reply);
    try sink.writeResult(tag, reply);
}

fn handleRestoreSeq(state: *State, sink: *StreamSink, tag: u32, body: []const u8) !void {
    const req = messages.decodeRestoreSeq(body) catch |e| {
        return sink.writeError(state.alloc, tag, "bad_request", @errorName(e));
    };
    _ = req;
    // Stub: allocate a fresh seq id, report zero resumed tokens.
    const id = state.allocSeq() catch |e| {
        return sink.writeError(state.alloc, tag, "oom", @errorName(e));
    };
    const reply = try messages.encodeRestoreResult(state.alloc, id, 0);
    defer state.alloc.free(reply);
    try sink.writeResult(tag, reply);
}

fn handleStats(state: *State, sink: *StreamSink, tag: u32, body: []const u8) !void {
    _ = body;
    const reply = try messages.encodeStatsResult(state.alloc, .{
        .vram_used = 0,
        .seqs_active = @intCast(state.live_seqs.count()),
        .max_seqs = 64,
        .ctx_tokens_free = state.llama.n_ctx,
    });
    defer state.alloc.free(reply);
    try sink.writeResult(tag, reply);
}

// ─── Real generator (llama-backed) ──────────────────────────────────

fn streamRealTokens(
    state: *State,
    sink: *StreamSink,
    tag: u32,
    prompt_tokens: []const i32,
    opts: messages.GenOpts,
) !void {
    // Copy the i32 prompt tokens to a mutable slice of llama.Token
    // (alias for i32, but the function signature takes non-const).
    const prompt_mut = try state.alloc.alloc(i32, prompt_tokens.len);
    defer state.alloc.free(prompt_mut);
    @memcpy(prompt_mut, prompt_tokens);

    const Ctx = struct {
        state: *State,
        sink: *StreamSink,
        tag: u32,
        tokens_sent: u32 = 0,
        err: ?anyerror = null,

        fn onToken(self_ptr: *anyopaque, tok_id: i32, text: []const u8, pos: i32) bool {
            const self: *@This() = @ptrCast(@alignCast(self_ptr));
            const body = messages.encodeTokenChunk(self.state.alloc, .{
                .token_id = tok_id,
                .text = text,
                .pos = pos,
            }) catch |e| {
                self.err = e;
                return false;
            };
            defer self.state.alloc.free(body);
            self.sink.writeFrame(.token_chunk, self.tag, body) catch |e| {
                self.err = e;
                return false;
            };
            self.tokens_sent += 1;
            return true;
        }
    };
    var cb_ctx: Ctx = .{ .state = state, .sink = sink, .tag = tag };

    const result = state.llama.generate(prompt_mut, opts.max_tokens, @ptrCast(&cb_ctx), Ctx.onToken) catch |e| {
        return sink.writeError(state.alloc, tag, "generate_failed", @errorName(e));
    };
    if (cb_ctx.err) |e| return e;

    const done = try messages.encodeDone(state.alloc, .{
        .stop_reason = switch (result.stop) {
            .eos => .eos,
            .max => .max,
            .abort => .abort,
        },
        .total_pos = result.total_pos,
        .tokens_generated = result.tokens_generated,
    });
    defer state.alloc.free(done);
    try sink.writeFrame(.done, tag, done);
}

// ─── tests ───────────────────────────────────────────────────────────
//
// These exercise the pure opcode-dispatch + CBOR paths. Tests that
// would require a real model (prefill streaming, load_model success)
// live in `llama.zig` and are gated on `DIS_TEST_MODEL`.

const test_alloc = std.testing.allocator;

/// Capture sink — records every frame written so tests can assert.
const CaptureSink = struct {
    alloc: std.mem.Allocator,
    frames: std.ArrayListUnmanaged(Captured) = .empty,

    const Captured = struct {
        kind: Opcode,
        tag: u32,
        body: []u8, // owned
    };

    fn init(alloc: std.mem.Allocator) CaptureSink {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *CaptureSink) void {
        for (self.frames.items) |f| self.alloc.free(f.body);
        self.frames.deinit(self.alloc);
    }

    fn asSink(self: *CaptureSink) StreamSink {
        return .{ .ctx = @ptrCast(self), .writeFrameFn = thunk };
    }

    fn thunk(ctx: *anyopaque, kind: Opcode, tag: u32, body: []const u8) anyerror!void {
        const self: *CaptureSink = @ptrCast(@alignCast(ctx));
        const owned = try self.alloc.dupe(u8, body);
        errdefer self.alloc.free(owned);
        try self.frames.append(self.alloc, .{ .kind = kind, .tag = tag, .body = owned });
    }
};

test "dispatch alloc_seq produces Result frame" {
    var state = State.init(test_alloc);
    defer state.deinit();
    var cap = CaptureSink.init(test_alloc);
    defer cap.deinit();
    var sink = cap.asSink();

    var w = cbor.Writer.init(test_alloc);
    defer w.deinit();
    try w.beginMap(1);
    try w.writeText("sessionId");
    try w.writeText("abcd");
    try std.testing.expect(try dispatch(&state, &sink, .alloc_seq, 2, w.bytes()));
    try std.testing.expectEqual(@as(usize, 1), cap.frames.items.len);
    try std.testing.expectEqual(Opcode.result, cap.frames.items[0].kind);
    try std.testing.expectEqual(@as(u32, 2), cap.frames.items[0].tag);
}

test "dispatch prefill without loaded model produces error" {
    var state = State.init(test_alloc);
    defer state.deinit();
    var cap = CaptureSink.init(test_alloc);
    defer cap.deinit();
    var sink = cap.asSink();

    const seq_id = try state.allocSeq();

    var w = cbor.Writer.init(test_alloc);
    defer w.deinit();
    try w.beginMap(3);
    try w.writeText("seqId");
    try w.writeInt(seq_id);
    try w.writeText("tokens");
    try w.beginArray(0);
    try w.writeText("opts");
    try w.beginMap(1);
    try w.writeText("maxTokens");
    try w.writeUint(3);

    try std.testing.expect(try dispatch(&state, &sink, .prefill, 42, w.bytes()));
    try std.testing.expectEqual(@as(usize, 1), cap.frames.items.len);
    try std.testing.expectEqual(Opcode.err, cap.frames.items[0].kind);
}

test "dispatch free_seq returns ack" {
    var state = State.init(test_alloc);
    defer state.deinit();
    var cap = CaptureSink.init(test_alloc);
    defer cap.deinit();
    var sink = cap.asSink();

    const id = try state.allocSeq();
    try std.testing.expect(state.hasSeq(id));

    var w = cbor.Writer.init(test_alloc);
    defer w.deinit();
    try w.beginMap(1);
    try w.writeText("seqId");
    try w.writeInt(id);

    try std.testing.expect(try dispatch(&state, &sink, .free_seq, 7, w.bytes()));
    try std.testing.expectEqual(Opcode.ack, cap.frames.items[0].kind);
    try std.testing.expect(!state.hasSeq(id));
}

test "dispatch unknown_seq on prefill produces error frame" {
    var state = State.init(test_alloc);
    defer state.deinit();
    var cap = CaptureSink.init(test_alloc);
    defer cap.deinit();
    var sink = cap.asSink();

    var w = cbor.Writer.init(test_alloc);
    defer w.deinit();
    try w.beginMap(2);
    try w.writeText("seqId");
    try w.writeInt(999);
    try w.writeText("tokens");
    try w.beginArray(0);

    try std.testing.expect(try dispatch(&state, &sink, .prefill, 1, w.bytes()));
    try std.testing.expectEqual(@as(usize, 1), cap.frames.items.len);
    try std.testing.expectEqual(Opcode.err, cap.frames.items[0].kind);
}

test "dispatch unknown opcode returns false" {
    var state = State.init(test_alloc);
    defer state.deinit();
    var cap = CaptureSink.init(test_alloc);
    defer cap.deinit();
    var sink = cap.asSink();
    try std.testing.expect(!(try dispatch(&state, &sink, @as(Opcode, @enumFromInt(0x77)), 0, &.{})));
}
