//! Metadata database — session registry persistence.
//!
//! v0 IN-MEMORY ONLY. Zig 0.16's std.Io.Dir API is still stabilising;
//! rather than couple M0 to it I'm keeping the registry in memory and
//! landing the JSONL journal / SQLite backend in M1 when I tackle
//! persistence for real (KV snapshots, per-session sqlite, state blobs
//! all need the same plumbing).
//!
//! Callers see the `MetaDb` interface below; when we wire up a real
//! backend the call sites don't change.

const std = @import("std");
const id_mod = @import("../util/id.zig");
const log = @import("log").scoped("meta_db");

pub const Phase = enum {
    provisioning,
    loading,
    running,
    idle,
    hibernating,
    hibernated,
    destroying,
    destroyed,

    pub fn toString(self: Phase) []const u8 { return @tagName(self); }

    pub fn fromString(s: []const u8) !Phase {
        inline for (@typeInfo(Phase).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @field(Phase, f.name);
        }
        return error.UnknownPhase;
    }
};

pub const SessionRow = struct {
    id: id_mod.Id128,
    namespace: []const u8,
    actor_name: []const u8,
    model_id: []const u8,
    key_packed: []const u8,
    phase: Phase,
    created_ms: i64,
    last_used_ms: i64,
    seq_capacity: u32,
    kv_cursor: u32 = 0,
    state_version: u64 = 0,
    kv_version: u64 = 0,
};

pub const MetaDb = struct {
    alloc: std.mem.Allocator,
    rows: std.AutoHashMap(id_mod.Id128, SessionRow),

    // M0 is single-threaded. When we parallelise session handling in M1
    // this grows a std.Io.Mutex — all methods already take &self so the
    // lock/unlock pairs drop in cleanly.

    pub fn open(alloc: std.mem.Allocator) !MetaDb {
        log.info("meta_db opened (in-memory v0)", .{});
        return .{
            .alloc = alloc,
            .rows = std.AutoHashMap(id_mod.Id128, SessionRow).init(alloc),
        };
    }

    pub fn deinit(self: *MetaDb) void {
        var it = self.rows.iterator();
        while (it.next()) |e| freeRow(self.alloc, e.value_ptr.*);
        self.rows.deinit();
    }

    pub fn upsert(self: *MetaDb, row: SessionRow) !void {
        const owned: SessionRow = .{
            .id = row.id,
            .namespace = try self.alloc.dupe(u8, row.namespace),
            .actor_name = try self.alloc.dupe(u8, row.actor_name),
            .model_id = try self.alloc.dupe(u8, row.model_id),
            .key_packed = try self.alloc.dupe(u8, row.key_packed),
            .phase = row.phase,
            .created_ms = row.created_ms,
            .last_used_ms = row.last_used_ms,
            .seq_capacity = row.seq_capacity,
            .kv_cursor = row.kv_cursor,
            .state_version = row.state_version,
            .kv_version = row.kv_version,
        };
        if (try self.rows.fetchPut(row.id, owned)) |kv| {
            freeRow(self.alloc, kv.value);
        }
    }

    pub fn delete(self: *MetaDb, sid: id_mod.Id128) !void {
        if (self.rows.fetchRemove(sid)) |kv| freeRow(self.alloc, kv.value);
    }

    pub fn loadAll(self: *MetaDb, alloc: std.mem.Allocator) ![]SessionRow {
        var out = try alloc.alloc(SessionRow, self.rows.count());
        var i: usize = 0;
        var it = self.rows.iterator();
        while (it.next()) |e| : (i += 1) {
            out[i] = e.value_ptr.*;
        }
        return out;
    }

    pub fn count(self: *MetaDb) u64 {
        return @intCast(self.rows.count());
    }

    fn freeRow(alloc: std.mem.Allocator, row: SessionRow) void {
        alloc.free(row.namespace);
        alloc.free(row.actor_name);
        alloc.free(row.model_id);
        alloc.free(row.key_packed);
    }
};

// ── tests ─────────────────────────────────────────────────────────────

test "upsert + loadAll roundtrip" {
    var db = try MetaDb.open(std.testing.allocator);
    defer db.deinit();

    const row: SessionRow = .{
        .id = [_]u8{0x01} ** 16,
        .namespace = "my-app",
        .actor_name = "agent",
        .model_id = "llama",
        .key_packed = "user/42",
        .phase = .hibernated,
        .created_ms = 1000,
        .last_used_ms = 2000,
        .seq_capacity = 4096,
        .kv_cursor = 100,
        .state_version = 5,
        .kv_version = 3,
    };
    try db.upsert(row);

    const rows = try db.loadAll(std.testing.allocator);
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(Phase.hibernated, rows[0].phase);
    try std.testing.expectEqual(@as(u32, 100), rows[0].kv_cursor);
    try std.testing.expectEqualStrings("my-app", rows[0].namespace);
}

test "upsert overwrites same id" {
    var db = try MetaDb.open(std.testing.allocator);
    defer db.deinit();

    const sid = [_]u8{0xAB} ** 16;
    try db.upsert(.{
        .id = sid, .namespace = "n", .actor_name = "a", .model_id = "m",
        .key_packed = "k", .phase = .running, .created_ms = 0,
        .last_used_ms = 0, .seq_capacity = 1024, .kv_cursor = 10,
    });
    try db.upsert(.{
        .id = sid, .namespace = "n", .actor_name = "a", .model_id = "m",
        .key_packed = "k", .phase = .idle, .created_ms = 0,
        .last_used_ms = 0, .seq_capacity = 1024, .kv_cursor = 50,
    });

    try std.testing.expectEqual(@as(u64, 1), db.count());
    const rows = try db.loadAll(std.testing.allocator);
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqual(Phase.idle, rows[0].phase);
    try std.testing.expectEqual(@as(u32, 50), rows[0].kv_cursor);
}

test "delete removes row" {
    var db = try MetaDb.open(std.testing.allocator);
    defer db.deinit();

    const sid = [_]u8{0xCD} ** 16;
    try db.upsert(.{
        .id = sid, .namespace = "n", .actor_name = "a", .model_id = "m",
        .key_packed = "k", .phase = .running, .created_ms = 0,
        .last_used_ms = 0, .seq_capacity = 1024,
    });
    try db.delete(sid);
    try std.testing.expectEqual(@as(u64, 0), db.count());
}
