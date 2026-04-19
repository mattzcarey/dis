//! Typed CBOR encoders/decoders for the dis-engine ↔ dis-infer wire.
//!
//! Each request opcode maps to a request struct (`*Req`) with a
//! matching response struct (`*Result`). Streaming ops (Prefill,
//! DecodeToken) emit one or more `TokenChunk` frames terminated by a
//! `Done` frame (or an `Error` frame on failure). One-shot ops either
//! return `Result` with a body or `Ack` with an empty body.
//!
//! Decoders allocate owned slices for variable-length fields (arrays,
//! strings) — call `deinit(alloc)` on the returned struct to free them.
//! Scalar-only structs don't need deinit.

const std = @import("std");
const cbor = @import("cbor");

pub const DecodeError = cbor.DecodeError;

// ── LoadModel ───────────────────────────────────────────────────────
//
// Req body:     { path: text, nCtx: uint, nGpuLayers: int }
// Result body:  { modelId: text, nCtx: uint, nEmbd: uint, nVocab: uint }

pub const LoadModelReq = struct {
    path: []const u8,
    n_ctx: u32 = 0,
    n_gpu_layers: i32 = -1,
};

pub const LoadModelResult = struct {
    model_id: []const u8, // borrowed from caller-provided body
    n_ctx: u32,
    n_embd: u32,
    n_vocab: u32,
};

pub fn decodeLoadModel(body: []const u8) DecodeError!LoadModelReq {
    var r = cbor.Reader.init(body);
    const n = try r.mapLen();
    var out: LoadModelReq = .{ .path = "" };
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = try r.readText();
        if (std.mem.eql(u8, key, "path")) {
            out.path = try r.readText();
        } else if (std.mem.eql(u8, key, "nCtx")) {
            const v = try r.readUint();
            out.n_ctx = @intCast(v);
        } else if (std.mem.eql(u8, key, "nGpuLayers")) {
            out.n_gpu_layers = try readI32(&r);
        } else try r.skip();
    }
    return out;
}

pub fn encodeLoadModelResult(alloc: std.mem.Allocator, m: LoadModelResult) ![]u8 {
    var w = cbor.Writer.init(alloc);
    errdefer w.deinit();
    try w.beginMap(4);
    try w.writeText("modelId");
    try w.writeText(m.model_id);
    try w.writeText("nCtx");
    try w.writeUint(m.n_ctx);
    try w.writeText("nEmbd");
    try w.writeUint(m.n_embd);
    try w.writeText("nVocab");
    try w.writeUint(m.n_vocab);
    return try w.toOwnedSlice();
}

// ── AllocSeq / FreeSeq ──────────────────────────────────────────────
//
// AllocSeq Req:    { sessionId: text }                    — 32-hex sid
// AllocSeq Result: { seqId: int }                         — llama seq_id
//
// FreeSeq Req:     { seqId: int }                         → Ack

pub const AllocSeqReq = struct { session_id: []const u8 };
pub const AllocSeqResult = struct { seq_id: i32 };
pub const FreeSeqReq = struct { seq_id: i32 };

pub fn decodeAllocSeq(body: []const u8) DecodeError!AllocSeqReq {
    var r = cbor.Reader.init(body);
    const n = try r.mapLen();
    var out: AllocSeqReq = .{ .session_id = "" };
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = try r.readText();
        if (std.mem.eql(u8, key, "sessionId")) {
            out.session_id = try r.readText();
        } else try r.skip();
    }
    return out;
}

pub fn encodeAllocSeqResult(alloc: std.mem.Allocator, seq_id: i32) ![]u8 {
    var w = cbor.Writer.init(alloc);
    errdefer w.deinit();
    try w.beginMap(1);
    try w.writeText("seqId");
    try w.writeInt(seq_id);
    return try w.toOwnedSlice();
}

