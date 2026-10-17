/**
 * Finops avoided-spend calculator court (Agent 14 lane).
 *
 * Pure tests — no substrate, no I/O. Run:
 *   T=$(mktemp -d) && cd workspace && node_modules/.bin/tsc \
 *     --outDir "$T" --rootDir . --module commonjs --moduleResolution node10 \
 *     --target es2022 --esModuleInterop --skipLibCheck --types node \
 *     test/finops_report.test.ts lib/finops/calculator.ts \
 *     && node --test "$T/test/finops_report.test.js"
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';

import {
  computeAvoidedSpend,
  FinopsError,
  RETAIL_TARIFFS,
} from '../lib/finops/calculator';
import type { RunManifest } from '../lib/finops/calculator';

// NFR-3 composite fixture manifest: one composite cycle = full 6-type surface,
// 1 RG + 3 storage + 2 KV + 1 cosmos + 2 EH + 1 SB, one wall-clock hour.
const NFR3_MANIFEST: RunManifest = {
  resources: [
    { type: 'resource_group', count: 1 },
    { type: 'storage_account', count: 3 },
    { type: 'key_vault', count: 2 },
    { type: 'cosmos_serverless', count: 1 },
    { type: 'eventhub_standard', count: 2 },
    { type: 'servicebus_standard', count: 1 },
  ],
  cycles: 500,
  durations_ms: 3_600_000,
};

test('NFR-3: 500 composite cycles produce the deterministic golden total', () => {
  const r = computeAvoidedSpend(NFR3_MANIFEST);
  // Golden number: computed independently by hand from the tariff table
  // (per-cycle = 3*(0.02/730+0.05) + 2*0.03 + (0.25/730+0.25) + 2*0.03 + 0.05,
  //  avoidedHours = 1, total = perCycle * 500).
  // Hand-derived: perCycle = 3*(0.02/730+0.05) + 2*0.03 + (0.25/730+0.25)
  //               + 2*0.03 + 1*0.05 = 0.5704246575342466 USD, hours=1,
  //               total = perCycle * 500 = 285.2123287671233 USD.
  assert.equal(
    r.totalUsd.toPrecision(12),
    (285.2123287671233).toPrecision(12),
  );
  assert.equal(r.perCycleUsd.toPrecision(12), (0.5704246575342466).toPrecision(12));
  assert.equal(r.avoidedHours, 1);
});

test('NFR-3: result is deterministic across repeated calls', () => {
  const a = computeAvoidedSpend(NFR3_MANIFEST);
  const b = computeAvoidedSpend(NFR3_MANIFEST);
  assert.equal(a.totalUsd, b.totalUsd);
  assert.equal(a.receipt.digest, b.receipt.digest);
});

test('zero cycles -> $0 avoided spend', () => {
  const r = computeAvoidedSpend({ ...NFR3_MANIFEST, cycles: 0 });
  assert.equal(r.totalUsd, 0);
});

test('zero durations_ms -> unit charges only, no hourly component', () => {
  // With 0 avoided hours the hourly components vanish but once-per-cycle unit
  // charges remain: 500 * (3*0.05 + 2*0.03 + 0.25 + 2*0 + 0) = 500 * 0.46.
  const r = computeAvoidedSpend({ ...NFR3_MANIFEST, durations_ms: 0 });
  assert.equal(r.totalUsd, 230);
});

test('unknown resource type -> typed FinopsError UNKNOWN_RESOURCE_TYPE', () => {
  assert.throws(
    () =>
      computeAvoidedSpend({
        resources: [{ type: 'quantum_lattice' as never, count: 1 }],
        cycles: 1,
        durations_ms: 1_000,
      }),
    (err: unknown) => {
      assert.ok(err instanceof FinopsError);
      assert.equal((err as FinopsError).code, 'UNKNOWN_RESOURCE_TYPE');
      return true;
    },
  );
});

test('negative cycles -> typed FinopsError INVALID_CYCLES', () => {
  assert.throws(
    () => computeAvoidedSpend({ ...NFR3_MANIFEST, cycles: -1 }),
    (err: unknown) => {
      assert.ok(err instanceof FinopsError);
      assert.equal((err as FinopsError).code, 'INVALID_CYCLES');
      return true;
    },
  );
});

test('PQC receipt: SHA-256 digest over canonical inputs, honest PQC_NOT_PROVISIONED', () => {
  const r = computeAvoidedSpend(NFR3_MANIFEST);
  assert.equal(r.receipt.algorithm, 'SHA-256');
  assert.equal(r.receipt.pqc_status, 'PQC_NOT_PROVISIONED');
  assert.match(r.receipt.digest, /^[0-9a-f]{64}$/);
  // Digest is verifiable: sha256 over the key-sorted canonical JSON.
  const expected = createHash('sha256')
    .update(
      JSON.stringify({
        cycles: NFR3_MANIFEST.cycles,
        durations_ms: NFR3_MANIFEST.durations_ms,
        resources: NFR3_MANIFEST.resources.map((res) => ({
          count: res.count,
          type: res.type,
        })),
      }),
    )
    .digest('hex');
  assert.equal(r.receipt.digest, expected);
});

test('receipt digest is key-order independent', () => {
  const reordered: RunManifest = {
    durations_ms: NFR3_MANIFEST.durations_ms,
    cycles: NFR3_MANIFEST.cycles,
    resources: NFR3_MANIFEST.resources.map((res) => ({
      count: res.count,
      type: res.type,
    })),
  };
  // Same manifest with keys written in a different order re-derives the same
  // digest because canonicalization sorts object keys (array order preserved).
  const a = computeAvoidedSpend(NFR3_MANIFEST).receipt.digest;
  const b = computeAvoidedSpend(reordered).receipt.digest;
  assert.equal(a, b);
});

test('tariff table cites approximate published Azure retail for every type', () => {
  for (const [type, t] of Object.entries(RETAIL_TARIFFS)) {
    assert.ok(t.note.length > 0, `${type} missing tariff note`);
    assert.ok(t.usdPerHour >= 0 && t.usdPerUnit >= 0, `${type} negative rate`);
  }
});
