//! Typed encoders/decoders for engine↔runner message bodies.
//!
//! Each tunnel frame has a 5-byte header (opcode + tag) followed by a
//! CBOR body whose shape depends on the opcode. This file owns the
//! mapping from opcode → message struct.
//!
//! Memory model:
//!   - Decoded messages borrow string/array slices from the incoming
//!     CBOR buffer. Callers must not hold decoded values past the
//!     lifetime of the original frame payload.
//!   - Encoders return an owned `[]u8` containing the CBOR body.
//!
//! Keys follow camelCase to match cbor-x on the TS side; cbor-x doesn't
//! canonically sort map keys, but the decoder here is order-independent
//! so that's fine.

const std = @import("std");
const cbor = @import("cbor");
const frames = @import("frames.zig");

// ─── Common error types ─────────────────────────────────────────────

pub const DecodeError = cbor.DecodeError || error{
    MissingField,
    TooManyFields,
    OutOfMemory,
};

// ─── Hello (engine → runner) ────────────────────────────────────────
//
// Body: { "version": uint, "nodeLabel": uint, "protocol": text }

pub const Hello = struct {
    version: u32,
    node_label: u32,
    protocol: []const u8, // borrowed; decoded frames own the slice
};

pub fn encodeHello(alloc: std.mem.Allocator, h: Hello) ![]u8 {
    var w = cbor.Writer.init(alloc);
    errdefer w.deinit();

    try w.beginMap(3);
    try w.writeText("version");
    try w.writeUint(h.version);
    try w.writeText("nodeLabel");
    try w.writeUint(h.node_label);
    try w.writeText("protocol");
    try w.writeText(h.protocol);
    return try w.toOwnedSlice();
}

// ─── RunnerReady (runner → engine) ──────────────────────────────────
//
// Body: { "actors": [text, ...], "maxSlots": uint, "authToken"?: text }

pub const RunnerReady = struct {
    actors: [][]const u8,
    max_slots: u32 = 0,
    auth_token: ?[]const u8 = null,

    pub fn deinit(self: *RunnerReady, alloc: std.mem.Allocator) void {
        alloc.free(self.actors);
    }
};

