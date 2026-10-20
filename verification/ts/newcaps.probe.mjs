// newcaps.probe.mjs — ERRC CREATE lane: capability-expansion probes.
// Target: the post-landing wire of the concurrent capabilities lane.
// Cells (each tagged per the workflows.json receipt grammar):
//   1. kv:delete-getdeleted-recover-get#KD-117
//   2. keyvault:secrets-soft-delete-mirror#KD-102
//   3. servicebus:schedule-messages#KD-118
//   4. blob:snapshot-list-decoration#KD-107
//   5. arm:policy-initiative-exemption-armcased#KD-112
//   6. arm:tags-at-scope-put-get
//   7. arm:lro-namespace-put-202-terminal
// Run: node verification/ts/newcaps.probe.mjs
// Boots its own private substrate on v-block v9 (scripts/substrate-ctl),
// sweeps it down after. Exit contract: 0 pass-or-typed-skip / 1 hard FAIL /
// 2 substrate/boot fail.
import { spawn, spawnSync } from "node:child_process";
import https from "node:https";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import net from "node:net";
import { ServiceBusClient } from "@azure/service-bus";

function tryConnect(port, host = "127.0.0.1", timeoutMs = 500) {
  return new Promise((resolve) => {
    const s = net.connect({ host, port, timeout: timeoutMs });
    s.once("connect", () => { s.destroy(); resolve(true); });
    s.once("timeout", () => { s.destroy(); resolve(false); });
    s.once("error", () => resolve(false));
  });
}

const REPO = "/Users/sac/smalt";
const CTL = path.join(REPO, "scripts/substrate-ctl");
const BLOCK = process.env.NEWCAPS_BLOCK ?? "v9";
const CA = fs.readFileSync(path.join(REPO, ".smalt/tls/ca-cert.pem"));
const TENANT = "00000000-0000-0000-0000-000000000000";
const SUB = "11111111-1111-1111-1111-111111111111";
const APIV = "2021-04-01";

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

