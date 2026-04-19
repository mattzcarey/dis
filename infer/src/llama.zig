//! `LlamaHost` — llama.cpp-backed engine used by dis-infer's opcode
//! handlers. Wraps one loaded model + one context + a sampler chain.
//!
//! Concurrency: llama_decode is NOT thread-safe across contexts, and
//! this host holds a single context, so handlers serialise decode
//! calls via `decode_mu`. The infer binary runs one connection at a
//! time for M1; when we parallelise later the lock stays correct.

const std = @import("std");
const log = @import("log").scoped("llama");
const llama = @import("llama");

pub const LlamaError = error{
    NotLoaded,
    ModelLoadFailed,
    ContextInitFailed,
    TokenizeFailed,
    DecodeFailed,
    OutOfMemory,
};

pub const StopReason = enum { eos, max, abort };

pub const GenerateResult = struct {
    stop: StopReason,
    tokens_generated: u32,
    total_pos: i32,
};

/// Active host state. Exactly one model + context per connection.
pub const LlamaHost = struct {
    alloc: std.mem.Allocator,

    loaded: bool = false,
    model: ?*llama.Model = null,
    ctx: ?*llama.Context = null,
    sampler: ?*llama.Sampler = null,

    n_ctx: u32 = 0,
    n_embd: u32 = 0,
    n_vocab: u32 = 0,
    model_id: []const u8 = "",

    decode_mu: std.Io.Mutex = .init,

    pub fn init(alloc: std.mem.Allocator) LlamaHost {
        llama.Backend.init();
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *LlamaHost) void {
        if (self.model_id.len > 0) self.alloc.free(self.model_id);
        if (self.sampler) |s| s.deinit();
        if (self.ctx) |c| c.deinit();
        if (self.model) |m| m.deinit();
        llama.Backend.deinit();
        self.* = undefined;
    }

    /// Load a GGUF model. Idempotent — a second call tears down the
    /// previous model/context/sampler first.
    pub fn loadModel(
        self: *LlamaHost,
        path: []const u8,
        n_ctx_req: u32,
        n_gpu_layers: i32,
    ) LlamaError!void {
        // Tear down any previous load.
        if (self.sampler) |s| {
            s.deinit();
            self.sampler = null;
        }
        if (self.ctx) |c| {
            c.deinit();
            self.ctx = null;
        }
        if (self.model) |m| {
            m.deinit();
            self.model = null;
        }
        if (self.model_id.len > 0) {
            self.alloc.free(self.model_id);
            self.model_id = "";
        }
        self.loaded = false;

        // NUL-terminate the path for llama.cpp.
        const path_z = self.alloc.allocSentinel(u8, path.len, 0) catch return LlamaError.OutOfMemory;
        defer self.alloc.free(path_z);
        @memcpy(path_z[0..path.len], path);

        var mparams = llama.Model.defaultParams();
        if (n_gpu_layers >= 0) mparams.n_gpu_layers = n_gpu_layers;

        const m = llama.Model.initFromFile(path_z.ptr, mparams) catch |e| {
            log.err("model load failed: {s} ({})", .{ path, e });
            return LlamaError.ModelLoadFailed;
        };
        errdefer m.deinit();

        var cparams = llama.Context.defaultParams();
        if (n_ctx_req > 0) cparams.n_ctx = n_ctx_req;
        cparams.n_seq_max = 1; // single sequence per context in M1

        const c = llama.Context.initFromModel(m, cparams) catch |e| {
            log.err("context init failed: {}", .{e});
            return LlamaError.ContextInitFailed;
        };
        errdefer c.deinit();

        // Default sampler chain: top-k → top-p → temperature → dist.
        const chain = llama.Sampler.initChain();
        errdefer chain.deinit();
        chain.add(llama.Sampler.initTopK(40));
        chain.add(llama.Sampler.initTopP(0.9, 1));
        chain.add(llama.Sampler.initTemp(0.8));
        chain.add(llama.Sampler.initDist(llama.default_seed));

        self.model = m;
        self.ctx = c;
        self.sampler = chain;
        self.loaded = true;
        self.n_ctx = c.nCtx();
        self.n_embd = @intCast(m.nEmbd());
        const v = m.vocab();
        self.n_vocab = @intCast(v.nTokens());

        var desc_buf: [128]u8 = undefined;
        const desc = m.desc(&desc_buf);
        self.model_id = self.alloc.dupe(u8, if (desc.len > 0) desc else basenameOf(path)) catch return LlamaError.OutOfMemory;

        log.info(
            "loaded: id='{s}' n_ctx={d} n_embd={d} n_vocab={d}",
            .{ self.model_id, self.n_ctx, self.n_embd, self.n_vocab },
        );
    }

    /// Tokenize `text` into a newly-allocated slice (caller owns).
    /// Adds BOS and parses special tokens.
    pub fn tokenize(self: *LlamaHost, text: []const u8) LlamaError![]llama.Token {
        const m = self.model orelse return LlamaError.NotLoaded;
        const v = m.vocab();

        // Discover required size via a zero-length probe (llama_tokenize
        // returns -needed when `n_max_tokens == 0`).
        const needed_neg = llama.c.llama_tokenize(
            @ptrCast(v),
            text.ptr,
            @intCast(text.len),
            null,
            0,
            true,
            true,
        );
        if (needed_neg == 0) {
            // Empty tokenization (empty string, etc.).
            return self.alloc.alloc(llama.Token, 0) catch return LlamaError.OutOfMemory;
        }
        const needed: usize = @intCast(-needed_neg);
        const buf = self.alloc.alloc(llama.Token, needed) catch return LlamaError.OutOfMemory;
        errdefer self.alloc.free(buf);
        const got = v.tokenize(text, buf, true, true) catch return LlamaError.TokenizeFailed;
        return buf[0..got];
    }

    /// Detokenize one token into UTF-8 text, writing into `buf`. Returns
    /// the written slice.
    pub fn tokenToPiece(self: *LlamaHost, token: llama.Token, buf: []u8) LlamaError![]u8 {
        const m = self.model orelse return LlamaError.NotLoaded;
        return m.vocab().tokenToPiece(token, buf);
    }

    /// Generation callback shape: called once per produced token.
    /// Return `false` to abort early.
    pub const OnToken = *const fn (
        ctx: *anyopaque,
        token_id: i32,
        text: []const u8,
        pos: i32,
    ) bool;

    /// Prefill + sampled generation loop. Feeds `prompt_tokens` through
    /// `llama_decode`, then samples up to `max_new_tokens`, invoking
    /// `on_token` for each. Stops on EOG, max_tokens, or when
    /// `on_token` returns false.
    pub fn generate(
        self: *LlamaHost,
        prompt_tokens: []llama.Token,
        max_new_tokens: u32,
        on_token_ctx: *anyopaque,
        on_token: OnToken,
    ) LlamaError!GenerateResult {
        const c = self.ctx orelse return LlamaError.NotLoaded;
        const sampler = self.sampler orelse return LlamaError.NotLoaded;
        const m = self.model.?;
        const v = m.vocab();

        const io = std.Io.Threaded.global_single_threaded.io();
        self.decode_mu.lockUncancelable(io);
        defer self.decode_mu.unlock(io);

        // Prefill.
        if (prompt_tokens.len > 0) {
            const prefill_batch = llama.Batch.getOne(prompt_tokens);
            if (c.decode(prefill_batch) != 0) return LlamaError.DecodeFailed;
        }
        var pos: i32 = @intCast(prompt_tokens.len);
        var n_generated: u32 = 0;
        var stop: StopReason = .max;

        var one: [1]llama.Token = .{0};
        var piece_buf: [64]u8 = undefined;
        while (n_generated < max_new_tokens) : (n_generated += 1) {
            const tok = sampler.sample(c, -1);
            sampler.accept(tok);

            if (v.isEog(tok)) {
                stop = .eos;
                break;
            }

            const piece = v.tokenToPiece(tok, &piece_buf);
            if (!on_token(on_token_ctx, tok, piece, pos)) {
                stop = .abort;
                break;
            }

            one[0] = tok;
            const decode_batch = llama.Batch.getOne(one[0..]);
            if (c.decode(decode_batch) != 0) return LlamaError.DecodeFailed;
            pos += 1;
        }

        return .{
            .stop = stop,
            .tokens_generated = n_generated,
            .total_pos = pos,
        };
    }
};

fn basenameOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

// ─── tests ───────────────────────────────────────────────────────────
//
// No unit tests here — `LlamaHost` requires a real GGUF to exercise
// meaningfully. End-to-end coverage lives in the smoke client driven
// by `zig build smoke` and the eventual CI runner.