pub fn decodeRunnerReady(alloc: std.mem.Allocator, body: []const u8) DecodeError!RunnerReady {
    var r = cbor.Reader.init(body);
    const n_fields = try r.mapLen();

    var out: RunnerReady = .{ .actors = &.{} };
    var saw_actors = false;
    errdefer if (saw_actors) alloc.free(out.actors);

    var i: usize = 0;
    while (i < n_fields) : (i += 1) {
        const key = try r.readText();
        if (std.mem.eql(u8, key, "actors")) {
            const n = try r.arrayLen();
            const arr = try alloc.alloc([]const u8, n);
            for (arr) |*slot| slot.* = try r.readText();
            out.actors = arr;
            saw_actors = true;
        } else if (std.mem.eql(u8, key, "maxSlots")) {
            const v = try r.readUint();
            out.max_slots = if (v > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(v);
        } else if (std.mem.eql(u8, key, "authToken")) {
            if (r.peekMajor()) |m| if (m == .simple) {
                try r.skip();
                continue;
            };
            out.auth_token = try r.readText();
        } else try r.skip();
    }

    if (!saw_actors) return DecodeError.MissingField;
    return out;
}

// ─── ActorStart (engine → runner) ────────────────────────────────────
//
// Body: {
//   "sid": text,          // 32-char lowercase hex
//   "actorName": text,
//   "reason": text,       // "create" | "wake" | "restart"
//   "input": any | null,  // optional
// }

pub const StartReason = enum { create, wake, restart };

pub const ActorStart = struct {
    session_id: []const u8,
    actor_name: []const u8,
    reason: StartReason,
    /// If non-null, emitted verbatim as a single CBOR value.
    input_cbor: ?[]const u8 = null,
};

pub fn encodeActorStart(alloc: std.mem.Allocator, m: ActorStart) ![]u8 {
    var w = cbor.Writer.init(alloc);
    errdefer w.deinit();

    const n_fields: usize = if (m.input_cbor != null) 4 else 3;
    try w.beginMap(n_fields);

    try w.writeText("sid");
    try w.writeText(m.session_id);

    try w.writeText("actorName");
    try w.writeText(m.actor_name);

    try w.writeText("reason");
    try w.writeText(@tagName(m.reason));

    if (m.input_cbor) |ic| {
        try w.writeText("input");
        try w.out.appendSlice(alloc, ic);
    }

    return try w.toOwnedSlice();
}

// ─── ActorStop (engine → runner) ─────────────────────────────────────
//
// Body: { "sessionId": text, "reason": text }

pub const StopReason = enum { idle, evicted, deploy, destroy, shutdown };

pub const ActorStop = struct {
    session_id: []const u8,
    reason: StopReason,
};

pub fn encodeActorStop(alloc: std.mem.Allocator, m: ActorStop) ![]u8 {
    var w = cbor.Writer.init(alloc);
    errdefer w.deinit();
    try w.beginMap(2);
    try w.writeText("sid");
    try w.writeText(m.session_id);
    try w.writeText("reason");
    try w.writeText(@tagName(m.reason));
    return try w.toOwnedSlice();
}

// ─── Result / Error (bidirectional) ──────────────────────────────────
//
// For v0, a typed Error body: { "code": text, "message": text }.

pub const ErrorBody = struct {
    code: []const u8,
    message: []const u8,
};

pub fn encodeError(alloc: std.mem.Allocator, e: ErrorBody) ![]u8 {
    var w = cbor.Writer.init(alloc);
    errdefer w.deinit();
    try w.beginMap(2);
    try w.writeText("code");
    try w.writeText(e.code);
    try w.writeText("message");
    try w.writeText(e.message);
    return try w.toOwnedSlice();
}

// ─── WsFrame (engine → runner) ────────────────────────────────────────
//
// Body: { sid: text, connectionId: text, kind: "text"|"binary", data: bytes }

pub const WsFrameKind = enum { text, binary };

pub const WsFrameMsg = struct {
    session_id: []const u8,
    connection_id: []const u8,
    kind: WsFrameKind,
    data: []const u8,
};

pub fn encodeWsFrame(alloc: std.mem.Allocator, m: WsFrameMsg) ![]u8 {
    var w = cbor.Writer.init(alloc);
    errdefer w.deinit();
    try w.beginMap(4);
    try w.writeText("sid");
    try w.writeText(m.session_id);
    try w.writeText("connectionId");
    try w.writeText(m.connection_id);
    try w.writeText("kind");
    try w.writeText(@tagName(m.kind));
    try w.writeText("data");
    if (m.kind == .text) {
        try w.writeText(m.data);
    } else {
        try w.writeBytesVal(m.data);
    }
    return try w.toOwnedSlice();
}

// ─── ConnectionMessage (runner → engine) ──────────────────────────────
//
// Body: {
//   sid: text,
//   connectionId: text ("*" for broadcast),
//   kind: "text" | "binary",
//   data: text | bytes,
//   exceptIds?: [text],   // connection ids to exclude; only meaningful with connectionId=="*"
// }
//
// `exceptIds` is allocated by the decoder (outer slice only — inner
// strings borrow from the CBOR buffer). Call `deinit(alloc)` to free.

pub const ConnectionMessage = struct {
    session_id: []const u8,
    connection_id: []const u8, // "*" means broadcast to all connections
    kind: WsFrameKind,
    data: []const u8,
    except_ids: []const []const u8 = &.{}, // owned outer slice, borrowed inner strings

    pub fn deinit(self: *ConnectionMessage, alloc: std.mem.Allocator) void {
        if (self.except_ids.len > 0) alloc.free(self.except_ids);
    }
};

pub fn decodeConnectionMessage(alloc: std.mem.Allocator, body: []const u8) DecodeError!ConnectionMessage {
    var r = cbor.Reader.init(body);
    const n = try r.mapLen();

    var out: ConnectionMessage = .{
        .session_id = "",
        .connection_id = "",
        .kind = .text,
        .data = "",
    };
    var saw_sid = false;
    var saw_cid = false;
    var saw_kind = false;
    var saw_data = false;
    var owns_except = false;
    errdefer if (owns_except) alloc.free(out.except_ids);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = try r.readText();
        if (std.mem.eql(u8, key, "sid")) {
            out.session_id = try r.readText();
            saw_sid = true;
        } else if (std.mem.eql(u8, key, "connectionId")) {
            out.connection_id = try r.readText();
            saw_cid = true;
        } else if (std.mem.eql(u8, key, "kind")) {
            const kstr = try r.readText();
            if (std.mem.eql(u8, kstr, "text")) {
                out.kind = .text;
            } else if (std.mem.eql(u8, kstr, "binary")) {
                out.kind = .binary;
            } else return DecodeError.TypeMismatch;
            saw_kind = true;
        } else if (std.mem.eql(u8, key, "data")) {
            // Accept either text or bytes major.
            switch (r.peekMajor() orelse return DecodeError.Truncated) {
                .text => out.data = try r.readText(),
                .bytes => out.data = try r.readBytes(),
                else => return DecodeError.TypeMismatch,
            }
            saw_data = true;
        } else if (std.mem.eql(u8, key, "exceptIds")) {
            // Null / undefined → empty list.
            if (r.peekMajor()) |m| if (m == .simple) {
                try r.skip();
                continue;
            };
            const arr_len = try r.arrayLen();
            if (arr_len > 0) {
                const arr = try alloc.alloc([]const u8, arr_len);
                for (arr) |*slot| slot.* = try r.readText();
                out.except_ids = arr;
                owns_except = true;
            }
        } else {
            try r.skip();
        }
    }

    if (!saw_sid or !saw_cid or !saw_kind or !saw_data) return DecodeError.MissingField;
    return out;
}

