/**
 * Structural ledger types for lane WS-11 (NIST AU-10 compliance surface).
 *
 * IMPORT SEAM (WS-4 -> WS-11): the canonical ledger lives in
 *   workspace/lib/copilot/session-ledger.ts  (lane WS-4).
 * WS-11 must not import WS-4's runtime — only its shape. We therefore
 * re-declare the contract structurally here. On integration, a single
 * `import type { LedgerEntry, LedgerSnapshot } from '../copilot/session-ledger'`
 * in this file replaces the local declarations below; both components and
 * au10.ts consume only these types, so the swap is one line and the rest of
 * the lane is already decoupled.
 *
 * Contract as of WS-4 session-ledger.ts (copied, not invented):
 *   appendLedger(entry) -> LedgerEntry
 *   getLedgerSnapshot() -> LedgerSnapshot { entries, tailHash, length, intact }
 *   verifyLedgerChain(snapshot) -> boolean
 */

/**
 * Structural mirror of WS-4's `TypedRefusal` (lib/copilot/typed-refusal.ts).
 * Structural identity means the swap-in of the real import needs no cast.
 */
export interface LedgerRefusal {
  refused: true;
  reason: string;
  verb: string;
  url: string;
  ts: number;
}

/**
 * Structural mirror of WS-4 `LedgerEntry`. Read-only surface: every field is
 * readonly so no consumer can mutate a ledger entry through this type.
 */
export interface LedgerEntry {
  readonly seq: number;
  readonly ts: number;
  readonly kind: 'refusal' | 'read' | 'event';
  readonly refusal?: LedgerRefusal;
  readonly verb: string;
  readonly url: string;
  readonly prevHash: string;
  readonly hash: string;
}

/**
 * Structural mirror of WS-4 `LedgerSnapshot`. `intact: false` means the hash
 * chain does not verify end-to-end; every AU-10 render must treat that as
 * REFUSED (never green on missing/tampered evidence).
 */
export interface LedgerSnapshot {
  readonly entries: readonly LedgerEntry[];
  readonly tailHash: string;
  readonly length: number;
  readonly intact: boolean;
}

/**
 * Genesis sentinel used by WS-4's chain (`prevHash === 'GENESIS'` for seq 0).
 * Exported so AU-10 classifiers can recognize an empty ledger without
 * importing WS-4 runtime code.
 */
export const GENESIS_HASH = 'GENESIS';
