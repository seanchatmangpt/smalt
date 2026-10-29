// W14-T4 — /api/sync/state sig-structure validation tests.
// Run: node --test workspace/app/api/sync/state/route.test.ts
// Native type stripping; the route imports lib/smalt relatively so this file
// can import it without a bundler alias. No mocks: validateEntry is exercised
// as the real exported function; live-POST legs talk to a REAL Next server at
// SYNC_TEST_BASE_URL over the REAL substrate. Loud SKIP when not provided.
import test from "node:test";
import assert from "node:assert/strict";
import { validateEntry } from "./route.ts";
import { assertLocalUrl } from "../../../../lib/smalt.ts";

function makeSig(): string {
  const raw = new Uint8Array(32);
  crypto.getRandomValues(raw);
  let bin = "";
  for (const b of raw) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

test("well-formed 43-char base64url sig + signedAt -> accepted", () => {
  const r = validateEntry(
    { id: "d1", data: { signedAt: "2026-10-20T00:00:00Z", v: 1 }, sig: makeSig() },
    0,
  );
  assert.equal(r.error, undefined);
  assert.equal(r.entry?.id, "d1");
  assert.equal(typeof r.entry?.sig, "string");
});

test("sig 'not-base64url' -> invalid_signature refusal row", () => {
  const r = validateEntry(
    { id: "d2", data: { signedAt: "2026-10-20T00:00:00Z" }, sig: "not-base64url" },
    0,
  );
  assert.equal(r.entry, undefined);
  assert.equal(r.error?.status, "error");
  assert.equal(r.error?.reason, "invalid_signature");
});

test("truncated 42-char sig -> invalid_signature", () => {
  const r = validateEntry(
    { id: "d3", data: { signedAt: "x" }, sig: makeSig().slice(0, 42) },
    0,
  );
  assert.equal(r.error?.reason, "invalid_signature");
});

test("padded 44-char sig -> invalid_signature (canonical unpadded only)", () => {
  const r = validateEntry(
    { id: "d4", data: { signedAt: "x" }, sig: makeSig() + "=" },
    0,
  );
  assert.equal(r.error?.reason, "invalid_signature");
});

test("well-formed sig but delta lacks signedAt -> invalid_signature", () => {
  const r = validateEntry({ id: "d5", data: { v: 1 }, sig: makeSig() }, 0);
  assert.equal(r.error?.reason, "invalid_signature");
});

test("non-string sig -> invalid_signature", () => {
  const r = validateEntry(
    { id: "d6", data: { signedAt: "x" }, sig: 12345 },
    0,
  );
  assert.equal(r.error?.reason, "invalid_signature");
});

test("no sig -> accepted (sig optional; LWW/CAS path unchanged)", () => {
  const r = validateEntry({ id: "d7", data: { v: 1 } }, 0);
  assert.equal(r.error, undefined);
  assert.equal(r.entry?.sig, undefined);
});

test("empty id still invalid_entry (sig check is additive)", () => {
  const r = validateEntry({ id: "", data: { signedAt: "x" }, sig: makeSig() }, 0);
  assert.equal(r.error?.reason, "invalid_entry");
});

// ---- live POST witness: real Next server + real substrate -------------------

function baseUrl(): string {
  return process.env.SYNC_TEST_BASE_URL ?? "";
}

test("live POST: sig present + well-formed -> applied", async (t) => {
  const base = baseUrl();
  if (base === "") {
    t.skip("SYNC_TEST_BASE_URL not set — live leg needs a real Next server");
    return;
  }
  const id = `w14t4-ok-${Date.now()}`;
  const url = assertLocalUrl(new URL("/api/sync/state", base).toString()).toString();
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify([
      {
        id,
        data: { signedAt: "2026-10-20T00:00:00Z", note: "w14-t4 well-formed sig" },
        sig: makeSig(),
      },
    ]),
  });
  assert.equal(res.status, 200);
  const j = await res.json() as { applied: Array<{ id: string }>; errors: Array<{ id: string; reason: string }> };
  assert.deepEqual(j.errors, []);
  assert.ok(j.applied.some((a) => a.id === id), JSON.stringify(j));
});

test("live POST: sig 'not-base64url' -> invalid_signature row, not applied", async (t) => {
  const base = baseUrl();
  if (base === "") {
    t.skip("SYNC_TEST_BASE_URL not set — live leg needs a real Next server");
    return;
  }
  const id = `w14t4-bad-${Date.now()}`;
  const url = assertLocalUrl(new URL("/api/sync/state", base).toString()).toString();
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify([
      {
        id,
        data: { signedAt: "2026-10-20T00:00:00Z", note: "w14-t4 ill-formed sig" },
        sig: "not-base64url",
      },
    ]),
  });
  assert.equal(res.status, 200);
  const j = await res.json() as { applied: Array<{ id: string }>; errors: Array<{ id: string; reason: string }> };
  assert.ok(
    j.errors.some((e) => e.id === id && e.reason === "invalid_signature"),
    JSON.stringify(j),
  );
  assert.ok(!j.applied.some((a) => a.id === id), JSON.stringify(j));
});
