// RG404 raw-wire probe (lane rg404, v26.10.20): same cycle shape as T21
// (scripts/bench/scvd_t21_arm_ramp.mjs) over the same 9444 TLS twin, but every
// request records its retry lineage so a 404 on a retried final RG DELETE is
// attributable. Emits NO bench jsonl (this is a diagnostic probe, not a lane).
// Run: NODE_TLS_REJECT_UNAUTHORIZED=0 node scripts/bench/rg404_wire_probe.mjs
import crypto from "node:crypto";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const ARM = process.env.RG404_ARM ?? "https://127.0.0.1:9444";
const STS = process.env.RG404_STS ?? "https://127.0.0.1:9444/organizations/oauth2/v2.0/token";
const CONCURRENCY = Number(process.env.RG404_CONCURRENCY ?? 128);
const CYCLES = Number(process.env.RG404_CYCLES ?? 8);
const RUN = process.env.RG404_RUN ?? Date.now().toString(36);
const SUB = "00000000-0000-0000-0000-000000000000";
const API = "2021-04-01";
const TIMEOUT = 20_000;

const log = (...a) => console.log(new Date().toISOString(), ...a);

async function mintToken() {
  const r = await fetch(STS, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials&client_id=rg404&client_secret=rg404&scope=https%3A%2F%2Fmanagement.azure.com%2F.default",
    signal: AbortSignal.timeout(10_000),
  });
  const j = await r.json();
  if (!j.access_token) throw new Error("no token");
  return j.access_token;
}

// One request. Returns {status, retried, transportErr}. ONE counted retry on
// transport error — identical semantics to the T21 lane, but lineage is kept.
async function arm(method, urlPath, body, token) {
  const doFetch = () =>
    fetch(`${ARM}${urlPath}`, {
      method,
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
        accept: "application/json",
      },
      ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
      signal: AbortSignal.timeout(TIMEOUT),
    });
  let retried = false;
  let r;
  try {
    r = await doFetch();
  } catch (e) {
    retried = true;
    const code = `${e?.cause?.code ?? e?.cause?.message ?? e?.message ?? "?"}`;
    r = await doFetch();
    return { status: r.status, retried, transportErr: code.slice(0, 80) };
  }
  r.body?.cancel().catch(() => {});
  return { status: r.status, retried, transportErr: null };
}

async function main() {
  // liveness
  try {
    const r = await fetch(`${ARM}/providers?api-version=2099-01-01`, { signal: AbortSignal.timeout(5000) });
    r.body?.cancel().catch(() => {});
    if (r.status >= 500) throw new Error("down");
  } catch {
    log("SKIP: substrate down");
    process.exit(3);
  }
  const token = await mintToken();
  let cycles = 0, failures = [];
  const evidence = [];

  const worker = async (w) => {
    for (let c = 0; c < CYCLES; c++) {
      const rg = `rg404-${RUN}-${w}-${c}`;
      const acct = `rg404a${RUN}${w}${c}`;
      const rgPath = `/subscriptions/${SUB}/resourcegroups/${rg}?api-version=${API}`;
      const resPath = `/subscriptions/${SUB}/resourceGroups/${rg}/providers/Microsoft.Storage/storageAccounts/${acct}?api-version=${API}`;
      const steps = [
        ["PUT", rgPath, { location: "eastus" }],
        ["GET", rgPath, undefined],
        ["PUT", resPath, { location: "eastus", kind: "StorageV2", sku: { name: "Standard_LRS" } }],
        ["GET", resPath, undefined],
        ["DELETE", resPath, undefined],
        ["DELETE", rgPath, undefined],
      ];
      cycles++;
      const lineage = [];
      let fail = null;
      for (const [m, p, b] of steps) {
        const { status, retried, transportErr } = await arm(m, p, b, token);
        lineage.push(`${m}:${status}${retried ? "(RETRY-AFTER-TRANSPORT-ERR)" : ""}${transportErr ? `[${transportErr}]` : ""}`);
        if (status < 200 || status >= 300) { fail = { m, status, retried, transportErr }; break; }
      }
      if (fail) {
        // forensic: is the RG gone right now?
        const probe = await arm("GET", rgPath, undefined, token);
        failures.push({ rg, fail, forensicRgGet: probe.status, lineage });
      } else if (lineage.some((l) => l.includes("RETRY"))) {
        evidence.push({ rg, lineage });
      }
    }
  };

  const t0 = Date.now();
  await Promise.all(Array.from({ length: CONCURRENCY }, (_, w) => worker(w)));
  const wall = Date.now() - t0;

  log(`rg404 probe: cycles=${cycles} failures=${failures.length} wall=${wall}ms retried-but-clean-cycles=${evidence.length}`);
  for (const f of failures) log("FAIL " + JSON.stringify(f));
  for (const e of evidence.slice(0, 5)) log("RETRY-EVIDENCE " + JSON.stringify(e));
  process.exit(failures.length === 0 ? 0 : 1);
}

await main();
