/**
 * Air-gap egress court (node --test, Chicago-style: real loopback server,
 * real fetch, real NextRequest — no mocks).
 *
 * Run: cd workspace && node --test test/airgap_egress.test.ts
 */

import test from "node:test";
import assert from "node:assert/strict";
import http from "node:http";

import {
  AirGapViolation,
  installAirGapFetch,
  drainAirGapAudit,
  AIRGAP_ALLOWED_PORTS,
} from "../src/lib/airgap-fetch.js";
import { middleware, airgapRedirectDecision } from "../middleware.js";
import { NextRequest } from "next/server.js";

/** Bind a real loopback server on the first free air-gap port (8443 → 9443 → 9444). */
async function startLoopback(): Promise<{ url: string; close: () => Promise<void> }> {
  const ports = [...AIRGAP_ALLOWED_PORTS].sort((a, b) => Number(a) - Number(b));
  for (const port of ports) {
    const attempt = await new Promise<{ server: http.Server; port: string } | null>((resolve) => {
      const server = http.createServer((_req, res) => {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ ok: true, port }));
      });
      server.once("error", () => resolve(null));
      server.listen(Number(port), "127.0.0.1", () => resolve({ server, port }));
    });
    if (attempt) {
      return {
        url: `http://127.0.0.1:${attempt.port}`,
        close: () => new Promise((res) => attempt.server.close(() => res())),
      };
    }
  }
  throw new Error(
    "[SKIP-candidate] no air-gap port free (8443/9443/9444 all EADDRINUSE) — court cannot run",
  );
}

test("allowed loopback fetch on an air-gap port passes through the wrapper", async () => {
  installAirGapFetch();
  const srv = await startLoopback();
  try {
    // Court exception: this test IS the air-gap probe — it must fire raw fetch
    // at the wrapper to prove the wrapper admits loopback and refuses egress.
    // eslint-disable-next-line no-restricted-syntax
    const res = await fetch(`${srv.url}/probe`);
    assert.equal(res.status, 200);
    const body = (await res.json()) as { ok: boolean; port: string };
    assert.equal(body.ok, true);
    assert.ok(AIRGAP_ALLOWED_PORTS.has(body.port));
    assert.deepEqual(drainAirGapAudit(), []);
  } finally {
    await srv.close();
  }
});

test("fetch to management.azure.com is aborted with typed AirGapViolation + audit row", async () => {
  installAirGapFetch();
  assert.rejects(
    // eslint-disable-next-line no-restricted-syntax -- court fires the raw fetch the guard must refuse
    async () => fetch("https://management.azure.com/subscriptions?api-version=2021-01-01"),
    (err: unknown) => {
      assert.ok(err instanceof AirGapViolation);
      assert.equal((err as AirGapViolation).host, "management.azure.com");
      assert.equal((err as AirGapViolation).port, "443");
      return true;
    },
  );
  const rows = drainAirGapAudit();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].host, "management.azure.com");
  assert.equal(rows[0].violation, "non-loopback-host");
  assert.match(rows[0].ts, /^\d{4}-/);
});

test("loopback on a NON air-gap port is refused (disallowed-port audit row)", async () => {
  installAirGapFetch();
  // eslint-disable-next-line no-restricted-syntax -- court fires the raw fetch the guard must refuse
  assert.rejects(async () => fetch("http://127.0.0.1:9545/mcp"), (err: unknown) => {
    assert.ok(err instanceof AirGapViolation);
    assert.equal((err as AirGapViolation).port, "9545");
    return true;
  });
  const rows = drainAirGapAudit();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].violation, "disallowed-port");
});

test("middleware decision core: loopback allows, azure + arbitrary hosts refuse", () => {
  assert.deepEqual(airgapRedirectDecision("http://127.0.0.1:9443/some/path"), { allow: true });
  const azure = airgapRedirectDecision("https://management.azure.com/subscriptions");
  assert.equal(azure.allow, false);
  if (!azure.allow) assert.match(azure.reason, /management\.azure\.com/);
  const evil = airgapRedirectDecision("https://evil.example/grab");
  assert.equal(evil.allow, false);
  if (!evil.allow) assert.match(evil.reason, /off-loopback/);
});

test("middleware blocks open-redirect to *.azure.com with 400 AirGapRedirectRefused", () => {
  const req = new NextRequest(
    "http://localhost:3000/api/v1/ingest?url=https%3A%2F%2Fmanagement.azure.com%2Fsubscriptions",
  );
  const res = middleware(req);
  assert.equal(res.status, 400);
  return res.json().then((body: { error: { code: string; param: string } }) => {
    assert.equal(body.error.code, "AirGapRedirectRefused");
    assert.equal(body.error.param, "url");
  });
});

test("middleware passes loopback redirect targets through (NextResponse.next)", () => {
  const req = new NextRequest(
    "http://localhost:3000/api/v1/ingest?url=http%3A%2F%2F127.0.0.1%3A9443%2Fok",
  );
  const res = middleware(req);
  assert.notEqual(res.status, 400);
});

test("middleware blocks arbitrary off-loopback redirect targets", () => {
  const req = new NextRequest(
    "http://localhost:3000/api/v1/ingest?redirect=https%3A%2F%2Fevil.example%2Fx",
  );
  const res = middleware(req);
  assert.equal(res.status, 400);
});
