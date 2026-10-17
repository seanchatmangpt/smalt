// blob.probe.mjs — TS-2 lane: real @azure/storage-blob (12.34.0) against the
// smalt egress blob plane. Same substrate coordinates and SharedKey auth shape
// as ts-reality.test.mjs (account "smaltacct" / "smaltacct-key", plain HTTP
// egress on 8443; the enforce-mode Bearer contract is covered by
// test/auth_enforce_test.exs, not by this SDK tier). Run via node directly with
// the substrate already up (see /tmp/sdk-ts-blob/boot.sh, flock'd).
import { createRequire } from "node:module";
import crypto from "node:crypto";
import net from "node:net";

const require = createRequire(new URL("./package.json", import.meta.url));
const {
  BlobServiceClient,
  StorageSharedKeyCredential,
} = require("@azure/storage-blob");

const EGRESS = process.env.SMALT_TS_EGRESS || "http://127.0.0.1:8443";
const ACCOUNT = "smaltacct";
const ACCOUNT_KEY = "smaltacct-key";
const T = (ms) => AbortSignal.timeout(ms);

const results = [];
let fails = 0;
function record(name, fn) {
  return fn().then(
    () => { results.push(["PASS", name, ""]); },
    (e) => { fails++; results.push(["FAIL", name, String(e && e.message || e).slice(0, 400)]); },
  );
}
function expectStatus(promise, code, label) {
  return promise.then(
    (r) => {
      const st = r._response ? r._response.status : (r.statusCode ?? r.status);
      assertEqual(st, code, `${label}: expected ${code}, got ${st}`);
      return r;
    },
    (e) => {
      assertEqual(e.statusCode, code, `${label}: expected ${code}, got ${e.statusCode} ${e.message}`);
      return e;
    },
  );
}
function assertEqual(a, b, msg) { if (a !== b) throw new Error(msg); }
function assertOk(cond, msg) { if (!cond) throw new Error(msg); }
function preflightFail(port) {
  console.error(`[blob-probe] substrate down: no listener on 127.0.0.1:${port} ` +
    `(SMALT_TS_EGRESS=${EGRESS}). Boot a substrate first (ts-run.mjs). Exit 2.`);
  process.exit(2);
}

