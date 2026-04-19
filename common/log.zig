//! Thin wrapper over std.log for consistent prefixing across both
//! `dis-engine` and `dis-infer`. Shared via the `log` module wired in
//! `build.zig`.
//!
//! Usage:
//!   const log = @import("log").scoped("http");
//!   log.info("listening on {s}", .{addr});

const std = @import("std");

pub fn scoped(comptime name: []const u8) type {
    return struct {
        const log_scope = std.log.scoped(std.meta.stringToEnum(enum { default }, "default") orelse .default);

        pub fn info(comptime fmt: []const u8, args: anytype) void {
            std.log.info("[{s}] " ++ fmt, .{name} ++ args);
        }
        pub fn warn(comptime fmt: []const u8, args: anytype) void {
            std.log.warn("[{s}] " ++ fmt, .{name} ++ args);
        }
        pub fn err(comptime fmt: []const u8, args: anytype) void {
            std.log.err("[{s}] " ++ fmt, .{name} ++ args);
        }
        pub fn debug(comptime fmt: []const u8, args: anytype) void {
            std.log.debug("[{s}] " ++ fmt, .{name} ++ args);
        }
    };
}
