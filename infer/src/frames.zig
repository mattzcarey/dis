//! dis-engine ↔ dis-infer wire frame codec (SPEC §7A).
//!
//! Unlike the engine↔runner tunnel which sits on top of a WebSocket
//! (WS gives us frame boundaries for free), engine↔infer runs over a
//! raw unix stream — so every frame carries its own length prefix.
//!
//! Frame layout:
//!
//!   ┌────────────┬──────────┬───────────┐
//!   │ len (u32)  │ kind (u8)│ tag (u32) │    header: 9 bytes, big-endian
//!   ├────────────┴──────────┴───────────┤
//!   │ body (exactly `len` bytes)        │    CBOR-encoded message
//!   └───────────────────────────────────┘
//!
//! `len` is the body length in bytes. Max body size is enforced by the
//! reader (MAX_BODY_BYTES below).
//!
//! `kind` is one of the opcodes in `Opcode`.
//!
//! `tag` is a u32 correlation token chosen by the requester. Replies
//! (Result, Ack, TokenChunk stream, Done, Error) echo the request
//! tag so the requester can route them to the right waiter / stream.
//! A fresh request uses a brand-new tag; streaming responses emit
//! multiple frames with the same tag terminated by Done or Error.

const std = @import("std");

pub const HEADER_BYTES: usize = 9;

/// Upper bound on a single frame body. Lets us reject garbage cheaply
/// without allocating. Large enough to hold a multi-thousand-token
/// tokenize response but small enough to flag a framing error.
pub const MAX_BODY_BYTES: usize = 16 * 1024 * 1024; // 16 MiB

/// Opcodes. Requests are 0x01..0x7F, responses / streaming 0x80..0xFF.
pub const Opcode = enum(u8) {
    // ── Requests (engine → infer) ──────────────────────────────────
    load_model       = 0x01,
    alloc_seq        = 0x02,
    free_seq         = 0x03,
    tokenize         = 0x04,
    apply_template   = 0x05,
    prefill          = 0x06, // streams TokenChunks
    decode_token     = 0x07, // streams TokenChunks
    abort_generate   = 0x08,
    kv_remove_range  = 0x09,
    snapshot_seq     = 0x0A,
    restore_seq      = 0x0B,
    stats            = 0x0C,

    // ── Responses (infer → engine) ─────────────────────────────────
    ack              = 0x80, // empty-body success ack for fire-and-forget style ops
    result           = 0x81, // success with a body
    token_chunk      = 0x82, // streaming token frame; `done` terminates the stream
    done             = 0x83, // streaming terminator
    err              = 0xFF, // error frame; body carries {code, message}

    _,
};

pub const Header = struct {
    len: u32,
    kind: Opcode,
    tag: u32,
};

pub const FrameError = error{
    /// Body length exceeded `MAX_BODY_BYTES`.
    FrameTooLarge,
    /// Underlying stream ended before we could read a full header/body.
    ShortRead,
    /// Underlying stream would block (should not happen with blocking Io).
    WouldBlock,
    /// Generic stream error from underneath.
    StreamError,
};

/// Read a full frame header from `r`. Blocks until 9 bytes have been
/// consumed. Rejects frames whose `len` exceeds `MAX_BODY_BYTES`.
pub fn readHeader(r: *std.Io.Reader) FrameError!Header {
    var buf: [HEADER_BYTES]u8 = undefined;
    r.readSliceAll(&buf) catch |e| return mapReadError(e);
    const len = std.mem.readInt(u32, buf[0..4], .big);
    const kind_byte = buf[4];
    const tag = std.mem.readInt(u32, buf[5..9], .big);
    if (len > MAX_BODY_BYTES) return FrameError.FrameTooLarge;
    return .{ .len = len, .kind = @enumFromInt(kind_byte), .tag = tag };
}

/// Read exactly `h.len` body bytes into `dst`. `dst.len` must equal
/// `h.len`.
pub fn readBody(r: *std.Io.Reader, dst: []u8) FrameError!void {
    r.readSliceAll(dst) catch |e| return mapReadError(e);
}

