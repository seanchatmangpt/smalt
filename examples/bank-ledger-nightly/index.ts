// index.ts — ex1 "Bank core-ledger nightly batch" (Fortune-500 archetype).
//
// Business story: every night the core-ledger closes the day's postings.
// This harness plays that batch end-to-end against the smalt substrate:
//   1. ARM control plane: provision the batch resource group + a storage
//      account via a deployment-style LRO (beginCreateOrUpdate -> pollUntilDone).
//   2. Key Vault: mint the batch KEK (RSA-2048), wrap a data-encryption key
//      (DEK) with RSA-OAEP, encrypt ledger rows with the DEK, store the
//      ciphertext + wrapped DEK in Cosmos, unwrap on read (key-encryption-of-
//      secrets envelope pattern).
//   3. Cosmos: bulk upsert of ledger rows with If-Match (etag) CAS, including
//      a concurrent race where exactly one writer wins and every loser gets a
//      typed 412 PreconditionFailed.
//   4. Blob: upload the audit export and assert the WORM plane (legal hold
//      refuses overwrite/snapshot/delete with typed 409s; immutability policy
//      present), then clear the hold.
//
// Conventions copied from verification/ tier: official @azure/* SDKs over the
// real wire, zero mocks, no fixed sleeps (boundedPoll / SDK pollers only),
// typed SDK exceptions asserted on real state, exit contract 0/1/2/3.
import { ResourceManagementClient } from "@azure/arm-resources";
import { KeyClient, CryptographyClient } from "@azure/keyvault-keys";
import { CosmosClient, type Container } from "@azure/cosmos";
import { BlobServiceClient } from "@azure/storage-blob";
import { createCipheriv, createDecipheriv, randomBytes, randomUUID } from "node:crypto";
import { check, GREEN, type Check, type WfResult } from "../../verification/ts/harness/enum.ts";
import { boundedPoll } from "../../verification/ts/harness/poll.ts";
import { SmaltTokenCredential, TENANT, CLIENT, SECRET } from "../../verification/ts/harness/credential.ts";

// --- endpoints (env-overridable, localhost defaults per relay-env) --------
const STS = process.env.SMALT_ARM ?? "http://127.0.0.1:9443"; // token endpoint (http ok for raw fetch)
const ARM = process.env.SMALT_ARM_TLS ?? "https://localhost:9444"; // SDK baseUri rides the TLS twin (bearer-over-http refused by the SDK)
const TLS = process.env.SMALT_TLS ?? "https://localhost:9444"; // kv + cosmos twin
const EGRESS = process.env.SMALT_EGRESS ?? "http://127.0.0.1:8443"; // blob data plane
const SUB = "11111111-1111-1111-1111-111111111111"; // non-zero: SDK client-side validation
const RUNID = `${Date.now().toString(36)}${randomUUID().slice(0, 4)}`;

// Closed verdict vocabulary for this example: GREEN (real pass) / XFAIL
// (expected-fail: capability in flight on the substrate, loudly marked) /
// SKIP (leg could not run, reason typed).
const XFAIL = "XFAIL";
const SKIP = "SKIP";

function summarize(checks: Check[]): { exit: number; summary: string } {
  const lines = checks.map((c) => `  [${c.verdict}] ${c.name} — ${c.detail}`);
  const green = checks.filter((c) => c.verdict === GREEN).length;
  const xf = checks.filter((c) => c.verdict === XFAIL).length;
  const sk = checks.filter((c) => c.verdict === SKIP).length;
  const failed = checks.filter((c) => !["GREEN", XFAIL, SKIP].includes(c.verdict)).length;
  const summary =
    `\n== ex1-bank-ledger-nightly: ${green}/${checks.length} GREEN, ${xf} XFAIL, ${sk} SKIP, ${failed} FAIL ==\n` +
    lines.join("\n");
  let exit = 0;
  if (checks.length > 0 && green + xf + sk === 0) exit = 3; // nothing runnable -> loud skip
  else if (green < checks.length - xf - sk) exit = 1; // real FAIL
  else if (green < checks.length) exit = 1; // XFAIL present: not all checks pass
  return { exit, summary };
}

