/**
 * ATH-2 running accumulator over journal frames.
 *
 * DEVIATION (documented): the charter names BLAKE3; no pure-TS/JS BLAKE3
 * implementation exists in the air-gapped workspace dependency set (checked
 * workspace/package.json + node_modules: zero hash deps), and pulling a new
 * dependency would break the zero-egress bootstrap. This module therefore
 * implements a running SHA-256 chain accumulator via WebCrypto
 * `crypto.subtle.digest` — same algebra (a running compression-chain root
 * over frame bytes), different hash identity. The server lane must judge
 * roots produced by the same hash; the hash identity is carried by the
 * accumulator `kind` tag ("sha256-chain") wherever a root crosses the wire
 * or a receipt.
 */

const KIND = "sha256-chain";

export function accumulatorKind(): string {
  return KIND;
}

function subtle(): SubtleCrypto {
  const c = (globalThis as { crypto?: Crypto }).crypto;
  if (!c?.subtle) {
    throw new Error("WebCrypto subtle unavailable — accumulator requires a secure context");
  }
  return c.subtle;
}

function toHex(b: ArrayBuffer): string {
  return [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
}

/** Running accumulator state: chain root plus leaf count. */
export class Accumulator {
  private rootBytes: Uint8Array | null = null;
  private count = 0;

  /** Fold one opaque frame (or payload) into the running root. */
  async append(bytes: Uint8Array): Promise<void> {
    const leaf = await subtle().digest("SHA-256", bytes as BufferSource);
    const input = this.rootBytes
      ? concat(this.rootBytes, new Uint8Array(leaf))
      : new Uint8Array(leaf);
    const next = await subtle().digest("SHA-256", input as BufferSource);
    this.rootBytes = new Uint8Array(next);
    this.count += 1;
  }

  /** Chain root as lowercase hex; empty string before the first append. */
  rootHex(): string {
    return this.rootBytes ? toHex(this.rootBytes.buffer as ArrayBuffer) : "";
  }

  leafCount(): number {
    return this.count;
  }
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}
