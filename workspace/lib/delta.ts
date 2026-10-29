/**
 * PRD §2.4 signed-transactional-delta wire format (first-party session scope).
 *
 * AUTH BOUNDARY (per PRD): these signatures are an INTEGRITY BINDING between
 * the client batch and the sync route, NOT cloud authentication. The session
 * key never leaves the browser and authorizes nothing — zero Azure secrets
 * live client-side. The server still decides admission under its own policy;
 * a valid HMAC only proves the payload was not corrupted or reordered in
 * transit within this page session.
 */

/** Random 32-byte session key, base64url. Held client-side only, per page load. */
export function makeSessionKey(): string {
  const raw = new Uint8Array(32);
  crypto.getRandomValues(raw);
  return bytesToBase64Url(raw);
}

/** Canonical JSON: object keys sorted recursively, stable separators. */
export function canonicalJson(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJson).join(",")}]`;
  }
  const entries = Object.entries(value as Record<string, unknown>)
    .filter(([, v]) => v !== undefined)
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([k, v]) => `${JSON.stringify(k)}:${canonicalJson(v)}`);
  return `{${entries.join(",")}}`;
}

async function hmacKey(key: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    base64UrlToBytes(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

/** HMAC-SHA256 over the canonical JSON of the delta; base64url signature. */
export async function signDelta(delta: unknown, key: string): Promise<string> {
  const data = new TextEncoder().encode(canonicalJson(delta));
  const mac = await crypto.subtle.sign("HMAC", await hmacKey(key), data);
  return bytesToBase64Url(new Uint8Array(mac as ArrayBuffer));
}

/** Constant-time-ish verify: recompute and compare decoded bytes. */
export async function verifyDelta(
  delta: unknown,
  key: string,
  sig: string,
): Promise<boolean> {
  const expected = base64UrlToBytes(await signDelta(delta, key));
  let provided: Uint8Array;
  try {
    provided = base64UrlToBytes(sig);
  } catch {
    return false;
  }
  if (expected.length !== provided.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected[i]! ^ provided[i]!;
  return diff === 0;
}

function bytesToBase64Url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlToBytes(s: string): Uint8Array<ArrayBuffer> {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
  const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
  const bin = atob(padded);
  const out = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
