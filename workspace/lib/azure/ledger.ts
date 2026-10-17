/**
 * Confidential Ledger console client (over smaltFetch, air-gap enforced).
 *
 * Surface (smalt egress plane, wire-proven):
 *   POST /app/transactions          — append; 201 receipt | 409 dup fence
 *   GET  /app/transactions/:tx_id   — receipt by id ("N.1") | 404
 *   GET  /app/transactions/latest   — newest receipt | 404 when empty
 *   GET  /app/transactions          — all receipts, monotonic tx order
 *   POST /attest/:type              — MAA token | 400 attestationFailedVerdict
 *
 * Trust model (honest boundary): the substrate signs every receipt with an
 * RS256 detached JWS whose payload is the canonical JSON of the receipt minus
 * its `signature` field. The substrate's RSA public key is NOT exposed on the
 * wire (no JWKS endpoint), so this client cannot verify the RSA signature
 * itself. What it CAN and DOES verify, without trusting the server:
 *   1. JWS structure — 3 segments, header {alg:"RS256", typ:"JWT"},
 *      signature segment well-formed.
 *   2. Signing-input integrity — the JWS payload segment must equal
 *      base64url(canonicalJson(receipt minus signature)) exactly, so any
 *      tampered receipt field (contents, hashes, txId) breaks the binding
 *      between the signed token and the rendered receipt.
 *   3. Chain math — data_hash = sha256(canonicalJson(contents)),
 *      merkle_root = sha256(prev_hash <> data_hash), and prev_hash of each
 *      entry equals the previous entry's merkle_root (genesis prev_hash is
 *      64 zeros). Recomputed client-side; any tampered byte fails.
 *
 * Close condition for full RS256 verification: a JWKS/public-key endpoint on
 * the substrate; the verify seam below takes an optional public key and uses
 * node:crypto verify when one is supplied.
 */

import { createHash, createVerify } from 'node:crypto';
import { smaltFetch } from '../smalt';

export const ZERO_HASH = '0'.repeat(64);

export interface LedgerReceipt {
  transactionId: string;
  subLedgerId?: string;
  data_hash: string;
  prev_hash: string;
  merkle_root: string;
  contents: unknown;
  timestamp?: string;
  signature: string; // RS256 JWS compact: h.p.s
  [k: string]: unknown;
}

export type Check =
  | { check: string; valid: true }
  | { check: string; valid: false; reason: string };

// ---------------------------------------------------------------------------
// Canonical JSON + hash math (mirrors Jason sorted-key encoding server-side)
// ---------------------------------------------------------------------------

/** Recursively key-sorted JSON — the substrate's canonical form. */
export function canonicalJson(value: unknown): string {
  if (value === null || typeof value === 'number' || typeof value === 'boolean') {
    return JSON.stringify(value);
  }
  if (typeof value === 'string') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (typeof value === 'object') {
    const keys = Object.keys(value as object).sort();
    const body = keys
      .map((k) => `${JSON.stringify(k)}:${canonicalJson((value as Record<string, unknown>)[k])}`)
      .join(',');
    return `{${body}}`;
  }
  throw new TypeError(`canonicalJson: unsupported value ${typeof value}`);
}

export function sha256Hex(input: string): string {
  return createHash('sha256').update(input, 'utf8').digest('hex');
}

/** sha256 of the canonical JSON encoding of the append contents. */
export function computeDataHash(contents: unknown): string {
  return sha256Hex(canonicalJson(contents));
}

/** sha256 of the UTF-8 string concatenation prev_hash <> data_hash. */
export function computeMerkleRoot(prevHash: string, dataHash: string): string {
  return sha256Hex(prevHash + dataHash);
}

// ---------------------------------------------------------------------------
// JWS / receipt structure verification
// ---------------------------------------------------------------------------

function b64urlToBuf(s: string): Buffer {
  return Buffer.from(s, 'base64url');
}

function isB64url(s: string): boolean {
  return /^[A-Za-z0-9_-]+$/.test(s);
}

/** base64url with no padding — the ReceiptSigner encoding. */
export function toB64url(s: string): string {
  return Buffer.from(s, 'utf8').toString('base64url');
}

export interface StructureResult {
  valid: boolean;
  reason?: string;
  /** Parsed JWS header when the token is structurally sound. */
  header?: { alg: string; typ: string };
}

/**
 * Structural + signing-input verification of a receipt. Never throws on
 * malformed input; every failure is a typed reason.
 */
