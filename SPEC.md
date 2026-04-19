# dis — Design Spec (v0)

> **Durable inference.** Write a class, get a stateful, GPU-backed actor with
> its own persistent KV cache, SQLite, and in-memory state. Two small Zig
> binaries (`zig build`, no Bazel), TypeScript SDK hosts user code.
> Inspired by Rivet + Cloudflare Durable Objects. **llama.cpp** is the
> inference runtime, linked as a C library via `@cImport`.

## 0. Elevator pitch

Users write a class that looks like a Cloudflare Durable Object:

```ts
import { DurableInference } from "@dis/sdk";

export class Agent extends DurableInference {
  override async onStart({ reason }) {
    // Warm the model we'll use — blocking other requests until ready.
    await this.ctx.blockConcurrencyWhile(async () => {
      await this.ai.loadModel("llama-3.2-1b");
    });
  }

  override async onStop({ reason }) {
    // reason: "idle" | "evicted" | "deploy" | "destroy" | "shutdown"
  }

  override async onRequest(req: Request): Promise<Response> {
    const prompt = await req.text();
    const stream = this.ai.generate("llama-3.2-1b", prompt, { maxTokens: 256 });
    return new Response(stream);
  }

  override async onMessage(msg: string | Uint8Array, ws: WebSocket) {
    const text = typeof msg === "string" ? msg : new TextDecoder().decode(msg);
    const stream = this.ai.generate("llama-3.2-1b", text);
    for await (const tok of stream) ws.send(tok.text);
  }
}
```

Two namespaces: `this.ctx.*` for everything actor-y (identity, `state`,
`sql`, scheduling, `broadcast`, concurrency, lifecycle), `this.ai.*` for
inference.

Each **instance of the class** is a durable actor addressed by compound key.
It owns:

- in-memory `this.ctx.state` (durable KV, CBOR-encoded),
- `this.ctx.sql` — a per-instance SQLite database,
- a dedicated **KV cache on a GPU** (the valuable state; warm context that
  survives between requests),
- four lifecycle hooks: `onStart` (activation), `onStop` (deactivation),
  `onRequest` (HTTP), `onMessage` (WebSocket frame).

`this.generate(prompt)` RPCs into the engine, which runs prefill+decode
against *this* session's KV cache and streams tokens back to the user code.
Idle sessions hibernate (VRAM → CPU RAM → disk). Next request wakes them.

Three binaries in play:

| Component | Language | Owns                                                                      |
|-----------|----------|---------------------------------------------------------------------------|
| `dis-engine` | Zig (pure) | Session metadata, persistence, HTTP to clients, WS tunnel to runners, RPC to infer |
| `dis-infer`  | Zig + `@cImport("llama.h")` | GPU, loaded model, KV cache per session (llama sequence id), prefill/decode, seq snapshot/restore |
| `dis-runner` | Node/Bun/Deno | User code (the `DurableInference` subclass), `ctx.state`, SQLite          |

Communication:

- `dis-engine` ↔ `dis-infer`: Unix socket, custom binary frame protocol. Both on the same host.
- `dis-engine` ↔ `dis-runner`: WebSocket tunnel, multiplexed CBOR frames.
- Clients ↔ `dis-engine`: plain HTTP + SSE.

Build story: every Zig binary uses `zig build`. No Bazel, no cmake. `dis-infer` compiles llama.cpp's C/C++ sources directly via `addCSourceFiles`. llama.cpp is vendored as a git submodule.

## 1. Scope

### MVP (v0) — what this spec covers

- Single-node Zig engine, one or more GPUs, one model loaded at startup.
- TypeScript SDK (`@dis/sdk`) with `DurableInference` base class.
- One or more runner processes connect to the engine over WebSocket.
- HTTP + SSE client surface on the engine; runner invokes user class.
- Session creation / destroy / get-or-create by compound key.
- Persistent per-session state (CBOR), per-session SQLite, KV cache checkpoints.
- Idle hibernation + VRAM-pressure eviction (LRU of hibernatable sessions).
- Crash recovery on both sides: engine rebuilds session registry; runners
  reconnect and re-advertise. Sessions start in `Hibernated` state.
- Simple admission control (bounded concurrent live sessions per model).

### v1 (not in this spec but design accommodates)

- Multi-model per binary.
- Multi-node: session_id with DC/node label; HTTP proxy between peers.
- Continuous batching (requires ZML model graph changes — out of scope).
- Object-storage tier for cross-node KV-cache snapshots.
- Live migration between nodes.

### v2+ (future)

- Sandboxed per-session user code (Lua? WASM?) for pre/post processing hooks.
- Speculative decoding, paged KV cache, prefix sharing.
- Multi-tenant quotas, billing, rate limits.

### Explicit non-goals

- Not a full model catalog / training system.
- Not a scheduler for arbitrary compute — inference only.
- Not a V8 isolate host. Sessions do **not** execute user code; they hold
  inference state and respond to a fixed protocol.

## 2. Mental model: the Session

```
┌──────────────────────── Session ────────────────────────┐
│ id        : Id128          — UUIDv1 w/ node label       │
│ key       : [][]const u8   — user compound key, unique  │
│              per (namespace, model, key)                │
│ namespace : []const u8                                  │
│ model     : ModelRef       — which compiled model       │
│ phase     : Phase enum     — see §6                     │
│                                                         │
│ state_blob: CborBlob       — in-memory, throttled flush │
│ sqlite    : *SqliteConn    — per-session database       │
│                                                         │
│ kv        : KvCacheHandle  — where the KV lives now:    │
│             { .vram  = { buffers: …, slot: SlotId } }   │
│           | { .ram   = PinnedHostBytes }                │
│           | { .disk  = PathBuf }                        │
│           | { .absent }                                 │
│                                                         │
│ cursor    : usize          — # of tokens in KV cache    │
│ seq_budget: usize          — max seqlen for this KV     │
│                                                         │
│ last_used : i64            — ms since epoch             │
│ pending   : Queue(Request) — serialised request queue   │
└─────────────────────────────────────────────────────────┘
```

A session processes requests **strictly serially** (one generation at a time).
Concurrency across sessions is achieved by N independent sessions running
alternating decode steps on the same GPU. There is no shared batching in MVP.

## 3. System overview

```
              ┌────────── Client ──────────┐
              │  HTTP: /v1/actors/...      │
              │  SSE:  streaming tokens    │
              └──────────────┬─────────────┘
                             │
                 ┌───────────▼───────────┐
                 │     dis-engine        │   pure Zig, zig build
                 │                       │
                 │  - HTTP frontend      │
                 │  - session registry   │
                 │  - WS tunnel hub      │
                 │  - meta persistence   │
                 │  - infer RPC client   │
                 └──────┬──────────┬─────┘
                        │          │
                WS      │          │   Unix socket
                        │          │   (binary frames)
                        ▼          ▼
            ┌─────────────────┐  ┌─────────────────────────┐
            │  dis-runner #1  │  │   dis-infer             │  Zig + C (llama.cpp)
            │ (Node/Bun/Deno) │  │                         │
            │                 │  │   - RPC server          │
            │ class Agent     │  │   - model loaded once   │
            │  extends        │  │   - seq per session     │
            │  DurableInfer   │  │   - prefill / decode    │
            │                 │  │   - seq save/load       │
            │ onRequest(r) {  │  │   - sampling            │
            │   return this   │  │   ┌─────────────────┐   │
            │     .generate() │  │   │   libllama.a    │   │
            │ }               │  │   │  (from git sub- │   │
            │                 │  │   │   module, built │   │
            │ ... tokens      │  │   │   by zig build) │   │
            │ ↓ stream back   │  │   └────────┬────────┘   │
            │   via engine    │  │            ▼            │
            └─────────────────┘  │        GPU / CPU        │
                                 │   (CUDA / Metal / ROCm) │
                                 └─────────────────────────┘
```

### 3.1 Engine components (`dis-engine`, pure Zig)

| Component        | Purpose                                                        |
|------------------|----------------------------------------------------------------|
| `http_server`    | Client-facing HTTP + SSE                                       |
| `router`         | session_id → Session slot                                      |
| `session_mgr`    | Session metadata, lifecycle, queue of pending work             |
| `tunnel_hub`     | Track connected runners; multiplex RPC over each WS            |
| `infer_client`   | Unix-socket client speaking dis-infer binary RPC               |
| `persistence`    | meta.db + per-session state.cbor + db.sqlite                   |
| `hibernator`     | Idle scan + LRU eviction, coordinated with `dis-infer`         |

Notably: **the engine does no GPU work and holds no model weights**. KV caches live inside `dis-infer` addressed by `seq_id`; the engine tracks the mapping `session_id ⇄ seq_id`.

### 3.2 Infer components (`dis-infer`, Zig + llama.cpp via `@cImport`)

| Component        | Purpose                                                        |
|------------------|----------------------------------------------------------------|
| `rpc_server`     | Accept Unix-socket connections from `dis-engine`; decode frames|
| `llama_host`     | Wraps `llama_context`; one long-lived context per model        |
| `seq_table`      | Allocate/free llama `seq_id` slots; map to session_id          |
| `snapshot_mgr`   | `llama_state_seq_save_file` / `llama_state_seq_load_file`      |
| `sampler_pool`   | Reusable `llama_sampler_chain`s per temperature/topk combo     |
| `chat_template`  | Applies GGUF-embedded chat template via `llama_chat_apply_template` |

`dis-infer` is **stateless outside of VRAM + snapshot files**. If it crashes the engine reconnects, the infer process reloads the model, and sessions restore from their last KV snapshot.

### 3.3 Runner components (`dis-runner`, TypeScript)

| Component        | Purpose                                                        |
|------------------|----------------------------------------------------------------|
| `@dis/sdk`       | `DurableInference` base class + `startRunner()`                |
| `engine-tunnel`  | Single WS to engine; frame codec; RPC client + server          |
| `actor-host`     | Per-session JS object; invokes user class methods              |
| `state-proxy`    | `ctx.state` impl; throttled flush to engine                    |
| `sql-driver`     | `ctx.sql` — SQLite file per actor                              |
| `generate-rpc`   | `this.generate(...)` → RPC to engine, returns async iterable   |

### 3.4 Message flow — a single request

