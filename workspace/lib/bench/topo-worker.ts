/// N-5 compute-saturation worker. Plain JS (Wasm-free). Wasm status: PENDING —
/// the AtomVM sim mode ships no wasm .avm (honestly noted; no wasm output is
/// wired into this worker as of v26.10.14).
///
/// Contract (page <-> worker):
///   page -> worker: { type: "run", buffer }  (buffer TRANSFERRED, zero-copy)
///   worker -> page: { type: "mem", usedJSHeapSize, ts }
///   worker -> page: { type: "progress", iterations, edgesScanned, elapsedMs }
///   worker -> page: { type: "done", iterations, edgesScanned, elapsedMs }
///
/// The transferred buffer is an edge list: uint32 [from, to] pairs over a
/// generated 50k-node DAG. Edges are constrained from < to, so the graph is
/// acyclic by construction and Kahn's algorithm terminates.

const workerSelf = globalThis as unknown as {
  postMessage(m: unknown): void;
  onmessage: ((ev: MessageEvent) => void) | null;
};
export {};

const COMPUTE_MS = 15_000;
const MEM_POLL_MS = 500;

/** One full Kahn topological sort over the transferred edge buffer. */
function kahnTopoSort(
  edges: Uint32Array,
  n: number,
): { orderLen: number; scans: number } {
  const numEdges = edges.length / 2;
  const indeg = new Uint32Array(n);
  const adjStart = new Uint32Array(n + 1);
  const adj = new Uint32Array(numEdges);

  // CSR adjacency: count out-degrees, prefix-sum, scatter.
  for (let e = 0; e < numEdges; e++) adjStart[edges[2 * e] + 1]++;
  for (let v = 0; v < n; v++) adjStart[v + 1] += adjStart[v];
  const cursor = adjStart.slice();
  for (let e = 0; e < numEdges; e++) adj[cursor[edges[2 * e]]++] = edges[2 * e + 1];

  // Kahn: FIFO of zero in-degree nodes.
  for (let e = 0; e < numEdges; e++) indeg[edges[2 * e + 1]]++;
  const queue = new Uint32Array(n);
  let qh = 0;
  let qt = 0;
  let scans = 0;
  for (let v = 0; v < n; v++) if (indeg[v] === 0) queue[qt++] = v;
  let emitted = 0;
  while (qh < qt) {
    const u = queue[qh++];
    emitted++;
    for (let p = adjStart[u]; p < adjStart[u + 1]; p++) {
      if (--indeg[adj[p]] === 0) queue[qt++] = adj[p];
      scans++;
    }
  }
  return { orderLen: emitted, scans };
}

workerSelf.onmessage = (ev: MessageEvent) => {
  const msg = ev.data;
  if (msg.type !== "run") return;
  const buffer: ArrayBuffer = msg.buffer as ArrayBuffer;
  const edges = new Uint32Array(buffer);
  let maxNode = 0;
  for (let i = 0; i < edges.length; i++) if (edges[i] > maxNode) maxNode = edges[i];
  const n = maxNode + 1;

  const start = performance.now();
  let iterations = 0;
  let scans = 0;

  const memTimer = setInterval(() => {
    const mem = (performance as unknown as { memory?: { usedJSHeapSize: number } })
      .memory;
    workerSelf.postMessage({
      type: "mem",
      usedJSHeapSize: mem ? Math.round(mem.usedJSHeapSize) : -1,
      ts: Date.now(),
    });
  }, MEM_POLL_MS);

  while (performance.now() - start < COMPUTE_MS) {
    const r = kahnTopoSort(edges, n);
    iterations++;
    scans += r.scans;
    workerSelf.postMessage({
      type: "progress",
      iterations,
      edgesScanned: scans,
      elapsedMs: Math.round(performance.now() - start),
    });
  }

  clearInterval(memTimer);
  workerSelf.postMessage({
    type: "done",
    iterations,
    edgesScanned: scans,
    elapsedMs: Math.round(performance.now() - start),
  });
};