// ─── Generate (runner → engine, streaming) ───────────────────────────
//
// Request body: { sid: text, modelId: text, prompt: text, opts?: map }
// Response: a stream of TokenChunk frames with the same tag, terminated
// by a Result frame.

pub const GenerateMsg = struct {
    session_id: []const u8,
    model_id: []const u8,
    prompt: []const u8,
    max_tokens: u32 = 0, // 0 = no cap
    temperature: f32 = 0.7,
};

pub fn decodeGenerate(body: []const u8) DecodeError!GenerateMsg {
    var r = cbor.Reader.init(body);
    const n = try r.mapLen();

    var out: GenerateMsg = .{
        .session_id = "",
        .model_id = "",
        .prompt = "",
    };
    var saw_sid = false;
    var saw_model = false;
    var saw_prompt = false;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = try r.readText();
        if (std.mem.eql(u8, key, "sid")) {
            out.session_id = try r.readText();
            saw_sid = true;
        } else if (std.mem.eql(u8, key, "modelId")) {
            out.model_id = try r.readText();
            saw_model = true;
        } else if (std.mem.eql(u8, key, "prompt")) {
            out.prompt = try r.readText();
            saw_prompt = true;
        } else if (std.mem.eql(u8, key, "opts")) {
            // Optional: skip for now; the stub generator doesn't use it.
            if (r.peekMajor()) |m| if (m == .simple) {
                try r.skip();
                continue;
            };
            // Might be a map — skip whole value regardless.
            try r.skip();
        } else {
            try r.skip();
        }
    }

    if (!saw_sid or !saw_model or !saw_prompt) return DecodeError.MissingField;
    return out;
}

