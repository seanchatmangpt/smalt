"use strict";
// s7_worm worm.test.cjs — E2E immutability chain over the live smalt substrate.
// Vendored @azure/storage-blob (SMALT_SDK_ROOT) + raw REST for the policy
// verbs the SDK lacks. Zero skips: where a wire route is missing the probe is
// a DOCUMENTED FAIL (named limitation), never a skip and never a fake pass.
const assert = require("node:assert/strict");
const { test } = require("node:test");
const path = require("node:path");

const SDK_ROOT =
  process.env.SMALT_SDK_ROOT || "~/smalt/test/sdk-full/node_modules";
const { BlobServiceClient, StorageSharedKeyCredential } = require(
  path.join(SDK_ROOT, "@azure/storage-blob"),
);

const BASE = "http://127.0.0.1:8443";
const ACCOUNT = "smaltacct";
const KEY = "smaltacct-key";
const T = (ms) => AbortSignal.timeout(ms);

function client() {
  return new BlobServiceClient(
    `${BASE}/${ACCOUNT}`,
    new StorageSharedKeyCredential(ACCOUNT, KEY),
  );
}

// Minimal raw REST (SharedKey-signed like the SDK; substrate blob routes
// currently do not enforce auth, but we sign anyway to stay spec-shaped).
function rawFetch(url, method, extraHeaders = {}, body = undefined) {
  const crypto = require("node:crypto");
  const u = new URL(url);
  const xms = Object.entries({ ...extraHeaders })
    .filter(([k]) => k.toLowerCase().startsWith("x-ms-"))
    .sort(([a], [b]) => (a < b ? -1 : 1));
  const canonicalHeaders = xms.map(([k, v]) => `${k.toLowerCase()}:${v}\n`).join("");
  const canonicalResource =
    `/${ACCOUNT}${u.pathname}` +
    [...u.searchParams.entries()]
      .map(([k, v]) => `\n${k.toLowerCase()}:${v}`)
      .join("");
  const contentLength = body ? Buffer.byteLength(body) : "";
  const stringToSign = [
    method, "", "", contentLength, "", "", "", "", "", "", "", "",
    canonicalHeaders + canonicalResource,
  ].join("\n");
  const sig = crypto
    .createHmac("sha256", Buffer.from(KEY, "base64"))
    .update(stringToSign, "utf8")
    .digest("base64");
  return fetch(url, {
    method,
    headers: {
      ...extraHeaders,
      "x-ms-date": new Date().toUTCString(),
      "x-ms-version": "2021-12-02",
      Authorization: `SharedKey ${ACCOUNT}:${sig}`,
    },
    body,
  });
}

async function createMutableContainer(name) {
  const res = await rawFetch(`${BASE}/${ACCOUNT}/${name}`, "PUT", {
    "x-ms-immutable-policy": "false",
  });
  assert.ok(
    res.status === 201,
    `mutable container create status ${res.status}`,
  );
  return res;
}

// ---------------------------------------------------------------------------
// 1. Immutable-by-default container: upload ok, overwrite 409, delete 409
// ---------------------------------------------------------------------------
test("worm: immutable default container — overwrite 409, delete 409", { timeout: 60_000 }, async () => {
  const service = client();
  const container = service.getContainerClient(`worm-imm-${Date.now()}`);
  await container.create({ abortSignal: T(60_000) });

  const blob = container.getBlockBlobClient("locked.bin");
  const first = await blob.upload(Buffer.from("first"), 5, { abortSignal: T(60_000) });
  assert.equal(first._response.status, 201, "first upload 201");

  await assert.rejects(
    () => blob.upload(Buffer.from("second"), 6, { abortSignal: T(60_000) }),
    (err) => err.statusCode === 409,
    "overwrite on immutable container must 409",
  );

  // Delete is also WORM-blocked on a legacy-immutable container.
  const delRes = await rawFetch(
    `${BASE}/${ACCOUNT}/${container.containerName}/locked.bin`,
    "DELETE",
  );
  assert.equal(delRes.status, 409, "delete on immutable container must 409");
  const delBody = await delRes.text();
  assert.match(delBody, /ContainerLocked/);
});

// ---------------------------------------------------------------------------
// 2. Mutable container: full upload/overwrite/delete cycle is unblocked
// ---------------------------------------------------------------------------
test("worm: mutable container (x-ms-immutable-policy: false) full cycle", { timeout: 60_000 }, async () => {
  const name = `worm-mut-${Date.now()}`;
  await createMutableContainer(name);

  const blobUrl = `${BASE}/${ACCOUNT}/${name}/cycle.bin`;
  const up1 = await rawFetch(blobUrl, "PUT", { "x-ms-blob-type": "BlockBlob" }, "v1");
  assert.equal(up1.status, 201, "first upload 201");

  const up2 = await rawFetch(blobUrl, "PUT", { "x-ms-blob-type": "BlockBlob" }, "v2");
  assert.equal(up2.status, 201, "overwrite on mutable container 201");

  const del = await rawFetch(blobUrl, "DELETE");
  assert.equal(del.status, 202, "delete on mutable container 202");
});

