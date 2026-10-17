// route.ts — N-2 lane /metrics sidecar: event-loop delay sampled in the SAME
// Next server process that executes the bench server actions.
import { monitorEventLoopDelay } from "node:perf_hooks";
type IntervalHistogram = ReturnType<typeof monitorEventLoopDelay>;

const ELD = monitorEventLoopDelay({ resolution: 10 });
ELD.enable();

function percentileNs(h: IntervalHistogram, p: number): number {
  // IntervalHistogram.percentile() takes a percentile in [0, 100).
  return h.percentile(p);
}

export async function GET(req: Request) {
  const shouldReset = new URL(req.url).searchParams.get("reset") === "1";
  const meanMs = ELD.mean / 1e6;
  const p50Ms = percentileNs(ELD, 50) / 1e6;
  const p90Ms = percentileNs(ELD, 90) / 1e6;
  const p99Ms = percentileNs(ELD, 99) / 1e6;
  const maxMs = ELD.max / 1e6;

  // Post-read reset gives the poller per-interval windows instead of a
  // process-lifetime average that would dilute storm-period spikes.
  if (shouldReset) {
    ELD.reset();
  }

  return Response.json({
    ok: true,
    event_loop_delay_ms: {
      mean: meanMs,
      p50: p50Ms,
      p90: p90Ms,
      p99: p99Ms,
      max: maxMs,
    },
    count: ELD.count,
    rss_mb: process.memoryUsage().rss / (1024 * 1024),
    uptime_s: process.uptime(),
  });
}

export const dynamic = "force-dynamic";
