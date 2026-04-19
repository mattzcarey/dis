// Public entry point for @dis/sdk.
//
// User apps should import from here only:
//
//   import { DurableInference, startRunner } from "@dis/sdk";

export { DurableInference } from "./durable.js";
export type { HostBindings } from "./durable.js";

export { startRunner } from "./runner.js";
export type { RunnerHandle } from "./runner.js";

export { encode as encodeFrame, decode as decodeFrame, type Frame } from "./frames.js";
export { Op, type Opcode, type Tunnel, StubTunnel } from "./tunnel.js";
export { WsTunnel, type TunnelHandlers, type WsTunnelOpts, type ClientResponse } from "./ws-tunnel.js";

export type {
  ActorClass,
  ActorCtx,
  AiApi,
  AlarmFireInfo,
  Connection,
  GenerateOpts,
  LoadModelOpts,
  ModelInfo,
  Persisted,
  PersistOpts,
  RetryOptions,
  RunnerOpts,
  Schedule,
  ScheduleFilter,
  ScheduleInfo,
  ScheduleOpts,
  ScheduleWhen,
  Sql,
  StartInfo,
  StartReason,
  StopInfo,
  StopReason,
  Token,
  TokenStream,
} from "./types.js";

export {
  ContextOverflow,
  DisError,
  InvalidKey,
  ModelNotLoaded,
  NotImplemented,
  ScheduleExists,
  StateValueTooLarge,
  TunnelClosed,
} from "./errors.js";