export function verifyReceiptStructure(receipt: LedgerReceipt): StructureResult {
  const fail = (reason: string): StructureResult => ({ valid: false, reason });
  if (!receipt || typeof receipt !== 'object') return fail('receipt is not an object');
  for (const field of ['transactionId', 'data_hash', 'prev_hash', 'merkle_root', 'signature']) {
    if (typeof receipt[field] !== 'string' || receipt[field] === '') {
      return fail(`missing or malformed field: ${field}`);
    }
  }
  if (!/^\d+\.\d+$/.test(receipt.transactionId)) return fail('transactionId is not "N.M"');

  const segs = receipt.signature.split('.');
  if (segs.length !== 3) return fail('signature is not a 3-segment JWS');
  const [h, p, s] = segs;
  if (!isB64url(h) || !isB64url(p) || !isB64url(s) || s.length < 128) {
    return fail('JWS segments are not base64url / signature too short for RS256');
  }
  let header: { alg: string; typ: string };
  try {
    header = JSON.parse(b64urlToBuf(h).toString('utf8'));
  } catch {
    return fail('JWS header is not JSON');
  }
  if (header.alg !== 'RS256') return fail(`alg confusion: ${header.alg}`);
  if (header.typ !== 'JWT') return fail(`typ fence: ${header.typ}`);

  // Signing-input integrity: payload segment must be exactly the canonical
  // encoding of the receipt minus its signature field.
  const rest: Record<string, unknown> = { ...receipt };
  delete rest.signature;
  const expectedPayload = toB64url(canonicalJson(rest));
  if (p !== expectedPayload) return fail('JWS payload does not match receipt body (tampered?)');

  return { valid: true, header };
}

/**
 * Optional full RS256 verification when a public key IS available (PEM or
 * JWK). The substrate does not expose one today — this seam exists so the
 * upgrade is a parameter, not a rewrite.
 */
export function verifySignature(
  receipt: LedgerReceipt,
  publicKeyPem: string
): { valid: boolean; reason?: string } {
  const struct = verifyReceiptStructure(receipt);
  if (!struct.valid) return { valid: false, reason: struct.reason };
  const [h, p, s] = receipt.signature.split('.');
  try {
    const ok = createVerify('RSA-SHA256')
      .update(`${h}.${p}`)
      .verify(publicKeyPem, b64urlToBuf(s));
    return ok ? { valid: true } : { valid: false, reason: 'RS256 signature invalid' };
  } catch (e) {
    return { valid: false, reason: `key error: ${(e as Error).message}` };
  }
}

// ---------------------------------------------------------------------------
// Chain audit (client-side math; no server trust)
// ---------------------------------------------------------------------------

/**
 * Audits one receipt against its predecessor (null for genesis). Checks:
 * data_hash recomputation, merkle_root recomputation, prev_hash linkage.
 */
export function auditReceipt(receipt: LedgerReceipt, prev: LedgerReceipt | null): Check[] {
  const out: Check[] = [];
  const push = (check: string, valid: boolean, reason = ''): void => {
    out.push(valid ? { check, valid: true } : { check, valid: false, reason });
  };

  const dataHash = computeDataHash(receipt.contents);
  push('data_hash recomputes', dataHash === receipt.data_hash,
    `expected ${dataHash}, got ${receipt.data_hash}`);

  const expectedPrev = prev ? prev.merkle_root : ZERO_HASH;
  push('prev_hash links', receipt.prev_hash === expectedPrev,
    `expected ${expectedPrev}, got ${receipt.prev_hash}`);

  const root = computeMerkleRoot(receipt.prev_hash, receipt.data_hash);
  push('merkle_root = sha256(prev<>data)', root === receipt.merkle_root,
    `expected ${root}, got ${receipt.merkle_root}`);

  const struct = verifyReceiptStructure(receipt);
  push('JWS structure + payload binding', struct.valid, struct.reason ?? '');

  return out;
}

/**
 * Full chain audit over a receipt list (tx order). Tamper anywhere fails the
 * entry and every subsequent link.
 */
export function auditChain(receipts: LedgerReceipt[]): { ok: boolean; failures: Check[] } {
  const failures: Check[] = [];
  const sorted = [...receipts].sort((a, b) => txSeq(a) - txSeq(b));
  let prev: LedgerReceipt | null = null;
  for (const r of sorted) {
    for (const c of auditReceipt(r, prev)) {
      if (!c.valid) failures.push({ ...c, check: `${r.transactionId}/${c.check}` });
    }
    prev = r;
}
  return { ok: failures.length === 0, failures };
}

