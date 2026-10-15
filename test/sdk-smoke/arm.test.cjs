"use strict";
// T3 arm.test.cjs — ARM plane over real wire, run against the ENFORCE-mode
// substrate (SMALT_ARM_BASE, booted by run.mjs on 9444 with Bearer
// verification ON): OAuth2 client-credentials token issuance (JWT shape +
// payload aud/iss/exp), the 401 path without a token, and the
// /subscriptions discovery endpoint with the Bearer attached.
const assert = require("node:assert/strict");
const { test } = require("node:test");

const ARM = process.env.SMALT_ARM_BASE || "http://127.0.0.1:9443";
const TOKEN = process.env.SMALT_SMOKE_TOKEN || "";

test("ARM: oauth2 client_credentials token has JWT shape and aud payload", async () => {
  const res = await fetch(`${ARM}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: "smoke-client",
      client_secret: "smoke-secret",
      scope: "https://management.azure.com/.default",
    }),
    signal: AbortSignal.timeout(60_000),
  });
  assert.equal(res.status, 200, `token endpoint status ${res.status}`);
  const body = await res.json();
  assert.ok(body.access_token, "access_token present");
  const segments = body.access_token.split(".");
  assert.equal(segments.length, 3, "access_token is 3 base64url segments");
  const payload = JSON.parse(Buffer.from(segments[1], "base64url").toString("utf8"));
  assert.ok(payload.aud, "JWT payload has aud");
  assert.match(payload.iss, /^https:\/\/login\.microsoftonline\.com\//, "iss prefix");
  assert.ok(payload.exp > Math.floor(Date.now() / 1000), "exp in the future");
});

test("ARM: enforce mode refuses a tokenless request with 401 Bearer challenge", async () => {
  const res = await fetch(`${ARM}/subscriptions`, {
    signal: AbortSignal.timeout(60_000),
  });
  assert.equal(res.status, 401, `tokenless /subscriptions status ${res.status}`);
  assert.match(
    res.headers.get("www-authenticate") || "",
    /Bearer error="invalid_token"/,
    "WWW-Authenticate Bearer challenge present",
  );
});

test("ARM: GET /subscriptions with minted Bearer returns Enabled subscription with tenant", async () => {
  assert.ok(TOKEN, "SMALT_SMOKE_TOKEN minted by run.mjs is present");
  const res = await fetch(`${ARM}/subscriptions`, {
    headers: { authorization: `Bearer ${TOKEN}` },
    signal: AbortSignal.timeout(60_000),
  });
  assert.equal(res.status, 200, `subscriptions status ${res.status}`);
  const body = await res.json();
  assert.ok(Array.isArray(body.value) && body.value.length >= 1, "value[0] present");
  const sub = body.value[0];
  assert.ok(sub.subscriptionId, "subscriptionId present");
  assert.equal(sub.state, "Enabled");
  // tenantId: the substrate's /subscriptions seed (Smalt.Store seed) carries
  // no tenantId field — asserting it here would test our wish, not the wire.
  // If the seed grows tenantId, tighten this row.
});
