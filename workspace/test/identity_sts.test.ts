/**
 * STS identity court — console lane (v26.10.16).
 *
 * Real-collaborator test (Chicago): exercises the live smalt substrate's STS
 * surfaces over real HTTP via StsClient. Exit contract: 0 pass / 1 fail /
 * 3 SKIP (substrate down — loud, never a fake pass).
 *
 * Run:
 *   node workspace/test/run-identity.test.mjs
 */
import assert from "node:assert/strict";
import {
  SMALT_ARM_RESOURCE,
  StsClient,
  TokenClock,
  b64urlDecode,
  decodeJwt,
  inspectClaims,
  parseWwwAuthenticate,
} from "../lib/azure/identity.js";

let failures = 0;

async function main(): Promise<void> {
const ARM = process.env.SMALT_ARM_TEST ?? "http://127.0.0.1:9443";

function check(name: string, fn: () => void | Promise<void>): Promise<void> {
  return Promise.resolve()
    .then(fn)
    .then(() => console.log(`[PASS] ${name}`))
    .catch((e) => {
      failures++;
      console.log(`[FAIL] ${name} — ${e && e.message}`);
    });
}

// Craft a token-shaped string with a mutated payload (signature left as the
// STS produced it — the substrate's signature check must refuse the mutation).
function withPayloadMutation(
  token: string,
  mutate: (p: Record<string, unknown>) => Record<string, unknown>,
): string {
  const [h, , s] = token.split(".");
  const payload = JSON.parse(b64urlDecode(
    h === h ? token.split(".")[1] : token.split(".")[1],
  ));
  const body = Buffer.from(JSON.stringify(mutate(payload))).toString("base64url");
  return `${h}.${body}.${s}`;
}

const client = new StsClient({ armBase: ARM, tenant: "smalt-tenant" });

// --- substrate up? (loud skip, exit 3) --------------------------------------
const { assertLocalUrl } = await import("../lib/smalt.js");
const probe = await fetch(assertLocalUrl(new URL("/metadata/endpoints", ARM).toString())).then(
  (r) => r.status,
  () => 0,
);
if (probe !== 200) {
  console.log(`[SKIP] smalt substrate not reachable at ${ARM} (probe ${probe})`);
  process.exit(3);
}

// 1. client_credentials mint + claims validation
await check("client_credentials mint → 3-segment JWT, aud/iss/roles correct", async () => {
  const t = await client.mint();
  assert.equal(t.tokenType, "Bearer");
  assert.ok(t.expiresInSec > 0);
  assert.equal(decodeJwt(t.accessToken).header.alg, "HS256");
  const ins = inspectClaims(t.accessToken);
  assert.equal(ins.aud, SMALT_ARM_RESOURCE);
  assert.equal(ins.iss, `${ARM}/smalt-tenant/v2.0`);
  assert.deepEqual(ins.roles, ["Contributor", "Owner"]);
  assert.ok(typeof ins.appid === "string" && ins.appid.length > 0);
  assert.ok(typeof ins.oid === "string" && ins.oid.length > 0);
  assert.ok(typeof ins.sub === "string" && ins.sub.length > 0);
  assert.ok(ins.window.isValidNow, `window ${ins.window.rendered}`);
  assert.ok(ins.window.msUntilExpiry > 0);
});

// 2. protected route with minted token → 200 (STS-verified acceptance)
await check("protected route 200 with minted bearer (verifyViaSts)", async () => {
  const t = await client.mint();
  const v = await client.verifyViaSts(t.accessToken);
  assert.equal(v.accepted, true);
  assert.equal(v.status, 200);
});

// 3. expired-token mutation → 401 (substrate refuses)
await check("expired/mutated token → 401 refused by substrate", async () => {
  const t = await client.mint();
  const expired = withPayloadMutation(t.accessToken, (p) => ({ ...p, exp: 1_000_000 }));
  const v = await client.verifyViaSts(expired);
  assert.equal(v.accepted, false);
  assert.equal(v.status, 401);
  // local window inspection also flags it
  const ins = inspectClaims(expired, 2_000_000_000);
  assert.equal(ins.window.isExpired, true);
});

// 4. malformed token → 401
await check("malformed token → 401", async () => {
  const v = await client.verifyViaSts("not.a.jwt");
  assert.equal(v.accepted, false);
  assert.equal(v.status, 401);
});

// 5. discovery: root OIDC document parses with token_endpoint present
await check("openid-configuration parses (issuer + token_endpoint)", async () => {
  const doc = await client.openidConfigurationRoot();
  assert.ok(typeof doc.issuer === "string");
  assert.ok(String(doc.token_endpoint).includes("/oauth2/v2.0/token"));
  assert.ok(
    Array.isArray(doc.id_token_signing_alg_values_supported) &&
      doc.id_token_signing_alg_values_supported.includes("HS256"),
  );
});

// 6. discovery: instance discovery 2022-09-01 envelope
await check("common/discovery/instance envelope (tenant_discovery_endpoint)", async () => {
  const doc = await client.instanceDiscovery();
  assert.ok(doc["tenant_discovery_endpoint"] ?? doc["metadata"], "instance envelope shape");
  assert.ok(
    String(doc["token_endpoint"]).endsWith("/oauth2/v2.0/token"),
    "instance token_endpoint",
  );
  assert.ok(String(doc["tenant_discovery_endpoint"]).includes("/v2.0/.well-known/openid-configuration"));
});

// 7. discovery: /metadata/endpoints full envelope, authority echo
await check("metadata/endpoints authority echo", async () => {
  const doc = await client.metadataEndpoints();
  const ad = doc as { activeDirectoryEndpoint?: string };
  assert.ok(typeof ad.activeDirectoryEndpoint === "string" && ad.activeDirectoryEndpoint.startsWith("http"));
  assert.equal(
    (doc as { authentication?: { audiences?: string[] } }).authentication?.audiences?.[0],
    SMALT_ARM_RESOURCE,
  );
});

// 8. JWKS is honestly empty (HS256 shared secret not published)
await check("discovery/keys returns empty JWKS (honest, by design)", async () => {
  const k = await client.jwks();
  assert.deepEqual(k.keys, []);
});

// 9. tenant enumeration
await check("tenant list (ARM /tenants)", async () => {
  const tenants = await client.listTenants();
  assert.ok(Array.isArray(tenants) && tenants.length >= 1);
  assert.ok(tenants[0]["tenantId"]);
});

// 10. challenge-response helper: tokenless → 401 challenge → mint → retry 200
await check("withChallenge: 401 challenge parsed, retry 200", async () => {
  const r = await client.withChallenge<Record<string, unknown>>("/subscriptions?api-version=2022-09-01");
  assert.equal(r.challenge.scheme, "Bearer");
  assert.equal(r.challenge.params.error, "invalid_token");
  assert.equal(r.status, 200);
  assert.ok(r.body && typeof r.body === "object");
});

// 11. TokenClock: expiry + needsRefresh transitions under a moving clock
await check("TokenClock expiry/refresh transitions", async () => {
  const minted = await client.mint();
  const ins = inspectClaims(minted.accessToken);
  const expMs = (ins.exp as number) * 1000;
  let now = expMs - 10 * 60_000; // 10 min before expiry
  const clock = new TokenClock(minted.accessToken, { nowMs: () => now, slackMs: 60_000 });
  assert.equal(clock.needsRefresh, false);
  now = expMs - 30_000; // inside slack
  assert.equal(clock.needsRefresh, true);
  assert.equal(clock.isExpired, false);
  now = expMs + 1;
  assert.equal(clock.isExpired, true);
  assert.equal(clock.needsRefresh, true);
});

// 13. WWW-Authenticate parser unit
await check("parseWwwAuthenticate params", () => {
  const c = parseWwwAuthenticate(
    'Bearer authorization="http://x/organizations", resource="http://x", error="invalid_token", error_description="MissingBearerToken"',
  );
  assert.equal(c.scheme, "Bearer");
  assert.equal(c.params.error, "invalid_token");
  assert.equal(c.params.error_description, "MissingBearerToken");
});

// 14. air-gap guard: smaltFetch refuses non-local host
await check("air-gap guard refuses non-local host", async () => {
  assert.throws(() => assertLocalUrl("https://management.azure.com/subscriptions"), /Air-gap/);
  const bad = new StsClient({ armBase: "https://evil.example.com" });
  await assert.rejects(() => bad.mint(), /Air-gap/);
});

}

main().then(() => process.exit(failures === 0 ? 0 : 1));
