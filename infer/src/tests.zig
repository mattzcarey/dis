//! Test aggregator. `zig build test-infer` compiles this root,
//! pulling in every infer module's embedded `test` blocks.

comptime {
    _ = @import("frames.zig");
    _ = @import("messages.zig");
    _ = @import("llama.zig");
    _ = @import("handlers.zig");
    _ = @import("config.zig");
}

