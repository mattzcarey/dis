//! Top-level Runtime. Owns long-lived subsystems:
//!   - Config (immutable)
//!   - MetaDb (session/actor metadata persistence; in-memory stub in M0)
//!   - TunnelHub (runner/session registry)
//!   - `conn_group` (std.Io.Group collecting per-connection tasks)
//!   - PRNG (seeded from io.random())
//!
//! The Runtime struct is heap-allocated and passed as `*Runtime` to the
//! http server and tunnel hub. Mutation happens via the hub's own lock.

const std = @import("std");
const log = @import("log").scoped("runtime");
const Config = @import("../config.zig").Config;
const MetaDb = @import("../storage/meta_db.zig").MetaDb;
const hub_mod = @import("../tunnel/hub.zig");
const TunnelHub = hub_mod.TunnelHub;
const runner_conn = @import("../tunnel/runner_conn.zig");

pub const Runtime = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    meta_db: MetaDb,
    hub: TunnelHub,

    /// Holds all per-connection tasks spawned by the http server. On
    /// shutdown we `await` this group to drain cleanly.
    conn_group: std.Io.Group = .init,

    prng: std.Random.Xoshiro256,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, cfg: Config) !Runtime {
        const meta_db = try MetaDb.open(alloc);

        var seed_bytes: [8]u8 = undefined;
        io.random(&seed_bytes);
        const seed = std.mem.readInt(u64, &seed_bytes, .little);
        const prng: std.Random.Xoshiro256 = std.Random.Xoshiro256.init(seed);

        log.info("initialized", .{});

        var rt: Runtime = .{
            .alloc = alloc,
            .io = io,
            .cfg = cfg,
            .meta_db = meta_db,
            .hub = undefined,
            .prng = prng,
        };
        // Hub holds a pointer to our PRNG field, so it must be
        // initialised after `rt` is in its final location. `finalize()`
        // re-points `hub.prng` at `&rt.prng` once the caller has placed
        // the Runtime at its stable address.
        _ = &rt;
        rt.hub = TunnelHub.init(alloc, io, &rt.prng);
        return rt;
    }

    /// Call after the Runtime has been placed at its final memory
    /// location (since TunnelHub captures `&rt.prng`). Installs the
    /// hub-calls vtable used by RunnerConn for inbound dispatch.
    pub fn finalize(self: *Runtime) void {
        self.hub.prng = &self.prng;
        runner_conn.installHubCalls(.{
            .routeConnectionMessage = routeConnectionMessageThunk,
        });
    }

    pub fn deinit(self: *Runtime) void {
        // Drain any in-flight per-connection tasks.
        self.conn_group.await(self.io) catch {};
        self.hub.deinit();
        self.meta_db.deinit();
        self.cfg.deinit(self.alloc);
    }
};

// ─── HubCalls thunks ─────────────────────────────────────────────────

fn routeConnectionMessageThunk(
    ref: *runner_conn.HubRef,
    sid_hex: []const u8,
    connection_id: []const u8,
    is_text: bool,
    data: []const u8,
    except_ids: []const []const u8,
) void {
    const hub = TunnelHub.fromRef(ref);
    hub.routeConnectionMessage(sid_hex, connection_id, is_text, data, except_ids);
}
