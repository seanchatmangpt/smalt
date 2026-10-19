// appconfig.probe.mjs — v26.10.16 lane: real REST probe of the smalt Azure App
// Configuration surface (/kv family, lib/smalt/egress_router.ex:924-1054).
// @azure/app-configuration is not vendored, so the probe rides plain REST —
// the same wire the SDK would drive (ledger.probe.mjs convention).
//
// Wire contract under test (egress_router.ex):
//   PUT /kv/:key?label=      create 201 / overwrite 200 (If-Match CAS);
//                            stale If-Match -> 412; existing without headers
//                            -> 409 WriteConflict; If-None-Match:* on existing
//                            -> 412 (create-only refusal)
//   GET /kv/:key?label=      200 + etag header; 404 KvNotFound
//   GET /kv?key=&label=      200 {items:[...]} + sync-token header
//   DELETE /kv/:key?label=   REQUIRES If-Match: missing -> 409 MissingIfMatch;
//                            stale -> 412; If-Match:* -> 204
//
// Auth: enforce mode — mint a bearer from smalt's own STS
// (POST /{tenant}/oauth2/v2.0/token, client_credentials), same convention as
// arm-resources.probe.mjs. Tokenless /kv requests 401 via kv_challenge_guard.
//
// Exit contract: 0 pass / 1 fail / 2 substrate down / 3 harness error.
import net from "node:net";

const ENDPOINT = process.env.SMALT_TS_KV_ENDPOINT || "http://127.0.0.1:8443";
const ARM = process.env.SMALT_TS_KV_ARM || "http://127.0.0.1:9443";
const PORT = Number(new URL(ENDPOINT).port) || 80;
const TENANT = "00000000-0000-0000-0000-000000000000";

// Substrate preflight: attach, don't boot. Exit 2 loud, never a fake fail.
await new Promise((resolve) => {
  const s = net.connect({ host: "127.0.0.1", port: PORT, timeout: 2000 });
  s.once("connect", () => { s.destroy(); resolve(); });
  s.once("timeout", () => { s.destroy(); console.error(`[appconfig] substrate down: no listener on 127.0.0.1:${PORT}. Exit 2.`); process.exit(2); });
  s.once("error", () => { s.destroy(); console.error(`[appconfig] substrate down: no listener on 127.0.0.1:${PORT}. Exit 2.`); process.exit(2); });
});

