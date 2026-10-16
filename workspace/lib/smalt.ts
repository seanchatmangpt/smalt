/**
 * Air-gap base URLs. The ONLY network hosts this console may contact.
 * Configure via env: NEXT_PUBLIC_SMALT_ARM, NEXT_PUBLIC_SMALT_EGRESS.
 */
export const SMALT_ARM =
  process.env.NEXT_PUBLIC_SMALT_ARM ?? "http://127.0.0.1:9443";
export const SMALT_EGRESS =
  process.env.NEXT_PUBLIC_SMALT_EGRESS ?? "http://127.0.0.1:8443";

/** Air-gap guard: refuse any URL that is not a localhost smalt endpoint. */
export function assertLocalUrl(url: string): URL {
  const u = new URL(url, typeof window === "undefined" ? SMALT_ARM : window.location.origin);
  if (!["127.0.0.1", "localhost", "[::1]", "::1"].includes(u.hostname)) {
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
  return fetch(url, init);
}
