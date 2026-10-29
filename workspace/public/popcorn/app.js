// Operator leg panel: renders the same #status text the smoke gate reads into
// a readable table. No fetch, no framework; polls #status textContent only.
// #status itself is the gate's contract and is never touched by this script.
const TOKEN_RE = /^(.+?)=(OK|SKIP|FAIL)(?:\((.*)\))?$/s;

// --- browser-legs instrumentation (W5-F) -------------------------------------
// Boot ms = wall time from script eval (page-load proxy) to the first composed
// #status line containing "live=" (the same line the smoke gate reads as
// SMOKE_RECEIPT). Per-poll deltas recorded alongside. Rows leave the page via
// console.log("BROWSER_LEG_ROW ..."), which scripts/browser_smoke.mjs pipes to
// stdout — no fetch, no egress. Bounded: max 3 rows per invocation.
const __t0 = performance.now();
window.__legTimings = { t0: __t0, pollDeltasMs: [], boot_ms: null, legs_rendered: 0, rows: 0 };
let __lastPollAt = null;

function __emitRow(legsCount) {
  const t = window.__legTimings;
  if (t.rows >= 3) return; // bounded: max 3 rows per invocation
  t.rows += 1;
  t.legs_rendered = legsCount;
  const row = {
    lane: "browser-legs",
    boot_ms: Math.round(t.boot_ms * 100) / 100,
    legs_rendered: legsCount,
    ts: new Date().toISOString(),
  };
  console.log(
    "BROWSER_LEG_ROW " +
      JSON.stringify({ ...row, poll_deltas_ms: t.pollDeltasMs.slice(0, 20) }),
  );
}
// -----------------------------------------------------------------------------

function parse(text) {
  if (!text) return [];
  return text
    .split(";")
    .map((t) => t.trim())
    .map((t) => t.match(TOKEN_RE))
    .filter(Boolean)
    .map((m) => ({ label: m[1].trim(), state: m[2], detail: m[3] ?? "" }));
}

const CHIP = {
  OK: ["#1a7f37", "#e6ffec"],
  SKIP: ["#9a6700", "#fff8c5"],
  FAIL: ["#cf222e", "#ffebe9"],
};

// Expanded rows persist across the 200ms re-render, keyed by leg label.
const expanded = new Set();

function __memSummary() {
  const m = window.__browserMem;
  if (!m) return "";
  const parts = [];
  if (m.jsUsedBytes != null)
    parts.push(`js ${(m.jsUsedBytes / 1048576).toFixed(1)}MiB`);
  if (m.pageBytes != null)
    parts.push(`page ${(m.pageBytes / 1048576).toFixed(1)}MiB`);
  if (m.wasmBytes != null)
    parts.push(`wasm ${(m.wasmBytes / 1048576).toFixed(1)}MiB`);
  return parts.length ? ` — mem ${parts.join("/")} of 32MiB budget` : "";
}

function render(legs) {
  const host = document.getElementById("legs");
  if (!host) return;
  host.textContent = "";

  const summary = document.createElement("div");
  summary.id = "legs-summary";
  summary.style.cssText =
    'font:13px ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;' +
    "padding:6px 8px 2px;color:#e6edf3;";
  const ok = legs.filter((l) => l.state === "OK").length;
  const skip = legs.filter((l) => l.state === "SKIP").length;
  const fail = legs.filter((l) => l.state === "FAIL").length;
  const boot = window.__legTimings.boot_ms;
  summary.textContent =
    `${ok} OK / ${skip} SKIP / ${fail} FAIL of ${legs.length}` +
    (boot != null ? ` — boot ${Math.round(boot)} ms` : "") +
    __memSummary() +
    ` — updated ${new Date().toLocaleTimeString()}`;
  host.appendChild(summary);

  const table = document.createElement("table");
  table.id = "legs-table";
  const style = table.style;
  style.borderCollapse = "collapse";
  style.fontFamily =
    'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace';
  style.fontSize = "13px";
  style.background = "#0d1117";
  style.color = "#e6edf3";
  style.padding = "8px";

  for (const leg of legs) {
    const [fg, bg] = CHIP[leg.state] ?? CHIP.SKIP;
    const tr = document.createElement("tr");
    tr.style.cursor = "pointer";
    tr.title = "click to toggle detail";
    tr.addEventListener("click", () => {
      if (expanded.has(leg.label)) expanded.delete(leg.label);
      else expanded.add(leg.label);
      render(parse(document.getElementById("status")?.textContent ?? ""));
    });

    const tdLabel = document.createElement("td");
    tdLabel.textContent = (expanded.has(leg.label) ? "▾ " : "▸ ") + leg.label;
    tdLabel.style.cssText = "padding:4px 10px;white-space:pre;";

    const tdChip = document.createElement("td");
    tdChip.style.cssText = `padding:4px 10px;`;
    const chip = document.createElement("span");
    chip.textContent = leg.state;
    chip.style.cssText = `display:inline-block;padding:1px 8px;border-radius:10px;font-weight:600;color:${fg};background:${bg};`;
    tdChip.appendChild(chip);

    const tdDetail = document.createElement("td");
    tdDetail.textContent = leg.detail;
    tdDetail.style.cssText =
      "padding:4px 10px;color:#8b949e;max-width:60ch;overflow-wrap:anywhere;";

    tr.append(tdLabel, tdChip, tdDetail);
    table.appendChild(tr);

    if (expanded.has(leg.label)) {
      const raw = document.createElement("tr");
      const rawTd = document.createElement("td");
      rawTd.colSpan = 3;
      rawTd.textContent = leg.detail || "(no detail)";
      rawTd.style.cssText =
        "padding:4px 10px 8px 24px;color:#c9d1d9;background:#161b22;" +
        "white-space:pre-wrap;overflow-wrap:anywhere;";
      raw.appendChild(rawTd);
      table.appendChild(raw);
    }
  }
  if (legs.length > 0) host.appendChild(table);
}

