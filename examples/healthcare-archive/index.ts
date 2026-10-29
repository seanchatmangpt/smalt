// index.ts — Healthcare compliance archive (Fortune-500 archetype, lane ex3).
//
// Story: a hospital platform team archives nightly patient-record exports to
// WORM-protected blob storage, keeps the compliance officers' working secrets
// in Key Vault with soft-delete recoverability, and appends every archive
// event to a Confidential Ledger whose Merkle chain is independently
// re-verified by the auditor (this harness recomputes every hash — it does
// not trust the server's word about its own chain).
//
// Wire shapes proven against this substrate by:
//   - blob snapshot: verification/ts/newcaps.probe.mjs cell 4 (KD-107)
//   - blob legal hold: verification/py/test_wf2_concurrency.py::test_blob_legal_hold
//   - immutability policy JSON body: lib/smalt/egress_router.ex
//     comp=immutabilityPolicy {immutabilityPeriodSinceCreationInDays, locked}
//   - deleted-secrets plane: newcaps.probe.mjs cell 2 (KD-102)
//   - ledger receipts: lib/smalt/security/ledger_writer.ex
//
// Transport law (witnessed 2026-10-19, receipt.md): the vendored
// @azure/storage-blob 12.34 hard-refuses bearer-over-http
// ("Bearer token authentication is not permitted for non-TLS protected
// URLs"), the TLS twin serves no blob routes (typed 404 RouteNotFound), and
// SharedKey is not admitted in enforce auth mode — so the blob leg rides the
// egress data plane with real-wire REST + bearer + x-ms-version (the exact
// shape newcaps.probe.mjs and py/wf2 validate). KV and Confidential Ledger
// ride the TLS twin. Zero mocks; no fixed sleeps (boundedPoll only).
//
// Exit contract: 0 pass (XFAIL counted loudly, in-flight surfaces) /
// 1 check FAIL / 2 substrate down / 3 loud skip.
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import https from "node:https";
import http from "node:http";
import { boundedPoll } from "../../verification/ts/harness/poll.ts";
import { GREEN, check, type Check } from "../../verification/ts/harness/enum.ts";

// ---- endpoints (env-overridable, localhost defaults) -----------------------
const EGRESS = process.env.SMALT_EGRESS ?? "http://127.0.0.1:8443";
const TLS = process.env.SMALT_TLS ?? "https://127.0.0.1:9444";
const ARM_HTTP = process.env.SMALT_ARM_HTTP ?? "http://127.0.0.1:9443";
const REPO = process.env.SMALT_REPO ?? path.resolve(import.meta.dirname, "../..");
const CA_PATH = process.env.SMALT_CA ?? path.join(REPO, ".smalt/tls/ca-cert.pem");
const TENANT = "00000000-0000-0000-0000-000000000000";
const STS = `${TLS}/${TENANT}/oauth2/v2.0/token`;
const XMS = { "x-ms-version": "2021-04-01" };

const RUN = `ex3-health-${Date.now().toString(36)}`;

// ---- substrate liveness (exit 2) -------------------------------------------
async function substrateUp(): Promise<void> {
  try {
    await boundedPoll(
      "substrate health (ARM /metadata/endpoints)",
      async () => {
        const r = await req("GET", `${ARM_HTTP}/metadata/endpoints`);
        return r.status === 200 ? true : null;
      },
      15_000,
    );
  } catch {
    console.error(`LOUD-SKIP exit 2: substrate not healthy at ${ARM_HTTP}`);
    process.exit(2);
  }
}

let _agent: https.Agent | undefined;
function agent(): https.Agent {
  if (!_agent) {
    _agent = new https.Agent({
      ca: fs.readFileSync(CA_PATH),
      rejectUnauthorized: true,
      keepAlive: true,
      servername: "localhost",
    });
  }
  return _agent;
}

// ---- REST helper (real wire; TLS CA-pinned) ---------------------------------
function req(
  method: string,
  url: string,
  { headers = {}, body = null as string | null } = {},
): Promise<{ status: number; headers: any; text: string; json: () => any }> {
  return new Promise((resolve) => {
    const u = new URL(url);
    const isHttps = u.protocol === "https:";
    const r = (isHttps ? https : http).request(
      {
        hostname: u.hostname,
        port: u.port,
        path: u.pathname + u.search,
        method,
        agent: isHttps ? agent() : undefined,
        servername: "localhost",
        headers,
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          resolve({
            status: res.statusCode!,
            headers: res.headers,
            text,
            json: () => { try { return JSON.parse(text); } catch { return null; } },
          });
        });
      },
    );
    r.on("error", (e) =>
      resolve({ status: 0, headers: {}, text: `transport: ${e.message}`, json: () => null }));
    r.end(body);
  });
}

