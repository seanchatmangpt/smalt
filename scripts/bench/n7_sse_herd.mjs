#!/usr/bin/env node
// N-7 lifecycle stress lane: SSE reconnection-herd driver.
//
// Phases: fd-ceiling check -> herd ramp -> steady -> storm (server-side
// abort of all SSE controllers) -> reconnect storm (exp backoff +
// Last-Event-ID replay) -> reconcile (gaplessness court).
//
// Usage:
//   node scripts/bench/n7_sse_herd.mjs \
//     --url http://127.0.0.1:3100/api/v1/stream \
//     --target 5000 \
//     --jsonl docs/jira/v26.10.14/bench/n7-sse-herd.jsonl

import { connect } from "node:net";
import { execFileSync } from "node:child_process";
import { appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

const args = process.argv.slice(2);
const arg = (n, d) => {
  const i = args.indexOf(n);
  return i >= 0 ? args[i + 1] : d;
};
const URL0 = arg("--url", "http://127.0.0.1:3100/api/v1/stream");
const TARGET = Number(arg("--target", "5000"));
const JSONL = arg("--jsonl", "docs/jira/v26.10.14/bench/n7-sse-herd.jsonl");
const RAMP_BATCH = Number(arg("--batch", "500"));
const BATCH_GAP_MS = Number(arg("--batch-gap", "300"));
const STEADY_MS = Number(arg("--steady", "6000"));
const SETTLE_MS = Number(arg("--settle", "5000"));
const RECONNECT_BUDGET_MS = Number(arg("--reconnect-budget", "30000"));

const u = new URL(URL0);
const origin = u.origin;
const streamPath = u.pathname;

mkdirSync(dirname(JSONL), { recursive: true });
function emit(row) {
  appendFileSync(
    JSONL,
    JSON.stringify({ lane: "n7", ts: new Date().toISOString(), ...row }) + "\n",
  );
}
const log = (...a) => console.log("[n7]", ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------- fd ceiling witness ----------
let ULIMIT_N = -1;
try {
  ULIMIT_N = Number(
    execFileSync("sh", ["-c", "ulimit -n"], { encoding: "utf8" }).trim(),
  );
} catch { /* keep -1 */ }

// ---------- raw SSE client (real socket, real parser, no mocks) ----------
class SseClient {
  constructor(id) {
    this.id = id;
    this.lastSeq = 0;
    this.gaps = 0;
    this.connects = 0;
    this.reconnects = 0;
    this.overflow = 0;
    this.permanent = false;
    this.everConnected = false;
    this.down = false;
    this._buf = "";
    this._hdrDone = false;
    this._sock = null;
    this._handlers = 0; // live event handlers on current socket (leak proxy)
  }

  connect(lastEventId, onDown) {
    this.down = false;
    this._buf = "";
    this._hdrDone = false;
    this.connects += 1;
    if (this.everConnected) this.reconnects += 1;

    const sock = connect({
      host: u.hostname,
      port: Number(u.port || 80),
    });
    this._sock = sock;
    this._handlers = 0;

    sock.on("connect", () => {
      const hdrs = [
        `GET ${streamPath} HTTP/1.1`,
        `Host: ${u.hostname}:${u.port || 80}`,
        "Accept: text/event-stream",
        "Cache-Control: no-cache",
      ];
      if (lastEventId > 0) hdrs.push(`Last-Event-ID: ${lastEventId}`);
      hdrs.push("Connection: close", "", "");
      sock.write(hdrs.join("\r\n"));
    });

    sock.on("data", (chunk) => {
      this._buf += chunk.toString("utf8");
      if (this._buf.length > 1 << 20) {
        this.overflow += 1;
        this._buf = this._buf.slice(-65536);
      }
      if (!this._hdrDone) {
        const hp = this._buf.indexOf("\r\n\r\n");
        if (hp < 0) return;
        this._buf = this._buf.slice(hp + 4);
        this._hdrDone = true;
      }
      let idx;
      while ((idx = this._buf.indexOf("\n\n")) >= 0) {
        const raw = this._buf.slice(0, idx);
        this._buf = this._buf.slice(idx + 2);
        this._event(raw);
      }
    });

    sock.on("error", () => this._downed(onDown));
    sock.on("close", () => this._downed(onDown));
    this._handlers = sock.eventNames().length;
  }

  _downed(onDown) {
    if (this.down || !this.everConnected) return;
    this.down = true;
    onDown(this);
  }

  _event(raw) {
    let id = null;
    for (const line of raw.split("\n")) {
      if (line.startsWith("id:")) id = Number(line.slice(3).trim());
    }
    if (id === null || !Number.isFinite(id)) return;
    if (this.lastSeq > 0 && id > this.lastSeq + 1) {
      this.gaps += id - this.lastSeq - 1;
    }
    if (id > this.lastSeq) this.lastSeq = id;
    this.everConnected = true;
  }

  get handles() {
    return this._sock && !this._sock.destroyed ? this._handlers : 0;
  }

  destroy() {
    if (this._sock) this._sock.destroy();
  }
}

const backoffMs = (attempt) =>
  Math.min(250 * 2 ** attempt, 4000) * (0.8 + 0.4 * Math.random());

async function getStats() {
  try {
    const r = await fetch(origin + streamPath + "?stats=1");
    return await r.json();
  } catch {
    return { active: -1, seq: 0, ring_len: 0, ring_span: 0 };
  }
}

// --------------------------------------------------------------------------
async function main() {
  const t0 = Date.now();
  log(`ulimit -n = ${ULIMIT_N}, target = ${TARGET}`);

  const clients = [];
  let stormArmed = false;
  let attachErrors = 0;
  let reattached = 0;
  let permanentDrops = 0;

  const onDown = (c) => {
    if (!stormArmed) {
      attachErrors += 1;
      return;
    }
    const attempt = (c._attempt = (c._attempt ?? 0) + 1);
    if (attempt > 8) {
      if (!c.permanent) permanentDrops += 1;
      c.permanent = true;
      return;
    }
    c._pendingTimer = setTimeout(() => {
      c._pendingTimer = null;
      if (c.permanent) return;
      c.connect(c.lastSeq, onDown);
    }, backoffMs(attempt - 1));
  };

  // Sweep: recover any client whose down-transition was missed (socket
  // destroyed without close/error delivery, etc.). Idempotent via
  // _pendingTimer.
  function sweep() {
    for (const c of herdClients) {
      if (c.down && !c.permanent && !c._pendingTimer) onDown(c);
    }
  }

  // Phase: ramp — attach the herd.
  for (let i = 0; i < TARGET; i += 1) {
    const c = new SseClient(i);
    clients.push(c);
    c.connect(0, onDown);
    if ((i + 1) % RAMP_BATCH === 0) await sleep(BATCH_GAP_MS);
  }
  await sleep(STEADY_MS);

  const rampStats = await getStats();
  const ceiling = rampStats.active > 0 ? rampStats.active : 0;
  const runAt = ceiling >= TARGET ? TARGET : Math.max(Math.floor(0.8 * ceiling), 1);
  emit({
    phase: "ramp",
    target: TARGET,
    ulimit_n: ULIMIT_N,
    active: rampStats.active,
    attach_errors: attachErrors,
    fd_ceiling_witnessed: ceiling,
    storm_run_size: runAt,
  });
  log(`ramp active=${rampStats.active} attachErrors=${attachErrors} runAt=${runAt}`);

  // If we could not attach the full target, trim the herd to 80% of ceiling.
  const herd = ceiling >= TARGET ? clients : clients.slice(0, runAt);
  for (const c of clients.slice(runAt)) c.destroy();

  // Phase: steady — deltas flowing.
  const seqA = (await getStats()).seq;
  await sleep(2000);
  const seqB = (await getStats()).seq;
  emit({ phase: "steady", delta_rate_per_s: Number(((seqB - seqA) / 2).toFixed(1)) });

  // Phase: storm — abrupt server-side abort of every controller.
  stormArmed = true; // arm before firing so clients reconnect, not count errors
  const storm = await fetch(origin + streamPath, {
    method: "POST",
    headers: { "x-smalt-storm": "abort" },
  })
    .then((r) => r.json())
    .catch((e) => ({ error: String(e) }));
  emit({ phase: "storm", aborted: storm.aborted ?? -1 });
  log("storm fired:", JSON.stringify(storm));

  // Phase: reconnect — clients react to close via onDown -> backoff loop.
  const herdClients = herd;
  const deadline = Date.now() + RECONNECT_BUDGET_MS;
  await sleep(1500);
  log(`post-storm active=${(await getStats()).active}`);

  while (Date.now() < deadline) {
    await sleep(1000);
    sweep();
    const s = await getStats();
    if (s.active >= herd.length) break;
  }
  log(`reconnect settled active=${(await getStats()).active}`);

  // Phase: settle — replay + live deltas flow.
  await sleep(SETTLE_MS);
  const finalStats = await getStats();

  // Courts.
  let diverged = 0, totalGaps = 0, overflowTotal = 0;
  let handleMin = Infinity, handleMax = -Infinity;
  for (const c of clients) {
    totalGaps += c.gaps;
    overflowTotal += c.overflow;
    if (c.gaps > 0 || c.permanent) diverged += 1;
    const h = c.handles;
    if (h < handleMin) handleMin = h;
    if (h > handleMax) handleMax = h;
  }
  const divergenceRate = diverged / clients.length;

  emit({
    phase: "verdict",
    target: TARGET,
    herd_size: herd.length,
    reattached_final_active: finalStats.active,
    permanent_drops: permanentDrops,
    attach_errors: attachErrors,
    client_gaps_total: totalGaps,
    diverged_clients: diverged,
    divergence_rate: Number(divergenceRate.toFixed(6)),
    divergence_threshold: 0.001,
    buffer_overflows: overflowTotal,
    listener_handles_min: handleMin === Infinity ? 0 : handleMin,
    listener_handles_max: handleMax === -Infinity ? 0 : handleMax,
    server_seq: finalStats.seq,
    server_ring_span: finalStats.ring_span,
    elapsed_ms: Date.now() - t0,
  });
  log(
    `verdict divergence=${(divergenceRate * 100).toFixed(4)}% ` +
      `permanent=${permanentDrops} attachErr=${attachErrors} ` +
      `overflows=${overflowTotal} handles=[${handleMin}..${handleMax}]`,
  );
}

main().catch((e) => {
  emit({ phase: "fatal", error: String((e && e.stack) || e) });
  process.exitCode = 1;
});
process.on("uncaughtException", (e) => {
  try {
    emit({ phase: "fatal", uncaught: String((e && e.stack) || e) });
  } catch { /* jsonl path unwritable */ }
});
process.on("unhandledRejection", (e) => {
  try {
    emit({ phase: "fatal", rejection: String((e && e.stack) || e) });
  } catch { /* jsonl path unwritable */ }
});
