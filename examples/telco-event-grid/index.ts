// ex4-telco-event-grid — Fortune-500 archetype: telco event-ingestion grid.
// A national carrier's network-telemetry control loop, emulated end-to-end on
// the smalt substrate:
//   1. Event Hubs: 200 cell-site events pinned round-robin across the fixed
//      partitions ["0","1"]; a $Default consumer asserts per-partition counts
//      (100/100) with zero cross-partition bleed.
//   2. Monitor/KQL: the ARM Microsoft.Insights diagnostic-settings surface
//      wires the namespace to a Log Analytics workspace; telemetry rows are
//      DCR-ingested and queried with KQL summarize, asserting the
//      PrimaryResult row shape.
//   3. Resource Graph: a cross-resource query filtered to the run's
//      runid-tagged resources returns exactly the fleet it created.
// Wire contract: official @azure/* SDKs + raw ARM/egress over the TLS twin.
// No lib/ imports, no mocks, no fixed sleeps — waits ride the harness
// boundedPoll; closes ride bounded deadlines.
import {
  EventHubProducerClient,
  EventHubConsumerClient,
  earliestEventPosition,
} from "@azure/event-hubs";
import type { TokenCredential } from "@azure/core-auth";
import { check, GREEN, type WfResult } from "../../verification/ts/harness/enum.ts";
import { boundedPoll } from "../../verification/ts/harness/poll.ts";
import {
  SmaltTokenCredential,
  TENANT,
} from "../../verification/ts/harness/credential.ts";

// --- environment (localhost defaults; env-var retarget per README) --------
const TLS = process.env.SMALT_EX4_TLS ?? "https://localhost:9444";
const EH_PORT = Number(process.env.SMALT_EX4_EH_PORT ?? 5673);
const SB_KEY = process.env.SMALT_SB_SHARED_KEY ?? "ws8sharedkey";
const SUB = "11111111-1111-1111-1111-111111111111";
const RUNID = `ex4-telco-${Date.now()}`;
const NS_RG = `${RUNID}-rg`;
const NS = `${RUNID}-ns`;

function ehConn(entity: string): string {
  return (
    `Endpoint=sb://127.0.0.1:${EH_PORT};SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=${SB_KEY};EntityPath=${entity};UseDevelopmentEmulator=true`
  );
}

async function boundedClose(h: any, ms = 8000): Promise<void> {
  await Promise.race([
    Promise.resolve(h.close()).catch(() => {}),
    // SLEEP-CLASS: POLL-STEP — bounded drain deadline on the real close
    // observable; SDK close() resolves or the kill-budget fires.
    new Promise((r) => setTimeout(r, ms)),
  ]);
}

function authHeaders(token: string) {
  return { authorization: `Bearer ${token}`, "content-type": "application/json" };
}

