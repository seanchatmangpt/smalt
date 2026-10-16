/**
 * External Term Format (ETF) encoder/decoder — pure TypeScript, zero dependencies.
 *
 * Wire format: http://erlang.org/doc/apps/erts/erl_ext_dist.html
 * Supported: integers, binaries, atoms, lists, tuples ({elements}), maps.
 *
 * TypeScript representation:
 *   integer  -> number | bigint
 *   binary   -> Uint8Array
 *   atom     -> { atom: string }
 *   list     -> { list: EtfTerm[] }   (improper tails are NOT produced)
 *   tuple    -> { elements: EtfTerm[] }
 *   map      -> { map: Array<[EtfTerm, EtfTerm]> }  (ordered pairs; insertion order preserved)
 */

export type EtfTerm =
  | number
  | bigint
  | Uint8Array
  | { atom: string }
  | { list: EtfTerm[] }
  | { elements: EtfTerm[] }
  | { map: Array<[EtfTerm, EtfTerm]> };

export class EtfError extends Error {
  constructor(
    message: string,
    public readonly code: string,
  ) {
    super(`etf: ${message} [${code}]`);
    this.name = 'EtfError';
  }
}

/** ETF version header byte. */
export const ETF_VERSION = 131;

/** Memory discipline: refuse inputs beyond this before decoding (4 MiB per term). */
export const ETF_MAX_INPUT_BYTES = 1 << 22;
export const ETF_MAX_DEPTH = 64;
export const ETF_MAX_ELEMENTS = 1 << 16;

// --- tags (erl_ext_dist.html) ---
const TAG_SMALL_INTEGER = 97; // SMALL_INTEGER_EXT
const TAG_INTEGER = 98; // INTEGER_EXT (4 bytes BE)
const TAG_SMALL_TUPLE = 104; // SMALL_TUPLE_EXT
const TAG_LARGE_TUPLE = 105; // LARGE_TUPLE_EXT
const TAG_MAP = 116; // MAP_EXT
const TAG_NIL = 106; // NIL_EXT (empty list)
const TAG_LIST_EXT = 108; // LIST_EXT
const TAG_BINARY = 109; // BINARY_EXT
const TAG_SMALL_BIG = 110; // SMALL_BIG_EXT
const TAG_LARGE_BIG = 111; // LARGE_BIG_EXT
const TAG_SMALL_ATOM_UTF8 = 119; // SMALL_ATOM_UTF8_EXT
const TAG_ATOM_UTF8 = 118; // ATOM_UTF8_EXT
const TAG_ATOM = 100; // ATOM_EXT (latin-1, legacy, read-only)
const TAG_STRING = 107; // STRING_EXT (bytes -> list of small ints)

const utf8 = new TextEncoder();
const latin1 = new TextDecoder('latin1');

// ---------------------------------------------------------------------------
// small helpers
// ---------------------------------------------------------------------------

function be32(n: number): number[] {
  return [(n >>> 24) & 0xff, (n >>> 16) & 0xff, (n >>> 8) & 0xff, n & 0xff];
}

function pushBig(out: number[], tag: number, value: bigint): void {
  // magnitude bytes, little-endian, minimal length, then sign byte
  let mag = value < 0n ? -value : value;
  const bytes: number[] = [];
  while (mag > 0n) {
    bytes.push(Number(mag & 0xffn));
    mag >>= 8n;
  }
  if (bytes.length === 0) bytes.push(0); // bignum representation of 0
  if (bytes.length > 255) throw new EtfError('bignum >255 bytes', 'ETF_BIG_TOO_LONG');
  out.push(tag, bytes.length, value < 0n ? 1 : 0, ...bytes);
}

// ---------------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------------

/** Encode a term to ETF bytes (leading 131 version byte included). */
export function etfEncode(term: EtfTerm): Uint8Array {
  const out: number[] = [];
  out.push(ETF_VERSION);
  encodeTerm(term, out, 0);
  return Uint8Array.from(out);
}

