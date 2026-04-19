//! WebSocket frame codec (RFC 6455 §5).
//!
//! Scope:
//!   - Read client frames (always masked, server→client always unmasked)
//!   - Write server frames (never masked)
//!   - Opcodes: continuation, text, binary, close, ping, pong
//!   - Lengths up to u64 (the full spec range)
//!   - Fragmentation assembled by caller — we return one frame at a time
//!
//! We do not do TLS; bind dis-engine behind a TLS-terminating proxy if
//! you need wss://.
//!
//! Pure byte-level code. Buffers are caller-allocated; we try to push
//! all mallocs out of the hot path.

const std = @import("std");

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    payload: []u8, // in caller's buffer; already unmasked
};

pub const ReadError = error{
    PayloadTooLarge,
    ProtocolError,
    Unmasked,
    ShortRead,
    EndOfStream,
};

pub const WriteError = error{
    ShortWrite,
    PayloadTooLarge,
};

// ── Reader ────────────────────────────────────────────────────────────
//
// Reads a single frame from a `*std.Io.Reader`. The returned Frame's
// payload is a slice of `payload_buf`, which must be sized to the
// largest frame you expect (v0 callers use ≥128 KiB).

pub fn readFrame(r: *std.Io.Reader, payload_buf: []u8) ReadError!Frame {
    const hdr2 = r.takeArray(2) catch return ReadError.ShortRead;
    const fin = (hdr2[0] & 0x80) != 0;
    const rsv = (hdr2[0] & 0x70) != 0;
    if (rsv) return ReadError.ProtocolError;
    const opcode_u4: u4 = @truncate(hdr2[0] & 0x0F);
    const opcode: Opcode = @enumFromInt(opcode_u4);

    const masked = (hdr2[1] & 0x80) != 0;
    if (!masked) return ReadError.Unmasked; // clients MUST mask

    var payload_len: u64 = hdr2[1] & 0x7F;
    if (payload_len == 126) {
        const ext = r.takeArray(2) catch return ReadError.ShortRead;
        payload_len = std.mem.readInt(u16, ext, .big);
    } else if (payload_len == 127) {
        const ext = r.takeArray(8) catch return ReadError.ShortRead;
        payload_len = std.mem.readInt(u64, ext, .big);
        if ((payload_len & (@as(u64, 1) << 63)) != 0) return ReadError.ProtocolError;
    }

    if (payload_len > payload_buf.len) return ReadError.PayloadTooLarge;

    const mask_key = r.takeArray(4) catch return ReadError.ShortRead;

    const payload = payload_buf[0..@intCast(payload_len)];
    // Take via readSliceShort; we may get fewer bytes in one call, so loop.
    var filled: usize = 0;
    while (filled < payload.len) {
        const n = r.readSliceShort(payload[filled..]) catch return ReadError.ShortRead;
        if (n == 0) return ReadError.EndOfStream;
        filled += n;
    }
    unmask(payload, mask_key.*);

    return .{ .fin = fin, .opcode = opcode, .payload = payload };
}

/// XOR `data` with `mask` bytewise. Mask is 4 bytes, repeating.
pub fn unmask(data: []u8, mask: [4]u8) void {
    for (data, 0..) |*b, i| b.* ^= mask[i & 3];
}

// ── Writer ────────────────────────────────────────────────────────────
//
// Server→client frames are never masked. We write the header directly
// to the caller's buffer and a second writeAll for the payload.

/// Compute header length for a given payload length. 2, 4, or 10 bytes.
pub inline fn headerLen(payload_len: usize) usize {
    if (payload_len < 126) return 2;
    if (payload_len <= 0xFFFF) return 4;
    return 10;
}

/// Encode a frame header into `buf` (must be at least headerLen bytes).
pub fn encodeHeader(buf: []u8, fin: bool, opcode: Opcode, payload_len: usize) usize {
    buf[0] = (if (fin) @as(u8, 0x80) else 0) | @as(u8, @intFromEnum(opcode));
    if (payload_len < 126) {
        buf[1] = @intCast(payload_len);
        return 2;
    } else if (payload_len <= 0xFFFF) {
        buf[1] = 126;
        std.mem.writeInt(u16, buf[2..4], @intCast(payload_len), .big);
        return 4;
    } else {
        buf[1] = 127;
        std.mem.writeInt(u64, buf[2..10], @intCast(payload_len), .big);
        return 10;
    }
}

/// Write a complete frame to `w`. Caller-allocated `scratch` is
/// used for the header and must be at least 10 bytes.
pub fn writeFrame(
    w: *std.Io.Writer,
    scratch: *[10]u8,
    fin: bool,
    opcode: Opcode,
    payload: []const u8,
) !void {
    const n = encodeHeader(scratch, fin, opcode, payload.len);
    try w.writeAll(scratch[0..n]);
    if (payload.len > 0) try w.writeAll(payload);
}

// ── tests ─────────────────────────────────────────────────────────────

test "unmask roundtrip" {
    var data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x01 };
    const mask: [4]u8 = .{ 0x11, 0x22, 0x33, 0x44 };
    const original = data;
    unmask(&data, mask);
    unmask(&data, mask);
    try std.testing.expectEqualSlices(u8, &original, &data);
}

test "headerLen boundaries" {
    try std.testing.expectEqual(@as(usize, 2), headerLen(0));
    try std.testing.expectEqual(@as(usize, 2), headerLen(125));
    try std.testing.expectEqual(@as(usize, 4), headerLen(126));
    try std.testing.expectEqual(@as(usize, 4), headerLen(0xFFFF));
    try std.testing.expectEqual(@as(usize, 10), headerLen(0x10000));
}

test "encodeHeader fin=true binary len=5" {
    var buf: [10]u8 = undefined;
    const n = encodeHeader(&buf, true, .binary, 5);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u8, 0x82), buf[0]); // FIN + binary
    try std.testing.expectEqual(@as(u8, 5), buf[1]);
}

test "encodeHeader 16-bit length" {
    var buf: [10]u8 = undefined;
    const n = encodeHeader(&buf, true, .binary, 0x1234);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(u8, 126), buf[1]);
    try std.testing.expectEqual(@as(u8, 0x12), buf[2]);
    try std.testing.expectEqual(@as(u8, 0x34), buf[3]);
}

test "encodeHeader 64-bit length" {
    var buf: [10]u8 = undefined;
    const n = encodeHeader(&buf, true, .binary, 0x10_0000);
    try std.testing.expectEqual(@as(usize, 10), n);
    try std.testing.expectEqual(@as(u8, 127), buf[1]);
    // 0x10_0000 as u64 big-endian → bytes [0,0,0,0,0,0x10,0,0] at buf[2..10]
    try std.testing.expectEqual(@as(u8, 0x10), buf[7]);
}
