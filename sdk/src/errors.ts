// Error taxonomy. All thrown errors extend DisError so users can
// `catch (e) { if (e instanceof DisError) … }` without importing subclasses.

export class DisError extends Error {
  constructor(message: string, public readonly code: string) {
    super(message);
    this.name = "DisError";
  }
}

export class NotImplemented extends DisError {
  constructor(what: string) {
    super(`not implemented: ${what}`, "NOT_IMPLEMENTED");
    this.name = "NotImplemented";
  }
}

export class TunnelClosed extends DisError {
  constructor(reason: string = "tunnel closed") {
    super(reason, "TUNNEL_CLOSED");
    this.name = "TunnelClosed";
  }
}

export class ScheduleExists extends DisError {
  constructor(key: string) {
    super(`schedule with idempotentKey '${key}' already exists`, "SCHEDULE_EXISTS");
    this.name = "ScheduleExists";
  }
}

export class ContextOverflow extends DisError {
  constructor() {
    super("prompt exceeds model context length", "CONTEXT_OVERFLOW");
    this.name = "ContextOverflow";
  }
}

export class ModelNotLoaded extends DisError {
  constructor(modelId: string) {
    super(`model '${modelId}' is not loaded; call ctx.ai.loadModel() first`, "MODEL_NOT_LOADED");
    this.name = "ModelNotLoaded";
  }
}

export class StateValueTooLarge extends DisError {
  constructor(key: string, bytes: number, limit: number) {
    super(`state value for '${key}' is ${bytes} bytes (limit ${limit})`, "STATE_VALUE_TOO_LARGE");
    this.name = "StateValueTooLarge";
  }
}

export class InvalidKey extends DisError {
  constructor(reason: string) {
    super(`invalid key: ${reason}`, "INVALID_KEY");
    this.name = "InvalidKey";
  }
}