```
1. client: POST /v1/actors/{id}/request  (or PUT get-or-create)
              │
2. engine: route to session slot; session is hibernated
              │  (if hibernated, ask infer to restore KV from snapshot first)
              │
3. engine: choose a runner that hosts this actor_name; send ActorWake
              │ WS
4. runner:  instantiate `new Agent(ctx)`; restore state from engine.LoadState
              │
5. runner:  call agent.onRequest(clientReq)
              │
6. user code: return this.generate(prompt)
              │ WS  (Generate RPC with sessionId)
7. engine: forwards to dis-infer via unix socket
              │ (Prefill frame: sessionId→seq_id, tokens, opts)
8. dis-infer: llama_tokenize(prompt); llama_decode(batch);
              │ iteratively sample + llama_decode; emit tokens
              │
9. engine: splices tokens from infer stream → runner stream → client SSE
              │
10. runner:  yields tokens through user's ReadableStream; final return
              │
11. idle → engine asks infer to snapshot seq (llama_state_seq_save_file),
              │  frees the seq_id. Session phase = hibernated.
```

## 4. Types

Everything in pseudocode-flavoured Zig. Not expected to compile; expected to
read well and leave no ambiguity about data shape.

```zig
// ─── IDs ──────────────────────────────────────────────────────────

const Id128 = [16]u8; // UUIDv1; high 16 bits = node label

fn nodeLabel(id: Id128) u16  { ... }
fn genId(node_label: u16) Id128 { ... }  // Rivet-style: label + time + rand

// ─── Compound key ─────────────────────────────────────────────────

// Serialized as forward-slash separated, escaping '\' and '/'.
//   ["org-acme", "user-123", "conv-456"]  ->  "org-acme/user-123/conv-456"
const Key = [] const [] const u8;

fn packKey(alloc: Allocator, key: Key) ![]u8 { ... }
fn unpackKey(alloc: Allocator, s: []const u8) !Key { ... }

// ─── Session ──────────────────────────────────────────────────────

const Phase = enum {
    provisioning, // id assigned, but no resources yet
    loading,      // model + KV cache being allocated
    running,      // actively processing requests
    idle,         // running but no pending request
    hibernating,  // draining + persisting state, slot still held
    hibernated,   // VRAM freed; state on ram/disk; awakable
    destroying,   // marked for destruction, flushing final state
    destroyed,    // terminal
};

const KvWhere = union(enum) {
    absent: void,                     // before first inference, or destroyed
    vram:   struct { slot: SlotId, buffers: KvBuffers },
    ram:    struct { bytes: PinnedBytes, shape: KvShape },
    disk:   struct { path: []const u8, shape: KvShape, bytes_len: usize },
};

const KvShape = struct {
    layers: u32,
    heads_kv: u32,
    head_dim: u32,
    seq_capacity: u32,  // allocated max — used for VRAM sizing
    dtype: Dtype,       // typically f16 or bf16
};

const Session = struct {
    id: Id128,
    namespace: []const u8,
    key_packed: []const u8,
    model: *Model,

    phase: Phase,

    // State
    state_blob: CborBlob,       // decoded, in-memory
    state_dirty: bool,
    state_version: u64,         // monotonic, for optimistic concurrency

    sqlite: ?*SqliteConn,       // lazily opened on first access
    sqlite_path: []const u8,

    kv: KvWhere,
    kv_cursor: u32,             // tokens currently populated
    kv_snapshot_version: u64,   // matches sequential write-through to disk

    created_ms: i64,
    last_used_ms: i64,

    // Concurrency
    queue: RequestQueue,
    busy:  std.Thread.Mutex,    // held during prefill/decode

    // Weak ref back to owning runtime for cross-cutting hooks
    runtime: *Runtime,
};

// ─── Request types ────────────────────────────────────────────────

const RequestKind = enum { chat, raw, hibernate, resume, checkpoint, destroy };

const Request = union(RequestKind) {
    chat: struct {
        prompt: []const u8,
        max_tokens: ?u32,
        temperature: f32 = 1.0,
        top_p: f32 = 1.0,
        stream: *SseStream,       // token-by-token output here
        reply: *oneshot.Sender(ChatResult),
    },
    raw: struct {
        tokens: []const u32,
        max_tokens: u32,
        stream: *SseStream,
        reply: *oneshot.Sender(RawResult),
    },
    hibernate: oneshot.Sender(void),
    resume:    oneshot.Sender(void),
    checkpoint: oneshot.Sender(void),
    destroy:   oneshot.Sender(void),
};

// ─── Model ────────────────────────────────────────────────────────

const ModelId = []const u8;  // e.g. "meta-llama/Llama-3.2-1B-Instruct"

const Model = struct {
    id: ModelId,
    zml_platform: *zml.Platform,
    compiled: zml.Exe.Pair,        // { prefill, decode }
    weights:  zml.Bufferized(LlmModel),
    config:   ModelConfig,         // vocab size, eos ids, chat template
    tokenizer: zml.tokenizer.Tokenizer,

    kv_shape_template: KvShape,    // shape for a *new* session

    // Admission control
    max_live_sessions: u32,        // hard cap (from config)
    live_sessions:   std.atomic.Value(u32),
};

// ─── Runtime ──────────────────────────────────────────────────────

const Runtime = struct {
    alloc: Allocator,
    cfg:   Config,
    node_label: u16,

    platform: *zml.Platform,
    models:   std.StringHashMap(*Model),   // v0: one model, but generic

    // Session registry: two indexes
    by_id:  std.AutoHashMap(Id128, *Session),
    by_key: std.StringHashMap(*Session),   // packed "ns/model/packed_key"
    registry_mutex: std.Thread.RwLock,

    vram: VramTracker,
    queue_pool: WorkStealingPool,
    http: *HttpServer,

    // Persistence
    meta_db: *SqliteConn,   // runtime-level sqlite for session metadata
    data_dir: []const u8,
};
```

## 5. HTTP API

All requests require `Authorization: Bearer <token>`. Token identifies a
namespace. A session's `(namespace, model, key)` tuple is globally unique.

### 5.1 Session management

| Method | Path                                         | Purpose                             |
|--------|----------------------------------------------|-------------------------------------|
| POST   | `/v1/sessions`                               | Create — specify model + key        |
| PUT    | `/v1/sessions`                               | Get-or-create by key                |
| GET    | `/v1/sessions/{id}`                          | Metadata: phase, cursor, last_used  |
| DELETE | `/v1/sessions/{id}`                          | Destroy and free all resources      |
| POST   | `/v1/sessions/{id}/hibernate`                | Force hibernate                     |
| POST   | `/v1/sessions/{id}/resume`                   | Wake without sending input          |
| POST   | `/v1/sessions/{id}/checkpoint`               | Flush state + kv to disk now        |

Request body for PUT (get-or-create):

```json
{
  "model": "meta-llama/Llama-3.2-1B-Instruct",
  "key":   ["org-acme", "user-123", "conv-456"],
  "seq_capacity": 8192,
  "initial_state": { "system_prompt": "You are helpful." }
}
```

### 5.2 Generation

| Method | Path                                         | Purpose                             |
|--------|----------------------------------------------|-------------------------------------|
| POST   | `/v1/sessions/{id}/chat`                     | Send a chat turn, stream tokens     |
| POST   | `/v1/sessions/{id}/raw`                      | Send raw token ids (power users)    |

Chat body:

```json
{ "prompt": "hey, remember me?", "max_tokens": 256, "temperature": 0.7 }
```

Response: `Content-Type: text/event-stream`, one SSE event per token:

```
event: token
data: {"text":" Sure","token_id":12345,"pos":42}

event: token
data: {"text":"!","token_id":0,"pos":43}

event: done
data: {"stop_reason":"eos","total_tokens":44,"elapsed_ms":812}
```

### 5.3 State access

| Method | Path                                  | Purpose                             |
|--------|---------------------------------------|-------------------------------------|
| GET    | `/v1/sessions/{id}/state`             | Return CBOR-decoded state as JSON   |
| PUT    | `/v1/sessions/{id}/state`             | Replace state (optimistic: `If-Match`) |
| PATCH  | `/v1/sessions/{id}/state`             | JSON-patch apply                    |

State writes set `state_dirty = true` and bump `state_version`.

### 5.4 SQLite access

| Method | Path                                  | Purpose                             |
|--------|---------------------------------------|-------------------------------------|
| POST   | `/v1/sessions/{id}/sql/exec`          | `{"sql":"INSERT ...","params":[...]}` |
| POST   | `/v1/sessions/{id}/sql/query`         | Returns `{"rows":[...],"cols":[...]}`|

Lazy open: the SQLite file is not created until first use.

### 5.5 Node-level

| Method | Path                | Purpose                                  |
|--------|---------------------|------------------------------------------|
| GET    | `/v1/health`        | Liveness                                 |
| GET    | `/v1/node`          | VRAM stats, live sessions, model info    |
| GET    | `/v1/metrics`       | Prometheus                               |

## 5A. SDK — `@dis/sdk` (TypeScript)

The SDK is a tiny package a user installs into their own TS project. They
write a class, export it, run `dis-runner` pointing at their module, and
the engine routes traffic into it.

### 5A.1 The base class

```ts
// packages/sdk/src/durable.ts  (what the user imports)
export abstract class DurableInference<Input = unknown> {
  /** Actor runtime: identity, state, sql, concurrency, scheduling, broadcast. */
  readonly ctx!: ActorCtx;

  /** Inference primitives — model registry + generation. */
  readonly ai!: AiApi;

  // ── Lifecycle hooks (all optional) ────────────────────────────────

  onStart?(info:   { reason: "create" | "wake" | "restart"; input?: Input }): void | Promise<void>;
  onStop?(info:    { reason: "idle" | "evicted" | "deploy" | "destroy" | "shutdown" }): void | Promise<void>;
  onRequest?(req: Request): Response | Promise<Response>;
  onMessage?(msg: string | Uint8Array, ws: WebSocket): void | Promise<void>;

  // Scheduled tasks dispatch to named methods on the subclass. Call
  // `this.ctx.schedule(when, "methodName", payload?)`. There is no
  // generic `onAlarm` hook.
}

export interface BroadcastOpts {
  to?: (peer: ActorPeer) => boolean;
  except?: WebSocket;
}

export interface ActorPeer {
  readonly id: string;
  readonly ws: WebSocket;
  readonly connectedAtMs: number;
  readonly remoteAddr: string;
}
```

`broadcast` is on `ctx`: see §5A.1.2.

### 5A.1.2 `ctx.initialState(defaults)` — typed, hydrated, Proxy-wrapped

Inspired by gsv's `PersistedObject` and CF DO storage blobs. You call
`initialState()` once per activation (inside `onStart`); it returns a deep
Proxy that's **already hydrated** from durable storage. No `$ready` to
await. Mutations auto-persist on a throttle.

```ts
// on ActorCtx:
initialState<T extends object>(
  defaults: T,
  opts?: { name?: string; throttleMs?: number },
): Promise<Persisted<T>>;

type Persisted<T> = T & {
  $flush(): Promise<void>;   // force-flush pending writes
  $raw(): T;                 // plain-object snapshot
};
```

Usage pattern:

