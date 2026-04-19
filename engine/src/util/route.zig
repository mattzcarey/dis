//! Client WebSocket URL routing.
//!
//! Path grammar:
//!
//!     /v1/ws/:actor         → create a new session
//!     /v1/ws/:actor?sid=H   → resume an existing session (32-char hex)
//!
//! Actor name segment is percent-decoded. No namespace in the URL
//! (multi-tenant routing will come from auth headers later).

const std = @import("std");

pub const RouteError = error{
    NotWsRoute,
    MalformedPath,
    InvalidSid,
    BufferTooSmall,
};

pub const SID_HEX_LEN = 32;

pub const WsRoute = struct {
    actor: []const u8,
    /// If non-null, caller wants to resume this 32-char lowercase-hex sid.
    sid: ?[]const u8,
};

/// Parse a request target such as `/v1/ws/chat?sid=00a1...` into a
/// WsRoute.
///
/// `scratch` receives the percent-decoded actor name. Returned slices
/// borrow from both `scratch` and `target`.
pub fn parseWs(target: []const u8, scratch: []u8) RouteError!WsRoute {
    if (!std.mem.startsWith(u8, target, "/v1/ws/")) return RouteError.NotWsRoute;

    const q_start = std.mem.indexOfScalar(u8, target, '?');
    const path = if (q_start) |q| target[0..q] else target;
    const query = if (q_start) |q| target[q + 1 ..] else "";

    const after_prefix = path[7..]; // skip "/v1/ws/"
    if (after_prefix.len == 0) return RouteError.MalformedPath;
    if (std.mem.indexOfScalar(u8, after_prefix, '/') != null) return RouteError.MalformedPath;

    const actor = try decodePercent(after_prefix, scratch);

    var sid: ?[]const u8 = null;
    if (query.len > 0) {
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            if (std.mem.startsWith(u8, pair, "sid=")) {
                const val = pair[4..];
                if (val.len != SID_HEX_LEN) return RouteError.InvalidSid;
                if (!isHexLower(val)) return RouteError.InvalidSid;
                sid = val;
            }
        }
    }

    return .{ .actor = actor, .sid = sid };
}

fn isHexLower(s: []const u8) bool {
    for (s) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn decodePercent(in: []const u8, out: []u8) RouteError![]const u8 {
    if (out.len < in.len) return RouteError.BufferTooSmall;
    var oi: usize = 0;
    var i: usize = 0;
    while (i < in.len) : (i += 1) {
        const c = in[i];
        if (c == '%') {
            if (i + 2 >= in.len) return RouteError.MalformedPath;
            const hi = hexDigit(in[i + 1]) orelse return RouteError.MalformedPath;
            const lo = hexDigit(in[i + 2]) orelse return RouteError.MalformedPath;
            out[oi] = (hi << 4) | lo;
            oi += 1;
            i += 2;
        } else if (c == '+') {
            out[oi] = ' ';
            oi += 1;
        } else {
            out[oi] = c;
            oi += 1;
        }
    }
    return out[0..oi];
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ─── tests ───────────────────────────────────────────────────────────

test "new session (no query)" {
    var scratch: [64]u8 = undefined;
    const r = try parseWs("/v1/ws/chat", &scratch);
    try std.testing.expectEqualStrings("chat", r.actor);
    try std.testing.expect(r.sid == null);
}

test "resume with sid param" {
    var scratch: [64]u8 = undefined;
    const sid = "00a1b2c300000000000000000000001f";
    var target_buf: [96]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "/v1/ws/chat?sid={s}", .{sid});
    const r = try parseWs(target, &scratch);
    try std.testing.expectEqualStrings("chat", r.actor);
    try std.testing.expectEqualStrings(sid, r.sid.?);
}

test "rejects multi-segment path" {
    var scratch: [64]u8 = undefined;
    try std.testing.expectError(RouteError.MalformedPath, parseWs("/v1/ws/foo/bar", &scratch));
}

test "rejects non-ws route" {
    var scratch: [64]u8 = undefined;
    try std.testing.expectError(RouteError.NotWsRoute, parseWs("/v1/health", &scratch));
}

test "rejects short sid" {
    var scratch: [64]u8 = undefined;
    try std.testing.expectError(RouteError.InvalidSid, parseWs("/v1/ws/chat?sid=abc", &scratch));
}

test "rejects non-hex sid" {
    var scratch: [64]u8 = undefined;
    const bad = "/v1/ws/chat?sid=00a1b2c3zz00000000000000000001f";
    try std.testing.expectError(RouteError.InvalidSid, parseWs(bad, &scratch));
}

test "percent-decoded actor name" {
    var scratch: [64]u8 = undefined;
    const r = try parseWs("/v1/ws/real%2Dtime", &scratch);
    try std.testing.expectEqualStrings("real-time", r.actor);
}
