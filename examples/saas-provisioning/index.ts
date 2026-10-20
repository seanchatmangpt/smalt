// index.ts — ex8 "Multi-tenant SaaS provisioning" (Fortune-500 archetype).
//
// Business story: a SaaS platform provisions a new tenant end-to-end on the
// smalt substrate: the control plane cuts an ARM resource group, walks the
// storage account and EventHub namespace through real ARM LROs
// (202 -> pollUntilDone -> terminal provisioningState), tags the tenant for
// cost allocation (PATCH-merge accumulates; full-replace PUT with empty tags
// renders null), and registers the tenant's data estate in the Purview Atlas
// catalog with a process lineage edge (tenant store -> namespace feed), which
// a lineage query must return. On tenant off-boarding the resource group is
// deleted and every child resource answers a typed 404 after a bounded poll.
//
// Conventions from verification/: official @azure/* SDKs over the real wire,
// zero mocks, no fixed sleeps (SDK LRO pollers + boundedPoll only), typed SDK
// exceptions asserted on real state, exit contract 0/1/2/3.
import { ResourceManagementClient } from "@azure/arm-resources";
import { randomUUID } from "node:crypto";
import { check, GREEN, type Check } from "../../verification/ts/harness/enum.ts";
import { expectRestError } from "../../verification/ts/harness/assert.ts";
import { boundedPoll } from "../../verification/ts/harness/poll.ts";
import { SmaltTokenCredential, TENANT, SUB } from "../../verification/ts/harness/credential.ts";

// --- endpoints (env-overridable, localhost defaults per relay-env) --------
const STS = process.env.SMALT_ARM ?? "http://127.0.0.1:9443"; // token endpoint (http ok for raw fetch)
const ARM = process.env.SMALT_ARM_TLS ?? "https://localhost:9444"; // SDK baseUri rides the TLS twin
const EGRESS = process.env.SMALT_EGRESS ?? "http://127.0.0.1:8443"; // Atlas v2 surface
const TENANT_ID = "00000000-0000-0000-0000-000000000000";
const RUNID = `${Date.now().toString(36)}${randomUUID().slice(0, 4)}`;

const XFAIL = "XFAIL";
const SKIP_SA = "SKIP#SURFACE-ABSENT";

function summarize(checks: Check[]): { exit: number; summary: string } {
  const lines = checks.map((c) => `  [${c.verdict}] ${c.name} — ${c.detail}`);
  const green = checks.filter((c) => c.verdict === GREEN).length;
  const xf = checks.filter((c) => c.verdict === XFAIL).length;
  const sk = checks.filter((c) => c.verdict === SKIP_SA).length;
  const failed = checks.filter((c) => c.verdict === "FAIL").length;
  const summary =
    `\n== ex8-saas-provisioning: ${green}/${checks.length} GREEN, ${xf} XFAIL, ${sk} SKIP, ${failed} FAIL ==\n` +
    lines.join("\n");
  let exit = 0;
  if (checks.length > 0 && green + xf + sk === 0) exit = 3; // nothing runnable -> loud skip
  else if (failed > 0) exit = 1; // real FAIL
  else if (green < checks.length) exit = 1; // XFAIL/SKIP present: not all green
  return { exit, summary };
}

