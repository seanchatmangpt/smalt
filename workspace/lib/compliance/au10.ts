/**
 * NIST SP 800-53 Rev.5 AU-10 classification (lane WS-11).
 *
 * AU-10 "Non-repudiation": assurance that an individual cannot subsequently
 * deny an action, built on attributable audit records — who / what / when /
 * where. Pure functions + one mapping table; no I/O, no mutation.
 *
 * Evidence-class mapping table (from the WS-4 ledger's honest surface):
 *
 * | class id                | AU-10 dim | derived from       | notes |
 * |-------------------------|-----------|--------------------|-------|
 * | AUDIT_RECORD_GENERATION | what      | verb + url         | the recorded action |
 * | ATTRIBUTABLE_IDENTITY   | who       | (no actor field)   | ledger carries no actor field, so coverage is always 'missing' — honest default |
 * | TIMESTAMPS              | when      | entry.ts           | epoch millis; no clock-source proof |
 * | ORIGIN_ADDRESS          | where     | entry.url          | URL origin when parseable, else partial |
 * | INTEGRITY_CHAIN         | means     | prevHash + hash    | tamper evidence, not attribution |
 * | TYPED_REFUSAL           | what      | kind === 'refusal' | provable non-action: mutation refused pre-network |
 * | CRYPTO_NON_REPUDIATION  | all       | Au10Attestation    | signed + hardware-verified; never inferred from ledger contents |
 */

import type { LedgerEntry, LedgerSnapshot } from './ledger-types';

/** The four AU-10 attribution dimensions. */
export type Au10Dimension = 'who' | 'what' | 'when' | 'where';

/** Evidence strength for one AU-10 dimension. */
export type Au10Coverage = 'present' | 'partial' | 'missing';

/** Evidence classes the classifier can emit. */
export type Au10EvidenceClass =
  | 'AUDIT_RECORD_GENERATION'
  | 'ATTRIBUTABLE_IDENTITY'
  | 'TIMESTAMPS'
  | 'ORIGIN_ADDRESS'
 | 'INTEGRITY_CHAIN'
 | 'TYPED_REFUSAL'
 | 'CRYPTO_NON_REPUDIATION';

/** Status per mission plan: unsigned / signed+hardware-verified / refused. */
export type Au10Status = 'unsigned' | 'signed-hardware-verified' | 'refused';

/** Classification of one ledger entry. */
export interface Au10EntryAssessment {
  readonly entry: LedgerEntry;
  readonly evidenceClass: Au10EvidenceClass;
  readonly coverage: Readonly<Record<Au10Dimension, Au10Coverage>>;
  readonly isTypedRefusal: boolean;
  /** 'chained' when both chain fields are populated on the entry. */
  readonly integrity: 'chained' | 'unchained';
  /** Evidence completeness ratio 0..1 over the four dimensions. */
  readonly score: number;
}

/**
 * Structural shape of a hardware attestation over the ledger tail. Not
 * produced anywhere yet; modeled so the "signed + hardware-verified" state is
 * reachable only via an explicit verified object binding the CURRENT tail.
 */
export interface Au10Attestation {
  readonly signature: string;
  /** Verified by a hardware-bound key (TPM / Secure Enclave). */
  readonly hardwareVerified: boolean;
  /** Key identity (who) that produced the signature. */
  readonly keyId: string;
  /** Tail hash the signature covers; must equal snapshot.tailHash at assess time. */
  readonly tailHash: string;
}

/** Extract URL origin for the `where` dimension. Null when unparseable. */
export function urlOrigin(url: string): string | null {
  try {
    return new URL(url).origin;
  } catch {
    return null;
  }
}

/** AU-10 status of a snapshot plus its per-entry classifications. */
export interface Au10Assessment {
  readonly status: Au10Status;
  readonly perEntry: readonly Au10EntryAssessment[];
}

/**
 * Overall AU-10 status. A downgrade cascade, never an upgrade:
 *  1. empty ledger or broken hash chain -> 'refused' (never green)
 *  2. verified hardware attestation binding the CURRENT tailHash -> 'signed-hardware-verified'
 *  3. otherwise -> 'unsigned'
 */
export function assessAu10Status(
  snapshot: LedgerSnapshot,
  attestation?: Au10Attestation,
): Au10Status {
  if (!snapshot.intact || snapshot.length === 0) return 'refused';
  const hwVerified =
    attestation !== undefined &&
    attestation.signature !== '' &&
    attestation.hardwareVerified === true &&
    attestation.tailHash === snapshot.tailHash;
  return hwVerified ? 'signed-hardware-verified' : 'unsigned';
}

/**
 * Classify a single ledger entry into its AU-10 evidence class and
 * who/what/when/where coverage. Missing evidence downgrades; never upgrades.
 */
export function classifyEntry(entry: LedgerEntry): Au10EntryAssessment {
  const what: Au10Coverage = entry.verb !== '' && entry.url !== '' ? 'present' : 'missing';
  const when: Au10Coverage = entry.ts >= 0 ? 'present' : 'missing';
  const origin = urlOrigin(entry.url);
  const where: Au10Coverage = origin !== null ? 'present' : 'partial';
  // The WS-4 ledger contract carries no actor field; who is honestly 'missing'
  const who: Au10Coverage = 'missing';

  const isTypedRefusal = entry.kind === 'refusal' && entry.refusal !== undefined;
  const evidenceClass: Au10EvidenceClass = isTypedRefusal
    ? 'TYPED_REFUSAL'
    : 'AUDIT_RECORD_GENERATION';
  const integrity: 'chained' | 'unchained' =
    entry.hash !== '' && entry.prevHash !== '' ? 'chained' : 'unchained';

  const presentCount = (['who', 'what', 'when', 'where'] as const).filter(
    (d) => ({ who, what, when, where })[d] === 'present',
  ).length;
  const score = presentCount / 4;

  return {
    entry,
    evidenceClass,
    coverage: { who, what, when, where },
    isTypedRefusal,
    integrity,
    score,
  };
}

/** Only 'signed-hardware-verified' renders green; 'unsigned' is not green. */
export function isGreen(status: Au10Status): boolean {
  return status === 'signed-hardware-verified';
}