pub fn decodeFreeSeq(body: []const u8) DecodeError!FreeSeqReq {
    var r = cbor.Reader.init(body);
    const n = try r.mapLen();
    var out: FreeSeqReq = .{ .seq_id = 0 };
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = try r.readText();
        if (std.mem.eql(u8, key, "seqId")) {
            out.seq_id = try readI32(&r);
        } else try r.skip();
    }
    return out;
}

// ── Tokenize ────────────────────────────────────────────────────────
//
// Req:     { seqId: int, text: text }
// Result:  { tokens: [int] }

pub const TokenizeReq = struct {
    seq_id: i32,
    text: []const u8,
};

pub fn decodeTokenize(body: []const u8) DecodeError!TokenizeReq {
    var r = cbor.Reader.init(body);
    const n = try r.mapLen();
    var out: TokenizeReq = .{ .seq_id = 0, .text = "" };
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = try r.readText();
        if (std.mem.eql(u8, key, "seqId")) {
            out.seq_id = try readI32(&r);
        } else if (std.mem.eql(u8, key, "text")) {
            out.text = try r.readText();
        } else try r.skip();
    }
    return out;
}

pub fn encodeTokensResult(alloc: std.mem.Allocator, tokens: []const i32) ![]u8 {
    var w = cbor.Writer.init(alloc);
    errdefer w.deinit();
    try w.beginMap(1);
    try w.writeText("tokens");
    try w.beginArray(tokens.len);
    for (tokens) |t| try w.writeInt(t);
    return try w.toOwnedSlice();
}

// ── ApplyTemplate ───────────────────────────────────────────────────
//
// Req:     { turns: [{role: text, content: text}] }
// Result:  { tokens: [int] }   (reuse encodeTokensResult)

pub const Turn = struct {
    role: []const u8,
    content: []const u8,
};

pub const ApplyTemplateReq = struct {
    turns: []const Turn, // owned outer slice, borrowed strings
    pub fn deinit(self: *ApplyTemplateReq, alloc: std.mem.Allocator) void {
        if (self.turns.len > 0) alloc.free(self.turns);
    }
};

pub fn decodeApplyTemplate(
    alloc: std.mem.Allocator,
    body: []const u8,
) !ApplyTemplateReq {
    var r = cbor.Reader.init(body);
    const n = try r.mapLen();
    var out: ApplyTemplateReq = .{ .turns = &.{} };
    var owns = false;
    errdefer if (owns) alloc.free(out.turns);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = try r.readText();
        if (std.mem.eql(u8, key, "turns")) {
            const arr_len = try r.arrayLen();
            if (arr_len == 0) continue;
            const arr = try alloc.alloc(Turn, arr_len);
            owns = true;
            out.turns = arr;
            for (arr) |*slot| {
                const m = try r.mapLen();
                var role: []const u8 = "";
                var content: []const u8 = "";
                var k: usize = 0;
                while (k < m) : (k += 1) {
                    const tkey = try r.readText();
                    if (std.mem.eql(u8, tkey, "role")) {
                        role = try r.readText();
                    } else if (std.mem.eql(u8, tkey, "content")) {
                        content = try r.readText();
                    } else try r.skip();
                }
                slot.* = .{ .role = role, .content = content };
            }
        } else try r.skip();
    }
    return out;
}

// ── Prefill / DecodeToken options + streaming ───────────────────────
//
// Prefill Req:      { seqId: int, tokens: [int], opts: GenOpts }
// DecodeToken Req:  { seqId: int, opts: GenOpts }
//
// Both stream TokenChunk frames (see below) terminated by Done.

pub const GenOpts = struct {
    temperature: f32 = 1.0,
    top_k: i32 = 40,
    top_p: f32 = 0.9,
    max_tokens: u32 = 256,
    seed: u64 = 0,
    /// If true, don't advance the actor's KV — used for scratch
    /// generations (e.g. a completion that should not become history).
    ephemeral: bool = false,
};

