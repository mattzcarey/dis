// Frame codec for engine↔runner RPC.
//
// Frame layout (each WebSocket binary message is one frame):
//
//     ┌────────┬───────────────┬───────────────────────────┐
//     │ kind   │    tag (BE)   │    body (CBOR)            │
//     │ u8 (1) │    u32 (4)    │    N bytes                │
//     └────────┴───────────────┴───────────────────────────┘
//
// WebSocket already provides frame boundaries, so we skip the u32 length
// prefix that the engine↔infer unix-socket format carries. The wire shape
// otherwise matches SPEC §5A.6 / §7A.1.
//
// `kind` is an opcode from ./tunnel:Op. `tag` correlates requests with
// responses and/or ties stream chunks together. `body` is whatever the
// opcode defines, CBOR-encoded.

import { decode as cborDecode, encode as cborEncode } from "cbor-x";
import type { Opcode } from "./tunnel.js";

export interface Frame {
  kind: Opcode;
  tag: number;
  body: unknown;
}

const HEADER = 5;

/** Encode a frame. Allocates. Returns the concatenated header + body. */
export function encode(kind: Opcode, tag: number, body: unknown): Uint8Array {
  const cborBody: Uint8Array = cborEncode(body);
  const out = new Uint8Array(HEADER + cborBody.byteLength);
  const view = new DataView(out.buffer);
  view.setUint8(0, kind);
  view.setUint32(1, tag >>> 0, false); // big-endian
  out.set(cborBody, HEADER);
  return out;
}

/** Decode a frame. Zero-copies the body view before CBOR-decoding. */
export function decode(data: Uint8Array): Frame {
  if (data.byteLength < HEADER) {
    throw new Error(`frame too short: ${data.byteLength} bytes`);
  }
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const kind = view.getUint8(0) as Opcode;
  const tag = view.getUint32(1, false);
  const body = cborDecode(data.subarray(HEADER)) as unknown;
  return { kind, tag, body };
}

/** Convenience: throw if `body` doesn't have the expected shape. */
export function expectObject<T extends object>(body: unknown, ctx: string): T {
  if (body === null || typeof body !== "object") {
    throw new Error(`frame body for ${ctx} is not an object`);
  }
  return body as T;
}
