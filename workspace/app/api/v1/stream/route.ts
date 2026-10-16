// N-7 lifecycle stress lane: SSE stream route handler.
//
// Re-sync contract:
//   - Global monotonically increasing sequence numbers on delta events.
//   - One shared 50 ms ticker produces one global delta per tick, fanned
//     out to every connected client (each client sees a delta every 50 ms).
//   - Heartbeat comment every 5 s (`: hb <seq> <iso>`).
//   - Client sends `Last-Event-ID: <seq>`; server replays every ring entry
//     with seq > lastEventId (in order), then switches to live deltas.
//   - Ring buffer is bounded (SMALT_N7_RING, default 4096 entries ≈ 205 s
//     of coverage). Replay beyond ring span is a client-side gap.
//
// Storm control (same file, no lib/ edits):
//   POST /api/v1/stream with header `x-smalt-storm: abort`
//     → abruptly errors every connected ReadableStream controller
//       (server-side abort; the process and ring survive so the
//       Last-Event-ID replay path is exercised for real).
//   GET  /api/v1/stream?stats=1
//     → JSON { active, seq, ring_len, ring_span } for listener-leak and
//       accept-capacity accounting.

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

interface Delta {
  seq: number;
  ts: number;
}

const RING_SIZE = Number(process.env.SMALT_N7_RING ?? 4096);
const DELTA_MS = Number(process.env.SMALT_N7_DELTA_MS ?? 50);
const HEARTBEAT_MS = 5000;

// Module-global state — one process, one ring, one ticker.
const ring: Delta[] = [];
let seq = 0;
let nextClientId = 1;
const controllers = new Map<
  number,
  ReadableStreamDefaultController<Uint8Array>
>();

function ringPush(d: Delta): void {
  ring.push(d);
  if (ring.length > RING_SIZE) ring.shift();
}

let ticker: ReturnType<typeof setInterval> | null = null;
function ensureTicker(): void {
  if (ticker !== null) return;
  ticker = setInterval(() => {
    seq += 1;
    const d: Delta = { seq, ts: Date.now() };
    ringPush(d);
    if (clientsCount() === 0) return; // still record to ring while idle
    const frame = encoder.encode(`id: ${d.seq}\ndata: ${JSON.stringify(d)}\n\n`);
    for (const ctrl of controllers.values()) {
      try {
        ctrl.enqueue(frame);
        ctrl.enqueue(ENC_ZERO);
      } catch {
        controllers.delete(keyOf(ctrl));
      }
    }
  }, DELTA_MS);
  if (typeof ticker.unref === "function") ticker.unref();
}

// Zero-byte enqueue is a liveness probe: a closed/aborted controller
// throws, letting the sweep drop dead entries without waiting for
// request-signal abort delivery.
const ENC = new TextEncoder();
const encoder = ENC;
const ENC_ZERO = encoder.encode("");

function clientsCount(): number {
  return controllers.size;
}

// Reverse lookup is avoided: we key controllers by client id and store the
// id on the controller itself via a WeakMap-free side map.
const ctrlIds = new Map<ReadableStreamDefaultController<Uint8Array>, number>();
function keyOf(ctrl: ReadableStreamDefaultController<Uint8Array>): number {
  return ctrlIds.get(ctrl) ?? -1;
}

function replayFrom(lastEventId: number): Delta[] {
  return ring.filter((d) => d.seq > lastEventId);
}

export async function GET(req: Request): Promise<Response> {
  const url = new URL(req.url);

  if (url.searchParams.get("stats") !== null) {return stats();}
  if (url.searchParams.get("drift") !== null) {
    return Response.json({ seq, ring_len: ring.length, ts: Date.now() });
  }

  const lastEventIdHdr = req.headers.get("last-event-id");
  const lastEventId = lastEventIdHdr === null ? 0 : Number(lastEventIdHdr);
  if (lastEventIdHdr !== null && !Number.isFinite(lastEventId)) {
    return new Response("bad last-event-id\n", { status: 400 });
  }

  ensureTicker();

  const clientId = nextClientId++;
  let registered: ReadableStreamDefaultController<Uint8Array> | null = null;
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      registered = controller;
      let closed = false;
      const write = (s: string): void => {
        if (closed) throw new Error("closed");
        controller.enqueue(encoder.encode(s));
      };

      const finish = (): void => {
        if (closed) return;
        closed = true;
        controllers.delete(clientId);
        ctrlIds.delete(controller);
      };

      ctrlIds.set(controller, clientId);
      controllers.set(clientId, controller);

      try {
        write("retry: 1000\n\n");
        for (const d of replayFrom(lastEventId)) {
          write(`id: ${d.seq}\ndata: ${JSON.stringify(d)}\n\n`);
        }
      } catch {
        finish();
        return;
      }

      const hb = setInterval(() => {
        try {
          write(`: hb ${seq} ${new Date().toISOString()}\n\n`);
        } catch {
          clearInterval(hb);
          finish();
        }
      }, HEARTBEAT_MS);
      if (typeof hb.unref === "function") hb.unref();

      req.signal.addEventListener("abort", finish);
    },
    cancel() {
      controllers.delete(clientId);
      if (registered) ctrlIds.delete(registered);
    },
  });

  return new Response(stream, {
    headers: {
      "content-type": "text/event-stream",
      "cache-control": "no-cache, no-transform",
      connection: "keep-alive",
      "x-accel-buffering": "no",
    },
  });
}

function stats(): Response {
  return Response.json({
    active: clientsCount(),
    seq,
    ring_len: ring.length,
    ring_span: ring.length ? seq - ring[0].seq + 1 : 0,
  });
}

// Storm trigger: abruptly error every controller. Node tears the streams
// down mid-flight; clients observe a hard connection reset while the
// process (and the ring) survive — a genuine server-side abort.
export async function POST(req: Request): Promise<Response> {
  if (req.headers.get("x-smalt-storm") !== "abort") {
    return new Response("bad storm header\n", { status: 400 });
  }
  let aborted = 0;
  for (const ctrl of [...controllers.values()]) {
    aborted += 1;
    try {
      ctrl.error(new Error("storm-abort"));
    } catch {
      /* already closed */
    }
  }
  controllers.clear();
  ctrlIds.clear();
  return Response.json({ aborted });
}
