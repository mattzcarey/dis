//! Minimal HTTP/1.1 request parser.
//!
//! We don't use std.http.Server because its API is still settling in
//! Zig 0.16. For v0 we read the request head ourselves — method, path,
//! headers — enough to route a connection to either the HTTP response
//! stub or the WebSocket upgrade handler.
//!
//! This is deliberately lenient (no RFC 9112 nitpicks) and has no body
//! parsing. After a successful `read()` the remaining bytes in the
//! buffer (after `head_len`) are the beginning of the body — callers
//! decide what to do with them.

const std = @import("std");

pub const Error = error{
    HeadTooLong,
    MalformedRequestLine,
    MalformedHeader,
    UnsupportedVersion,
    OutOfMemory,
};

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    OPTIONS,
    HEAD,
    PATCH,
    OTHER,

    pub fn fromString(s: []const u8) Method {
        if (std.mem.eql(u8, s, "GET")) return .GET;
        if (std.mem.eql(u8, s, "POST")) return .POST;
        if (std.mem.eql(u8, s, "PUT")) return .PUT;
        if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, s, "OPTIONS")) return .OPTIONS;
        if (std.mem.eql(u8, s, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, s, "PATCH")) return .PATCH;
        return .OTHER;
    }
};

pub const Header = struct {
    name: []const u8, // borrowed from buffer
    value: []const u8, // borrowed from buffer
};

pub const Request = struct {
    method: Method,
    target: []const u8,
    headers: []Header,
    head_len: usize, // number of bytes consumed from the input buffer

    /// Case-insensitive header lookup.
    pub fn header(self: Request, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    pub fn deinit(self: *Request, alloc: std.mem.Allocator) void {
        alloc.free(self.headers);
        self.* = undefined;
    }
};

/// Parse a request head from `buf`. Returns the Request or an error.
/// Caller owns `result.headers` via the allocator.
pub fn parse(alloc: std.mem.Allocator, buf: []const u8) Error!Request {
    const end_of_head_rel = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return Error.HeadTooLong;
    const head = buf[0..end_of_head_rel];
    const head_len = end_of_head_rel + 4;

    // Request-line: METHOD SP TARGET SP HTTP/1.x CRLF
    var line_it = std.mem.splitSequence(u8, head, "\r\n");
    const request_line = line_it.next() orelse return Error.MalformedRequestLine;

    var rl = std.mem.splitScalar(u8, request_line, ' ');
    const method_str = rl.next() orelse return Error.MalformedRequestLine;
    const target = rl.next() orelse return Error.MalformedRequestLine;
    const version = rl.next() orelse return Error.MalformedRequestLine;
    if (!std.mem.eql(u8, version, "HTTP/1.1") and !std.mem.eql(u8, version, "HTTP/1.0")) {
        return Error.UnsupportedVersion;
    }

    // Header lines.
    var headers = std.ArrayList(Header).empty;
    errdefer headers.deinit(alloc);

    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return Error.MalformedHeader;
        const name = line[0..colon];
        var value = line[colon + 1 ..];
        // Trim OWS on the value.
        while (value.len > 0 and (value[0] == ' ' or value[0] == '\t')) value = value[1..];
        while (value.len > 0 and (value[value.len - 1] == ' ' or value[value.len - 1] == '\t')) value = value[0 .. value.len - 1];
        try headers.append(alloc, .{ .name = name, .value = value });
    }

    return .{
        .method = Method.fromString(method_str),
        .target = target,
        .headers = try headers.toOwnedSlice(alloc),
        .head_len = head_len,
    };
}

// ── tests ─────────────────────────────────────────────────────────────

test "parse simple GET" {
    const raw = "GET /v1/health HTTP/1.1\r\nHost: example\r\n\r\n";
    var req = try parse(std.testing.allocator, raw);
    defer req.deinit(std.testing.allocator);
    try std.testing.expectEqual(Method.GET, req.method);
    try std.testing.expectEqualStrings("/v1/health", req.target);
    try std.testing.expectEqualStrings("example", req.header("host").?);
}

test "header lookup is case-insensitive" {
    const raw = "GET / HTTP/1.1\r\nUser-Agent: curl\r\n\r\n";
    var req = try parse(std.testing.allocator, raw);
    defer req.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("curl", req.header("USER-AGENT").?);
    try std.testing.expectEqualStrings("curl", req.header("user-agent").?);
}

test "parse WS upgrade request" {
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
    try std.testing.expectEqualStrings("/runner", req.target);
    try std.testing.expectEqualStrings("websocket", req.header("upgrade").?);
    try std.testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", req.header("sec-websocket-key").?);
}

test "incomplete head returns error" {
    try std.testing.expectError(Error.HeadTooLong, parse(std.testing.allocator, "GET /partial"));
}

test "malformed request line" {
    try std.testing.expectError(
        Error.MalformedRequestLine,
        parse(std.testing.allocator, "JUNK\r\n\r\n"),
    );
}
