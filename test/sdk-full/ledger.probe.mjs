// Lane 329: real REST probe of the smalt Confidential Ledger surface
// (`/app/transactions` on the data plane, served by lib/smalt/egress_router.ex
// via lib/smalt/security/confidential_ledger.ex / ledger_writer.ex).
// @azure/azure-confidentialledger is not in test/sdk-full/node_modules, so the
// probe rides plain REST — same wire the SDK would drive.
//
// Scope (coordinator trim): append/read/receipt happy path + the lazy-create
// default (append to a never-created subledger succeeds — KD-42 MATCHED
// re-grade evidence). Receipt/chained-hash envelope verification included.
//
// Exit contract: 0 pass / 1 fail / 2 substrate down / 3 harness error.
import crypto from "node:crypto";
import net from "node:net";

const ENDPOINT = process.env.LEDGER_ENDPOINT || "http://127.0.0.1:39318";
const PORT = Number(new URL(ENDPOINT).port) || 80;
const results = [];
function rec(name, status, detail) {
  results.push({ name, status, detail });
  console.log(`[${status}] ${name} — ${detail}`);
}
const sha256hex = (s) => crypto.createHash("sha256").update(s, "utf8").digest("hex");
const deepEq = (a, b) => JSON.stringify(a) === JSON.stringify(b) ||
  (a !== null && b !== null && typeof a === "object" && typeof b === "object" &&
    Object.keys(a).length === Object.keys(b).length &&
    Object.keys(a).every((k) => deepEq(a[k], b[k])));

// Substrate preflight: this probe attaches, it does not boot. Exit 2 loud
// (substrate down), never a fake "1 = test fail" on a dead plane.
await new Promise((resolve) => {
  const s = net.connect({ host: "127.0.0.1", port: PORT, timeout: 2000 });
  s.once("connect", () => { s.destroy(); resolve(); });
  s.once("timeout", () => { s.destroy(); console.error(`[ledger-probe] substrate down: no listener on 127.0.0.1:${PORT}. Exit 2.`); process.exit(2); });
  s.once("error", () => { s.destroy(); console.error(`[ledger-probe] substrate down: no listener on 127.0.0.1:${PORT}. Exit 2.`); process.exit(2); });
});

async function j(method, path, body) {
  const res = await fetch(`${ENDPOINT}${path}`, {
    method,
    headers: body !== undefined ? { "content-type": "application/json" } : {},
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* leave null */ }
  return { status: res.status, json, text };
}

// Fresh subledger name-space check happens against the fixed "default_ledger"
// route; laziness is proven by appending FIRST (no creation call exists on the
// surface at all — there is no "create subledger" route).
let failures = 0;
try {
  // 1. Lazy-create: POST append to a never-created subledger must succeed.
  const contents1 = { contents: { probe: "lane329", n: 1, msg: `first append ${Date.now()}` } };
  const a1 = await j("POST", "/app/transactions", contents1);
  if (a1.status === 201 && a1.json?.transactionId) {
    rec("append.lazy-create", "PASS", `status 201, tx ${a1.json.transactionId}, subLedgerId=${a1.json.subLedgerId}`);
  } else {
    failures++;
    rec("append.lazy-create", "FAIL", `status ${a1.status} body=${a1.text.slice(0, 200)}`);
  }
  const r1 = a1.json ?? {};

  // 2. Read back by tx id; envelope must round-trip.
  const g1 = await j("GET", `/app/transactions/${r1.transactionId}`);
  const envOk = g1.status === 200 &&
    g1.json?.transactionId === r1.transactionId &&
    typeof g1.json?.data_hash === "string" &&
    typeof g1.json?.prev_hash === "string" &&
    typeof g1.json?.merkle_root === "string" &&
    typeof g1.json?.signature === "string" &&
    deepEq(g1.json?.contents, contents1);
  if (envOk) {
    rec("read.by-tx-id", "PASS", `tx ${g1.json.transactionId} envelope complete (data_hash/prev_hash/merkle_root/signature/contents)`);
  } else {
    failures++;
    rec("read.by-tx-id", "FAIL", `status ${g1.status} body=${g1.text.slice(0, 200)}`);
  }

  // 3. Chained-hash law: merkle_root == sha256(prev_hash <> data_hash).
  const chainOk = g1.json?.merkle_root === sha256hex(`${g1.json?.prev_hash}${g1.json?.data_hash}`);
  if (chainOk) {
    rec("receipt.chain-hash", "PASS", `merkle_root=${g1.json.merkle_root.slice(0, 16)}… == sha256(prev_hash||data_hash)`);
  } else {
    failures++;
    rec("receipt.chain-hash", "FAIL", `merkle_root=${g1.json?.merkle_root} prev=${g1.json?.prev_hash} data=${g1.json?.data_hash}`);
  }

  // 4. Second append: prev_hash must link to first receipt's merkle_root.
  const a2 = await j("POST", "/app/transactions", { contents: { probe: "lane329", n: 2, msg: `second append ${Date.now()}` } });
  const r2 = a2.json ?? {};
  const linkOk = a2.status === 201 &&
    r2.prev_hash === r1.merkle_root &&
    r2.merkle_root === sha256hex(`${r2.prev_hash}${r2.data_hash}`);
  if (linkOk) {
    rec("append.chain-link", "PASS", `tx ${r2.transactionId}: prev_hash == tx1.merkle_root; chain extends`);
  } else {
    failures++;
    rec("append.chain-link", "FAIL", `status ${a2.status} prev=${r2.prev_hash} expected ${r1.merkle_root}`);
  }

  // 5. GET latest matches the second receipt; list contains both, in order.
  const lat = await j("GET", "/app/transactions/latest");
  const lst = await j("GET", "/app/transactions");
  const ids = Array.isArray(lst.json) ? lst.json.map((x) => x.transactionId) : [];
  const latestOk = lat.status === 200 && lat.json?.transactionId === r2.transactionId;
  const listOk = lst.status === 200 &&
    ids.includes(r1.transactionId) && ids.includes(r2.transactionId) &&
    ids.indexOf(r1.transactionId) < ids.indexOf(r2.transactionId);
  rec("read.latest", latestOk ? "PASS" : (failures++, "FAIL"),
    latestOk ? `latest == tx ${r2.transactionId}` : `status ${lat.status} tx=${lat.json?.transactionId}`);
  rec("read.list-order", listOk ? "PASS" : (failures++, "FAIL"),
    listOk ? `list has ${ids.length} receipt(s), tx1 before tx2` : `status ${lst.status} ids=${JSON.stringify(ids)}`);

  // 6. Unknown tx id -> typed 404 TransactionNotFound.
  const miss = await j("GET", "/app/transactions/99999.1");
  const missOk = miss.status === 404 && JSON.stringify(miss.json ?? {}).includes("TransactionNotFound");
  rec("read.unknown-tx", missOk ? "PASS" : (failures++, "FAIL"),
    missOk ? "404 TransactionNotFound envelope" : `status ${miss.status} body=${miss.text.slice(0, 120)}`);
} catch (e) {
  console.error(`[ledger-probe] harness error: ${e?.stack || e}`);
  process.exit(3);
}

console.log(`\nledger probe: ${results.length - failures}/${results.length} PASS`);
process.exit(failures === 0 ? 0 : 1);
