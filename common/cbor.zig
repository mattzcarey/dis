//! Minimal CBOR (RFC 8949) encoder/decoder.
//!
//! Shared between `dis-engine` and `dis-infer` — both binaries
//! `@import("cbor")` to reach this module. Tests live here so any
//! breakage surfaces on `zig build test` at the repo root.
//!
//! Supports the subset we exchange on the engine↔runner and
//! engine↔infer wires:
//!
//!   - major 0 (uint) and major 1 (negative int)
//!   - major 2 (byte string), major 3 (text string)
//!   - major 4 (fixed-length array), major 5 (fixed-length map)
//!   - major 7 simples: null (0xF6), false (0xF4), true (0xF5)
//!
//! Indefinite-length items, tagged values (major 6), and floats are not
//! emitted by cbor-x (the TS side's encoder) for any of the messages we
//! care about. Decoders reject them with `DecodeError.Unsupported`.
//!
//! Reader borrows slices from the backing buffer; Writer owns its output
//! `ArrayList`.

const std = @import("std");

pub const Major = enum(u3) {
    uint = 0,
    nint = 1,
    bytes = 2,
    text = 3,
    array = 4,
    map = 5,
    tagged = 6,
    simple = 7,
};

pub const DecodeError = error{
    Truncated,
    Unsupported,
    TypeMismatch,
    ArgumentOverflow,
};

// ─── Reader ──────────────────────────────────────────────────────────

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn eof(self: *const Reader) bool {
        return self.pos >= self.buf.len;
    }

    pub fn remaining(self: *const Reader) []const u8 {
        return self.buf[self.pos..];
    }

    fn read1(self: *Reader) !u8 {
        if (self.pos >= self.buf.len) return DecodeError.Truncated;
        const b = self.buf[self.pos];
        self.pos += 1;
        return b;
    }

    fn readSlice(self: *Reader, n: usize) ![]const u8 {
        if (self.pos + n > self.buf.len) return DecodeError.Truncated;
        const s = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    const Head = struct { major: Major, arg: u64, info: u5 };

    fn readHead(self: *Reader) !Head {
        const ib = try self.read1();
        const major: Major = @enumFromInt(@as(u3, @intCast(ib >> 5)));
        const info: u5 = @intCast(ib & 0x1F);
        const arg: u64 = switch (info) {
            0...23 => info,
            24 => try self.read1(),
            25 => blk: {
                const s = try self.readSlice(2);
                break :blk std.mem.readInt(u16, s[0..2], .big);
            },
            26 => blk: {
                const s = try self.readSlice(4);
                break :blk std.mem.readInt(u32, s[0..4], .big);
            },
            27 => blk: {
                const s = try self.readSlice(8);
                break :blk std.mem.readInt(u64, s[0..8], .big);
            },
            28...30 => return DecodeError.Unsupported,
            31 => return DecodeError.Unsupported, // indefinite-length
        };
        return .{ .major = major, .arg = arg, .info = info };
    }

    /// Peek the next major type without advancing. Null if at EOF.
    pub fn peekMajor(self: *const Reader) ?Major {
        if (self.pos >= self.buf.len) return null;
        return @enumFromInt(@as(u3, @intCast(self.buf[self.pos] >> 5)));
    }

    /// True if the next byte is CBOR null (0xF6).
    pub fn isNull(self: *const Reader) bool {
        if (self.pos >= self.buf.len) return false;
        return self.buf[self.pos] == 0xF6;
    }

    pub fn readNull(self: *Reader) !void {
        const h = try self.readHead();
        if (h.major != .simple or h.info != 22) return DecodeError.TypeMismatch;
    }

    pub fn readBool(self: *Reader) !bool {
        const h = try self.readHead();
        if (h.major != .simple) return DecodeError.TypeMismatch;
        return switch (h.info) {
            20 => false,
            21 => true,
            else => DecodeError.TypeMismatch,
        };
    }

    pub fn readUint(self: *Reader) !u64 {
        const h = try self.readHead();
        if (h.major != .uint) return DecodeError.TypeMismatch;
        return h.arg;
    }

    pub fn readInt(self: *Reader) !i64 {
        const h = try self.readHead();
        switch (h.major) {
            .uint => {
                if (h.arg > std.math.maxInt(i64)) return DecodeError.ArgumentOverflow;
                return @intCast(h.arg);
            },
            .nint => {
                if (h.arg >= std.math.maxInt(i64)) return DecodeError.ArgumentOverflow;
                return -@as(i64, @intCast(h.arg)) - 1;
            },
            else => return DecodeError.TypeMismatch,
        }
    }

    /// Read a text string (major 3). Returns a slice borrowing from the
    /// underlying buffer — caller must not hold past the buffer's lifetime.
    pub fn readText(self: *Reader) ![]const u8 {
        const h = try self.readHead();
        if (h.major != .text) return DecodeError.TypeMismatch;
        return try self.readSlice(@intCast(h.arg));
    }

    /// Read a byte string (major 2). Borrow semantics same as readText.
    pub fn readBytes(self: *Reader) ![]const u8 {
        const h = try self.readHead();
        if (h.major != .bytes) return DecodeError.TypeMismatch;
        return try self.readSlice(@intCast(h.arg));
    }

    pub fn arrayLen(self: *Reader) !usize {
        const h = try self.readHead();
        if (h.major != .array) return DecodeError.TypeMismatch;
        return @intCast(h.arg);
    }

    pub fn mapLen(self: *Reader) !usize {
        const h = try self.readHead();
        if (h.major != .map) return DecodeError.TypeMismatch;
        return @intCast(h.arg);
    }

    /// Skip exactly one complete value (including nested children).
    pub fn skip(self: *Reader) DecodeError!void {
        const h = try self.readHead();
        switch (h.major) {
            .uint, .nint, .simple => {},
            .bytes, .text => _ = try self.readSlice(@intCast(h.arg)),
            .array => {
                var i: u64 = 0;
                while (i < h.arg) : (i += 1) try self.skip();
            },
            .map => {
                var i: u64 = 0;
                while (i < h.arg) : (i += 1) {
                    try self.skip();
                    try self.skip();
                }
            },
            .tagged => try self.skip(),
        }
    }
};

