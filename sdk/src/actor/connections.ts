// Tracks WebSocket connections attached to one actor's session.
//
// The real TCP sockets live in `dis-engine`, not here. Each inbound
// `WsFrame(sid, connectionId, data)` tunnel message represents one
// frame from a client; we look up (or lazily create) a
// RemoteConnection for that connectionId and pass the pair
// `(connection, data)` to the actor's `onMessage`.
//
// `broadcast(msg, without?)` sends a single ConnectionMessage with
// `connectionId: "*"` and an optional `exceptIds` array so the engine
// fans out server-side (one tunnel frame, N WS writes) instead of
// sending N individual frames over the runner tunnel.

import { Op, type Tunnel } from "../tunnel.js";
import type { Connection } from "../types.js";

/**
 * Concrete `Connection`. `send` / `close` round-trip through the
 * engine tunnel as one CBOR frame each.
 */
export class RemoteConnection implements Connection {
  readonly connectedAtMs: number;
  readonly remoteAddr: string = "unknown";

  constructor(
    readonly id: string,
    private readonly tunnel: Tunnel,
    private readonly sessionId: string,
  ) {
    this.connectedAtMs = Date.now();
  }

  send(data: string | Uint8Array): void {
    const isText = typeof data === "string";
    this.tunnel.sendOneWay(Op.ConnectionMessage, {
      sid: this.sessionId,
      connectionId: this.id,
      kind: isText ? "text" : "binary",
      data,
    });
  }

  close(code = 1000, reason = ""): void {
    this.tunnel.sendOneWay(Op.ConnectionClose, {
      sid: this.sessionId,
      connectionId: this.id,
      code,
      reason,
    });
  }
}

/**
 * Per-session connection registry. Keyed by engine-assigned id.
 */
export class ConnectionRegistry {
  private readonly conns = new Map<string, RemoteConnection>();

  constructor(
    private readonly tunnel: Tunnel,
    private readonly sessionId: string,
  ) {}

  /** Get (or create) a connection handle by its engine-assigned id. */
  ensure(id: string): RemoteConnection {
    let c = this.conns.get(id);
    if (!c) {
      c = new RemoteConnection(id, this.tunnel, this.sessionId);
      this.conns.set(id, c);
    }
    return c;
  }

  remove(id: string): void {
    this.conns.delete(id);
  }

  size(): number {
    return this.conns.size;
  }

  /** Iteration support; used by ActorHost.stop() to close all connections. */
  *[Symbol.iterator](): IterableIterator<RemoteConnection> {
    yield* this.conns.values();
  }

  /**
   * Fan out to every connection attached to this session. Emits a
   * single ConnectionMessage(`connectionId: "*"`) tunnel frame; the
   * engine handles the N-way server-side write. When `without` is
   * non-empty, the engine skips any connection whose id appears in it.
   */
  broadcast(msg: string | Uint8Array, without?: readonly string[]): void {
    const isText = typeof msg === "string";
    const body: {
      sid: string;
      connectionId: "*";
      kind: "text" | "binary";
      data: string | Uint8Array;
      exceptIds?: readonly string[];
    } = {
      sid: this.sessionId,
      connectionId: "*",
      kind: isText ? "text" : "binary",
      data: msg,
    };
    if (without && without.length > 0) body.exceptIds = without;
    this.tunnel.sendOneWay(Op.ConnectionMessage, body);
  }
}