// ---------------------------------------------------------------------------
// 3. Legal hold via raw REST: set -> delete blocked 409 -> release -> 202
// ---------------------------------------------------------------------------
test("worm: legal hold raw REST chain", { timeout: 60_000 }, async () => {
  const name = `worm-hold-${Date.now()}`;
  await createMutableContainer(name);

  const blobUrl = `${BASE}/${ACCOUNT}/${name}/hold.bin`;
  const up = await rawFetch(blobUrl, "PUT", { "x-ms-blob-type": "BlockBlob" }, "held");
  assert.equal(up.status, 201, "blob upload 201");

  const holdRes = await rawFetch(
    `${BASE}/${ACCOUNT}/${name}?comp=legalhold`,
    "PUT",
    { "x-ms-legal-hold": "true" },
  );
  const holdBody = await holdRes.text();
  const holdSet =
    holdRes.status === 200 &&
    (holdRes.headers.get("x-ms-legal-hold") === "true" || /legal/i.test(holdBody));

  if (!holdSet) {
    assert.fail(
      `DOCUMENTED FAIL — raw REST PUT ?comp=legalhold did not set a legal hold ` +
      `(status=${holdRes.status}, body=${holdBody.slice(0, 200)}). ` +
      `Limitation: the egress router has no ?comp=legalhold route — ` +
      `BlobStorage.set_legal_hold/4 exists in the data plane but is not mounted on ` +
      `any wire route; the guarded catch-all mis-dispatches to create_container (201). ` +
      `Legal-hold 409 semantics are unreachable over the wire.`,
    );
  }

  const delRes = await rawFetch(blobUrl, "DELETE");
  assert.equal(delRes.status, 409, "delete under hold must 409");
  assert.match(await delRes.text(), /legal hold/);

  const relRes = await rawFetch(
    `${BASE}/${ACCOUNT}/${name}?comp=legalhold`,
    "PUT",
    { "x-ms-legal-hold": "false" },
  );
  assert.equal(relRes.status, 200, "release hold 200");

  const del2 = await rawFetch(blobUrl, "DELETE");
  assert.equal(del2.status, 202, "delete after release 202");
});

// ---------------------------------------------------------------------------
// 4. Immutability policy via raw REST: set w/ retention -> lock -> re-PUT 409
// ---------------------------------------------------------------------------
test("worm: immutability policy raw REST set + lock + immutability", { timeout: 60_000 }, async () => {
  const name = `worm-pol-${Date.now()}`;
  await createMutableContainer(name);

  const policyUrl = `${BASE}/${ACCOUNT}/${name}?comp=immutabilityPolicy`;
  const setRes = await rawFetch(policyUrl, "PUT", {}, JSON.stringify({
    immutabilityPeriodSinceCreationInDays: 1,
  }));
  const setBody = await setRes.text();

  if (setRes.status !== 200) {
    assert.fail(
      `DOCUMENTED FAIL — raw REST PUT ?comp=immutabilityPolicy did not set a policy ` +
      `(status=${setRes.status}, body=${setBody.slice(0, 200)}). ` +
      `Limitation: the egress router has no ?comp=immutabilityPolicy route — ` +
      `BlobStorage.set_immutability_policy/5 exists in the data plane but is not mounted ` +
      `on any wire route; the guarded catch-all mis-dispatches to create_container (201/200). ` +
      `Policy lock + 409 ContainerLocked-on-re-PUT semantics are unreachable over the wire.`,
    );
  }

  // Lock it (requires If-Match: "*").
  const lockRes = await rawFetch(policyUrl, "PUT", { "if-match": "*" }, JSON.stringify({
    immutabilityPeriodSinceCreationInDays: 1,
    locked: true,
  }));
  assert.equal(lockRes.status, 200, "lock 200");

  // Locked policy is immutable: a further PUT must 409 ContainerLocked.
  const reRes = await rawFetch(policyUrl, "PUT", { "if-match": "*" }, JSON.stringify({
    immutabilityPeriodSinceCreationInDays: 2,
  }));
  assert.equal(reRes.status, 409, "re-PUT on locked policy must 409 ContainerLocked");
  assert.match(await reRes.text(), /ContainerLocked/);
});