pub const PrefillReq = struct {
    seq_id: i32,
    tokens: []const i32, // owned; free with deinit()
    opts: GenOpts = .{},

    pub fn deinit(self: *PrefillReq, alloc: std.mem.Allocator) void {
        if (self.tokens.len > 0) alloc.free(self.tokens);
    }
};

pub const DecodeTokenReq = struct {
    seq_id: i32,
    opts: GenOpts = .{},
};

pub fn decodePrefill(alloc: std.mem.Allocator, body: []const u8) !PrefillReq {
    var r = cbor.Reader.init(body);
    const n = try r.mapLen();
    var out: PrefillReq = .{ .seq_id = 0, .tokens = &.{} };
    var owns = false;
    errdefer if (owns) alloc.free(out.tokens);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = try r.readText();
        if (std.mem.eql(u8, key, "seqId")) {
            out.seq_id = try readI32(&r);
        } else if (std.mem.eql(u8, key, "tokens")) {
            const arr_len = try r.arrayLen();
            if (arr_len == 0) continue;
            const arr = try alloc.alloc(i32, arr_len);
            owns = true;
            out.tokens = arr;
            for (arr) |*slot| slot.* = try readI32(&r);
        } else if (std.mem.eql(u8, key, "opts")) {
            out.opts = try readGenOpts(&r);
        } else try r.skip();
    }
    return out;
}

pub fn decodeDecodeToken(body: []const u8) DecodeError!DecodeTokenReq {
    var r = cbor.Reader.init(body);
    const n = try r.mapLen();
    var out: DecodeTokenReq = .{ .seq_id = 0 };
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = try r.readText();
        if (std.mem.eql(u8, key, "seqId")) {
            out.seq_id = try readI32(&r);
        } else if (std.mem.eql(u8, key, "opts")) {
            out.opts = try readGenOpts(&r);
        } else try r.skip();
    }
    return out;
}

fn readGenOpts(r: *cbor.Reader) DecodeError!GenOpts {
    var out: GenOpts = .{};
    // Null / undefined → defaults.
    if (r.peekMajor()) |m| if (m == .simple) {
        try r.skip();
        return out;
    };
    const n = try r.mapLen();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = try r.readText();
        if (std.mem.eql(u8, key, "temperature")) {
            // Accept a uint/int stand-in for floats (decoder doesn't
            // support float majors yet). Real floats round-trip through
            // JSON via the runner in M2.
            out.temperature = @floatFromInt(try readI32(r));
        } else if (std.mem.eql(u8, key, "topK")) {
            out.top_k = try readI32(r);
        } else if (std.mem.eql(u8, key, "topP")) {
            out.top_p = @floatFromInt(try readI32(r));
        } else if (std.mem.eql(u8, key, "maxTokens")) {
            const v = try r.readUint();
            out.max_tokens = @intCast(v);
        } else if (std.mem.eql(u8, key, "seed")) {
            out.seed = try r.readUint();
        } else if (std.mem.eql(u8, key, "ephemeral")) {
            out.ephemeral = try r.readBool();
        } else try r.skip();
    }
    return out;
}

// ── TokenChunk / Done (streaming responses) ─────────────────────────
//
// TokenChunk body: { tokenId: int, text: text, pos: int }
// Done body:       { stopReason: text, totalPos: int, tokensGenerated: uint }

pub const TokenChunk = struct {
    token_id: i32,
    text: []const u8,
    pos: i32,
};

pub fn encodeTokenChunk(alloc: std.mem.Allocator, c: TokenChunk) ![]u8 {
    var w = cbor.Writer.init(alloc);
    errdefer w.deinit();
    try w.beginMap(3);
    try w.writeText("tokenId");
    try w.writeInt(c.token_id);
    try w.writeText("text");
    try w.writeText(c.text);
    try w.writeText("pos");
    try w.writeInt(c.pos);
    return try w.toOwnedSlice();
}

pub const StopReason = enum { eos, max, abort };