async function mintToken() {
  const res = await fetch(`${ARM}/${TENANT}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: "appconfig-probe",
      client_secret: "appconfig-probe",
      scope: "https://smalt.config/.default",
    }),
  });
  if (res.status !== 200) throw new Error(`STS ${res.status}: ${(await res.text()).slice(0, 200)}`);
  return (await res.json()).access_token;
}

let TOKEN;
try {
  TOKEN = await mintToken();
} catch (e) {
  console.error(`[appconfig] harness error minting STS token: ${e?.name}: ${e?.message}`);
  process.exit(3);
}

const results = [];
let failures = 0;
function rec(name, status, detail) {
  results.push({ name, status });
  if (status === "FAIL") failures++;
  console.log(`[${status}] ${name} — ${detail}`);
}

const AUTH = { authorization: `Bearer ${TOKEN}` };
async function j(method, path, body, extra = {}) {
  const res = await fetch(`${ENDPOINT}${path}`, {
    method,
    headers: { ...AUTH, ...(body !== undefined ? { "content-type": "application/json" } : {}), ...extra },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* leave null */ }
  return { status: res.status, json, text, headers: res.headers };
}

// unique-per-run keys so re-runs never collide with prior substrate state
const RUN = Date.now();
const K = (n) => `probe-${RUN}-${n}`;

// 0. tokenless first touch -> 401 challenge (kv_challenge_guard over /kv)
{
  const res = await fetch(`${ENDPOINT}/kv/${K("auth")}`);
  rec("auth.tokenless-401", res.status === 401 ? "PASS" : "FAIL",
    `tokenless GET /kv -> ${res.status} (kv_challenge_guard)`);
}

// 1. PUT create -> 201 with quoted etag
const key1 = K("k1");
const p1 = await j("PUT", `/kv/${key1}?label=probe`, { value: "v1", contentType: "text/plain" });
const p1ok = p1.status === 201 && typeof p1.json?.etag === "string" && p1.json.etag.startsWith('"') &&
  p1.json.key === key1 && p1.json.label === "probe" && p1.json.value === "v1";
rec("put.create-201", p1ok ? "PASS" : "FAIL",
  p1ok ? `201, etag=${p1.json.etag.slice(0, 12)}…, label=probe` : `status ${p1.status} body=${p1.text.slice(0, 200)}`);
const etag1 = p1.json?.etag;

// 2. GET 200 + etag header, round-trips value
const g1 = await j("GET", `/kv/${key1}?label=probe`);
const g1ok = g1.status === 200 && g1.json?.value === "v1" &&
  (g1.headers.get("etag") || "") === etag1;
rec("get.200-etag", g1ok ? "PASS" : "FAIL",
  g1ok ? `200, value round-trips, etag header == PUT etag` : `status ${g1.status} etag=${g1.headers.get("etag")} body=${g1.text.slice(0, 120)}`);

// 3. list with key= prefix filter and label= filter
await j("PUT", `/kv/${K("k2")}?label=probe`, { value: "v2" });
await j("PUT", `/kv/${K("k3")}?label=other`, { value: "v3" });
const l1 = await j("GET", `/kv?key=${K("")}`);
const l2 = await j("GET", `/kv?key=${K("")}&label=other`);
const l1keys = (l1.json?.items || []).map((i) => i.key);
const l2keys = (l2.json?.items || []).map((i) => i.key);
const l1ok = l1.status === 200 && l1keys.length >= 3 && l1keys.every((k) => k.startsWith(`probe-${RUN}`));
const l2ok = l2.status === 200 && l2keys.length === 1 && l2keys[0] === K("k3");
rec("list.key-filter", l1ok ? "PASS" : "FAIL",
  l1ok ? `key= prefix filter returned ${l1keys.length} items, all run-prefixed` : `status ${l1.status} items=${JSON.stringify(l1keys)}`);
rec("list.label-filter", l2ok ? "PASS" : "FAIL",
  l2ok ? `label=other returned exactly [${l2keys}]` : `status ${l2.status} items=${JSON.stringify(l2keys)}`);
const sync = l1.headers.get("sync-token");
rec("list.sync-token", sync ? "PASS" : "FAIL", `sync-token header: ${sync ?? "MISSING"}`);

// 4. etag CAS: stale If-Match PUT -> 412
const stale = await j("PUT", `/kv/${key1}?label=probe`,
  { value: "stale" }, { "if-match": '"deadbeef"' });
rec("put.stale-ifmatch-412", stale.status === 412 ? "PASS" : "FAIL",
  `stale If-Match PUT -> ${stale.status} ${JSON.stringify(stale.json?.error?.code ?? null)}`);

// 5. fresh etag overwrite -> 200 (CAS happy path)
const fresh = await j("PUT", `/kv/${key1}?label=probe`,
  { value: "v1b" }, { "if-match": etag1 });
const freshOk = fresh.status === 200 && fresh.json?.value === "v1b" && fresh.json?.etag !== etag1;
rec("put.cas-overwrite-200", freshOk ? "PASS" : "FAIL",
  freshOk ? `If-Match fresh etag -> 200, etag rotated` : `status ${fresh.status} body=${fresh.text.slice(0, 120)}`);
const etag2 = fresh.json?.etag;

// 6. create-only: If-None-Match:* on existing -> 412
const createOnly = await j("PUT", `/kv/${key1}?label=probe`,
  { value: "dup" }, { "if-none-match": "*" });
rec("put.create-only-412", createOnly.status === 412 ? "PASS" : "FAIL",
  `If-None-Match:* on existing -> ${createOnly.status} ${JSON.stringify(createOnly.json?.error?.code ?? null)}`);

// 7. bare overwrite without precondition headers -> 409 WriteConflict
const bare = await j("PUT", `/kv/${key1}?label=probe`, { value: "bare" });
rec("put.bare-overwrite-409", bare.status === 409 ? "PASS" : "FAIL",
  `headerless overwrite of existing -> ${bare.status} ${JSON.stringify(bare.json?.error?.code ?? null)}`);

// 8. DELETE without If-Match -> 409 MissingIfMatch (even after the kv exists)
const del0 = await j("DELETE", `/kv/${key1}?label=probe`);
rec("delete.missing-ifmatch-409", del0.status === 409 ? "PASS" : "FAIL",
  `DELETE without If-Match -> ${del0.status} ${JSON.stringify(del0.json?.code ?? del0.json?.error?.code ?? null)}`);

// 9. DELETE with stale If-Match -> 412
const delStale = await j("DELETE", `/kv/${key1}?label=probe`, undefined, { "if-match": '"deadbeef"' });
rec("delete.stale-ifmatch-412", delStale.status === 412 ? "PASS" : "FAIL",
  `DELETE stale If-Match -> ${delStale.status}`);

// 10. DELETE with If-Match:* -> 204
const del = await j("DELETE", `/kv/${key1}?label=probe`, undefined, { "if-match": "*" });
rec("delete.ifmatch-star-204", del.status === 204 ? "PASS" : "FAIL",
  `DELETE If-Match:* -> ${del.status}`);

// 11. idempotent 404 after delete (GET and DELETE both)
const g2 = await j("GET", `/kv/${key1}?label=probe`);
const d2 = await j("DELETE", `/kv/${key1}?label=probe`, undefined, { "if-match": "*" });
const idemOk = g2.status === 404 && d2.status === 404 &&
  JSON.stringify(g2.json ?? {}).includes("KvNotFound");
rec("delete.idempotent-404", idemOk ? "PASS" : "FAIL",
  `post-delete GET -> ${g2.status}, second DELETE (If-Match:*) -> ${d2.status} KvNotFound=${JSON.stringify(g2.json ?? {}).includes("KvNotFound")}`);

// 12. PUT If-Match:* on never-created kv -> 412 (RFC 7232 existence assertion)
const starCreate = await j("PUT", `/kv/${K("kstar")}?label=probe`,
  { value: "x" }, { "if-match": "*" });
rec("put.ifmatch-star-create-412", starCreate.status === 412 ? "PASS" : "FAIL",
  `If-Match:* on absent kv -> ${starCreate.status} (existence assertion, RFC 7232)`);

// 13. If-Match with the current etag on DELETE -> 204 (exact etag delete)
await j("PUT", `/kv/${K("kdel")}?label=probe`, { value: "bye" });
const g3 = await j("GET", `/kv/${K("kdel")}?label=probe`);
const delExact = await j("DELETE", `/kv/${K("kdel")}?label=probe`, undefined, { "if-match": g3.headers.get("etag") });
rec("delete.exact-etag-204", delExact.status === 204 ? "PASS" : "FAIL",
  `DELETE with exact current etag -> ${delExact.status}`);

console.log(`\nappconfig probe: ${results.length - failures}/${results.length} PASS`);
process.exit(failures === 0 ? 0 : 1);
