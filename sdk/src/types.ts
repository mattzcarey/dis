// Public types for @dis/sdk. Everything exported here is part of the API
// surface users will see. Internal types live alongside their impls.

// ─── Actor context ───────────────────────────────────────────────────

export interface ActorCtx {
  /**
   * The 32-char lowercase-hex session id assigned by the engine. Stable
   * for the lifetime of this actor instance; clients resume a session
   * by reconnecting with `?sid=<id>`.
   */
  readonly id: string;
  /** Registration name of the class (e.g. "chat"). */
  readonly actorName: string;

  /** Per-actor SQLite. */
  readonly sql: Sql;

  /**
   * Declare defaults and receive the actor's persisted-state Proxy,
   * already hydrated from durable storage. If a prior value exists for
   * this actor, it wins over the defaults; otherwise the defaults are
   * stored so subsequent activations see them.
   *
   * ```ts
   * override async onStart() {
   *   this.state = await this.ctx.initialState({ turns: 0, createdAt: 0 });
   *   this.state.turns += 1;                 // auto-persists (throttled)
   * }
   * ```
   *
   * Call at most once per activation per `name`. A second call with a
   * different `name` returns an independent persisted object.
   */
  initialState<T extends object>(
    defaults: T,
    opts?: PersistOpts,
  ): Promise<Persisted<T>>;

  /**
   * Run `fn` exclusively — `onRequest`, `onMessage`, and scheduled task
   * dispatches are queued until it resolves. Use for atomic init,
   * migrations, and read-modify-write patterns on state.
   *
   * If `fn` throws, the actor is destroyed and recreated on next request.
   */
  blockConcurrencyWhile<T>(fn: () => Promise<T>): Promise<T>;

  /** Request hibernation after the current invocation returns. */
  hibernate(): Promise<void>;

  /** Destroy this actor permanently. All state/scheduled tasks removed. */
  destroy(): Promise<void>;

  /**
   * Fan-out a message to every connection currently attached to this
   * session. Single tunnel frame; the engine performs the N-way write
   * server-side.
   *
   * Pass `without` (array of connection ids, e.g. from `connection.id`
   * in `onMessage`) to exclude specific connections — typically the
   * sender when echoing into a multi-tab session:
   *
   * ```ts
   * onMessage(connection, msg) {
   *   this.ctx.broadcast(msg, [connection.id]);   // everyone except the sender
   * }
   * ```
   */
  broadcast(msg: string | Uint8Array, without?: readonly string[]): void;

  // ── Scheduling ────────────────────────────────────────────────────

  /**
   * Schedule `callback` to run in the future. Four modes via `when`:
   *
   *   ctx.schedule(60,            "task")     — in 60 seconds
   *   ctx.schedule(new Date(...), "task")     — at a specific time
   *   ctx.schedule("0 8 * * *",   "task")     — cron
   *   ctx.schedule({every: 30},   "task")     — repeating interval
   *
   * Pass `opts.idempotentKey` to dedup repeat calls (e.g. in `onStart`).
   */
  schedule<T = unknown>(
    when: ScheduleWhen,
    callback: string,
    payload?: T,
    opts?: ScheduleOpts,
  ): Promise<Schedule<T>>;

  /** Look up a schedule by id. Synchronous. */
  getSchedule<T = unknown>(id: string): Schedule<T> | undefined;

  /** Query schedules with optional filters. Synchronous. */
  getSchedules<T = unknown>(filter?: ScheduleFilter): Schedule<T>[];

  /** Cancel a schedule by id. Returns true if one was cancelled. */
  cancelSchedule(id: string): Promise<boolean>;
}

// ─── SQLite ──────────────────────────────────────────────────────────

export interface Sql {
  exec(sql: string, params?: readonly unknown[]): Promise<void>;
  query<T = Record<string, unknown>>(
    sql: string,
    params?: readonly unknown[],
  ): Promise<T[]>;
  transaction<T>(fn: () => Promise<T>): Promise<T>;
}

// ─── Persisted state (durable auto-flush Proxy) ──────────────────────

export interface PersistOpts {
  /** Unique key if multiple persisted objects per actor. Default: "default". */
  name?: string;
  /** Throttle window in ms for auto-flush. Default 1000. */
  throttleMs?: number;
}

/** A Proxy-wrapped T with three reserved `$` methods for control. */
export type Persisted<T> = T & {
  /** Resolves once the initial load from storage has completed. */
  readonly $ready: Promise<void>;
  /** Force a synchronous flush of pending writes to storage. */
  $flush(): Promise<void>;
  /** Snapshot of the underlying object (a plain copy, no proxy). */
  $raw(): T;
};

// ─── Scheduling ──────────────────────────────────────────────────────
// Single `schedule()` API lives on `DurableInference` — see src/durable.ts.

/**
 * When a scheduled task should fire. Four variants covering all modes:
 *
 *   42              — delayed 42 seconds
 *   new Date(ts)    — at a specific wall-clock time
 *   "0 8 * * *"     — cron (5-field minute hour dom month dow)
 *   { every: 30 }   — repeating interval (sub-minute OK)
 */
export type ScheduleWhen = number | Date | string | { every: number };

