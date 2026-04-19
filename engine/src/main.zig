//! dis-engine entry point.

const std = @import("std");
const loadFromFile = @import("config.zig").loadFromFile;
const Runtime = @import("runtime/runtime.zig").Runtime;
const Server = @import("http/server.zig").Server;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    // Parse argv: first non-program arg is the config path.
    var iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer iter.deinit();
    _ = iter.next(); // program name
    const config_path_arg = iter.next();
    const config_path = if (config_path_arg) |p| p else "config.json";

    const cfg = loadFromFile(alloc, io, std.Io.Dir.cwd(), config_path) catch |e| {
        std.log.err("failed to load config from {s}: {}", .{ config_path, e });
        std.process.exit(1);
    };

    var rt = try Runtime.init(alloc, io, cfg);
    defer rt.deinit();
    rt.finalize();

    var srv = try Server.init(alloc, io, &rt);
    defer srv.deinit();

    try srv.serve();
}
