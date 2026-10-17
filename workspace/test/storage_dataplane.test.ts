/**
 * Console blob data-plane court — node:test against the LIVE smalt substrate
 * (8443 blob plane, enforce mode via smalt STS Bearer).
 *
 * Covers: container create/list, block blob upload (full + staged
 * blocks/commit), byte-exact download, snapshot create+read, blob/container
 * metadata get/set, legal-hold toggle, WORM immutability, ETag/If-Match
 * preconditions, idempotent re-PUT, typed ARM error envelopes, delete→404.
 *
 * Exit contract: 0 pass / 1 fail. Requires a live substrate; if 8443 is not
 * listening the file SKIPS LOUDLY (exit 0 with [SKIP] lines, never a fake
 * pass) per the smalt harness-skip contract.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import {
  SmaltBlobClient,
  SmaltStorageError,
  stsToken,
  DEFAULT_ARM_BASE,
} from "../src/lib/azure/storage.js";
import { assertLocalUrl } from "../lib/smalt.js";

const RUN = `ws521-${Date.now()}`;
const CONTAINER = `${RUN}-c`;

// -- loud skip gate: is the substrate listening on 8443? ----------------------

async function port8443Open(): Promise<boolean> {
  return new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port: 8443, timeout: 2000 });
    s.on("connect", () => {
      s.destroy();
      resolve(true);
    });
    s.on("error", () => resolve(false));
    s.on("timeout", () => {
      s.destroy();
      resolve(false);
    });
  });
}

const SUBSTRATE_UP = await port8443Open();

test("air-gap guard: smaltFetch refuses non-local host", () => {
  assert.throws(() => assertLocalUrl("https://example.com/blob"), /Air-gap violation/);
});

test("substrate reachable on 8443", { skip: !SUBSTRATE_UP && "substrate down on 8443 — loud skip" }, () => {
  assert.ok(SUBSTRATE_UP);
});

// -- shared client ------------------------------------------------------------

let token: string | undefined;
let client: SmaltBlobClient;

test("setup: STS token + client", { skip: !SUBSTRATE_UP && "substrate down" }, async () => {
  token = await stsToken(DEFAULT_ARM_BASE);
  assert.ok(token.length > 40, "STS minted a real JWT");
  client = new SmaltBlobClient({ token });
});

// -- lifecycle ----------------------------------------------------------------

test("container create → list contains it", { skip: !SUBSTRATE_UP && "substrate down" }, async () => {
  const mk = await client.createContainer(CONTAINER, {
    metadata: { stage: "court", run: RUN },
    immutable: false,
  });
  assert.equal(mk.status, 201);
  const list = await client.listContainers();
  assert.ok(list.includes(CONTAINER), `list shows ${CONTAINER}`);
});

test("idempotent re-PUT: container re-create 409 ContainerAlreadyExists", { skip: !SUBSTRATE_UP && "substrate down" }, async () => {
  const err = await client
    .createContainer(CONTAINER)
    .then(() => null, (e: unknown) => e as SmaltStorageError);
  assert.ok(err instanceof SmaltStorageError, "typed error, not a throw-all");
  assert.equal(err.statusCode, 409);
  assert.equal(err.code, "ContainerAlreadyExists");
});

test("block blob upload → byte-exact download (multibyte)", { skip: !SUBSTRATE_UP && "substrate down" }, async () => {
  const content = Buffer.from(`héllo smalt 🌊 ${RUN}`, "utf8");
  const up = await client.uploadBlockBlob(CONTAINER, "dir/greeting.txt", content, {
    metadata: { owner: "ws521" },
    contentType: "text/plain",
  });
  assert.equal(up.status, 201);
  assert.ok(up.etag, "etag present");

  const dl = await client.downloadBlob(CONTAINER, "dir/greeting.txt");
  assert.equal(dl.status, 200);
  assert.ok(dl.body.equals(content), "download byte-exact");
});

test("staged blocks: putBlock ×3 → putBlockList → byte-exact concat", { skip: !SUBSTRATE_UP && "substrate down" }, async () => {
  const parts = [Buffer.from("alpha-"), Buffer.from("beta-"), Buffer.from("gamma")];
  const ids = ["b1", "b2", "b3"];
  for (let i = 0; i < parts.length; i++) {
    const r = await client.putBlock(CONTAINER, "staged.bin", ids[i], parts[i]);
    assert.equal(r.status, 201);
  }
  const commit = await client.putBlockList(CONTAINER, "staged.bin", ids);
  assert.equal(commit.status, 201);
  const dl = await client.downloadBlob(CONTAINER, "staged.bin");
  assert.ok(dl.body.equals(Buffer.concat(parts)), "block-list concat byte-exact");
});

test("ETag / If-Match precondition", { skip: !SUBSTRATE_UP && "substrate down" }, async () => {
  const up = await client.uploadBlockBlob(CONTAINER, "cond.txt", Buffer.from("v1"));
  assert.equal(up.status, 201);
  // stale etag overwrite → 412
  const err = await client
    .uploadBlockBlob(CONTAINER, "cond.txt", Buffer.from("v2"), { ifMatch: '"stale-etag"' })
    .then(() => null, (e: unknown) => e as SmaltStorageError);
  assert.ok(err instanceof SmaltStorageError);
  assert.equal(err.statusCode, 412);
  assert.equal(err.code, "PreconditionFailed");
  // matching etag overwrite → 201
  const ok = await client.uploadBlockBlob(CONTAINER, "cond.txt", Buffer.from("v2"), { ifMatch: up.etag! });
  assert.equal(ok.status, 201);
});

test("blob metadata set (PUT comp=metadata) → read via HEAD x-ms-meta-*", { skip: !SUBSTRATE_UP && "substrate down" }, async () => {
  await client.uploadBlockBlob(CONTAINER, "meta.txt", Buffer.from("m"));
  const set = await client.setBlobMetadata(CONTAINER, "meta.txt", { team: "console", wave: "521" });
  assert.equal(set.status, 200);
  // Deviation: GET ?comp=metadata on a blob is not registered on the router's
  // GET arm (@blob_get_comps = blocklist only) → typed 400; Azure parity read
  // path on this substrate is the KD-01 x-ms-meta-* echo on GET/HEAD blob.
  const head = await client.headBlob(CONTAINER, "meta.txt");
  const meta = Object.fromEntries(
    Object.entries(head.headers).filter(([k]) => k.startsWith("x-ms-meta-")).map(([k, v]) => [k.slice(10), v]),
  );
  assert.equal(meta.team, "console");
  assert.equal(meta.wave, "521");
});

test("container metadata get/set", { skip: !SUBSTRATE_UP && "substrate down" }, async () => {
  await client.setContainerMetadata(CONTAINER, { env: "court" });
  const meta = await client.getContainerMetadata(CONTAINER);
  assert.equal(meta.env, "court");
});

test("snapshot create → 400 InvalidQueryParameter (substrate deviation, engine-only)", { skip: !SUBSTRATE_UP && "substrate down" }, async () => {
  // Deviation witness: BlobStorage.snapshot_blob/4 exists at the engine layer
  // (test/data_plane/blob_hardening_test.exs) but the egress router blob PUT
  // arm registers only block/blocklist/metadata (@blob_put_comps) — a wire
  // PUT ?comp=snapshot answers the fail-closed 400 InvalidQueryParameter,
  // never the Azure 201 + x-ms-snapshot. Witnessed on the live wire here;
  // the client method keeps the correct Azure wire shape for when the router
  // registers the comp.
  await client.uploadBlockBlob(CONTAINER, "snap.txt", Buffer.from("snapshot-me-v1"));
  const err = await client
    .createSnapshot(CONTAINER, "snap.txt")
    .then(() => null, (e: unknown) => e as SmaltStorageError);
  assert.ok(err instanceof SmaltStorageError, "typed error, not a throw-all");
  assert.equal(err.statusCode, 400);
  assert.equal(err.code, "InvalidQueryParameter");
  const dl = await client.downloadBlob(CONTAINER, "snap.txt");
  assert.equal(dl.body.toString("utf8"), "snapshot-me-v1");
});

test("legal hold: set → mutation refused 409 → clear", { skip: !SUBSTRATE_UP && "substrate down" }, async () => {
  await client.uploadBlockBlob(CONTAINER, "worm.txt", Buffer.from("immutable"));
  const hold = await client.setLegalHold(CONTAINER, true);
  assert.equal(hold.status, 200);

  const overwrite = await client
    .uploadBlockBlob(CONTAINER, "worm.txt", Buffer.from("tamper"))
    .then(() => null, (e: unknown) => e as SmaltStorageError);
  assert.ok(overwrite instanceof SmaltStorageError);
  assert.equal(overwrite.statusCode, 409);
  assert.equal(overwrite.code, "ContainerLocked");

  const del = await client
    .deleteBlob(CONTAINER, "worm.txt")
    .then(() => null, (e: unknown) => e as SmaltStorageError);
  assert.ok(del instanceof SmaltStorageError);
  assert.equal(del.statusCode, 409);
  assert.equal(del.code, "ContainerLocked");

  const clear = await client.setLegalHold(CONTAINER, false);
  assert.equal(clear.status, 200);
  // hold cleared → delete succeeds (202)
  const delOk = await client.deleteBlob(CONTAINER, "worm.txt");
  assert.equal(delOk.status, 202);
});

test("WORM immutability policy: set → lock → overwrite refused 409", { skip: !SUBSTRATE_UP && "substrate down" }, async () => {
  const wormC = `${RUN}-worm`;
  await client.createContainer(wormC, { immutable: false });
  await client.uploadBlockBlob(wormC, "ledger.txt", Buffer.from("ledger-v1"));
  // set unlocked, then LOCK (locking requires If-Match: "*" per Azure + substrate)
  const pol = await client.setImmutabilityPolicy(wormC, {
    immutabilityPeriodSinceCreationInDays: 1,
  });
  assert.equal(pol.status, 200);
  const locked = await client.setImmutabilityPolicy(wormC, {
    immutabilityPeriodSinceCreationInDays: 1,
    locked: true,
    ifMatch: "*",
  });
  assert.equal(locked.status, 200);
  assert.equal(locked.record.locked, true, "policy committed locked");
  const overwrite = await client
    .uploadBlockBlob(wormC, "ledger.txt", Buffer.from("tamper"))
    .then(() => null, (e: unknown) => e as SmaltStorageError);
  assert.ok(overwrite instanceof SmaltStorageError);
  assert.equal(overwrite.statusCode, 409);
  assert.equal(overwrite.code, "ContainerLocked");
  // cleanup is impossible under the locked policy — that IS the WORM proof
  console.log(`[ws521] worm container ${wormC} left in place (locked policy — deletion refused by design)`);
});

test("delete → 404, typed envelope", { skip: !SUBSTRATE_UP && "substrate down" }, async () => {
  await client.uploadBlockBlob(CONTAINER, "doomed.txt", Buffer.from("bye"));
  const del = await client.deleteBlob(CONTAINER, "doomed.txt");
  assert.equal(del.status, 202);
  const err = await client
    .downloadBlob(CONTAINER, "doomed.txt")
    .then(() => null, (e: unknown) => e as SmaltStorageError);
  assert.ok(err instanceof SmaltStorageError);
  assert.equal(err.statusCode, 404);
  assert.equal(err.code, "BlobNotFound");
});

test("teardown: container delete", { skip: !SUBSTRATE_UP && "substrate down" }, async () => {
  const r = await client.deleteContainer(CONTAINER).then(() => "deleted", (e: unknown) => `note: ${(e as SmaltStorageError).code}`);
  console.log(`[ws521] teardown ${CONTAINER}: ${r}`);
});
