/**
 * ATH-2 frame codec — byte-moving only, zero domain words.
 *
 * Wire frame (all integers big-endian):
 *
 *   offset  size  field
 *   0       4     magic   = 0x534D4C54 ("SMLT")
 *   4       4     len     = payload byte length
 *   8       8     clientId (u64; producer identity as integer)
 *   16      8     seqId    (u64; monotone per clientId)
 *   24      8     ts       (u64; producer epoch millis)
 *   32      4     crc32    (IEEE, table-driven, over payload only)
 *   36      1     op       (integer opcode; semantics live in the law layer)
 *   37      4     reserved (zeroes; header is 41 bytes total)
 *   41      len   payload
 *
 * The four bytes of `reserved` pad the enumerated fields to the fixed 41-byte
 * header the wire contract pins; both lanes (browser sender, server receiver)
 * count 41. Decode results are typed; a corrupt or short frame never throws.
 */

export const FRAME_MAGIC = 0x534d4c54;
export const HEADER_LEN = 41;

/** Typed decode refusals. `code` is an integer opcode-class, not prose. */
export type CodecError =
  | { code: "BAD_MAGIC"; expected: number; observed: number }
  | { code: "SHORT_FRAME"; needed: number; observed: number }
  | { code: "BAD_LEN"; declared: number; observed: number }
  | { code: "BAD_CRC32"; expected: number; observed: number }
  | { code: "SEQ_REGRESSION"; observed: bigint; minimum: bigint };

export type DecodeResult<T> = { ok: true; value: T } | { ok: false; error: CodecError };

export interface Frame {
  clientId: bigint;
  seqId: bigint;
  ts: bigint;
  op: number;
  payload: Uint8Array;
  /** Encoded frame bytes (header + payload), exactly what crossed the wire. */
  bytes: Uint8Array;
}

// --- CRC32 (IEEE 802.3, reflected, poly 0xEDB88320) -------------------------

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    t[n] = c >>> 0;
  }
  return t;
})();

export function crc32(bytes: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) {
    c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) >>> 0;
}

/** Check vector: crc32(utf8("123456789")) must be 0xCBF43926. */
export function crc32SelfTest(): boolean {
  return crc32(new TextEncoder().encode("123456789")) === 0xcbf43926;
}

// --- encode -----------------------------------------------------------------

export function encodeFrame(
  clientId: bigint,
  seqId: bigint,
  ts: bigint,
  op: number,
  payload: Uint8Array,
): Uint8Array {
  const bytes = new Uint8Array(HEADER_LEN + payload.length);
  const dv = new DataView(bytes.buffer);
  dv.setUint32(0, FRAME_MAGIC, false);
  dv.setUint32(4, payload.length, false);
  dv.setBigUint64(8, clientId & 0xffffffffffffffffn, false);
  dv.setBigUint64(16, seqId & 0xffffffffffffffffn, false);
  dv.setBigUint64(24, ts & 0xffffffffffffffffn, false);
  dv.setUint32(32, crc32(payload), false);
  dv.setUint8(36, op & 0xff);
  // bytes[37..41) stay zero (reserved).
  bytes.set(payload, HEADER_LEN);
  return bytes;
}

// --- decode -----------------------------------------------------------------

export interface DecodeOptions {
  /** Enforce seqId > expectedSeq - 1 (monotone, no regression, no reuse). */
  minSeqId?: bigint;
}

export function decodeFrame(bytes: Uint8Array, opts: DecodeOptions = {}): DecodeResult<Frame> {
  if (bytes.length < HEADER_LEN) {
    return { ok: false, error: { code: "SHORT_FRAME", needed: HEADER_LEN, observed: bytes.length } };
  }
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const magic = dv.getUint32(0, false);
  if (magic !== FRAME_MAGIC) {
    return { ok: false, error: { code: "BAD_MAGIC", expected: FRAME_MAGIC, observed: magic } };
  }
  const len = dv.getUint32(4, false);
  if (HEADER_LEN + len !== bytes.length) {
    return { ok: false, error: { code: "BAD_LEN", declared: len, observed: bytes.length - HEADER_LEN } };
  }
  const payload = bytes.slice(HEADER_LEN);
  const expected = crc32(payload);
  const observed = dv.getUint32(32, false);
  if (expected !== observed) {
    return { ok: false, error: { code: "BAD_CRC32", expected, observed } };
  }
  const seqId = dv.getBigUint64(16, false);
  const min = opts.minSeqId ?? 0n;
  if (seqId < min) {
    return { ok: false, error: { code: "SEQ_REGRESSION", observed: seqId, minimum: min } };
  }
  return {
    ok: true,
    value: {
      clientId: dv.getBigUint64(8, false),
      seqId,
      ts: dv.getBigUint64(24, false),
      op: dv.getUint8(36),
      payload,
      bytes,
    },
  };
}
