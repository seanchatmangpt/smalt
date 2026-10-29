// seed_blob_cors.mjs — idempotent blob `<Cors>` rule seeding for the
// in-browser blob leg (BK-91, BK-89 retry).
//
// Why this exists: the blob plane answers OPTIONS preflight from STORED
// account `<Cors>` rules only (Smalt.DataPlane.BlobCors, :smalt_blob_cors —
// ETS-only, NOT durable across a substrate bounce). The browser smoke's blob
// leg otherwise SKIPs loudly with blob=SKIP(cors-preflight-403:...). This
// script re-seeds the rules over the wire so the demo walk is repeatable;
// browser_smoke.mjs wires it as a best-effort pre-step.
//
// Usage: node scripts/seed_blob_cors.mjs   (exit 0 seeded | 1 loud failure)
//
// Env overrides: SMALT_EGRESS (default http://127.0.0.1:8443),
// SMALT_STS (default http://127.0.0.1:9443), SMALT_TENANT, SMALT_ACCOUNT.
const EGRESS = process.env.SMALT_EGRESS ?? "http://127.0.0.1:8443";
const stsBase = process.env.SMALT_STS ?? "http://127.0.0.1:9443";
const TENANT = process.env.SMALT_TENANT ?? "smalt-tenant";
const ACCOUNT = process.env.SMALT_ACCOUNT ?? "popcorn";
const MS_VERSION = "2021-12-02";

// The demo walk's methods/headers (PopcornDemo.LiveBlob + LiveEG): PUT/GET
// blob, PUT block/blocklist, DELETE blob/container, POST EventGrid publish
// (/topics/:topic/events), OPTIONS preflight; custom headers x-ms-version /
// x-ms-blob-type / content-type / authorization.
// Two rules: (1) exact loopback origins — the documented posture, and (2)
// a wildcard rule — REQUIRED in practice because the browser smoke serves
// on a RANDOM 127.0.0.1 port and BlobCors origin matching is exact-string,
// so no exact origin entry can ever match http://127.0.0.1:<random-port>.
const XML = `<?xml version="1.0" encoding="utf-8"?>
<StorageServiceProperties>
  <Cors>
    <CorsRule>
      <AllowedOrigins>http://127.0.0.1,http://localhost</AllowedOrigins>
      <AllowedMethods>GET,PUT,HEAD,OPTIONS,DELETE,POST</AllowedMethods>
      <AllowedHeaders>*</AllowedHeaders>
      <ExposedHeaders>*</ExposedHeaders>
      <MaxAgeInSeconds>3600</MaxAgeInSeconds>
    </CorsRule>
    <CorsRule>
      <AllowedOrigins>*</AllowedOrigins>
      <AllowedMethods>GET,PUT,HEAD,OPTIONS,DELETE,POST</AllowedMethods>
      <AllowedHeaders>*</AllowedHeaders>
      <ExposedHeaders>*</ExposedHeaders>
      <MaxAgeInSeconds>3600</MaxAgeInSeconds>
    </CorsRule>
  </Cors>
</StorageServiceProperties>`;

async function mintToken() {
  const res = await fetch(`${stsBase}/${TENANT}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials&client_id=bk91-cors-seed&client_secret=not-checked",
  });
  const body = await res.text();
  if (res.status !== 200) throw new Error(`sts-mint http-${res.status}: ${body.slice(0, 200)}`);
  const tok = JSON.parse(body).access_token;
  if (!tok) throw new Error("sts-mint: no access_token in body");
  return tok;
}

// Idempotent: the PUT fully replaces the account's rule set each run
// (parity: PUT without a Cors block clears rules; we always send both rules).
export async function seedBlobCors({ log = console.log } = {}) {
  const token = await mintToken();
  const url = `${EGRESS}/${ACCOUNT}?restype=service&comp=properties`;
  const res = await fetch(url, {
    method: "PUT",
    headers: {
      "authorization": `Bearer ${token}`,
      "x-ms-version": MS_VERSION,
      "content-type": "application/xml",
    },
    body: XML,
  });
  const body = await res.text();
  if (res.status !== 202) {
    throw new Error(`cors-seed http-${res.status}: ${body.slice(0, 200)}`);
  }
  log(`SEED_BLOB_CORS: OK — ${ACCOUNT} <Cors> rules seeded (202, PUT ${url})`);
  return 0;
}

// Direct-invocation face (the import face is used by browser_smoke.mjs).
if (process.argv[1] && import.meta.url.endsWith(process.argv[1].split("/").pop())) {
  seedBlobCors().then(
    () => process.exit(0),
    (e) => { console.error(`SEED_BLOB_CORS: FAIL — ${e.message}`); process.exit(1); },
  );
}
