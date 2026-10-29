/**
 * Pattern 15 — Persistent Worker Pin.
 *
 * Module-scoped singleton bridge onto the law-reticle worker: the worker is
 * spawned once per page lifetime, INIT is idempotent (a ready promise is
 * memoized, concurrent callers await the same init), and admission requests
 * are correlated by `crypto.randomUUID()`. The 16 MiB Bounded-Arena cap
 * (pattern 6) is enforced HERE — before any gl_alloc in the worker sees the
 * payload — and the structured refusal rule `ALLOC_CAP_EXCEEDED` is the same
 * vocabulary the worker's own refusals surface.
 *
 * Messaging reuses the landed Guard/packet-4 surface (guard.ts); this module
 * pins the lifecycle policy on top of it.
 */

import { Guard, capRefusal, andonRule } from "./guard";

/**
 * Default spawn: refused at runtime. The worker URL is built with
 * `import.meta.url` — bundler/page territory (lib/engine is compiled
 * commonjs by the node courts, where import.meta is illegal). The page
 * supplies the spawn, exactly like Guard.
 */
function defaultSpawn(): Worker {
  throw new Error(
    "law worker spawn not supplied — pass a () => Worker from the page (import.meta.url resolves there)",
  );
}

export type AdmitOutcome =
  | { status: "ADMITTED"; ms: number }
  | { status: "ANDON_REFUSAL"; rule: string; ms: number };

export class LawWorkerBridge {
  private guard: Guard;
  private readyPromise: Promise<void> | null = null;
  private reticle = "";
  private spawn: () => Worker;

  constructor(spawn: () => Worker = defaultSpawn) {
    this.spawn = spawn;
    this.guard = new Guard(spawn);
  }

  /**
   * Idempotent INIT: the first call spawns the worker and loads the reticle;
   * every later call awaits the same ready promise (no re-spawn, no
   * re-INIT), even when callers race.
   */
  init(reticle: string, spawn?: () => Worker): Promise<void> {
    if (!this.readyPromise) {
      this.reticle = reticle;
      if (spawn) {
        this.spawn = spawn;
        this.guard = new Guard(spawn);
      }
      this.readyPromise = (async () => {
        const enc = new TextEncoder();
        const v = await this.guard.init(enc.encode(reticle));
        if (v.status !== 0) {
          const detail = v.status === 2 ? v.detail : v.reason;
          throw new Error(`law worker INIT failed: ${detail}`);
        }
      })().catch((e) => {
        // W6 (expl1): a REJECTED ready promise is not memoized — clearing it
        // here lets the next init() retry instead of failing INIT for the
        // page lifetime on one bad spawn.
        this.readyPromise = null;
        throw e;
      });
    }
    return this.readyPromise;
  }

  /**
   * One admission. Cap check (pattern 6) runs on the main thread BEFORE the
   * worker call — an oversized payload never reaches gl_alloc.
   */
  async admit(payload: Uint8Array, node: bigint = 0n): Promise<AdmitOutcome> {
    await this.init(this.reticle);
    const cap = capRefusal(payload.length);
    if (cap) {
      // COMPILE-FREEZE UNBLOCK (PAT-B lane): capRefusal's union type has no
      // .reason accessor; route through andonRule for the same string.
      return { status: "ANDON_REFUSAL", rule: andonRule(cap) ?? "ALLOC_CAP_EXCEEDED", ms: 0 };
    }
    const v = await this.guard.admit(1, node, payload);
    const rule = andonRule(v);
    if (rule !== null) {
      return { status: "ANDON_REFUSAL", rule, ms: v.ms };
    }
    return { status: "ADMITTED", ms: v.ms };
  }

  /** Test/court seam: only false before the first init() call. */
  get pinned(): boolean {
    return this.readyPromise !== null;
  }

  dispose(): void {
    this.guard.dispose();
    this.readyPromise = null;
  }
}

/** The module-scoped pin (pattern 15): one worker per page lifetime. */
export const lawWorkerBridge = new LawWorkerBridge();
