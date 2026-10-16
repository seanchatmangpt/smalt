/**
 * Typed refusal vocabulary for the Zero-Actuation Copilot Controller.
 * Lane WS-4. A refusal is a receipt, not an error: it carries identity
 * (verb+url), consequence reason, and timestamp — replayable from the ledger.
 */

export type TypedRefusalReason =
  | 'ZERO_ACTUATION'
  | 'SUGGESTION_MUTATION_VERB'
  | 'LEDGER_CHAIN_BROKEN';

export interface TypedRefusal {
  refused: true;
  reason: TypedRefusalReason;
  /** HTTP method or operation verb that was blocked (e.g. PUT, deployments/write). */
  verb: string;
  /** Request URL or suggestion operation id that was blocked. */
  url: string;
  /** Epoch millis at refusal time. */
  ts: number;
}

export function makeRefusal(
  reason: TypedRefusalReason,
  verb: string,
  url: string,
  ts: number = Date.now(),
): TypedRefusal {
  return { refused: true, reason, verb, url, ts };
}

export function isTypedRefusal(value: unknown): value is TypedRefusal {
  return (
    typeof value === 'object' &&
    value !== null &&
    (value as TypedRefusal).refused === true &&
    typeof (value as TypedRefusal).reason === 'string' &&
    typeof (value as TypedRefusal).verb === 'string' &&
    typeof (value as TypedRefusal).url === 'string' &&
    typeof (value as TypedRefusal).ts === 'number'
  );
}