pub const Done = struct {
    stop_reason: StopReason,
    total_pos: i32,
    tokens_generated: u32,
};

pub fn encodeDone(alloc: std.mem.Allocator, d: Done) ![]u8 {
    var w = cbor.Writer.init(alloc);
    errdefer w.deinit();
    try w.beginMap(3);
    try w.writeText("stopReason");
    try w.writeText(@tagName(d.stop_reason));
    try w.writeText("totalPos");
    try w.writeInt(d.total_pos);
    try w.writeText("tokensGenerated");
    try w.writeUint(d.tokens_generated);
    return try w.toOwnedSlice();
}

// ── AbortGenerate / KvRemoveRange ───────────────────────────────────
//
// AbortGenerate Req:  { tag: uint }           → Ack
// KvRemoveRange Req:  { seqId: int, p0: int, p1: int } → Ack

pub const AbortGenerateReq = struct { tag: u32 };
pub const KvRemoveRangeReq = struct {
    seq_id: i32,
    p0: i32,
    p1: i32,
};

pub fn decodeAbortGenerate(body: []const u8) DecodeError!AbortGenerateReq {
    var r = cbor.Reader.init(body);
    const n = try r.mapLen();
    var out: AbortGenerateReq = .{ .tag = 0 };
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = try r.readText();
        if (std.mem.eql(u8, key, "tag")) {
            const v = try r.readUint();
            out.tag = @intCast(v);
        } else try r.skip();
    }
    return out;
}

pub fn decodeKvRemoveRange(body: []const u8) DecodeError!KvRemoveRangeReq {
    var r = cbor.Reader.init(body);
    const n = try r.mapLen();
    var out: KvRemoveRangeReq = .{ .seq_id = 0, .p0 = 0, .p1 = 0 };
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = try r.readText();
        if (std.mem.eql(u8, key, "seqId")) {
            out.seq_id = try readI32(&r);
        } else if (std.mem.eql(u8, key, "p0")) {
            out.p0 = try readI32(&r);
        } else if (std.mem.eql(u8, key, "p1")) {
            out.p1 = try readI32(&r);
        } else try r.skip();
    }
    return out;
}

// ── SnapshotSeq / RestoreSeq ────────────────────────────────────────
//
// SnapshotSeq Req:     { seqId: int, path: text }        Result: { bytesWritten: uint }
// RestoreSeq  Req:     { sessionId: text, path: text }   Result: { seqId: int, nTokens: uint }

pub const SnapshotSeqReq = struct {
    seq_id: i32,
    path: []const u8,
};

pub const RestoreSeqReq = struct {
    session_id: []const u8,
    path: []const u8,
};

pub fn decodeSnapshotSeq(body: []const u8) DecodeError!SnapshotSeqReq {
    var r = cbor.Reader.init(body);
    const n = try r.mapLen();
    var out: SnapshotSeqReq = .{ .seq_id = 0, .path = "" };
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = try r.readText();
        if (std.mem.eql(u8, key, "seqId")) {
            out.seq_id = try readI32(&r);
        } else if (std.mem.eql(u8, key, "path")) {
            out.path = try r.readText();
        } else try r.skip();
    }
    return out;
}

pub fn decodeRestoreSeq(body: []const u8) DecodeError!RestoreSeqReq {
    var r = cbor.Reader.init(body);
    const n = try r.mapLen();
    var out: RestoreSeqReq = .{ .session_id = "", .path = "" };
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = try r.readText();
        if (std.mem.eql(u8, key, "sessionId")) {
            out.session_id = try r.readText();
        } else if (std.mem.eql(u8, key, "path")) {
            out.path = try r.readText();
        } else try r.skip();
    }
    return out;
}

pub fn encodeSnapshotResult(alloc: std.mem.Allocator, bytes_written: u64) ![]u8 {
    var w = cbor.Writer.init(alloc);
    errdefer w.deinit();
    try w.beginMap(1);
    try w.writeText("bytesWritten");
    try w.writeUint(bytes_written);
    return try w.toOwnedSlice();
}

