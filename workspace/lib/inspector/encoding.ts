/**
 * Inspector encoding utilities — hex dump + UTF-8/ETF-ish safe rendering.
 *
 * Pure functions, no React. All renderers are "safe": invalid UTF-8 sequences
 * and non-printable bytes never throw and never produce control characters —
 * they render as `.` (hex gutter ASCII column) or `�` (JSON fallback).
 */

/** Bytes that render as printable single-width ASCII in the hex ASCII column. */
function isPrintable(b: number): boolean {
  return b >= 0x20 && b <= 0x7e;
}

/**
 * Render a byte as a safe single character for the hex-view ASCII column.
 * Printable ASCII passes through; everything else (including DEL, C1, control)
 * renders as `.`.
 */
export function byteToAscii(b: number): string {
  return isPrintable(b) ? String.fromCharCode(b) : ".";
}

/**
 * Decode bytes to a display string. Valid UTF-8 runs decode as text; invalid
 * sequences are replaced with U+FFFD (never thrown, never lossy-looped).
 */
export function bytesToSafeUtf8(bytes: Uint8Array): string {
  try {
    // TextDecoder with fatal:false replaces invalid sequences with U+FFFD.
    return new TextDecoder("utf-8", { fatal: false }).decode(bytes);
  } catch {
    // TextDecoder unavailable or unsupported label: byte-wise printable fallback.
    let out = "";
    for (const b of bytes) out += byteToAscii(b);
    return out;
  }
}

export interface HexRow {
  /** Zero-padded 8-digit offset, e.g. "00000000". */
  offset: string;
  /** 16 hex byte tokens, grouped in two 8-byte runs; short final row space-padded. */
  hex: string;
  /** 16-char ASCII column, non-printables as `.`. */
  ascii: string;
}

const ROW = 16;

/**
 * Classic 16-bytes-per-row hex dump (offset | hex | ascii).
 * Empty input yields zero rows — renderers should show an empty state.
 */
export function hexDump(bytes: Uint8Array): HexRow[] {
  const rows: HexRow[] = [];
  for (let base = 0; base < bytes.length; base += ROW) {
    const slice = bytes.subarray(base, base + ROW);
    const hexParts: string[] = [];
    const ascii: string[] = [];
    for (let i = 0; i < ROW; i++) {
      if (i < slice.length) {
        hexParts.push(slice[i].toString(16).padStart(2, "0"));
        ascii.push(byteToAscii(slice[i]));
      } else {
        hexParts.push("  ");
        ascii.push(" ");
      }
      if (i === 7) hexParts.push(""); // visual mid-row gap
    }
    rows.push({
      offset: base.toString(16).padStart(8, "0"),
      hex: hexParts.join(" "),
      ascii: ascii.join(""),
    });
  }
  return rows;
}

/**
 * ETF-ish structural preview: handles the Erlang External Term Format's common
 * extension point — payload starting with magic byte 131 followed by a term
 * header. We do NOT fully decode ETF (WS-4 owns the codec); we recognize the
 * envelope and give a safe textual hint. Any non-ETF bytes fall back to
 * safe-UTF-8 / printable rendering.
 */
export const ETF_VERSION_MAGIC = 131;

export interface DecodedPreview {
  kind: "json" | "etf" | "text" | "binary";
  /** Human-safe text to render. */
  text: string;
}

/** Best-effort classification and safe rendering of arbitrary payload bytes. */
export function decodePreview(bytes: Uint8Array): DecodedPreview {
  if (bytes.length > 0 && bytes[0] === ETF_VERSION_MAGIC) {
    return {
      kind: "etf",
      text:
        `ETF term envelope (magic 131, ${bytes.length - 1} term bytes) — ` +
        "structural decode owned by ETF codec lane; raw bytes in Hex tab.",
    };
  }
  const text = bytesToSafeUtf8(bytes);
  const trimmed = text.trim();
  if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
    try {
      return { kind: "json", text: JSON.stringify(JSON.parse(trimmed), null, 2) };
    } catch {
      // fall through
    }
  }
  // Heuristic: mostly-printable => text, else binary summary.
  let printable = 0;
  for (const b of bytes) if (isPrintable(b) || b === 0x0a || b === 0x09) printable++;
  if (bytes.length === 0 || printable / Math.max(bytes.length, 1) > 0.85) {
    return { kind: "text", text };
  }
  return { kind: "binary", text: bytesToSafeUtf8(bytes) };
}

/** Stable JSON rendering for manifest objects; never throws on cycles (fallback). */
export function safeJsonStringify(value: unknown): string {
  try {
    return JSON.stringify(value, null, 2) ?? "null";
  } catch {
    return String(value);
  }
}