```ts
interface State { turns: number; createdAt: number; }

class Agent extends DurableInference<unknown, State> {
  override async onStart({ reason }: StartInfo) {
    this.state = await this.ctx.initialState<State>({ turns: 0, createdAt: 0 });
    if (reason === "create") this.state.createdAt = Date.now();
  }

  override async onRequest(req: Request) {
    this.state.turns += 1;       // auto-persist, throttled
    return new Response("ok");
  }
}
```

The second generic parameter on `DurableInference<Input, State>` types
`this.state`; pass it once at the class and everything downstream is
typed.

**Semantics**:

- **Scope**: one persisted object per `(actor, name)` pair. `name` defaults
  to `"default"` — pass it explicitly if you want multiple independent
  persisted objects per actor.
- **Hydration**: `initialState()` awaits internally and returns an
  already-hydrated Proxy. Defaults are applied only when no prior value
  exists; otherwise the stored value wins.
- **Deep proxying**: `state.users[0].name = "x"` works. Every `get` that
  returns an object returns a wrapped Proxy transparently.
- **Throttled flush**: mutations schedule a flush on a timer
  (`throttleMs`, default 1000 ms). Call `$flush()` for immediate persist.
  `onStop` always runs before the actor goes away, and a failed in-flight
  flush marks dirty for retry.
- **Reserved keys**: `$flush`, `$raw` cannot be assigned or deleted.
  User state must not start with `$`.
- **Serialisable values only**: CBOR via `structuredClone` under the hood —
  functions, class instances with methods, DOM types will throw on
  assignment.
- **Size limits**: root blob capped at 1 MiB in v0 (v1: paged).
- **Concurrency**: if two fibers mutate concurrently, last writer wins on
  the underlying object. Use `blockConcurrencyWhile` around complex RMW
  patterns.

For structured multi-row data, use `ctx.sql` instead (see §5A.1.3). The
rule of thumb: `state` for small actor-scoped values that fit one blob;
`sql` for anything row-oriented or queryable.

### 5A.1.5 Scheduling semantics

Covers every call to `ctx.schedule(...)`.

- **Fires even when hibernated** — the engine's scheduler ticks globally.
  On fire the engine wakes the actor (`onStart({ reason: "wake" })` first)
  then invokes `this[callback](payload, info)` as a regular method call.
  Invocation info: `{ schedule: Schedule<T>; attempt: number; isRetry: boolean }`.
- **At-least-once.** Callbacks should be idempotent.
- **Retry policy** (`retry` opts): on throw, exponential backoff starting at
  `baseDelaySeconds` (default 2 s), up to `maxAttempts` (default 6). Then
  drop + log.
- **Idempotency**: opt-in via `opts.idempotentKey`. If set, the engine
  dedups subsequent calls on `(actorId, idempotentKey)` — a duplicate
  `schedule()` returns the existing `Schedule` unchanged. Without the
  key, every call creates a new row.
- **Interval overlap prevention**: for `{ every: N }` schedules, if the
  callback is still running when the next tick is due, that tick is
  skipped (logged as warning). Prevents runaway resource use.
- **Errors don't stop intervals**: a throwing tick doesn't cancel the
  schedule; retries follow `retry` opts (default 6× backoff), then we
  move on to the next interval.
- **Atomicity**: a schedule row is marked "done" only after the callback
  resolves successfully (or retries exhaust). A crash mid-execution → the
  schedule re-fires on next engine start.
- **Ordering**: when multiple schedules are due, they fire in ascending
  `time` order. Ties broken by id lexicographically.
- **`getSchedule` / `getSchedules` are synchronous**: they read from an
  in-memory mirror of the per-actor `schedules` SQL table.
- **`destroy()`**: calling `this.ctx.destroy()` from within a scheduled
  callback is safe; the engine defers teardown until the callback resolves.
- Persisted in `meta.db` `schedules` table (see §8.2).

### 5A.1.1 `this.ctx` — actor runtime context

Everything about being an actor — identity, durable storage, concurrency,
scheduling, broadcasting — lives here. The only thing *not* on `ctx` is
inference, which is on `this.ai`.

```ts
export interface ActorCtx {
  // ── Identity ──────────────────────────────────────────────────────
  readonly id: string;                      // 16-byte Id128 as hex
  readonly key: readonly string[];          // compound user key
  readonly namespace: string;
  readonly actorName: string;               // class registration key, e.g. "agent"

  // ── Storage ───────────────────────────────────────────────────────
  initialState<T extends object>(defaults: T, opts?: PersistOpts): Promise<Persisted<T>>;
  //           ^ typed + hydrated Proxy — see §5A.1.2
  readonly sql: Sql;                        // per-actor SQLite (see §5A.1.3)

  // ── Concurrency ───────────────────────────────────────────────────
  /**
   * Run `fn` exclusively: onRequest / onMessage / scheduled callbacks
   * are queued until `fn` resolves. Use for atomic init, migrations,
   * model warm-up, read-modify-write. Throws are fatal (actor dies
   * and is recreated on next request — CF-DO semantics).
   */
  blockConcurrencyWhile<T>(fn: () => Promise<T>): Promise<T>;

  // ── Lifecycle ─────────────────────────────────────────────────────
  hibernate(): Promise<void>;
  destroy(): Promise<void>;          // permanent; state + schedules wiped

  // ── Scheduling (see §5A.1.5 for semantics) ────────────────────────
  schedule<T>(
    when: number | Date | string | { every: number },
    callback: string,
    payload?: T,
    opts?: { retry?: RetryOptions; idempotentKey?: string },
  ): Promise<Schedule<T>>;

  getSchedule<T>(id: string): Schedule<T> | undefined;
  getSchedules<T>(filter?: ScheduleFilter): Schedule<T>[];
  cancelSchedule(id: string): Promise<boolean>;

  // ── Broadcast to connected WS peers ───────────────────────────────
  broadcast(msg: string | Uint8Array, opts?: BroadcastOpts): number;
}
```

### 5A.1.3 `ctx.sql` — per-actor SQLite

```ts
export interface Sql {
  exec(sql: string, params?: unknown[]): Promise<void>;
  query<T = Record<string, unknown>>(sql: string, params?: unknown[]): Promise<T[]>;
  transaction<T>(fn: () => Promise<T>): Promise<T>;
}
```

### 5A.1.4 `this.ai` — inference surface

All inference lives here. Separated from `ctx` so side-effectful GPU
work is visually distinct and trivially mockable in tests.

```ts
export interface AiApi {
  /** List every model known to this engine (loaded or not). */
  models(): Promise<ModelInfo[]>;

  /**
   * Ensure `modelId` is loaded and ready to serve. Idempotent and
   * engine-global — concurrent callers across actors coalesce into
   * a single load.
   */
  loadModel(modelId: string, opts?: LoadModelOpts): Promise<void>;

  /**
   * Run a chat turn. Reuses this actor's KV cache for (actor, modelId).
   * If this is the first `generate` against `modelId` for this actor,
   * a fresh KV cache is allocated.
   *
   * Returns a stream that yields decoded text chunks (Uint8Array) and
   * is also async-iterable over individual `Token` objects.
   */
  generate(
    modelId: string,
    prompt: string,
    opts?: GenerateOpts,
  ): TokenStream;

  /** Raw-token equivalent — skips chat template rendering. */
  generateRaw(
    modelId: string,
    tokens: number[],
    opts?: GenerateOpts,
  ): TokenStream;

  /** Tokenize `text` against `modelId`'s vocab (pure, no KV mutation). */
  tokenize(modelId: string, text: string): Promise<number[]>;

  /**
   * Discard this actor's KV cache for `modelId` (next `generate` will
   * re-prefill from scratch). Useful when conversation context is
   * getting stale or too long.
   */
  resetContext(modelId: string): Promise<void>;
}

export interface GenerateOpts {
  maxTokens?: number;
  temperature?: number;
  topP?: number;
  topK?: number;
  /**
   * Don't advance the KV cache — run a one-shot generation that leaves
   * the actor's context untouched. Useful for "dry-run" or side-channel
   * lookups.
   */
  ephemeral?: boolean;
}

export interface ModelInfo {
  id: string;             // e.g. "llama-3.2-1b"
  loaded: boolean;        // resident in VRAM on this engine
  family: string;         // "llama", "qwen", "gemma", ...
  quant: string;          // "Q4_K_M", "Q8_0", "F16", ...
  contextLength: number;  // n_ctx the engine was built with
}

export interface LoadModelOpts {
  timeoutMs?: number;     // default 120_000
  nGpuLayers?: number;    // -1 = all (default)
}

export type TokenStream =
  ReadableStream<Uint8Array> & AsyncIterable<Token> & {
    /** Bytes only — equivalent to a getReader().read() loop. */
    asText(): AsyncIterable<string>;
  };

export interface Token {
  text: string;
  tokenId: number;
  pos: number;          // position within this actor's KV cache for this model
}
```

### 5A.1.4.1 Why split `ai` out of `ctx`?

1. **Testing**: pass a mock `ai` object that returns canned tokens; everything else keeps its real `ctx`.
2. **Introspection**: `this.ai.models()` is an obvious API surface. Having to learn "inference is actually on ctx" is needless cognitive load.
3. **Evolvability**: future AI primitives (embeddings, classification, image gen) live on `ai`; they'd crowd `ctx` otherwise.
4. **Symmetry** with `state`, `alarm` — each capability gets its own object.

### 5A.1.6 Hook semantics — precise timing

| Hook       | Invoked…                                                   | Awaited?                    |
|------------|------------------------------------------------------------|-----------------------------|
| `onStart`  | Before the first `onRequest` / `onMessage` of an activation. Completes before any request is handled. | Yes — all else blocks on it.|
| `onStop`   | After the last in-flight request resolves. Before state flushes. | Yes (with deadline, see below). |
| `onRequest`| Per incoming HTTP request, in its own fiber.               | N/A                         |
| `onMessage`| Per incoming WS frame, in-order within a given connection. | Yes (next frame blocks).    |

**`onStop` deadlines**:

| reason     | deadline       | After deadline…                                |
|------------|----------------|------------------------------------------------|
| `idle`     | 10 s           | Cancelled; we log and continue to state flush. |
| `evicted`  | 2 s            | Cancelled; state is flushed best-effort.       |
| `deploy`   | 30 s           | Cancelled; new version activates immediately.  |
| `destroy`  | 10 s           | Cancelled; artefacts removed regardless.       |
| `shutdown` | 5 s            | Cancelled; process exits.                      |

These are configurable per-actor via an optional `lifecycle` config block
(v1).

### 5A.1.7 WebSocket specifics

There is no `onConnect` / `onDisconnect` in the v0 API — they collapse into
`onStart` / `onStop`'s reasons. An empty connection (no messages sent) is
visible to the actor via the `ws.onClose` property on any `ws` handle it
retains. If you want explicit per-connection hooks, we'll add them in v1
once we see the usage patterns.

