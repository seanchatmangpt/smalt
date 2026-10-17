#!/usr/bin/env node
// sentinel.probe.mjs — KD-37 lane: first real-wire (node fetch, raw HTTP — no
// first-party Azure Monitor ingestion SDK ships a browser/node client for the
// DCR Logs Ingestion + Log Analytics Query pair this emulator serves) probe of
// the Sentinel / Log Analytics surface:
//   POST /dataCollectionRules/:dcr/streams/:stream?api-version=2023-01-01
//   POST /v1/workspaces/:id/query
// over lib/smalt/egress_router.ex's data plane (8443-class port).
//
// Follows test/sdk-full/eventhubs.probe.mjs's self-boot harness: boots the
// smalt substrate (mix run --no-start --no-halt, MIX_ENV=test -> auth
// :anonymous on the data plane) on a private port block so this probe never
// contends the front door or sibling lanes. MIX_ENV=test also gives the data
// plane :anonymous auth (config/test.exs), matching how the other data-plane
// probes (cosmos.probe.mjs) attach.
//
// Run: flock /tmp/smalt-substrate.lock node test/sdk-full/sentinel.probe.mjs
// Exit codes: 0 all pass / 1 probe failure / 2 substrate never up / 3 harness.
import { spawn } from "node:child_process";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import { randomBytes } from "node:crypto";

const REPO = path.resolve(import.meta.dirname, "../..");
// Lane 325 private block: primary Sentinel plane = 39305 (egress), STS plane
// = 39306 (ARM, hosts /oauth2 token mint if a future strict-auth variant
// needs it), TLS twin = 39307. AMQP/EH listeners must also own free ports, so
// they take 39308/39309 (same lane lease, adjacent tail).
const EGRESS_PORT = Number(process.env.SMALT_TSSN_EGRESS_PORT || 39305);
const ARM_PORT = Number(process.env.SMALT_TSSN_ARM_PORT || 39306);
const ARM_TLS_PORT = Number(process.env.SMALT_TSSN_ARM_TLS_PORT || 39307);
const AMQP_PORT = Number(process.env.SMALT_TSSN_AMQP_PORT || 39308);
const EH_PORT = Number(process.env.SMALT_TSSN_EH_PORT || 39309);
const POLL_DEADLINE_MS = 90_000;

const BASE = `http://127.0.0.1:${EGRESS_PORT}`;
const TENANT = "00000000-0000-0000-0000-000000000000";

const RESULTS = [];
const probe = (name, fn) => RESULTS.push({ name, run: fn });

