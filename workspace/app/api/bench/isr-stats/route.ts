// N-6 lane: ISR regeneration witness endpoint.
// GET  -> {regenerations, staleServed, regenerationsRuntime, perSlug, ...}
// POST -> driver reports wire-observed stale-served count / resets the log.

import {
  readStats,
  recordStaleServed,
  resetEvents,
  EVENTS_PATH,
} from "@/lib/bench/isr-counter";
import { debugFacesEnabled, debugFaceDisabled } from "@/lib/debug-faces";

export const dynamic = "force-dynamic";

export async function GET() {
  return Response.json({ eventsPath: EVENTS_PATH, ...readStats() });
}

export async function POST(req: Request) {
  // Mutating face (reset / stale-report) — gated, EXPL7-R1 E7-3.
  if (!debugFacesEnabled()) return debugFaceDisabled();
  const body = await req.json().catch(() => ({}));
  if (body.reset === true) {
    resetEvents();
    return Response.json({ ok: true, reset: true });
  }
  if (typeof body.staleServed === "number") {
    recordStaleServed(body.staleServed);
    return Response.json({ ok: true, staleServed: body.staleServed });
  }
  return Response.json({ ok: false, error: "nothing to record" }, { status: 400 });
}
