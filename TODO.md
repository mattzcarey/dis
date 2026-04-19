# TODO

Roadmap for `dis`. Items are roughly ordered by dependency. Each bullet
is a single coherent chunk of work — anything marked `(blocked)` is
gated on something above it.

## Next up — close the loop runner → engine → infer → model

Right now `dis-infer` runs real inference but nothing connects to it
from the engine. A session speaks to a runner over the client WS; the
runner calls `this.ai.generate(...)` but the engine-side handler still
streams from `gen_stub.streamStub` instead of dispatching to the infer
socket.

- **Engine-side infer client** (`engine/src/infer/client.zig`).
  - Unix-socket dialer + the framing codec from SPEC §7A
    (u32 BE len + u8 kind + u32 BE tag + body).
  - Reader task dispatching Ack/Result/TokenChunk/Done/Error by tag.
  - `Pending` waiters reused from `tunnel/pending.zig` for one-shot
    RPCs (LoadModel, AllocSeq, Tokenize, etc.).
  - Per-generate stream state (tag → channel) for prefill/decode_token
    streaming, with `abort_generate` wired to cancellation.
- **Swap generation source.** Replace `gen_stub.streamStub` inside
  `runner_conn.handleGenerate` with `infer_client.generate(...)` so the
  runner sees real TokenChunk frames.
- **Engine config**: add `infer_socket_path` to `config.zig`; dial on
  boot, reconnect with backoff if the infer process restarts.
- **End-to-end test**: launch `dis-infer` + `dis-engine` + an SDK
  runner, have a WS client POST `{type:"response.create",...}`, assert
  streamed `response.text.delta` frames contain real text.

## Per-session KV cache

The LlamaHost currently shares one context across all callers. For
multi-session durability we need to:

- Map `sid` → `llama_seq_id` inside `LlamaHost`, tracked in a
  `std.AutoHashMap`.
- On `alloc_seq(sessionId)`: pick the next free seq id (or reuse if
  known), call nothing yet (llama.cpp allocates lazily on decode).
- On `free_seq(seqId)`: `llama_memory_seq_rm(mem, seq_id, -1, -1)` to
  evict that sequence from the KV cache.
- `snapshot_seq` / `restore_seq`: wrap
  `llama_state_seq_save_file` / `llama_state_seq_load_file` — these
  already exist in the vendored wrapper under `State.*`.
- Make `LlamaHost.generate` take a `seq_id` and pass it through to the
  batch so each session's KV lives independently.

## Session idle eviction + restart

- **Engine**: `TunnelHub` currently never calls `ActorStop`. Add a
  timer that evicts sessions idle for longer than `cfg.idle_ms`,
  sending `ActorStop{reason:"idle"}` to the runner.
- **Runner** (`@dis/sdk`): finalize `onStop({reason})` path, drain
  peers cleanly, drop the `ActorHost` entry. Already mostly wired in
  `actor/host.ts:stop` — needs engine-side trigger.
- **Restart on next connect**: when a client reconnects with `?sid=`
  and the session was evicted but still has durable state on disk,
  transparently `ActorStart{reason:"wake"}` and restore KV via
  `restore_seq` before handing off to the actor.

## Durable state (`ctx.initialState`)

The SDK exposes the Proxy (`sdk/src/actor/persist.ts`) but the
engine-side `StateGet` / `StateSet` handlers are no-ops.

- **Engine**: implement `StateGet`, `StateSet`, `StateDelete`,
  `StateList`, `StateClear` against a SQLite-backed `MetaDb` (schema
  already sketched at `engine/src/storage/schema.sql`, but `MetaDb` is
  still an in-memory stub).
- **Zig SQLite**: pick one of
  - vendored `zsqlite` or similar wrapper, or
  - direct `@cImport("sqlite3.h")` with a minimal wrapper similar to
    the llama one.
  - Evaluate both; sqlite has no C++ dependency so source-compile via
    `addCSourceFiles` is feasible even without a system lib.
- **Transactions**: StateTxnBegin/Commit/Rollback opcodes; serialized
  per-session so `blockConcurrencyWhile` semantics are preserved.
- **Throttling**: the SDK Proxy throttles auto-flush via
  `opts.throttleMs` (default 1000). Make sure engine-side writes are
  batched so a chatty actor doesn't pin the SQLite write thread.

## Scheduling

`ctx.schedule(...)` + `ctx.cancelSchedule(...)` are exposed on the SDK
but the engine side is all stubs.

