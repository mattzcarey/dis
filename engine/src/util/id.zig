//! Session id — 16 bytes, generated as a UUID v7 per RFC 9562.
//!
//! Layout (most-significant byte first):
//!
//!   byte 0..6    : 48-bit big-endian Unix timestamp in milliseconds
//!   byte 6 hi 4  : version = 0x7
//!   byte 6 lo 4  : rand_a (4 bits)
//!   byte 7       : rand_a (8 bits)
//!   byte 8 hi 2  : variant = 0b10 (RFC 4122)
//!   byte 8 lo 6  : rand_b (6 bits)
//!   byte 9..15   : rand_b (56 bits)
//!
//! Total entropy: 74 bits (version + variant consume 6 bits of a 16-byte
//! random payload). Time-sortable within a millisecond-bucket; per-ms
//! order is random.
//!
//! Wire/URL rendering is 32 lowercase hex chars (no dashes) to keep
//! CBOR and URL surface compact. Clients that want to decode as a UUID
//! can re-split the hex; `toUuidString()` renders the dashed form.

const std = @import("std");

pub const Id128 = [16]u8;

pub const Id128Error = error{
    InvalidHex,
};

/// Generate a fresh UUID v7. `io` provides wall-clock time; `prng`
/// supplies the random bits. Caller is responsible for serialising
/// concurrent PRNG access.
pub fn generate(io: std.Io, prng: *std.Random) Id128 {
    var id: Id128 = undefined;
    prng.bytes(&id);

    const now_ms = currentMillis(io);
    // High 48 bits = timestamp (big-endian).
    id[0] = @truncate(now_ms >> 40);
    id[1] = @truncate(now_ms >> 32);
    id[2] = @truncate(now_ms >> 24);
    id[3] = @truncate(now_ms >> 16);
    id[4] = @truncate(now_ms >> 8);
    id[5] = @truncate(now_ms);

    // Version nibble = 0b0111 (v7) in high 4 bits of byte 6.
    id[6] = (id[6] & 0x0F) | 0x70;
    // Variant bits = 0b10 in high 2 bits of byte 8 (RFC 4122 layout).
    id[8] = (id[8] & 0x3F) | 0x80;

    return id;
}

fn currentMillis(io: std.Io) u64 {
    // `real` is Zig 0.16's wall-clock (Unix epoch) clock.
    const ts = std.Io.Clock.real.now(io);
    const ms_i = ts.toMilliseconds();
    if (ms_i < 0) return 0;
    return @intCast(ms_i);
}

/// Extract the 48-bit timestamp (ms since epoch) from a v7 id.
pub inline fn timestampMs(id: Id128) u64 {
    return (@as(u64, id[0]) << 40) |
        (@as(u64, id[1]) << 32) |
        (@as(u64, id[2]) << 24) |
        (@as(u64, id[3]) << 16) |
        (@as(u64, id[4]) << 8) |
        @as(u64, id[5]);
}

/// True if `id` is a well-formed UUID v7 (correct version + variant).
pub inline fn isV7(id: Id128) bool {
    return (id[6] & 0xF0) == 0x70 and (id[8] & 0xC0) == 0x80;
}

/// Lowercase hex, no dashes — 32 chars. Caller owns the slice.
pub fn toHex(alloc: std.mem.Allocator, id: Id128) ![]u8 {
    const out = try alloc.alloc(u8, 32);
    writeHex(out[0..32], id);
    return out;
}

/// Write 32 lowercase hex chars into `dst`.
pub fn writeHex(dst: *[32]u8, id: Id128) void {
    const hex_chars = "0123456789abcdef";
    for (id, 0..) |b, i| {
        dst[i * 2] = hex_chars[b >> 4];
        dst[i * 2 + 1] = hex_chars[b & 0x0F];
    }
}

/// Parse 32-char lowercase hex.
pub fn fromHex(hex: []const u8) Id128Error!Id128 {
    if (hex.len != 32) return Id128Error.InvalidHex;
    var id: Id128 = undefined;
    _ = std.fmt.hexToBytes(&id, hex) catch return Id128Error.InvalidHex;
    return id;
}

/// Canonical dashed UUID: `xxxxxxxx-xxxx-7xxx-yxxx-xxxxxxxxxxxx`.
pub fn toUuidString(id: Id128) [36]u8 {
    var hex: [32]u8 = undefined;
    writeHex(&hex, id);
    var out: [36]u8 = undefined;
    @memcpy(out[0..8], hex[0..8]);
    out[8] = '-';
    @memcpy(out[9..13], hex[8..12]);
    out[13] = '-';
    @memcpy(out[14..18], hex[12..16]);
    out[18] = '-';
    @memcpy(out[19..23], hex[16..20]);
    out[23] = '-';
    @memcpy(out[24..36], hex[20..32]);
    return out;
}

// ── tests ─────────────────────────────────────────────────────────────

fn testPrng() std.Random.Xoshiro256 {
    var seed: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    return std.Random.Xoshiro256.init(std.mem.readInt(u64, &seed, .little));
}

fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "generate produces UUID v7 bits" {
    var xoshiro = testPrng();
    var rng = xoshiro.random();
    const id = generate(testIo(), &rng);
    try std.testing.expect(isV7(id));
    // version nibble = 7
    try std.testing.expectEqual(@as(u8, 0x70), id[6] & 0xF0);
    // variant = 0b10xxxxxx
    try std.testing.expectEqual(@as(u8, 0x80), id[8] & 0xC0);
}

test "generate produces distinct ids" {
    var xoshiro = testPrng();
    var rng = xoshiro.random();
    const a = generate(testIo(), &rng);
    const b = generate(testIo(), &rng);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "hex roundtrip" {
    var xoshiro = testPrng();
    var rng = xoshiro.random();
    const id = generate(testIo(), &rng);

    const hex = try toHex(std.testing.allocator, id);
    defer std.testing.allocator.free(hex);
    try std.testing.expectEqual(@as(usize, 32), hex.len);

    const back = try fromHex(hex);
    try std.testing.expectEqualSlices(u8, &id, &back);
}

test "fromHex rejects wrong length" {
    try std.testing.expectError(Id128Error.InvalidHex, fromHex("deadbeef"));
}

test "toUuidString has dashes in the right places" {
    const id: Id128 = .{ 0x01, 0x92, 0xf8, 0xab, 0x7c, 0x3d, 0x7f, 0x12, 0xa3, 0xe4, 0xb5, 0xc6, 0xd7, 0xe8, 0xf9, 0x01 };
    const s = toUuidString(id);
    try std.testing.expectEqualStrings("0192f8ab-7c3d-7f12-a3e4-b5c6d7e8f901", &s);
}
