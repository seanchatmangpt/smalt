// BK-ASSERTG — BK-TOPO WI-1 court: env-typed allowlist (SMALT_ALLOWED_HOSTS).
//
// Chicago court, no mocks: the real lib/smalt.ts assertLocalUrl and the real
// lib/caller-gate.ts assertLoopbackCaller are exercised directly with the
// env var set/unset in-process.
//
// Run: cd workspace && node --test test/smalt_allowlist.test.ts
//
// Legs:
//   env unset/empty  -> loopback admitted, non-loopback refused
//                       (byte-identical default posture; Air-gap violation)
//   env set          -> named host admitted (witness host:
//                       smalt-console.default.svc.cluster.local — the kind
//                       console pod's service DNS), other named hosts refused
//   caller-gate      -> same posture on Host header + Origin; gate never
//                       disabled (non-named host still 403 with env set)
import test from "node:test";
import assert from "node:assert/strict";

import { assertLocalUrl, allowedHosts } from "../lib/smalt.ts";
import { assertLoopbackCaller } from "../lib/caller-gate.ts";

const WITNESS_HOST = "smalt-console.default.svc.cluster.local";

function withEnv<T>(value: string | undefined, fn: () => T): T {
  const had = "SMALT_ALLOWED_HOSTS" in process.env;
  const prev = process.env.SMALT_ALLOWED_HOSTS;
  if (value === undefined) delete process.env.SMALT_ALLOWED_HOSTS;
  else process.env.SMALT_ALLOWED_HOSTS = value;
  try {
    return fn();
  } finally {
    if (had) process.env.SMALT_ALLOWED_HOSTS = prev!;
    else delete process.env.SMALT_ALLOWED_HOSTS;
  }
}

test("env unset -> loopback admitted (byte-identical default)", () => {
  withEnv(undefined, () => {
    for (const h of ["http://127.0.0.1:9443/x", "http://localhost:8443/y", "http://[::1]:9443/"]) {
      const u = assertLocalUrl(h);
      assert.ok(u, `loopback ${h} admitted`);
    }
    assert.deepEqual(allowedHosts(), []);
  });
});

test("env unset -> non-loopback refused with Air-gap violation", () => {
  withEnv(undefined, () => {
    assert.throws(
      () => assertLocalUrl(`http://${WITNESS_HOST}:9443/`),
      /Air-gap violation/,
      "named host must be refused when env unset (non-vacuity)"
    );
  });
});

test("env empty string -> loopback-only (byte-identical default)", () => {
  withEnv("", () => {
    assertLocalUrl("http://127.0.0.1:9443/");
    assert.throws(() => assertLocalUrl(`http://${WITNESS_HOST}:9443/`), /Air-gap violation/);
  });
});

test("env whitespace-only -> loopback-only", () => {
  withEnv("  ", () => {
    assert.throws(() => assertLocalUrl(`http://${WITNESS_HOST}:9443/`), /Air-gap violation/);
  });
});

test("env set -> witness kind-console service DNS admitted", () => {
  withEnv(WITNESS_HOST, () => {
    const u = assertLocalUrl(`http://${WITNESS_HOST}:9443/arm/locations`);
    assert.equal(u.hostname, WITNESS_HOST);
  });
});

test("env set -> non-named host still refused (no wildcard egress)", () => {
  withEnv(WITNESS_HOST, () => {
    assert.throws(
      () => assertLocalUrl("http://evil.example.com:9443/"),
      /Air-gap violation/
    );
    assert.throws(
      // subdomain of an allowed host is NOT implied
      () => assertLocalUrl(`http://x.${WITNESS_HOST}/`),
      /Air-gap violation/
    );
  });
});

test("env set -> comma list parsed, whitespace + case tolerated", () => {
  withEnv(` ${WITNESS_HOST} , SMALT-DATA.default.svc.cluster.local ,`, () => {
    assert.deepEqual(allowedHosts(), [WITNESS_HOST, "smalt-data.default.svc.cluster.local"]);
    assertLocalUrl(`http://SMALT-DATA.default.svc.cluster.local:8443/`);
  });
});

test("caller-gate env set -> allowed Host header proceeds", () => {
  withEnv(WITNESS_HOST, () => {
    const res = assertLoopbackCaller(
      new Request(`http://${WITNESS_HOST}:3100/api/sync/state`, {
        headers: { host: `${WITNESS_HOST}:3100` },
      })
    );
    assert.equal(res, null);
  });
});

test("caller-gate env set -> allowed Origin proceeds, non-named Host 403", async () => {
  withEnv(WITNESS_HOST, async () => {
    const res = assertLoopbackCaller(
      new Request(`http://${WITNESS_HOST}:3100/`, {
        headers: {
          host: `${WITNESS_HOST}:3100`,
          origin: `http://${WITNESS_HOST}:3000`,
        },
      })
    );
    assert.equal(res, null);
    const refused = assertLoopbackCaller(
      new Request("http://other.default.svc.cluster.local/", {
        headers: { host: "other.default.svc.cluster.local" },
      })
    );
    assert.ok(refused);
    assert.equal(refused.status, 403);
    const body = (await refused.json()) as { error: string };
    assert.equal(body.error, "sync_state_non_loopback");
  });
});

test("caller-gate env unset -> non-loopback Host still 403 (gate never disabled)", () => {
  withEnv(undefined, () => {
    const res = assertLoopbackCaller(
      new Request(`http://${WITNESS_HOST}/`, { headers: { host: WITNESS_HOST } })
    );
    assert.ok(res);
    assert.equal(res.status, 403);
  });
});
