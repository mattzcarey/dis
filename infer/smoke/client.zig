//! dis-infer wire smoke client. Drives a running dis-infer through the
//! full request flow against a real GGUF:
//!
//!   LoadModel → AllocSeq → Tokenize → Prefill (stream) → Done → Stats
//!
//! Usage:
//!   zig build smoke
//!   ./zig-out/bin/dis-infer /tmp/dis-infer.sock &
//!   ./zig-out/bin/dis-infer-smoke /tmp/dis-infer.sock /path/to/model.gguf "Once upon a time"
//!
//! Not a production client — the engine-side real client will live in
//! `engine/src/infer/`.

const std = @import("std");
const infer = @import("infer");
const frames = infer.frames;
const cbor = infer.cbor;

const DEFAULT_SOCK = "/tmp/dis-infer.sock";
const DEFAULT_PROMPT = "Once upon a time";
const MAX_NEW_TOKENS: u64 = 32;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer iter.deinit();
    _ = iter.next(); // prog
    const sock = iter.next() orelse DEFAULT_SOCK;
    const model = iter.next() orelse {
        std.debug.print("usage: dis-infer-smoke <sock> <model.gguf> [prompt]\n", .{});
        std.process.exit(2);
    };
    const prompt = iter.next() orelse DEFAULT_PROMPT;

    std.debug.print("sock={s}\nmodel={s}\nprompt={s}\n\n", .{ sock, model, prompt });

    const addr = try std.Io.net.UnixAddress.init(sock);
    const stream = try addr.connect(io);
    defer stream.close(io);

    var rb: [8192]u8 = undefined;
    var wb: [8192]u8 = undefined;
    var reader = std.Io.net.Stream.Reader.init(stream, io, &rb);
    var writer = std.Io.net.Stream.Writer.init(stream, io, &wb);
    const r = &reader.interface;
    const w = &writer.interface;

    // ── 1. LoadModel ───────────────────────────────────────────────
    {
        var cw = cbor.Writer.init(alloc);
        defer cw.deinit();
        try cw.beginMap(3);
        try cw.writeText("path");
        try cw.writeText(model);
        try cw.writeText("nCtx");
        try cw.writeUint(512);
        try cw.writeText("nGpuLayers");
        try cw.writeInt(99); // full offload if GPU available
        try frames.writeFrame(w, .load_model, 1, cw.bytes());
        std.debug.print("→ load_model\n", .{});
        try awaitResult(alloc, r, "load_model", .result);
    }

    // ── 2. AllocSeq ────────────────────────────────────────────────
    var seq_id: i32 = 0;
    {
        var cw = cbor.Writer.init(alloc);
        defer cw.deinit();
        try cw.beginMap(1);
        try cw.writeText("sessionId");
        try cw.writeText("0123456789abcdef0123456789abcdef");
        try frames.writeFrame(w, .alloc_seq, 2, cw.bytes());
        std.debug.print("→ alloc_seq\n", .{});
        seq_id = try awaitAllocSeq(alloc, r);
        std.debug.print("  seqId={d}\n", .{seq_id});
    }

    // ── 3. Tokenize the prompt ─────────────────────────────────────
    var prompt_tokens: []i32 = &.{};
    {
        var cw = cbor.Writer.init(alloc);
        defer cw.deinit();
        try cw.beginMap(2);
        try cw.writeText("seqId");
        try cw.writeInt(seq_id);
        try cw.writeText("text");
        try cw.writeText(prompt);
        try frames.writeFrame(w, .tokenize, 3, cw.bytes());
        std.debug.print("→ tokenize\n", .{});
        prompt_tokens = try awaitTokens(alloc, r);
        std.debug.print("  tokens={d}\n", .{prompt_tokens.len});
    }
    defer alloc.free(prompt_tokens);

    // ── 4. Prefill (streaming response) ────────────────────────────
    {
        var cw = cbor.Writer.init(alloc);
        defer cw.deinit();
        try cw.beginMap(3);
        try cw.writeText("seqId");
        try cw.writeInt(seq_id);
        try cw.writeText("tokens");
        try cw.beginArray(prompt_tokens.len);
        for (prompt_tokens) |t| try cw.writeInt(t);
        try cw.writeText("opts");
        try cw.beginMap(1);
        try cw.writeText("maxTokens");
        try cw.writeUint(MAX_NEW_TOKENS);
        try frames.writeFrame(w, .prefill, 4, cw.bytes());
        std.debug.print("→ prefill\n\n{s}", .{prompt});
        try streamTokens(alloc, r);
    }

    // ── 5. Stats ───────────────────────────────────────────────────
    {
        var cw = cbor.Writer.init(alloc);
        defer cw.deinit();
        try cw.beginMap(0);
        try frames.writeFrame(w, .stats, 5, cw.bytes());
        std.debug.print("\n→ stats\n", .{});
        try awaitResult(alloc, r, "stats", .result);
    }
}

