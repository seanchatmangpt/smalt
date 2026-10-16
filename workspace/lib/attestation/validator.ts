/**
 * Attestation Receipt Validator — WebCrypto (SubtleCrypto) verification of
 * signed attestation receipts over their JCS-canonical form.
 *
 * Contract — verify() is TOTAL: it never throws on malformed input; every
 * malformed shape yields a typed refusal or { valid: false, reason }.
 *
 *   verify(receipt) ->
 *     | { valid: true; signer: string }
 *     | { valid: false; reason: string }
 *     | { refused: 'ALGORITHM_UNSUPPORTED'; algorithm: string }
 *
 * Algorithms:
 *   - 'RS256'      : RSASSA-PKCS1-v1_5 over SHA-256
 *   - 'ECDSA-P256' : ECDSA P-256 over SHA-256 (WebCrypto raw r||s signature)
 *   - 'ML-DSA-65'  : REFUSED — no WebCrypto primitive exists. Honest boundary:
 *                    this is a typed refusal, never a silent pass. Close
 *                    condition (future work): a pure-TS ML-DSA verifier
 *                    (FIPS 204) or a wasm ML-DSA module wired behind the same
 *                    verify() seam.
 */

import { jcsCanonicalBytes, fromBase64Url } from './canonical';
import { checkBootDigest } from './boot-digests';

export const SUPPORTED_ALGORITHMS = ['RS256', 'ECDSA-P256'] as const;
export type SupportedAlgorithm = (typeof SUPPORTED_ALGORITHMS)[number];

/** Recognized-but-unimplemented algorithms (typed refusal, never silent pass). */
export const UNSUPPORTED_ALGORITHMS = ['ML-DSA-65'] as const;
export type UnsupportedAlgorithm = (typeof UNSUPPORTED_ALGORITHMS)[number];

export interface AttestationReceipt {
  /** Signature algorithm name (case-sensitive). */
  algorithm: string;
  /** Stable signer/device identity — echoed on success. */
  signerId: string;
  /** The payload that was signed (any JSON value). */
  payload: unknown;
  /** Signature over JCS(payload), base64url (or base64/hex) encoded. */
  signature: string;
  /** Signer public key as JWK (public). */
  key: JsonWebKey;
  /** Optional chipset serial (triggers the boot-digest allowlist check). */
  chipsetSerial?: string;
  /** Optional boot measurement digest (hex). */
  bootDigest?: string;
}

export type VerifyResult =
  | { valid: true; signer: string }
  | { valid: false; reason: string }
  | { refused: 'ALGORITHM_UNSUPPORTED'; algorithm: string };

/**
 * Total verifier. Accepts any input; classifies rather than throws.
 */
export async function verify(receipt: unknown): Promise<VerifyResult> {
  try {
    return await verifyInner(receipt);
  } catch (e) {
    return {
      valid: false,
      reason: `MALFORMED: ${
        e instanceof Error ? e.message : String(e)
      }`,
    };
  }
}

