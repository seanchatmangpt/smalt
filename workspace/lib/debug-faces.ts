/**
 * Bench/debug route-face gate (EXPL7-R1, E7-3).
 *
 * The bench-lane debug faces — /api/v1/stream ?stats/?drift + storm POST,
 * /api/v1/ingest GET, /api/bench/isr-revalidate POST, /api/bench/isr-stats
 * POST — were self-declared bench-lane surfaces with nothing gating them to
 * bench runs (EXPL-7 E7-3). Gate: they answer 404 unless the server was
 * started with SMALT_DEBUG_FACES=1. Bench lanes that exercise them (N-6/N-7)
 * must set SMALT_DEBUG_FACES=1 when launching the Next server.
 */

export function debugFacesEnabled(): boolean {
  return process.env.SMALT_DEBUG_FACES === "1";
}

/** Typed 404 for a gated face — indistinguishable from a missing route. */
export function debugFaceDisabled(): Response {
  return Response.json({ error: "not_found" }, { status: 404 });
}

/**
 * Dev-plane gate (KD-173C close): the ingest POST face's dev-default HMAC key
 * (`n4-dev-key`, KD-173) is admitted ONLY when the server was started with
 * SMALT_DEV_PLANE=1. Any other startup (SMALT_DEV_PLANE unset or prod-pinned)
 * refuses the default key with a typed 503 — a provisioned
 * SMALT_INGEST_HMAC_KEY is unaffected on every plane.
 */
// KD-COVERS: KD-173
export function devPlaneEnabled(): boolean {
  return process.env.SMALT_DEV_PLANE === "1";
}

/** Typed 503 for the dev-default ingest key on a non-dev plane (KD-173). */
export function devDefaultKeyRefused(): Response {
  return Response.json(
    {
      error: "dev_default_key_refused",
      detail:
        "SMALT_INGEST_HMAC_KEY unset and SMALT_DEV_PLANE!=1: the public-source dev-default HMAC key is not admitted; provision SMALT_INGEST_HMAC_KEY or start with SMALT_DEV_PLANE=1",
    },
    { status: 503, headers: { "retry-after": "0" } },
  );
}