### 5A.2 User code — the full picture

```ts
// src/agent.ts  (user writes this)
import {
  DurableInference,
  type ScheduleInfo,
  type StartInfo,
  type StopInfo,
} from "@dis/sdk";

const MODEL = "llama-3.2-1b";

interface Input  { system: string }
interface State  { system: string; turns: number; createdAt: number; lastActiveAt: number }

export class Agent extends DurableInference<Input, State> {
  override async onStart({ reason, input }: StartInfo<Input>): Promise<void> {
    await this.ctx.blockConcurrencyWhile(async () => {
      this.state = await this.ctx.initialState<State>({
        system: "", turns: 0, createdAt: 0, lastActiveAt: 0,
      });

      await this.ai.loadModel(MODEL);

      if (reason === "create") {
        this.state.system    = input!.system;
        this.state.createdAt = Date.now();
        await this.ctx.sql.exec(
          `CREATE TABLE IF NOT EXISTS turns (
             idx INTEGER PRIMARY KEY, role TEXT, text TEXT, ts INTEGER
           )`,
        );
      }
    });

    this.ctx.broadcast(JSON.stringify({ kind: "hello" }));

    // Idempotent — safe on every wake.
    await this.ctx.schedule({ every: 5 * 60 }, "rollupStats", undefined,
                            { idempotentKey: "rollup" });
    await this.ctx.schedule("0 3 * * *", "gcOldTurns", { keepDays: 7 },
                            { idempotentKey: "gc" });
  }

  override async onStop({ reason }: StopInfo): Promise<void> {
    this.ctx.broadcast(JSON.stringify({ kind: "bye", reason }));
    this.state.lastActiveAt = Date.now();
    await this.state.$flush();
  }

  override async onRequest(req: Request): Promise<Response> {
    const prompt = await req.text();

    this.state.turns += 1;                // auto-persists (throttled)

    await this.ctx.sql.exec(
      `INSERT INTO turns(role, text, ts) VALUES (?, ?, ?)`,
      ["user", prompt, Date.now()],
    );

    const stream = this.ai.generate(MODEL, prompt, { maxTokens: 256, temperature: 0.7 });
    const [toClient, toDb] = stream.tee();
    this.recordReply(toDb).catch(console.error);

    return new Response(toClient, {
      headers: { "content-type": "text/event-stream" },
    });
  }

  override async onMessage(msg: string | Uint8Array, ws: WebSocket): Promise<void> {
    const text = typeof msg === "string" ? msg : new TextDecoder().decode(msg);

    this.ctx.broadcast(JSON.stringify({ kind: "typing", from: "peer" }), { except: ws });

    const stream = this.ai.generate(MODEL, text, { maxTokens: 256 });
    for await (const tok of stream) {
      this.ctx.broadcast(JSON.stringify({ kind: "token", text: tok.text }));
    }
    this.ctx.broadcast(JSON.stringify({ kind: "done" }));
  }

  async rollupStats(_payload: undefined, info: ScheduleInfo): Promise<void> {
    console.log("[rollup]", this.ctx.id, "turns:", this.state.turns, "attempt:", info.attempt);
  }

  async gcOldTurns(args: { keepDays: number }): Promise<void> {
    const cutoff = Date.now() - args.keepDays * 86_400_000;
    await this.ctx.sql.exec("DELETE FROM turns WHERE ts < ?", [cutoff]);
  }

  private async recordReply(stream: ReadableStream<Uint8Array>) {
    const reader = stream.getReader();
    let text = "";
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      text += new TextDecoder().decode(value);
    }
    await this.ctx.sql.exec(
      `INSERT INTO turns(role, text, ts) VALUES (?, ?, ?)`,
      ["assistant", text, Date.now()],
    );
  }
}

// src/index.ts  (user writes this)
import { startRunner } from "@dis/sdk";
import { Agent } from "./agent.js";

startRunner({
  engineUrl: process.env.DIS_ENGINE_URL ?? "ws://localhost:7070/runner",
  namespace: "my-app",
  actors: { agent: Agent },
});
```

### 5A.2.1 Broadcast semantics — runtime-managed peers

- The runtime tracks every WebSocket opened to an actor in a per-actor set.
- When an actor goes through `onStop`, all peer `ws` handles still have a
  chance to deliver a last message via `this.ctx.broadcast(...)` inside the
  `onStop` body; after the hook returns the runtime closes any remaining
  open sockets with code 1001 ("going away").
- `broadcast` is fire-and-forget: delivery errors on individual peers
  silently evict them and don't throw.
- For sending to only *one* specific peer, call `ws.send(...)` directly
  on the `ws` handle passed into `onMessage`. `broadcast` is for
  **fan-out**, not targeted sends.

### 5A.3 CLI

```
dis-runner dev                  # runs startRunner() with hot reload
dis-runner deploy ./dist        # bundles and deploys to an engine
```

### 5A.4 Addressing actors

Clients address an actor via HTTP:

```
PUT /v1/actors/agent   body: { "namespace": "my-app", "key": ["user-42"] }
                       → { "id": "…" }

POST /v1/actors/{id}/request   body: (raw bytes, passed to onRequest as Request)
                               → response streamed from user code
```

Identity rules (same as §12.1):
- `(namespace, actor_name, key)` is globally unique within the cluster.
- `actor_name` == `"agent"` here (the key in the `actors` map).
- Session id = derived 16-byte Id128, stable for the life of the actor.

### 5A.5 State change tracking

`ctx.state` is wrapped in a `Proxy` that marks the session dirty on any
mutation. A throttled flusher (`stateSaveIntervalMs`, default 1000) sends
the CBOR blob to the engine via `SaveState` RPC. Explicit `saveState(
{ immediate: true })` forces a sync flush. The runtime serializes only
CBOR-compatible values (Map, Set, TypedArray, plain objects, primitives);
functions and DOM types throw on assignment.

### 5A.6 The RPC shape (runner ↔ engine)

Multiplexed over a single WebSocket. Messages are CBOR-encoded frames
with a 4-byte big-endian length prefix. Frame schema:

```
Frame = {
  kind: u8,           // opcode
  tag:  u32,          // correlation id for req/resp
  payload: cbor any,
}
```

Opcodes (enum):

```
// engine → runner
0x01  Hello                { runnerId, engineVersion }
0x10  ActorStart           { sessionId, actorName, key, namespace,
                             state?, input? }
0x11  ActorStop            { sessionId, reason }
0x12  ActorWake            { sessionId }
0x13  ActorSleep           { sessionId }
0x20  ClientRequest        { sessionId, requestId, method, url, headers, body }
0x21  ClientRequestAbort   { sessionId, requestId }

// runner → engine
0x80  RunnerReady          { namespace, actors: string[] }
0x90  ClientResponse       { requestId, status, headers, bodyStart|bodyChunk|bodyEnd }
0xA0  Generate             { sessionId, prompt|tokens, opts }       // expects stream response
0xA1  Tokenize             { sessionId, text }                       // returns token[]
0xA2  SaveState            { sessionId, stateCbor, version }
0xA3  LoadState            { sessionId }                             // returns cbor blob
0xA4  SqlExec              { sessionId, sql, params }
0xA5  SqlQuery             { sessionId, sql, params }
0xA6  Hibernate            { sessionId }

// bidirectional
0xF0  TokenChunk           { tag, tokens: Token[], done?: bool }
0xFF  Error                { tag, code, message }
```

Streaming responses (e.g., tokens from `Generate`) use multiple `TokenChunk`
frames with the original `tag`, terminated by a frame with `done=true`.



### 6.1 State machine

```
                       +----------+
                       |destroyed |
                       +----▲-----+
                            |
                       final flush
                            |
    create                 +--+--+
       +--->provisioning-->|     |
                           |     |<-------------+
                           v     |              |
     (allocate slot)  [loading]<--+---resume----+
                           |                    |
                   ready   v                    |
                      [running]                 |
                      ^      |                  |
            next req  |      | idle_timeout     |
                      |      v                  |
                   [idle]--->[hibernating]      |
                                 |              |
                          drain+flush           |
                                 v              |
                          [hibernated]----------+
                                 |
                          destroy|
                                 v
                          [destroying]
                                 |
                                 v
                             [destroyed]
```

### 6.2 Allocation (provisioning → loading → running)

Pseudocode for `Runtime.createSession`:

```zig
fn createSession(rt: *Runtime, req: CreateReq) !*Session {
    // 1. Key uniqueness check
    const packed = packKey(rt.alloc, .{ req.namespace, req.model, req.key });
    rt.registry_mutex.lockWrite();
    defer rt.registry_mutex.unlockWrite();
    if (rt.by_key.get(packed)) |existing| return existing;   // get-or-create

    // 2. Admission control
    const model = rt.models.get(req.model) orelse return error.UnknownModel;
    if (model.live_sessions.load(.acq) >= model.max_live_sessions) {
        // v0: fail fast. v1: queue or force hibernate an LRU session.
        return error.TooManyLiveSessions;
    }

    // 3. VRAM slot reservation (can fail → surface to client)
    const slot = try rt.vram.reserve(kvCacheBytes(model, req.seq_capacity));
    errdefer rt.vram.release(slot);

    // 4. Build the Session struct, insert into registries
    const sess = try rt.alloc.create(Session);
    sess.* = .{
        .id = genId(rt.node_label),
        .namespace = dupe(rt.alloc, req.namespace),
        .key_packed = packed,
        .model = model,
        .phase = .loading,
        .state_blob = cbor.encode(req.initial_state orelse .{}),
        .state_dirty = true,
        .state_version = 1,
        .sqlite = null,
        .sqlite_path = pathFor(rt.data_dir, sess.id, "db"),
        .kv = .{ .vram = .{ .slot = slot, .buffers = undefined } },
        .kv_cursor = 0,
        .kv_snapshot_version = 0,
        .created_ms = nowMs(),
        .last_used_ms = nowMs(),
        .queue = RequestQueue.init(rt.alloc),
        .busy = .{},
        .runtime = rt,
    };
    try rt.by_id.put(sess.id, sess);
    try rt.by_key.put(packed, sess);

    // 5. Allocate KV cache buffers on the selected device
    //    (uses ZML's Buffer.uninitialized — see model/kv_cache.zig)
    sess.kv.vram.buffers = try KvCacheAlloc(model, req.seq_capacity);

    // 6. Write metadata row to meta_db (durable)
    try rt.meta_db.exec(
        \\INSERT INTO sessions(id, namespace, model_id, key_packed,
        \\                     phase, created_ms, seq_capacity)
        \\VALUES (?1, ?2, ?3, ?4, 'loading', ?5, ?6)
    , .{ sess.id, sess.namespace, model.id, packed, sess.created_ms, req.seq_capacity });

    _ = model.live_sessions.fetchAdd(1, .acq_rel);

    // 7. Spawn the session fiber — it transitions to .running once ready
    try rt.queue_pool.spawn(sessionLoop, .{ sess });

    return sess;
}
```

