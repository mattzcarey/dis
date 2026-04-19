//! llama.cpp Zig bindings — derived from Deins/llama.cpp.zig (MIT, see
//! UPSTREAM_LICENSE) and patched for Zig 0.16 + latest upstream llama.h
//! (memory API, init_from_model rename, current sampler chain).
//!
//! Imports `llama.h` via the build-system translate-c module wired in
//! `build.zig`. Link against `libllama` + `libggml*` (Homebrew provides
//! the dylibs on macOS; source-compile from the submodule lands in a
//! follow-up).
//!
//! Surface is intentionally small — just what `dis-infer` needs:
//!   - Backend init/deinit
//!   - Model.initFromFile / deinit / vocab / metadata
//!   - Vocab token queries + tokenize / tokenToPiece
//!   - Context.initFromModel / deinit / nCtx
//!   - Batch.getOne / decode
//!   - Sampler chain (temp, top-k, top-p, dist, greedy) + sample
//!   - Memory.clear / seqRm / seqKeep (per-session KV bookkeeping)
//!   - State.seqSaveFile / seqLoadFile (snapshot/restore per seq)
//!
//! Anything beyond this can be added incrementally; the `c` export is
//! public so callers can reach raw symbols when needed.

const std = @import("std");

pub const c = @import("llama.h");

// ── Primitive aliases ────────────────────────────────────────────────

pub const Pos = c.llama_pos;
pub const Token = c.llama_token;
pub const SeqId = c.llama_seq_id;
pub const CStr = [*:0]const u8;

pub const default_seed: u32 = c.LLAMA_DEFAULT_SEED;

// ── Backend ──────────────────────────────────────────────────────────

pub const Backend = struct {
    pub fn init() void {
        // Modern llama.cpp requires explicit backend registration; the
        // static `llama_backend_init` no longer wires up CPU/Metal/CUDA
        // automatically. `ggml_backend_load_all` scans the DSO install
        // paths (/opt/homebrew/lib/libggml-*.dylib on macOS) and links
        // every backend it finds.
        c.ggml_backend_load_all();
        c.llama_backend_init();
    }
    pub fn deinit() void {
        c.llama_backend_free();
    }
};

// ── Model ────────────────────────────────────────────────────────────

pub const Model = opaque {
    pub const Params = c.llama_model_params;
    pub fn defaultParams() Params {
        return c.llama_model_default_params();
    }

    pub fn initFromFile(path: CStr, params: Params) error{LoadFailed}!*Model {
        const ptr = c.llama_model_load_from_file(path, params);
        if (ptr == null) return error.LoadFailed;
        return @ptrCast(ptr);
    }

    pub fn deinit(self: *Model) void {
        c.llama_model_free(self.asC());
    }

    pub fn vocab(self: *const Model) *const Vocab {
        return @ptrCast(c.llama_model_get_vocab(self.asCConst()).?);
    }

    pub fn nCtxTrain(self: *const Model) i32 {
        return c.llama_model_n_ctx_train(self.asCConst());
    }
    pub fn nEmbd(self: *const Model) i32 {
        return c.llama_model_n_embd(self.asCConst());
    }
    pub fn nParams(self: *const Model) u64 {
        return c.llama_model_n_params(self.asCConst());
    }

    /// Fill `out_buf` with a short model type description ("LLaMA 7B", etc.).
    pub fn desc(self: *const Model, out_buf: []u8) []u8 {
        const n = c.llama_model_desc(self.asCConst(), out_buf.ptr, out_buf.len);
        if (n <= 0) return out_buf[0..0];
        return out_buf[0..@intCast(n)];
    }

    pub fn asC(self: *Model) *c.llama_model {
        return @ptrCast(self);
    }
    pub fn asCConst(self: *const Model) *const c.llama_model {
        return @ptrCast(self);
    }
};

// ── Vocab ────────────────────────────────────────────────────────────