function encodeTerm(t: EtfTerm, out: number[], depth: number): void {
  if (depth > ETF_MAX_DEPTH) throw new EtfError('nesting too deep', 'ETF_DEPTH');
  if (out.length > ETF_MAX_INPUT_BYTES) throw new EtfError('encoded term exceeds budget', 'ETF_TOO_LARGE');

  if (typeof t === 'number') {
    if (!Number.isInteger(t)) throw new EtfError('non-integer number (fixed-point law: integers only)', 'ETF_NON_INTEGER');
    if (t >= 0 && t <= 255) {
      out.push(TAG_SMALL_INTEGER, t);
    } else if (t >= -0x80000000 && t <= 0x7fffffff) {
      out.push(TAG_INTEGER, ...be32(t < 0 ? t + 0x100000000 : t));
    } else {
      pushBig(out, TAG_SMALL_BIG, BigInt(t));
    }
    return;
  }
  if (typeof t === 'bigint') {
    pushBig (out, TAG_SMALL_BIG, t);
    return;
  }
  if (t instanceof Uint8Array) {
    out.push(TAG_BINARY, ...be32(t.byteLength), ...t);
    return;
  }
  if ('atom' in t) {
    const name = utf8.encode(t.atom);
    if (name.length > 255) throw new EtfError('atom name >255 bytes', 'ETF_ATOM_TOO_LONG');
    out.push(TAG_SMALL_ATOM_UTF8, name.length, ...name);
    return;
  }
  if ('elements' in t) {
    if (t.elements.length > 255) {
      out.push(TAG_LARGE_TUPLE, ...be32(t.elements.length));
    } else {
      out.push(TAG_SMALL_TUPLE, t.elements.length);
    }
    for (const e of t.elements) encodeTerm(e, out, depth + 1);
    return;
  }
  if ('list' in t) {
    const n = t.list.length;
    if (n === 0) {
      out.push(TAG_NIL);
    } else {
      out.push(TAG_LIST_EXT, ...be32(n));
      for (const e of t.list) encodeTerm(e, out, depth + 1);
      out.push(TAG_NIL); // proper-list tail
    }
    return;
  }
  if ('map' in t) {
    out.push(TAG_MAP, ...be32(t.map.length));
    for (const [k, v] of t.map) {
      encodeTerm(k, out, depth + 1);
      encodeTerm(v, out, depth + 1);
    }
    return;
  }
  throw new EtfError('unsupported term shape', 'ETF_UNSUPPORTED');
}

// ---------------------------------------------------------------------------
// Decoder (bounded, strict)
// ---------------------------------------------------------------------------

/** Decode ETF bytes (expects leading 131 version byte). Bounded and strict. */
export function etfDecode(bytes: Uint8Array): EtfTerm {
  if (bytes.byteLength < 1) throw new EtfError('empty input', 'ETF_EMPTY');
  if (bytes.byteLength > ETF_MAX_INPUT_BYTES) throw new EtfError('input exceeds ETF_MAX_INPUT_BYTES', 'ETF_TOO_LARGE');
  let pos = 0;
  if (bytes[pos++] !== ETF_VERSION) throw new EtfError('bad version byte', 'ETF_VERSION');
  const c: Cursor = { pos };
  const term = decodeTerm(bytes, c, 0);
  if (c.pos !== bytes.byteLength) throw new EtfError('trailing bytes after term', 'ETF_TRAILING');
  return term;
}

interface Cursor {
  pos: number;
}

function need(bytes: Uint8Array, c: Cursor, n: number): void {
  if (c.pos + n > bytes.byteLength) throw new EtfError('truncated input', 'ETF_TRUNCATED');
}

function u8(bytes: Uint8Array, c: Cursor): number {
  need(bytes, c, 1);
  return bytes[c.pos++];
}

function u16(bytes: Uint8Array, c: Cursor): number {
  need(bytes, c, 2);
  const v = (bytes[c.pos] << 8) | bytes[c.pos + 1];
  c.pos += 2;
  return v;
}

function u32(bytes: Uint8Array, c: Cursor): number {
  need(bytes, c, 4);
  let v = 0;
  for (let i = 0; i < 4; i++) v = v * 256 + bytes[c.pos + i];
  c.pos += 4;
  return v;
}

