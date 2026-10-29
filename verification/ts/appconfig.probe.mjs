// appconfig.probe.mjs — T24WIRE new-gap probe: @azure/app-configuration
// end-to-end witness against the RUNNING smalt substrate (never restarts it;
// loud SKIP exit 3 if substrate down). Uses the unmodified official SDK
// (AppConfigurationClient, AAD/TokenCredential mode) over the 9444 TLS twin
// where the /kv face rides, auth via the substrate STS client-credentials flow.
// Exit contract: 0 witness PASS / 1 hard FAIL / 3 loud SKIP.
// Run: NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem node verification/ts/appconfig.probe.mjs
import fs from "node:fs";
import path from "node:path";
import { SmaltTokenCredential } from "./harness/credential.ts";
import { AppConfigurationClient } from "@azure/app-configuration";

const REPO = path.resolve(import.meta.dirname, "../..");
const CA = path.join(REPO, ".smalt/tls/ca-cert.pem");
if (!fs.existsSync(CA)) {
  console.error("SKIP: missing TLS CA — run bash scripts/gen_dev_cert.sh");
  process.exit(3);
}
const ENDPOINT = process.env.SMALT_TLS ?? "https://localhost:9444";
const TENANT = "00000000-0000-0000-0000-000000000000";
const KEY = `wire-parity/appconfig/${Date.now()}`;

// Loud SKIP probe: substrate down => typed exit 3, never a fake pass.
async function substrateUp() {
  try {
    const res = await fetch(`${ENDPOINT.replace("localhost", "127.0.0.1")}/${TENANT}/oauth2/v2.0/token`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "client_credentials",
        client_id: "00000000-0000-0000-0000-000000000000",
        client_secret: "smalt-tf-mock-secret",
        scope: "https://management.azure.com/.default",
      }),
      dispatcher: undefined,
    });
    return res.ok;
  } catch {
    return false;
  }
}

const up = await substrateUp();
if (!up) {
  console.error(`LOUD-SKIP: substrate not reachable at ${ENDPOINT} (exit 3, nothing restarted)`);
  process.exit(3);
}

const cred = new SmaltTokenCredential(`${ENDPOINT}/${TENANT}/oauth2/v2.0/token`);
const client = new AppConfigurationClient(ENDPOINT, cred);

const cells = [];
function cell(tag, verdict, detail) {
  cells.push({ tag, verdict, detail });
  console.log(`[${verdict}] ${tag} — ${detail}`);
}

// 1. set (create)
const set = await client.setConfigurationSetting({ key: KEY, value: "v1" });
cell("set-create", set?.key === KEY ? "PASS" : "FAIL", `key=${set?.key} etag=${set?.etag?.slice(0, 12)}…`);

// 2. get
const got = await client.getConfigurationSetting({ key: KEY });
cell("get-roundtrip", got?.value === "v1" ? "PASS" : "FAIL", `value=${JSON.stringify(got?.value)}`);

// 3. CAS update via If-Match (onlyIfUnchanged -> If-Match: <etag>, KD-148 class)
const cas = await client.setConfigurationSetting(
  { key: KEY, value: "v2", etag: got.etag },
  { onlyIfUnchanged: true },
);
cell("cas-if-match", cas?.value === "v2" ? "PASS" : "FAIL", `value=${JSON.stringify(cas?.value)}`);

// 4. negative CAS: stale If-Match must 412
let negVerdict = "FAIL";
let negDetail = "no error thrown";
try {
  await client.setConfigurationSetting({ key: KEY, value: "v3", etag: got.etag }, { onlyIfUnchanged: true });
} catch (e) {
  negVerdict = e?.statusCode === 412 ? "PROBED" : "PROBED"; // typed 412 expected
  negVerdict = e?.statusCode === 412 ? "PASS" : "FAIL";
  negDetail = `status=${e?.statusCode} name=${e?.name}`;
}
cell("cas-stale-412", negVerdict, negDetail);

// 4b. onlyIfChanged -> If-None-Match: <current etag> must 412 (RFC 7232)
let inmVerdict = "FAIL";
let inmDetail = "no error thrown";
try {
  await client.setConfigurationSetting({ key: KEY, value: "v4", etag: cas.etag }, { onlyIfChanged: true });
} catch (e) {
  inmVerdict = e?.statusCode === 412 ? "PASS" : "FAIL";
  inmDetail = `status=${e?.statusCode}`;
}
cell("cas-if-none-match-412", inmVerdict, inmDetail);

// 5. list by key filter
let listed = 0;
for await (const s of client.listConfigurationSettings({ keyFilter: KEY })) listed++;
cell("list-key-filter", listed === 1 ? "PASS" : "FAIL", `count=${listed}`);

// 6. delete + confirm gone
await client.deleteConfigurationSetting({ key: KEY, etag: cas.etag }, { onlyIfUnchanged: true });
let goneVerdict = "FAIL";
let goneDetail = "get after delete resolved";
try {
  await client.getConfigurationSetting({ key: KEY });
} catch (e) {
  goneVerdict = e?.statusCode === 404 ? "PASS" : "FAIL";
  goneDetail = `status=${e?.statusCode}`;
}
cell("delete-404", goneVerdict, goneDetail);

const pass = cells.filter((c) => c.verdict === "PASS").length;
const fail = cells.filter((c) => c.verdict === "FAIL").length;
console.log(`SUMMARY pass=${pass} fail=${fail} total=${cells.length}`);
// emit jsonl row
const row = {
  lane: "wire-parity",
  surface: "app-configuration",
  op: "sdk-e2e-6cell",
  n: cells.length,
  errors: fail,
  verdict: fail === 0 ? "PASS" : "FAIL",
  sdk: "@azure/app-configuration@1.13.0",
  endpoint: ENDPOINT,
  cells,
  ts: new Date().toISOString(),
};
const out = process.env.WIRE_PARITY_JSONL ?? "/Users/sac/smalt/tmp/bench/wire-parity.jsonl";
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.appendFileSync(out, JSON.stringify(row) + "\n");
process.exit(fail === 0 ? 0 : 1);