pub const Vocab = opaque {
    pub fn nTokens(self: *const Vocab) i32 {
        return c.llama_vocab_n_tokens(self.asC());
    }

    pub fn tokenBos(self: *const Vocab) Token {
        return c.llama_vocab_bos(self.asC());
    }
    pub fn tokenEos(self: *const Vocab) Token {
        return c.llama_vocab_eos(self.asC());
    }
    pub fn isEog(self: *const Vocab, t: Token) bool {
        return c.llama_vocab_is_eog(self.asC(), t);
    }

    /// Returns the number of tokens written on success (0..out_tokens.len),
    /// or error.OutOfSpace (with the required capacity reported negatively
    /// by llama.cpp) when `out_tokens` is too small.
    pub fn tokenize(
        self: *const Vocab,
        text: []const u8,
        out_tokens: []Token,
        add_special: bool,
        parse_special: bool,
    ) error{OutOfSpace}!usize {
        const n = c.llama_tokenize(
            self.asC(),
            text.ptr,
            @intCast(text.len),
            out_tokens.ptr,
            @intCast(out_tokens.len),
            add_special,
            parse_special,
        );
        if (n < 0) return error.OutOfSpace;
        return @intCast(n);
    }

    /// Decode a single token into human-readable text, writing into `buf`.
    /// Returns the written slice. `special=true` so control tokens render.
    pub fn tokenToPiece(self: *const Vocab, token: Token, buf: []u8) []u8 {
        const n = c.llama_token_to_piece(
            self.asC(),
            token,
            buf.ptr,
            @intCast(buf.len),
            0, // lstrip
            true, // special
        );
        if (n <= 0) return buf[0..0];
        return buf[0..@intCast(n)];
    }

    fn asC(self: *const Vocab) *const c.llama_vocab {
        return @ptrCast(self);
    }
};

// ── Context ──────────────────────────────────────────────────────────

pub const Context = opaque {
    pub const Params = c.llama_context_params;
    pub fn defaultParams() Params {
        return c.llama_context_default_params();
    }

    pub fn initFromModel(m: *Model, params: Params) error{ContextInitFailed}!*Context {
        const ptr = c.llama_init_from_model(m.asC(), params);
        if (ptr == null) return error.ContextInitFailed;
        return @ptrCast(ptr);
    }

    pub fn deinit(self: *Context) void {
        c.llama_free(self.asC());
    }

    pub fn model(self: *const Context) *const Model {
        return @ptrCast(c.llama_get_model(self.asCConst()).?);
    }

    pub fn nCtx(self: *const Context) u32 {
        return c.llama_n_ctx(self.asCConst());
    }

    /// Run a forward pass on `batch`. Returns 0 on success, non-zero on
    /// error (out of KV, context overflow, etc.).
    pub fn decode(self: *Context, batch: c.llama_batch) i32 {
        return c.llama_decode(self.asC(), batch);
    }

    /// Raw logits pointer for the last decoded batch. Indexed by the
    /// batch's per-token `logits[i]` flag; use `getLogitsIth` to read a
    /// specific row.
    pub fn getLogitsIth(self: *Context, i: i32) [*]f32 {
        return c.llama_get_logits_ith(self.asC(), i);
    }

    pub fn asC(self: *Context) *c.llama_context {
        return @ptrCast(self);
    }
    pub fn asCConst(self: *const Context) *const c.llama_context {
        return @ptrCast(self);
    }
};

// ── Batch ────────────────────────────────────────────────────────────
//
// `llama_batch_get_one` wraps a flat token slice into a single-sequence
// batch — exactly what prefill needs. The returned `llama_batch` value
// holds pointers into the caller's `tokens` slice; keep it alive until
// `decode` returns.

pub const Batch = struct {
    pub fn getOne(tokens: []Token) c.llama_batch {
        return c.llama_batch_get_one(tokens.ptr, @intCast(tokens.len));
    }
};

// ── Sampler ──────────────────────────────────────────────────────────
//
// Samplers form a chain: init a chain with `Sampler.initChain`, add
// individual component samplers via `add`, then call `sample` on the
// chain per token. `deinit` the chain at the end; component samplers
// added to a chain must NOT be freed separately (chain owns them).

