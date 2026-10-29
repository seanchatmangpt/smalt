/**
 * Shared plain-node air-gap guard for workspace court/bench harnesses.
 *
 * Provenance: mirrors the canonical guard in lib/smalt.ts assertLocalUrl
 * (localhost-only hostnames). This copy exists because the plain-node courts
 * (e2e-court.mjs et al.) run without a TS loader — if lib/smalt.ts tightens
 * (e.g. a new forbidden host), update BOTH copies; a premise-drift court leg
 * comparing the two is the registered close condition (EXPL7-R1 E7-4).
 */

export function assertLocalUrl(url) {
  const u = new URL(url);
  if (!["127.0.0.1", "localhost", "[::1]", "::1"].includes(u.hostname)) {
    throw new Error(`Air-gap violation: refused non-local host "${u.hostname}"`);
  }
  return u;
}