function decodeTerm(bytes: Uint8Array, c: Cursor, depth: number): EtfTerm {
  if (depth > ETF_MAX_DEPTH) throw new EtfError('nesting too deep', 'ETF_DEPTH');
  const tag = u8(bytes, c);
  switch (tag) {
    case TAG_SMALL_INTEGER:
      return u8(bytes, c);

    case TAG_INTEGER: {
      const v = u32(bytes, c);
      return v >= 0x80000000 ? v - 0x100000000 : v;
    }

    case TAG_SMALL_BIG:
    case TAG_LARGE_BIG: {
      const n = tag === TAG_SMALL_BIG ? u8(bytes, c) : u32(bytes, c);
      if (n === 0) throw new EtfError('zero-length bignum', 'ETF_BIG_EMPTY');
      need(bytes, c, n + 1);
      const sign = bytes[c.pos];
      let v = 0n;
      for (let i = n - 1; i >= 0; i--) v = (v << 8n) | BigInt(bytes[c.pos + 1 + i]);
      c.pos += n + 1;
      if (sign > 1) throw new EtfError('bad bignum sign byte', 'ETF_BIG_SIGN');
      return sign === 1 ? -v : v;
    }

    case TAG_SMALL_TUPLE:
    case TAG_LARGE_TUPLE: {
      const n = tag === TAG_SMALL_TUPLE ? u8(bytes, c) : u32(bytes, c);
      if (n > ETF_MAX_ELEMENTS) throw new EtfError('tuple too large', 'ETF_TOO_MANY');
      const elements: EtfTerm[] = [];
      for (let i = 0; i < n; i++) elements.push(decodeTerm(bytes, c, depth + 1));
      return { elements };
    }

    case TAG_NIL:
      return { list: [] };

    case TAG_LIST_EXT: {
      const n = u32(bytes, c);
      if (n > ETF_MAX_ELEMENTS) throw new EtfError('list too large', 'ETF_TOO_MANY');
      const list: EtfTerm[] = [];
      for (let i = 0; i < n; i++) list.push(decodeTerm(bytes, c, depth + 1));
      const tail = decodeTerm(bytes, c, depth + 1);
      if (!isList(tail) || tail.list.length !== 0) {
        throw new EtfError('improper list tail not supported', 'ETF_IMPROPER');
      }
      return { list };
    }

    case TAG_BINARY: {
      const n = u32(bytes, c);
      if (c.pos + n > bytes.byteLength) throw new EtfError('binary length overruns input', 'ETF_TRUNCATED');
      const b = bytes.slice(c.pos, c.pos + n);
      c.pos += n;
      return b;
    }

    case TAG_STRING: {
      // STRING_EXT: bytes -> list of small integers
      const n = u16(bytes, c);
      need(bytes, c, n);
      const list: EtfTerm[] = [];
      for (let i = 0; i < n; i++) list.push(bytes[c.pos + i]);
      c.pos += n;
      return { list };
    }

    case TAG_MAP: {
      const n = u32(bytes, c);
      if (n > ETF_MAX_ELEMENTS) throw new EtfError('map too large', 'ETF_TOO_MANY');
      const map: Array<[EtfTerm, EtfTerm]> = [];
      for (let i = 0; i < n; i++) {
        const k = decodeTerm(bytes, c, depth + 1);
        const v = decodeTerm(bytes, c, depth + 1);
        map.push([k, v]);
      }
      return { map };
    }

    case TAG_SMALL_ATOM_UTF8:
    case TAG_ATOM_UTF8: {
      const n = u8(bytes, c);
      need(bytes, c, n);
      const s = new TextDecoder('utf-8').decode(bytes.subarray(c.pos, c.pos + n));
      c.pos += n;
      return { atom: s };
    }

    case TAG_ATOM: {
      const n = u16(bytes, c);
      need(bytes, c, n);
      const s = latin1.decode(bytes.subarray(c.pos, c.pos + n));
      c.pos += n;
      return { atom: s };
    }

    default:
      throw new EtfError(`unknown tag ${tag}`, 'ETF_BAD_TAG');
  }
}

// ---------------------------------------------------------------------------
// type guards
// ---------------------------------------------------------------------------

export function isAtom(t: EtfTerm): t is { atom: string } {
  return typeof t === 'object' && t !== null && 'atom' in t && typeof (t as { atom: unknown }).atom === 'string';
}

export function isTuple(t: EtfTerm): t is { elements: EtfTerm[] } {
  return typeof t === 'object' && t !== null && 'elements' in t;
}

export function isList(t: EtfTerm): t is { list: EtfTerm[] } {
  return typeof t === 'object' && t !== null && 'list' in t;
}

export function isMap(t: EtfTerm): t is { map: Array<[EtfTerm, EtfTerm]> } {
  return typeof t === 'object' && t !== null && 'map' in t;
}

/** Convenience atom constructor: `atom('ok')` -> { atom: 'ok' }. */
export function atom(name: string): { atom: string } {
  return { atom: name };
}
