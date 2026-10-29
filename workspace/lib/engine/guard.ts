/**
 * ATH-2 guard bridge — main-thread handle on the law-reticle worker.
 *
 * The worker evaluates op-1 (SHACL preflight) / op-2 (N3 admission) through
 * the pinned graphlaw.wasm artifact using its documented gl_alloc/gl_call/
 * gl_free buffer ABI. Messages cross the bridge as packet-4 length-prefixed
 * byte frames (u32 big-endian length + payload) — the same framing the smalt
 * WASM-1 port driver uses on the server side — carried inside postMessage
 * transferables. Typed verdicts only; no domain words.
 */

import type { RequestMsg, ResponseMsg } from "../../workers/law-reticle.worker";

export type GuardVerdict =
  | { status: 0; ms: number }
  | { status: 1; reason: string; ms: number }
  | { status: 2; detail: string; ms: number };

// --- pattern 6 (Bounded Arena): client-side allocation cap, pre-gl_alloc ----

/**
 * Payload cap enforced on the main thread BEFORE the worker (and its
 * gl_alloc) ever sees the bytes. The worker refusal for oversized bodies is
 * mapped to the same structured rule so both paths share one vocabulary.
 */
export const ALLOC_CAP_BYTES = 16 * 1024 * 1024;

/**
 * Pattern 6: the structured andon rule for a payload that exceeds the cap,
 * or `null` when the payload is within the arena and may proceed to the
 * worker. Returns a typed status-1 verdict so the caller treats it exactly
 * like a worker refusal.
 */
export function capRefusal(
  payloadLen: number,
): { status: 1; reason: string; ms: number } | null {
  if (payloadLen > ALLOC_CAP_BYTES) {
    return { status: 1, reason: "ALLOC_CAP_EXCEEDED", ms: 0 };
  }
  return null;
}

/**
 * Pattern 2: map a structured verdict to the andon rule surfaced at
 * `[data-andon-rule]`. Guard faults (status 2) are andon too — the sieve is
 * down, not the frame guilty. Status 0 never raises.
 */
export function andonRule(v: GuardVerdict): string | null {
  if (v.status === 1) return v.reason;
  if (v.status === 2) return "GUARD_FAULT";
  return null;
}

// --- packet-4 framing (u32 BE length prefix), mirroring smalt's port frames --

export function pack4(payload: Uint8Array): Uint8Array {
  const out = new Uint8Array(4 + payload.length);
  new DataView(out.buffer).setUint32(0, payload.length, false);
  out.set(payload, 4);
  return out;
}

export function unpack4(frame: Uint8Array): Uint8Array {
  const dv = new DataView(frame.buffer, frame.byteOffset, frame.byteLength);
  const len = dv.getUint32(0, false);
  if (4 + len !== frame.length) {
    throw new Error(`packet-4 length prefix mismatch: ${len} vs ${frame.length - 4}`);
  }
  return frame.slice(4);
}

export class Guard {
  private worker: Worker | null = null;
  private nextId = 1;
  private pending = new Map<number, (v: GuardVerdict) => void>();
  private timers = new Map<number, ReturnType<typeof setTimeout>>();
  private spawn: (() => Worker) | null = null;
  private callTimeoutMs: number;

  /**
   * W6 (expl1): every call carries a bounded timeout — a worker that never
   * answers (terminated mid-admit, wedged wasm call) resolves typed
   * GUARD_TIMEOUT within the bound instead of hanging the awaiter forever.
   * Default 10s; courts pass a short bound.
   */
  private static readonly DEFAULT_CALL_TIMEOUT_MS = 10_000;

  /**
   * `spawn` builds the Worker — supplied by the caller (a page) because the
   * worker URL resolves via `import.meta.url`, which is page/bundler territory
   * and keeps this module importable in plain-node courts. `callTimeoutMs`
   * bounds every call (courts pass a short value; default 10s).
   */
  constructor(spawn?: () => Worker, callTimeoutMs?: number) {
    this.spawn = spawn ?? null;
    this.callTimeoutMs = callTimeoutMs ?? Guard.DEFAULT_CALL_TIMEOUT_MS;
  }

  /** Spawn the worker and run INIT (reticle bytes loaded). */
  async init(reticleBytes: Uint8Array): Promise<GuardVerdict> {
    if (!this.worker && this.spawn) {
      this.worker = this.spawn();
      this.worker.onmessage = (ev: MessageEvent<ResponseMsg>) => this.onMessage(ev.data);
    }
    if (!this.worker) {
      const ms = 0;
      return { status: 2, detail: "no worker spawn function supplied", ms };
    }
    const reticle = pack4(reticleBytes);
    return this.call({ type: "INIT", id: this.nextId++, reticle }, reticle);
  }

  /** Evaluate one admission: op 1 = SHACL preflight, op 2 = N3 admission. */
  async admit(op: 1 | 2, node: bigint, payload: Uint8Array): Promise<GuardVerdict> {
    if (!this.worker) {
      const ms = 0;
      return { status: 2, detail: "guard not initialized", ms };
    }
    const body = pack4(payload);
    return this.call({ type: "ADMIT_INPUT", id: this.nextId++, op, node, body }, body);
  }

  dispose(): void {
    this.worker?.terminate();
    this.worker = null;
    // Fail-closed: in-flight admissions resolve typed (GUARD_FAULT), never
    // left hanging or silently dropped (W6 guard-side half).
    for (const resolve of this.pending.values()) {
      resolve({ status: 2, detail: "guard disposed with in-flight admission", ms: 0 });
    }
    this.pending.clear();
    for (const t of this.timers.values()) clearTimeout(t);
    this.timers.clear();
  }

  private call(msg: RequestMsg, transfer: Uint8Array): Promise<GuardVerdict> {
    return new Promise((resolve) => {
      const settle = (v: GuardVerdict) => {
        const t = this.timers.get(msg.id);
        if (t !== undefined) clearTimeout(t);
        this.timers.delete(msg.id);
        this.pending.delete(msg.id);
        resolve(v);
      };
      this.pending.set(msg.id, settle);
      this.timers.set(
        msg.id,
        setTimeout(() => {
          // Fail-closed: the pending entry is dropped so a late worker
          // response cannot resolve a stale awaiter; the caller gets a
          // typed fault within the bound, never a hang (W6, expl1).
          settle({
            status: 2,
            detail: `GUARD_TIMEOUT: no response within ${this.callTimeoutMs}ms`,
            ms: this.callTimeoutMs,
          });
        }, this.callTimeoutMs),
      );
      this.worker!.postMessage(msg, [transfer.buffer as ArrayBuffer]);
    });
  }

  private onMessage(m: ResponseMsg): void {
    const resolve = this.pending.get(m.id);
    if (resolve) resolve(m.verdict);
  }
}
