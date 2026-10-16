/**
 * JCS-canonical JSON (RFC 8785 subset) — pure TypeScript.
 *
 * Scope (honest subset of RFC 8785): objects serialize with recursively
 * sorted keys and no whitespace; strings use JSON escaping; numbers are
 * emitted by JSON.stringify (IEEE-754 round-trip) — the RFC 8785 ES6
 * number serialization algorithm, which JSON.stringify implements on all
 * conforming runtimes. We support only JSON types (no BigInt / -0
 * normalization beyond JSON.stringify's "0").
 */

/** Recursively canonicalize a JSON-compatible value to JCS-form bytes input (string). */
export function jcsCanonical(value: unknown): string {
  return serialize(value);
}

function serialize(value: unknown): string {
  if (value === null) return 'null';
  switch (typeof value) {
    case 'boolean':
      return value ? 'true' : 'false';
    case 'string':
      return JSON.stringify(value);
    case 'number':
      return serializeNumber(value);
    case 'object': {
      if (Array.isArray(value)) {
        return '[' + value.map(serialize).join(',') + ']';
      }
      if (isPlainObject(value)) {
        const keys = Object.keys(value).sort();
        return (
          '{' +
          keys
            .map((k) => JSON.stringify(k) + ':' + serialize(value[k]))
            .join(',') +
          '}'
        );
      }
      // Functions, Dates, class instances, symbols — not JSON types.
      throw new TypeError('jcsCanonical: non-JSON value of object type');
    }
    default:
      // undefined, function, symbol, bigint
      throw new TypeError(
        `jcsCanonical: unsupported typeof ${typeof value}`
      );
  }
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
  if (v === null || typeof v !== 'object') return false;
  const proto = Object.getPrototypeOf(v);
  return proto === Object.prototype || proto === null;
}

/**
 * RFC 8785 number serialization = ECMAScript Number::toString.
 * Rejects non-finite values (JSON has no Infinity/NaN).
 */
function serializeNumber(n: number): string {
  if (!Number.isFinite(n)) {
    throw new TypeError('jcsCanonical: non-finite number');
  }
  return Object.is(n, -0) ? '0' : String(n);
}

/** Canonical form as UTF-8 bytes (the signing input). */
export function jcsCanonicalBytes(value: unknown): Uint8Array {
  return new TextEncoder().encode(jcsCanonical(value));
}

/** RFC 4648 base64url helpers (RFC 8785 string rules already handle this via JSON). */
export function toBase64Url(bytes: Uint8Array): string {
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function fromBase64Url(s: string): Uint8Array {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/');
  const pad = b64.length % 4 === 0 ? '' : '='.repeat(4 - (b64.length % 4));
  const bin = atob(b64 + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
