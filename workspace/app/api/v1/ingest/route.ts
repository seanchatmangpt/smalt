// N-4 lifecycle stress lane: streaming ingest route handler (self-contained).
//
// Env config (documented contract):
//   SMALT_INGEST_HMAC_KEY   HMAC-SHA256 secret (default: "n4-dev-key")
//   SMALT_RATE_CAPACITY     token bucket capacity  (default: 20000)
//   SMALT_RATE_REFILL       tokens refilled per second (default: 5000)
//
// Auth: x-smalt-signature = hex HMAC-SHA256 over the RAW request body.
//   401 on missing/invalid signature.
// Rate limit: in-memory token bucket (module singleton), 429 on exhaustion.
// Success: 202 { accepted: true, bytes: <n> }.
// GET on this route = debug court surface: bucket counters + heap snapshot.

import { createHmac, timingSafeEqual } from "node:crypto";

// Debug-face gate (EXPL7-R1 E7-3): the GET debug surface answers 404 unless
// the server was started with SMALT_DEBUG_FACES=1 (bench lanes set it).
// Dev-plane gate (KD-173C): the dev-default HMAC key is refused with 503
// unless the server was started with SMALT_DEV_PLANE=1.
import {
  debugFacesEnabled,
  debugFaceDisabled,
  devPlaneEnabled,
  devDefaultKeyRefused,
} from "../../../../lib/debug-faces.ts";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MAX_BODY_BYTES = 8 * 1024 * 1024;

// ---- token bucket (process-global singleton) ----
const CAPACITY = Number(process.env.SMALT_RATE_CAPACITY ?? 20000);
const REFILL_PER_SEC = Number(process.env.SMALT_RATE_REFILL ?? 5000);
let tokens = CAPACITY;
let lastRefill = Date.now();
let accepted = 0;
let rejected401 = 0;
let rejected429 = 0;

function refill(): void {
  const now = Date.now();
  const elapsed = (now - lastRefill) / 1000;
  if (elapsed > 0) {
    tokens = Math.min(CAPACITY, tokens + elapsed * REFILL_PER_SEC);
    lastRefill = now;
  }
}

function takeToken(): boolean {
  refill();
  if (tokens >= 1) {
    tokens -= 1;
    accepted += 1;
    return true;
  }
  rejected429 += 1;
  return false;
}

// ---- POST: streaming ingest ----
export async function POST(req: Request): Promise<Response> {
  const key = process.env.SMALT_INGEST_HMAC_KEY ?? "n4-dev-key";
  const sig = req.headers.get("x-smalt-signature") ?? "";

  // KD-173C dev-plane gate: refuse the public-source dev-default key on any
  // non-dev plane (typed 503) BEFORE signature verification. A provisioned
  // SMALT_INGEST_HMAC_KEY is admitted on every plane; with SMALT_DEV_PLANE=1
  // the dev posture is preserved end to end.
  if (key === "n4-dev-key" && !devPlaneEnabled()) {
    return devDefaultKeyRefused();
  }

  // Stream the raw body chunk-by-chunk; HMAC over the raw bytes.
  const chunks: Uint8Array[] = [];
  let total = 0;
  const body = req.body;
  if (body) {
    const reader = body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value) {
        total += value.byteLength;
        if (total > MAX_BODY_BYTES) {
          try {
            await reader.cancel();
          } catch {
            /* stream already closed */
          }
          return Response.json(
            { error: "payload_too_large", bytes: total },
            { status: 413 },
          );
        }
        chunks.push(value);
      }
    }
  }
  const raw = concatenate(chunks, total);

  const expected = createHmac("sha256", key).update(raw).digest("hex");
  if (
    sig.length !== expected.length ||
    !timingSafeEqual(Buffer.from(sig, "utf8"), Buffer.from(expected, "utf8"))
  ) {
    rejected401 += 1;
    return Response.json({ error: "invalid_signature" }, { status: 401 });
  }

  if (!takeToken()) {
    return Response.json(
      { error: "rate_limited" },
      { status: 429, headers: { "retry-after": "1" } },
    );
  }

  return Response.json(
    { accepted: true, bytes: total },
    { status: 202, headers: { "x-smalt-ingest-bytes": String(total) } },
  );
}

function concatenate(chunks: Uint8Array[], total: number): Buffer {
  const out = Buffer.allocUnsafe(total);
  let off = 0;
  for (const c of chunks) {
    out.set(c, off);
    off += c.byteLength;
  }
  return out;
}

// ---- GET: debug court surface (gated, E7-3) ----
export async function GET(): Promise<Response> {
  if (!debugFacesEnabled()) return debugFaceDisabled();
  refill();
  return Response.json(
    {
      capacity: CAPACITY,
      refillPerSec: REFILL_PER_SEC,
      tokens,
      accepted,
      rejected401,
      rejected429,
      heap: process.memoryUsage(),
    },
    { status: 200 },
  );
}
