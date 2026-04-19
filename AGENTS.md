# AGENTS.md

Conventions for AI coding agents (and humans) working on this repo.

## TypeScript (`sdk/`, `examples/`)

**Use web-standard APIs only.** The SDK must run unchanged on **Node
22+**, **Bun**, **Deno**, and (where sensible) browsers.

Allowed:

- `WebSocket`, `fetch`, `Request`, `Response`, `Headers`
- `TextEncoder`, `TextDecoder`
- `ReadableStream`, `WritableStream`, `TransformStream`
- `ArrayBuffer`, `Uint8Array`, DataView
- `Map`, `Set`, `Promise`, `AbortController`
- `structuredClone`, `crypto.randomUUID`, `crypto.subtle`

Not allowed in `sdk/src/`:

- `import … from "node:*"` or bare Node builtins (`fs`, `path`, `os`,
  `child_process`, `stream`, `events`, `http`, …)
- `Buffer` (use `Uint8Array`)
- `process.*` beyond `process.argv` / `process.env` in the runner
  entry point — SDK internals stay free of it
- `require()` — repo is ESM-only

If a new capability genuinely needs a Node-only API, isolate it behind
a runtime-switched module (e.g. `*.node.ts` / `*.bun.ts`) rather than
sprinkling conditionals through shared code. Ask before adding.

## Zig (`engine/`, `infer/`, `common/`)

- Zig **0.16** — use `std.Io` / `std.Io.net` / `Io.Mutex` /
  `Io.Group.concurrent`. Don't introduce `std.Thread.*` primitives in
  new code.
- One `zig build` at the repo root builds everything. No Bazel, no
  CMake, no other meta-build systems.
- Shared Zig code lives in `common/` and is reached via module import
  (`@import("cbor")`, `@import("log")`), not by relative path.
- llama.cpp is a submodule at `third_party/llama.cpp/`; the Zig
  bindings are vendored + patched at `third_party/llama.cpp.zig/`.
  Keep the wrapper surface minimal — add bindings as callers need
  them, don't re-translate the entire header.

## Wire protocol

- Engine ↔ runner tunnel: CBOR frames. Field names are `camelCase`
  (`sessionId`, `connectionId`, `exceptIds`) — they round-trip through
  `cbor-x` directly to JS property names.
- Engine ↔ infer: length-prefixed CBOR (see `SPEC.md §7A`). Opcodes are
  stable `u8`s; add new ones at the end, never renumber.

## Testing

- `zig build test` must stay green. Every pure-Zig module with logic
  should carry its own `test` blocks.
- `npm run typecheck` (or `bun run typecheck`) in `sdk/` and each
  example must pass.
- No real-model tests in the default `test` target — they need a GGUF
  download. Drive real inference through the smoke client:
  `./zig-out/bin/dis-infer-smoke <sock> <model.gguf> "<prompt>"`.

## Commits

- One logical change per commit. Messages describe the *why*, not the
  *what*.
- Don't commit build artifacts (`zig-out/`, `.zig-cache/`, `dist/`,
  `node_modules/`) or model files.