// ─── Writer ──────────────────────────────────────────────────────────

pub const Writer = struct {
    alloc: std.mem.Allocator,
    out: std.ArrayList(u8),

    pub fn init(alloc: std.mem.Allocator) Writer {
        return .{ .alloc = alloc, .out = .empty };
    }

    pub fn deinit(self: *Writer) void {
        self.out.deinit(self.alloc);
    }

    pub fn toOwnedSlice(self: *Writer) ![]u8 {
        return self.out.toOwnedSlice(self.alloc);
    }

    pub fn bytes(self: *const Writer) []const u8 {
        return self.out.items;
    }

    fn writeHead(self: *Writer, major: Major, arg: u64) !void {
        const mb: u8 = @as(u8, @intFromEnum(major)) << 5;
        if (arg < 24) {
            try self.out.append(self.alloc, mb | @as(u8, @intCast(arg)));
        } else if (arg <= 0xFF) {
            try self.out.ensureUnusedCapacity(self.alloc, 2);
            self.out.appendAssumeCapacity(mb | 24);
            self.out.appendAssumeCapacity(@intCast(arg));
        } else if (arg <= 0xFFFF) {
            try self.out.ensureUnusedCapacity(self.alloc, 3);
            self.out.appendAssumeCapacity(mb | 25);
            var b: [2]u8 = undefined;
            std.mem.writeInt(u16, &b, @intCast(arg), .big);
            self.out.appendSliceAssumeCapacity(&b);
        } else if (arg <= 0xFFFFFFFF) {
            try self.out.ensureUnusedCapacity(self.alloc, 5);
            self.out.appendAssumeCapacity(mb | 26);
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, @intCast(arg), .big);
            self.out.appendSliceAssumeCapacity(&b);
        } else {
            try self.out.ensureUnusedCapacity(self.alloc, 9);
            self.out.appendAssumeCapacity(mb | 27);
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, arg, .big);
            self.out.appendSliceAssumeCapacity(&b);
        }
    }

    pub fn writeNull(self: *Writer) !void {
        try self.out.append(self.alloc, 0xF6);
    }

    pub fn writeBool(self: *Writer, v: bool) !void {
        try self.out.append(self.alloc, if (v) 0xF5 else 0xF4);
    }

    pub fn writeUint(self: *Writer, v: u64) !void {
        try self.writeHead(.uint, v);
    }

    pub fn writeInt(self: *Writer, v: i64) !void {
        if (v >= 0) {
            try self.writeHead(.uint, @intCast(v));
        } else {
            try self.writeHead(.nint, @intCast(-(v + 1)));
        }
    }

    pub fn writeText(self: *Writer, s: []const u8) !void {
        try self.writeHead(.text, @intCast(s.len));
        try self.out.appendSlice(self.alloc, s);
    }

    pub fn writeBytesVal(self: *Writer, b: []const u8) !void {
        try self.writeHead(.bytes, @intCast(b.len));
        try self.out.appendSlice(self.alloc, b);
    }

    pub fn beginArray(self: *Writer, n: usize) !void {
        try self.writeHead(.array, @intCast(n));
    }

    pub fn beginMap(self: *Writer, n: usize) !void {
        try self.writeHead(.map, @intCast(n));
    }
};

// ─── tests ───────────────────────────────────────────────────────────

