// SCVD-T21 lane: ARM control-plane ramp — 128 concurrent workers doing full
// PUT/GET/DELETE resource cycles against the ARM gateway riding the 9444 TLS
// twin (STS bearer, KD-15 handshake shape: tokenless 401 already witnessed on
// the front door). Per cycle: RG PUT, RG GET, generic resource PUT
// (Microsoft.Storage/storageAccounts), resource GET, resource DELETE, RG
// DELETE — unique names per worker/cycle. 128 workers x 4 cycles = 512 ops
// (one op = one full 6-request cycle). Typed FAIL (exit 1) on any error at
// 128. Loud SKIP (exit 3) if substrate down — never restart.
// Emits tmp/bench/scvd-arm.jsonl.
//
// Run: NODE_TLS_REJECT_UNAUTHORIZED=0 node scripts/bench/scvd_t21_arm_ramp.mjs
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const ARM = process.env.SCVD_ARM ?? "https://127.0.0.1:9444"; // ARM via TLS twin
const STS = process.env.SCVD_STS ?? "https://127.0.0.1:9444/organizations/oauth2/v2.0/token";
const OUT = process.env.SCVD_OUT ?? path.join(REPO, "tmp/bench/scvd-arm.jsonl");
const CONCURRENCY = Number(process.env.SCVD_CONCURRENCY ?? 128);
const CYCLES_PER_WORKER = Number(process.env.SCVD_CYCLES ?? 4); // x6 reqs = 3072 reqs
const RUN = process.env.SCVD_RUN ?? Date.now().toString(36);
const SUB = process.env.SCVD_SUB ?? "00000000-0000-0000-0000-000000000000";
const API = process.env.SCVD_API ?? "2021-04-01";
const OP_TIMEOUT_MS = 20_000;
const WALL_BUDGET_MS = 60_000;

const log = (...a) => console.log(new Date().toISOString(), ...a);
const withTimeout = (p, ms = OP_TIMEOUT_MS) =>
  Promise.race([
    p,
    new Promise((_, rej) =>
      setTimeout(() => rej(Object.assign(new Error("BENCH_OP_TIMEOUT"), { code: "BENCH_OP_TIMEOUT" })), ms),
    ),
  ]);

const machine = {
  cpu: os.cpus()[0].model,
  cores: os.cpus().length,
  node: process.version,
  endpoint: ARM,
};

function emitRow(row) {
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.appendFileSync(OUT, JSON.stringify(row) + "\n");
}

const pct = (sorted, p) => {
  const i = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return Number(sorted[i].toFixed(3));
};

// ---- liveness probe: loud SKIP, never restart ------------------------------
async function substrateUp() {
  try {
    const r = await fetch(`${ARM}/providers?api-version=2099-01-01`, {
      signal: AbortSignal.timeout(5000),
    });
    r.body?.cancel().catch(() => {});
    return r.status < 500;
  } catch {
    return false;
  }
}

// ---- bearer via emulator STS (KD-15 shape: any client_id/secret accepted) --
async function mintToken() {
  const r = await fetch(STS, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials&client_id=scvd-t21&client_secret=scvd-t21&scope=https%3A%2F%2Fmanagement.azure.com%2F.default",
    signal: AbortSignal.timeout(10_000),
  });
  if (!r.ok) throw new Error(`STS mint failed: ${r.status}`);
  const j = await r.json();
  if (!j.access_token) throw new Error("STS mint: no access_token");
  return j.access_token;
}

// ---- one raw ARM request; returns status -----------------------------------
// Transport errors (ECONNRESET et al.) get ONE counted retry — sustained-load
// transients only; HTTP error statuses are never retried. transport_retries is
// disclosed in the result row.
//
// KD-COVERS: KD-157 — a transport-errored DELETE may have EXECUTED server-side
// (response lost to ERR_HTTP2_SESSION_ERROR); the counted retry then sees 404
// even though the cycle's own delete succeeded. Delete is idempotent in
// effect, so a 404 on a RETRIED delete is accepted as an idempotent-success
// outcome and counted in delete_retry_404_ok (disclosed in the result row).
// Never applied to PUT/GET — those keep strict non-retry-404 semantics.
let transportRetries = 0;
let deleteRetry404Ok = 0;
async function arm(method, urlPath, body, token) {
  const doFetch = () => fetch(`${ARM}${urlPath}`, {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
      accept: "application/json",
    },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(OP_TIMEOUT_MS),
  });
  let r;
  let retried = false;
  try {
    r = await withTimeout(doFetch());
  } catch (e) {
    transportRetries++;
    retried = true;
    transportErr = `${e?.cause?.code ?? e?.cause?.message ?? e?.message ?? "?"}`;
    r = await withTimeout(doFetch()); // second failure propagates
  }
  r.body?.cancel().catch(() => {});
  if (retried && method === "DELETE" && r.status === 404) {
    deleteRetry404Ok++;
    return 204; // idempotent delete-success (KD-157); counted + disclosed
  }
  return r.status;
}
let transportErr = "";