// ─── TokenChunk (engine → runner, streaming) ─────────────────────────
//
// Body: { tokens: [Token], done: bool }
// Token: { text: text, tokenId: int, pos: int }

pub const Token = struct {
    text: []const u8,
    token_id: i64 = 0,
    pos: i64 = 0,
};

pub fn encodeTokenChunk(alloc: std.mem.Allocator, tokens: []const Token, done: bool) ![]u8 {
    var w = cbor.Writer.init(alloc);
    errdefer w.deinit();
    try w.beginMap(2);
    try w.writeText("tokens");
    try w.beginArray(tokens.len);
    for (tokens) |t| {
        try w.beginMap(3);
        try w.writeText("text");
        try w.writeText(t.text);
        try w.writeText("tokenId");
        try w.writeInt(t.token_id);
        try w.writeText("pos");
        try w.writeInt(t.pos);
    }
    try w.writeText("done");
    try w.writeBool(done);
    return try w.toOwnedSlice();
}

// ─── ConnectionClose (runner → engine) ────────────────────────────────
//
// Body: { sid: text, connectionId: text, code?: uint, reason?: text }

pub const ConnectionCloseMsg = struct {
    session_id: []const u8,
    connection_id: []const u8,
    code: u16 = 1000,
    reason: []const u8 = "",
};

pub fn decodeConnectionClose(body: []const u8) DecodeError!ConnectionCloseMsg {
    var r = cbor.Reader.init(body);
    const n = try r.mapLen();
    var out: ConnectionCloseMsg = .{ .session_id = "", .connection_id = "" };
    var saw_sid = false;
    var saw_cid = false;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = try r.readText();
        if (std.mem.eql(u8, key, "sid")) {
            out.session_id = try r.readText();
            saw_sid = true;
        } else if (std.mem.eql(u8, key, "connectionId")) {
            out.connection_id = try r.readText();
            saw_cid = true;
        } else if (std.mem.eql(u8, key, "code")) {
            const c = try r.readUint();
            out.code = if (c > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(c);
        } else if (std.mem.eql(u8, key, "reason")) {
            out.reason = try r.readText();
        } else try r.skip();
    }
    if (!saw_sid or !saw_cid) return DecodeError.MissingField;
    return out;
}

// ─── Wire-level helpers (frame = header + body) ──────────────────────
//
// Convenience: encode a body via one of the encoders above and wrap it
// in a tunnel frame. Returns an owned slice.

pub fn encodeFrameWithBody(
    alloc: std.mem.Allocator,
    kind: frames.Opcode,
    tag: u32,
    body: []const u8,
) ![]u8 {
    return try frames.encode(alloc, kind, tag, body);
}

// ─── tests ───────────────────────────────────────────────────────────

test "hello encode is valid CBOR" {
    const alloc = std.testing.allocator;
    const bytes = try encodeHello(alloc, .{
        .version = 1,
        .node_label = 0x0001,
        .protocol = "dis/v0",
    });
    defer alloc.free(bytes);

    var r = cbor.Reader.init(bytes);
    try std.testing.expectEqual(@as(usize, 3), try r.mapLen());
    try std.testing.expectEqualStrings("version", try r.readText());
    try std.testing.expectEqual(@as(u64, 1), try r.readUint());
    try std.testing.expectEqualStrings("nodeLabel", try r.readText());
    try std.testing.expectEqual(@as(u64, 1), try r.readUint());
    try std.testing.expectEqualStrings("protocol", try r.readText());
    try std.testing.expectEqualStrings("dis/v0", try r.readText());
    try std.testing.expect(r.eof());
}