### 6.3 The session loop (running)

```zig
fn sessionLoop(sess: *Session) void {
    sess.phase = .running;
    defer sess.phase = .destroyed;

    while (true) {
        const req_or_null = sess.queue.popOrTimeout(sess.runtime.cfg.idle_ms);
        const req = req_or_null orelse {
            // Idle timeout fired — trigger hibernation
            sess.hibernateSelf() catch |e| std.log.err("hibernate: {}", .{e});
            // hibernateSelf re-enqueues us into the hibernated set and returns.
            // The loop fiber exits; a new one spawns on wake.
            return;
        };

        sess.busy.lock();
        defer sess.busy.unlock();
        sess.last_used_ms = nowMs();

        switch (req) {
            .chat => |c| handleChat(sess, c),
            .raw  => |r| handleRaw(sess, r),
            .hibernate => |tx| { sess.hibernateSelf() catch {}; tx.send({}); return; },
            .resume    => |tx| { tx.send({}); },          // no-op if already running
            .checkpoint => |tx| { sess.checkpoint() catch {}; tx.send({}); },
            .destroy  => |tx| {
                sess.destroyInline() catch {};
                tx.send({});
                return;
            },
        }
    }
}
```

### 6.4 Hibernate

```zig
fn hibernateSelf(sess: *Session) !void {
    sess.phase = .hibernating;

    // 1. Flush state_blob to disk if dirty
    if (sess.state_dirty) {
        try sess.runtime.flushState(sess);   // writes cbor blob next to sqlite
    }

    // 2. Close sqlite (WAL checkpoint then close)
    if (sess.sqlite) |s| { try s.checkpoint(); s.close(); sess.sqlite = null; }

    // 3. Snapshot KV cache: VRAM → pinned RAM → disk (two-stage)
    //    MVP keeps only disk tier; RAM tier is v1.
    switch (sess.kv) {
        .vram => |v| {
            var bytes = try kvCacheToBytes(sess.runtime.alloc, sess.model, v);
            defer sess.runtime.alloc.free(bytes);

            const path = pathFor(sess.runtime.data_dir, sess.id, "kv");
            try writeAtomic(path, bytes);

            sess.kv.vram.buffers.deinit();
            sess.runtime.vram.release(v.slot);

            sess.kv = .{ .disk = .{
                .path = path,
                .shape = sess.model.kv_shape_template.withCapacity(sess.seq_budget),
                .bytes_len = bytes.len,
            }};
            sess.kv_snapshot_version += 1;
        },
        else => {},   // already off-VRAM
    }

    // 4. Update meta_db row
    try sess.runtime.meta_db.exec(
        "UPDATE sessions SET phase='hibernated', last_used_ms=?2 WHERE id=?1",
        .{ sess.id, sess.last_used_ms });

    // 5. Decrement live count
    _ = sess.model.live_sessions.fetchSub(1, .acq_rel);
    sess.phase = .hibernated;
}
```

### 6.5 Wake

Triggered when the Router finds a session whose phase ∈ {`hibernated`,
`hibernating`} and an incoming request targets it.

```zig
fn wake(sess: *Session) !void {
    assert(sess.phase == .hibernated);

    // Re-reserve a VRAM slot
    const seq_cap = sess.kv.disk.shape.seq_capacity;
    const slot = try sess.runtime.vram.reserve(kvCacheBytes(sess.model, seq_cap));

    // Load KV bytes from disk → pinned host → device
    var buffers = try kvCacheFromDisk(sess.model, sess.kv.disk.path, slot);

    sess.kv = .{ .vram = .{ .slot = slot, .buffers = buffers } };
    sess.phase = .loading;
    _ = sess.model.live_sessions.fetchAdd(1, .acq_rel);

    // Respawn the session loop
    try sess.runtime.queue_pool.spawn(sessionLoop, .{ sess });
}
```

### 6.6 Destroy

```zig
fn destroyInline(sess: *Session) !void {
    sess.phase = .destroying;
    defer sess.phase = .destroyed;

    sess.queue.closeAndDrain();              // refuse new requests

    if (sess.sqlite) |s| { s.close(); sess.sqlite = null; }
    switch (sess.kv) {
        .vram => |v| { v.buffers.deinit(); sess.runtime.vram.release(v.slot); },
        .ram  => |r| sess.runtime.alloc.free(r.bytes),
        .disk => {},
        .absent => {},
    }

    // Remove metadata + disk artefacts
    try sess.runtime.meta_db.exec("DELETE FROM sessions WHERE id=?1", .{ sess.id });
    try std.fs.deleteTreeAbsolute(sessionDir(sess.runtime.data_dir, sess.id));

    sess.runtime.registry_mutex.lockWrite();
    _ = sess.runtime.by_id.remove(sess.id);
    _ = sess.runtime.by_key.remove(sess.key_packed);
    sess.runtime.registry_mutex.unlockWrite();

    _ = sess.model.live_sessions.fetchSub(1, .acq_rel);
    sess.runtime.alloc.destroy(sess);
}
```

## 7. Inference loop (llama.cpp side)

All inference lives inside `dis-infer`. The engine forwards Generate RPCs
and splices token chunks back to the client. The SDK's
`this.generate(prompt)` goes: runner → engine (WS) → infer (unix socket) →
llama.cpp → GPU → back.

### 7.1 How llama.cpp models a session

llama.cpp's `llama_context` has N parallel **slots** (sequences), addressed
by `llama_seq_id` (an `int32_t`). Each slot holds its own KV cache inside
one shared KV-cache buffer:

```
llama_context
 ├─ kv_cache (one big buffer, n_ctx * n_layer * ... )
 │   ├─ seq 0 → tokens [0..pos_0]
 │   ├─ seq 1 → tokens [0..pos_1]
 │   └─ ...
 ├─ sampler_chain[]        — per slot, configured per request
 └─ batch                  — scratch for llama_decode(...)
```

We map `session_id → llama_seq_id`. The engine keeps this mapping; infer
just services seq_ids. When we hibernate, we snapshot the seq's KV to a
file and free the slot.

### 7.2 Prefill + decode — one llama_decode per turn

```zig
// infer/src/session.zig   (pseudocode)
const c = @cImport({ @cInclude("llama.h"); });

/// Prefill: push the new user-turn tokens into seq_id.
/// llama.cpp handles the "position" bookkeeping per seq.
fn prefill(ctx: *c.llama_context, seq_id: c.llama_seq_id,
           tokens: []const c.llama_token) !c.llama_token
{
    var batch = c.llama_batch_init(@intCast(tokens.len), 0, 1);
    defer c.llama_batch_free(batch);
    for (tokens, 0..) |tok, i| {
        c.llama_batch_add(&batch, tok, @intCast(i + current_pos), &seq_id, 1,
                          i == tokens.len - 1);  // logits only for last token
    }
    if (c.llama_decode(ctx, batch) != 0) return error.DecodeFailed;

    // Sample first response token
    return sampleOne(ctx, seq_id);
}

fn decodeOne(ctx: *c.llama_context, seq_id: c.llama_seq_id,
             token: c.llama_token, pos: c.llama_pos) !c.llama_token
{
    var batch = c.llama_batch_init(1, 0, 1);
    defer c.llama_batch_free(batch);
    c.llama_batch_add(&batch, token, pos, &seq_id, 1, true);
    if (c.llama_decode(ctx, batch) != 0) return error.DecodeFailed;
    return sampleOne(ctx, seq_id);
}
```

### 7.3 Sampling

Built into llama.cpp; we build a `llama_sampler_chain` per request:

```zig
fn buildSampler(opts: SamplingOpts) *c.llama_sampler {
    const chain = c.llama_sampler_chain_init(c.llama_sampler_chain_default_params());
    if (opts.temperature != 1.0)
        c.llama_sampler_chain_add(chain, c.llama_sampler_init_temp(opts.temperature));
    if (opts.top_k > 0)
        c.llama_sampler_chain_add(chain, c.llama_sampler_init_top_k(opts.top_k));
    if (opts.top_p < 1.0)
        c.llama_sampler_chain_add(chain, c.llama_sampler_init_top_p(opts.top_p, 1));
    c.llama_sampler_chain_add(chain, c.llama_sampler_init_dist(opts.seed));
    return chain;
}

fn sampleOne(ctx: *c.llama_context, seq_id: c.llama_seq_id) c.llama_token {
    const tok = c.llama_sampler_sample(sampler, ctx, -1);  // -1 = last logits
    c.llama_sampler_accept(sampler, tok);
    return tok;
}
```

### 7.4 Streaming loop (inside dis-infer, per request)

```zig
fn generate(host: *LlamaHost, seq_id: c.llama_seq_id,
            prompt_tokens: []const c.llama_token,
            sampler: *c.llama_sampler,
            out: *RpcWriter) !void
{
    // 1. Tokenize the user turn (done on host.model_vocab by caller)
    // 2. Prefill
    var next = try prefill(host.ctx, seq_id, prompt_tokens);
    var pos: c.llama_pos = @intCast(prompt_tokens.len);

    // 3. Decode loop with streaming
    var produced: u32 = 0;
    while (produced < host.max_tokens) : (produced += 1) {
        if (c.llama_vocab_is_eog(host.vocab, next)) break;

        // token → text fragment (handles multi-byte splits)
        var piece: [64]u8 = undefined;
        const n = c.llama_token_to_piece(host.vocab, next,
                                          &piece, piece.len, 0, true);
        if (n < 0) return error.TokenToPiece;
        try out.tokenChunk(next, piece[0..@intCast(n)]);

        next = try decodeOne(host.ctx, seq_id, next, pos);
        pos += 1;
    }
    try out.done(.{ .stop_reason = .eos, .total_pos = pos });
}
```

### 7.5 Chat templates

llama.cpp pulls the chat template out of GGUF metadata:

```zig
fn applyTemplate(model: *const c.llama_model, turns: []const ChatTurn)
    ![]u8
{
    // Convert []ChatTurn → []llama_chat_message (role + content)
    // Call llama_chat_apply_template(model, null, msgs, n, true, &buf);
    ...
}
```

This handles Llama-3, Qwen, Gemma, Mistral, Phi, etc. without us hardcoding
anything per model.

### 7.6 KV rollback on abort

Same problem as before — partial assistant-turn KVs need to be invalidated
when the client disconnects mid-stream. llama.cpp gives us:

```c
void llama_kv_cache_seq_rm(llama_context * ctx,
                           llama_seq_id   seq_id,
                           llama_pos      p0,
                           llama_pos      p1);
```

On abort, we call this with `p0 = turn_start_pos`, `p1 = -1` to delete all
KV past the user turn, and reset `pos` in our side-table. Next request
re-prefills only the clean region.

### 7.7 Snapshots

```c
size_t llama_state_seq_save_file(llama_context *,
                                  const char *filepath,
                                  llama_seq_id,
                                  const llama_token *, size_t);
size_t llama_state_seq_load_file(llama_context *,
                                  const char *filepath,
                                  llama_seq_id dst,
                                  llama_token *out_tokens, size_t cap,
                                  size_t *out_len);
```

Called from `dis-infer` on Hibernate (save + seq_rm) and on Wake
(load into a free seq_id). File is opaque to us — llama.cpp owns the
format — so we just write to `<data_dir>/sessions/<id_hex>/kv.bin`.

## 7A. Infer RPC (engine ↔ dis-infer)

Unix socket at `/run/dis/infer.sock` by default (configurable). Custom
binary frame protocol — small, streaming-friendly, no HTTP overhead.

### 7A.1 Frame format

```
┌──────────┬──────────┬──────────┬──────────┐
│ len (u32 BE, body only) │  kind  │  tag    │
├──────────┴──────────┴──────────┴──────────┤
│  body (length = `len` bytes)              │
└───────────────────────────────────────────┘

kind: u8 opcode
tag:  u32 BE, correlation id for req/resp
body: opcode-specific payload, CBOR-encoded
```

### 7A.2 Opcodes

**Engine → Infer (requests):**

```
0x01  LoadModel          { path, n_ctx, n_gpu_layers, ... }
0x02  AllocSeq           { session_id }                    → { seq_id }
0x03  FreeSeq            { seq_id }
0x04  Tokenize           { seq_id, text }                  → { tokens }
0x05  ApplyTemplate      { turns: [{role,content}] }       → { tokens }
0x06  Prefill            { seq_id, tokens, sampler_opts }  → stream of Token
0x07  DecodeToken        { seq_id, sampler_opts }          → stream of Token
0x08  AbortGenerate      { tag_of_running_generate }
0x09  KvRemoveRange      { seq_id, p0, p1 }
0x0A  SnapshotSeq        { seq_id, path }                  → { bytes_written }
0x0B  RestoreSeq         { session_id, path }              → { seq_id, n_tokens }
0x0C  Stats                                                 → { vram_used, seqs_active, ... }
```

**Infer → Engine (responses / streaming):**

```
0x80  Ack                { tag }
0x81  Result             { tag, cbor_payload }
0x82  TokenChunk         { tag, token_id, text, pos }
0x83  Done               { tag, stop_reason, total_pos }
0xFF  Error              { tag, code, message }
```

Streaming responses use multiple `TokenChunk` frames with the same `tag`,
terminated by `Done`.

### 7A.3 Engine-side infer client (pseudocode)

```zig
// engine/src/infer_client.zig
const InferClient = struct {
    socket: std.Io.net.Stream,
    alloc: std.mem.Allocator,
    io: std.Io,
    next_tag: std.atomic.Value(u32),
    pending: std.AutoHashMap(u32, *Oneshot),

    pub fn allocSeq(self: *InferClient, sid: Id128) !i32 {
        const tag = self.next_tag.fetchAdd(1, .acq_rel);
        try self.writeFrame(tag, 0x02, .{ .session_id = sid });
        const resp = try self.awaitResult(tag);
        return resp.seq_id;
    }

    /// Long-running: returns an async iterable of Token frames.
    pub fn prefill(self: *InferClient, seq_id: i32,
                   tokens: []const i32, opts: SamplingOpts,
                   sink: *TokenSink) !void
    {
        const tag = self.next_tag.fetchAdd(1, .acq_rel);
        try self.writeFrame(tag, 0x06, .{ .seq_id = seq_id, .tokens = tokens, .opts = opts });
        try self.awaitStream(tag, sink);
    }
    // ... similar for other opcodes
};
```

### 7A.4 Backpressure

Tokens stream fast; if the client (or the runner WS, or the SSE channel)
reads slowly we need to throttle decode. The infer side's decode loop
blocks on `writeFrame` — so backpressure propagates naturally from the
slow reader all the way down to llama.cpp. No explicit flow control.

## 8. Persistence layout

### 8.1 On-disk layout

```
<data_dir>/
  meta.db                    # SQLite, runtime-level metadata
  sessions/
    <id_hex>/
      state.cbor             # last flushed state blob
      kv.bin                 # last kv cache snapshot (shape header + raw tensor bytes)
      db.sqlite              # per-session SQLite (user data)
      db.sqlite-wal
      db.sqlite-shm
  models/
    <model_id_sanitized>/
      weights/               # safetensors or symlink
      tokenizer.json
      config.json
      compiled/              # cached compiled XLA modules keyed by
                             #   (zml_version, seq_budget, shardings_hash)
```

### 8.2 `meta.db` schema

```sql
CREATE TABLE sessions (
    id           BLOB PRIMARY KEY,       -- 16 bytes
    namespace    TEXT NOT NULL,
    model_id     TEXT NOT NULL,
    key_packed   TEXT NOT NULL,
    phase        TEXT NOT NULL,
    created_ms   INTEGER NOT NULL,
    last_used_ms INTEGER NOT NULL,
    seq_capacity INTEGER NOT NULL,
    kv_cursor    INTEGER NOT NULL DEFAULT 0,
    state_version INTEGER NOT NULL DEFAULT 0,
    kv_version   INTEGER NOT NULL DEFAULT 0,
    UNIQUE (namespace, model_id, key_packed)
);

CREATE INDEX idx_sessions_last_used ON sessions(last_used_ms);
CREATE INDEX idx_sessions_phase_time ON sessions(phase, last_used_ms);
```

### 8.3 KV snapshot file format

```
header (fixed 64 bytes):
  magic      = "DISKVC\0\0"    (8 bytes)
  version    = u32 le
  dtype      = u8   (0=f16, 1=bf16, 2=f32)
  layers     = u32 le
  heads_kv   = u32 le
  head_dim   = u32 le
  seq_cap    = u32 le
  cursor     = u32 le          # # valid tokens
  crc32      = u32 le          # over payload
  reserved   = u8[...]

payload:
  K tensor:  layers × seq_cap × heads_kv × head_dim × dtype
  V tensor:  layers × seq_cap × heads_kv × head_dim × dtype
  layer_index_scalar: u32
  rng_state: 32 bytes
```

Writes are atomic: write to `kv.bin.tmp`, fsync, rename.

### 8.4 State blob (CBOR)

Whatever the client wants. Restricted to CBOR-serializable types.
Inspired by Rivet: a single whole-blob overwrite, throttled.

The state can include a `history` array (list of (role, text) turns). v0
doesn't interpret it; it's just passed through. v1 may use it for automatic
chat template rendering.

### 8.5 Crash recovery

At startup:

```zig
fn recover(rt: *Runtime) !void {
    // Read all sessions from meta.db
    var rows = try rt.meta_db.query("SELECT id, namespace, model_id, key_packed, " ++
                                    "phase, kv_cursor, seq_capacity, last_used_ms FROM sessions", .{});
    while (try rows.next()) |row| {
        const model = rt.models.get(row.model_id) orelse {
            std.log.warn("orphan session {x} for unknown model {s}", .{row.id, row.model_id});
            continue;
        };

        // All sessions come back as Hibernated.
        // Running/loading sessions were killed by the crash; their last good
        // KV snapshot (if any) is on disk. If kv_version=0 there's nothing to
        // restore — we start with an empty KV on next wake.
        const sess = try rt.alloc.create(Session);
        sess.* = .{
            .id = row.id, .namespace = row.namespace, .key_packed = row.key_packed,
            .model = model, .phase = .hibernated,
            .state_blob = try readCbor(statePath(rt.data_dir, row.id)),
            .state_dirty = false, .state_version = row.state_version,
            .sqlite = null, .sqlite_path = sqlitePath(rt.data_dir, row.id),
            .kv = if (row.kv_version > 0)
                .{ .disk = diskHandleFor(row.id, row.seq_capacity) }
            else .{ .absent = {} },
            .kv_cursor = if (row.kv_version > 0) row.kv_cursor else 0,
            .kv_snapshot_version = row.kv_version,
            .created_ms = row.created_ms, .last_used_ms = row.last_used_ms,
            .queue = RequestQueue.init(rt.alloc), .busy = .{}, .runtime = rt,
        };
        try rt.by_id.put(sess.id, sess);
        try rt.by_key.put(sess.key_packed, sess);
    }
}
```

## 9. KV cache management

### 9.1 VramTracker

```zig
const SlotId = u32;

const VramTracker = struct {
    total_bytes: u64,
    used_bytes: std.atomic.Value(u64),
    slots: std.AutoHashMap(SlotId, Reservation),
    next_id: std.atomic.Value(SlotId),
    mutex: std.Thread.Mutex,

    const Reservation = struct { bytes: u64, sess: ?*Session };

    pub fn reserve(self: *VramTracker, bytes: u64) !SlotId {
        // Fast path
        const after = self.used_bytes.fetchAdd(bytes, .acq_rel) + bytes;
        if (after <= self.total_bytes) {
            return self.registerSlot(bytes, null);
        }
        _ = self.used_bytes.fetchSub(bytes, .acq_rel);

        // Pressure path: try to evict LRU hibernatable sessions
        try self.evictUntilFree(bytes);

        _ = self.used_bytes.fetchAdd(bytes, .acq_rel);
        return self.registerSlot(bytes, null);
    }

    pub fn release(self: *VramTracker, slot: SlotId) void {
        const r = self.slots.fetchRemove(slot) orelse return;
        _ = self.used_bytes.fetchSub(r.value.bytes, .acq_rel);
    }

    fn evictUntilFree(self: *VramTracker, need: u64) !void {
        // Find hibernate candidates: sessions in .idle or .running (preempt)
        // ordered by last_used_ms ASC, skip .loading and actively-busy ones.
        var freed: u64 = 0;
        while (freed < need) {
            const victim = self.pickVictim() orelse return error.VramExhausted;
            // Request hibernation and wait
            try victim.queue.push(.{ .hibernate = oneshotBlocking() });
            freed += self.slotBytesFor(victim);
        }
    }
};
```

### 9.2 Size math

```
kv_bytes = 2 /* K+V */
         × layers
         × seq_capacity
         × heads_kv
         × head_dim
         × sizeof(dtype)
```

Example — Llama-3.2-1B: 16 layers, 8 kv heads, head_dim 64, seq 8192, f16:

```
2 × 16 × 8192 × 8 × 64 × 2 = 268_435_456 bytes ≈ 256 MiB per session
```

A 40 GiB A100 fits ~150 such sessions' KV before other allocations. The
config's `max_live_sessions` must be set below that.

### 9.3 Snapshot / restore (VRAM ↔ disk)

```zig
fn kvCacheToBytes(alloc: Allocator, model: *Model, v: KvVram) ![]u8 {
    // v.buffers.k / .v are zml.Buffers on device.
    // Sync-read each into a host pinned slice and concatenate.
    const shape = model.kv_shape_template;
    const dtype_bytes = shape.dtype.size();
    const per_tensor = shape.layers * shape.seq_capacity * shape.heads_kv
                     * shape.head_dim * dtype_bytes;

    const buf = try alloc.alloc(u8, 2 * per_tensor + 64);

    writeHeader(buf[0..64], shape, v.cursor);
    try v.buffers.k.readInto(buf[64..][0..per_tensor]);
    try v.buffers.v.readInto(buf[64 + per_tensor ..][0..per_tensor]);
    return buf;
}

fn kvCacheFromDisk(model: *Model, path: []const u8, slot: SlotId) !KvBuffers {
    var f = try std.fs.openFileAbsolute(path, .{});
    defer f.close();
    var header: [64]u8 = undefined;
    _ = try f.readAll(&header);
    const shape = parseHeader(header);
    assert(shape.eq(model.kv_shape_template));

    // Stream into device via ZML's Buffer.fromReader (async h2d DMA)
    const k = try Buffer.fromReader(model.platform, shape.tensorShape(), &f, size = per_tensor);
    const v = try Buffer.fromReader(model.platform, shape.tensorShape(), &f, size = per_tensor);
    return .{ .k = k, .v = v, .layer_index = zeroScalar(u32) };
}
```

The key ZML touchpoints here are `Buffer.readInto` (doesn't exist yet — we'll
add it) and `Buffer.fromReader` (similar). For v0 we're allowed to go the slow
path: `Buffer.toSliceAlloc` → host pinned → `Buffer.fromSlice`.

### 9.4 Hibernation scanner

```zig
fn hibernatorTick(rt: *Runtime) void {
    const now = nowMs();
    var it = rt.sessions_by_last_used.iterator();  // sorted asc
    while (it.next()) |sess| {
        if (sess.phase != .running and sess.phase != .idle) continue;
        if (now - sess.last_used_ms < rt.cfg.idle_ms) break;  // sorted ⇒ rest are newer
        sess.queue.tryPush(.{ .hibernate = oneshotFireAndForget() });
    }
}
```

## 10. Model loading

At startup the node loads one model. The full flow:

```zig
fn loadModel(rt: *Runtime, spec: ModelSpec) !*Model {
    // 1. Resolve source → concrete repo (hf://, s3://, file://)
    const repo = try resolveVfs(rt.vfs, spec.source);

    // 2. Parse config.json, tokenizer.json
    const cfg = try ModelConfig.parse(repo.config_json);
    const tok = try zml.tokenizer.Tokenizer.fromFile(repo.tokenizer_json);

    // 3. Build the Zig model struct with placeholder Tensors
    const llm_meta = try buildLlmMeta(cfg);   // shapes for all weights

    // 4. Stream weights directly to device (ZML's zml.io.load)
    const platform = rt.platform;
    const sharding = try zml.sharding.replicated(platform);
    const weights = try zml.io.load(LlmModel, llm_meta, rt.alloc, rt.io, platform,
        repo.safetensors_store, .{
            .parallelism = 16,
            .dma_chunks  = 32,
            .dma_chunk_size = 128 * zml.MiB,
            .shardings = &sharding,
        });

    // 5. Compile prefill + decode in parallel (seq_capacity determines shape)
    const kv_shape = KvShape{
        .layers = cfg.num_layers, .heads_kv = cfg.num_kv_heads,
        .head_dim = cfg.head_dim, .seq_capacity = spec.seq_capacity,
        .dtype = cfg.kv_dtype,
    };

    const compiled = try compileInParallel(platform, llm_meta, kv_shape);

    // 6. Cache compiled XLA on disk for next start
    try saveCompiledCache(compiled, cachePath(rt.data_dir, spec, kv_shape));

    const m = try rt.alloc.create(Model);
    m.* = .{
        .id = spec.id, .zml_platform = platform, .compiled = compiled,
        .weights = weights, .config = cfg, .tokenizer = tok,
        .kv_shape_template = kv_shape,
        .max_live_sessions = spec.max_live_sessions,
        .live_sessions = .{ .raw = 0 },
    };
    try rt.models.put(m.id, m);
    return m;
}
```

### 10.1 Caching compiled artifacts

The XLA executable is expensive to build (~minutes). Cache it keyed by:

```
sha256( zml_version || platform_target || model_id || safetensors_hash
        || seq_capacity || shardings_hash )
```

Stored in `<data_dir>/models/<id>/compiled/<hash>/{prefill.xla,decode.xla,meta.cbor}`.

## 11. Concurrency model

### 11.1 Per-session serialization

Each session's request queue is a Zig channel. The session loop pops one
request at a time and holds `sess.busy` for the entire prefill+decode. No
concurrent chat turns against one session.

### 11.2 Cross-session parallelism on one GPU

Multiple sessions' decode steps interleave naturally: PJRT dispatches each
`Exe.call` to the GPU asynchronously, then we block on `toSlice` for the
token id. While session A is blocked awaiting its DMA-back, session B can
submit its next decode step. This is concurrent but **not** batched — each
session gets its own kernel launch.

For MVP we don't build a scheduler. We rely on `Exe.call` being thread-safe
(ZML docs need verification — if not, wrap in a platform-wide mutex).

### 11.3 Task model

Zig 0.16 ships `std.Io` with fibers. We use fibers for:
- Each session loop (one fiber per live session).
- Each HTTP connection (one fiber).

Heavy CPU work (CBOR encode, compression) runs on a small thread pool via
`std.Thread.Pool`.

### 11.4 Locking hierarchy

1. `rt.registry_mutex` — short; only during insert/remove/lookup
2. `sess.busy` — long; during prefill/decode
3. `vram.mutex` — short; during reserve/release
4. `meta_db` — serialized via SQLite's WAL

Rule: never hold `registry_mutex` while waiting on `sess.busy` or on a queue.

## 12. Routing

### 12.1 Single-node MVP

```zig
fn route(rt: *Runtime, req: HttpRequest) !*Session {
    if (req.path_match("/v1/sessions/{id}/...")) |id| {
        rt.registry_mutex.lockRead();
        defer rt.registry_mutex.unlockRead();
        return rt.by_id.get(id) orelse error.NotFound;
    }

    if (req.method == .PUT and req.path_eq("/v1/sessions")) {
        const body = try parseJson(GetOrCreateReq, req.body);
        const packed = packKey(rt.alloc, .{ body.namespace, body.model, body.key });
        {
            rt.registry_mutex.lockRead();
            defer rt.registry_mutex.unlockRead();
            if (rt.by_key.get(packed)) |s| return s;
        }
        return try rt.createSession(.{ ...body });
    }
    // ...
}
```

### 12.2 v1: multi-node

- Session IDs encode a 16-bit node label (first 2 bytes).
- Each node owns a subset of labels. A cluster config file maps labels to
  HTTP endpoints.
- Routing: if `nodeLabel(id) != this_node.label`, HTTP-proxy to the owner.
- For get-or-create: pick a target node via a stable hash of the compound key
  (jump hash or rendezvous). On a hit that's not local, proxy.
- Cross-node uniqueness of `(namespace, model, key)` enforced by whichever
  node owns the hash bucket for that key.
- Membership + label assignment: out of scope. Start with a static config.

## 13. Failure modes

| Failure                                    | Behavior                                                           |
|--------------------------------------------|--------------------------------------------------------------------|
| VRAM exhausted at create                   | 503 with `Retry-After`; LRU-evict hibernatable sessions first      |
| VRAM exhausted at wake                     | Keep session hibernated; return 503                                |
| Process crash mid-prefill                  | On restart, session resumes from last `kv_snapshot_version` (or 0) |
| Process crash during snapshot              | Atomic rename ensures old snapshot preserved                       |
| Model file corrupt / missing               | Refuse to start; fail readiness                                    |
| Client disconnects mid-stream              | `SseStream.sendToken` returns error; loop aborts, cursor rolled back|
| Client disconnects during prefill          | Finish prefill (uninterruptible); drop generated first token       |
| Cursor rollback on client-aborted decode   | Snapshot cursor at start; on abort restore kv_cursor; KV is stale  |
|                                            | but we mark kv as dirty-invalid to force re-prefill next time      |
| Disk full at snapshot                      | Skip; keep in VRAM; log and metric                                 |
| SQLite corruption                          | Per-session blast radius; mark `phase='corrupt'`; admin must fix   |
| Clock skew (for last_used_ms)              | Monotonic clock only; wallclock for logging                        |

### 13.1 The "KV rollback" problem

When decode is interrupted partway through a turn, the KV cache contains
partial assistant-turn KVs that don't correspond to complete text. We can
either:

- (a) leave the KV dirty and require the client to restart the turn from
  scratch (next chat call triggers a re-prefill of the whole user turn) — or
- (b) truncate the KV back to `kv_cursor_at_turn_start` on abort.

MVP picks (b). Requires tracking the turn's starting cursor; on abort we
reset `sess.kv_cursor = turn_start`. The KV buffers on device still contain
stale data past that index, but correctness is preserved because the attention
mask is driven by `token_index` (aka cursor), not by buffer contents.

## 14. File / directory layout