// ===========================================================================
async function main() {
  if (!(await substrateUp())) {
    log("SKIP: live substrate down (9443/9444 not serving) — lane law: never restart");
    emitRow({
      lane: "scvd-t21", surface: "arm", op: "skip-substrate-down", n: 0,
      ops_per_sec: 0, p50_ms: 0, p95_ms: 0, p99_ms: 0, errors: 0, wall_ms: 0,
      machine, standing: "SKIP",
    });
    process.exit(3);
  }

  const token = await mintToken();

  const lat = [];
  let errors = 0, ops = 0, reqs = 0;
  let lastErr = "";

  // Full lifecycle cycle: RG PUT -> RG GET -> resource PUT -> resource GET ->
  // resource DELETE -> RG DELETE. Any non-OK or timeout = typed error.
  const worker = async (w) => {
    for (let c = 0; c < CYCLES_PER_WORKER; c++) {
      const rg = `scvd-t21-${RUN}-${w}-${c}`;
      const res = `scvdsa${RUN}${w}${c}`;
      const rgPath = `/subscriptions/${SUB}/resourcegroups/${rg}?api-version=${API}`;
      const resPath = `/subscriptions/${SUB}/resourceGroups/${rg}/providers/Microsoft.Storage/storageAccounts/${res}?api-version=${API}`;
      const t0 = performance.now();
      const stepStatuses = [];
      let forensic = "";
      try {
        const steps = [
          ["PUT", rgPath, { location: "eastus", tags: { lane: "t21" } }],
          ["GET", rgPath, undefined],
          ["PUT", resPath, {
            location: "eastus",
            kind: "StorageV2",
            sku: { name: "Standard_LRS", tier: "Standard" },
          }],
          ["GET", resPath, undefined],
          ["DELETE", resPath, undefined],
          ["DELETE", rgPath, undefined],
        ];
        for (const [m, p, b] of steps) {
          const st = await arm(m, p, b, token);
          reqs++;
          stepStatuses.push(st);
          const ok = st >= 200 && st < 300;
          // RG/resource GET of a just-deleted thing would be an error; PUT/GET
          // must be 2xx. DELETE may be 200/202/204.
          if (!ok) throw new Error(`${m} ${p} -> ${st}`);
        }
        lat.push(performance.now() - t0);
        ops++;
      } catch (e) {
        lat.push(performance.now() - t0);
        errors++; ops++; // failed cycles count as ops too (honest n)
        // forensic probe: is the RG visible immediately after the failure?
        try {
          const st = await arm("GET", rgPath, undefined, token);
          forensic = `rg-get-after-fail=${st}`;
        } catch (e) {
          forensic = `rg-get-after-fail=ERR:${String(e?.cause?.code ?? e?.message ?? "?").slice(0, 60)}`;
        }
        lastErr = `${rg} steps=[${stepStatuses.join(",")}] ${forensic}: ${String(e?.message ?? e).slice(0, 160)}`;
        // best-effort teardown so a failed cycle doesn't strand the RG
        await arm("DELETE", rgPath, undefined, token).catch(() => {});
      }
    }
  };

  const t0 = Date.now();
  await Promise.all(Array.from({ length: CONCURRENCY }, (_, w) => worker(w)));
  const wallMs = Date.now() - t0;
  const sorted = [...lat].sort((a, b) => a - b);
  const standing = errors === 0 && wallMs <= WALL_BUDGET_MS ? "PASS" : "FAIL";

  emitRow({
    lane: "scvd-t21", surface: "arm", op: `putgetdelete-c${CONCURRENCY}`, n: ops,
    ops_per_sec: Number((ops / (wallMs / 1000)).toFixed(1)),
    p50_ms: pct(sorted, 50), p95_ms: pct(sorted, 95), p99_ms: pct(sorted, 99),
    errors, wall_ms: wallMs, wall_budget_ms: WALL_BUDGET_MS,
    requests: reqs, transport_retries: transportRetries,
    delete_retry_404_ok: deleteRetry404Ok,
    ...(transportErr ? { last_transport_err: transportErr.slice(0, 120) } : {}),
    concurrency: CONCURRENCY, cycles_per_worker: CYCLES_PER_WORKER,
    machine, standing,
    ...(lastErr ? { last_err: lastErr.slice(0, 200) } : {}),
  });
  log(`ARM n=${ops} cycles (${reqs} reqs) ops/s=${(ops / (wallMs / 1000)).toFixed(1)} p50=${pct(sorted, 50)}ms p95=${pct(sorted, 95)}ms p99=${pct(sorted, 99)}ms errors=${errors} wall=${wallMs}ms standing=${standing}${lastErr ? " lastErr=" + lastErr : ""}`);
  process.exit(standing === "PASS" ? 0 : 1);
}

await main();