pub fn encodeRestoreResult(
    alloc: std.mem.Allocator,
    seq_id: i32,
    n_tokens: u32,
) ![]u8 {
    var w = cbor.Writer.init(alloc);
    errdefer w.deinit();
    try w.beginMap(2);
    try w.writeText("seqId");
    try w.writeInt(seq_id);
    try w.writeText("nTokens");
    try w.writeUint(n_tokens);
    return try w.toOwnedSlice();
}

// ── Stats ────────────────────────────────────────────────────────────
//
// Req:     {}                              (empty map accepted)
// Result:  { vramUsed: uint, seqsActive: uint, maxSeqs: uint, ctxTokensFree: uint }

pub const StatsResult = struct {
    vram_used: u64 = 0,
    seqs_active: u32 = 0,
    max_seqs: u32 = 0,
    ctx_tokens_free: u32 = 0,
};

pub fn encodeStatsResult(alloc: std.mem.Allocator, s: StatsResult) ![]u8 {
    var w = cbor.Writer.init(alloc);
    errdefer w.deinit();
    try w.beginMap(4);
    try w.writeText("vramUsed");
    try w.writeUint(s.vram_used);
    try w.writeText("seqsActive");
    try w.writeUint(s.seqs_active);
    try w.writeText("maxSeqs");
    try w.writeUint(s.max_seqs);
    try w.writeText("ctxTokensFree");
    try w.writeUint(s.ctx_tokens_free);
    return try w.toOwnedSlice();
}

// ── Error ───────────────────────────────────────────────────────────
//
// body: { code: text, message: text }

pub const ErrorFrame = struct {
    code: []const u8,
    message: []const u8,
};

pub fn encodeError(alloc: std.mem.Allocator, e: ErrorFrame) ![]u8 {
    var w = cbor.Writer.init(alloc);
    errdefer w.deinit();
    try w.beginMap(2);
    try w.writeText("code");
    try w.writeText(e.code);
    try w.writeText("message");
    try w.writeText(e.message);
    return try w.toOwnedSlice();
}

// ─── helpers ────────────────────────────────────────────────────────

/// Read a CBOR int (accepts uint or negative-int major) and narrow to
/// i32. Overflows saturate to i32 min/max.
fn readI32(r: *cbor.Reader) DecodeError!i32 {
    switch (r.peekMajor() orelse return DecodeError.Truncated) {
        .uint => {
            const v = try r.readUint();
            if (v > @as(u64, std.math.maxInt(i32))) return std.math.maxInt(i32);
            return @intCast(v);
        },
        .nint => {
            const v = try r.readInt(); // returns i64
            if (v < std.math.minInt(i32)) return std.math.minInt(i32);
            if (v > std.math.maxInt(i32)) return std.math.maxInt(i32);
            return @intCast(v);
        },
        else => return DecodeError.TypeMismatch,
    }
}

// ─── tests ───────────────────────────────────────────────────────────

test "decodeLoadModel roundtrip" {
    const alloc = std.testing.allocator;
    var w = cbor.Writer.init(alloc);
    defer w.deinit();
    try w.beginMap(3);
    try w.writeText("path");
    try w.writeText("/models/tiny.gguf");
    try w.writeText("nCtx");
    try w.writeUint(4096);
    try w.writeText("nGpuLayers");
    try w.writeInt(99);

    const req = try decodeLoadModel(w.bytes());
    try std.testing.expectEqualStrings("/models/tiny.gguf", req.path);
    try std.testing.expectEqual(@as(u32, 4096), req.n_ctx);
    try std.testing.expectEqual(@as(i32, 99), req.n_gpu_layers);
}