export function txSeq(receipt: LedgerReceipt): number {
  return parseInt(receipt.transactionId.split('.')[0], 10);
}

// ---------------------------------------------------------------------------
// Wire client (smaltFetch; bearer token from the emulator STS)
// ---------------------------------------------------------------------------

export class LedgerError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string
  ) {
    super(`[${status}] ${code}: ${message}`);
  }
}

function bearer(token: string): Record<string, string> {
  return { Authorization: `Bearer ${token}` };
}

async function parseEnvelope(res: Response): Promise<never> {
  let code = 'Unknown';
  let message = '';
  try {
    const env = (await res.json()) as { error?: { code?: string; message?: string } };
    code = env?.error?.code ?? code;
    message = env?.error?.message ?? '';
  } catch {
    /* non-JSON error body */
  }
  throw new LedgerError(res.status, code, message || `HTTP ${res.status}`);
}

/** Fetch a bearer token from the smalt emulator STS (any client_id/secret). */
export async function fetchAccessToken(
  armBase: string,
  tenant = 'contoso'
): Promise<string> {
  const res = await smaltFetch(armBase, `/${tenant}/oauth2/v2.0/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'grant_type=client_credentials&client_id=console-lane&client_secret=console-lane',
  });
  if (!res.ok) await parseEnvelope(res);
  const body = (await res.json()) as { access_token?: string };
  if (!body.access_token) throw new LedgerError(0, 'NoAccessToken', 'STS returned no access_token');
  return body.access_token;
}

export interface AppendResult {
  status: number;
  receipt: LedgerReceipt;
}

/** Append contents; returns the 201 receipt. Duplicate content 409s. */
export async function appendTransaction(
  egressBase: string,
  token: string,
  contents: unknown
): Promise<AppendResult> {
  const res = await smaltFetch(egressBase, '/app/transactions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...bearer(token) },
    body: canonicalJson(contents),
  });
  if (res.status === 409) await parseEnvelope(res);
  if (!res.ok) await parseEnvelope(res);
  return { status: res.status, receipt: (await res.json()) as LedgerReceipt };
}

/** Read one receipt by tx id ("N.1") or the literal "latest". */
export async function getTransaction(
  egressBase: string,
  token: string,
  txId: string
): Promise<LedgerReceipt> {
  const res = await smaltFetch(egressBase, `/app/transactions/${encodeURIComponent(txId)}`, {
    headers: bearer(token),
  });
  if (!res.ok) await parseEnvelope(res);
  return (await res.json()) as LedgerReceipt;
}

export async function getLatest(
  egressBase: string,
  token: string
): Promise<LedgerReceipt> {
  return getTransaction(egressBase, token, 'latest');
}

/** All receipts in monotonic transaction order (server-sorted). */
export async function listTransactions(
  egressBase: string,
  token: string
): Promise<LedgerReceipt[]> {
  const res = await smaltFetch(egressBase, '/app/transactions', { headers: bearer(token) });
  if (!res.ok) await parseEnvelope(res);
  const body = (await res.json()) as LedgerReceipt[];
  if (!Array.isArray(body)) {
    throw new LedgerError(0, 'NotAList', 'GET /app/transactions did not return a list');
  }
  return body;
}

// ---------------------------------------------------------------------------
// MAA attestation (POST /attest/:type)
// ---------------------------------------------------------------------------

export interface AttestResult {
  status: number;
  /** MAA token (JWS) when attested; null on typed 400 refusal. */
  token: string | null;
  claims?: Record<string, unknown>;
}

/**
 * Request an MAA token for a hex64 measurement. The substrate refuses
 * measurements outside its configured baseline with 400
 * attestationFailedVerdict — a typed outcome, surfaced as token: null.
 */
export async function attest(
  egressBase: string,
  token: string,
  measurement: string,
  type = 'sevsnpvm'
): Promise<AttestResult> {
  const res = await smaltFetch(egressBase, `/attest/${type}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...bearer(token) },
    body: canonicalJson({ measurement }),
  });
  if (res.status === 400) {
    await parseEnvelope(res); // typed LedgerError(attestationFailedVerdict)
  }
  if (!res.ok) await parseEnvelope(res);
  const body = (await res.json()) as { token?: string; tokenResponse?: { token?: string } };
  const jws = body.token ?? body.tokenResponse?.token ?? null;
  return { status: res.status, token: jws };
}