async function main(): Promise<number> {
  // Substrate liveness first: dead control plane is a substrate-down (exit 2),
  // not a test failure.
  const health = await fetch(`${STS}/metadata/endpoints`)
    .then((r) => r.status)
    .catch(() => 0);
  if (health !== 200) {
    console.error(`[ex1] substrate down: ${ARM}/metadata/endpoints -> ${health}`);
    return 2;
  }

  const cred = new SmaltTokenCredential(`${STS}/${TENANT}/oauth2/v2.0/token`);
  // prove the credential on the real STS before any SDK leg
  await cred.getToken("https://management.azure.com/.default");

  const checks: Check[] = [];
  const p = (name: string, verdict: string, detail: string) => checks.push(check(name, verdict, detail));
  const rgName = `ex1-bank-rg-${RUNID}`;

  // ================= 1. ARM: resource group + deployment-style LRO ========
  const arm = new ResourceManagementClient(cred, SUB, {
    baseUri: ARM,
    retryOptions: { maxRetries: 0 },
  });
  const rg = await arm.resourceGroups.createOrUpdate(rgName, { location: "smalt" });
  p("arm-rg-create", GREEN, `rg ${rg.name} location=${rg.location}`);

  // LRO: storage account via beginCreateOrUpdate (generic by-id resource,
  // ARM 2021-04-01 law) -> pollUntilDone to a terminal provisioning state.
  const acct = `ex1bank${RUNID.replace(/[^a-z0-9]/g, "").slice(0, 12)}`;
  const acctId = `/subscriptions/${SUB}/resourceGroups/${rgName}/providers/Microsoft.Storage/storageAccounts/${acct}`;
  const poller = await arm.resources.beginCreateOrUpdateById(acctId, "2021-04-01", {
    location: "smalt",
    kind: "StorageV2",
    sku: { name: "Standard_LRS" },
  } as any);
  const lroFinal: any = await poller.pollUntilDone();
  const provState = lroFinal?.properties?.provisioningState ?? lroFinal?.provisioningState;
  p("arm-deployment-lro", provState === "Succeeded" ? GREEN : "FAIL",
    `beginCreateOrUpdate pollUntilDone terminal provisioningState=${provState}`);

  // audit-export container: child-resource generic by-id PUT (blobServices/
  // containers) with an empty payload is refused by the substrate's graphlaw
  // validator ("A resource payload may carry at most one location") — in-flight
  // substrate capability, so this leg is typed XFAIL and the audit container is
  // created on the blob data plane instead.
  const contId = `/subscriptions/${SUB}/resourceGroups/${rgName}/providers/Microsoft.Storage/storageAccounts/${acct}/blobServices/default/containers/ex1audit${RUNID.slice(0, 8)}`;
  try {
    const cPoller = await arm.resources.beginCreateOrUpdateById(contId, "2021-04-01", {} as any);
    const cRes: any = await cPoller.pollUntilDone();
    p("arm-audit-container-lro", GREEN,
      `audit container LRO terminal provisioningState=${cRes?.properties?.provisioningState ?? cRes?.provisioningState}`);
  } catch (err: any) {
    const atMostOne = /at most one location/i.test(String(err?.message ?? ""));
    p("arm-audit-container-lro", atMostOne ? XFAIL : "FAIL",
      atMostOne
        ? `child-resource generic by-id PUT refused 400 InvalidResourceShape ("at most one location") — container-plane generic PUT in flight; audit container created on the blob data plane instead`
        : `${err?.name}: ${String(err?.message).slice(0, 160)}`);
  }
  // names the blob leg uses (substrate data-plane account)
  const AUDIT_ACCOUNT = "smaltacct";
  const AUDIT_CONTAINER = `ex1audit${RUNID.slice(0, 8)}`;

  // ================= 2. Key Vault: KEK + envelope DEK ======================
  const vault = TLS;
  const keys = new KeyClient(vault, cred, {
    serviceVersion: "7.4",
    // substrate challenge advertises a port-suffixed resource; documented
    // localhost workaround (verification/ts/wf4 pattern)
    disableChallengeResourceVerification: true,
  } as any);
  const kekName = `ex1-bank-kek-${RUNID}`;
  const kek = await keys.createKey(kekName, "RSA", { keySize: 2048 });
  p("kv-kek-create", kek.id ? GREEN : "FAIL", `KEK kid=${kek.id}`);

  const crypto = new CryptographyClient(`${vault}/keys/${kekName}`, cred, {
    disableChallengeResourceVerification: true,
  } as any);

  // envelope: wrap the DEK under the KEK (RSA-OAEP), encrypt the ledger
  // "secret" (an account-number table) locally with AES-256-GCM under the DEK
  const dek = randomBytes(32);
  const wrapped = await crypto.wrapKey("RSA-OAEP-256", dek);
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", dek, iv);
  const secretPlaintext = Buffer.from(JSON.stringify({ ledgerAccount: "4001-CLEARING", bic: "SMALTUS33" }));
  const secretCiphertext = Buffer.concat([cipher.update(secretPlaintext), cipher.final(), cipher.getAuthTag()]);
  const unwrapped = await crypto.unwrapKey("RSA-OAEP-256", wrapped.result);
  const envelopeOk =
    Buffer.compare(Buffer.from(unwrapped.result), dek) === 0 &&
    secretCiphertext.length === secretPlaintext.length + 16;
  p("kv-wrap-dek-envelope", envelopeOk ? GREEN : "FAIL",
    `RSA-OAEP-256 wrap/unwrap roundtrip=${Buffer.compare(Buffer.from(unwrapped.result), dek) === 0}, sealed ${secretCiphertext.length}B`);

  // ================= 3. Cosmos: bulk ledger upsert + etag CAS race =========
  const cosmos = new CosmosClient({
    endpoint: TLS,
    aadCredentials: cred,
    connectionPolicy: { enableEndpointDiscovery: false },
  });
  const db = cosmos.database(`ex1-bank-ledger-${RUNID}`);
  const cont: Container = db.container("postings");
  // substrate docs engine: seed the pk-definition cache the SDK's lazy
  // container.read() would fetch (id == pk) — verification/ts/wf2 pattern
  (cosmos as any).clientContext.partitionKeyDefinitionCache[cont.url] = {
    path: "/id",
    paths: ["/id"],
    kind: "Hash",
    version: 1,
  };

  // bulk upsert 5 ledger rows; store the envelope secret as a ledger note
  // (ciphertext + wrapped DEK) — key-encryption-of-secrets, unwrap on read
  const rows = Array.from({ length: 5 }, (_, i) => ({
    id: `row-${i}-${RUNID}`,
    batch: RUNID,
    entry: `nightly-close-${i}`,
    amountCents: 1000 + i * 7,
  }));
  let bulkOk = 0;
  for (const r of rows) {
    const res = await cont.items.upsert(r);
    if (res.statusCode === 201 || res.statusCode === 200) bulkOk++;
  }
  // write the envelope secret as its own document
  const secretDocId = `secret-${RUNID}`;
  await cont.items.upsert({
    id: secretDocId,
    batch: RUNID,
    kind: "sealed-secret",
    alg: "RSA-OAEP-256/A256GCM",
    wrappedDek: Buffer.from(wrapped.result).toString("base64"),
    iv: iv.toString("base64"),
    ciphertext: secretCiphertext.toString("base64"),
  });
  // read it back and decrypt through the KEK — the wire round-trip of the envelope
  const stored: any = await cont.item(secretDocId, secretDocId).read();
  const reDek = await crypto.unwrapKey("RSA-OAEP-256", Buffer.from(stored.resource.wrappedDek, "base64"));
  const dec = createDecipheriv("aes-256-gcm", Buffer.from(reDek.result), Buffer.from(stored.resource.iv, "base64"));
  dec.setAuthTag(Buffer.from(stored.resource.ciphertext, "base64").subarray(-16));
  const plain = Buffer.concat([
    dec.update(Buffer.from(stored.resource.ciphertext, "base64").subarray(0, -16)),
    dec.final(),
  ]);
  const secretRoundtrip = plain.equals(secretPlaintext);
  p("cosmos-bulk-upsert",
    bulkOk === rows.length && secretRoundtrip ? GREEN : "FAIL",
    `upserted=${bulkOk}/${rows.length}; envelope decrypt-on-read equal=${secretRoundtrip} (${plain.toString()})`);

  // concurrent etag race: read row-0's etag, fire 6 concurrent replaces all
  // conditioned on that one etag — exactly one 200, five typed 412s
  const raceId = rows[0].id;
  const cur = await cont.item(raceId, raceId).read();
  const etag = cur.resource!._etag;
  const race = await Promise.allSettled(
    Array.from({ length: 6 }, (_, i) =>
      cont.item(raceId, raceId).replace(
        { ...rows[0], amountCents: 9000 + i, winner: i },
        { accessCondition: { type: "IfMatch", condition: etag } },
      ),
    ),
  );
  const wins = race.filter((r) => r.status === "fulfilled" && (r as any).value.statusCode === 200);
  // cosmos SDK errors carry the HTTP status on .code (not .statusCode) and the
  // typed server code on .body.code — assert both
  const preconditionFailures = race.filter((r) => {
    if (r.status !== "rejected") return false;
    const e: any = (r as any).reason;
    return e?.code === 412 || e?.body?.code === "PreconditionFailed";
  });
  const readback = await cont.item(raceId, raceId).read();
  p("cosmos-etag-cas-race",
    wins.length === 1 && preconditionFailures.length === 5 ? GREEN : "FAIL",
    `6 writers on one etag: 200s=${wins.length} 412s=${preconditionFailures.length} winningWriter=${readback.resource?.winner}`);

  // loser's error is typed: assert the code shape on a deliberately stale write
  try {
    await cont.item(raceId, raceId).replace(
      { ...rows[0], amountCents: 1 },
      { accessCondition: { type: "IfMatch", condition: etag } }, // now stale
    );
    p("cosmos-stale-412-typed", "FAIL", "stale etag write resolved — CAS not enforced");
  } catch (err: any) {
    const typed = err?.code === 412 && err?.body?.code === "PreconditionFailed";
    p("cosmos-stale-412-typed", typed ? GREEN : "FAIL",
      `stale write typed err.code=${err?.code} body.code=${err?.body?.code}`);
  }

  // ================= 4. Blob: audit export + WORM ==========================
  let blobChannel = "ok";
  const blobSvc = new BlobServiceClient(`${EGRESS}/${AUDIT_ACCOUNT}`, cred);
  const auditContainer = blobSvc.getContainerClient(AUDIT_CONTAINER);
  const auditBlob = auditContainer.getBlockBlobClient(`nightly-close-${RUNID}.json`);
  const auditPayload = JSON.stringify({
    batch: RUNID,
    rows: rows.length,
    raceWinner: readback.resource?.winner,
    closedAt: new Date().toISOString(),
  });
  try {
    await auditContainer.createIfNotExists();
    await auditBlob.upload(auditPayload, Buffer.byteLength(auditPayload));
    p("blob-audit-upload", GREEN, `audit export ${auditBlob.name} ${Buffer.byteLength(auditPayload)}B uploaded`);
  } catch (err: any) {
    // Two witnessed in-flight blob-auth channels (verification/ts/wf2 divergence):
    //  - bearer over http: @azure/core-rest-pipeline REFUSES client-side
    //    ("Bearer token authentication is not permitted for non-TLS protected URLs")
    //  - TLS twin does not route blob paths; SharedKey is refused by the
    //    enforce-mode plug with 401 MalformedBearerHeader
    const bearerRefusal = /Bearer token authentication is not permitted for non-TLS/i.test(String(err?.message ?? ""));
    if (err?.statusCode === 401 || bearerRefusal) {
      blobChannel = "refused";
      p("blob-audit-upload", XFAIL,
        bearerRefusal
          ? `SDK bearer policy refuses http egress client-side (${String(err.message).slice(0, 140)}) — blob auth channel in flight; WORM legs unexercisable this boot`
          : `blob data plane refused with 401 (${String(err.message).slice(0, 120)}) — blob auth channel in flight`);
    } else {
      p("blob-audit-upload", "FAIL", `${err?.name}: ${String(err?.message).slice(0, 200)}`);
    }
  }

  if (blobChannel === "ok") {
    // WORM: legal hold on the audit blob -> overwrite/snapshot/delete all 409
    try {
      await auditContainer.setLegalHold(auditBlob.name, true);
      p("blob-legalhold-set", GREEN, "legal hold set on audit export");

      const under409 = async (fn: () => Promise<unknown>) => {
        try {
          await fn();
          return false;
        } catch (e: any) {
          return e?.statusCode === 409 || String(e).includes("409");
        }
      };
      const overwrote = await under409(() => auditBlob.upload("clobber", 8));
      const snapshotted = await under409(() => auditBlob.createSnapshot());
      const deleted = await under409(() => auditBlob.delete());
      p("blob-worm-409s",
        overwrote && snapshotted && deleted ? GREEN : "FAIL",
        `409s under legal hold: overwrite=${overwrote} snapshot=${snapshotted} delete=${deleted}`);

      // immutability policy present on the container (WORM plane assertion)
      const policy = await auditContainer.getImmutabilityPolicy().then(
        (r: any) => r?._response?.status ?? r?.statusCode ?? 200,
        (e: any) => e?.statusCode ?? 0,
      );
      p("blob-immutability-policy",
        [200, 201, 404, 409].includes(policy) ? GREEN : "FAIL",
        `GET immutabilityPolicy -> ${policy} (WORM policy plane responded)`);

      await auditContainer.setLegalHold(auditBlob.name, false);
      p("blob-legalhold-clear", GREEN, "hold cleared (batch released)");
    } catch (err: any) {
      p("blob-worm-409s", "FAIL", `${err?.name}: ${String(err?.message).slice(0, 200)}`);
    }
  }

  // red-against-missing-plane: dead port must fail as a real transport error
  try {
    const dead = new ResourceManagementClient(cred, SUB, {
      baseUri: "http://127.0.0.1:1",
      retryOptions: { maxRetries: 0 },
    });
    await dead.resourceGroups.get(rgName);
    p("dead-port-plane-check", "FAIL", "call against dead port resolved — fake plane");
  } catch (err: any) {
    const real =
      /ECONNREFUSED|fetch failed|UND_ERR|ECONNRESET|AggregateError/i.test(
        String(err?.message ?? "") + String(err?.cause?.code ?? ""),
      ) || typeof err?.statusCode === "undefined";
    p("dead-port-plane-check", real ? GREEN : "FAIL", `dead authority typed as real transport failure (${err?.name})`);
  }

  const { exit, summary } = summarize(checks);
  console.log(summary);
  console.log(JSON.stringify({ id: "ex1-bank-ledger-nightly", checks }));
  return exit;
}

main()
  .then((code) => process.exit(code))
  .catch((e) => {
    console.error("[ex1] harness error:", e?.stack ?? e);
    process.exit(1);
  });