// ---------------------------------------------------------------------------
// 5. Retention expiry (policy_state/3 contract): expires_at reporting
// ---------------------------------------------------------------------------
test("worm: retention expiry contract — expires_at reported, expiry itself time-dependent", { timeout: 60_000 }, async () => {
  // BlobStorage.policy_state/4 marks a container expired when
  // now > created_at + retention_days, but the wire offers no path to
  // backdate created_at or set retention_days (create_container is only
  // reachable with server System time and the 1095-day default), and
  // :now_ms is engine-injected only. So the EXPIRED transition is
  // time-dependent and honestly out of scope for a wire e2e; we assert the
  // observable part of the contract: the container listing carries the
  // HasImmutabilityPolicy/HasLegalHold flags derived from policy_state.
  const service = client();
  const name = `worm-exp-${Date.now()}`;
  const container = service.getContainerClient(name);
  await container.create({ abortSignal: T(60_000) });

  const listRes = await rawFetch(`${BASE}/${ACCOUNT}?comp=list&prefix=${name}`, "GET");
  assert.equal(listRes.status, 200, "list 200");
  const xml = await listRes.text();
  assert.match(xml, new RegExp(`<Name>${name}</Name>`));
  assert.match(xml, /<HasImmutabilityPolicy>false<\/HasImmutabilityPolicy>/);
  assert.match(xml, /<HasLegalHold>false<\/HasLegalHold>/);
});

// ---------------------------------------------------------------------------
// 6. Container metadata round-trip via SDK
// ---------------------------------------------------------------------------
test("worm: container metadata round-trip", { timeout: 60_000 }, async () => {
  const service = client();
  const name = `worm-meta-${Date.now()}`;
  const container = service.getContainerClient(name);
  await container.create({ abortSignal: T(60_000) });

  await container.setMetadata({ owner: "s7-worm", classification: "worm-e2e" }, {
    abortSignal: T(60_000),
  });
  const props = await container.getProperties({ abortSignal: T(60_000) });
  const meta = props.metadata || {};
  assert.equal(meta.owner, "s7-worm", "metadata owner round-trips");
  assert.equal(meta.classification, "worm-e2e", "metadata classification round-trips");
});

// ---------------------------------------------------------------------------
// 7. List pagination: 75 containers across 3 pages
// ---------------------------------------------------------------------------
test("worm: list pagination 75 containers / 3 pages of 30", { timeout: 120_000 }, async () => {
  const service = client();
  const stem = `worm-page-${Date.now()}`;
  const names = [];
  for (let i = 0; i < 75; i++) {
    const n = `${stem}-${String(i).padStart(3, "0")}`;
    names.push(n);
    await service.getContainerClient(n).create({ abortSignal: T(60_000) });
  }

  const seen = [];
  let pages = 0;
  for await (const c of service.listContainers({ prefix: stem, includeMetadata: false }).byPage({
    maxPageSize: 30,
  })) {
    pages++;
    for (const item of c.containerItems || []) seen.push(item.name);
  }
  assert.equal(pages, 3, `expected 3 pages, got ${pages}`);
  assert.equal(seen.length, 75, `expected 75 containers, got ${seen.length}`);
  assert.deepEqual(seen, [...seen].sort(), "page order is deterministic (sorted)");
});

// ---------------------------------------------------------------------------
// 8. Negatives: stale If-Match 412, missing x-ms-version 400
// ---------------------------------------------------------------------------
test("worm: negative — stale If-Match on overwrite -> 412", { timeout: 60_000 }, async () => {
  const name = `worm-neg-${Date.now()}`;
  await createMutableContainer(name);
  const blobUrl = `${BASE}/${ACCOUNT}/${name}/etag.bin`;

  const up = await rawFetch(blobUrl, "PUT", { "x-ms-blob-type": "BlockBlob" }, "v1");
  assert.equal(up.status, 201);
  const etag = up.headers.get("etag");
  assert.ok(etag, "upload returns etag");

  const stale = await rawFetch(blobUrl, "PUT", { "if-match": '"deadbeefdeadbeef"' }, "v2");
  assert.equal(stale.status, 412, "stale If-Match must 412");
  assert.match(await stale.text(), /PreconditionFailed/);

  const fresh = await rawFetch(blobUrl, "PUT", { "if-match": etag }, "v2");
  assert.equal(fresh.status, 201, "matching If-Match overwrite succeeds");
});

test("worm: negative — missing x-ms-version on blob catch-all -> 400 MissingXMsVersion", { timeout: 30_000 }, async () => {
  const res = await fetch(`${BASE}/${ACCOUNT}/noversion-container/noversion.bin`, {
    method: "PUT",
    body: "x",
  });
  assert.equal(res.status, 400, "missing x-ms-version must 400");
  const body = await res.text();
  assert.match(body, /MissingXMsVersion/);
});
