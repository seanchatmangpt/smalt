/**
 * P12 Constant Seal — client-side parse + verify of the server receiptToken.
 *
 * Encoding (COORDINATED with the server minter — see
 * docs/jira/v26.10.22/receipts/bk92-receipt-sot.md, ALIVE: the server minter
 * `lib/smalt/sync/receipt.ex` has landed and mints byte-identical cross-mint
 * faces against this module): lowercase hex, 640 hex chars = 320 bytes = 40
 * words of 8 bytes. Base64 of the same 320 bytes is also accepted at parse
 * time (hex∪base64 parse superset, proven in the BK-92 court).
 *
 * Receipt layout (320 bytes, big-endian):
 *   bytes  0..3   magic  0x534D4C54 ("SMLT", same as the frame codec)
 *   bytes  4..7   version 1
 *   bytes  8..15  leafCount uint64 BE — number of frames sealed
 *   bytes 16..47  sha256-chain root (32 bytes, merkle.ts Accumulator)
 *   bytes 48..319 reserved, all zero
 *
 * The 320-byte invariant (NFR-EVI-001) holds at any leaf count n — the seal
 * is a fixed-size word vector, O(1) on the wire. P12's court proves it at
 * n=1 and n=100 synthetic leaves.
 */

import { Accumulator } from "./merkle";

export const RECEIPT_BYTES = 320;
export const RECEIPT_VERSION = 1;
export const RECEIPT_MAGIC = 0x534d4c54; // "SMLT" — frame codec magic

export interface ReceiptFields {
  byteLength: number;
  magic: number;
  version: number;
  leafCount: number;
  /** sha256-chain root as lowercase hex. */
  rootHex: string;
  /** True when bytes 48..319 are all zero (layout conformance). */
  reservedZero: boolean;
}

export type ReceiptParseError =
  | { code: "NOT_STRING" }
  | { code: "BAD_ENCODING" }
  | { code: "BAD_LENGTH"; observed: number; expected: number }
  | { code: "BAD_MAGIC"; observed: number }
  | { code: "BAD_VERSION"; observed: number };

export type ReceiptParseResult =
  | { ok: true; value: ReceiptFields; bytes: Uint8Array }
  | { ok: false; error: ReceiptParseError };

/** Decode a hex (preferred) or base64 token to raw bytes; null on failure. */
function decodeToken(token: string): Uint8Array | null {
  const t = token.trim();
  if (t.length === 0) return null;
  if (/^[0-9a-fA-F]+$/.test(t) && t.length % 2 === 0) {
    const out = new Uint8Array(t.length / 2);
    for (let i = 0; i < t.length; i += 2) {
      out[i / 2] = parseInt(t.slice(i, i + 2), 16);
    }
    return out;
  }
  const atob = (globalThis as { atob?: (s: string) => string }).atob;
  if (!atob) return null;
  try {
    const bin = atob(t);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

function beView(bytes: Uint8Array): DataView {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
}

function toHex(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += bytes[i].toString(16).padStart(2, "0");
  return s;
}

/** Parse a receiptToken into typed fields; never throws. */
export function parseReceiptToken(token: unknown): ReceiptParseResult {
  if (typeof token !== "string") return { ok: false, error: { code: "NOT_STRING" } };
  const bytes = decodeToken(token);
  if (!bytes) return { ok: false, error: { code: "BAD_ENCODING" } };
  if (bytes.length !== RECEIPT_BYTES) {
    return { ok: false, error: { code: "BAD_LENGTH", observed: bytes.length, expected: RECEIPT_BYTES } };
  }
  const dv = beView(bytes);
  const magic = dv.getUint32(0, false);
  if (magic !== RECEIPT_MAGIC) {
    return { ok: false, error: { code: "BAD_MAGIC", observed: magic } };
  }
  const version = dv.getUint32(4, false);
  if (version !== RECEIPT_VERSION) {
    return { ok: false, error: { code: "BAD_VERSION", observed: version } };
  }
  let reservedZero = true;
  for (let i = 48; i < RECEIPT_BYTES; i++) {
    if (bytes[i] !== 0) {
      reservedZero = false;
      break;
    }
  }
  return {
    ok: true,
    value: {
      byteLength: bytes.length,
      magic,
      version,
      leafCount: Number(dv.getBigUint64(8, false)),
      rootHex: toHex(bytes.subarray(16, 48)),
      reservedZero,
    },
    bytes,
  };
}

/** Mint a receipt token (hex) for courts/probes; the sync server mirrors this. */
export function mintReceiptToken(leafCount: number, rootHex: string): string {
  const b = new Uint8Array(RECEIPT_BYTES);
  const dv = new DataView(b.buffer);
  dv.setUint32(0, RECEIPT_MAGIC, false);
  dv.setUint32(4, RECEIPT_VERSION, false);
  dv.setBigUint64(8, BigInt(leafCount), false);
  for (let i = 0; i < 32; i++) {
    b[16 + i] = parseInt(rootHex.slice(i * 2, i * 2 + 2), 16);
  }
  return toHex(b);
}

/**
 * Recompute the client's leaf chain hash over the synced frames (sha256-chain
 * Accumulator) and compare against the receipt root. Node-testable: WebCrypto
 * only.
 */
export async function verifyReceipt(
  frames: Uint8Array[],
  receiptToken: string,
): Promise<
  | { ok: true; verified: boolean; fields: ReceiptFields }
  | { ok: false; error: ReceiptParseError }
> {
  const parsed = parseReceiptToken(receiptToken);
  if (!parsed.ok) return parsed;
  const fields = parsed.value;
  const acc = new Accumulator();
  for (const f of frames) await acc.append(f);
  const countsMatch = acc.leafCount() === fields.leafCount;
  return {
    ok: true,
    verified: countsMatch && acc.rootHex() === fields.rootHex && fields.reservedZero,
    fields,
  };
}

// --- P8 DOM fields ----------------------------------------------------------

/**
 * Drive the P8/P12 DOM fields on a host element:
 *   data-receipt-bytes="<byteLength>"
 *   data-receipt-verified="true"|"false"
 * Parse alone never verifies; malformed tokens set bytes="0" verified="false".
 * Pass `verified=true` only after verifyReceipt() has confirmed the root.
 */
export function renderReceiptFields(
  el: { setAttribute(name: string, value: string): void },
  token: unknown,
  verified: boolean,
): void {
  const parsed = parseReceiptToken(token);
  if (!parsed.ok) {
    el.setAttribute("data-receipt-bytes", "0");
    el.setAttribute("data-receipt-verified", "false");
    return;
  }
  el.setAttribute("data-receipt-bytes", String(parsed.value.byteLength));
  el.setAttribute("data-receipt-verified", verified ? "true" : "false");
}
