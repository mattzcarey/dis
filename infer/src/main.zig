//! dis-infer entry point.
//!
//! Binds a unix socket, accepts connections (one at a time for M1 —
//! the engine is the only expected peer), and runs the per-connection
//! frame loop in-place. Multi-accept + concurrent connection tasks
//! via `std.Io.Group` land alongside the move to a real model in M2.

const std = @import("std");
const log = @import("log").scoped("infer.main");

const Config = @import("config.zig").Config;
const Conn = @import("conn.zig").Conn;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer it.deinit();
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(alloc);
    while (it.next()) |a| try argv.append(alloc, a);

    const cfg = try Config.fromArgv(alloc, argv.items);

    // Remove stale socket from a previous run (best-effort).
    std.Io.Dir.cwd().deleteFile(io, cfg.socket_path) catch {};

    const addr = try std.Io.net.UnixAddress.init(cfg.socket_path);
    var listener = addr.listen(io, .{ .kernel_backlog = 16 }) catch |e| {
        log.err("bind {s}: {}", .{ cfg.socket_path, e });
        std.process.exit(1);
    };
    defer listener.deinit(io);
    log.info("listening on {s}", .{cfg.socket_path});

    while (true) {
        const stream = listener.accept(io) catch |e| {
            log.warn("accept: {}", .{e});
            continue;
        };
        const conn = Conn.create(alloc, io, stream) catch |e| {
            log.warn("create conn: {}", .{e});
            stream.close(io);
            continue;
        };
        log.info("engine connected", .{});
        conn.run();
        log.info("engine disconnected", .{});
        conn.destroy();
    }
}
