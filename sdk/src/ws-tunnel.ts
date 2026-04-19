// Real WebSocket-backed implementation of the Tunnel interface.
//
// Responsibilities:
//   1. Open a WS to the engine, send RunnerReady, wait for Hello.
//   2. Multiplex outbound RPCs (request / requestStream) using correlation tags.
//   3. Dispatch inbound engine→runner frames via TunnelHandlers.
//   4. Reconnect with exponential backoff on disconnect.
//
// Uses the global WebSocket (available in Node ≥22, Bun, Deno, browsers).

import { decode as decodeFrame, encode as encodeFrame } from "./frames.js";
import { Op, type Opcode, type Tunnel } from "./tunnel.js";
import { TunnelClosed } from "./errors.js";

// ─── Handler surface: engine → runner RPCs ─────────────────────────────
//
// The runner implements these and passes them to the WsTunnel at
// construction. The tunnel dispatches engine-initiated frames to them.

// Wire shapes: every engine→runner RPC carries `sid` (session id, hex)
// as the primary correlation. Handlers receive the decoded CBOR body
// verbatim.

export interface TunnelHandlers {
  /** Engine is booting up an actor on this runner. */
  onActorStart(msg: {
    sid: string;
    actorName: string;
    namespace: string;
    key: readonly string[];
    input?: unknown;
    reason: "create" | "wake" | "restart";
  }): Promise<void>;

  /** Engine is shutting down an actor on this runner. */
  onActorStop(msg: {
    sid: string;
    reason: "idle" | "evicted" | "deploy" | "destroy" | "shutdown";
  }): Promise<void>;

  /** A client HTTP request targeted at an actor on this runner. */
  onClientRequest(msg: {
    sid: string;
    requestId: string;
    method: string;
    url: string;
    headers: Record<string, string>;
    body: Uint8Array | null;
  }): Promise<ClientResponse>;

  /** A single WebSocket frame targeted at an actor on this runner. */
  onWsFrame(msg: {
    sid: string;
    connectionId: string;
    kind: "text" | "binary";
    data: string | Uint8Array;
  }): Promise<void>;

  /** A scheduled task is firing on an actor on this runner. */
  onScheduleFire(msg: {
    sid: string;
    schedule: unknown; // opaque Schedule<T>; host re-casts internally
    attempt: number;
    isRetry: boolean;
  }): Promise<void>;
}

export interface ClientResponse {
  status: number;
  headers: Record<string, string>;
  body: Uint8Array;
}

// ─── Tunnel options ────────────────────────────────────────────────────

export interface WsTunnelOpts {
  engineUrl: string;
  actors: readonly string[];
  authToken?: string;

  handlers: TunnelHandlers;

  /** Max slots this runner will accept. Engine may clamp. */
  maxSlots?: number;

  /** Initial reconnect delay in ms. Doubles up to `maxBackoffMs`. */
  baseBackoffMs?: number;
  maxBackoffMs?: number;
}

interface PendingRpc {
  resolve(value: unknown): void;
  reject(err: unknown): void;
}

// ─── Implementation ────────────────────────────────────────────────────

export class WsTunnel implements Tunnel {
  private ws: WebSocket | null = null;
  private readonly pending = new Map<number, PendingRpc>();
  private readonly streams = new Map<number, ReadableStreamDefaultController<unknown>>();
  private nextTag = 1;
  private closed = false;
  private backoff: number;
  private readyPromise: Promise<void>;
  private readyResolve!: () => void;
  private readyReject!: (e: unknown) => void;

  constructor(private readonly opts: WsTunnelOpts) {
    this.backoff = opts.baseBackoffMs ?? 500;
    this.readyPromise = new Promise<void>((res, rej) => {
      this.readyResolve = res;
      this.readyReject = rej;
    });
    void this.connectLoop();
  }

  /** Resolves when the first successful handshake completes. */
  ready(): Promise<void> {
    return this.readyPromise;
  }

  // ── Tunnel interface ────────────────────────────────────────────────

  request<R = unknown>(kind: Opcode, payload: unknown): Promise<R> {
    const tag = this.allocTag();
    return new Promise<R>((resolve, reject) => {
      this.pending.set(tag, { resolve: resolve as (v: unknown) => void, reject });
      try {
        this.send(kind, tag, payload);
      } catch (e) {
        this.pending.delete(tag);
        reject(e);
      }
    });
  }