/// Encode a header into the first 9 bytes of `dst` (which must be at
/// least `HEADER_BYTES` long).
pub fn encodeHeader(dst: []u8, h: Header) void {
    std.debug.assert(dst.len >= HEADER_BYTES);
    std.mem.writeInt(u32, dst[0..4], h.len, .big);
    dst[4] = @intFromEnum(h.kind);
    std.mem.writeInt(u32, dst[5..9], h.tag, .big);
}

/// Write a full frame (header + body) to `w` with a single flush.
/// Caller retains ownership of `body`.
pub fn writeFrame(
    w: *std.Io.Writer,
    kind: Opcode,
    tag: u32,
    body: []const u8,
) !void {
    if (body.len > MAX_BODY_BYTES) return FrameError.FrameTooLarge;
    var hdr: [HEADER_BYTES]u8 = undefined;
    encodeHeader(&hdr, .{
        .len = @intCast(body.len),
        .kind = kind,
        .tag = tag,
    });
    try w.writeAll(&hdr);
    if (body.len > 0) try w.writeAll(body);
    try w.flush();
}

fn mapReadError(e: anyerror) FrameError {
    return switch (e) {
        error.EndOfStream, error.ReadFailed => FrameError.ShortRead,
        error.WouldBlock => FrameError.WouldBlock,
        else => FrameError.StreamError,
    };
}

// ─── tests ───────────────────────────────────────────────────────────

test "encodeHeader roundtrip" {
    var buf: [HEADER_BYTES]u8 = undefined;
    encodeHeader(&buf, .{ .len = 42, .kind = .load_model, .tag = 0xCAFEBABE });

    try std.testing.expectEqual(@as(u8, 0), buf[0]);
    try std.testing.expectEqual(@as(u8, 0), buf[1]);
    try std.testing.expectEqual(@as(u8, 0), buf[2]);
    try std.testing.expectEqual(@as(u8, 42), buf[3]);
    try std.testing.expectEqual(@as(u8, 0x01), buf[4]);
    try std.testing.expectEqual(@as(u8, 0xCA), buf[5]);
    try std.testing.expectEqual(@as(u8, 0xFE), buf[6]);
    try std.testing.expectEqual(@as(u8, 0xBA), buf[7]);
    try std.testing.expectEqual(@as(u8, 0xBE), buf[8]);
}

test "readHeader parses big-endian fields" {
    var bytes: [HEADER_BYTES]u8 = .{ 0x00, 0x00, 0x01, 0x00, 0x82, 0x00, 0x00, 0x00, 0x07 };
    var reader: std.Io.Reader = .fixed(&bytes);
    const h = try readHeader(&reader);
    try std.testing.expectEqual(@as(u32, 256), h.len);
    try std.testing.expectEqual(Opcode.token_chunk, h.kind);
    try std.testing.expectEqual(@as(u32, 7), h.tag);
}

test "readHeader rejects oversize frames" {
    var bytes: [HEADER_BYTES]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0, 0, 0, 0 };
    var reader: std.Io.Reader = .fixed(&bytes);
    try std.testing.expectError(FrameError.FrameTooLarge, readHeader(&reader));
}

test "readHeader ShortRead on truncated stream" {
    var bytes: [4]u8 = .{ 0, 0, 0, 0 };
    var reader: std.Io.Reader = .fixed(&bytes);
    try std.testing.expectError(FrameError.ShortRead, readHeader(&reader));
}

test "writeFrame emits header+body in order" {
    var out: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);
    try writeFrame(&writer, .result, 9, "hi");
    const w = writer.buffered();
    try std.testing.expectEqual(@as(usize, HEADER_BYTES + 2), w.len);
    try std.testing.expectEqual(@as(u8, 0x81), w[4]);
    try std.testing.expectEqualStrings("hi", w[HEADER_BYTES..]);
}
