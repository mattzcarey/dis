//! Public entry point of the `infer` module — re-exports everything
//! the binary and smoke client consume. Other internals (conn, config,
//! handlers) stay file-local to their callers in `main.zig`.

pub const frames = @import("frames.zig");
pub const messages = @import("messages.zig");
pub const cbor = @import("cbor");