- **Wire schedule storage**: `schedules` table in `MetaDb` (id, sid,
  callback, payload (CBOR bytes), fire_at_ms, cron_expr, interval_s,
  idempotent_key, attempt, next_retry_at_ms). Per-row lock for
  idempotent-key dedup.
- **Scheduler loop**: one task per engine process, polls with a LEAST
  `fire_at_ms` query on a short tick. On fire, send `ScheduleFire` to
  the owning runner; on success mark done or compute next interval.
- **Retries**: exponential backoff driven by `attempt` + `retry.baseDelaySeconds`.
- **Cron parser**: 5-field minute-hour-dom-month-dow, pick a small
  pure-Zig parser.

## Auth (bearer tokens)

Right now `/v1/ws/:actor` has no auth. User identity is supposed to
come from `Authorization: Bearer <token>`.

- Parse + validate bearer on both `/runner` (runner ↔ engine) and
  `/v1/ws/:actor` (client ↔ engine) handshakes.
- Simple file-backed token store (`cfg.auth_tokens_file`) for first
  pass: one token per line, maps to a user id.
- Thread the authenticated user id into the `Session` struct so
  handlers can see *who* is asking.

## Runner registration / multi-runner

`TunnelHub.newSession` picks the first live runner handling the
actor name — works for one runner but doesn't load-balance.

- **Runner capacity reporting**: `RunnerReady` already carries
  `maxSlots`; track `live_sessions` per runner and refuse new ones if
  at cap.
- **Routing**: round-robin or least-loaded between runners that
  declared the same actor. Prefer sticky-by-sid on resume so
  long-running sessions stay pinned to their runner.
- **Runner failure**: on runner disconnect, mark all its sessions as
  `dead`, reject reconnect until operator intervention or auto-migrate
  (rebuild KV from persisted state on another runner).

## Protocol stability + docs

- **Freeze SPEC.md §7A** (engine ↔ infer wire) — publish the frame
  layout + opcode numbers as stable, guard with a `protocol_version`
  field in the Hello frame.
- **Engine ↔ runner wire**: same treatment once `ctx.schedule` and
  `ctx.initialState` land — these are the last holes in the opcode
  table.
- Minimal user-facing docs: the `DurableInference` class contract,
  runner startup, engine config, and how to point infer at a GGUF.

## Build / infra

- **Source-compile llama.cpp** from the submodule (today we link a
  prebuilt libllama from a system install prefix). This removes the
  system dependency and pins ABI to the submodule's exact commit.
  Requires walking `ggml/src/`, `src/`, and the platform backends
  (Metal on macOS needs `.metal` shader compilation), and porting
  relevant parts of the upstream CMake config to `build.zig`.
- **CI**: GitHub Actions running `zig build test` on macOS (Metal-linked
  llama, the main dev platform) and Linux (CPU-only llama) against a
  pinned Zig + a tiny public GGUF.
- **Release binaries**: `zig build -Dtarget=<triple> -Doptimize=ReleaseFast`
  for the engine and infer, attached to GitHub releases.

## Observability

- Structured logs with a `session_id` field on every line for grep-ability.
- Per-session metrics: tokens_generated, tokens_prompt, decode_ms,
  model_id. Dump on `/v1/stats` JSON endpoint.
- Optional: OpenTelemetry traces through the runner → engine → infer
  hop so a single `response.create` can be followed end to end.

## Self-hosted mini-cloud + rapid code push

Model: the **platform is long-lived, user code is ephemeral**. Install
once, iterate rapidly. Like `wrangler deploy` but for a box you own
(Raspberry Pi, home server, single VPS).

```
~/dis/
├── bin/{dis-engine, dis-infer}   ← platform: long-lived
├── models/*.gguf                  ← loaded once, resident forever
├── code/
│   ├── current -> v42/            ← symlink; atomic swap
│   ├── v41/…                      ← previous bundle (instant rollback)
│   └── v42/
│       ├── bundle.js              ← one file, ESM, dis-runner loads this
│       └── manifest.json          ← actor classes + version + hash
├── data/                          ← engine meta.db + per-seq KV snapshots
├── engine.sock                    ← engine control-plane socket
└── config.json
```

### The split

| Lives forever | Pushed per-change |
|---|---|
| `dis-engine` (Zig binary) | Compiled TS bundle (`bundle.js`) |
| `dis-infer` (Zig binary) | Manifest: class list + version |
| Loaded model weights | — |
| Open WebSockets + session KV | — |

