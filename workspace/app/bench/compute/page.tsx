"use client";

/// N-5 compute-saturation bench page (/bench/compute).
///
/// Main thread: interactive tab/chart surface with a requestAnimationFrame FPS
/// counter; input-latency probe hooks (input event -> next rAF) exposed to the
/// Playwright/CDP driver via `window.__n5`.
/// Worker thread: dedicated worker (lib/bench/topo-worker.ts) runs a 15 s
/// compute-heavy topological sort over a generated 50k-node DAG edge list,
/// transferred zero-copy (50 MB ArrayBuffer via postMessage transfer list).

import { useCallback, useEffect, useRef, useState } from "react";

const NODES = 50_000;
const BUFFER_BYTES = 50 * 1024 * 1024; // 50 MB edge list, transferred zero-copy

type WorkerMsg =
  | { type: "mem"; usedJSHeapSize: number; ts: number }
  | { type: "progress"; iterations: number; edgesScanned: number; elapsedMs: number }
  | { type: "done"; iterations: number; edgesScanned: number; elapsedMs: number };

type LatencySample = { dispatchMs: number; rafMs: number; latencyMs: number };

/** Generate the DAG edge list (from < to guarantees acyclic by construction). */
function generateDagEdges(): Uint32Array {
  const numEdges = BUFFER_BYTES / 8; // uint32 [from, to] pairs -> 50 MB total
  const edges = new Uint32Array(numEdges * 2);
  let s = 0x9e3779b9;
  const rnd = () => {
    s ^= s << 13;
    s ^= s >>> 17;
    s ^= s << 5;
    return s >>> 0;
  };
  for (let e = 0; e < numEdges; e++) {
    const u = rnd() % NODES;
    const span = NODES - 1 - u;
    const v = u + 1 + (span > 0 ? rnd() % span : 0);
    edges[2 * e] = u;
    edges[2 * e + 1] = v;
  }
  return edges;
}