async function verifyInner(receipt: unknown): Promise<VerifyResult> {
  // ---- shape classification (typed refusals, no throws) ----
  if (
    typeof receipt !== 'object' ||
    receipt === null ||
    Array.isArray(receipt)
  ) {
    return { valid: false, reason: 'MALFORMED: receipt must be a JSON object' };
  }
  const r = receipt as Record<string, unknown>;

  const algorithm = r['algorithm'];
  if (typeof algorithm !== 'string' || algorithm.length === 0) {
    return { valid: false, reason: 'MALFORMED: missing algorithm' };
  }

  // Algorithm gate FIRST: recognized-but-unimplemented -> typed refusal.
  if ((UNSUPPORTED_ALGORITHMS as readonly string[]).includes(algorithm)) {
    return { refused: 'ALGORITHM_UNSUPPORTED', algorithm };
  }
  if (!(SUPPORTED_ALGORITHMS as readonly string[]).includes(algorithm)) {
    return {
      valid: false,
      reason: `MALFORMED: unknown algorithm ${String(algorithm)}`,
    };
  }

  const signerId = r['signerId'];
  if (typeof signerId !== 'string' || signerId.length === 0) {
    return { valid: false, reason: 'MALFORMED: missing signerId' };
  }
  if (!('payload' in r)) {
    return { valid: false, reason: 'MALFORMED: missing payload' };
  }
  if (typeof r['signature'] !== 'string' || r['signature'].length === 0) {
    return { valid: false, reason: 'MALFORMED: missing signature' };
  }
  const key = r['key'];
  if (typeof key !== 'object' || key === null || Array.isArray(key)) {
    return {
      valid: false,
      reason: 'MALFORMED: missing key (JWK object required)',
    };
  }

  const receipt2 = r as unknown as AttestationReceipt;

  // ---- boot-digest allowlist (when the receipt carries device identity) ----
  if (receipt2.chipsetSerial !== undefined || receipt2.bootDigest !== undefined) {
    const boot = checkBootDigest(receipt2.chipsetSerial, receipt2.bootDigest);
    if (!boot.allowed) {
      return { valid: false, reason: `BOOT_DIGEST_${boot.reason}` };
    }
  }

  return cryptoVerify(receipt2, algorithm as SupportedAlgorithm);
}

async function cryptoVerify(
  r: AttestationReceipt,
  algorithm: SupportedAlgorithm
): Promise<VerifyResult> {
  const data: Uint8Array<ArrayBuffer> = jcsCanonicalBytes(r.payload) as Uint8Array<ArrayBuffer>;
  const sig = decodeSig(r.signature);
  if (!sig.ok) return { valid: false, reason: sig.reason };
  try {
    const cryptoKey = await importPublicKey(algorithm, r.key);
    const ok = await crypto.subtle.verify(
      algParams(algorithm),
      cryptoKey,
      sig.bytes as Uint8Array<ArrayBuffer>,
      data
    );
    if (!ok) return { valid: false, reason: 'BAD_SIGNATURE' };
    return { valid: true, signer: r.signerId };
  } catch (e) {
    return {
      valid: false,
      reason: `KEY_OR_ALGORITHM_ERROR: ${
        e instanceof Error ? e.message : String(e)
      }`,
    };
  }
}

/** Import a public key from JWK. */
async function importPublicKey(
  algorithm: SupportedAlgorithm,
  key: JsonWebKey
): Promise<CryptoKey> {
  if (algorithm === 'RS256') {
    return crypto.subtle.importKey(
      'jwk',
      key,
      { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
      false,
      ['verify']
    );
  }
  return crypto.subtle.importKey(
    'jwk',
    key,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['verify']
  );
}

function algParams(algorithm: SupportedAlgorithm): AlgorithmIdentifier | EcdsaParams {
  if (algorithm === 'RS256') return { name: 'RSASSA-PKCS1-v1_5' };
  return { name: 'ECDSA', hash: 'SHA-256' };
}

/** Accept base64url (preferred), base64, or hex signature encodings. */
function decodeSig(
  s: string
): { ok: true; bytes: Uint8Array } | { ok: false; reason: string } {
  if (/^[0-9a-fA-F]+$/.test(s) && s.length % 2 === 0) {
    const out = new Uint8Array(s.length / 2);
    for (let i = 0; i < s.length; i += 2) {
      out[i / 2] = parseInt(s.slice(i, i + 2), 16);
    }
    return { ok: true, bytes: out };
  }
  try {
    return { ok: true, bytes: fromBase64Url(s) };
  } catch {
    return {
      ok: false,
      reason: 'MALFORMED: signature is not decodable base64url/base64/hex',
    };
  }
}

/** SHA-256 helper over arbitrary input; returns lowercase hex. */
export async function sha256Hex(data: Uint8Array | string): Promise<string> {
  const bytes =
    typeof data === 'string' ? new TextEncoder().encode(data) : data;
  const digest = await crypto.subtle.digest(
    'SHA-256',
    bytes as Uint8Array<ArrayBuffer>
  );
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}
