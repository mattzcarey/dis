// Engine tunnel — single WebSocket to dis-engine carrying multiplexed RPC
// frames. Concrete impl lands in M2; for now this file defines the shape
// and provides a no-op tunnel so the SDK can be built + tested in isolation.


import { NotImplemented } from "./errors.js";

// Frame opcodes — see SPEC §5A.6.
export const Op = {
  // engine → runner
  Hello:              0x01,
  ActorStart:         0x10,
  ActorStop:          0x11,
  ClientRequest:      0x20,
  ClientRequestAbort: 0x21,
  WsFrame:            0x22, // engine → runner: inbound client WS frame
  ConnectionMessage:  0x23, // runner → engine: outbound frame to connection (or "*")
  ConnectionClose:    0x24, // runner → engine: force-close a connection
  // 0xC5 ScheduleFire lives under the scheduling section below.

  // runner → engine
  RunnerReady:        0x80,
  ClientResponse:     0x90,
  Generate:           0xA0,
  GenerateRaw:        0xA1,
  Tokenize:           0xA2,
  LoadModel:          0xA3,
  Models:             0xA4,
  ResetContext:       0xA5,
  StateGet:           0xB0,
  StateGetMany:       0xB1,
  StateSet:           0xB2,
  StateSetMany:       0xB3,
  StateDelete:        0xB4,
  StateList:          0xB5,
  StateClear:         0xB6,
  StateTxnBegin:      0xB7,
  StateTxnCommit:     0xB8,
  StateTxnRollback:   0xB9,
  Schedule:           0xC0, // delayed | scheduled | cron
  ScheduleEvery:      0xC1, // interval
  CancelSchedule:     0xC2,
  GetSchedule:        0xC3,
  GetSchedules:       0xC4,
  ScheduleFire:       0xC5, // engine → runner, invoke callback
  SqlExec:            0xD0,
  SqlQuery:           0xD1,
  Broadcast:          0xE0,
  Hibernate:          0xE1,
  BlockConcurrency:   0xE2,

  // bidirectional replies
  Ack:                0xE8,
  Result:             0xE9,

  // bidirectional streaming + error
  TokenChunk:         0xF0,
  Error:              0xFF,
} as const;

export type Opcode = (typeof Op)[keyof typeof Op];

export interface Frame {
  kind: Opcode;
  tag: number;
  payload: unknown;
}

/**
 * Abstract tunnel — everything an ActorHost needs to talk to the engine.
 * The concrete WebSocket-backed impl lives in ./ws-tunnel.ts.
 */
export interface Tunnel {
  /** Send a one-shot RPC; resolve with the engine's Result payload. */
  request<R = unknown>(kind: Opcode, payload: unknown): Promise<R>;

  /**
   * Send a streaming RPC (e.g. Generate). Returns a ReadableStream of
   * TokenChunk payloads, terminated by a frame with `done: true` or an
   * error frame.
   */
  requestStream<T = unknown>(kind: Opcode, payload: unknown): ReadableStream<T>;

  /**
   * Fire-and-forget send. No reply expected; the engine will not
   * generate a Result for this frame. Used for outbound peer messages,
   * close notifications, etc.
   */
  sendOneWay(kind: Opcode, payload: unknown): void;

  /** Cancel an in-flight stream by its correlation tag. */
  abort(tag: number): void;

  /** Called on disconnect; resolve when the tunnel has fully closed. */
  close(): Promise<void>;
}

/**
 * Stub tunnel that throws NotImplemented on every call. Handy for local
 * development before the engine is wired up; lets code type-check and
 * unit tests run without a live engine.
 */
export class StubTunnel implements Tunnel {
  request<R = unknown>(_kind: Opcode, _payload: unknown): Promise<R> {
    return Promise.reject(new NotImplemented("tunnel.request"));
  }
  requestStream<T = unknown>(_kind: Opcode, _payload: unknown): ReadableStream<T> {
    return new ReadableStream<T>({
      start(ctl) {
        ctl.error(new NotImplemented("tunnel.requestStream"));
      },
    });
  }
  sendOneWay(_kind: Opcode, _payload: unknown): void {}
  abort(_tag: number): void {}
  close(): Promise<void> {
    return Promise.resolve();
  }
}


