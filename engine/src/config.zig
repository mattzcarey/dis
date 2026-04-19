//! Engine configuration loaded from a JSON file at startup.
//!
//! Schema: see config.example.json.

const std = @import("std");

pub const Config = struct {
    bind: []const u8 = "127.0.0.1:7070",
    data_dir: []const u8 = "./data",
    auth_tokens_file: ?[]const u8 = null,
    idle_ms: u64 = 300_000,
    checkpoint_ms: u64 = 60_000,
    default_max_tokens: u32 = 2048,
    state_save_interval_ms: u32 = 1000,
    max_state_bytes: u32 = 1024 * 1024,
    model: ModelConfig,

    /// Optional: after a runner registers, mint one bootstrap session
    /// for the named actor. Useful for smoke-testing before any clients
    /// connect. The minted session's sid is just logged; it's otherwise
    /// identical to a client-minted session.
    bootstrap_actor: ?[]const u8 = null,

    pub const ModelConfig = struct {
        id: []const u8,
        source: []const u8,
        seq_capacity: u32 = 8192,
        max_live_sessions: u32 = 64,
    };

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        alloc.free(self.bind);
        alloc.free(self.data_dir);
        if (self.auth_tokens_file) |p| alloc.free(p);
        alloc.free(self.model.id);
        alloc.free(self.model.source);
        if (self.bootstrap_actor) |s| alloc.free(s);
    }
};

pub const LoadError = error{
    OpenFailed,
    InvalidJson,
    MissingField,
    OutOfMemory,
};

/// Load config from a JSON file under `dir`. Strings heap-allocated on `alloc`.
pub fn loadFromFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
) !Config {
    const file = dir.openFile(io, path, .{}) catch |e| {
        std.log.err("config: cannot open {s}: {}", .{ path, e });
        return LoadError.OpenFailed;
    };
    defer file.close(io);

    const len = try file.length(io);
    const body = try alloc.alloc(u8, @intCast(len));
    defer alloc.free(body);
    _ = try file.readPositionalAll(io, body, 0);

    return try parseJson(alloc, body);
}

pub fn parseJson(alloc: std.mem.Allocator, src: []const u8) !Config {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        src,
        .{ .ignore_unknown_fields = true },
    ) catch return LoadError.InvalidJson;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return LoadError.InvalidJson;
    const obj = root.object;

    var cfg: Config = .{
        .bind = try alloc.dupe(u8, "127.0.0.1:7070"),
        .data_dir = try alloc.dupe(u8, "./data"),
        .auth_tokens_file = null,
        .model = .{
            .id = try alloc.dupe(u8, ""),
            .source = try alloc.dupe(u8, ""),
        },
    };
    errdefer cfg.deinit(alloc);

    if (obj.get("bind")) |v| {
        alloc.free(cfg.bind);
        cfg.bind = try alloc.dupe(u8, v.string);
    }
    if (obj.get("data_dir")) |v| {
        alloc.free(cfg.data_dir);
        cfg.data_dir = try alloc.dupe(u8, v.string);
    }
    if (obj.get("auth_tokens_file")) |v| {
        if (v == .string) cfg.auth_tokens_file = try alloc.dupe(u8, v.string);
    }
    if (obj.get("idle_ms")) |v| cfg.idle_ms = @intCast(v.integer);
    if (obj.get("checkpoint_ms")) |v| cfg.checkpoint_ms = @intCast(v.integer);
    if (obj.get("default_max_tokens")) |v| cfg.default_max_tokens = @intCast(v.integer);
    if (obj.get("state_save_interval_ms")) |v| cfg.state_save_interval_ms = @intCast(v.integer);
    if (obj.get("max_state_bytes")) |v| cfg.max_state_bytes = @intCast(v.integer);

    const model = obj.get("model") orelse return LoadError.MissingField;
    if (model != .object) return LoadError.InvalidJson;
    const m = model.object;
    if (m.get("id")) |v| {
        alloc.free(cfg.model.id);
        cfg.model.id = try alloc.dupe(u8, v.string);
    } else return LoadError.MissingField;
    if (m.get("source")) |v| {
        alloc.free(cfg.model.source);
        cfg.model.source = try alloc.dupe(u8, v.string);
    } else return LoadError.MissingField;
    if (m.get("seq_capacity")) |v| cfg.model.seq_capacity = @intCast(v.integer);
    if (m.get("max_live_sessions")) |v| cfg.model.max_live_sessions = @intCast(v.integer);

    if (obj.get("bootstrap_actor")) |v| {
        if (v != .string) return LoadError.InvalidJson;
        cfg.bootstrap_actor = try alloc.dupe(u8, v.string);
    }

    return cfg;
}

// ── tests ─────────────────────────────────────────────────────────────

test "parse minimal config" {
    const src =
        \\{
        \\  "model": { "id": "test-model", "source": "hf://test/test" }
        \\}
    ;
    var cfg = try parseJson(std.testing.allocator, src);
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("test-model", cfg.model.id);
    try std.testing.expectEqual(@as(u32, 8192), cfg.model.seq_capacity);
}

test "parse full config" {
    const src =
        \\{
        \\  "bind": "0.0.0.0:8080",
        \\  "data_dir": "/var/lib/dis",
        \\  "idle_ms": 60000,
        \\  "model": {
        \\    "id": "m", "source": "hf://m",
        \\    "seq_capacity": 4096, "max_live_sessions": 32
        \\  },
        \\  "bootstrap_actor": "echo"
        \\}
    ;
    var cfg = try parseJson(std.testing.allocator, src);
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("0.0.0.0:8080", cfg.bind);
    try std.testing.expectEqual(@as(u32, 4096), cfg.model.seq_capacity);
    try std.testing.expectEqualStrings("echo", cfg.bootstrap_actor.?);
}

test "parseJson rejects missing model" {
    try std.testing.expectError(
        LoadError.MissingField,
        parseJson(std.testing.allocator, "{}"),
    );
}
