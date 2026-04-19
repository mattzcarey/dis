// ActorCtx impl — the grand unified "everything-actor" object. Holds
// references to state/sql implementations and wires scheduling, broadcast,
// and lifecycle ops to the tunnel.

import { Op, type Tunnel } from "../tunnel.js";
import type {
  ActorCtx,
  Persisted,
  PersistOpts,
  Schedule,
  ScheduleFilter,
  ScheduleOpts,
  ScheduleWhen,
  Sql,
} from "../types.js";
import type { ConnectionRegistry } from "./connections.js";
import { createPersisted } from "./persist.js";

export class CtxImpl implements ActorCtx {
  constructor(
    private readonly tunnel: Tunnel,
    public readonly id: string,
    public readonly actorName: string,
    public readonly sql: Sql,
    private readonly connections: ConnectionRegistry,
    // In-memory mirror of scheduled tasks for synchronous getters.
    private readonly scheduleMirror: Map<string, Schedule<unknown>>,
  ) {}

  // ── Persisted state ─────────────────────────────────────────────────

  async initialState<T extends object>(
    defaults: T,
    opts?: PersistOpts,
  ): Promise<Persisted<T>> {
    const p = createPersisted(this.tunnel, this.id, defaults, opts);
    await p.$ready;
    return p;
  }

  // ── Concurrency ─────────────────────────────────────────────────────

  blockConcurrencyWhile<T>(fn: () => Promise<T>): Promise<T> {
    // The actor host owns the lock; it installs a real impl at bind time.
    // This placeholder runs fn without serialization — OK for single-fiber
    // tests, dangerous in prod. Replaced by ActorHost.install().
    return fn();
  }

  // ── Lifecycle ───────────────────────────────────────────────────────

  hibernate(): Promise<void> {
    return this.tunnel.request<void>(Op.Hibernate, { sid: this.id });
  }

  destroy(): Promise<void> {
    return this.tunnel.request<void>(Op.ActorStop, { sid: this.id, reason: "destroy" });
  }

  // ── Scheduling ──────────────────────────────────────────────────────

  async schedule<T = unknown>(
    when: ScheduleWhen,
    callback: string,
    payload?: T,
    opts?: ScheduleOpts,
  ): Promise<Schedule<T>> {
    const schedule = await this.tunnel.request<Schedule<T>>(Op.Schedule, {
      sid: this.id,
      when: encodeWhen(when),
      callback,
      payload,
      idempotentKey: opts?.idempotentKey,
      retry: opts?.retry,
    });
    this.scheduleMirror.set(schedule.id, schedule as Schedule<unknown>);
    return schedule;
  }

  getSchedule<T = unknown>(id: string): Schedule<T> | undefined {
    return this.scheduleMirror.get(id) as Schedule<T> | undefined;
  }

  getSchedules<T = unknown>(filter?: ScheduleFilter): Schedule<T>[] {
    const all = [...this.scheduleMirror.values()] as Schedule<T>[];
    if (!filter) return all;
    return all.filter((s) => {
      if (filter.id && s.id !== filter.id) return false;
      if (filter.type && s.type !== filter.type) return false;
      if (filter.callback && s.callback !== filter.callback) return false;
      if (filter.timeRange) {
        const t = s.time * 1000;
        if (filter.timeRange.start && t < filter.timeRange.start.getTime()) return false;
        if (filter.timeRange.end && t > filter.timeRange.end.getTime()) return false;
      }
      return true;
    });
  }

  async cancelSchedule(id: string): Promise<boolean> {
    const ok = await this.tunnel.request<boolean>(Op.CancelSchedule, {
      sid: this.id,
      id,
    });
    if (ok) this.scheduleMirror.delete(id);
    return ok;
  }

  // ── Broadcast ──────────────────────────────────────────────────────

  broadcast(msg: string | Uint8Array, without?: readonly string[]): void {
    this.connections.broadcast(msg, without);
  }
}

// ─── Helpers ─────────────────────────────────────────────────────────

type WireWhen =
  | { kind: "delayed"; seconds: number }
  | { kind: "scheduled"; atMs: number }
  | { kind: "cron"; expr: string }
  | { kind: "interval"; seconds: number };

function encodeWhen(when: ScheduleWhen): WireWhen {
  if (typeof when === "number") return { kind: "delayed", seconds: when };
  if (when instanceof Date) return { kind: "scheduled", atMs: when.getTime() };
  if (typeof when === "string") return { kind: "cron", expr: when };
  return { kind: "interval", seconds: when.every };
}
