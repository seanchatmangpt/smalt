// KD-171R — shared caller gate for the BFF sync/state face.
//
// KD-COVERS: KD-171
//
// Two halves, composed in assertSyncCaller:
//
//   1. Loopback posture (EXPL7-R1 E7-1, moved here verbatim from route.ts so
//      the court and any future BFF face share one gate): Host (port-stripped)
//      and, when present, Origin must be loopback hosts, else typed 403
//      `sync_state_non_loopback`.
//
//   2. Shared-secret caller gate (KD-171R): when SMALT_BFF_SYNC_SECRET is set,
//      the request MUST carry header `x-smalt-sync-secret` whose value equals
//      the env secret — compared with node:crypto timingSafeEqual over a
//      length-prefixed buffer (the ingest HMAC gate pattern,
//      workspace/app/api/v1/ingest/route.ts). Missing -> typed 403
//      `sync_state_missing_secret`; wrong -> typed 403
//      `sync_state_invalid_secret`. When the env is UNSET the secret half is
//      inert and the face keeps the KD-171 loopback-open dev posture (the
//      same typed dev-default law as KD-173's SMALT_INGEST_HMAC_KEY posture).
//
// The gate is best-effort vs header spoofing below the loopback boundary;
// the air-gap is the trust boundary (KD-169 class), this gate hardens the
// caller boundary inside it.
import { timingSafeEqual } from "node:crypto";

export const SYNC_SECRET_HEADER = "x-smalt-sync-secret";

const LOOPBACK_HOSTS = ["127.0.0.1", "localhost", "[::1]", "::1"];

// BK-TOPO WI-1: operator-declared extra hosts (comma-separated) admitted
// alongside loopback when non-empty; unset/empty -> loopback-only
// (byte-identical posture). Never disables the gate — named hosts only,
// no wildcards.
function hostAllowed(hostName: string): boolean {
  if (LOOPBACK_HOSTS.includes(hostName)) return true;
  const raw = process.env.SMALT_ALLOWED_HOSTS;
  if (raw === undefined || raw.trim() === "") return false;
  const extra = raw
    .split(",")
    .map((h) => h.trim().toLowerCase())
    .filter((h) => h !== "");
  return extra.includes(hostName.toLowerCase());
}

export function assertLoopbackCaller(req: Request): Response | null {
  const host = req.headers.get("host");
  if (host === null) {
    return Response.json(
      { error: "sync_state_non_loopback", detail: "missing host header" },
      { status: 403 }
    );
  }
  // strip an explicit port for comparison ("127.0.0.1:3100" -> "127.0.0.1")
  const hostName = host.replace(/:\d+$/, "");
  if (!hostAllowed(hostName)) {
    return Response.json(
      { error: "sync_state_non_loopback", detail: `non-loopback host "${hostName}"` },
      { status: 403 }
    );
  }
  const origin = req.headers.get("origin");
  if (origin !== null) {
    try {
      const o = new URL(origin);
      if (!hostAllowed(o.hostname)) {
        return Response.json(
          { error: "sync_state_non_loopback", detail: `non-loopback origin "${o.hostname}"` },
          { status: 403 }
        );
      }
    } catch {
      return Response.json(
        { error: "sync_state_non_loopback", detail: "unparseable origin parse" },
        { status: 403 }
      );
    }
  }
  return null;
}

// Timing-safe comparison of the presented header against the env secret.
// Length prefix: timingSafeEqual throws on length mismatch, so compare a
// length-hiding padded form (ingest gate pattern).
function secretMatches(presented: string, secret: string): boolean {
  const a = Buffer.from(presented, "utf8");
  const b = Buffer.from(secret, "utf8");
  if (a.length !== b.length) {
    // still burn a comparison against a padded buffer so missing vs wrong is
    // not distinguishable by timing
    timingSafeEqual(b, b);
    return false;
  }
  return timingSafeEqual(a, b);
}

/**
 * Full caller gate: loopback posture + (when SMALT_BFF_SYNC_SECRET is set)
 * the shared-secret check. Returns the typed 403 Response to return, or null
 * when the caller may proceed.
 */
export function assertSyncCaller(req: Request): Response | null {
  const loop = assertLoopbackCaller(req);
  if (loop !== null) return loop;

  const secret = process.env.SMALT_BFF_SYNC_SECRET;
  if (secret === undefined || secret === "") return null; // dev posture preserved

  const presented = req.headers.get(SYNC_SECRET_HEADER);
  if (presented === null) {
    return Response.json(
      { error: "sync_state_missing_secret", detail: `missing ${SYNC_SECRET_HEADER} header` },
      { status: 403 }
    );
  }
  if (!secretMatches(presented, secret)) {
    return Response.json(
      { error: "sync_state_invalid_secret", detail: `invalid ${SYNC_SECRET_HEADER} header` },
      { status: 403 }
    );
  }
  return null;
}
