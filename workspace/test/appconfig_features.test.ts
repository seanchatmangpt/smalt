/**
 * App Configuration client tests — lane 527 Agent 7 (v26.10.16).
 *
 * Three tiers, honest by construction:
 *  1. PURE — feature-flag parsing + client-side evaluation (no I/O).
 *  2. CONTRACT — a real in-test http server serving the Azure App
 *     Configuration wire contract (kv CRUD, ETag If-Match/If-None-Match,
 *     412/409/404 semantics, label filtering, feature-flag content type).
 *     Chicago school: real collaborators over loopback, real HTTP — no mock
 *     of owned code; the client runs for real against a real server.
 *  3. SUBSTRATE — live smalt emulator probes. The substrate has NO
 *     /appconfig plane (witnessed typed 404 RouteNotFound). These are
 *     SKIP-LOUD with that exact reason until the substrate route lands;
 *     a skip is a loud skip, never a faked pass.
 *
 * Run: node --test workspace/test/appconfig_features.test.ts
 * (Node >= 23.6 strips TS types natively.)
 */
import test from "node:test";
import assert from "node:assert/strict";
import * as http from "node:http";
import type { AddressInfo } from "node:net";

import {
  AppConfigClient,
  AppConfigError,
  FEATURE_FLAG_CONTENT_TYPE,
  evaluateFeatureFlag,
  isFeatureFlagContentType,
  parseFeatureFlag,
  type AppConfigSetting,
  type FeatureFlag,
} from "../lib/azure/appconfig.js";
import { smaltFetch } from "../lib/smalt.js";

const EGRESS = process.env.NEXT_PUBLIC_SMALT_EGRESS ?? "http://127.0.0.1:8443";

// ---------------------------------------------------------------------------
// Mock App Configuration contract server (real server, real loopback HTTP)
// ---------------------------------------------------------------------------

interface Row {
  key: string;
  label: string;
  value: string;
  contentType?: string;
  lastModified: string;
}

/** Minimal in-memory App Configuration service speaking the wire contract. */
function startContractServer(): Promise<{ base: string; close: () => Promise<void> }> {
  return new Promise((resolve) => {
    const rows = new Map<string, Row>(); // `${key}\n${label}` -> row
    const etagOf = (r: Row) => `"${r.key}|${r.label}|${r.value.length}|${r.lastModified}"`;

    const server = http.createServer((req, res) => {
      const u = new URL(req.url ?? "/", "http://127.0.0.1");
      const chunks: Buffer[] = [];
      req.on("data", (c) => chunks.push(c));
      req.on("end", () => {
        const body = Buffer.concat(chunks).toString();
        const respond = (status: number, payload: unknown) => {
          res.writeHead(status, { "content-type": "application/json" });
          res.end(JSON.stringify(payload));
        };
        const parsed = body ? (JSON.parse(body) as Record<string, unknown>) : {};
        const key = decodeURIComponent(u.pathname.replace(/^\/kv\/?/, ""));
        const label = u.searchParams.get("label") ?? "";

        // LIST /kv
        if (u.pathname === "/kv" && req.method === "GET") {
          const keyFilter = u.searchParams.get("key") ?? "";
          const labelFilter = u.searchParams.get("label");
          const items = [...rows.values()].filter(
            (r) =>
              (!keyFilter || r.key.startsWith(keyFilter)) &&
              (labelFilter === null || r.label === labelFilter),
          );
          return respond(200, { items });
        }
        if (!key) return respond(404, { detail: "missing key" });

        const k = `${key}\n${label}`;
        const existing = rows.get(k);

        // PUT /kv/{key}?label= — ETag conditional semantics per the contract.
        if (req.method === "PUT") {
          const ifMatch = req.headers["if-match"];
          const ifNoneMatch = req.headers["if-none-match"];
          if (ifMatch && ifMatch !== "*" && (!existing || ifMatch !== etagOf(existing))) {
            return respond(412, { detail: "etag mismatch" });
          }
          // Create-only (If-None-Match: *) on an existing kv is 412.
          if (ifNoneMatch === "*" && existing) return respond(412, { detail: "already exists" });
          // Unconditional overwrite of an existing kv is 409.
          if (!ifMatch && existing) return respond(409, { detail: "write conflict" });

          const row: Row = {
            key,
            label,
            value: String(parsed.value ?? ""),
            contentType: parsed.contentType ? String(parsed.contentType) : undefined,
            lastModified: new Date().toISOString(),
          };
          rows.set(k, row);
          return respond(200, { ...row, etag: etagOf(row) });
        }

        // DELETE /kv/{key}?label= — If-Match required; stale etag is 412.
        if (req.method === "DELETE") {
          if (!existing) return respond(404, { detail: "not found" });
          const ifMatch = req.headers["if-match"];
          if (ifMatch !== "*" && ifMatch !== etagOf(existing)) {
            return respond(412, { detail: "etag mismatch" });
          }
          rows.delete(k);
          return respond(204, {});
        }

        // GET /kv/{key}?label= — If-None-Match → 304 on match.
        if (req.method === "GET") {
          if (!existing) return respond(404, { detail: "not found" });
          const inm = req.headers["if-none-match"];
          if (inm && inm === etagOf(existing)) return respond(304, {});
          return respond(200, { ...existing, etag: etagOf(existing) });
        }

        return respond(405, { detail: "method not allowed" });
      });
    });
    server.listen(0, "127.0.0.1", () =>
      resolve({
        base: `http://127.0.0.1:${(server.address() as AddressInfo).port}`,
        close: () =>
          new Promise<void>((res, rej) =>
            server.close((err) => (err ? rej(err) : res())),
          ),
      }),
    );
  });
}