/** Tag union describing a scheduled task. */
export type Schedule<T = unknown> = {
  /** Unique id for this schedule. Use with cancelSchedule/getSchedule. */
  id: string;
  /** Method name to invoke on the actor. */
  callback: string;
  /** Payload handed to the callback when it fires. */
  payload: T;
  /** Next execution time, Unix seconds. */
  time: number;
  /** User-supplied idempotency key, if any. */
  idempotentKey?: string;
} & (
  | { type: "scheduled" }
  | { type: "delayed"; delayInSeconds: number }
  | { type: "cron"; cron: string }
  | { type: "interval"; intervalSeconds: number }
);

export interface RetryOptions {
  /** Max retries on uncaught exception. Default 6. */
  maxAttempts?: number;
  /** Base delay in seconds for exponential backoff. Default 2. */
  baseDelaySeconds?: number;
}

export interface ScheduleOpts {
  retry?: RetryOptions;
  /**
   * Optional dedup token. When set, a subsequent `schedule()` call with
   * the same `idempotentKey` (scoped to this actor) returns the existing
   * `Schedule` unchanged instead of creating a new row. When unset,
   * every call creates a new schedule.
   *
   * Common pattern: set this when calling `schedule()` in `onStart()`
   * so restarts don't accumulate duplicates.
   */
  idempotentKey?: string;
}

export interface ScheduleFilter {
  id?: string;
  type?: "scheduled" | "delayed" | "cron" | "interval";
  callback?: string;
  timeRange?: { start?: Date; end?: Date };
}

/** Extra info handed to scheduled callbacks on invocation. */
export interface ScheduleInfo {
  /** The Schedule object that fired. */
  schedule: Schedule<unknown>;
  /** Retry attempt, 0 on first run. */
  attempt: number;
  /** True if this invocation is a retry. */
  isRetry: boolean;
}

// Deprecated — legacy alarm hook type kept for migration; no longer used.
export type AlarmFireInfo = ScheduleInfo;

// ─── Inference ───────────────────────────────────────────────────────

export interface ModelInfo {
  id: string;
  loaded: boolean;
  family: string;
  quant: string;
  contextLength: number;
}

export interface LoadModelOpts {
  /** Timeout in ms. Default: 120_000. */
  timeoutMs?: number;
  /** GPU layers to offload; -1 means all. Default: -1. */
  nGpuLayers?: number;
}

export interface GenerateOpts {
  maxTokens?: number;
  temperature?: number;
  topP?: number;
  topK?: number;
  /** If true, do not advance the actor's KV cache. */
  ephemeral?: boolean;
}

export interface Token {
  text: string;
  tokenId: number;
  /** Position within this actor's KV cache for this model. */
  pos: number;
}

/** A generation stream. Bytes + async iterator of tokens. */
export interface TokenStream extends ReadableStream<Uint8Array>, AsyncIterable<Token> {
  /** Yield decoded text strings instead of bytes. */
  asText(): AsyncIterable<string>;
}

export interface AiApi {
  models(): Promise<ModelInfo[]>;
  loadModel(modelId: string, opts?: LoadModelOpts): Promise<void>;
  generate(modelId: string, prompt: string, opts?: GenerateOpts): TokenStream;
  generateRaw(modelId: string, tokens: readonly number[], opts?: GenerateOpts): TokenStream;
  tokenize(modelId: string, text: string): Promise<number[]>;
  resetContext(modelId: string): Promise<void>;
}

// ─── Connections ─────────────────────────────────────────────────────

/**
 * A handle to one WebSocket connection attached to this actor's
 * session. Passed as the first argument to `onMessage(connection, msg)`.
 *
 * The TCP socket lives in `dis-engine`; `send` / `close` round-trip
 * through the runner tunnel as single CBOR frames.
 */
export interface Connection {
  /** Engine-assigned id — 16-char lowercase hex. */
  readonly id: string;
  /** Unix-ms timestamp when the engine accepted this connection's upgrade. */
  readonly connectedAtMs: number;
  /** Best-effort remote address if available; `"unknown"` otherwise. */
  readonly remoteAddr: string;
  /** Send a frame to just this connection. */
  send(data: string | Uint8Array): void;
  /** Close this connection's WS with an optional code/reason. */
  close(code?: number, reason?: string): void;
}

// ─── Lifecycle hook info ─────────────────────────────────────────────

export type StartReason = "create" | "wake" | "restart";

export type StopReason = "idle" | "evicted" | "deploy" | "destroy" | "shutdown";

export interface StartInfo<Input = unknown> {
  reason: StartReason;
  input?: Input;
}

export interface StopInfo {
  reason: StopReason;
}

// ─── Runner startup config ───────────────────────────────────────────

import type { DurableInference } from "./durable.js";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type ActorClass = new (...args: any[]) => DurableInference<any, any>;

export interface RunnerOpts {
  /** WebSocket URL of the dis engine. e.g. "ws://localhost:7070/runner". */
  engineUrl: string;
  /**
   * Actor classes this runner hosts. Each class's registration name is
   * read from its `name` instance field; see `DurableInference.name`.
   */
  actors: readonly ActorClass[];
  /** Bearer token sent on the runner handshake. */
  authToken?: string;
  /** Override max slots this runner will accept. Default: 100. */
  maxSlots?: number;
}