  requestStream<T = unknown>(kind: Opcode, payload: unknown): ReadableStream<T> {
    const tag = this.allocTag();
    // eslint-disable-next-line @typescript-eslint/no-this-alias
    const self = this;
    return new ReadableStream<T>({
      start(controller) {
        self.streams.set(tag, controller as ReadableStreamDefaultController<unknown>);
        try {
          self.send(kind, tag, payload);
        } catch (e) {
          controller.error(e);
          self.streams.delete(tag);
        }
      },
      cancel(reason) {
        self.streams.delete(tag);
        try {
          self.send(Op.ClientRequestAbort, tag, { reason: String(reason ?? "cancelled") });
        } catch {
          // best-effort
        }
      },
    });
  }

  abort(tag: number): void {
    try {
      this.send(Op.ClientRequestAbort, tag, {});
    } catch {
      // ignored
    }
  }

  async close(): Promise<void> {
    this.closed = true;
    this.failAll(new TunnelClosed("tunnel explicitly closed"));
    try {
      this.ws?.close(1000, "runner shutting down");
    } catch {
      // ignored
    }
  }

  /** Fire-and-forget send; no reply expected. */
  sendOneWay(kind: Opcode, payload: unknown): void {
    try {
      this.send(kind, this.allocTag(), payload);
    } catch (e) {
      console.warn("[dis] sendOneWay failed:", e);
    }
  }

  /** Send an unsolicited response (e.g. ClientResponse back to engine). */
  sendResponse(kind: Opcode, tag: number, payload: unknown): void {
    this.send(kind, tag, payload);
  }

  // ── Connection lifecycle ────────────────────────────────────────────

  private async connectLoop(): Promise<void> {
    while (!this.closed) {
      try {
        await this.connectOnce();
        // reset backoff on successful handshake
        this.backoff = this.opts.baseBackoffMs ?? 500;
      } catch (e) {
        if (this.closed) return;
        console.warn("[dis] tunnel connect failed:", e);
      }
      if (this.closed) return;
      await sleep(this.backoff);
      this.backoff = Math.min(this.backoff * 2, this.opts.maxBackoffMs ?? 30_000);
    }
  }

  /**
   * Open a WS, handshake, then sit on it until it closes. The returned
   * Promise resolves when the connection closes cleanly and rejects if
   * the handshake fails or the connection aborts abnormally. The
   * `readyPromise` is separately resolved the first time we see a Hello
   * from the engine; callers await `tunnel.ready()`, not this method.
   */
  private connectOnce(): Promise<void> {
    return new Promise<void>((resolveConn, rejectConn) => {
      const url = buildUrl(this.opts.engineUrl, this.opts.authToken);
      const ws = new WebSocket(url);
      ws.binaryType = "arraybuffer";
      this.ws = ws;

      let opened = false;
      let helloSeen = false;

      ws.addEventListener("open", () => {
        opened = true;
        this.send(Op.RunnerReady, this.allocTag(), {
          actors: this.opts.actors,
          maxSlots: this.opts.maxSlots ?? 100,
          authToken: this.opts.authToken,
        });
      });

      ws.addEventListener("message", (ev: MessageEvent) => {
        const data = ev.data;
        if (!(data instanceof ArrayBuffer)) {
          console.warn("[dis] ignored non-binary frame");
          return;
        }
        try {
          const frame = decodeFrame(new Uint8Array(data));
          if (!helloSeen && frame.kind === Op.Hello) {
            helloSeen = true;
            this.readyResolve();
            return;
          }
          this.dispatch(frame.kind, frame.tag, frame.body);
        } catch (e) {
          console.warn("[dis] frame decode failed:", e);
        }
      });

      ws.addEventListener("close", (ev: CloseEvent) => {
        this.ws = null;
        this.failAll(new TunnelClosed(`ws closed: ${ev.code} ${ev.reason}`));
        if (!opened) {
          rejectConn(new Error(`ws closed before open: ${ev.code}`));
        } else {
          // Clean or unclean close after successful open — either way,
          // resolve so the caller reconnects (unless explicitly closed).
          resolveConn();
        }
      });

      // Note: we intentionally don't reject on "error" — Bun/Node emit
      // transient error events during handshake that are harmless and
      // will be followed by an open or close anyway. The close event is
      // the authoritative signal for failure.
      ws.addEventListener("error", () => {
        /* handled via close */
      });
    });
  }