let base = "http://127.0.0.1:0";
let closeServer: () => Promise<void> = async () => {};

test.before(async () => {
  const srv = await startContractServer();
  base = srv.base;
  closeServer = srv.close;
});

test.after(async () => {
  await closeServer();
});

// ---------------------------------------------------------------------------
// Tier 1 — PURE: parsing + evaluation
// ---------------------------------------------------------------------------

const flagBody = (over: Partial<FeatureFlag> = {}): string =>
  JSON.stringify({
    id: "console.dark-mode",
    enabled: true,
    conditions: { client_filters: [] },
    ...over,
  });

test("parseFeatureFlag parses a valid flag with filters", () => {
  const f = parseFeatureFlag(flagBody({
    conditions: {
      client_filters: [{ name: "Microsoft.Percentage", parameters: { Value: 50 } }],
    },
  }));
  assert.equal(f.id, "console.dark-mode");
  assert.equal(f.enabled, true);
  assert.equal(f.conditions?.client_filters[0].name, "Microsoft.Percentage");
});

test("parseFeatureFlag rejects non-flag payloads loudly", () => {
  assert.throws(() => parseFeatureFlag('{"nope":true}'), /invalid feature-flag/);
  assert.throws(() => parseFeatureFlag(""), /empty feature-flag/);
  assert.throws(
    () => parseFeatureFlag('{"id":"x","enabled":true,"conditions":{"client_filters":7}}'),
    /client_filters/,
  );
});

test("isFeatureFlagContentType matches the Azure wire content type only", () => {
  assert.ok(isFeatureFlagContentType(FEATURE_FLAG_CONTENT_TYPE));
  assert.ok(isFeatureFlagContentType("application/vnd.microsoft.appconfig.kv+json;ctype-feature;charset=utf-8"));
  assert.equal(isFeatureFlagContentType("application/json"), false);
  assert.equal(isFeatureFlagContentType(undefined), false);
});

test("evaluate: enabled with no filters is true; disabled is false", () => {
  assert.equal(evaluateFeatureFlag(parseFeatureFlag(flagBody())), true);
  assert.equal(evaluateFeatureFlag(parseFeatureFlag(flagBody({ enabled: false }))), false);
});

test("evaluate: Percentage filter buckets deterministically on userId", () => {
  const mk = (pct: number) => parseFeatureFlag(flagBody({
    conditions: { client_filters: [{ name: "Microsoft.Percentage", parameters: { Value: pct } }] },
  }));
  const ctx = { userId: "user-a", hashOverride: 0.501 };
  assert.equal(evaluateFeatureFlag(mk(50), ctx), false); // 50.1 >= 50
  assert.equal(evaluateFeatureFlag(mk(51), ctx), true);   // 50.1 < 51
  // No userId + no override → empty-string hash, still deterministic.
  assert.equal(typeof evaluateFeatureFlag(mk(100)), "boolean");
});