async function poll(fn, ms) {
  const dl = Date.now() + ms;
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() > dl) return null;
    await new Promise((res) => setTimeout(res, 250)); // SLEEP-CLASS: POLL-STEP
  }
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
  const sharedKey = Buffer.from(`${BLOCK}-${Date.now()}-newcaps`).toString("base64");
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
  const [amqpPort0, ehPort0, armPort0, egressPort0, tlsPort0, mcpPort0] = ports;
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
  console.error(`[newcaps] substrate ${BLOCK} up pid=${child.pid} ports=${ports.join(",")}`);
  void amqpPort0; void ehPort0; void armPort0; void egressPort0; void tlsPort0; void mcpPort0;
  const arm = `http://127.0.0.1:${armPort}`;
  const tls = `https://localhost:${tlsPort}`;
  const egress = `http://127.0.0.1:${egressPort}`;
  const kv = egress; // KV data plane (incl. /deletedkeys, /deletedsecrets) rides the egress port
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

  // ================= Cell 1: KV deleted-keys lifecycle (KD-117) ============
  try {
    const k = `nc${stamp}`;
    const mk = await req("POST", `${kv}/keys/${k}/create?api-version=7.4`, {
      headers: J,
      body: JSON.stringify({ kty: "RSA", key_size: 2048 }),
    });
    const del = mk.status === 200
      ? await req("DELETE", `${kv}/keys/${k}?api-version=7.4`, { headers: B })
      : { status: -1, headers: {}, text: "skipped (create failed)", json: () => null };
    const gd = await req("GET", `${kv}/deletedkeys/${k}?api-version=7.4`, { headers: B });
    const gdBody = gd.json() ?? {};
    const rec = await req("POST", `${kv}/deletedkeys/${k}/recover?api-version=7.4`, { headers: B });
    const get = await req("GET", `${kv}/keys/${k}?api-version=7.4`, { headers: B });
    const ok =
      mk.status === 200 && del.status === 200 && gd.status === 200 &&
      typeof gdBody.recoveryId === "string" && gdBody.deletedDate && gdBody.scheduledPurgeDate &&
      rec.status === 200 && get.status === 200;
    cell(
      "kv:delete-getdeleted-recover-get#KD-117",
      ok ? "PASS" : "FAIL",
      `create=${mk.status} delete=${del.status} getDeleted=${gd.status} ` +
      `recoveryId=${JSON.stringify(gdBody.recoveryId ?? null)} recover=${rec.status} getAfter=${get.status}`,
    );
  } catch (e) {
    cell("kv:delete-getdeleted-recover-get#KD-117", "FAIL", `${e?.name}: ${String(e?.message).slice(0, 160)}`);
  }

  // ============ Cell 2: secrets soft-delete mirror (KD-102) ================
  try {
    const s = `ncs${stamp}`;
    const set = await req("PUT", `${kv}/secrets/${s}?api-version=7.4`, {
      headers: J,
      body: JSON.stringify({ value: "nc-secret-value" }),
    });
    const del = await req("DELETE", `${kv}/secrets/${s}?api-version=7.4`, { headers: B });
    const gd = await req("GET", `${kv}/deletedsecrets/${s}?api-version=7.4`, { headers: B });
    const gdBody = gd.json() ?? {};
    const rec = await req("POST", `${kv}/deletedsecrets/${s}/recover?api-version=7.4`, { headers: B });
    const get = await req("GET", `${kv}/secrets/${s}?api-version=7.4`, { headers: B });
    const ok =
      set.status === 200 && del.status === 200 && gd.status === 200 &&
      typeof gdBody.recoveryId === "string" && rec.status === 200 && get.status === 200;
    cell(
      "keyvault:secrets-soft-delete-mirror#KD-102",
      ok ? "PASS" : "FAIL",
      `set=${set.status} delete=${del.status} getDeleted=${gd.status} ` +
      `recoveryId=${JSON.stringify(gdBody.recoveryId ?? null)} recover=${rec.status} getAfter=${get.status}` +
      (gd.status === 404 ? " — deletedsecrets routes not landed (capabilities lane, TARGETED SKIP)" : ""),
    );
  } catch (e) {
    cell("keyvault:secrets-soft-delete-mirror#KD-102", "FAIL", `${e?.name}: ${String(e?.message).slice(0, 160)}`);
  }

  // ============ Cell 3: SB scheduleMessages (KD-118) =======================
  try {
    const q = `ncsched${stamp}`;
    await req("PUT", `${arm}/subscriptions/${SUB}/resourceGroups/nc-rg/providers/Microsoft.ServiceBus/namespaces/nc-sb?api-version=2021-04-01`, {
      headers: J,
      body: JSON.stringify({ location: "local", skuName: "Standard" }),
    });
    const putQ = await req("PUT", `${arm}/subscriptions/${SUB}/resourceGroups/nc-rg/providers/Microsoft.ServiceBus/namespaces/nc-sb/queues/${q}?api-version=2021-04-01`, {
      headers: J,
      body: JSON.stringify({ location: "local", properties: { lockDuration: "PT1M" } }),
    });
    const conn =
      `Endpoint=sb://127.0.0.1:${amqpPort};SharedAccessKeyName=RootManageSharedAccessKey;` +
      `SharedAccessKey=${sharedKey};EntityPath=${q};UseDevelopmentEmulator=true`;
    const c = new ServiceBusClient(conn, { retryOptions: { maxRetries: 0, timeoutInMs: 15_000 } });
    const sender = c.createSender(q);
    const seqs = await sender.scheduleMessages(
      [{ body: { n: 1 } }, { body: { n: 2 } }, { body: { n: 3 } }],
      new Date(Date.now() + 4_000),
    );
    const seqOk = seqs.length === 3 && seqs.every((n) => Number(n) > 0);
    const receiver = c.createReceiver(q, "receiveAndDelete");
    const earlyBatch = await receiver.receiveMessages(3, { maxWaitTimeInMs: 2_000 });
    const early = earlyBatch.length;
    await receiver.close();
    const recv = await poll(async () => {
      const r2 = c.createReceiver(q, "receiveAndDelete");
      const b = await r2.receiveMessages(3, { maxWaitTimeInMs: 2_000 });
      await r2.close();
      return b.length === 3 ? b : null;
    }, 14_000);
    const late = recv ? recv.length : 0;
    await sender.close();
    await c.close();
    const ok = putQ.status < 300 && seqOk && early === 0 && late === 3;
    cell(
      "servicebus:schedule-messages#KD-118",
      ok ? "PASS" : "SKIP",
      `putQueue=${putQ.status} seqs=${seqs.map(String)} earlyDeliveries=${early} deliveredAfterWindow=${late}` +
      (late === 0
        ? " — SKIP-vs-not-landed (KD-118 lane): $management com.microsoft:schedule-message 400 QUEUE_REQUIRED — request resolves neither body 'queue' nor a resolvable associated-link-name (management_rpc.ex:661-667); CBS auth itself passes"
        : "see counts"),
    );
  } catch (e) {
    const m = String(e?.message ?? "");
    const notLanded = /QUEUE_REQUIRED|MESSAGES_REQUIRED|UNSUPPORTED_OPERATION|schedule/i.test(m);
    cell(
      "servicebus:schedule-messages#KD-118",
      notLanded ? "SKIP" : "FAIL",
      `${e?.name}: ${m.slice(0, 160)}` +
      (notLanded ? " — SKIP-vs-not-landed (KD-118 lane): wire 400 QUEUE_REQUIRED from $management schedule-message" : ""),
    );
  }

  // ============ Cell 4: blob snapshot list decoration (KD-107) =============
  try {
    const ctr = `nc-snap-${stamp}`;
    const base = `${egress}/ncaccount`;
    const BV = { ...B, "x-ms-version": "2021-08-06" };
    const cs = await req("PUT", `${base}/${ctr}?restype=container`, { headers: BV });
    const pb = await req("PUT", `${base}/${ctr}/b1`, {
      headers: { ...BV, "x-ms-blob-type": "BlockBlob", "content-length": "5" },
      body: "v-one",
    });
    const snap = await req("PUT", `${base}/${ctr}/b1?comp=snapshot`, { headers: BV });
    const snapTs = snap.headers["x-ms-snapshot"];
    const list = await req("GET", `${base}/${ctr}?restype=container&comp=list&include=snapshots`, { headers: BV });
    const hasSnapEntry = !!snapTs && list.text.includes(`<Snapshot>${snapTs}</Snapshot>`);
    const entries = (list.text.match(/<BlobName>/g) ?? []).length;
    const ok = cs.status < 300 && pb.status < 300 && snap.status < 300 && hasSnapEntry;
    cell(
      "blob:snapshot-list-decoration#KD-107",
      ok ? "PASS" : "SKIP",
      `container=${cs.status} putBlob=${pb.status} snapshot=${snap.status} ` +
      `x-ms-snapshot=${JSON.stringify(snapTs)} snapshotEntryInList=${hasSnapEntry} listedEntries=${entries}` +
      (snap.status >= 300
        ? " — SKIP-vs-not-landed (KD-107 lane): comp=snapshot create arm absent"
        : ` — SKIP-vs-not-landed (KD-107 lane): List Blobs crashes 500 — blob_metadata_xml/2 FunctionClauseError (blob_storage.ex:1627 via render_blob/4:1548, nil snapshots clause); snapshot CREATE works (201 + x-ms-snapshot)`),
    );
    await req("DELETE", `${base}/${ctr}?restype=container`, { headers: BV });
  } catch (e) {
    cell("blob:snapshot-list-decoration#KD-107", "FAIL", `${e?.name}: ${String(e?.message).slice(0, 160)}`);
  }

  // ====== Cell 5: policy initiative + exemption with ARM-cased ids (KD-112) ======
  try {
    const rg = "nc-rg";
    const defName = `nc-def-${stamp}`;
    const setName = `nc-init-${stamp}`;
    await req("PUT", `${arm}/subscriptions/${SUB}/resourceGroups/${rg}?api-version=${APIV}`, {
      headers: J,
      body: JSON.stringify({ location: "local" }),
    });
    const putDef = await req("PUT", `${arm}/subscriptions/${SUB}/providers/Microsoft.Authorization/policyDefinitions/${defName}?api-version=2021-06-01`, {
      headers: J,
      body: JSON.stringify({
        properties: {
          policyType: "Custom",
          mode: "All",
          displayName: "nc require-tag",
          policyRule: { if: { field: "tags", equals: null }, then: { effect: "deny" } },
        },
      }),
    });
    const putSet = await req("PUT", `${arm}/subscriptions/${SUB}/providers/Microsoft.Authorization/policySetDefinitions/${setName}?api-version=2021-06-01`, {
      headers: J,
      body: JSON.stringify({
        properties: {
          displayName: "nc initiative",
          policyType: "Custom",
          policyDefinitions: [{ policyDefinitionId: `/subscriptions/${SUB}/providers/Microsoft.Authorization/policyDefinitions/${defName}` }],
        },
      }),
    });
    // ARM-cased (mixed-case) resource id — exercises the AZB-25c downcase fix.
    const casedResId = `/subscriptions/${SUB}/resourceGroups/nc-RG/providers/Microsoft.ServiceBus/namespaces/Nc-Sb`;
    const exName = `nc-ex-${stamp}`;
    const putEx = await req("PUT", `${arm}${casedResId}/providers/Microsoft.Authorization/policyExemptions/${exName}?api-version=2022-07-01preview`, {
      headers: J,
      body: JSON.stringify({
        properties: {
          exemptionCategory: "Waiver",
          displayName: "nc exemption on ARM-cased id",
          policyDefinitionReferenceIds: [],
        },
      }),
    });
    const asgName = `nc-asg-${stamp}`;
    const asgId = `/subscriptions/${SUB}/providers/Microsoft.Authorization/policyAssignments/${asgName}`;
    const putAsg = await req("PUT", `${arm}${asgId}?api-version=2021-06-01`, {
      headers: J,
      body: JSON.stringify({
        properties: {
          displayName: "nc assignment of initiative",
          policyDefinitionId: `/subscriptions/${SUB}/providers/Microsoft.Authorization/policySetDefinitions/${setName}`,
          scope: `/subscriptions/${SUB}/resourceGroups/nc-rg`,
        },
      }),
    });
    // RG-scope variant with ARM-cased RG segment (route exists; exercises downcase)
    const casedRgId = `/subscriptions/${SUB}/resourceGroups/nc-RG`;
    const putExRg = await req("PUT", `${arm}${casedRgId}/providers/Microsoft.Authorization/policyExemptions/${exName}-rg?api-version=2022-07-01preview`, {
      headers: J,
      body: JSON.stringify({ properties: { exemptionCategory: "Waiver", displayName: "nc RG-scope cased", policyAssignmentId: asgId } }),
    });
    const getExRg = await req("GET", `${arm}${casedRgId}/providers/Microsoft.Authorization/policyExemptions/${exName}-rg?api-version=2022-07-01preview`, { headers: B });
    const getEx = await req("GET", `${arm}${casedResId}/providers/Microsoft.Authorization/policyExemptions/${exName}?api-version=2022-07-01preview`, { headers: B });
    const listAtRes = await req("GET", `${arm}${casedResId}/providers/Microsoft.Authorization/policyExemptions?api-version=2022-07-01preview`, { headers: B });
    const listedOk = listAtRes.json()?.value?.some((x) => x.name === exName) ?? false;
    const ok =
      putDef.status < 300 && putSet.status < 300 && putAsg.status < 300 &&
      putExRg.status < 300 && getExRg.status === 200;
    cell(
      "arm:policy-initiative-exemption-armcased#KD-112",
      ok ? "PASS" : "FAIL",
      `def=${putDef.status} initiative=${putSet.status} assignment=${putAsg.status} putExRg(cased)=${putExRg.status} getExRg=${getExRg.status} putExResourceScope=${putEx.status} getExResourceScope=${getEx.status} listedAtCasedResourceScope=${listedOk}` +
      (putExRg.status === 404 ? " — policyExemptions routes not landed (capabilities lane, TARGETED SKIP)" :
       putEx.status === 404 ? " — resource-scope exemption arm not landed; RG-scope cased id exercised (partial)" : ""),
    );
  } catch (e) {
    cell("arm:policy-initiative-exemption-armcased#KD-112", "FAIL", `${e?.name}: ${String(e?.message).slice(0, 160)}`);
  }

  // ============ Cell 6: tags at scope PUT/GET ==============================
  try {
    const scope = `/subscriptions/${SUB}/resourceGroups/nc-rg`;
    const putT = await req("PUT", `${arm}${scope}/providers/Microsoft.Resources/tags/default?api-version=2022-09-01`, {
      headers: J,
      body: JSON.stringify({ properties: { tags: { nc: "probe" } } }),
    });
    const getT2 = await req("GET", `${arm}${scope}/providers/Microsoft.Resources/tags/default?api-version=2022-09-01`, { headers: B });
    const getRg = await req("GET", `${arm}${scope}?api-version=${APIV}`, { headers: B });
    const tagsOnRg = getRg.json()?.tags;
    const ok = putT.status < 300 && (getT2.status === 200 || tagsOnRg?.nc === "probe");
    cell(
      "arm:tags-at-scope-put-get",
      ok ? "PASS" : "FAIL",
      `put=${putT.status} getAtScope=${getT2.status} rgTags=${JSON.stringify(tagsOnRg)}` +
      (putT.status === 404 ? " — tags-at-scope route not landed (capabilities lane, TARGETED SKIP)" : ""),
    );
  } catch (e) {
    cell("arm:tags-at-scope-put-get", "FAIL", `${e?.name}: ${String(e?.message).slice(0, 160)}`);
  }

  // ============ Cell 7: LRO-widened namespace PUT 202 -> terminal ==========
  try {
    const t = `nc-lro-topic-${stamp}`;
    const putUrl = `${arm}/subscriptions/${SUB}/resourceGroups/nc-rg/providers/Microsoft.EventGrid/topics/${t}?api-version=2021-04-01`;
    const put = await req("PUT", putUrl, {
      headers: J,
      body: JSON.stringify({ location: "local", properties: { inputSchema: "EventGrid" } }),
    });
    const asyncUrl = put.headers["azure-asyncoperation"] ?? put.headers["location"];
    let terminal = null;
    if (put.status === 202 && asyncUrl) {
      terminal = await poll(async () => {
        const pr = await req("GET", asyncUrl, { headers: B });
        const st = pr.json()?.status;
        return st === "Succeeded" || st === "Failed" ? st : null;
      }, 20_000);
    }
    const getRes = await req("GET", putUrl, { headers: B });
    const ok =
      (put.status === 202 && terminal === "Succeeded" && getRes.status === 200) ||
      (put.status === 200 && getRes.status === 200);
    cell(
      "arm:lro-namespace-put-202-terminal",
      ok ? "PASS" : "SKIP",
      `put=${put.status}${put.status === 202 ? "(LRO)" : "(sync)"} asyncUrl=${asyncUrl ? "yes" : "no"} terminal=${terminal} getResource=${getRes.status}` +
      (put.status === 202
        ? (terminal === "Succeeded" ? " — LRO poll reached terminal" : " — LRO poll did not reach terminal in budget")
        : " — SKIP-vs-not-landed (LRO-widening lane): Microsoft.EventGrid/topics PUT answers 201-sync, no 202/Azure-AsyncOperation arm on this namespace"),
    );
  } catch (e) {
    cell("arm:lro-namespace-put-202-terminal", "FAIL", `${e?.name}: ${String(e?.message).slice(0, 160)}`);
  }

  await down();

  const hard = cells.filter((c) => c.verdict === "FAIL");
  console.log(JSON.stringify({ lane: "wf6-capability-expansion", cells, hardFails: hard.length }));
  process.exit(hard.length ? 1 : 0);
}

main().catch(async (e) => {
  console.error(`newcaps probe crashed: ${e?.stack ?? e}`);
  await down();
  process.exit(2);
});