test "encode + decode LoadModelResult" {
    const alloc = std.testing.allocator;
    const body = try encodeLoadModelResult(alloc, .{
        .model_id = "tiny-q4",
        .n_ctx = 4096,
        .n_embd = 1024,
        .n_vocab = 32000,
    });
    defer alloc.free(body);
    var r = cbor.Reader.init(body);
    try std.testing.expectEqual(@as(usize, 4), try r.mapLen());
    try std.testing.expectEqualStrings("modelId", try r.readText());
    try std.testing.expectEqualStrings("tiny-q4", try r.readText());
}

test "decodePrefill tokens + opts" {
    const alloc = std.testing.allocator;
    var w = cbor.Writer.init(alloc);
    defer w.deinit();
    try w.beginMap(3);
    try w.writeText("seqId");
    try w.writeInt(7);
    try w.writeText("tokens");
    try w.beginArray(3);
    try w.writeInt(1);
    try w.writeInt(2);
    try w.writeInt(3);
    try w.writeText("opts");
    try w.beginMap(2);
    try w.writeText("maxTokens");
    try w.writeUint(64);
    try w.writeText("seed");
    try w.writeUint(42);

    var req = try decodePrefill(alloc, w.bytes());
    defer req.deinit(alloc);
    try std.testing.expectEqual(@as(i32, 7), req.seq_id);
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, req.tokens);
    try std.testing.expectEqual(@as(u32, 64), req.opts.max_tokens);
    try std.testing.expectEqual(@as(u64, 42), req.opts.seed);
}

test "encodeTokenChunk + encodeDone shapes" {
    const alloc = std.testing.allocator;

    const tc = try encodeTokenChunk(alloc, .{ .token_id = 99, .text = "hello", .pos = 5 });
    defer alloc.free(tc);
    var r1 = cbor.Reader.init(tc);
    try std.testing.expectEqual(@as(usize, 3), try r1.mapLen());

    const dn = try encodeDone(alloc, .{ .stop_reason = .max, .total_pos = 256, .tokens_generated = 128 });
    defer alloc.free(dn);
    var r2 = cbor.Reader.init(dn);
    try std.testing.expectEqual(@as(usize, 3), try r2.mapLen());
    try std.testing.expectEqualStrings("stopReason", try r2.readText());
    try std.testing.expectEqualStrings("max", try r2.readText());
}

test "decodeTokenize + encodeTokensResult" {
    const alloc = std.testing.allocator;
    var w = cbor.Writer.init(alloc);
    defer w.deinit();
    try w.beginMap(2);
    try w.writeText("seqId");
    try w.writeInt(3);
    try w.writeText("text");
    try w.writeText("hello world");
    const req = try decodeTokenize(w.bytes());
    try std.testing.expectEqual(@as(i32, 3), req.seq_id);
    try std.testing.expectEqualStrings("hello world", req.text);

    const result = try encodeTokensResult(alloc, &.{ 1, 2, 3, 4 });
    defer alloc.free(result);
    var r = cbor.Reader.init(result);
    try std.testing.expectEqual(@as(usize, 1), try r.mapLen());
    try std.testing.expectEqualStrings("tokens", try r.readText());
    try std.testing.expectEqual(@as(usize, 4), try r.arrayLen());
}

test "decodeApplyTemplate turns" {
    const alloc = std.testing.allocator;
    var w = cbor.Writer.init(alloc);
    defer w.deinit();
    try w.beginMap(1);
    try w.writeText("turns");
    try w.beginArray(2);
    try w.beginMap(2);
    try w.writeText("role");
    try w.writeText("system");
    try w.writeText("content");
    try w.writeText("you are helpful");
    try w.beginMap(2);
    try w.writeText("role");
    try w.writeText("user");
    try w.writeText("content");
    try w.writeText("hi");

    var req = try decodeApplyTemplate(alloc, w.bytes());
    defer req.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), req.turns.len);
    try std.testing.expectEqualStrings("system", req.turns[0].role);
    try std.testing.expectEqualStrings("you are helpful", req.turns[0].content);
    try std.testing.expectEqualStrings("user", req.turns[1].role);
}
