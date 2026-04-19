//! WebSocket opening handshake (RFC 6455).
//!
//! Given a parsed HTTP request that claims to be a WS upgrade, compute
//! the `Sec-WebSocket-Accept` header value and render the response
//! that completes the server-side handshake.
//!
//! Only the subset we need for RFC 6455:
//!   - Single version (13)
//!   - Ignore extensions / subprotocols in v0
//!   - HTTP/1.1 only

const std = @import("std");
const Request = @import("../http/request.zig").Request;

pub const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const HandshakeError = error{
    NotAnUpgrade,
    MissingKey,
    UnsupportedVersion,
    OutOfMemory,
};

/// Verify the request is a legitimate WS upgrade for version 13 and
/// compute the response `Sec-WebSocket-Accept` value.
///
/// Caller owns the returned bytes (28 char base64-encoded SHA1).
pub fn acceptKey(alloc: std.mem.Allocator, request: Request) HandshakeError![]u8 {
    // Upgrade: websocket
    const upgrade = request.header("upgrade") orelse return HandshakeError.NotAnUpgrade;
    if (!std.ascii.eqlIgnoreCase(upgrade, "websocket")) return HandshakeError.NotAnUpgrade;

    // Connection must contain "upgrade" (case-insensitive, comma-separated).
    const conn = request.header("connection") orelse return HandshakeError.NotAnUpgrade;
    var contains_upgrade = false;
    var conn_it = std.mem.splitScalar(u8, conn, ',');
    while (conn_it.next()) |part| {
        var p = part;
        while (p.len > 0 and (p[0] == ' ' or p[0] == '\t')) p = p[1..];
        while (p.len > 0 and (p[p.len - 1] == ' ' or p[p.len - 1] == '\t')) p = p[0 .. p.len - 1];
        if (std.ascii.eqlIgnoreCase(p, "upgrade")) {
            contains_upgrade = true;
            break;
        }
    }
    if (!contains_upgrade) return HandshakeError.NotAnUpgrade;

    const version = request.header("sec-websocket-version") orelse return HandshakeError.UnsupportedVersion;
    if (!std.mem.eql(u8, version, "13")) return HandshakeError.UnsupportedVersion;

    const client_key = request.header("sec-websocket-key") orelse return HandshakeError.MissingKey;

    // accept = base64(sha1(client_key ++ GUID))
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(client_key);
    sha.update(GUID);
    var digest: [20]u8 = undefined;
    sha.final(&digest);

    const encoded_len = std.base64.standard.Encoder.calcSize(digest.len);
    const out = try alloc.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(out, &digest);
    return out;
}

/// Format the 101 Switching Protocols response. Caller owns the returned
/// bytes. Consumes `accept` (freed by caller separately).
pub fn renderResponse(alloc: std.mem.Allocator, accept: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: {s}\r\n" ++
        "\r\n",
        .{accept},
    );
}

// ── tests ─────────────────────────────────────────────────────────────

test "RFC 6455 example accept" {
    // From RFC 6455 §1.3:
    //   key    = "dGhlIHNhbXBsZSBub25jZQ=="
    //   accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    const parse = @import("../http/request.zig").parse;
    const raw =
        "GET /runner HTTP/1.1\r\n" ++
        "Host: localhost:7070\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";
    var req = try parse(std.testing.allocator, raw);
    defer req.deinit(std.testing.allocator);

    const key = try acceptKey(std.testing.allocator, req);
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", key);
}

test "missing upgrade header rejected" {
    const parse = @import("../http/request.zig").parse;
    const raw =
        "GET /runner HTTP/1.1\r\n" ++
        "Host: localhost:7070\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";
    var req = try parse(std.testing.allocator, raw);
    defer req.deinit(std.testing.allocator);
    try std.testing.expectError(HandshakeError.NotAnUpgrade, acceptKey(std.testing.allocator, req));
}

test "unsupported version rejected" {
    const parse = @import("../http/request.zig").parse;
    const raw =
        "GET /runner HTTP/1.1\r\n" ++
        "Host: localhost:7070\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: abc\r\n" ++
        "Sec-WebSocket-Version: 8\r\n" ++
        "\r\n";
    var req = try parse(std.testing.allocator, raw);
    defer req.deinit(std.testing.allocator);
    try std.testing.expectError(HandshakeError.UnsupportedVersion, acceptKey(std.testing.allocator, req));
}

test "connection header with multiple tokens" {
    const parse = @import("../http/request.zig").parse;
    const raw =
        "GET /runner HTTP/1.1\r\n" ++
        "Host: localhost:7070\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: keep-alive, Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";
    var req = try parse(std.testing.allocator, raw);
    defer req.deinit(std.testing.allocator);
    const key = try acceptKey(std.testing.allocator, req);
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", key);
}
