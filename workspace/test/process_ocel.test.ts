// OCEL reader court (node --test, Chicago-style: real fixture NDJSON on real
// fs, no mocks). Points SMALT_OCEL_DIR at a real temp dir before importing the
// module, then exercises the guard and the summary grouping on real files.
//
// Run: cd workspace && node --test test/process_ocel.test.ts

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

process.env.SMALT_OCEL_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "ocel-court-"));
const { guardOcelPath, readOcelSummary, OCEL_ROOT } = await import(
  "../lib/process/ocel.js"
);

const ROOT = OCEL_ROOT;

test("guard refuses paths outside the ocel root", () => {
  assert.throws(() => guardOcelPath("/etc/passwd"), /OCEL_READ_REFUSED/);
  assert.throws(
    () => guardOcelPath(path.join(ROOT, "..", "secrets.json")),
    /OCEL_READ_REFUSED/,
  );
});

test("guard admits files inside the ocel root", () => {
  const p = path.join(ROOT, "events.ndjson");
  assert.equal(guardOcelPath(p), path.resolve(p));
});

test("missing sink reads as available:false, never throws", () => {
  const s = readOcelSummary();
  assert.equal(s.available, false);
  assert.match(s.reason!, /no OCEL events/);
});

test("summary groups events, objects, traces from real fixture NDJSON", () => {
  const fragment = {
    "ocel:eventTypes": [{ name: "enclave.lifecycle.stage" }],
    "ocel:events": [
      {
        id: "ev-1",
        type: "enclave.lifecycle.stage",
        time: "2026-10-16T19:09:11.357125Z",
        attributes: { stage: "parse", verdict: "ok" },
        relationships: [
          { objectId: "enclave/main", qualifier: "enclave" },
          { objectId: "main.tf", qualifier: "fixture" },
        ],
      },
      {
        id: "ev-2",
        type: "enclave.lifecycle.stage",
        time: "2026-10-16T19:09:11.384496Z",
        attributes: {},
        relationships: [{ objectId: "enclave/main", qualifier: "enclave" }],
      },
    ],
    "ocel:objectTypes": [{ name: "enclave" }, { name: "fixture" }],
    "ocel:objects": [
      { id: "enclave/main", type: "enclave" },
      { id: "main.tf", type: "fixture" },
    ],
  };
  fs.writeFileSync(path.join(ROOT, "events.ndjson"), JSON.stringify(fragment) + "\n");
  fs.writeFileSync(
    path.join(ROOT, "powl_model.json"),
    JSON.stringify({ type: "dfg", trace_count: 1 }),
  );

  const s = readOcelSummary();
  assert.equal(s.available, true);
  assert.equal(s.totalEvents, 2);
  assert.equal(s.totalObjects, 2);
  assert.deepEqual(s.eventTypes, [{ name: "enclave.lifecycle.stage", count: 2 }]);
  assert.deepEqual(s.objectTypes.map((t) => t.name).sort(), ["enclave", "fixture"]);
  // recency-descending
  assert.equal(s.recentEvents[0].id, "ev-2");
  // longest trace first, grouped by objectId
  assert.equal(s.perObjectTraces[0].objectId, "enclave/main");
  assert.equal(s.perObjectTraces[0].trace.length, 2);
  assert.equal(s.perObjectTraces[1].objectId, "main.tf");
  assert.equal(s.perObjectTraces[1].objectType, "fixture");
  // powl model referenced when present
  assert.equal((s.powlModel as { type: string }).type, "dfg");
});

test("torn trailing line is tolerated, not fatal", () => {
  fs.appendFileSync(path.join(ROOT, "events.ndjson"), '{"ocel:events":[{"id":"to');
  const s = readOcelSummary();
  assert.equal(s.available, true);
  assert.equal(s.totalEvents, 2);
});
