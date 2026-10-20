// diagnostics.probe.mjs — ERRC CREATE lane: diagnostics/monitoring stack probe.
// Target: Sentinel/Log Analytics DCR ingest + KQL query engine, KQL typed
// parse errors, and the microsoft.insights/metrics ARM surface.
// Cells (each tagged per the workflows.json receipt grammar):
//   1. sentinel:dcr-ingest-kql-aggregate — 10-row DCR ingest, aggregated back
//      through `| where TimeGenerated > ago(1h) | summarize count() by Level |
//      sort by count_ desc`; table must match the ingested distribution.
//   2. sentinel:kql-typed-parse-error — unknown pipeline operator -> 400
//      BadQuery with SYN code + byte position.
//   3. arm:monitor-metrics-emit-query — POST custom metric emit then GET the
//      bucketed series back (surface landed; no SKIP expected). Plus monotonic
//      api-version refusal (KD-78 shape, FUTURE version pin per corpus law).
//   4. sentinel:table-stats — typed SKIP: no multi-table stats surface exists
//      on the egress/ARM routers (owning surface: Sentinel/LA workspace tables
//      ARM family — no route landed).
// Run: node verification/ts/diagnostics.probe.mjs
// Boots its own private substrate on v-block v15 (scripts/substrate-ctl port
// shape: 39700 + 10*blockNo..+5), sweeps it down after. Exit contract:
// 0 pass-or-typed-skip / 1 hard FAIL / 2 substrate/boot fail.
import { spawn, spawnSync } from "node:child_process";
import https from "node:https";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import net from "node:net";

function tryConnect(port, host = "127.0.0.1", timeoutMs = 500) {
  return new Promise((resolve) => {
    const s = net.connect({ host, port, timeout: timeoutMs });
    s.once("connect", () => { s.destroy(); resolve(true); });
    s.once("timeout", () => { s.destroy(); resolve(false); });
    s.once("error", () => resolve(false));
  });
}

const REPO = path.resolve(import.meta.dirname, "../..");
const CTL = path.join(REPO, "scripts/substrate-ctl");
const BLOCK = process.env.DIAG_BLOCK ?? "v15";
const CA = fs.readFileSync(path.join(REPO, ".smalt/tls/ca-cert.pem"));
const TENANT = "00000000-0000-0000-0000-000000000000";
const SUB = "11111111-1111-1111-1111-111111111111";
const APIV = "2021-04-01";
const SENTINEL_APIV = "2023-01-01";
const METRICS_APIV = "2024-02-01"; // Smalt.Metrics @latest_api_version

const cells = [];
function cell(tag, verdict, detail) {
  cells.push({ tag, verdict, detail });
  console.log(`[${verdict}] ${tag} — ${detail}`);
}

const agent = new https.Agent({ ca: CA, rejectUnauthorized: true, keepAlive: true });

function req(method, url, { headers = {}, body = null } = {}) {
  return new Promise((resolve) => {
    const u = new URL(url);
    const isHttps = u.protocol === "https:";
    const mod = isHttps ? https : http;
    const r = mod.request(
      {
        hostname: u.hostname,
        port: u.port,
        path: u.pathname + u.search,
        method,
        agent: isHttps ? agent : undefined,
        servername: "localhost",
        headers,
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          resolve({
            status: res.statusCode,
            headers: res.headers,
            text,
            json() {
              try { return JSON.parse(text); } catch { return null; }
            },
          });
        });
      },
    );
    r.on("error", (e) =>
      resolve({ status: 0, headers: {}, text: `transport: ${e.message}`, json: () => null }));
    r.end(body);
  });
}

async function down() {
  spawnSync(CTL, ["down", "--block", BLOCK, "--mode", "sweep"], { timeout: 60_000 });
}

