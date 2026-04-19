// The base class users extend. Two capability namespaces are injected by
// ActorHost at activation time:
//
//   this.ctx    — identity, sql, concurrency, scheduling, broadcast,
//                 lifecycle, initialState()
//   this.ai     — inference
//
// `this.state` is a typed slot the user populates by calling
// `await this.ctx.initialState({...defaults})` inside onStart.

import type {
  ActorCtx,
  AiApi,
  Connection,
  Persisted,
  StartInfo,
  StopInfo,
} from "./types.js";

export abstract class DurableInference<
  Input = unknown,
  State extends object = Record<string, never>,
> {
  /**
   * Actor registration name. Clients route to this actor via
   * `ws://engine/v1/ws/<name>`. Defaults to `snake_case(constructor.name)`,
   * e.g. `ChatActor` → `"chat_actor"`. Override to customize:
   *
   * ```ts
   * class ChatActor extends DurableInference {
   *   override name = "chat";
   * }
   * ```
   */
  readonly name: string = defaultActorName(this.constructor.name);

  /** Actor runtime: identity, sql, concurrency, scheduling, broadcast. */
  readonly ctx!: ActorCtx;

  /** Inference primitives. */
  readonly ai!: AiApi;

  /**
   * Durable auto-persisted state. Typed by the second generic parameter;
   * populated via `await this.ctx.initialState({...})` inside onStart.
   */
  state!: Persisted<State>;

  // ── Lifecycle hooks (all optional) ──────────────────────────────────

  onStart?(info: StartInfo<Input>): void | Promise<void>;
  onStop?(info: StopInfo): void | Promise<void>;
  onRequest?(req: Request): Response | Promise<Response>;
  /**
   * Called once per WS frame from any attached connection.
   * `connection.send(...)` replies to just that connection;
   * `this.ctx.broadcast(...)` fans out to every connection attached
   * to this session.
   */
  onMessage?(connection: Connection, msg: string | Uint8Array): void | Promise<void>;

  // Scheduled tasks dispatch to named methods on the subclass. Use
  // `this.ctx.schedule(...)`; no generic onAlarm hook.

  /**
   * Runtime-internal: called by `ActorHost` to inject capability objects.
   * @internal
   */
  __bindHost(b: HostBindings): void {
    mutable(this).ctx = b.ctx;
    mutable(this).ai = b.ai;
  }
}

// ─── Internal wiring types ─────────────────────────────────────────────

export interface HostBindings {
  ctx: ActorCtx;
  ai: AiApi;
}

function mutable<T>(x: T): Mutable<T> {
  return x as Mutable<T>;
}

type Mutable<T> = { -readonly [K in keyof T]: T[K] };

/**
 * Convert a JS class name to snake_case for registration.
 *
 *   "ChatActor"     → "chat_actor"
 *   "RealtimeV2"    → "realtime_v2"
 *   "HTTPHandler"   → "http_handler"
 *   "Chat"          → "chat"
 */
export function defaultActorName(className: string): string {
  if (!className) return "actor";
  // Insert "_" before a run of uppercase that ends before a lowercase,
  // then before any lowercase-to-uppercase transition.
  const step1 = className.replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2");
  const step2 = step1.replace(/([a-z\d])([A-Z])/g, "$1_$2");
  return step2.toLowerCase();
}
