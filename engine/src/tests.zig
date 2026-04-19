//! Test aggregator. `zig build test-engine` compiles this root, which
//! pulls in every engine module's embedded `test` blocks, plus the
//! shared `cbor` module (engine is its primary consumer).

comptime {
    _ = @import("cbor"); // common/cbor.zig
    _ = @import("util/id.zig");
    _ = @import("util/route.zig");
    _ = @import("config.zig");
    _ = @import("storage/meta_db.zig");
    _ = @import("http/server.zig");
    _ = @import("http/request.zig");
    _ = @import("ws/handshake.zig");
    _ = @import("ws/frame.zig");
    _ = @import("tunnel/frames.zig");
    _ = @import("tunnel/messages.zig");
    _ = @import("tunnel/pending.zig");
    _ = @import("tunnel/runner_conn.zig");
    _ = @import("tunnel/hub.zig");
    _ = @import("tunnel/connection.zig");
    _ = @import("generate/stub.zig");
}