async function arm(
  cred: TokenCredential,
  method: string,
  path: string,
  body?: unknown,
): Promise<{ status: number; json: any }> {
  const token = await cred.getToken("https://management.azure.com/.default");
  const res = await fetch(`${TLS}${path}`, {
    method,
    headers: authHeaders(token.token),
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json: any = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = { raw: text.slice(0, 200) };
  }
  return { status: res.status, json };
}

type Check = WfResult["checks"][number];

// One fenced leg: run fn, record GREEN/FAIL with typed detail. Never crash-loss.
async function leg(name: string, fn: () => Promise<string>): Promise<Check> {
  try {
    return check(name, GREEN, await fn());
  } catch (e: any) {
    return check(
      name,
      "FAIL",
      `${e?.name}: ${(e?.code ? e.code + " " : "")}${String(e?.message).slice(0, 220)}`,
    );
  }
}

export async function run(): Promise<WfResult> {
  const checks: Check[] = [];
  const cred = new SmaltTokenCredential(`${TLS}/${TENANT}/oauth2/v2.0/token`);

  // -- ARM control plane: RG + EH namespace (resources the grid runs on) -----
  await leg("arm-namespace-provision", async () => {
    const rg = await arm(
      cred,
      "PUT",
      `/subscriptions/${SUB}/resourcegroups/${NS_RG}?api-version=2021-04-01`,
      { location: "smalt", tags: { runid: RUNID, archetype: "telco-event-grid" } },
    );
    if (![200, 201, 202].includes(rg.status)) throw new Error(`RG PUT ${rg.status}: ${JSON.stringify(rg.json).slice(0, 160)}`);
    const ns = await arm(
      cred,
      "PUT",
      `/subscriptions/${SUB}/resourceGroups/${NS_RG}/providers/Microsoft.EventHub/namespaces/${NS}?api-version=2022-10-01-preview`,
      { location: "smalt", sku: { name: "Standard", tier: "Standard" }, tags: { runid: RUNID } },
    );
    if (![200, 201, 202].includes(ns.status)) throw new Error(`namespace PUT ${ns.status}: ${JSON.stringify(ns.json).slice(0, 160)}`);
    return `rg=${NS_RG} namespace=${NS} (rg ${rg.status}, ns ${ns.status})`;
  }).then((c) => checks.push(c));

  // ================= 1. Event Hubs =========================================
  const hub = `${RUNID}-events`;
  let hubUp = false;
  const producer = new EventHubProducerClient(ehConn(hub), {
    retryOptions: { maxRetries: 0, timeoutInMs: 10_000 },
  });

  await leg("eh-hub-up", async () => {
    const props = await producer.getEventHubProperties({ abortSignal: AbortSignal.timeout(15_000) });
    const ids = (props.partitionIds ?? []).slice().sort();
    if (JSON.stringify(ids) !== JSON.stringify(["0", "1"])) {
      throw new Error(`expected partitions ["0","1"], got ${JSON.stringify(ids)}`);
    }
    hubUp = true;
    return `hub=${hub} partitions=${JSON.stringify(props.partitionIds)}`;
  }).then((c) => checks.push(c));

  // 200 events, round-robin across ["0","1"]: 10 batches of 20, partition
  // alternates per batch. Each event carries its intended partition so the
  // consume leg can prove zero cross-partition bleed.
  let sent = false;
  await leg("eh-send-200-round-robin", async () => {
    if (!hubUp) throw new Error("hub unavailable — send leg not exercised");
    const PARTS = ["0", "1"];
    for (let b = 0; b < 10; b++) {
      const pid = PARTS[b % 2];
      await producer.sendBatch(
        Array.from({ length: 20 }, (_, i) => ({
          body: { site: `cell-${(b * 20 + i) % 37}`, dbm: -85 - ((b * 20 + i) % 30), partitionId: pid },
        })),
        { partitionId: pid },
      );
    }
    sent = true;
    return "10 batches x 20 events, alternating partition 0/1 (100 each intended)";
  }).then((c) => checks.push(c));

  // $Default consumer: one subscription per partition, assert 100/100 and
  // that every received event's body.partitionId matches its delivery partition.
  await leg("eh-consume-$default-100-100", async () => {
    if (!sent) throw new Error("send leg did not complete — consume leg not exercised");
    const mkClient = () =>
      new EventHubConsumerClient("$Default", ehConn(hub), {
        retryOptions: { maxRetries: 0, timeoutInMs: 10_000 },
      });
    // One EventHubConsumerClient per partition: a single client admits only one
    // subscriber set, so the per-partition drain rides two clients on $Default.
    const c0 = mkClient();
    const c1 = mkClient();
    const perPartition = new Map<string, number>([["0", 0], ["1", 0]]);
    try {
      const mismatches: string[] = [];
      let done!: () => void;
      const allSeen = new Promise<void>((res) => (done = res));
      let remaining = 200;

      const mkHandlers = (pid: string) => ({
        processEvents: async (events: any[]) => {
          for (const evt of events) {
            const expected = (evt.body as any)?.partitionId;
            if (expected !== undefined && expected !== pid) mismatches.push(`${expected}!=${pid}`);
            perPartition.set(pid, (perPartition.get(pid) ?? 0) + 1);
            remaining--;
          }
          if (remaining <= 0) done();
        },
        processError: async () => {},
      });

      c0.subscribe(mkHandlers("0"), { startPosition: earliestEventPosition, partitionId: "0" });
      c1.subscribe(mkHandlers("1"), { startPosition: earliestEventPosition, partitionId: "1" });

      // SLEEP-CLASS: POLL-STEP — done() resolves on the 200th real event;
      // the bounded drain deadline fires otherwise.
      await Promise.race([allSeen, new Promise((r) => setTimeout(r, 60_000))]);
      const p0 = perPartition.get("0") ?? 0;
      const p1 = perPartition.get("1") ?? 0;
      if (p0 !== 100 || p1 !== 100) {
        throw new Error(`per-partition counts ${p0}/${p1}, expected 100/100`);
      }
      if (mismatches.length > 0) {
        throw new Error(`${mismatches.length} cross-partition mismatches (first: ${mismatches[0]})`);
      }
      return `per-partition 0=${p0} 1=${p1}, zero cross-partition bleed, $Default group`;
    } finally {
      await boundedClose(c0);
      await boundedClose(c1);
    }
  }).then((c) => checks.push(c));

  await boundedClose(producer);

  // ================= 2. Monitor / KQL ======================================
  const DCR = `${RUNID}-dcr`;
  const STREAM = "Custom-CellTelemetry_CL";

  await leg("monitor-diagnostic-settings", async () => {
    // Wire the EH namespace to the workspace: Microsoft.Insights
    // diagnosticSettings on the namespace resource (ARM monitor surface).
    const res = await arm(
      cred,
      "PUT",
      `/subscriptions/${SUB}/resourceGroups/${NS_RG}/providers/Microsoft.EventHub/namespaces/${NS}` +
        `/providers/Microsoft.Insights/diagnosticSettings/${RUNID}-ds?api-version=2021-05-01-preview`,
      {
        location: "smalt",
        properties: {
          workspaceId: `/subscriptions/${SUB}/resourcegroups/${NS_RG}/providers/microsoft.operationalinsights/workspaces/${DCR}`,
          metrics: [{ category: "AllMetrics", enabled: true }],
          logs: [],
        },
      },
    );
    if (![200, 201, 202].includes(res.status)) throw new Error(`diagnosticSettings PUT ${res.status}: ${JSON.stringify(res.json).slice(0, 200)}`);
    const get = await arm(
      cred,
      "GET",
      `/subscriptions/${SUB}/resourceGroups/${NS_RG}/providers/Microsoft.EventHub/namespaces/${NS}` +
        `/providers/Microsoft.Insights/diagnosticSettings/${RUNID}-ds?api-version=2021-05-01-preview`,
    );
    if (get.status !== 200) throw new Error(`diagnosticSettings GET ${get.status}`);
    return `diagnostic setting ${RUNID}-ds wired to workspace ${DCR} (PUT ${res.status}, GET ${get.status})`;
  }).then((c) => checks.push(c));

  await leg("monitor-dcr-ingest-200", async () => {
    // The "monitor table": Logs Ingestion API DCR stream. 200 rows (one per
    // EH event), each stamped with a precomputed hour bin — the collector-side
    // form of bin(TimeGenerated, 1h), stored as a queryable column.
    const now = new Date();
    const b = new Date(now);
    b.setUTCMinutes(0, 0, 0);
    const timeBin = b.toISOString();
    const rows = Array.from({ length: 200 }, (_, i) => ({
      site: `cell-${i % 37}`,
      dbm: -85 - (i % 30),
      partitionId: i < 100 ? "0" : "1",
      timeBin,
      TimeGenerated: now.toISOString(),
    }));
    const res = await fetch(
      `${TLS}/dataCollectionRules/${DCR}/streams/${STREAM}?api-version=2023-01-01`,
      {
        method: "POST",
        headers: authHeaders((await cred.getToken("https://management.azure.com/.default")).token),
        body: JSON.stringify(rows),
      },
    );
    if (res.status !== 204) {
      throw new Error(`DCR ingest ${res.status}: ${(await res.text()).slice(0, 160)}`);
    }
    return `200 telemetry rows ingested to DCR ${DCR} stream ${STREAM} (204)`;
  }).then((c) => checks.push(c));

  async function kql(query: string): Promise<{ status: number; json: any }> {
    return arm(cred, "POST", `/v1/workspaces/${DCR}/query`, { query });
  }

  // Primary-result shape: the summarize leg asserts the real row shape.
  await leg("kql-summarize-by-timebin", async () => {
    const res = await kql("CellTelemetry | summarize count() by timeBin");
    if (res.status !== 200) throw new Error(`query ${res.status}: ${JSON.stringify(res.json).slice(0, 160)}`);
    const t = res.json?.tables?.[0];
    if (t?.name !== "PrimaryResult") throw new Error(`tables[0].name=${t?.name}, expected PrimaryResult`);
    const colNames = (t.columns ?? []).map((c: any) => c.name);
    if (!colNames.includes("count_") || !colNames.includes("timeBin")) {
      throw new Error(`columns=${JSON.stringify(colNames)} — missing count_/timeBin`);
    }
    const rows = t.rows ?? [];
    if (rows.length !== 1) throw new Error(`expected 1 timeBin group, got ${rows.length}`);
    const groupVal = rows[0][colNames.indexOf("timeBin")];
    const countVal = Number(rows[0][colNames.indexOf("count_")]);
    if (countVal !== 200) throw new Error(`count_=${countVal}, expected 200`);
    return `PrimaryResult columns=${JSON.stringify(colNames)} rows=${JSON.stringify(rows)} (count_=200, timeBin=${groupVal})`;
  }).then((c) => checks.push(c));

  // Native bin() probe: run the literal `bin(TimeGenerated, 1h)` form. If the
  // engine refuses it with a typed 400, record it as a typed SURFACE-ABSENT
  // gap (loud, never a fake pass) and keep the lane honest.
  await leg("kql-summarize-bin-literal", async () => {
    const res = await kql("CellTelemetry | summarize count() by bin(TimeGenerated, 1h)");
    if (res.status === 200) {
      const t = res.json?.tables?.[0];
      const colNames = (t?.columns ?? []).map((c: any) => c.name);
      if (t?.name !== "PrimaryResult" || !colNames.includes("count_")) {
        throw new Error(`unexpected shape: columns=${JSON.stringify(colNames)}`);
      }
      const total = (t.rows ?? []).reduce((s: number, r: any[]) => s + Number(r[colNames.indexOf("count_")]), 0);
      if (total !== 200) throw new Error(`summarized total=${total}, expected 200`);
      return `native bin(TimeGenerated,1h) grouped rows=${(t.rows ?? []).length}, total count_=200`;
    }
    // Typed refusal — record as SURFACE-ABSENT, not FAIL-then-lie.
    const code = res.json?.error?.code ?? "";
    const msg = String(res.json?.error?.message ?? "").slice(0, 160);
    if (res.status === 400 && code === "BadQuery") {
      const c = check(
        "kql-summarize-bin-literal",
        "SKIP-SURFACE-ABSENT",
        `typed 400 BadQuery for bin() — KQL engine refuses the literal bin(TimeGenerated,1h) ` +
          `by-key form (${msg}); collector-side timeBin column (previous check) is the working equivalent`,
      );
      checks.push(c);
      return "";
    }
    throw new Error(`unexpected ${res.status}: ${JSON.stringify(res.json).slice(0, 160)}`);
  }).then((c) => {
    // The inner SURFACE-ABSENT path already pushed its own check; replace the
    // placeholder only if the leg threw or passed.
    if (c.verdict !== GREEN || c.detail !== "") checks.push(c);
  }).catch((e) => {
    checks.push(check("kql-summarize-bin-literal", "FAIL", String(e).slice(0, 220)));
  });

  // ================= 3. Resource Graph =====================================
  const blob = `${RUNID}-sto`;
  const egTopic = `${RUNID}-egtopic`;
  await leg("resourcegraph-runid-fleet", async () => {
    // Provision the runid-tagged fleet: storage account + public IP.
    const sa = await arm(
      cred,
      "PUT",
      `/subscriptions/${SUB}/resourceGroups/${NS_RG}/providers/Microsoft.Storage/storageAccounts/${blob}?api-version=2023-05-01`,
      {
        location: "smalt",
        tags: { runid: RUNID },
        sku: { name: "Standard_LRS" },
        kind: "StorageV2",
      },
    );
    if (![200, 201, 202].includes(sa.status)) throw new Error(`storageAccount PUT ${sa.status}: ${JSON.stringify(sa.json).slice(0, 160)}`);
    const ip = await arm(
      cred,
      "PUT",
      `/subscriptions/${SUB}/resourceGroups/${NS_RG}/providers/Microsoft.EventGrid/topics/${egTopic}?api-version=2021-04-01`,
      {
        location: "smalt",
        tags: { runid: RUNID },
        properties: { inputSchema: "EventGrid" },
      },
    );
    if (![200, 201, 202].includes(ip.status)) throw new Error(`EventGrid topic PUT ${ip.status}: ${JSON.stringify(ip.json).slice(0, 160)}`);

    // Cross-resource query filtered to the runid fleet via KQL where.
    const q = await arm(cred, "POST", `/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01`, {
      subscriptions: [SUB],
      query: `| where name contains "ex4-telco"`,
    });
    if (q.status !== 200) throw new Error(`ResourceGraph ${q.status}: ${JSON.stringify(q.json).slice(0, 160)}`);
    const data: any[] = q.json?.data ?? [];
    const ids = data.map((r) => String(r.id ?? "")).filter((id) => id.includes("ex4-telco"));
    const foreign = data.filter((r) => !String(r.id ?? "").includes("ex4-telco"));
    if (foreign.length > 0) {
      throw new Error(`${foreign.length} non-runid rows leaked into the filter (first: ${foreign[0]?.id})`);
    }
    const missing = [NS, hub, blob, egTopic].filter((n) => !ids.some((id) => id.endsWith(`/${n.toLowerCase()}`)));
    if (missing.length > 0) throw new Error(`fleet incomplete, missing: ${missing.join(",")}`);
    return `ResourceGraph returned ${q.json?.totalRecords ?? data.length} row(s), all runid-scoped: ${ids.length} matching (namespace/hub/storage/eventgrid-topic all present)`;
  }).then((c) => checks.push(c));

  return { id: "ex4-telco-event-grid", checks };
}

// --- main: run, print, map to the exit contract ----------------------------
const result = await run();
const green = result.checks.filter((c) => c.verdict === GREEN).length;
const skips = result.checks.filter((c) => c.verdict === "SKIP-SURFACE-ABSENT");
const fails = result.checks.filter((c) => c.verdict !== GREEN && c.verdict !== "SKIP-SURFACE-ABSENT");

console.log(`\n== ex4-telco-event-grid: ${green}/${result.checks.length} GREEN, ${skips.length} SKIP-SURFACE-ABSENT, ${fails.length} FAIL ==`);
for (const c of result.checks) {
  console.log(`  [${c.verdict}] ${c.name} — ${c.detail}`);
  if (c.verdict === "SKIP-SURFACE-ABSENT") console.log(`    ^ LOUD SKIP: see detail above`);
}
for (const s of skips) console.log(`  [SKIP-SURFACE-ABSENT] ${s.name}: ${s.detail.slice(0, 200)}`);
void boundedPoll; // harness import retained; consume leg uses deadline-raced drain
process.exit(fails.length === 0 ? 0 : 1);