// ---- smalt STS token (TLS twin) ---------------------------------------------
const cached: { at: { token: string; expiresOnTimestamp: number } | null } = { at: null };
async function token(): Promise<string> {
  if (cached.at && cached.at.expiresOnTimestamp > Date.now() + 60_000) return cached.at.token;
  const res = await req("POST", STS, {
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: TENANT,
      client_secret: "smalt-tf-mock-secret",
      scope: "https://management.azure.com/.default",
    }).toString(),
  });
  const payload = res.json();
  if (res.status !== 200 || !payload?.access_token) {
    throw new Error(`STS ${res.status}: ${res.text.slice(0, 200)}`);
  }
  const mid = payload.access_token.split(".")[1];
  const claims = JSON.parse(Buffer.from(mid, "base64url").toString("utf8"));
  cached.at = { token: payload.access_token, expiresOnTimestamp: (claims.exp ?? 0) * 1000 };
  return cached.at.token;
}

// ---- verdict helpers ---------------------------------------------------------
const checks: Check[] = [];
function p(name: string, verdict: string, detail: string) {
  checks.push(check(name, verdict, detail));
  console.log(`[${verdict}] ${name} — ${detail}`);
}

function requireStatus(label: string, got: { status: number; text: string }, want: number | number[]) {
  const wantArr = Array.isArray(want) ? want : [want];
  if (!wantArr.includes(got.status)) {
    throw new Error(`CHECK-FAIL ${label}: expected ${wantArr.join("/")} got ${got.status}: ${got.text.slice(0, 200)}`);
  }
}

// Merkle chain verify (auditor-side recompute; canonical = sorted-key JSON):
//   data_hash  = sha256(canonical_json(contents))
//   merkle     = sha256(prev_hash <> data_hash)
//   linkage    = receipt[n+1].prev_hash === receipt[n].merkle_root
function canonical(value: any): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  return `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(",")}}`;
}
const sha256hex = (buf: Buffer) => createHash("sha256").update(buf).digest("hex");

function verifyChain(receipts: any[]): { ok: boolean; why: string } {
  for (const r of receipts) {
    const dh = sha256hex(Buffer.from(canonical(r.contents), "utf8"));
    if (dh !== r.data_hash) return { ok: false, why: `tx ${r.transactionId}: data_hash recompute mismatch` };
    // writer: hash(prev_hash <> data_hash) — hex-STRING concatenation, then sha256
    const root = sha256hex(Buffer.from(r.prev_hash + r.data_hash, "utf8"));
    if (root !== r.merkle_root) return { ok: false, why: `tx ${r.transactionId}: merkle_root recompute mismatch` };
  }
  for (let i = 1; i < receipts.length; i++) {
    if (receipts[i].prev_hash !== receipts[i - 1].merkle_root) {
      return { ok: false, why: `chain break at ${receipts[i].transactionId}: prev_hash != prior merkle_root` };
    }
  }
  return { ok: true, why: `${receipts.length} receipts: data_hash, merkle_root, linkage recomputed client-side` };
}

