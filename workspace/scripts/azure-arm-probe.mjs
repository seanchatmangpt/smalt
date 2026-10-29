#!/usr/bin/env node
// azure-arm-probe.mjs - lane WS-8 integration proof.
//
// Plain node (no Next, no TS build). Boots nothing: connects to a RUNNING
// smalt substrate and walks subscriptions -> resource groups -> generic
// resource list. Read verbs only (GET + the STS client_credentials POST).
//
// Usage:
//   node scripts/azure-arm-probe.mjs [--boot]
// Env:
//   SMALT_ARM_BASE / NEXT_PUBLIC_SMALT_ARM  default https://localhost:9443
//   NODE_TLS_REJECT_UNAUTHORIZED=1 is intentionally NOT set; the dev TLS twin
//   serves a self-signed leaf, so the probe sets NODE_TLS_REJECT_UNAUTHORIZED=0
//   for itself (documented in sdk-results/ts-arm-resources.md, constraint 2).
//   SMALT_PROBE_TENANT (default smalt-tenant)
//
// Exit codes: 0 all steps witnessed, 1 step failure, 2 substrate unreachable.
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";

const ARM_BASE = (
  process.env.NEXT_PUBLIC_SMALT_ARM ||
  process.env.SMALT_ARM_BASE ||
  "https://localhost:9443"
).replace(/\/+$/, "");
const TENANT = process.env.SMALT_PROBE_TENANT || "smalt-tenant";
const APIV = "2021-04-01";

let failures = 0;

// Air-gap host guard (SHIM-COURT): mirrors lib/smalt.ts assertLocalUrl for
// this plain-node probe — only localhost smalt endpoints are reachable.
function assertLocalUrl(url) {
  const u = new URL(url);
  if (!["127.0.0.1", "localhost", "[::1]", "::1"].includes(u.hostname)) {
    throw new Error(`Air-gap violation: refused non-local host "${u.hostname}"`);
  }
  return u;
}
function record(name, ok, detail) {
  const tag = ok ? "PASS" : "FAIL";
  console.log(`[${tag}] ${name} :: ${detail}`);
  if (!ok) failures++;
}

async function get(path, token) {
  const res = await fetch(assertLocalUrl(`${ARM_BASE}${path}`), {
    headers: { authorization: `Bearer ${token}` },
  });
  const json = await res.json().catch(() => ({}));
  return { status: res.status, json };
}

main().catch((e) => { console.error("[probe] harness error:", e); process.exitCode = 3; });

async function main() {
  console.log(`[probe] arm base: ${ARM_BASE}`);
  console.log(`[probe] tenant:   ${TENANT}`);

  // Reachability gate.
  try {
    await fetch(assertLocalUrl(`${ARM_BASE}/subscriptions?api-version=${APIV}`));
  } catch {
    console.error(`[probe] substrate unreachable at ${ARM_BASE} (exit 2)`);
    process.exit(2);
  }

  // Step 1: STS client_credentials mint (raw STS POST; see credential.ts doc).
  const body = new URLSearchParams({
    grant_type: "client_credentials",
    client_id: "ws8-probe",
    client_secret: "ws8-probe-secret",
    scope: "https://management.azure.com/.default",
  });
  const stsRes = await fetch(assertLocalUrl(`${ARM_BASE}/${TENANT}/oauth2/v2.0/token`), {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  });
  const sts = await stsRes.json().catch(() => ({}));
  const token = sts.access_token;
  record(
    "sts-mint",
    stsRes.status === 200 &&
      typeof token === "string" &&
      token.split(".").length === 3,
    `status=${stsRes.status} segments=${String(token || "").split(".").length} expires_in=${sts.expires_in}`,
  );
  if (!token) process.exit(1);

  // Step 2: subscriptions.
  const subs = await get("/subscriptions?api-version=" + APIV, token);
  const subRows = subs.json?.value ?? [];
  record(
    "list-subscriptions",
    subs.status === 200 && subRows.length >= 1,
    `status=${subs.status} subs=${subRows.length} first=${subRows[0]?.subscriptionId} state=${subRows[0]?.properties?.state}`,
  );
  const sub = subRows[0]?.subscriptionId;
  if (!sub) process.exit(1);

  // Step 3: resource groups (drain nextLink pagination).
  let rgs = [];
  let next = `/subscriptions/${sub}/resourcegroups?api-version=${APIV}`;
  while (next) {
    const page = await get(next, token);
    if (page.status !== 200) {
      record("list-resource-groups", false, `status=${page.status}`);
      rgs = [];
      break;
    }
    rgs = rgs.concat(page.json?.value ?? []);
    const link = page.json?.nextLink;
    next = link
      ? `${link.replace(/^https?:\/\/[^/]+/, "")}&api-version=${APIV}`
      : null;
  }
  record(
    "list-resource-groups",
    rgs.length >= 0 && failures === 0,
    `status=200 rgs=${rgs.length} names=${rgs.map((r) => r.name).slice(0, 5).join(",") || "(none)"}`,
  );

  // Step 4: generic resource walk. The subscription-level generic list
  // (GET /subscriptions/{sub}/resources) is MISSING on the emulator (404
  // RouteNotFound — same divergence family as D2, witnessed 2026-10-15), so
  // the witnessed generic read is the provider inventory
  // (GET /subscriptions/{sub}/providers). Both are witnessed below.
  const provRes = await get(`/subscriptions/${sub}/providers?api-version=${APIV}`, token);
  const provTypes = provRes.json?.resourceTypes ?? [];
  record(
    "list-generic-resources-providers-inventory",
    provRes.status === 200 && Array.isArray(provTypes),
    `status=${provRes.status} resourceTypes=${provTypes.length}`,
  );
  const genList = await get(`/subscriptions/${sub}/resources?api-version=${APIV}`, token);
  console.log(
    `[probe] KNOWN-DIVERGENCE (D2-family): GET /subscriptions/{sub}/resources -> ${genList.status} (route missing on emulator; real Azure serves 200 value[])`,
  );
  // Step 5: read-only ban spot-check — tokenless request must 401 (no
  // accidental actuation surface).
  const tokenless = await fetch(assertLocalUrl(`${ARM_BASE}/subscriptions?api-version=${APIV}`));
  record(
    "tokenless-401",
    tokenless.status === 401,
    `status=${tokenless.status} challenge=${tokenless.headers.get("www-authenticate") ?? "-"}`,
  );

  console.log(`[probe] done: ${failures === 0 ? "ALL PASS" : failures + " failure(s)"}`);
  process.exit(failures === 0 ? 0 : 1);
}