export default function BenchComputePage() {
  const [tab, setTab] = useState<"chart" | "table" | "log">("chart");
  const [fps, setFps] = useState(0);
  const [workerState, setWorkerState] = useState<
    "idle" | "running" | "done" | "terminated"
  >("idle");
  const [workerMem, setWorkerMem] = useState(-1);
  const [iterations, setIterations] = useState(0);
  const [log, setLog] = useState<string[]>([]);
  const [latencies, setLatencies] = useState<LatencySample[]>([]);

  const workerRef = useRef<Worker | null>(null);
  const bufferRef = useRef<ArrayBuffer | null>(null);
  const framesRef = useRef({ total: 0, dropped: 0, last: 0, windowBase: 0 });
  const latencyRef = useRef<LatencySample[]>([]);
  const pendingInputRef = useRef<number | null>(null);

  const pushLog = useCallback((line: string) => {
    setLog((prev) => [`${Date.now()} ${line}`, ...prev].slice(0, 50));
  }, []);

  // requestAnimationFrame FPS counter with dropped-frame accounting.
  useEffect(() => {
    let raf = 0;
    const tick = (t: number) => {
      const f = framesRef.current;
      if (f.last > 0) {
        f.total++;
        if (t - f.last > 20) f.dropped++; // >20 ms gap = dropped frame (60 Hz = 16.6 ms budget)
      }
      f.last = t;
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, []);

  // 1 Hz UI refresh of FPS + latency samples.
  useEffect(() => {
    const iv = setInterval(() => {
      const f = framesRef.current;
      setFps(f.total - f.windowBase);
      f.windowBase = f.total;
      setLatencies(latencyRef.current.slice(-200));
    }, 1000);
    return () => clearInterval(iv);
  }, []);

  // Input-latency probe: CDP-dispatched input -> capture listener -> next rAF.
  useEffect(() => {
    const onInput = () => {
      if (pendingInputRef.current === null) return;
      const dispatchMs = pendingInputRef.current;
      pendingInputRef.current = null;
      requestAnimationFrame((rafMs) => {
        latencyRef.current.push({
          dispatchMs,
          rafMs,
          latencyMs: rafMs - dispatchMs,
        });
      });
    };
    window.addEventListener("mousedown", onInput, true);
    window.addEventListener("keydown", onInput, true);
    window.addEventListener("wheel", onInput, true);
    return () => {
      window.removeEventListener("mousedown", onInput, true);
      window.removeEventListener("keydown", onInput, true);
      window.removeEventListener("wheel", onInput, true);
    };
  }, []);

  const startWorker = useCallback(() => {
    if (workerRef.current) return;
    const edges = generateDagEdges();
    const buffer = edges.buffer as ArrayBuffer;
    bufferRef.current = buffer;
    const worker = new Worker(
      new URL("../../../lib/bench/topo-worker.ts", import.meta.url),
    );
    worker.onmessage = (ev: MessageEvent<WorkerMsg>) => {
      const m = ev.data;
      if (m.type === "mem") setWorkerMem(m.usedJSHeapSize);
      else if (m.type === "progress") setIterations(m.iterations);
      else if (m.type === "done") {
        setIterations(m.iterations);
        setWorkerState("done");
        pushLog(`worker done: ${m.iterations} iters, ${m.edgesScanned} scans in ${m.elapsedMs} ms`);
      }
    };
    worker.postMessage({ type: "run", buffer }, [buffer]);
    setWorkerState("running");
    pushLog("posted 50 MB ArrayBuffer to worker (transfer list, zero-copy; detached on main thread)");
    workerRef.current = worker;
  }, [pushLog]);

  // Auto-boot the worker 1.5 s after mount so the driver can poll readiness.
  useEffect(() => {
    const t = setTimeout(startWorker, 1500);
    return () => clearTimeout(t);
  }, [startWorker]);

  const terminateWorker = useCallback(() => {
    if (!workerRef.current) return;
    workerRef.current.terminate();
    workerRef.current = null;
    bufferRef.current = null;
    setWorkerState("terminated");
    pushLog("worker terminated; awaiting heap reclaim");
  }, [pushLog]);

  // Driver bridge, refreshed every render so closures see latest state.
  useEffect(() => {
    (window as unknown as Record<string, unknown>).__n5 = {
      state: () => workerState,
      fps: () => fps,
      workerMem: () => workerMem,
      iterations: () => iterations,
      latencies: () => latencyRef.current,
      droppedFrames: () => framesRef.current.dropped,
      totalFrames: () => framesRef.current.total,
      baselineHeap: () =>
        (performance as unknown as { memory?: { usedJSHeapSize: number } }).memory
          ?.usedJSHeapSize ?? -1,
      terminate: () => terminateWorker(),
    };
  });

  const workerBusy = workerState === "running";
  const series = Array.from({ length: 60 }, (_, i) => 40 + 30 * Math.sin(i / 6));
  const display = series.map((v) => (workerBusy ? v + (iterations % 7) : v));

  return (
    <main style={{ padding: 24, fontFamily: "monospace" }}>
      <h1 style={{ fontSize: 18 }}>N-5 Compute Saturation Bench</h1>
      <section style={{ display: "flex", gap: 12, margin: "12px 0" }}>
        {(["chart", "table", "log"] as const).map((t) => (
          <button
            key={t}
            data-tab={t}
            onClick={() => setTab(t)}
            style={{
              padding: "6px 14px",
              border: "1px solid #555",
              background: tab === t ? "#345" : "#222",
              color: "#eee",
            }}
          >
            {t}
          </button>
        ))}
        <button
          data-action="terminate"
          onClick={terminateWorker}
          style={{ padding: "6px 14px" }}
        >
          terminate worker
        </button>
      </section>

      <section style={{ margin: "12px 0", fontSize: 13 }}>
        <div>
          worker: {workerState} | topo iterations: {iterations}
        </div>
        <div>
          fps: {fps} | dropped: {framesRef.current.dropped}
        </div>
        <div>worker heap: {workerMem} B</div>
      </section>

      {tab === "chart" && (
        <section aria-label="chart">
          <svg width="720" height="240" role="img">
            {display.map((v, i) => (
              <rect
                key={i}
                x={i * 12}
                y={240 - v}
                width={10}
                height={v}
                fill={workerBusy ? "#4a6fa5" : "#777"}
              />
            ))}
          </svg>
        </section>
      )}
      {tab === "table" && (
        <table>
          <tbody>
            {latencies.slice(-10).map((s, i) => (
              <tr key={i}>
                <td>#{i}</td>
                <td>{s.latencyMs.toFixed(1)} ms</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {tab === "log" && (
        <ul aria-label="event log">
          {log.map((l, i) => (
            <li key={i}>{l}</li>
          ))}
        </ul>
      )}
    </main>
  );
}
