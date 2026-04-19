// ActorHost — one instance per live actor inside the runner process.
// Responsibilities:
//   1. Instantiate the user's class.
//   2. Wire up ctx / ai so every capability points at this session.
//   3. Serialize incoming events (request, message, scheduled callback)
//      using a FIFO mutex so lifecycle invariants hold.
//   4. Dispatch scheduled callbacks to named methods on the instance.

import type { ActorClass, DurableInference } from "../index.js";
import type {
  AlarmFireInfo,
  ScheduleInfo,
  StartReason,
  StopReason,
} from "../types.js";
import type { Tunnel } from "../tunnel.js";
import { AiImpl } from "./ai.js";
import { CtxImpl } from "./ctx.js";
import { ConnectionRegistry } from "./connections.js";
import { SqlImpl } from "./sql.js";
import type { HostBindings } from "../durable.js";
import type { Schedule } from "../types.js";

export interface HostInit {
  tunnel: Tunnel;
  sessionId: string;
  actorName: string;
  ActorCls: ActorClass;
}

export class ActorHost {
  readonly connections: ConnectionRegistry;

  private readonly actor: DurableInference;
  private readonly scheduleMirror = new Map<string, Schedule<unknown>>();

  // FIFO invocation queue. blockConcurrencyWhile reuses this.
  private chain: Promise<unknown> = Promise.resolve();

  constructor(private readonly init: HostInit) {
    this.connections = new ConnectionRegistry(init.tunnel, init.sessionId);
    const sql = new SqlImpl(init.tunnel, init.sessionId);
    const ai = new AiImpl(init.tunnel, init.sessionId);
    const ctx = new CtxImpl(
      init.tunnel,
      init.sessionId,
      init.actorName,
      sql,
      this.connections,
      this.scheduleMirror,
    );

    // Override CtxImpl.blockConcurrencyWhile to use *our* chain.
    ctx.blockConcurrencyWhile = <T>(fn: () => Promise<T>): Promise<T> => this.serialize(fn);

    const bindings: HostBindings = { ctx, ai };

    // eslint-disable-next-line new-cap
    this.actor = new init.ActorCls();
    this.actor.__bindHost(bindings);
  }

  // ── Serialization ──────────────────────────────────────────────────

  /** Chain a unit of work — queued behind all prior invocations. */
  private serialize<T>(fn: () => Promise<T>): Promise<T> {
    const next = this.chain.then(fn, fn);
    // Keep the chain alive even on rejection; consumers await their own results.
    this.chain = next.catch(() => undefined);
    return next;
  }

  // ── Event entrypoints (called by the Runner tunnel dispatcher) ─────

  async start(reason: StartReason, input?: unknown): Promise<void> {
    if (this.actor.onStart) {
      await this.serialize(async () => {
        await this.actor.onStart!({ reason, input });
      });
    }
  }

  async stop(reason: StopReason): Promise<void> {
    if (this.actor.onStop) {
      await this.serialize(async () => {
        await this.actor.onStop!({ reason });
      });
    }
    // Close any remaining connection WSes after onStop gets its last broadcast in.
    for (const conn of this.connections) {
      try { conn.close(1001, "going away"); } catch { /* ignore */ }
    }
  }

  request(req: Request): Promise<Response> {
    const handler = this.actor.onRequest;
    if (!handler) {
      return Promise.resolve(new Response("no onRequest handler", { status: 501 }));
    }
    return this.serialize(() => handler.call(this.actor, req) as Promise<Response>);
  }

  /** Dispatch an inbound client WS frame, routing to the connection handle. */
  messageFromConnection(connectionId: string, data: string | Uint8Array): Promise<void> {
    const handler = this.actor.onMessage;
    if (!handler) return Promise.resolve();
    const conn = this.connections.ensure(connectionId);
    return this.serialize(async () => {
      await handler.call(this.actor, conn, data);
    });
  }

  /** Invoked by the tunnel when a scheduled task fires. */
  scheduledFire(
    schedule: Schedule<unknown>,
    attempt: number,
    isRetry: boolean,
  ): Promise<void> {
    const method = (this.actor as unknown as Record<string, unknown>)[schedule.callback];
    if (typeof method !== "function") {
      // The method doesn't exist. Let the engine retry — eventually the
      // engine gives up per the retry policy. We throw so the engine sees
      // a failure.
      return Promise.reject(
        new Error(`scheduled callback '${schedule.callback}' is not a method`),
      );
    }
    const info: ScheduleInfo = { schedule, attempt, isRetry };
    return this.serialize(async () => {
      await (method as (p: unknown, i: ScheduleInfo) => unknown | Promise<unknown>)
        .call(this.actor, schedule.payload, info);
    });
  }

  // ── Connection mgmt hooks (called by tunnel on lifecycle events) ────

  removeConnectionById(connectionId: string): void {
    this.connections.remove(connectionId);
  }
}

// Kept here for clarity; re-exported from index.ts if callers need it.
export type { AlarmFireInfo };