// ─── helpers ────────────────────────────────────────────────────────

fn awaitResult(alloc: std.mem.Allocator, r: *std.Io.Reader, label: []const u8, expected: frames.Opcode) !void {
    const hdr = try frames.readHeader(r);
    const body = try alloc.alloc(u8, hdr.len);
    defer alloc.free(body);
    try frames.readBody(r, body);
    if (hdr.kind == .err) {
        var cr = cbor.Reader.init(body);
        _ = try cr.mapLen();
        _ = try cr.readText();
        const code = try cr.readText();
        _ = try cr.readText();
        const msg = try cr.readText();
        std.debug.print("  ERR {s}: {s}\n", .{ code, msg });
        return error.RemoteError;
    }
    if (hdr.kind != expected) {
        std.debug.print("  {s}: unexpected kind=0x{X:0>2}\n", .{ label, @intFromEnum(hdr.kind) });
        return error.UnexpectedFrame;
    }
    std.debug.print("  {s} ok ({d}B)\n", .{ label, body.len });
}

fn awaitAllocSeq(alloc: std.mem.Allocator, r: *std.Io.Reader) !i32 {
    const hdr = try frames.readHeader(r);
    const body = try alloc.alloc(u8, hdr.len);
    defer alloc.free(body);
    try frames.readBody(r, body);
    if (hdr.kind != .result) return error.UnexpectedFrame;
    var cr = cbor.Reader.init(body);
    _ = try cr.mapLen();
    _ = try cr.readText(); // "seqId"
    const v = try cr.readInt();
    return @intCast(v);
}

fn awaitTokens(alloc: std.mem.Allocator, r: *std.Io.Reader) ![]i32 {
    const hdr = try frames.readHeader(r);
    const body = try alloc.alloc(u8, hdr.len);
    defer alloc.free(body);
    try frames.readBody(r, body);
    if (hdr.kind == .err) return error.RemoteError;
    if (hdr.kind != .result) return error.UnexpectedFrame;
    var cr = cbor.Reader.init(body);
    _ = try cr.mapLen();
    _ = try cr.readText(); // "tokens"
    const n = try cr.arrayLen();
    const out = try alloc.alloc(i32, n);
    errdefer alloc.free(out);
    for (out) |*slot| slot.* = @intCast(try cr.readInt());
    return out;
}

fn streamTokens(alloc: std.mem.Allocator, r: *std.Io.Reader) !void {
    while (true) {
        const hdr = try frames.readHeader(r);
        const body = try alloc.alloc(u8, hdr.len);
        defer alloc.free(body);
        try frames.readBody(r, body);
        switch (hdr.kind) {
            .token_chunk => {
                var cr = cbor.Reader.init(body);
                _ = try cr.mapLen();
                _ = try cr.readText(); // "tokenId"
                _ = try cr.readInt();
                _ = try cr.readText(); // "text"
                const t = try cr.readText();
                _ = try cr.readText(); // "pos"
                _ = try cr.readInt();
                // Print directly without quoting — shows the generated text inline.
                std.debug.print("{s}", .{t});
            },
            .done => {
                var cr = cbor.Reader.init(body);
                _ = try cr.mapLen();
                _ = try cr.readText(); // "stopReason"
                const stop = try cr.readText();
                _ = try cr.readText(); // "totalPos"
                _ = try cr.readInt();
                _ = try cr.readText(); // "tokensGenerated"
                const generated = try cr.readUint();
                std.debug.print("\n\n[done stop={s} tokens={d}]\n", .{ stop, generated });
                return;
            },
            .err => {
                var cr = cbor.Reader.init(body);
                _ = try cr.mapLen();
                _ = try cr.readText();
                const code = try cr.readText();
                _ = try cr.readText();
                const msg = try cr.readText();
                std.debug.print("\nERR {s}: {s}\n", .{ code, msg });
                return error.RemoteError;
            },
            else => {
                std.debug.print("\nunexpected kind=0x{X:0>2}\n", .{@intFromEnum(hdr.kind)});
                return error.UnexpectedFrame;
            },
        }
    }
}