```
dis/
├── SPEC.md                  ← you are here
├── README.md
├── build.zig
├── build.zig.zon
├── BUILD.bazel              ← because ZML requires Bazel
├── MODULE.bazel
├── config.example.toml
├── src/
│   ├── main.zig             ← entry point, CLI parsing
│   ├── config.zig
│   ├── runtime/
│   │   ├── runtime.zig      ← Runtime struct + top-level lifecycle
│   │   ├── registry.zig     ← by_id/by_key maps
│   │   ├── scheduler.zig    ← request queue + session loop spawn
│   │   ├── vram.zig         ← VramTracker
│   │   ├── hibernator.zig
│   │   └── recovery.zig     ← startup recover() from meta.db
│   ├── session/
│   │   ├── session.zig      ← Session struct, lifecycle methods
│   │   ├── queue.zig        ← per-session request queue
│   │   ├── state.zig        ← CBOR blob + throttled flusher
│   │   ├── sqlite.zig       ← per-session SQLite wrapper
│   │   └── kv_cache.zig     ← VRAM alloc, snapshot, restore
│   ├── model/
│   │   ├── model.zig        ← Model struct + registry
│   │   ├── loader.zig       ← ZML weight load + compile
│   │   ├── compile_cache.zig ← hash keys + save/load compiled exe
│   │   ├── config.zig       ← parse HuggingFace config.json
│   │   └── chat_template.zig ← per-model (llama3, qwen, …)
│   ├── http/
│   │   ├── server.zig       ← std.http.Server wrapper
│   │   ├── routes.zig       ← dispatch
│   │   ├── handlers/
│   │   │   ├── sessions.zig
│   │   │   ├── state.zig
│   │   │   ├── sql.zig
│   │   │   └── generation.zig
│   │   └── sse.zig          ← SseStream helper
│   ├── storage/
│   │   ├── meta_db.zig      ← runtime-level SQLite bindings
│   │   ├── paths.zig        ← data_dir/sessions/<id>/… path helpers
│   │   └── atomic.zig       ← write-then-rename
│   ├── util/
│   │   ├── id.zig           ← UUIDv1 + node label encoding
│   │   ├── cbor.zig
│   │   ├── key.zig          ← pack/unpack compound keys
│   │   └── log.zig
│   └── zml_bindings/        ← thin wrappers around zml.Exe/Buffer
│       ├── buffer_io.zig    ← toSlice/fromSlice helpers
│       └── rt.zig           ← lazy Platform init
├── tests/
│   ├── e2e/
│   │   └── chat_roundtrip.zig
│   └── unit/
│       ├── vram_tracker.zig
│       ├── session_lifecycle.zig
│       └── key_pack.zig
└── docs/
    ├── architecture.md
    ├── deploying.md
    └── client_api.md
```

## 15. Build

### 15.1 Why Bazel

ZML's build is Bazel-only in practice. We piggyback on it: our `MODULE.bazel`
declares `@zml` as a dep and our `BUILD.bazel` builds a `zig_binary`:

```python
# BUILD.bazel (root)
load("@rules_zig//zig:defs.bzl", "zig_binary")

zig_binary(
    name = "dis",
    main = "src/main.zig",
    deps = [
        "@zml//zml",
        "@zml//zml/tokenizer",
        "@zml//examples/llm/models/llama:llama_lib",  # fork into our tree later
    ],
    copts = ["-O", "ReleaseFast"],
)
```

### 15.2 Commands

```bash
# Dev CPU build (no GPU)
bazel run //:dis -- --config=config.dev.toml

# CUDA build
bazel run //:dis \
  --@zml//platforms:cuda=true \
  --config=opt \
  -- --config=config.prod.toml

# Release tarball (per-target)
bazel build //:dis_tar --platforms=@zml//platforms:linux_amd64_cuda
```

### 15.3 Config file

```toml
# config.prod.toml
node_label      = 0x0001
bind            = "0.0.0.0:7070"
data_dir        = "/var/lib/dis"
auth_token_file = "/etc/dis/tokens"

idle_ms              = 300_000      # 5 min to hibernate
checkpoint_ms        = 60_000       # periodic kv snapshot while running
default_max_tokens   = 2048

[model]
id             = "meta-llama/Llama-3.2-1B-Instruct"
source         = "hf://meta-llama/Llama-3.2-1B-Instruct"
seq_capacity   = 8192
max_live_sessions = 128
```

## 16. Interfaces we need from ZML (status check)

| Need                                       | ZML has it?                      | Notes                                      |
|--------------------------------------------|----------------------------------|--------------------------------------------|
| Load HF safetensors from local/hf://       | ✅ `zml.io.load`                 | Used verbatim                              |
| Compile prefill + decode graphs            | ✅ `platform.compile`            | Used verbatim                              |
| Per-session KV buffers (in/out aliasing)   | ✅ via `Bufferized(KvCache)`     | Our sessions each build one               |
| Buffer → host bytes (for snapshot)         | ⚠️ `Buffer.toSliceAlloc` works   | Slow path; fine for MVP                    |
| Buffer ← host bytes (for restore)          | ✅ `Buffer.fromSlice`            | Fine                                       |
| Direct-stream Buffer → disk writer         | ❌ not exposed                    | v1: add `Buffer.writeTo(std.io.Writer)`    |
| Concurrent `Exe.call` thread safety        | ❓ unverified                     | Need to audit or wrap in mutex             |
| Hot swap / unload model                    | ⚠️ possible via `Exe.deinit`     | Manual orchestration                       |
| Continuous batching                        | ❌ needs graph w/ `.b` axis      | Out of scope for v0                        |
| Paged KV cache                             | ❌                                | Out of scope                                |
| Return logits instead of sampled tokens    | ⚠️ fork model file                | Possible; v1                                |

## 17. Observability

- Prometheus endpoint at `/v1/metrics`.
- Per-session metrics labels: model, namespace (careful with cardinality).
- Core metrics:
  - `dis_sessions_total{phase}` (gauge)
  - `dis_vram_bytes_used` (gauge)
  - `dis_vram_bytes_total` (gauge)
  - `dis_requests_total{kind,status}` (counter)
  - `dis_prefill_tokens_total` (counter)
  - `dis_decode_tokens_total` (counter)
  - `dis_tokens_per_second{stage=prefill|decode}` (histogram)
  - `dis_time_to_first_token_ms` (histogram)
  - `dis_hibernate_total{reason=idle|pressure}` (counter)
  - `dis_wake_total{hit=warm|cold}` (counter)
  - `dis_kv_snapshot_bytes` (histogram)

- Traces: `opentelemetry-zig` or a homebrew tracer emitting OTLP. Every HTTP
  request is a span; prefill/decode are child spans; snapshot/wake are spans.

## 18. Security (minimum viable)

- Bearer token auth; each token scoped to a `namespace`.
- A token can only see/mutate sessions in its namespace.
- Admin token (from env var) for `/v1/node` and metrics.
- TLS termination out-of-process (behind a reverse proxy). No plans for in-process TLS v0.
- Session SQLite parameters are bound; no raw SQL string interpolation.
- State blob is size-limited (`max_state_bytes` in config, default 1 MiB).

## 19. Client usage example

```bash
# Create or fetch a conversation session
curl -sS -X PUT http://dis/v1/sessions \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta-llama/Llama-3.2-1B-Instruct",
    "key":   ["acme", "user-42", "conv-abc"],
    "seq_capacity": 8192,
    "initial_state": { "system": "You are Aria, a terse assistant." }
  }'
# → { "id": "0001-4e7a-...", "phase": "loading", ... }

# Chat (SSE stream)
curl -N -X POST http://dis/v1/sessions/0001-4e7a.../chat \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "prompt": "What do you remember about me?", "max_tokens": 128 }'
# → stream of event:token / event:done

# Next call reuses the KV cache — only the new user turn is prefilled.
```

## 20. Open questions / design alternatives

Flagging for discussion before we start cutting code:

1. **Single-binary vs engine+runner (Rivet-style).** Current spec is single
   binary. A Rivet-style split would let user code run pre/post hooks in a
   separate process, but triples complexity and isn't needed for pure
   inference. **Decision: single binary, revisit if user-code hooks become a
   requirement.**

2. **Per-session SQLite via KV chunks (Rivet) vs real files.** Rivet chunks
   each SQLite file into 4 KiB KV values for transactional metadata. We
   could do that, but we have native file access so just use real SQLite
   files per session. **Decision: real files.**

3. **Blocking vs non-blocking `Buffer.toSlice`.** PJRT buffers are
   async-dispatched; `toSlice` synchronises. For the decode loop that's
   acceptable (it's the critical path anyway). For snapshots it could be a
   concurrency killer. **v1: add a `Buffer.readInto(io.Writer)` escape hatch
   in ZML.**

4. **Chat template strategy.** v0: hardcode per-model Zig functions (like ZML
   does). v1: ship a minimal Jinja2 subset evaluator that reads `chat_template`
   from `tokenizer.json`.

5. **KV cache rollback on abort** — (a) re-prefill whole turn, (b) truncate
   cursor. Spec picks (b). **Should we make this configurable per session?**

6. **Session IDs: UUIDv1 vs ULID.** UUIDv1 embeds timestamp and is familiar.
   ULID is lexicographically sortable, which is nice for log debugging. We
   need the high bits for node label regardless. **Decision: 16-byte ID,
   `[label:2][timestamp:6][rand:8]` — our own format, not strictly UUID.**

7. **Key uniqueness scope.** Rivet scopes by `(namespace, actor_name, key)`.
   Ours is `(namespace, model, key)`. If a user switches models mid-conversation
   it creates a new session — which is correct because the KV cache is
   model-specific. **Decision: (namespace, model, key).**

8. **Should sessions stream-persist state on every mutation or throttle?**
   Rivet default 10s throttle for server, 100ms for library. **Decision:
   throttle at `state_save_interval_ms` (config, default 1000ms). Forced flush
   on hibernate and on `checkpoint` RPC.**

9. **One model per node or many?** v0 one. v1 many — requires a model router
   in front of the session router and per-model VRAM pools.

10. **Streaming back-pressure.** SSE is fire-and-forget; if the client reads
    slow we buffer. We should have a bounded channel between decode loop and
    SSE writer, and pause decode if the channel is full. **Todo: design this;
    MVP can just sleep decoder with a simple mutex if buffer > N.**

## 21. Implementation plan (for when we start cutting code)

Milestone 0 — plumbing (~1 week):

- [ ] Bazel workspace; `bazel run //:dis` builds an empty binary
- [ ] `Config` load from TOML
- [ ] `std.http.Server` + `/v1/health` + `/v1/node`
- [ ] `meta.db` open + schema + migrations
- [ ] `Id128` + `Key` + tests

Milestone 1 — model + one-shot inference (~2 weeks):

- [ ] Model loader using `zml.io.load`
- [ ] Prefill + decode compile & cache
- [ ] `/v1/sessions/{id}/chat` with stateless (no KV reuse) per-request
- [ ] Tokenizer + Llama-3 chat template hardcoded

Milestone 2 — durable sessions (~2 weeks):

- [ ] Session struct, registry, session loop
- [ ] VramTracker + KV cache alloc
- [ ] KV-reuse across chat turns (persistent KV cache)
- [ ] `POST /v1/sessions`, `PUT /v1/sessions` get-or-create
- [ ] Per-session SQLite

Milestone 3 — hibernation (~1 week):

- [ ] KV snapshot to disk
- [ ] Idle timeout hibernation
- [ ] VRAM-pressure eviction (LRU)
- [ ] Wake path with cold-start

Milestone 4 — state + polish (~1 week):

- [ ] State blob with throttled flush
- [ ] Crash recovery on startup
- [ ] Metrics
- [ ] Bench harness + two sample clients (curl script, TypeScript)

Ship v0.