test "uint encoding widths" {
    const alloc = std.testing.allocator;
    var w = Writer.init(alloc);
    defer w.deinit();
    try w.writeUint(0);
    try w.writeUint(23);
    try w.writeUint(24);
    try w.writeUint(255);
    try w.writeUint(256);
    try w.writeUint(0x10000);
    try w.writeUint(0x1_0000_0000);

    var r = Reader.init(w.bytes());
    try std.testing.expectEqual(@as(u64, 0), try r.readUint());
    try std.testing.expectEqual(@as(u64, 23), try r.readUint());
    try std.testing.expectEqual(@as(u64, 24), try r.readUint());
    try std.testing.expectEqual(@as(u64, 255), try r.readUint());
    try std.testing.expectEqual(@as(u64, 256), try r.readUint());
    try std.testing.expectEqual(@as(u64, 0x10000), try r.readUint());
    try std.testing.expectEqual(@as(u64, 0x1_0000_0000), try r.readUint());
    try std.testing.expect(r.eof());
}

test "negative ints" {
    const alloc = std.testing.allocator;
    var w = Writer.init(alloc);
    defer w.deinit();
    try w.writeInt(-1);
    try w.writeInt(-100);
    try w.writeInt(-1000);
    try w.writeInt(42);

    var r = Reader.init(w.bytes());
    try std.testing.expectEqual(@as(i64, -1), try r.readInt());
    try std.testing.expectEqual(@as(i64, -100), try r.readInt());
    try std.testing.expectEqual(@as(i64, -1000), try r.readInt());
    try std.testing.expectEqual(@as(i64, 42), try r.readInt());
}

test "text and bytes" {
    const alloc = std.testing.allocator;
    var w = Writer.init(alloc);
    defer w.deinit();
    try w.writeText("hello");
    try w.writeText("");
    try w.writeBytesVal(&[_]u8{ 1, 2, 3 });

    var r = Reader.init(w.bytes());
    try std.testing.expectEqualStrings("hello", try r.readText());
    try std.testing.expectEqualStrings("", try r.readText());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, try r.readBytes());
}

test "array and map" {
    const alloc = std.testing.allocator;
    var w = Writer.init(alloc);
    defer w.deinit();

    try w.beginMap(2);
    try w.writeText("actors");
    try w.beginArray(2);
    try w.writeText("Agent");
    try w.writeText("Counter");
    try w.writeText("max");
    try w.writeUint(42);

    var r = Reader.init(w.bytes());
    const n_map = try r.mapLen();
    try std.testing.expectEqual(@as(usize, 2), n_map);

    try std.testing.expectEqualStrings("actors", try r.readText());
    const n_arr = try r.arrayLen();
    try std.testing.expectEqual(@as(usize, 2), n_arr);
    try std.testing.expectEqualStrings("Agent", try r.readText());
    try std.testing.expectEqualStrings("Counter", try r.readText());

    try std.testing.expectEqualStrings("max", try r.readText());
    try std.testing.expectEqual(@as(u64, 42), try r.readUint());
}

test "null and bool" {
    const alloc = std.testing.allocator;
    var w = Writer.init(alloc);
    defer w.deinit();
    try w.writeNull();
    try w.writeBool(true);
    try w.writeBool(false);

    var r = Reader.init(w.bytes());
    try std.testing.expect(r.isNull());
    try r.readNull();
    try std.testing.expectEqual(true, try r.readBool());
    try std.testing.expectEqual(false, try r.readBool());
}

test "type mismatch rejected" {
    const alloc = std.testing.allocator;
    var w = Writer.init(alloc);
    defer w.deinit();
    try w.writeText("hi");
    var r = Reader.init(w.bytes());
    try std.testing.expectError(DecodeError.TypeMismatch, r.readUint());
}

test "skip nested" {
    const alloc = std.testing.allocator;
    var w = Writer.init(alloc);
    defer w.deinit();
    // {"a": [1, 2, {"b": "c"}], "tag": 1}
    try w.beginMap(2);
    try w.writeText("a");
    try w.beginArray(3);
    try w.writeUint(1);
    try w.writeUint(2);
    try w.beginMap(1);
    try w.writeText("b");
    try w.writeText("c");
    try w.writeText("tag");
    try w.writeUint(1);

    var r = Reader.init(w.bytes());
    _ = try r.mapLen();
    try std.testing.expectEqualStrings("a", try r.readText());
    try r.skip(); // the nested array
    try std.testing.expectEqualStrings("tag", try r.readText());
    try std.testing.expectEqual(@as(u64, 1), try r.readUint());
    try std.testing.expect(r.eof());
}

test "truncated buffer" {
    const raw = [_]u8{0x19}; // uint16 header without body
    var r = Reader.init(&raw);
    try std.testing.expectError(DecodeError.Truncated, r.readUint());
}

test "rejects indefinite length" {
    // 0x9F = array, info=31 (indefinite)
    const raw = [_]u8{0x9F};
    var r = Reader.init(&raw);
    try std.testing.expectError(DecodeError.Unsupported, r.arrayLen());
}
