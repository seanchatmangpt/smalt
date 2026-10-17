/**
 * Structural mutation-verb interceptor (lane WS-4).
 *
 * One frozen pattern table, consulted at two layers:
 *   1. UI suggestion layer  — checkSuggestion() inspects advisor output ops.
 *   2. fetch-wrapper layer  — session-ledger.guardedFetch consults isMutation().
 *
 * Zero-actuation law: any method+URL matching a mutation pattern is refused
 * before any network I/O. Read verbs pass through.
 */

export const MUTATION_VERBS = ['PUT', 'POST', 'DELETE', 'PATCH'] as const;

import type { TypedRefusalReason } from './typed-refusal';

/**
 * ARM mutation operation patterns. Frozen: the gate table is read-only
 * at runtime; changing the law is an admitted transition, not a flag flip.
 */
export const ARM_MUTATION_PATTERNS: readonly RegExp[] = Object.freeze([
  // Microsoft.Resources/deployments/* — any non-read deployment operation
  /Microsoft\.Resources\/deployments\/(?!.*\/read(?:$|[?\/]))/i,
  // Microsoft.Compute/virtualMachines/* write/delete (not read)
  /Microsoft\.Compute\/virtualMachines\/(?!.*\/read(?:$|[?\/]))/i,
  // Microsoft.KeyVault/vaults/secrets/* (not read)
  /Microsoft\.KeyVault\/vaults\/secrets\/(?!.*\/read(?:$|[?\/]))/i,
]);

/**
 * Read patterns that always pass, even under a mutation verb shape.
 * Tested against the FULL URL string (not u.pathname): the `[?\/]`
 * alternatives in these patterns are only reachable when the query
 * string is still present (pathname has it stripped), so matching
 * against pathname made them dead. SHIM-COURT: read-marker semantics
 * are matched against the raw URL.
 */
const READ_PATTERNS: readonly RegExp[] = Object.freeze([
  /\/read(?:$|[?\/])/i,
  /GET\b/i,
]);

function urlPath(url: string): string {
  try {
    const u = new URL(url, 'http://localhost');
    return u.pathname;
  } catch {
    return url;
  }
}

/**
 * Gate decision for a method+URL pair. Pure: no I/O, no state.
 */
export function isMutation(method: string, url: string): boolean {
  const verb = method.toUpperCase();
  if (verb === 'GET' || verb === 'HEAD' || verb === 'OPTIONS') return false;
  const path = urlPath(url);

  // Explicit read markers pass for non-mutation verbs, tested against the
  // full URL so query-anchored read markers stay reachable (SHIM-COURT:
  // dead read-allowlist branch removed; see READ_PATTERNS doc).
  if (
    READ_PATTERNS.some((re) => re.test(url)) &&
    !MUTATION_VERBS.includes(verb as (typeof MUTATION_VERBS)[number])
  ) {
    return false;
  }

  // Generic actuation verbs are mutations on ARM-shaped or any URL.
  if (MUTATION_VERBS.includes(verb as (typeof MUTATION_VERBS)[number])) {
    return true;
  }

  // Non-HTTP verbs carrying ARM mutation operation names (suggestion layer).
  return ARM_MUTATION_PATTERNS.some((re) => re.test(path));
}

export interface SuggestionOp {
  /** Operation id or URL, e.g. "Microsoft.Compute/virtualMachines/vm1/write". */
  op?: string;
  /** Optional HTTP method if the suggestion carries one. */
  method?: string;
}

/**
 * UI-suggestion-layer gate: returns null when the suggestion is read-only
 * and safe to render as actionable; a typed reason when it carries a
 * mutation verb and must render as a typed refusal instead.
 */
export function checkSuggestion(s: SuggestionOp): TypedRefusalReason | null {
  const verb = (s.method ?? 'OP').toUpperCase();
  const target = s.op ?? '';
  if (isMutation(verb, target)) {
    return 'SUGGESTION_MUTATION_VERB';
  }
  return null;
}
