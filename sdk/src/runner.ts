// `startRunner(...)` — user entry point from their `src/index.ts`.
//
// Opens the WsTunnel, registers handlers that create/destroy ActorHosts
// and dispatch client requests. Per-session state lives inside each
// ActorHost; cross-session state (peer tracking, pending client requests)
// lives on the Runner struct below.

import { ActorHost } from "./actor/host.js";
import type { ActorClass, RunnerOpts } from "./types.js";
import {
  WsTunnel,
  type ClientResponse,
  type TunnelHandlers,
} from "./ws-tunnel.js";

export interface RunnerHandle {
  /** Gracefully close: stop hosts, flush state, close tunnel. */
  stop(): Promise<void>;
  /** Wait for the first successful handshake with the engine. */
  ready(): Promise<void>;
  /** Live session ids. */
  liveSessions(): string[];
  /** Registered actor names, in registration order. */
  actorNames(): string[];
}

export async function startRunner(opts: RunnerOpts): Promise<RunnerHandle> {
  const runner = new Runner(opts);
  runner.attach();
  return {
    stop: () => runner.stop(),
    ready: () => runner.ready(),
    liveSessions: () => runner.liveSessions(),
    actorNames: () => runner.actorNames(),
  };
}

class Runner {
  private readonly hosts = new Map<string, ActorHost>();
  private readonly registry: Map<string, ActorClass>;
  private tunnel!: WsTunnel;

  constructor(private readonly opts: RunnerOpts) {
    this.registry = buildRegistry(opts.actors);
  }

  attach(): void {
    const handlers: TunnelHandlers = {
      onActorStart: (msg) => this.actorStart(msg),
      onActorStop: (msg) => this.actorStop(msg),
      onClientRequest: (msg) => this.clientRequest(msg),
      onWsFrame: (msg) => this.wsFrame(msg),
      onScheduleFire: (msg) => this.scheduleFire(msg),
    };
    this.tunnel = new WsTunnel({
      engineUrl: this.opts.engineUrl,
      actors: [...this.registry.keys()],
      ...(this.opts.authToken !== undefined && { authToken: this.opts.authToken }),
      ...(this.opts.maxSlots !== undefined && { maxSlots: this.opts.maxSlots }),
      handlers,
    });
  }

  ready(): Promise<void> {
    return this.tunnel.ready();
  }

  liveSessions(): string[] {
    return [...this.hosts.keys()];
  }

  actorNames(): string[] {
    return [...this.registry.keys()];
  }

  async stop(): Promise<void> {
    await Promise.all([...this.hosts.values()].map((h) => h.stop("shutdown")));
    this.hosts.clear();
    await this.tunnel.close();
  }

  // ── Engine → runner dispatch ─────────────────────────────────────────

  private async actorStart(msg: {
    sid: string;
    actorName: string;
    input?: unknown;
    reason: "create" | "wake" | "restart";
  }): Promise<void> {
    const ActorCls = this.registry.get(msg.actorName);
    if (!ActorCls) {
      throw new Error(`unknown actor name: ${msg.actorName}`);
    }
    const host = new ActorHost({
      tunnel: this.tunnel,
      sessionId: msg.sid,
      actorName: msg.actorName,
      ActorCls,
    });
    this.hosts.set(msg.sid, host);
    await host.start(msg.reason, msg.input);
  }

  private async actorStop(msg: {
    sid: string;
    reason: "idle" | "evicted" | "deploy" | "destroy" | "shutdown";
  }): Promise<void> {
    const host = this.hosts.get(msg.sid);
    if (!host) return;
    this.hosts.delete(msg.sid);
    await host.stop(msg.reason);
  }

  private async clientRequest(msg: {
    sid: string;
    requestId: string;
    method: string;
    url: string;
    headers: Record<string, string>;
    body: Uint8Array | null;
  }): Promise<ClientResponse> {
    const host = this.hosts.get(msg.sid);
    if (!host) {
      return {
        status: 410,
        headers: { "content-type": "text/plain" },
        body: new TextEncoder().encode("actor gone\n"),
      };
    }
    const req = new Request(msg.url, {
      method: msg.method,
      headers: msg.headers,
      body: msg.body as unknown as BodyInit | null,
    });
    const res = await host.request(req);
    const bodyBuf = new Uint8Array(await res.arrayBuffer());
    const headers: Record<string, string> = {};
    res.headers.forEach((v, k) => {
      headers[k] = v;
    });
    return { status: res.status, headers, body: bodyBuf };
  }

  private async wsFrame(msg: {
    sid: string;
    connectionId: string;
    kind: "text" | "binary";
    data: string | Uint8Array;
  }): Promise<void> {
    const host = this.hosts.get(msg.sid);
    if (!host) return;
    await host.messageFromConnection(msg.connectionId, msg.data);
  }

  private async scheduleFire(msg: {
    sid: string;
    schedule: unknown;
    attempt: number;
    isRetry: boolean;
  }): Promise<void> {
    const host = this.hosts.get(msg.sid);
    if (!host) return;
    await host.scheduledFire(
      msg.schedule as Parameters<ActorHost["scheduledFire"]>[0],
      msg.attempt,
      msg.isRetry,
    );
  }
}

/**
 * Probe each class for its registered `name` and build a lookup map.
 * Collisions throw — two actors can't register the same name.
 */
function buildRegistry(classes: readonly ActorClass[]): Map<string, ActorClass> {
  const m = new Map<string, ActorClass>();
  for (const Cls of classes) {
    let name: string;
    try {
      const probe = new (Cls as new () => { name?: string })();
      name = typeof probe.name === "string" && probe.name ? probe.name : Cls.name;
    } catch (e) {
      throw new Error(
        `dis: could not instantiate actor class '${Cls.name}' to read its name. ` +
          `DurableInference subclasses must be constructible with no args. (${String(e)})`,
      );
    }
    if (m.has(name)) {
      throw new Error(`dis: duplicate actor name '${name}' registered`);
    }
    m.set(name, Cls);
  }
  return m;
}