test("evaluate: TimeWindow filter honors Start/End", () => {
  const mk = (start: string | undefined, end: string | undefined) => parseFeatureFlag(flagBody({
    conditions: {
      client_filters: [{ name: "Microsoft.TimeWindow", parameters: { Start: start, End: end } }],
    },
  }));
  const now = new Date("2026-10-16T12:00:00Z");
  assert.equal(evaluateFeatureFlag(mk(undefined, undefined), { now }), true);
  assert.equal(evaluateFeatureFlag(mk("2026-10-01T00:00:00Z", "2026-10-15T00:00:00Z"), { now }), false);
  assert.equal(evaluateFeatureFlag(mk("2026-10-16T00:00:00Z", "2026-10-17T00:00:00Z"), { now }), true);
  assert.equal(evaluateFeatureFlag(mk("2026-10-17T00:00:00Z", undefined), { now }), false);
});

test("evaluate: Targeting filter matches audience users", () => {
  const mk = (users: string[]) => parseFeatureFlag(flagBody({
    conditions: {
      client_filters: [{ name: "Microsoft.Targeting", parameters: { Audience: { Users: users } } },
      ],
    },
  }));
  assert.equal(evaluateFeatureFlag(mk(["sean@example.com"]), { userId: "sean@example.com" }), true);
  assert.equal(evaluateFeatureFlag(mk(["other@example.com"]), { userId: "sean@example.com" }), false);
  assert.equal(evaluateFeatureFlag(mk(["a"]), {}), false); // no userId → false
});

test("evaluate: unknown filter is fail-closed false; Any/All requirement types", () => {
  const unknown = parseFeatureFlag(flagBody({
    conditions: { client_filters: [{ name: "Microsoft.CrystalBall" }] },
  }));
  assert.equal(evaluateFeatureFlag(unknown), false);

  const anyMix = parseFeatureFlag(flagBody({
    conditions: {
      requirement_type: "Any",
      client_filters: [{ name: "Microsoft.CrystalBall" }, { name: "AlwaysOn" }],
    },
  }));
  assert.equal(evaluateFeatureFlag(anyMix), true); // Any: AlwaysOn passes
  const allMix = parseFeatureFlag(flagBody({
    conditions: {
      requirement_type: "All",
      client_filters: [{ name: "AlwaysOn" }, { name: "Microsoft.CrystalBall" }],
    },
  }));
  assert.equal(evaluateFeatureFlag(allMix), false); // All: unknown kills it
});

// ---------------------------------------------------------------------------
// Tier 2 — CONTRACT: client against the real in-test contract server
// ---------------------------------------------------------------------------

test("contract: put creates, get round-trips, etag present", async () => {
  const c = new AppConfigClient({ base });
  const s = await c.put("app:color", "blue");
  assert.ok(s.etag);
  const got = await c.get("app:color");
  assert.equal(got?.value, "blue");
  assert.equal(got?.etag, s.etag);
});

test("contract: unconditional overwrite of existing kv is 409", async () => {
  const c = new AppConfigClient({ base });
  await c.put("app:conflict", "v1");
  await assert.rejects(() => c.put("app:conflict", "v2"), (e: unknown) => {
    const err = e as AppConfigError;
    return err instanceof AppConfigError && err.status === 409;
  });
});

test("contract: If-Match CAS update succeeds; stale etag is 412", async () => {
  const c = new AppConfigClient({ base });
  const s1 = await c.put("app:cas", "v1");
  const s2 = await c.put("app:cas", "v2", { ifMatch: s1.etag });
  assert.equal(s2.value, "v2");
  await assert.rejects(
    () => c.put("app:cas", "v3", { ifMatch: s1.etag }),
    (e: unknown) => (e as AppConfigError).status === 412,
  );
});