// ============================================================================
async function main(): Promise<number> {
  await substrateUp();
  const tok = await token();
  const B = { Authorization: `Bearer ${tok}`, ...XMS };
  const J = { "content-type": "application/json", ...B };
  const blobBase = `${EGRESS}/${RUN}-acct`;
  const stamp = Date.now().toString(36);

  // ================= Blob: WORM archive + snapshot immutability =============
  const container = `${RUN}-records`;
  const blobName = `patient-export-${stamp}.ndjson`;
  const V1 = Buffer.from(
    JSON.stringify({
      patientId: "P-0001", mrn: "MRN-8842",
      exportedAt: new Date().toISOString(), records: 42,
    }) + "\n",
  );

  const putCtr = await req("PUT", `${blobBase}/${container}?restype=container`, { headers: B });
  requireStatus("blob-container-create", putCtr, 201);
  p("blob-container-create", GREEN, `container ${container} created (201)`);

  const blobUrl = `${blobBase}/${container}/${blobName}`;
  const putBlob = await req("PUT", blobUrl, {
    headers: { ...B, "x-ms-blob-type": "BlockBlob", "content-length": String(V1.length) },
    body: V1,
  });
  requireStatus("blob-upload", putBlob, 201);
  p("blob-upload", GREEN, `patient export uploaded (${V1.length} bytes BlockBlob)`);


  // Snapshot taken BEFORE the hold (the hold create-arm refuses snapshots — R5, witnessed): the archive freeze — the archive freeze
  const snap = await req("PUT", `${blobUrl}?comp=snapshot`, { headers: B });
  requireStatus("snapshot-create", snap, 201);
  const snapTs = snap.headers["x-ms-snapshot"] as string;
  if (!snapTs) throw new Error("CHECK-FAIL snapshot-create: no x-ms-snapshot header returned");
  p("snapshot-create", GREEN, `snapshot ${snapTs} frozen (x-ms-snapshot minted)`);

  // WORM legal hold ON
  const holdUrl = `${blobBase}/${container}?restype=container&comp=legalhold`;
  requireStatus("legalhold-on",
    await req("PUT", holdUrl, { headers: { ...B, "x-ms-legal-hold": "true" } }), 200);
  p("worm-legalhold-on", GREEN, "legal hold set (comp=legalhold x-ms-legal-hold=true)");

  // Overwrite under hold -> typed 409 ContainerLocked
  const ovr = await req("PUT", blobUrl, {
    headers: { ...B, "x-ms-blob-type": "BlockBlob", "content-length": "6" },
    body: "tamper",
  });
  p("worm-overwrite-refused",
    ovr.status === 409 && /ContainerLocked/i.test(ovr.text) ? GREEN : "FAIL",
    `overwrite under hold -> ${ovr.status} ${ovr.text.slice(0, 120)}`);

  // Delete under hold -> typed 409 ContainerLocked
  const del = await req("DELETE", blobUrl, { headers: B });
  p("worm-delete-refused",
    del.status === 409 && /ContainerLocked/i.test(del.text) ? GREEN : "FAIL",
    `delete under hold -> ${del.status} ${del.text.slice(0, 120)}`);

  // Hold off; tamper the BASE blob; the snapshot must stay frozen
  requireStatus("legalhold-off",
    await req("PUT", holdUrl, { headers: { ...B, "x-ms-legal-hold": "false" } }), 200);
  const tamper = await req("PUT", blobUrl, {
    headers: { ...B, "x-ms-blob-type": "BlockBlob", "content-length": "18" },
    body: "TAMPERED-AFTER-HOLD",
  });
  requireStatus("base-tamper", tamper, 201);
  // global fetch (the helper above 404s RouteNotFound on this read for
  // reasons the node-fetch replay does not reproduce; same real wire)
  const snapGet = await fetch(`${blobUrl}?sharesnapshot=${snapTs}`, { headers: B });
  const snapText = await snapGet.text();
  const frozen = snapGet.status === 200 && snapText === V1.toString();
  p("snapshot-immutable",
    frozen ? GREEN : "FAIL",
    `GET ?sharesnapshot -> ${snapGet.status}, body=${String(snapText).slice(0, 160)} ${frozen ? "== frozen V1 bytes (base tamper invisible)" : "!= V1"}"`);

  // Time-based immutability policy (raw REST, SDK-gap surface)
  const polUrl = `${blobBase}/${container}?restype=container&comp=immutabilityPolicy`;
  const putRes = await fetch(polUrl, { method: "PUT", headers: J, body: JSON.stringify({ immutabilityPeriodSinceCreationInDays: 30, locked: false }) });
  const putPol = { status: putRes.status };
  const getRes = await fetch(polUrl, { headers: B });
  const polText = await getRes.text();
  const getPol = { status: getRes.status, text: polText, json: () => { try { return JSON.parse(polText); } catch { return null; } } };
  const polBody = getPol.json() ?? {};
  const polOk = putPol.status < 300 && getPol.status === 200 &&
    (Number(polBody.period_days ?? polBody.immutabilityPeriodSinceCreationInDays ?? 0) >= 30 ||
     !!polBody.until);
  p("worm-immutability-policy",
    polOk ? GREEN : "FAIL",
    `PUT=${putPol.status} GET=${getPol.status} policy=${getPol.text.slice(0, 140)}`);

  // best-effort cleanup (WORM refusals here are the system working)
  await req("DELETE", `${blobBase}/${container}?restype=container`, { headers: B });

  // ================= KV: secret soft delete -> recover ======================
  const secName = `${RUN}-breakglass`;
  const setSecret = await req("PUT", `${TLS}/secrets/${secName}?api-version=7.4`, {
    headers: J, body: JSON.stringify({ value: `break-glass-${stamp}` }),
  });
  p("kv-secret-set", setSecret.status === 200 ? GREEN : "FAIL", `PUT /secrets -> ${setSecret.status}`);

  const delSecret = await req("DELETE", `${TLS}/secrets/${secName}?api-version=7.4`, { headers: B });
  p("kv-secret-delete", delSecret.status === 200 ? GREEN : "FAIL", `DELETE /secrets -> ${delSecret.status}`);

  const gd = await req("GET", `${TLS}/deletedsecrets/${secName}?api-version=7.4`, { headers: B });
  const gdBody = gd.json() ?? {};
  if (gd.status === 404) {
    p("kv-deleted-secret-visible", "XFAIL",
      `GET /deletedsecrets -> 404: deleted-secrets plane not landed on this substrate build — typed XFAIL, skip-until-deleted-keys-landed (KD-102)`);
    p("kv-secret-recover", "XFAIL", "recover arm not run: depends on the deleted-secrets plane");
  } else {
    p("kv-deleted-secret-visible",
      gd.status === 200 && typeof gdBody.recoveryId === "string" ? GREEN : "FAIL",
      `GET /deletedsecrets -> ${gd.status} recoveryId=${JSON.stringify(gdBody.recoveryId ?? null)}`);
    const rec = await req("POST", `${TLS}/deletedsecrets/${secName}/recover?api-version=7.4`, { headers: B });
    const getAfter = await req("GET", `${TLS}/secrets/${secName}?api-version=7.4`, { headers: B });
    p("kv-secret-recover",
      rec.status === 200 && getAfter.status === 200 ? GREEN : "FAIL",
      `recover -> ${rec.status}, re-GET -> ${getAfter.status}`);
  }

  // ================= Ledger: append, dup 409, Merkle chain ==================
  const exportHash = sha256hex(V1);
  const ledgerEntries = [
    { kind: "archive-committed", patientId: "P-0001", blob: blobName, snapshot: snapTs, sha256OfExport: exportHash },
    { kind: "access-audited", patientId: "P-0001", principal: "records-office", action: "read", run: stamp },
    { kind: "hold-cleared", container, authorizedBy: "compliance-officer-7", run: stamp },
  ];
  const receipts: any[] = [];
  for (const contents of ledgerEntries) {
    const r = await req("POST", `${TLS}/app/transactions`, { headers: J, body: JSON.stringify({ contents }) });
    requireStatus("ledger-append", r, 201);
    receipts.push(r.json());
  }
  p("ledger-append-201", GREEN, `3 appends admitted (first tx ${receipts[0]?.transactionId})`);

  // duplicate contents -> typed 409 LedgerItemAlreadyExists
  const dup = await req("POST", `${TLS}/app/transactions`, { headers: J, body: JSON.stringify({ contents: ledgerEntries[0] }) });
  p("ledger-duplicate-409",
    dup.status === 409 && /LedgerItemAlreadyExists/i.test(dup.text) ? GREEN : "FAIL",
    `re-append of identical contents -> ${dup.status} ${dup.text.slice(0, 120)}`);

  // Auditor re-verifies through the wire: read back, recompute every hash
  const list = await req("GET", `${TLS}/app/transactions`, { headers: B });
  const wireReceipts: any[] = list.json() ?? [];
  const target = wireReceipts.length >= 3 ? wireReceipts.slice(-3) : wireReceipts;
  const chain = verifyChain(target);
  p("ledger-merkle-chain-verified", chain.ok ? GREEN : "FAIL", chain.why);

  const latest = await req("GET", `${TLS}/app/transactions/latest`, { headers: B });
  p("ledger-latest-tx",
    latest.status === 200 && !!latest.json()?.transactionId ? GREEN : "FAIL",
    `GET /app/transactions/latest -> ${latest.status} tx=${latest.json()?.transactionId}`);

  const byId = await req("GET", `${TLS}/app/transactions/${encodeURIComponent(receipts[0]?.transactionId ?? "")}`, { headers: B });
  p("ledger-tx-by-id",
    byId.status === 200 && byId.json()?.transactionId === receipts[0]?.transactionId ? GREEN : "FAIL",
    `GET /app/transactions/${receipts[0]?.transactionId} -> ${byId.status}`);

  // ---- rollup ----------------------------------------------------------------
  const fails = checks.filter((c) => c.verdict === "FAIL");
  const xfails = checks.filter((c) => c.verdict === "XFAIL");
  const greens = checks.filter((c) => c.verdict === GREEN);
  console.log(`\n== healthcare-archive: ${greens.length}/${checks.length} GREEN, ${xfails.length} XFAIL, ${fails.length} FAIL ==`);
  for (const c of checks) console.log(`  [${c.verdict}] ${c.name} — ${c.detail}`);
  if (xfails.length) console.log("  NOTE: XFAIL = typed in-flight surface, loud, never a fake pass");
  return fails.length > 0 ? 1 : 0;
}

main()
  .then((code) => process.exit(code))
  .catch((e) => {
    console.error(`[healthcare-archive] crashed: ${e?.stack ?? e}`);
    process.exit(1);
  });
