//! Runtime config for dis-infer.
//!
//! M1 keeps this tiny: one unix socket path. A future M2 pass adds a
//! JSON config file (socket_path, model_path, n_ctx, n_gpu_layers,
//! max_seqs, …) to match the engine's config.zig shape.

const std = @import("std");

pub const Config = struct {
    /// Absolute path to the unix socket to listen on. The engine
    /// connects here. We default to `/tmp/dis-infer.sock` on macOS/Linux
    /// so dev doesn't need root to create `/run/dis/`.
    socket_path: []const u8 = "/tmp/dis-infer.sock",

    pub fn fromArgv(alloc: std.mem.Allocator, argv: []const []const u8) !Config {
        _ = alloc; // reserved for when we start duping strings.
        var cfg: Config = .{};
        // First positional arg (after program name) overrides the socket path.
        if (argv.len >= 2) cfg.socket_path = argv[1];
        return cfg;
    }
};