test("contract: create-only If-None-Match:* refuses duplicates with 412", async () => {
  const c = new AppConfigClient({ base });
  await c.putFeatureFlag("ff:unique", { id: "ff:unique", enabled: true, conditions: { client_filters: [] } });
  await assert.rejects(
    () => c.put("ff:unique", "x", { ifNoneMatch: "*" }),
    (e: unknown) => (e as AppConfigError).status === 412,
  );
});

test("contract: labels isolate values; list filters by key prefix + label", async () => {
  const c = new AppConfigClient({ base });
  await c.put("app:env", "dev", { label: "dev" });
  await c.put("app:env", "prod", { label: "prod" });
  assert.equal((await c.get("app:env", { label: "dev" }))?.value, "dev");
  assert.equal((await c.get("app:env", { label: "prod" }))?.value, "prod");
  const items = await c.list({ key: "app:env", label: "dev" });
  assert.equal(items.length, 1);
  assert.equal(items[0].value, "dev");
});

test("contract: feature flags ride the wire content type and parse back", async () => {
  const c = new AppConfigClient({ base });
  const flag: FeatureFlag = {
    id: "console.beta",
    enabled: true,
    conditions: { client_filters: [{ name: "Microsoft.Percentage", parameters: { Value: 10 } }] },
  };
  const s = await c.putFeatureFlag("ff:beta", flag);
  assert.ok(isFeatureFlagContentType(s.contentType));
  const parsed = await c.getFeatureFlag("ff:beta");
  assert.equal(parsed?.id, "console.beta");
  // A non-flag kv must not parse as a flag.
  await c.put("not:a:flag", "plain", { contentType: "text/plain" });
  await assert.rejects(() => c.getFeatureFlag("not:a:flag"), /invalid feature-flag/);
});

test("contract: watchSentinel fires on etag change and is stoppable", async () => {
  const c = new AppConfigClient({ base });
  const s0 = await c.put("sentinel:version", "1");
  const events: (AppConfigSetting | null)[] = [];
  let hits = 0;
  const stop = c.watchSentinel("sentinel:version", (s) => {
    hits++;
    events.push(s);
  }, { pollMs: 25 });
  // Force an etag change.
  await c.put("sentinel:version", "2", { ifMatch: s0.etag });
  await new Promise((r) => setTimeout(r, 120));
  stop();
  assert.ok(hits >= 1, `expected at least one fire, got ${hits}`);
  assert.ok(events.some((e) => e?.value === "2"));
});

test("contract: DELETE with If-Match removes; 404 delete is idempotent", async () => {
  const c = new AppConfigClient({ base });
  await c.put("app:doomed", "x");
  await c.del("app:doomed");
  assert.equal(await c.get("app:doomed"), null);
  await c.del("app:doomed"); // idempotent
});

// ---------------------------------------------------------------------------
// Tier 3 — SUBSTRATE (SKIP-LOUD until the /appconfig route lands)
// ---------------------------------------------------------------------------

test("substrate: typed RouteNotFound for GET /kv (gap witness)", async (t) => {
  let code = 0;
  let body = "";
  try {
    const res = await smaltFetch(EGRESS, "/kv?api-version=1.0", {
      signal: AbortSignal.timeout(3_000),
    });
    code = res.status;
    body = (await res.json().catch(() => ({}))).error?.code ?? "";
  } catch (e) {
    t.skip(`substrate unreachable on ${EGRESS}: ${String(e)}`);
    return;
  }
  if (code === 401) {
    t.skip(`SKIP-LOUD substrate-pending: smalt enforce-mode auth gates the egress plane tokenless (401); the authed surface has no App Configuration routes — authed GET /appconfig + /kv witnessed 404 {"error":{"code":"RouteNotFound"}} (see sdk-results/appconfig-console-gap.md)`);
    return;
  }
  if (code === 404 && body === "RouteNotFound") {
    t.skip(`SKIP-LOUD substrate-pending: smalt has no App Configuration plane — GET ${EGRESS}/kv -> 404 {"error":{"code":"RouteNotFound"}} (registered gap, appconfig-console-gap.md)`);
    return;
  }
  // The route landed — run the real CRUD probe.
  const c = new AppConfigClient({ base: EGRESS });
  await c.put("lane527:probe", "hello");
  assert.equal((await c.get("lane527:probe"))?.value, "hello");
  await c.del("lane527:probe");
});
