/**
 * Air-gap base URLs. The ONLY network hosts this console may contact.
 * Configure via env: NEXT_PUBLIC_SMALT_ARM, NEXT_PUBLIC_SMALT_EGRESS.
 */
export const SMALT_ARM =
  process.env.NEXT_PUBLIC_SMALT_ARM ?? "http://127.0.0.1:9443";
export const SMALT_EGRESS =
  process.env.NEXT_PUBLIC_SMALT_EGRESS ?? "http://127.0.0.1:8443";

/**
 * Loopback hosts always admitted. Operator-declared extra hosts via
 * SMALT_ALLOWED_HOSTS (comma-separated hostnames, BK-TOPO WI-1): when
 * non-empty, those named hosts are admitted alongside loopback; unset or
 * empty -> byte-identical loopback-only behavior. No wildcards —
 * explicitly named hosts only; the air-gap posture is preserved.
 */
export const LOOPBACK_HOSTS = ["127.0.0.1", "localhost", "[::1]", "::1"];

export function allowedHosts(): string[] {
  const raw = process.env.SMALT_ALLOWED_HOSTS;
  if (raw === undefined || raw.trim() === "") return [];
  return raw
    .split(",")
    .map((h) => h.trim().toLowerCase())
    .filter((h) => h !== "");
}

/** Air-gap guard: refuse any URL that is not a localhost smalt endpoint. */
export function assertLocalUrl(url: string): URL {
  const u = new URL(url, typeof window === "undefined" ? SMALT_ARM : window.location.origin);
  if (!LOOPBACK_HOSTS.includes(u.hostname) && !allowedHosts().includes(u.hostname.toLowerCase())) {
    throw new Error(
      `Air-gap violation: refused non-local host "${u.hostname}". Only the local smalt emulator is reachable.`
    );
  }
  return u;
}

/** fetch against the local smalt emulator. Never call global fetch directly. */
export async function smaltFetch(
  base: string,
  path: string,
  init?: RequestInit
): Promise<Response> {
  const url = assertLocalUrl(new URL(path, base).toString());
  // SHIM-COURT: default redirect:"error" — a 30x with an off-host Location
  // must not carry the request (or its body) past the air-gap guard, which
  // only validates the initial URL.
  return fetch(url, { redirect: "error", ...init });
}