async function main() {
  // SMALT_TSSN_EXTERNAL=1: attach to an already-running substrate (data plane
  // via SMALT_TSSN_EGRESS_PORT).
  const EXTERNAL = process.env.SMALT_TSSN_EXTERNAL === "1";

  const portsFree = EXTERNAL
    ? [true, true, true, true, true]
    : await Promise.all(
        [AMQP_PORT, EH_PORT, ARM_PORT, EGRESS_PORT, ARM_TLS_PORT].map(async (p) => {
          const s = net.connect({ host: "127.0.0.1", port: p, timeout: 1200 });
          return new Promise((resolve) => {
            s.once("connect", () => { s.destroy(); resolve(false); });
            s.once("error", () => resolve(true));
            s.once("timeout", () => { s.destroy(); resolve(true); });
          });
        }),
      );
  if (!portsFree.every(Boolean)) {
    console.error(`[ts-sn-probe] a port in 39305-39309 is occupied — wait or override SMALT_TSSN_*`);
    process.exitCode = 3;
    return;
  }

  const bootEval = [
    `Application.put_env(:smalt, :sb_shared_key, "${randomBytes(48).toString("base64")}")`,
    `Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:${AMQP_PORT}")`,
    `Application.put_env(:smalt, :amqp_port, ${AMQP_PORT})`,
    `Application.put_env(:smalt, :event_hubs_port, ${EH_PORT})`,
    `Application.put_env(:smalt, :arm_port, ${ARM_PORT})`,
    `Application.put_env(:smalt, :egress_port, ${EGRESS_PORT})`,
    `Application.put_env(:smalt, :arm_tls_port, ${ARM_TLS_PORT})`,
    `{:ok, _} = Application.ensure_all_started(:smalt)`,
  ].join("; ");

  const logPath = path.join(REPO, "test/sdk-full/.logs/sentinel-probe-substrate.log");
  fs.mkdirSync(path.dirname(logPath), { recursive: true });
  const logStream = fs.createWriteStream(logPath, { flags: "w" });
  const child = spawn("mix", ["run", "--no-start", "--no-halt", "-e", bootEval], {
    cwd: REPO,
    env: { ...process.env, MIX_ENV: "test" },
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
  });
  child.stdout.pipe(logStream);
  child.stderr.pipe(logStream);

  const killSubstrate = async () => {
    try {
      if (child.pid && child.exitCode === null) {
        try { process.kill(-child.pid, "SIGTERM"); } catch { child.kill("SIGTERM"); }
        const dl = Date.now() + 5000;
        while (child.exitCode === null && Date.now() < dl) await new Promise((r) => setTimeout(r, 200));
        if (child.exitCode === null) process.kill(-child.pid, "SIGKILL");
      }
    } catch { /* gone */ }
  };
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    process.on(sig, () => { killSubstrate(); process.exit(130); });
  }
  process.on("exit", () => {
    try { if (child.pid && child.exitCode === null) process.kill(-child.pid, "SIGKILL"); } catch {}
  });

  const tryConnect = (port) =>
    new Promise((resolve) => {
      const s = net.connect({ host: "127.0.0.1", port, timeout: 1500 });
      s.once("connect", () => { s.destroy(); resolve(true); });
      s.once("error", () => resolve(false));
      s.once("timeout", () => { s.destroy(); resolve(false); });
    });

  const start = Date.now();
  for (;;) {
    const ups = await Promise.all(
      [EGRESS_PORT, ARM_PORT].map(tryConnect),
    );
    if (ups.every(Boolean)) break;
    if (Date.now() - start > POLL_DEADLINE_MS) {
      console.error(`[ts-sn-probe] substrate did not open 39305/39306 in ${POLL_DEADLINE_MS / 1000}s. Log: ${logPath}`);
      await killSubstrate();
      process.exitCode = 2;
      return;
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  console.log(`[ts-sn-probe] substrate up (egress ${EGRESS_PORT}, arm ${ARM_PORT}) after ${Date.now() - start}ms`);

  // --- Sentinel surface probes (raw wire, typed assertions) -----------------

  const DCR = `ts37-dcr-${randomBytes(3).toString("hex")}`;
  const STREAM = "Custom-ts37-logs-cl1";
  // The emulator couples the query workspace id to the DCR name (query lists
  // stored rows under "#{workspace_id}/", ingest stores under "#{dcr}/").
  // Real Log Analytics queries by workspace, independent of DCR — recorded as
  // a divergence note in the KD-37 receipt, not papered over here.
  const WS = DCR;
  const ingestUrl = `${BASE}/dataCollectionRules/${DCR}/streams/${STREAM}?api-version=`;

  const rows = [
    { Time: "t1", msg: "sentinel ingest witness one", lvl: "a", n: 1 },
    { Time: "t2", msg: "sentinel ingest witness two", lvl: "b", n: 2 },
  ];

  probe("dcr-ingest: 204 + x-ms-request-id (api-version 2023-01-01)", async () => {
    const res = await fetch(`${ingestUrl}2023-01-01`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(rows),
    });
    if (res.status !== 204) throw new Error(`status ${res.status}: ${(await res.text()).slice(0, 200)}`);
    const rid = res.headers.get("x-ms-request-id");
    if (!rid) throw new Error("204 without x-ms-request-id header");
    return `status=204 x-ms-request-id=${rid}`;
  });

  probe("dcr-ingest: wrong api-version (2022-10-27) -> typed 400 InvalidApiVersion", async () => {
    const res = await fetch(`${ingestUrl}2022-10-27`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(rows),
    });
    if (res.status !== 400) throw new Error(`expected 400, got ${res.status}`);
    const body = await res.json();
    const code = body?.error?.code;
    if (code !== "InvalidApiVersion") throw new Error(`wrong error code: ${JSON.stringify(body).slice(0, 200)}`);
    return `status=400 code=InvalidApiVersion msg=${JSON.stringify(body?.error?.message).slice(0, 120)}`;
  });

  probe("dcr-ingest: missing api-version -> typed 400 InvalidApiVersion", async () => {
    const res = await fetch(`${BASE}/dataCollectionRules/${DCR}/streams/${STREAM}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(rows),
    });
    if (res.status !== 400) throw new Error(`expected 400, got ${res.status}`);
    const body = await res.json();
    if (body?.error?.code !== "InvalidApiVersion") throw new Error(`wrong code: ${JSON.stringify(body).slice(0, 200)}`);
    return `status=400 code=InvalidApiVersion (absent param)`;
  });

  probe("dcr-ingest: non-object record -> typed 400 InvalidData", async () => {
    const res = await fetch(`${ingestUrl}2023-01-01`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify([rows[0], null]),
    });
    if (res.status !== 400) throw new Error(`expected 400, got ${res.status}`);
    const body = await res.json();
    if (body?.error?.code !== "InvalidData") throw new Error(`wrong code: ${JSON.stringify(body).slice(0, 200)}`);
    return `status=400 code=InvalidData (null record refused, no partial insert)`;
  });

  probe("query: roundtrip ingested rows (no api-version — real SDK wire shape)", async () => {
    const res = await fetch(`${BASE}/v1/workspaces/${WS}/query`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query: "Custom-Logs | take 10" }),
    });
    if (res.status !== 200) throw new Error(`status ${res.status}: ${(await res.text()).slice(0, 200)}`);
    const body = await res.json();
    const table = body?.tables?.[0];
    if (table?.name !== "PrimaryResult") throw new Error(`no PrimaryResult: ${JSON.stringify(body).slice(0, 200)}`);
    const cols = table.columns.map((c) => c.name);
    // DIVERGENCE (KD candidate, recorded in the receipt): the emulator does NOT
    // materialize TimeGenerated on ingest — it preserves the row's own keys
    // (here "Time") and only lists TimeGenerated in the empty-result column
    // set (@base_columns). Real Log Analytics always stamps TimeGenerated.
    for (const need of ["eventId", "sha256Hash", "ledgerId", "tenantId", "subjectSha256"]) {
      if (!cols.includes(need)) throw new Error(`augmented column ${need} missing; cols=${cols.join(",")}`);
    }
    const msgs = table.rows.map((r) => r[cols.indexOf("msg")]);
    for (const want of ["sentinel ingest witness one", "sentinel ingest witness two"]) {
      if (!msgs.includes(want)) throw new Error(`ingested row missing from query: ${msgs.slice(0, 4)}`);
    }
    return `rows=${table.rows.length} cols=${cols.length} roundtrip ok (both witnesses present)`;
  });

  probe("query: api-version=2023-01-01 accepted", async () => {
    const res = await fetch(`${BASE}/v1/workspaces/${WS}/query?api-version=2023-01-01`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query: "Custom-Logs | take 5" }),
    });
    if (res.status !== 200) throw new Error(`status ${res.status}: ${(await res.text()).slice(0, 200)}`);
    const body = await res.json();
    if (body?.tables?.[0]?.name !== "PrimaryResult") throw new Error("no PrimaryResult");
    return `status=200 PrimaryResult rows=${body.tables[0].rows.length}`;
  });

  probe("query: wrong api-version (2021-08-27) -> typed 400 InvalidApiVersion", async () => {
    const res = await fetch(`${BASE}/v1/workspaces/${WS}/query?api-version=2021-08-27`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query: "Custom-Logs | take 5" }),
    });
    if (res.status !== 400) throw new Error(`expected 400, got ${res.status}`);
    const body = await res.json();
    if (body?.error?.code !== "InvalidApiVersion") throw new Error(`wrong code: ${JSON.stringify(body).slice(0, 200)}`);
    return `status=400 code=InvalidApiVersion (query route gate, R173)`;
  });

  probe("query: KQL pipeline where | project order preserved", async () => {
    const res = await fetch(`${BASE}/v1/workspaces/${WS}/query`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query: 'Custom-Logs | where lvl == "a" | project msg, n' }),
    });
    if (res.status !== 200) throw new Error(`status ${res.status}: ${(await res.text()).slice(0, 200)}`);
    const body = await res.json();
    const table = body?.tables?.[0];
    const colNames = table.columns.map((c) => c.name);
    if (JSON.stringify(colNames) !== JSON.stringify(["msg", "n"])) {
      throw new Error(`project order not preserved: ${colNames.join(",")}`);
    }
    if (table.rows.length !== 1 || table.rows[0][0] !== "sentinel ingest witness one") {
      throw new Error(`where filter wrong: ${JSON.stringify(table.rows).slice(0, 200)}`);
    }
    return `pipeline where|project: 1 row (lvl==a), cols=[msg,n] in order`;
  });

  probe("query: bare operator without pipe -> typed 400 BadQuery", async () => {
    const res = await fetch(`${BASE}/v1/workspaces/${WS}/query`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query: 'where lvl == "a"' }),
    });
    if (res.status !== 400) throw new Error(`expected 400, got ${res.status}`);
    const body = await res.json();
    if (body?.error?.code !== "BadQuery") throw new Error(`wrong code: ${JSON.stringify(body).slice(0, 200)}`);
    return `status=400 code=BadQuery (R26 parse-error gate)`;
  });

  // --- Summary ---------------------------------------------------------------
  let pass = 0;
  const receipts = [];
  for (const p of RESULTS) {
    let status = "PASS";
    let detail = "";
    try {
      detail = String(await p.run());
    } catch (e) {
      status = "FAIL";
      detail = `${e?.name}: ${e?.message}`.slice(0, 400);
    }
    if (status === "PASS") pass++;
    receipts.push({ name: p.name, status, detail });
    console.log(`[${status}] ${p.name} — ${detail}`);
  }
  console.log(`\nSUMMARY: ${pass}/${RESULTS.length} PASS, ${RESULTS.length - pass} FAIL`);
  console.log(JSON.stringify(receipts, null, 2));
  process.exitCode = pass === RESULTS.length ? 0 : 1;
  // Explicit teardown + exit: the detached substrate child's piped stdio and
  // the open log WriteStream otherwise hold the event loop (and the beam)
  // alive after SUMMARY.
  await killSubstrate();
  logStream.end();
  process.exit(pass === RESULTS.length ? 0 : 1);
}

main().catch((e) => {
  console.error(`[ts-sn-probe] harness error: ${e?.name}: ${e?.message}`);
  process.exitCode = 3;
});
