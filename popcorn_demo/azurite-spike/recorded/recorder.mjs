// recorder.mjs — W30-F recorded-test pattern (Azure SDK guideline testing-8).
// Records a real blob round trip against smalt (guideline: recorded tests pin
// an explicit api-version, refreshed on service-team notification).
//
// Usage: node recorder.mjs [endpoint]
//   endpoint default http://127.0.0.1:8443 (smalt blob data plane). The task
//   named 9444; that TLS twin routes only the ARM surface (blob paths return
//   RouteNotFound there), so the recording targets the 8443 data plane.
//
// Emits recordings/blob-roundtrip.json:
//   {schema, endpoint, account, apiVersion, recordedAt, transactions: [...]}
// Each transaction: {name, request: {method, url, headers, body},
//                    response: {status, headers, body}}

import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const endpoint = process.argv[2] || "http://127.0.0.1:8443";
const account = "devstoreaccount1";
// Fresh container per record run: smalt HTTP-created containers default
// immutable=true (WORM), so a used container can never be deleted — reuse
// would record 409s. The name is substituted back at replay time.
const container = `rec-pattern-${Date.now()}-${process.pid}`;
const blobName = "roundtrip.txt";
const apiVersion = "2021-12-02"; // explicit, pinned per testing-8
const blobBody = "hello-recorded-pattern";

const sts = process.env.SMALT_STS || "http://127.0.0.1:9443";
const token = await getToken(sts, "organizations");

// --- live transport ---------------------------------------------------------
async function rawRequest(method, url, headers = {}, bodyBuf = null) {
  const res = await fetch(url, { method, headers, body: bodyBuf });
  const resHeaders = {};
  res.headers.forEach((v, k) => (resHeaders[k] = v));
  const resBody = Buffer.from(await res.arrayBuffer());
  return { status: res.status, headers: resHeaders, body: resBody.toString("base64") };
}

async function getToken(stsBase, tenant) {
  const res = await fetch(`${stsBase}/${tenant}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body:
      "grant_type=client_credentials&client_id=recorder&client_secret=recorder-secret&scope=https://storage.azure.com/.default",
  });
  if (!res.ok) throw new Error(`STS ${res.status}: ${await res.text()}`);
  return (await res.json()).access_token;
}

// --- unrecorded setup (not part of the recording) ---------------------------
// Deterministic clean slate: drop the container if a prior run left it, so the
// recorded create-container deterministically returns 201 on every record run.
async function cleanSlate() {
  await rawRequest(
    "DELETE",
    `${endpoint}/${account}/${container}`,
    { Authorization: `Bearer ${token}`, "x-ms-version": apiVersion },
  );
}

// --- recorded transactions (in order) ---------------------------------------
const commonHeaders = { Authorization: `Bearer ${token}`, "x-ms-version": apiVersion };
const transactions = [];

function record(name, method, url, headers, reqBody, res) {
  transactions.push({
    name,
    request: { method, url, headers, body: reqBody },
    response: {
      status: res.status,
      headers: res.headers,
      body: Buffer.from(res.body, "base64").toString(),
    },
  });
  console.log(`[record] ${name}: ${res.status}`);
}

await cleanSlate();

// 1. create container
{
  const url = `${endpoint}/${account}/${container}?restype=container`;
  const res = await rawRequest("PUT", url, commonHeaders);
  record("create-container", "PUT", url, commonHeaders, "", res);
}

// 2. put block blob
{
  const url = `${endpoint}/${account}/${container}/${blobName}`;
  const headers = { ...commonHeaders, "x-ms-blob-type": "BlockBlob" };
  const res = await rawRequest("PUT", url, headers, Buffer.from(blobBody));
  record("put-blob", "PUT", url, headers, blobBody, res);
}

// 3. get blob
{
  const url = `${endpoint}/${account}/${container}/${blobName}`;
  const res = await rawRequest("GET", url, commonHeaders);
  record("get-blob", "GET", url, commonHeaders, "", res);
}

// 4. get container properties
{
  const url = `${endpoint}/${account}/${container}?restype=container`;
  const res = await rawRequest("GET", url, commonHeaders);
  record("get-container-properties", "GET", url, commonHeaders, "", res);
}

// 5. delete blob
{
  const url = `${endpoint}/${account}/${container}/${blobName}`;
  const res = await rawRequest("DELETE", url, commonHeaders);
  record("delete-blob", "DELETE", url, commonHeaders, "", res);
}

// 6. delete container
{
  const url = `${endpoint}/${account}/${container}`;
  const res = await rawRequest("DELETE", url, commonHeaders);
  record("delete-container", "DELETE", url, commonHeaders, "", res);
}

const outFile = join(here, "recordings", "blob-roundtrip.json");
mkdirSync(dirname(outFile), { recursive: true });
const payload = {
  schema: "recorded-test/v1",
  endpoint,
  account,
  apiVersion,
  recordedAt: new Date().toISOString(),
  transactions,
};
writeFileSync(outFile, JSON.stringify(payload, null, 2) + "\n");
console.log(`[record] wrote ${transactions.length} transactions -> ${outFile}`);
