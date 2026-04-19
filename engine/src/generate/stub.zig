//! Mock token generator.
//!
//! Splits the prompt on whitespace, then streams one pseudo-token back
//! every `delay_ms` milliseconds until the prompt is exhausted. Also
//! appends a short canned reply so the stream has visible output even
//! for empty prompts.
//!
//! Replaced by a real dispatch to `dis-infer` once that binary lands.
//! The public surface here — `streamStub()` — is the signature the real
//! generate-path will implement; callers in runner_conn don't change.

const std = @import("std");
const log = @import("log").scoped("gen");

const messages = @import("../tunnel/messages.zig");
const frames = @import("../tunnel/frames.zig");
const RunnerConn = @import("../tunnel/runner_conn.zig").RunnerConn;

const Io = std.Io;

pub const DEFAULT_DELAY_MS: u64 = 40;

const CANNED_SUFFIX = [_][]const u8{ " —", " generated", " by", " dis", " stub." };

/// Stream a mock response to `prompt` back over `rc` using tunnel tag
/// `tag`. Sends TokenChunk frames as it goes; terminates with a Result
/// frame so the caller's awaited Promise resolves.
///
/// Blocks the caller task until the stream completes.
pub fn streamStub(
    rc: *RunnerConn,
    io: Io,
    tag: u32,
    prompt: []const u8,
    max_tokens: u32,
    delay_ms: u64,
) void {
    const cap: usize = if (max_tokens == 0) std.math.maxInt(usize) else max_tokens;
    var sent: usize = 0;
    var pos: i64 = 0;

    // Echo the prompt word-by-word first. Prepend a space to each word
    // after the first so concatenated deltas render naturally — mirrors
    // how real tokenizers (SentencePiece/BPE) emit leading-space tokens.
    var it = std.mem.tokenizeAny(u8, prompt, " \t\n\r");
    var prefix_buf: [256]u8 = undefined;
    var first = true;
    while (it.next()) |word| {
        if (sent >= cap) break;
        const emit: []const u8 = if (first) word else blk: {
            if (word.len + 1 > prefix_buf.len) break :blk word;
            prefix_buf[0] = ' ';
            @memcpy(prefix_buf[1 .. 1 + word.len], word);
            break :blk prefix_buf[0 .. 1 + word.len];
        };
        sendOne(rc, io, tag, emit, pos, false);
        sent += 1;
        pos += 1;
        first = false;
        sleep(io, delay_ms);
    }

    // Then a short canned suffix.
    for (CANNED_SUFFIX) |w| {
        if (sent >= cap) break;
        sendOne(rc, io, tag, w, pos, false);
        sent += 1;
        pos += 1;
        sleep(io, delay_ms);
    }

    // Final frame: empty token list + done=true.
    sendDone(rc, tag);

    // Terminating Result so awaited Promise on the SDK side resolves.
    const result_body = [_]u8{0xF6}; // CBOR null
    rc.sendOneWay(.result, tag, &result_body) catch |e| {
        log.warn("stream result send: {}", .{e});
    };
}

fn sendOne(rc: *RunnerConn, io: Io, tag: u32, text: []const u8, pos: i64, done: bool) void {
    _ = io;
    const toks = [_]messages.Token{.{ .text = text, .token_id = 0, .pos = pos }};
    const body = messages.encodeTokenChunk(rc.alloc, &toks, done) catch |e| {
        log.warn("encode token chunk: {}", .{e});
        return;
    };
    defer rc.alloc.free(body);
    rc.sendOneWay(.token_chunk, tag, body) catch |e| {
        log.warn("send token chunk: {}", .{e});
    };
}

fn sendDone(rc: *RunnerConn, tag: u32) void {
    const body = messages.encodeTokenChunk(rc.alloc, &.{}, true) catch |e| {
        log.warn("encode done chunk: {}", .{e});
        return;
    };
    defer rc.alloc.free(body);
    rc.sendOneWay(.token_chunk, tag, body) catch |e| {
        log.warn("send done chunk: {}", .{e});
    };
}

fn sleep(io: Io, ms: u64) void {
    if (ms == 0) return;
    const dur = Io.Duration.fromMilliseconds(@intCast(ms));
    Io.sleep(io, dur, .awake) catch |e| switch (e) {
        error.Canceled => {},
    };
}