Because the engine holds `sid → session` durably, a user-code push
does **not** drop client WebSockets. On code swap the runner reconnects
to the engine, the engine re-asserts ownership, and the next inbound
message hits new code. Mid-stream generation completes on old code
(don't interrupt an in-flight `llama_decode`); the next turn uses the
new code.

### `dis push` — the one-command deploy

```bash
$ dis push                      # default: push cwd as the new version
bundled 3 actors (11.4 KB)
uploading to pi@home:~/dis/code/v43/ …
runner v43 ready in 140ms
✓ live: chat, echo, voice

$ dis push --target prod        # named remote in ~/.dis/config
$ dis rollback                  # flip symlink back to vN-1
$ dis log                       # tail engine + runner logs via control socket
```

What the CLI does:

1. **Bundle.** `bun build ./src/*.ts --target=bun --outfile=bundle.js`
   (or esbuild equivalent). Single-file ESM output. No `node_modules`
   on the target.
2. **Probe.** Static-analyse exports for `DurableInference` subclasses,
   build `manifest.json` with class names + a content hash.
3. **Upload.** Ship bundle + manifest over ssh (dev) or an engine
   control endpoint (later). Write to `~/dis/code/vN/` atomically.
4. **Swap.** Update the `current` symlink. Notify the engine over its
   control socket — engine tells the runner to reload.
5. **Reload.** Runner imports `current/bundle.js`, re-registers actor
   classes with the engine, sends `RunnerReady` with the new class
   list. Sessions whose actor is still registered keep going; sessions
   whose actor was dropped get `ActorStop{reason:"replaced"}`.

Push-to-live target: **under 1 second** on LAN. The bundle is tiny
(KB, not MB — no model weights travel with it), the engine is already
warm, and the model is still resident in infer.

### Rollout knobs worth adding

- `dis push --dry-run` — bundle + typecheck, don't deploy.
- `dis push --canary=10%` — new code handles 10% of new sessions,
  existing sessions keep old code; flip to 100% on `dis promote`.
  Simpler than CF's percent-of-requests model because we route at
  session-creation time, not per-request.
- `dis push --version=<name>` — pin a specific version label for
  `dis rollback` targeting.

### What's missing right now

- `dis` CLI binary. Pure TS; one file; ships in `sdk/` as a bin entry.
- Engine control socket (`engine.sock`) speaking a tiny JSON-line
  protocol: `reload`, `status`, `rollback`, `log tail`.
- Runner hot-reload path: today `sdk/src/runner.ts` imports user code
  once at startup. Needs a `reload(newModulePath)` that instantiates
  fresh `ActorHost`s for changed classes, migrates or stops the rest.
- Cross-compile targets baked into CI: `aarch64-linux-musl` (Pi 5,
  most ARM SBCs), `x86_64-linux-musl` (static, runs anywhere),
  `x86_64-linux-gnu` (glibc hosts).
- systemd unit templates: `dis-engine.service` (Requires=dis-infer),
  `dis-runner.service` (Requires=dis-engine), both `Restart=on-failure`.

### Stretch: the full mini-cloud

- **Multi-tenant on one box**: engine routes `/v1/ws/:actor` by the
  bearer token's tenant id, each tenant has its own `code/` prefix +
  runner process. One Pi, N apps.
- **Fleet push**: `dis push --fleet home` pushes to every node in
  `~/.dis/fleet/home.toml` in parallel with a health-check gate
  between them.
- **Image-based reconciliation** (ergonomic for immutable setups):
  instead of `scp` + symlink, the runner polls a manifest URL and
  pulls the referenced bundle, systemd-style. Push becomes "update
  the manifest, wait for convergence".

## Stretch

- **Multi-model**: infer currently holds one `LlamaHost` (one model).
  To host multiple concurrently, either multi-process (one infer per
  model) or multi-context inside one process. Former is simpler;
  engine gains a model→socket-path routing table.
- **Vision**: InternVL3-1B ships with an `mmproj` companion; adding
  vision support means pulling mmproj into the infer host and wiring
  a new opcode (e.g. `encode_image`) plus an image field on
  `response.create`.
- **Speculative decode** via a draft model — llama.cpp exposes the
  primitive but we'd need a second context per session.
- **Cross-engine migration**: if a runner dies, reconstruct the KV on
  another runner from the last `snapshot_seq` + the tail of input
  tokens since that snapshot.
