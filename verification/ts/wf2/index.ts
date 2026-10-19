// wf2-concurrency — cosmos 8-way etag race, appconfig If-Match race,
// blob legal-hold WORM lifecycle.
import { CosmosClient, type Container } from "@azure/cosmos";
import { StorageSharedKeyCredential } from "@azure/storage-blob";
import { randomBytes } from "node:crypto";
import { AppConfigurationClient } from "@azure/app-configuration";
import { BlobServiceClient } from "@azure/storage-blob";
import { check, GREEN, type WfResult } from "../harness/enum.ts";
import { expectRestError } from "../harness/assert.ts";
import type { SubstrateCoords, CredMode } from "../harness/credential.ts";

type Ctx = { coords: SubstrateCoords; runid: string; cred: any; credMode: CredMode };

export async function run(ctx: Ctx): Promise<WfResult> {
  const checks: WfResult["checks"] = [];
  const p = (name: string, verdict: string, detail: string) => checks.push(check(name, verdict, detail));
  const EG = ctx.coords.egress;

  // --- cosmos 8-way same-etag race ----------------------------------------
  // Substrate mounts only the docs engine (/dbs/<db>/colls/<coll>/docs/*);
  // db/coll control-plane routes 404 (RouteNotFound), so the SDK is driven
  // straight at the docs surface (auto-ensure on first create).
  const cosmos = new CosmosClient({
    endpoint: ctx.coords.tls,
    aadCredentials: ctx.cred,
    connectionPolicy: { enableEndpointDiscovery: false },
  });
  const cont: Container = cosmos.database(`wf2-${ctx.runid}`).container("race");
  // Substrate colls GET answers NotFound (pk definitions not served), so the
  // SDK's lazy container.read() for pk resolution fails; seed its cache with
  // the /id definition the docs engine itself enforces (id == pk).
  (cosmos as any).clientContext.partitionKeyDefinitionCache[cont.url] = {
    path: "/id",
    paths: ["/id"],
    kind: "Hash",
    version: 1,
  };
  const docId = `race-${ctx.runid}`;
  const created = await cont.items.upsert({ id: docId, v: 0 });
  const etag = created.resource!._etag;

  const results = await Promise.allSettled(
    Array.from({ length: 8 }, (_, i) =>
      cont.item(docId, docId).replace(
        { id: docId, v: i + 1 },
        { accessCondition: { type: "IfMatch", condition: etag } },
      ),
    ),
  );
  const ok = results.filter((r) => r.status === "fulfilled" && (r as PromiseFulfilledResult<any>).value.statusCode === 200);
  const conflicted = results.filter((r) => r.status === "rejected" && statusOf((r as PromiseRejectedResult).reason) === 412);
  const readback = await cont.item(docId, docId).read();
  const winnerV = readback.resource?.v;
  p(
    "cosmos-8way-etag-race",
    ok.length === 1 && conflicted.length === 7 && typeof winnerV === "number" ? GREEN : "FAIL",
    `1x200=${ok.length === 1} 7x412=${conflicted.length === 7} winnerV=${winnerV}`,
  );

  // red-against-missing-plane: dead egress -> typed transport failure
  try {
    const dead = new CosmosClient({ endpoint: "http://127.0.0.1:1", key: "k", connectionPolicy: { enableEndpointsDiscovery: false } });
    await dead.databases.read("nope");
    p("dead-port-plane-check", "FAIL", "dead-port cosmos read resolved — fake plane");
    return { id: "wf2", checks };
  } catch (err: any) {
    const real = /ECONNREFUSED|fetch failed|UND_ERR|AggregateError|ECONNRESET|TypeError/i.test(String(err?.name ?? "") + String(err?.message ?? "") + String(err?.cause?.code ?? ""));
    p("dead-port-plane-check", real ? GREEN : "FAIL", `dead endpoint typed failure (${err?.name ?? err?.code})`);
  }

  // --- appconfig If-Match race --------------------------------------------
  const appconfig = new AppConfigurationClient(ctx.coords.tls, ctx.cred, { allowInsecureConnection: false } as any);
  const key = `wf2-${ctx.runid}`;
  // Substrate answers 201 on kv PUT-create where real Azure App Configuration
  // answers 200 — every @azure/app-configuration version type-asserts 200 and
  // RestErrors on 201, so the SDK cannot perform the CREATE leg. Seed the
  // record raw (wire-shape seeding, same class as the lift's sharedKeyFetch),
  // then run the whole If-Match race through the SDK (update/delete = 200).
  const tok = await ctx.cred.getToken("https://management.azure.com/.default");
  await fetch(`${ctx.coords.tls}/kv/${key}?api-version=1.0`, {
    method: "PUT",
    headers: {
      authorization: `Bearer ${tok.token}`,
      "content-type": "application/json",
      "if-none-match": "*",
    },
    body: JSON.stringify({ value: "v0" }),
  });
  const cur = await appconfig.getConfigurationSetting({ key });
  const [ra, rb] = [
    appconfig.setConfigurationSetting({ key, value: "A", etag: cur.etag }, { onlyIfUnchanged: true }),
    appconfig.setConfigurationSetting({ key, value: "B", etag: cur.etag }, { onlyIfUnchanged: true }),
  ] as const;
  const race = await Promise.allSettled([ra, rb]);
  const wins = race.filter((r) => r.status === "fulfilled").length;
  const hits412 = race.filter((r) => r.status === "rejected" && statusOf((r as PromiseRejectedResult).reason) === 412).length;
  const after = await appconfig.getConfigurationSetting({ key });
  p("appconfig-ifmatch-race",
    wins === 1 && hits412 === 1 ? GREEN : "FAIL",
    `fulfilled=${wins} 412=${hits412} finalValue=${after.value}`);

  // Unconditional overwrite (no If-Match) on an existing key must be a typed
  // 409 WriteConflict — the substrate's last-writer-wins refusal shape.
  await expectRestError(
    () => appconfig.setConfigurationSetting({ key, value: "unconditional" }),
    { status: 409, code: /WriteConflict|Conflic/i },
    "appconfig-unconditional-409",
  ).then((g) => p("appconfig-unconditional-409", GREEN, `typed 409 ${g.code}`))
   .catch((e: any) => p("appconfig-unconditional-409", "FAIL", String(e.message).slice(0, 200)));

  // red-against-missing-plane #2: delete missing key -> typed 404
  await expectRestError(
    () => appconfig.deleteConfigurationSetting({ key: `wf2-missing-${ctx.runid}` }),
    { status: 404 },
    "appconfig-missing-404",
  ).then(() => p("appconfig-missing-404", GREEN, "delete missing key typed 404"))
   .catch((e: any) => p("appconfig-missing-404", "FAIL", String(e.message).slice(0, 200)));

  // --- blob legal-hold lifecycle ------------------------------------------
  // Auth-channel divergence (witnessed, no KD row at run time):
  //  - bearer: the egress blob plane ACCEPTS bearer tokens, but
  //    @azure/core-rest-pipeline's bearer policy refuses to send one over
  //    non-TLS URLs, and the TLS twin does not route blob paths (404).
  //  - SharedKey: the SDK signs it correctly, but the enforce-mode Bearer
  //    plug refuses the SharedKey scheme with 401 MalformedBearerHeader
  //    (real Azure accepts SharedKey on the blob data plane in every mode).
  // The lifecycle below therefore runs SharedKey and EXPECTS to surface the
  // refusal; if the substrate admits SharedKey, the full WORM lifecycle
  // asserts as normal.
  const ACCOUNT = "smaltacct";
  const blobSvc = new BlobServiceClient(
    `${egressBase(EG)}/${ACCOUNT}`,
    new StorageSharedKeyCredential(ACCOUNT, "smaltacct-key"),
  );
  const cname = `wf2${ctx.runid.replace(/-/g, "")}`;
  let blobChannel = "ok";
  await containerCreate(blobSvc, cname).catch((e: any) => {
    if (e?.statusCode === 401 && /MalformedBearerHeader/i.test(String(e.message))) {
      blobChannel = "refused-401-MalformedBearerHeader (SharedKey vs enforce-mode bearer plug)";
      p("blob-auth-channel", "FAIL",
        `SharedKey refused by enforce-mode Bearer plug; bearer-over-http refused by the SDK itself; ` +
        `blob not routed on the TLS twin — no usable official-SDK blob channel under enforce auth`);
    } else {
      throw e;
    }
  });
  if (blobChannel !== "ok") {
    return { id: "wf2", checks };
  }
  const blob = container.getBlockBlobClient(`hold-${ctx.runid}`);
  const payload = "immutable-payload";
  await blob.upload(payload, payload.length);
  p("blob-upload", GREEN, "block uploaded");

  await container.setLegalHold(`hold-${ctx.runid}`, true);
  p("blob-legalhold-set", GREEN, "legal hold set");

  const lock409 = async (fn: () => Promise<unknown>) =>
    (await fn().then(
      () => false,
      (e: any) => e?.statusCode === 409 || String(e).includes("409"),
    )) as boolean;
  const overwrote = await lock409(() => blob.upload("clobber", 7));
  const snapshotted = await lock409(() => blob.createSnapshot());
  const deleted = await lock409(() => blob.delete());
  p("blob-worm-409s",
    overwrote && snapshotted && deleted ? GREEN : "FAIL",
    `409s under hold: overwrite=${overwrote} snapshot=${snapshotted} delete=${deleted}`);

  await container.setLegalHold(`hold-${ctx.runid}`, false);
  p("blob-legalhold-clear", GREEN, "hold cleared");

  const del = await container.delete().then((r: any) => r?._response?.status ?? 202).catch((e: any) => e?.statusCode);
  p("blob-container-delete", [202, 204, 201].includes(del) ? GREEN : "FAIL", `delete status ${del}`);

  return { id: "wf2", checks };
}

async function containerCreate(svc: any, name: string) {
  return svc.getContainerClient(name).create();
}

function egressBase(egress: string): string {
  return egress;
}

function statusOf(err: any): number | undefined {
  return err?.statusCode ?? err?.code ?? err?.response?.status;
}