pub const Sampler = opaque {
    pub fn initChain() *Sampler {
        const params = c.llama_sampler_chain_default_params();
        return @ptrCast(c.llama_sampler_chain_init(params).?);
    }

    pub fn initGreedy() *Sampler {
        return @ptrCast(c.llama_sampler_init_greedy().?);
    }
    pub fn initDist(seed: u32) *Sampler {
        return @ptrCast(c.llama_sampler_init_dist(seed).?);
    }
    pub fn initTopK(k: i32) *Sampler {
        return @ptrCast(c.llama_sampler_init_top_k(k).?);
    }
    pub fn initTopP(p: f32, min_keep: usize) *Sampler {
        return @ptrCast(c.llama_sampler_init_top_p(p, min_keep).?);
    }
    pub fn initTemp(t: f32) *Sampler {
        return @ptrCast(c.llama_sampler_init_temp(t).?);
    }

    pub fn deinit(self: *Sampler) void {
        c.llama_sampler_free(self.asC());
    }

    /// Append `other` to this chain. After this call, `other` is owned
    /// by the chain and must not be freed separately.
    pub fn add(self: *Sampler, other: *Sampler) void {
        c.llama_sampler_chain_add(self.asC(), other.asC());
    }

    pub fn accept(self: *Sampler, token: Token) void {
        c.llama_sampler_accept(self.asC(), token);
    }

    /// Draw a single token from the sampler chain over `ctx`'s last
    /// decoded logits at row `idx` (use -1 for the last row).
    pub fn sample(self: *Sampler, ctx: *Context, idx: i32) Token {
        return c.llama_sampler_sample(self.asC(), ctx.asC(), idx);
    }

    fn asC(self: *Sampler) *c.llama_sampler {
        return @ptrCast(@alignCast(self));
    }
};

// ── Memory (per-sequence KV) ─────────────────────────────────────────
//
// llama.cpp renamed the KV-cache API to `memory_*` in ~b5xxx. We expose
// the subset relevant to per-session bookkeeping.

pub const Memory = struct {
    pub fn clear(ctx: *Context, data: bool) void {
        const mem = c.llama_get_memory(ctx.asC());
        c.llama_memory_clear(mem, data);
    }

    /// Remove tokens in `[p0, p1)` for `seq_id`. Pass `p0 < 0` for
    /// "from the start" and `p1 < 0` for "to the end".
    pub fn seqRm(ctx: *Context, seq_id: SeqId, p0: Pos, p1: Pos) bool {
        const mem = c.llama_get_memory(ctx.asC());
        return c.llama_memory_seq_rm(mem, seq_id, p0, p1);
    }

    pub fn seqKeep(ctx: *Context, seq_id: SeqId) void {
        const mem = c.llama_get_memory(ctx.asC());
        c.llama_memory_seq_keep(mem, seq_id);
    }
};

// ── Per-sequence state save/load (file) ──────────────────────────────

pub const State = struct {
    /// Save the per-sequence KV cache for `seq_id` to `path`. Returns the
    /// number of bytes written. Snapshot is resumable later via
    /// `seqLoadFile` even across process restarts.
    pub fn seqSaveFile(
        ctx: *Context,
        path: CStr,
        seq_id: SeqId,
        tokens: []const Token,
    ) usize {
        return c.llama_state_seq_save_file(
            ctx.asC(),
            path,
            seq_id,
            tokens.ptr,
            tokens.len,
        );
    }

    /// Load a previously saved per-sequence KV into `seq_id`.
    /// `tokens_buf` receives the original token list; returns the slice
    /// of it that was filled, or `error.LoadFailed`.
    pub fn seqLoadFile(
        ctx: *Context,
        path: CStr,
        seq_id: SeqId,
        tokens_buf: []Token,
    ) error{LoadFailed}![]Token {
        var n_read: usize = 0;
        const n = c.llama_state_seq_load_file(
            ctx.asC(),
            path,
            seq_id,
            tokens_buf.ptr,
            tokens_buf.len,
            &n_read,
        );
        if (n == 0) return error.LoadFailed;
        return tokens_buf[0..n_read];
    }
};