function poll() {
  const now = performance.now();
  if (__lastPollAt != null) {
    window.__legTimings.pollDeltasMs.push(Math.round((now - __lastPollAt) * 100) / 100);
  }
  __lastPollAt = now;

  const text = document.getElementById("status")?.textContent ?? "";
  const legs = parse(text);
  if (legs.length > 0) render(legs);

  const t = window.__legTimings;
  if (t.boot_ms == null && text.includes("live=")) {
    t.boot_ms = now - __t0;
    __emitRow(legs.length);
  }
}

poll();
setInterval(poll, 200);

// --- in-browser memory instrumentation (S9) ----------------------------------
// Measured where the ceiling binds: inside the browser, after the boot receipt
// settles. Three surfaces, best-effort and honestly typed:
//   1. performance.memory (Chrome-only): main-thread JS heap
//      (usedJSHeapSize/totalJSHeapSize). Does NOT include the BEAM worker.
//   2. performance.measureUserAgentSpecificMemory(): whole-page RSS-class bytes
//      (includes workers + WASM) — only under cross-origin isolation, which the
//      smoke server provides via COOP/COEP.
//   3. WebAssembly.Memory size via Popcorn globals: best-effort; Popcorn runs
//      the BEAM in a Worker and exposes no memory handle on window, so this is
//      probed (globalThis.Popcorn / Module) and reported loudly when absent.
// Emits exactly one console BROWSER_MEM_ROW per run; also surfaces heap bytes
// in the #legs-summary panel line. #status is never touched.
const MEM_BUDGET_BYTES = 32 * 1024 * 1024;
const mem = {
  jsUsedBytes: null,
  jsTotalBytes: null,
  pageBytes: null,
  wasmBytes: null,
  wasmSurface: "unreachable: no WebAssembly.Memory handle exposed on window",
  measured: false,
};

function __readJsHeap() {
  const pm = performance.memory;
  if (pm && typeof pm.usedJSHeapSize === "number") {
    mem.jsUsedBytes = pm.usedJSHeapSize;
    mem.jsTotalBytes = pm.totalJSHeapSize;
  }
}

async function __readPageMemory() {
  try {
    if (globalThis.crossOriginIsolated && performance.measureUserAgentSpecificMemory) {
      const r = await performance.measureUserAgentSpecificMemory();
      mem.pageBytes = r.bytes;
    }
  } catch (e) {
    mem.wasmSurface = "unreachable: measureUserAgentSpecificMemory threw: " + e;
  }
}

function __readWasmMemory() {
  // Best-effort probe of any Popcorn-exposed memory handle.
  for (const [name, obj] of [
    ["globalThis.Popcorn", globalThis.Popcorn],
    ["globalThis.Module", globalThis.Module],
  ]) {
    const m =
      obj?.memory ?? obj?.wasmMemory ?? obj?.HEAP8?.buffer ?? obj?.instance?.exports?.memory;
    if (m instanceof WebAssembly.Memory) {
      mem.wasmBytes = m.buffer.byteLength;
      mem.wasmSurface = name + ".memory.buffer";
      return;
    }
  }
}

async function __measureMemory() {
  if (mem.measured) return;
  mem.measured = true;
  __readJsHeap();
  __readWasmMemory();
  await __readPageMemory();

  const memRow = {
    lane: "browser-mem",
    js_used_bytes: mem.jsUsedBytes,
    js_total_bytes: mem.jsTotalBytes,
    page_bytes: mem.pageBytes,
    wasm_bytes: mem.wasmBytes,
    wasm_surface: mem.wasmSurface,
    budget_bytes: MEM_BUDGET_BYTES,
    cross_origin_isolated: !!globalThis.crossOriginIsolated,
    ts: new Date().toISOString(),
  };
  console.log("BROWSER_MEM_ROW " + JSON.stringify(memRow));

  // Surface into the panel summary line (re-render will pick this up on the
  // next 200ms poll; stored so render() reads the latest value).
  window.__browserMem = mem;
}

// Trigger once, on the poll AFTER the boot receipt settles (live legs composed).
const __origEmitRow = __emitRow;
__emitRow = function (legsCount) {
  __origEmitRow(legsCount);
  __measureMemory();
};