async function main() {
  // ---- private substrate, bootPrivate shape (known SB shared key) ---------
  spawnSync(CTL, ["down", "--block", BLOCK, "--mode", "sweep"], { timeout: 60_000 });
  const n = Number(BLOCK.slice(1));
  const ports = [0, 1, 2, 3, 4, 5].map((i) => 39700 + 10 * n + i);
  const [amqpPort, ehPort, armPort, egressPort, tlsPort, mcpPort] = ports;
  const certDir = path.join(REPO, ".smalt/tls");
  const sharedKey = Buffer.from(`${BLOCK}-${Date.now()}-diagnostics`).toString("base64");
  const bootEval = [
    `Application.put_env(:smalt, :sb_shared_key, "${sharedKey}")`,
    `Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:${amqpPort}")`,
    `Application.put_env(:smalt, :amqp_port, ${amqpPort})`,
    `Application.put_env(:smalt, :event_hubs_port, ${ehPort})`,
    `Application.put_env(:smalt, :arm_port, ${armPort})`,
    `Application.put_env(:smalt, :egress_port, ${egressPort})`,
    `Application.put_env(:smalt, :arm_tls_port, ${tlsPort})`,
    `Application.put_env(:smalt, :mcp_port, ${mcpPort})`,
    `Application.put_env(:smalt, :auth_mode, :enforce)`,
    `{:ok, _} = Application.ensure_all_started(:smalt)`,
  ].join("; ");
  fs.mkdirSync("/tmp/smalt-substrate-state/logs", { recursive: true });
  const logFd = fs.openSync(`/tmp/smalt-substrate-state/logs/${BLOCK}.log`, "w");
  const child = spawn("mix", ["run", "--no-start", "--no-halt", "-e", bootEval], {
    cwd: REPO,
    env: {
      ...process.env,
      MIX_ENV: "test",
      SMALT_TLS_CERTFILE: path.join(certDir, "dev-cert.pem"),
      SMALT_TLS_KEYFILE: path.join(certDir, "dev-key.pem"),
    },
    stdio: ["ignore", logFd, logFd],
    detached: true,
  });
  fs.closeSync(logFd);
  const allUp = async () =>
    (await Promise.all(ports.map((p) => tryConnect(p)))).every(Boolean);
  const deadline = Date.now() + 90_000;
  for (;;) {
    let ok = false;
    if (await allUp()) {
      const h = await fetch(`http://127.0.0.1:${armPort}/metadata/endpoints`)
        .then((x) => x.status).catch(() => 0);
      ok = h === 200;
    }
    if (ok) break;
    if (Date.now() > deadline) {
      try { process.kill(-child.pid, "SIGKILL"); } catch {}
      console.error(`substrate ${BLOCK} not healthy in 90s (log: /tmp/smalt-substrate-state/logs/${BLOCK}.log)`);
      process.exit(2);
    }
    await new Promise((res) => setTimeout(res, 250)); // SLEEP-CLASS: POLL-STEP
  }
  console.error(`[diagnostics] substrate ${BLOCK} up pid=${child.pid} ports=${ports.join(",")}`);
  void amqpPort; void ehPort; void mcpPort;
  const arm = `http://127.0.0.1:${armPort}`;
  const tls = `https://localhost:${tlsPort}`;
  const egress = `http://127.0.0.1:${egressPort}`;
  // ---- STS token (enforce mode) -------------------------------------------
  const tokRes = await req("POST", `${tls}/${TENANT}/oauth2/v2.0/token`, {
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: TENANT,
      client_secret: "smalt-tf-mock-secret",
      scope: "https://management.azure.com/.default",
    }).toString(),
  });
  const token = tokRes.json()?.access_token;
  if (!token) {
    console.error(`STS failed: ${tokRes.status} ${tokRes.text.slice(0, 200)}`);
    await down();
    process.exit(2);
  }
  const B = { Authorization: `Bearer ${token}` };
  const J = { "content-type": "application/json", ...B };
  const stamp = Date.now() % 100000;

  // ====== Cell 1: DCR ingest -> KQL aggregate round-trip ===================
  try {
    const dcr = `diag-dcr-${stamp}`;
    const stream = "Custom-Logs";
    // Distribution: warn=5, error=3, info=2 (10 rows), TimeGenerated = now.
    const dist = [["warn", 5], ["error", 3], ["info", 2]];
    const rows = dist.flatMap(([lvl, n], gi) =>
      Array.from({ length: n }, (_, i) => ({
        TimeGenerated: new Date().toISOString(),
        Level: lvl,
        batch: gi,
        msg: `diag row ${gi}-${i}`,
      })),
    );
    const ing = await req(
      "POST",
      `${egress}/dataCollectionRules/${dcr}/streams/${stream}?api-version=${SENTINEL_APIV}`,
      { headers: J, body: JSON.stringify(rows) },
    );
    const qRes = await req(
      "POST",
      `${egress}/v1/workspaces/${dcr}/query?api-version=${SENTINEL_APIV}`,
      {
        headers: J,
        body: JSON.stringify({
          query: "Custom-Logs | where TimeGenerated > ago(1h) | summarize count() by Level | sort by count_ desc",
        }),
      },
    );
    const table = qRes.json()?.tables?.[0];
    const colNames = (table?.columns ?? []).map((c) => c.name);
    const gotRows = table?.rows ?? [];
    const gotDist = gotRows.map(([lvl, cnt]) => [lvl, Number(cnt)]);
    const countsOk =
      JSON.stringify(gotDist.map(([l, c]) => [l, c]).sort((a, b) => a[0].localeCompare(b[0]))) ===
      JSON.stringify([["error", 3], ["info", 2], ["warn", 5]]);
    const descOk = gotDist.every(([, c], i) => i === 0 || gotDist[i - 1][1] >= c);
    const ok =
      ing.status === 204 &&
      typeof ing.headers["x-ms-request-id"] === "string" &&
      ing.headers["x-ms-request-id"] !== "" &&
      qRes.status === 200 &&
      table?.name === "PrimaryResult" &&
      colNames.includes("Level") &&
      colNames.includes("count_") &&
      countsOk &&
      descOk;
    cell(
      "sentinel:dcr-ingest-kql-aggregate",
      ok ? "PASS" : "FAIL",
      `ingest=${ing.status} requestId=${ing.headers["x-ms-request-id"] ? "yes" : "no"} ` +
      `query=${qRes.status} table=${table?.name} cols=${JSON.stringify(colNames)} ` +
      `rows=${JSON.stringify(gotDist)} descOk=${descOk}` +
      (qRes.status !== 200 ? ` — body: ${qRes.text.slice(0, 200)}` : ""),
    );
  } catch (e) {
    cell("sentinel:dcr-ingest-kql-aggregate", "FAIL", `${e?.name}: ${String(e?.message).slice(0, 160)}`);
  }

  // ====== Cell 2: KQL typed parse error (SYN code + position) ==============
  try {
    const dcr = `diag-dcr-${stamp}`;
    const r = await req(
      "POST",
      `${egress}/v1/workspaces/${dcr}/query?api-version=${SENTINEL_APIV}`,
      {
        headers: J,
        body: JSON.stringify({
          query: "Custom-Logs | where Level == 'warn' | frobnicate by Level",
        }),
      },
    );
    const body = r.json() ?? {};
    const msg = body?.error?.message ?? "";
    const syn = msg.match(/SYN\d{4}/)?.[0] ?? null;
    const pos = msg.match(/\(position (\d+)\)/)?.[1] ?? null;
    const ok =
      r.status === 400 &&
      body?.error?.code === "BadQuery" &&
      syn !== null &&
      pos !== null &&
      Number(pos) > 0;
    cell(
      "sentinel:kql-typed-parse-error",
      ok ? "PASS" : "FAIL",
      `status=${r.status} code=${JSON.stringify(body?.error?.code ?? null)} ` +
      `syn=${JSON.stringify(syn)} position=${JSON.stringify(pos)} msg=${JSON.stringify(msg.slice(0, 160))}`,
    );
  } catch (e) {
    cell("sentinel:kql-typed-parse-error", "FAIL", `${e?.name}: ${String(e?.message).slice(0, 160)}`);
  }

  // ====== Cell 3: microsoft.insights/metrics emit + query (ARM plane) ======
  try {
    const rg = "diag-rg";
    await req("PUT", `${arm}/subscriptions/${SUB}/resourceGroups/${rg}?api-version=${APIV}`, {
      headers: J,
      body: JSON.stringify({ location: "local" }),
    });
    const ns = `diag-sb-${stamp}`;
    const putNs = await req(
      "PUT",
      `${arm}/subscriptions/${SUB}/resourceGroups/${rg}/providers/Microsoft.ServiceBus/namespaces/${ns}?api-version=${APIV}`,
      { headers: J, body: JSON.stringify({ location: "local", skuName: "Standard" }) },
    );
    const resBase =
      `${arm}/subscriptions/${SUB}/resourceGroups/${rg}` +
      `/providers/Microsoft.ServiceBus/namespaces/${ns}/providers/microsoft.insights/metrics`;
    // POST emit a custom metric point.
    const emit = await req("POST", `${resBase}?api-version=${METRICS_APIV}`, {
      headers: J,
      body: JSON.stringify({ metric: "diagQueueDepth", value: 42, unit: "Count" }),
    });
    // GET the series back.
    const getM = await req(
      "GET",
      `${resBase}?api-version=${METRICS_APIV}&metricnames=diagQueueDepth&timespan=PT1H`,
      { headers: B },
    );
    const series = getM.json()?.value?.[0];
    const ok =
      putNs.status < 300 &&
      emit.status === 200 &&
      getM.status === 200 &&
      Array.isArray(getM.json()?.value) &&
      getM.json().value.length > 0;
    // Monotonic api-version refusal (KD-78 shape; FUTURE version pin).
    const badV = await req("GET", `${resBase}?api-version=2099-01-01`, { headers: B });
    const badVOk =
      badV.status === 400 &&
      (badV.json()?.error?.code === "InvalidApiVersionParameter" ||
        /InvalidApiVersion/i.test(badV.text));
    cell(
      "arm:monitor-metrics-emit-query",
      ok && badVOk ? "PASS" : "FAIL",
      `putNamespace=${putNs.status} emit=${emit.status} query=${getM.status} ` +
      `seriesCount=${getM.json()?.value?.length ?? 0} ` +
      `futureApiVersion=${badV.status}/${JSON.stringify(badV.json()?.error?.code ?? null)}` +
      (emit.status === 404 ? " — metrics emit arm answered 404 ResourceNotFound" : "") +
      (!badVOk ? " — monotonic api-version refusal missing" : ""),
    );
  } catch (e) {
    cell("arm:monitor-metrics-emit-query", "FAIL", `${e?.name}: ${String(e?.message).slice(0, 160)}`);
  }

  // ====== Cell 4: sentinel table stats — typed SKIP ========================
  // No multi-table stats surface (workspace tables ARM family) is routed on
  // the egress or ARM gateways: no GET .../tables, no tableStats route. SKIP
  // names the owning surface; flip to a real probe when the lane lands.
  cell(
    "sentinel:table-stats",
    "SKIP",
    "not-landed — owning surface: Sentinel/Log Analytics workspace tables ARM family " +
    "(GET workspaces/:id/tables) — no route on egress_router.ex or arm_gateway/router.ex",
  );

  await down();

  const hard = cells.filter((c) => c.verdict === "FAIL");
  console.log(JSON.stringify({ lane: "wf6-diagnostics", cells, hardFails: hard.length }));
  process.exit(hard.length ? 1 : 0);
}

main().catch(async (e) => {
  console.error(`diagnostics probe crashed: ${e?.stack ?? e}`);
  await down();
  process.exit(2);
});