test "runner ready roundtrip" {
    const alloc = std.testing.allocator;
    var w = cbor.Writer.init(alloc);
    defer w.deinit();
    try w.beginMap(3);
    try w.writeText("actors");
    try w.beginArray(2);
    try w.writeText("chat");
    try w.writeText("echo");
    try w.writeText("maxSlots");
    try w.writeUint(64);
    try w.writeText("authToken");
    try w.writeText("s3cret");

    var decoded = try decodeRunnerReady(alloc, w.bytes());
    defer decoded.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), decoded.actors.len);
    try std.testing.expectEqualStrings("chat", decoded.actors[0]);
    try std.testing.expectEqualStrings("echo", decoded.actors[1]);
    try std.testing.expectEqual(@as(u32, 64), decoded.max_slots);
    try std.testing.expectEqualStrings("s3cret", decoded.auth_token.?);
}

test "runner ready without optional authToken" {
    const alloc = std.testing.allocator;
    var w = cbor.Writer.init(alloc);
    defer w.deinit();
    try w.beginMap(2);
    try w.writeText("actors");
    try w.beginArray(1);
    try w.writeText("echo");
    try w.writeText("maxSlots");
    try w.writeUint(10);

    var decoded = try decodeRunnerReady(alloc, w.bytes());
    defer decoded.deinit(alloc);
    try std.testing.expectEqual(@as(?[]const u8, null), decoded.auth_token);
    try std.testing.expectEqual(@as(u32, 10), decoded.max_slots);
}

test "runner ready with null authToken" {
    const alloc = std.testing.allocator;
    var w = cbor.Writer.init(alloc);
    defer w.deinit();
    try w.beginMap(3);
    try w.writeText("actors");
    try w.beginArray(0);
    try w.writeText("maxSlots");
    try w.writeUint(1);
    try w.writeText("authToken");
    try w.writeNull();

    var decoded = try decodeRunnerReady(alloc, w.bytes());
    defer decoded.deinit(alloc);
    try std.testing.expectEqual(@as(?[]const u8, null), decoded.auth_token);
}

test "runner ready missing actors field" {
    const alloc = std.testing.allocator;
    var w = cbor.Writer.init(alloc);
    defer w.deinit();
    try w.beginMap(1);
    try w.writeText("maxSlots");
    try w.writeUint(1);
    try std.testing.expectError(DecodeError.MissingField, decodeRunnerReady(alloc, w.bytes()));
}

test "actor start encode without input" {
    const alloc = std.testing.allocator;
    const bytes = try encodeActorStart(alloc, .{
        .session_id = "sid-abc",
        .actor_name = "Agent",
        .reason = .create,
    });
    defer alloc.free(bytes);

    var r = cbor.Reader.init(bytes);
    try std.testing.expectEqual(@as(usize, 3), try r.mapLen());

    try std.testing.expectEqualStrings("sid", try r.readText());
    try std.testing.expectEqualStrings("sid-abc", try r.readText());
    try std.testing.expectEqualStrings("actorName", try r.readText());
    try std.testing.expectEqualStrings("Agent", try r.readText());
    try std.testing.expectEqualStrings("reason", try r.readText());
    try std.testing.expectEqualStrings("create", try r.readText());
    try std.testing.expect(r.eof());
}

test "actor start encode with raw input cbor" {
    const alloc = std.testing.allocator;

    var input_w = cbor.Writer.init(alloc);
    defer input_w.deinit();
    try input_w.beginMap(1);
    try input_w.writeText("foo");
    try input_w.writeUint(1);

    const bytes = try encodeActorStart(alloc, .{
        .session_id = "sid",
        .actor_name = "A",
        .reason = .wake,
        .input_cbor = input_w.bytes(),
    });
    defer alloc.free(bytes);

    var r = cbor.Reader.init(bytes);
    try std.testing.expectEqual(@as(usize, 4), try r.mapLen());
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        _ = try r.readText();
        try r.skip();
    }
    try std.testing.expectEqualStrings("input", try r.readText());
    try std.testing.expectEqual(@as(usize, 1), try r.mapLen());
    try std.testing.expectEqualStrings("foo", try r.readText());
    try std.testing.expectEqual(@as(u64, 1), try r.readUint());
}