  // ── Frame send/recv ─────────────────────────────────────────────────

  private send(kind: Opcode, tag: number, payload: unknown): void {
    const ws = this.ws;
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      throw new TunnelClosed(`cannot send: ws not open (state=${ws?.readyState})`);
    }
    ws.send(encodeFrame(kind, tag, payload));
  }

  private dispatch(kind: Opcode, tag: number, body: unknown): void {
    switch (kind) {
      case Op.TokenChunk:
        return this.handleStreamChunk(tag, body);

      case Op.Error:
        return this.handleError(tag, body);

      case Op.Ack:
      case Op.Result:
        return this.handleResult(tag, body);

      // ── engine → runner RPCs ─────────────────────────────────────
      case Op.ActorStart:
        void this.handleEngineCall(tag, () =>
          this.opts.handlers.onActorStart(body as never).then(() => ({})),
        );
        return;
      case Op.ActorStop:
        void this.handleEngineCall(tag, () =>
          this.opts.handlers.onActorStop(body as never).then(() => ({})),
        );
        return;
      case Op.ClientRequest:
        void this.handleEngineCall(tag, () =>
          this.opts.handlers.onClientRequest(body as never),
        );
        return;
      case Op.WsFrame:
        // One-way: engine doesn't wait for a reply. Fire and forget.
        void this.opts.handlers.onWsFrame(body as never).catch((e) => {
          console.warn("[dis] onWsFrame error:", e);
        });
        return;
      case Op.ScheduleFire:
        void this.handleEngineCall(tag, () =>
          this.opts.handlers.onScheduleFire(body as never).then(() => ({})),
        );
        return;

      default:
        // Unknown kind: if a pending rpc exists for this tag, resolve it.
        return this.handleResult(tag, body);
    }
  }

  private handleStreamChunk(tag: number, body: unknown): void {
    const ctrl = this.streams.get(tag);
    if (!ctrl) return;
    const { tokens, done } = (body ?? {}) as {
      tokens?: unknown[];
      done?: boolean;
    };
    if (Array.isArray(tokens)) {
      for (const t of tokens) ctrl.enqueue(t);
    }
    if (done) {
      ctrl.close();
      this.streams.delete(tag);
    }
  }

  private handleError(tag: number, body: unknown): void {
    const { message, code } = (body ?? {}) as { message?: string; code?: string };
    const err = new Error(message ?? "engine error");
    Object.assign(err, { code: code ?? "ENGINE_ERROR" });

    const p = this.pending.get(tag);
    if (p) {
      p.reject(err);
      this.pending.delete(tag);
      return;
    }
    const s = this.streams.get(tag);
    if (s) {
      s.error(err);
      this.streams.delete(tag);
    }
  }

  private handleResult(tag: number, body: unknown): void {
    const p = this.pending.get(tag);
    if (!p) return;
    p.resolve(body);
    this.pending.delete(tag);
  }

  private async handleEngineCall(
    tag: number,
    fn: () => Promise<unknown>,
  ): Promise<void> {
    try {
      const result = await fn();
      this.send(Op.Result, tag, result);
    } catch (e) {
      const err = e as Error;
      this.send(Op.Error, tag, {
        code: (err as { code?: string }).code ?? "HANDLER_FAILED",
        message: err.message ?? String(err),
      });
    }
  }

  private failAll(err: unknown): void {
    for (const p of this.pending.values()) p.reject(err);
    this.pending.clear();
    for (const s of this.streams.values()) {
      try { s.error(err); } catch { /* already errored */ }
    }
    this.streams.clear();
  }

  private allocTag(): number {
    const t = this.nextTag;
    this.nextTag = (this.nextTag + 1) >>> 0 || 1; // wrap past 0
    return t;
  }
}

// ─── Helpers ─────────────────────────────────────────────────────────

function buildUrl(base: string, token?: string): string {
  if (!token) return base;
  const sep = base.includes("?") ? "&" : "?";
  return `${base}${sep}token=${encodeURIComponent(token)}`;
}

function sleep(ms: number): Promise<void> {
  return new Promise((res) => setTimeout(res, ms));
}
