// persisted-object: deep Proxy over a plain object, backed by a single
// blob per (actor, name) in durable state. Inspired by gsv's pattern
// and CF Durable Objects' storage blobs.
//
// Semantics:
//   - `$ready` — promise for the hydration-from-disk step.
//   - Any `set` or `delete` on the returned object (at any depth) schedules
//     a throttled flush (default 1 s) that writes the *whole* root blob
//     back to durable storage.
//   - `$flush()` performs an immediate, awaitable flush.
//   - `$raw()` returns a plain-object snapshot of the current state.
//
// The blob format on the wire is CBOR (handled engine-side); JS callers
// just see structured-cloneable values. Functions, DOM types, class
// instances with non-data fields etc. will throw if assigned.

import { Op, type Tunnel } from "../tunnel.js";
import type { Persisted, PersistOpts } from "../types.js";

const RESERVED = new Set(["$ready", "$flush", "$raw"]);

export function createPersisted<T extends object>(
  tunnel: Tunnel,
  sessionId: string,
  defaults: T,
  opts: PersistOpts = {},
): Persisted<T> {
  const name = opts.name ?? "default";
  const throttleMs = opts.throttleMs ?? 1000;
  const key = `__persisted__:${name}`;

  // Current in-memory value. Starts as a clone of defaults, replaced on
  // hydration with the stored value (remote wins if present).
  let current: T = structuredClone(defaults);

  let dirty = false;
  let flushTimer: ReturnType<typeof setTimeout> | null = null;
  let flushingPromise: Promise<void> | null = null;

  const ready = (async () => {
    try {
      const remote = await tunnel.request<T | null>(Op.StateGet, {
        sid: sessionId,
        key,
      });
      if (remote !== null && remote !== undefined) {
        current = remote;
      } else {
        // Persist defaults so subsequent readers see them.
        await tunnel.request<void>(Op.StateSet, {
          sid: sessionId,
          key,
          value: current,
          immediate: true,
        });
      }
    } catch (e) {
      // Log and carry on with defaults — engine may be temporarily down.
      console.warn("[dis] persist hydrate failed:", e);
    }
  })();

  const flushNow = async (): Promise<void> => {
    if (flushingPromise) return flushingPromise;
    if (!dirty) return;
    dirty = false;
    if (flushTimer) {
      clearTimeout(flushTimer);
      flushTimer = null;
    }
    const snapshot = structuredClone(current);
    flushingPromise = tunnel
      .request<void>(Op.StateSet, { sid: sessionId, key, value: snapshot, immediate: true })
      .finally(() => { flushingPromise = null; });
    try {
      await flushingPromise;
    } catch {
      // Flush failed — re-mark dirty so next attempt retries.
      dirty = true;
    }
  };

  const scheduleFlush = (): void => {
    dirty = true;
    if (flushTimer) return;
    flushTimer = setTimeout(() => {
      flushTimer = null;
      void flushNow();
    }, throttleMs);
  };

  // Deep Proxy: every property access that returns an object is itself
  // wrapped, so nested assignments trigger the parent's flush scheduler.
  const wrap = (value: unknown): unknown => {
    if (value === null || typeof value !== "object") return value;
    if (ArrayBuffer.isView(value) || value instanceof ArrayBuffer) return value;
    // Already wrapped? No way to detect cheaply; wrap idempotently by
    // relying on the fact that proxying a Proxy is fine.
    return new Proxy(value as object, {
      get(target, p) {
        const v = Reflect.get(target, p);
        if (typeof p === "symbol") return v;
        return wrap(v);
      },
      set(target, p, v) {
        const ok = Reflect.set(target, p, v);
        if (ok) scheduleFlush();
        return ok;
      },
      deleteProperty(target, p) {
        const ok = Reflect.deleteProperty(target, p);
        if (ok) scheduleFlush();
        return ok;
      },
    });
  };

  // Root Proxy also exposes $ready / $flush / $raw.
  const root = new Proxy(current as object, {
    get(target, p) {
      if (typeof p === "string" && RESERVED.has(p)) {
        if (p === "$ready") return ready;
        if (p === "$flush") return flushNow;
        if (p === "$raw") return () => structuredClone(current);
      }
      return wrap(Reflect.get(current, p));
    },
    set(target, p, v) {
      if (typeof p === "string" && RESERVED.has(p)) return false;
      const ok = Reflect.set(current as object, p, v);
      if (ok) scheduleFlush();
      return ok;
    },
    deleteProperty(target, p) {
      if (typeof p === "string" && RESERVED.has(p)) return false;
      const ok = Reflect.deleteProperty(current as object, p);
      if (ok) scheduleFlush();
      return ok;
    },
    has(target, p) {
      return Reflect.has(current as object, p);
    },
    ownKeys() {
      return Reflect.ownKeys(current as object);
    },
    getOwnPropertyDescriptor(target, p) {
      return Reflect.getOwnPropertyDescriptor(current as object, p);
    },
  });

  return root as Persisted<T>;
}