test "decodeConnectionMessage text broadcast with exceptIds" {
    const alloc = std.testing.allocator;
    var w = cbor.Writer.init(alloc);
    defer w.deinit();
    try w.beginMap(5);
    try w.writeText("sid");
    try w.writeText("abc");
    try w.writeText("connectionId");
    try w.writeText("*");
    try w.writeText("kind");
    try w.writeText("text");
    try w.writeText("data");
    try w.writeText("hi");
    try w.writeText("exceptIds");
    try w.beginArray(2);
    try w.writeText("c1");
    try w.writeText("c2");

    var m = try decodeConnectionMessage(alloc, w.bytes());
    defer m.deinit(alloc);
    try std.testing.expectEqualStrings("abc", m.session_id);
    try std.testing.expectEqualStrings("*", m.connection_id);
    try std.testing.expectEqual(WsFrameKind.text, m.kind);
    try std.testing.expectEqualStrings("hi", m.data);
    try std.testing.expectEqual(@as(usize, 2), m.except_ids.len);
    try std.testing.expectEqualStrings("c1", m.except_ids[0]);
    try std.testing.expectEqualStrings("c2", m.except_ids[1]);
}

test "decodeConnectionMessage omits exceptIds entirely" {
    const alloc = std.testing.allocator;
    var w = cbor.Writer.init(alloc);
    defer w.deinit();
    try w.beginMap(4);
    try w.writeText("sid");
    try w.writeText("s");
    try w.writeText("connectionId");
    try w.writeText("c");
    try w.writeText("kind");
    try w.writeText("text");
    try w.writeText("data");
    try w.writeText("hi");

    var m = try decodeConnectionMessage(alloc, w.bytes());
    defer m.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), m.except_ids.len);
}

test "decodeConnectionMessage with null exceptIds" {
    const alloc = std.testing.allocator;
    var w = cbor.Writer.init(alloc);
    defer w.deinit();
    try w.beginMap(5);
    try w.writeText("sid");
    try w.writeText("s");
    try w.writeText("connectionId");
    try w.writeText("*");
    try w.writeText("kind");
    try w.writeText("text");
    try w.writeText("data");
    try w.writeText("hi");
    try w.writeText("exceptIds");
    try w.writeNull();

    var m = try decodeConnectionMessage(alloc, w.bytes());
    defer m.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), m.except_ids.len);
}

test "decodeConnectionMessage binary" {
    const alloc = std.testing.allocator;
    var w = cbor.Writer.init(alloc);
    defer w.deinit();
    try w.beginMap(4);
    try w.writeText("sid");
    try w.writeText("s");
    try w.writeText("connectionId");
    try w.writeText("c");
    try w.writeText("kind");
    try w.writeText("binary");
    try w.writeText("data");
    try w.writeBytesVal(&[_]u8{ 0xDE, 0xAD });
    var m = try decodeConnectionMessage(alloc, w.bytes());
    defer m.deinit(alloc);
    try std.testing.expectEqual(WsFrameKind.binary, m.kind);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD }, m.data);
}

test "encodeWsFrame text shape" {
    const alloc = std.testing.allocator;
    const bytes = try encodeWsFrame(alloc, .{
        .session_id = "sid",
        .connection_id = "c",
        .kind = .text,
        .data = "hi",
    });
    defer alloc.free(bytes);
    var r = cbor.Reader.init(bytes);
    try std.testing.expectEqual(@as(usize, 4), try r.mapLen());
    try std.testing.expectEqualStrings("sid", try r.readText());
    try std.testing.expectEqualStrings("sid", try r.readText());
    try std.testing.expectEqualStrings("connectionId", try r.readText());
    try std.testing.expectEqualStrings("c", try r.readText());
    try std.testing.expectEqualStrings("kind", try r.readText());
    try std.testing.expectEqualStrings("text", try r.readText());
    try std.testing.expectEqualStrings("data", try r.readText());
    try std.testing.expectEqualStrings("hi", try r.readText());
}


