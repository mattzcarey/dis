//! Engine↔runner frame codec (matches sdk/src/frames.ts).
//!
//! Wire shape inside a WS binary message:
//!
//!     ┌────────┬───────────────┬───────────────────────────┐
//!     │ kind   │    tag (BE)   │    body (CBOR)            │
//!     │ u8 (1) │    u32 (4)    │    N bytes                │
//!     └────────┴───────────────┴───────────────────────────┘
//!
//! v0: the body is kept as an opaque byte slice on the Zig side. Once
//! we pull in or write a CBOR decoder we'll exchange CBOR values here.

const std = @import("std");

pub const HEADER_LEN: usize = 5;

pub const Opcode = enum(u8) {
    // engine → runner
    hello = 0x01,
    actor_start = 0x10,
    actor_stop = 0x11,
    client_request = 0x20,
    client_request_abort = 0x21,
    ws_frame = 0x22, // engine → runner: one inbound client WS frame
    connection_message = 0x23, // runner → engine: send a frame to a connection (or all connections via "*")
    connection_close = 0x24, // runner → engine: forcibly close a connection

    // runner → engine
    runner_ready = 0x80,
    client_response = 0x90,
    generate = 0xA0,
    generate_raw = 0xA1,
    tokenize = 0xA2,
    load_model = 0xA3,
    models = 0xA4,
    reset_context = 0xA5,

    state_get = 0xB0,
    state_get_many = 0xB1,
    state_set = 0xB2,
    state_set_many = 0xB3,
    state_delete = 0xB4,
    state_list = 0xB5,
    state_clear = 0xB6,
    state_txn_begin = 0xB7,
    state_txn_commit = 0xB8,
    state_txn_rollback = 0xB9,

    schedule = 0xC0,
    schedule_every = 0xC1,
    cancel_schedule = 0xC2,
    get_schedule = 0xC3,
    get_schedules = 0xC4,
    schedule_fire = 0xC5,

    sql_exec = 0xD0,
    sql_query = 0xD1,

    broadcast = 0xE0,
    hibernate = 0xE1,
    block_concurrency = 0xE2,

    // bidirectional replies
    ack = 0xE8,
    result = 0xE9,

    // streaming + error
    token_chunk = 0xF0,
    err = 0xFF,

    _,
};

pub const Frame = struct {
    kind: Opcode,
    tag: u32,
    body: []const u8, // opaque CBOR in v0
};

pub const DecodeError = error{TooShort};

/// Decode a frame from a WS payload. `buf` is borrowed — the returned
/// frame references it.
pub fn decode(buf: []const u8) DecodeError!Frame {
    if (buf.len < HEADER_LEN) return DecodeError.TooShort;
    const kind_byte = buf[0];
    const tag = std.mem.readInt(u32, buf[1..5], .big);
    return .{
        .kind = @enumFromInt(kind_byte),
        .tag = tag,
        .body = buf[HEADER_LEN..],
    };
}

/// Encode a frame header into the start of `buf`. Caller is responsible
/// for copying/appending the body. Returns the number of bytes written.
pub fn encodeHeader(buf: []u8, kind: Opcode, tag: u32) void {
    std.debug.assert(buf.len >= HEADER_LEN);
    buf[0] = @intFromEnum(kind);
    std.mem.writeInt(u32, buf[1..5], tag, .big);
}

/// Encode a frame into a single allocated buffer (header + body copy).
pub fn encode(alloc: std.mem.Allocator, kind: Opcode, tag: u32, body: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, HEADER_LEN + body.len);
    encodeHeader(out, kind, tag);
    @memcpy(out[HEADER_LEN..], body);
    return out;
}

// ── tests ─────────────────────────────────────────────────────────────

test "decode frame" {
    const raw = [_]u8{ 0xC0, 0x00, 0x00, 0x00, 0x2A, 0xAA, 0xBB };
    const f = try decode(&raw);
    try std.testing.expectEqual(Opcode.schedule, f.kind);
    try std.testing.expectEqual(@as(u32, 42), f.tag);
    try std.testing.expectEqual(@as(usize, 2), f.body.len);
    try std.testing.expectEqual(@as(u8, 0xAA), f.body[0]);
}

test "encode/decode roundtrip" {
    const body = [_]u8{ 1, 2, 3, 4 };
    const bytes = try encode(std.testing.allocator, .runner_ready, 0x01020304, &body);
    defer std.testing.allocator.free(bytes);
    const f = try decode(bytes);
    try std.testing.expectEqual(Opcode.runner_ready, f.kind);
    try std.testing.expectEqual(@as(u32, 0x01020304), f.tag);
    try std.testing.expectEqualSlices(u8, &body, f.body);
}

test "decode rejects short buffer" {
    try std.testing.expectError(DecodeError.TooShort, decode(&[_]u8{ 0x01, 0x02 }));
}