// Atlas v2 calls ride the egress plane with the substrate STS bearer (raw
// fetch — no @azure SDK exists for the catalog face; the wire shape is the
// documented Atlas v2 contract witnessed in docs/jira/v26.10.16/sdk-results/ts-atlas.md).
async function atlas(
  token: string,
  method: "POST" | "GET",
  path: string,
  body?: unknown,
): Promise<{ status: number; json: any }> {
  const res = await fetch(`${EGRESS}${path}`, {
    method,
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${token}`,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json: any = null;
  try {
    json = JSON.parse(text);
  } catch {
    json = { raw: text.slice(0, 200) };
  }
  return { status: res.status, json };
}

async function main(): Promise<number> {
  // Substrate liveness first: dead control plane is a substrate-down (exit 2).
  const health = await fetch(`${STS}/metadata/endpoints`)
    .then((r) => r.status)
    .catch(() => 0);
  if (health !== 200) {
    console.error(`[ex8] substrate down: ${STS}/metadata/endpoints -> ${health}`);
    return 2;
  }

  const cred = new SmaltTokenCredential(`${STS}/${TENANT_ID}/oauth2/v2.0/token`);
  // prove the credential on the real STS before any SDK leg
  const { token } = await cred.getToken("https://management.azure.com/.default");

  const checks: Check[] = [];
  const p = (name: string, verdict: string, detail: string) => checks.push(check(name, verdict, detail));
  const rgName = `ex8-saas-rg-${RUNID}`;

  // ================= 1. RG create (tenant onboarding root) =================
  const arm = new ResourceManagementClient(cred, SUB, {
    baseUri: ARM,
    retryOptions: { maxRetries: 0 },
  });
  const rg = await arm.resourceGroups.createOrUpdate(rgName, { location: "smalt" });
  p("rg-create", GREEN, `tenant RG ${rg.name} location=${rg.location}`);

  // ================= 2. Storage account LRO (tenant store) =================
  // beginCreateOrUpdateById (generic by-id, ARM 2021-04-01 law) returns a
  // poller on a 202; pollUntilDone drives it to a terminal provisioningState.
  const acct = `ex8saas${RUNID.replace(/[^a-z0-9]/g, "").slice(0, 12)}`;
  const acctId = `/subscriptions/${SUB}/resourceGroups/${rgName}/providers/Microsoft.Storage/storageAccounts/${acct}`;
  const acctPoller = await arm.resources.beginCreateOrUpdateById(acctId, "2021-04-01", {
    location: "smalt",
    kind: "StorageV2",
    sku: { name: "Standard_LRS" },
  } as any);
  const acctFinal: any = await acctPoller.pollUntilDone();
  const acctState = acctFinal?.properties?.provisioningState ?? acctFinal?.provisioningState;
  p("storage-lro",
    acctState === "Succeeded" ? GREEN : "FAIL",
    `storage account PUT -> LRO terminal provisioningState=${acctState}`);

  // ================= 3. EventHub namespace + event hub LRO (tenant feed) ===
  const nsName = `ex8-saas-ns-${RUNID}`;
  const nsId = `/subscriptions/${SUB}/resourceGroups/${rgName}/providers/Microsoft.EventHub/namespaces/${nsName}`;
  const nsPoller = await arm.resources.beginCreateOrUpdateById(nsId, "2022-10-01-preview", {
    location: "smalt",
    sku: { name: "Standard", tier: "Standard" },
    tags: { tenant: RUNID },
  } as any);
  const nsFinal: any = await nsPoller.pollUntilDone();
  const nsState = nsFinal?.properties?.provisioningState ?? nsFinal?.provisioningState;
  p("eventhub-namespace-lro",
    nsState === "Succeeded" ? GREEN : "FAIL",
    `namespace LRO terminal provisioningState=${nsState}`);

  // event hub child of the namespace (fixed partition law ["0","1"] on the
  // substrate data plane)
  const hubName = `ex8-saas-hub-${RUNID}`;
  const hubId = `${nsId}/eventhubs/${hubName}`;
  try {
    const hubPoller = await arm.resources.beginCreateOrUpdateById(hubId, "2021-11-01", {
      properties: { partitionCount: 2, messageRetentionInDays: 1 },
    } as any);
    const hubFinal: any = await hubPoller.pollUntilDone();
    const hubState = hubFinal?.properties?.provisioningState ?? hubFinal?.provisioningState ?? "terminal";
    p("eventhub-hub-lro", GREEN, `event hub LRO terminal provisioningState=${hubState}`);
  } catch (err: any) {
    // Witnessed wire law: ARM child-resource generic by-id PUT is refused
    // 400 InvalidResourceShape ("at most one location") on this substrate —
    // typed XFAIL, never a silent pass.
    const shapeRefusal = /at most one location|InvalidResourceShape/i.test(String(err?.message ?? ""));
    p("eventhub-hub-lro",
      shapeRefusal ? XFAIL : "FAIL",
      shapeRefusal
        ? `child by-id PUT refused 400 InvalidResourceShape ("at most one location") — messaging-child generic PUT plane in flight`
        : `${err?.name}: ${String(err?.message).slice(0, 160)}`);
  }

  // ================= 4. Tags law (cost allocation) =========================
  // PATCH merges accumulate; full-replace PUT with an empty tags map -> null.
  await arm.resourceGroups.update(rgName, { tags: { tenant: RUNID, env: "prod" } });
  await arm.resourceGroups.update(rgName, { tags: { costCenter: "cc-saas-8" } });
  const tagged = await arm.resourceGroups.get(rgName);
  const merged = tagged.tags ?? {};
  const mergeOk = merged.tenant === RUNID && merged.env === "prod" && merged.costCenter === "cc-saas-8";
  p("tags-patch-merge", mergeOk ? GREEN : "FAIL", `tags after two PATCH merges: ${JSON.stringify(tagged.tags)}`);

  await arm.resourceGroups.createOrUpdate(rgName, { location: "smalt", tags: {} });
  const untagged = await arm.resourceGroups.get(rgName);
  p("tags-empty-null",
    untagged.tags === null || untagged.tags === undefined ? GREEN : "FAIL",
    `tags after PUT full-replace with empty tags: ${JSON.stringify(untagged.tags ?? null)}`);

  // ================= 5. Atlas / lineage (tenant data estate) ===============
  // Register the provisioned estate as Atlas entities + a Process edge
  // tenant-store -> provisioning-pipeline -> tenant-feed, then assert the
  // lineage query returns the edge. Typed SKIP#SURFACE-ABSENT if the catalog
  // face is not exposed over the wire (404 on the first Atlas call).
  let atlasRun = false;
  try {
    const gTenant = randomUUID();
    const gProc = randomUUID();
    const gFeed = randomUUID();

    const mk = await atlas(token, "POST", "/atlas/v2/entity", {
      entity: { typeName: "Database", guid: gTenant, attributes: { name: `tenant-store-${RUNID}`, qualifiedName: `ex8//saas/${RUNID}/store` } },
    });
    if (mk.status !== 201) throw Object.assign(new Error(`entity create ${mk.status}: ${JSON.stringify(mk.json).slice(0, 160)}`), { surface: true });

    const mkProc = await atlas(token, "POST", "/atlas/v2/entity", {
      entity: { typeName: "Process", guid: gProc, attributes: { name: `tenant-provision-${RUNID}`, qualifiedName: `ex8//saas/${RUNID}/pipeline` } },
    });
    if (mkProc.status !== 201) throw Object.assign(new Error(`entity create ${mkProc.status}`), { surface: true });

    const mkFeed = await atlas(token, "POST", "/atlas/v2/entity", {
      entity: { typeName: "Asset", guid: gFeed, attributes: { name: nsName, qualifiedName: `ex8//saas/${RUNID}/feed` } },
    });
    if (mkFeed.status !== 201) throw Object.assign(new Error(`entity create ${mkFeed.status}`), { surface: true });

    const got = await atlas(token, "GET", `/atlas/v2/entity/guid/${gTenant}`);
    p("atlas-entity-register",
      mkProc.status === 201 && mkFeed.status === 201 && got.status === 200 && got.json?.guid === gTenant ? GREEN : "FAIL",
      `3 entities minted; GET roundtrip guid=${got.json?.guid} typeName=${got.json?.typeName}`);

    // process edges: store -> pipeline -> feed (lineage chain)
    const e1 = await atlas(token, "POST", "/atlas/v2/relationship", {
      relationship: { typeName: "smalt_lineage", end1: { guid: gTenant }, end2: { guid: gProc } },
    });
    const e2 = await atlas(token, "POST", "/atlas/v2/relationship", {
      relationship: { typeName: "smalt_lineage", end1: { guid: gProc }, end2: { guid: gFeed } },
    });
    if (e1.status !== 201 || e2.status !== 201) {
      throw Object.assign(new Error(`relationship ${e1.status}/${e2.status}`), { surface: e1.status === 404 || e2.status === 404 });
    }

    // lineage query must return the process edge
    const lineage = await atlas(token, "GET", `/atlas/v2/lineage/both/${gFeed}?depth=2`);
    const rels: any[] = lineage.json?.relations ?? [];
    const edge = rels.find((r) => r.fromEntityId === gProc && r.toEntityId === gFeed);
    const map = lineage.json?.guidEntityMap ?? {};
    p("atlas-lineage-edge",
      lineage.status === 200 && !!edge ? GREEN : "FAIL",
      `lineage/both depth=2 returned ${rels.length} relation(s); process edge ${gProc}->${gFeed} ${edge ? "present" : "ABSENT"}; map has ${Object.keys(map).length} entities`);

    atlasRun = true;
  } catch (err: any) {
    if (err?.surface) {
      p("atlas-lineage-edge", SKIP_SA, `Purview Atlas surface not exposed over the wire (${String(err.message).slice(0, 160)}) — loud skip`);
    } else {
      p("atlas-lineage-edge", "FAIL", `${err?.name}: ${String(err?.message).slice(0, 200)}`);
    }
  }

  // ================= 6. Cascade delete (tenant off-boarding) ===============
  const delPoller = await arm.resourceGroups.beginDelete(rgName);
  await delPoller.pollUntilDone();
  p("rg-delete-lro", GREEN, "RG beginDelete pollUntilDone terminal");

  // every child answers typed 404 after a bounded poll (cascade convergence
  // is observed, never slept on)
  const gone = async (id: string, apiVersion: string) => {
    await boundedPoll(
      `cascade-404 ${id}`,
      async () => {
        try {
          await arm.resources.getById(id, apiVersion);
          return null; // still present -> keep polling
        } catch (err: any) {
          return err?.statusCode === 404 ? "gone" : null;
        }
      },
      30_000,
    );
  };
  await gone(acctId, "2021-04-01");
  p("cascade-storage-404", GREEN, `storage account ${acct} typed 404 after boundedPoll`);

  let nsGone = "missing";
  try {
    await gone(nsId, "2022-10-01-preview");
    nsGone = "gone";
  } catch (err: any) {
    nsGone = `poll-timeout: ${String(err.message).slice(0, 120)}`;
  }
  p("cascade-namespace-404", nsGone === "gone" ? GREEN : "FAIL", `namespace ${nsName} ${nsGone}`);

  await expectRestError(
    () => arm.resourceGroups.get(rgName),
    { status: 404, code: "ResourceGroupNotFound" },
    "rg-gone-404",
  ).then(() => p("rg-gone-404", GREEN, "re-GET after delete typed 404 ResourceGroupNotFound"))
   .catch((e) => p("rg-gone-404", "FAIL", String(e.message).slice(0, 200)));

  const { exit, summary } = summarize(checks);
  console.log(summary);
  console.log(JSON.stringify({ id: "ex8-saas-provisioning", checks }));
  return exit;
}

main()
  .then((code) => process.exit(code))
  .catch((e) => {
    console.error("[ex8] harness error:", e?.stack ?? e);
    process.exit(1);
  });