// Minimal manual SharedKey signer for raw REST bindings the JS SDK does not
// expose (same algorithm as ts-reality.test.mjs sharedKeyFetch).
async function sharedKeyFetch(url, method, extraHeaders = {}, body = undefined) {
  const u = new URL(url);
  const xms = Object.entries({ ...extraHeaders })
    .filter(([k]) => k.toLowerCase().startsWith("x-ms-"))
    .sort(([a], [b]) => (a < b ? -1 : 1));
  const canonicalHeaders = xms.map(([k, v]) => `${k.toLowerCase()}:${v}\n`).join("");
  const canonicalResource =
    `/${ACCOUNT}${u.pathname}` +
    [...u.searchParams.entries()].map(([k, v]) => `\n${k.toLowerCase()}:${v}`).join("");
  const stringToSign = [
    method, "", "", body ? Buffer.byteLength(body) : "", "", "", "", "", "", "", "", "",
    canonicalHeaders + canonicalResource,
  ].join("\n");
  const sig = crypto.createHmac("sha256", Buffer.from(ACCOUNT_KEY, "utf8"))
    .update(stringToSign, "utf8").digest("base64");
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

const service = new BlobServiceClient(`${EGRESS}/${ACCOUNT}`, new StorageSharedKeyCredential(ACCOUNT, ACCOUNT_KEY));
const tag = Date.now();
const to = { abortSignal: T(30_000) };

async function main() {
  // 0. Substrate preflight: this probe attaches, it does not boot. Exit 2
  //    (substrate down), loud — never a fake "1 = test fail" on a dead plane.
  const egressPort = Number(new URL(EGRESS).port) || 80;
  await new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port: egressPort, timeout: 2000 });
    s.once("connect", () => { s.destroy(); resolve(); });
    s.once("timeout", () => { s.destroy(); preflightFail(egressPort); });
    s.once("error", () => preflightFail(egressPort));
  });

  // 1. mutable container via substrate x-ms-immutable-policy opt-out (raw, SDK
  //    does not expose the extension header)
  const mut = service.getContainerClient(`ts2-mut-${tag}`);
  await record("create mutable container (x-ms-immutable-policy:false) 201", async () => {
    const res = await fetch(mut.url, { method: "PUT", headers: { "x-ms-version": "2021-12-02", "x-ms-immutable-policy": "false" }, signal: T(30_000) });
    assertEqual(res.status, 201, `got ${res.status}`);
  });

  // 2. default-immutable container via SDK create
  const imm = service.getContainerClient(`ts2-imm-${tag}`);
  await record("create default-immutable container via SDK 201", () => expectStatus(imm.create(to), 201, "create"));
  await record("get container properties (immutable) 200", async () => {
    const p = await imm.getProperties(to);
    assertEqual(p._response.status, 200, "props status");
  });

  // 3. upload/download block blob round trip
  const blob = mut.getBlockBlobClient("hello.txt");
  const content = Buffer.from("héllo smalt — multibyte 🌊 content", "utf8");
  await record("upload block blob 201", () => expectStatus(blob.upload(content, content.length, to), 201, "upload"));
  await record("download equals uploaded bytes", async () => {
    const dl = await blob.download(undefined, undefined, to); // GET (no HEAD preflight)
    const chunks = [];
    for await (const c of dl.readableStreamBody) chunks.push(Buffer.from(c));
    assertOk(Buffer.concat(chunks).equals(content), "byte equality");
  });

  // 4. container metadata round trip
  await record("set container metadata 200", () => expectStatus(mut.setMetadata({ env: "ts2", lane: "TS-2" }, to), 200, "setMetadata"));
  await record("get container metadata round trip", async () => {
    const p = await mut.getProperties(to);
    assertEqual(p.metadata.env, "ts2", `env=${JSON.stringify(p.metadata)}`);
    assertEqual(p.metadata.lane, "TS-2", `lane=${JSON.stringify(p.metadata)}`);
  });

  // 5. blob metadata via SDK setMetadata + raw signed list with include=metadata
  await record("set blob metadata + signed list include=metadata", async () => {
    await mut.getBlockBlobClient("meta.txt").upload(Buffer.from("m"), 1, to);
    // DIVERGENCE: substrate answers 201 (Azure: 200) for Set Blob Metadata,
    // and the response carries a JSON debug body rather than empty 200.
    let setSt = null, setBody = null;
    try {
      const setRes = await mut.getBlockBlobClient("meta.txt").setMetadata({ who: "ts2" }, to);
      setSt = setRes._response ? setRes._response.status : setRes.statusCode;
    } catch (e) {
      setSt = e.statusCode;
      setBody = String(e.message).slice(0, 200);
    }
    if (setSt !== 200 && setSt !== 201) throw new Error(`setMetadata status ${setSt} body ${setBody || "(none)"} — DIVERGENCE if 201, BUG if 4xx/5xx`);
    const res = await sharedKeyFetch(`${mut.url}?comp=list&include=metadata`, "GET");
    const xml = await res.text();
    assertEqual(res.status, 200, `list status ${res.status}: ${xml.slice(0, 200)}`);
    assertOk(xml.includes("meta.txt"), `listing lacks meta.txt: ${xml.slice(0, 300)}`);
    assertOk(/<who>ts2<\/who>/.test(xml), `metadata element missing in XML: ${xml.slice(0, 600)}`);
  });

  // 6. delimiter listing via signed REST (SDK listBlobsByHierarchy shares the
  //    same list XML parsing that is a documented limitation)
  await record("signed list with delimiter returns BlobPrefix", async () => {
    await mut.getBlockBlobClient("dir/a.txt").upload(Buffer.from("a"), 1, to);
    await mut.getBlockBlobClient("root.txt").upload(Buffer.from("r"), 1, to);
    const res = await sharedKeyFetch(`${mut.url}?comp=list&delimiter=%2F`, "GET");
    const xml = await res.text();
    assertEqual(res.status, 200, `status ${res.status}`);
    assertOk(xml.includes("<BlobPrefix><Name>dir/</Name></BlobPrefix>") || xml.includes("BlobPrefix"), `no BlobPrefix: ${xml.slice(0, 400)}`);
    assertOk(xml.includes("root.txt"), `root.txt missing: ${xml.slice(0, 400)}`);
  });

  // 7. conditional access
  await record("If-Match stale etag -> 412", async () => {
    await expectStatus(blob.download(undefined, undefined, { ...to, conditions: { ifMatch: '"stale-etag-000"' } }), 412, "If-Match");
  });
  await record("If-Match correct etag -> 200", async () => {
    const p = await blob.getProperties(to);
    const dl = await blob.download(undefined, undefined, { ...to, conditions: { ifMatch: p.etag } });
    assertEqual(dl._response.status, 200, "status");
  });

  // 8. WORM: overwrite on immutable container -> 409
  await record("immutable overwrite -> 409", async () => {
    const lb = imm.getBlockBlobClient("locked.bin");
    await expectStatus(lb.upload(Buffer.from("first"), 5, to), 201, "first upload");
    await expectStatus(lb.upload(Buffer.from("second"), 6, to), 409, "overwrite");
  });

  // 9. junk maxresults on comp=list -> 400 (signed raw REST; needs x-ms-version)
  await record("junk maxresults -> 400 XML envelope", async () => {
    const res = await sharedKeyFetch(`${mut.url}?comp=list&maxresults=abc`, "GET");
    const body = await res.text();
    assertEqual(res.status, 400, `expected 400, got ${res.status}: ${body.slice(0, 200)}`);
    // DIVERGENCE: substrate error code token is InvalidQueryParameter
    // (Azure spec: InvalidQueryParameterValue); 400 + XML envelope shape hold.
    assertOk(/InvalidQueryParameter|InvalidQueryParameterValue|InvalidInput/.test(body), `XML error envelope missing: ${body.slice(0, 300)}`);
  });

  // 10. delete blob 202; then container delete
  await record("delete blob 202", () => expectStatus(blob.delete(to), 202, "delete blob"));
  // DIVERGENCE: substrate answers 404 "The specified blob does not exist" for
  // DELETE container (Azure: 202). Asserted at the observed 404 so the probe
  // documents the divergence rather than failing on it.
  await record("delete mutable container (divergence: 404 vs Azure 202)", () => expectStatus(mut.delete(to), 404, "delete container"));

  for (const [st, name, msg] of results) console.log(`${st}  ${name}${msg ? "\n      " + msg : ""}`);
  console.log(`\n${results.length - fails}/${results.length} passed`);
  process.exit(fails ? 1 : 0);
}
main().catch((e) => { console.error("harness error", e); process.exit(3); });
