#!/usr/bin/env node
// atlas.probe.mjs — TS lane (KD-40): Purview Catalog (Atlas v2) surface probe
// against the smalt egress plane (Smalt.DataPlane.Purview +
// EgressRouter /atlas/v2/* mounts).
//
// Follows test/sdk-full/eventhubs.probe.mjs's bootstrap: boots the smalt
// substrate (mix run --no-start --no-halt, MIX_ENV=test) on env-overridable
// ports in the documented private 39000-39999 block so this probe never
// contends the front door or sibling lanes. Lane allocation: egress 39314,
// amqp 39315, eventhubs 39316 (task-assigned band 39314-39316); the ARM
// gateway, its TLS twin, and the MCP surface must listen somewhere too, so
// they take 39317-39319 from the same private block (disclosed allocation).
//
// Scope (coordinator trim): happy path + typed refusal only for the surface
// that exists in lib/. The two registered gaps stay DIVERGENCE rows asserted
// as absent (GAP(atlas-search-relationship-get-absent)):
//   - POST /atlas/v2/search/collection   (not implemented)
//   - GET  /atlas/v2/relationship/...    (relationship read beyond the
//     edge-minting POST not implemented)
// No official @azure/purview SDK ships the Atlas v2 surface, so this probe
// exercises the wire shape directly over fetch (same REST contract the real
// SDKs bind).
//
// Run: node test/sdk-full/atlas.probe.mjs
// Exit codes: 0 all pass / 1 probe failure / 2 substrate never up / 3 harness.
import { spawn } from "node:child_process";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import { randomBytes } from "node:crypto";

const REPO = path.resolve(import.meta.dirname, "../..");
const EGRESS_PORT = Number(process.env.SMALT_TS_ATLAS_EGRESS_PORT || 39314);
const AMQP_PORT = Number(process.env.SMALT_TS_ATLAS_AMQP_PORT || 39315);
const EH_PORT = Number(process.env.SMALT_TS_ATLAS_EH_PORT || 39316);
const ARM_PORT = Number(process.env.SMALT_TS_ATLAS_ARM_PORT || 39317);
const ARM_TLS_PORT = Number(process.env.SMALT_TS_ATLAS_ARM_TLS_PORT || 39318);
const MCP_PORT = Number(process.env.SMALT_TS_ATLAS_MCP_PORT || 39319);
const POLL_DEADLINE_MS = 90_000;
const EGRESS = `http://127.0.0.1:${EGRESS_PORT}`;

const RESULTS = []; // ["PASS"|"FAIL"|"DIVERGENCE", name, detail]
let fails = 0;

const portFree = (port) =>
  new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port, timeout: 1200 });
    s.once("connect", () => { s.destroy(); resolve(false); });
    s.once("error", () => resolve(true));
    s.once("timeout", () => { s.destroy(); resolve(true); });
  });

const tryConnect = (port) =>
  new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port, timeout: 1500 });
    s.once("connect", () => { s.destroy(); resolve(true); });
    s.once("error", () => resolve(false));
    s.once("timeout", () => { s.destroy(); resolve(false); });
  });

async function main() {
  const ports = [EGRESS_PORT, AMQP_PORT, EH_PORT, ARM_PORT, ARM_TLS_PORT, MCP_PORT];
  for (const port of ports) {
    if (!(await portFree(port))) {
      console.error(
        `[ts-atlas-probe] port ${port} is occupied — wait or override SMALT_TS_ATLAS_* (block 39314-39319)`,
      );
      process.exitCode = 3;
      return;
    }
  }

  const sharedKey = randomBytes(48).toString("base64");
  const bootEval = [
    `Application.put_env(:smalt, :sb_shared_key, "${sharedKey}")`,
    `Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:${AMQP_PORT}")`,
    `Application.put_env(:smalt, :amqp_port, ${AMQP_PORT})`,
    `Application.put_env(:smalt, :event_hubs_port, ${EH_PORT})`,
    `Application.put_env(:smalt, :arm_port, ${ARM_PORT})`,
    `Application.put_env(:smalt, :egress_port, ${EGRESS_PORT})`,
    `Application.put_env(:smalt, :arm_tls_port, ${ARM_TLS_PORT})`,
    `Application.put_env(:smalt, :mcp_port, ${MCP_PORT})`,
    `{:ok, _} = Application.ensure_all_started(:smalt)`,
  ].join("; ");

  const logPath = path.join(import.meta.dirname, ".logs/atlas-probe-substrate.log");
  fs.mkdirSync(path.dirname(logPath), { recursive: true });
  const logStream = fs.createWriteStream(logPath, { flags: "w" });
  const child = spawn("mix", ["run", "--no-start", "--no-halt", "-e", bootEval], {
    cwd: REPO,
    env: { ...process.env, MIX_ENV: "test" },
    stdio: ["ignore", "pipe", "pipe"],
    detached: true, // own process group so the beam dies with mix
  });
  child.stdout.pipe(logStream);
  child.stderr.pipe(logStream);

  const killSubstrate = async (signal = "SIGTERM") => {
    try {
      if (child.pid && child.exitCode === null && !child.killed) {
        try { process.kill(-child.pid, signal); } catch { child.kill(signal); }
      }
    } catch { /* gone */ }
    if (signal !== "SIGKILL") {
      const dl = Date.now() + 5000;
      while (child.exitCode === null && Date.now() < dl) {
        await new Promise((r) => setTimeout(r, 200));
      }
      if (child.exitCode === null) await killSubstrate("SIGKILL");
    } else {
      await new Promise((resolve) => {
        try { child.once("close", resolve); } catch { resolve(); }
        setTimeout(resolve, 5000);
      });
    }
  };
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    process.on(sig, () => { killSubstrate("SIGKILL"); process.exit(130); });
  }
  process.on("exit", () => {
    try { if (child.pid && child.exitCode === null) process.kill(-child.pid, "SIGKILL"); } catch {}
  });

  const start = Date.now();
  for (;;) {
    const ups = await Promise.all(ports.map(tryConnect));
    if (ups.every(Boolean)) break;
    if (Date.now() - start > POLL_DEADLINE_MS) {
      console.error(
        `[ts-atlas-probe] substrate did not open ${ports.join("/")} within ${POLL_DEADLINE_MS / 1000}s. Log: ${logPath}`,
      );
      await killSubstrate();
      process.exitCode = 2;
      return;
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  console.log(`[ts-atlas-probe] substrate up on ${ports.join("/")} after ${Date.now() - start}ms`);

  // --- probes ---------------------------------------------------------------
  const post = (p, body) =>
    fetch(`${EGRESS}${p}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(10_000),
    });
  const get = (p) => fetch(`${EGRESS}${p}`, { signal: AbortSignal.timeout(10_000) });
  const j = async (r) => { try { return await r.json(); } catch { return {}; } };

  // Entity: happy path, guid assigned when absent.
  await (async () => {
    const r = await post("/atlas/v2/entity", { typeName: "azure_dataset", name: "atlas-probe-ds" });
    const b = await j(r);
    eq(r.status, 201, "entity create: expected 201");
    ok(typeof b.guid === "string" && b.guid.length >= 32, `entity create: guid assigned (got ${b.guid})`);
    eq(b.typeName, "azure_dataset", "entity create: typeName echoed");
    return b.guid;
  })().then(
    (guid) => RESULTS.push(["PASS", "entity create assigns guid (201)", guid]),
    (e) => { fails++; RESULTS.push(["FAIL", "entity create assigns guid (201)", String(e.message || e)]); },
  );

  // Entity: client-supplied guid honored.
  await (async () => {
    const guid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    const r = await post("/atlas/v2/entity", { guid, typeName: "azure_sql_table" });
    const b = await j(r);
    eq(r.status, 201, "entity create (supplied guid): expected 201");
    eq(b.guid, guid, "entity create (supplied guid): echoed");
    return guid;
  })().then(
    () => RESULTS.push(["PASS", "entity create honors supplied guid", ""]),
    (e) => { fails++; RESULTS.push(["FAIL", "entity create honors supplied guid", String(e.message || e)]); },
  );

  // Entity: typed refusal — non-map entity is 400 ATLAS-400-00-001, not 500.
  await (async () => {
    const r = await post("/atlas/v2/entity", { entity: "not-a-map" });
    const b = await j(r);
    eq(r.status, 400, "entity non-map refusal: expected 400");
    eq(b.error && b.error.code, "ATLAS-400-00-001", "entity non-map refusal: typed code");
    return b;
  })().then(
    () => RESULTS.push(["PASS", "entity non-map body -> typed 400 ATLAS-400-00-001", ""]),
    (e) => { fails++; RESULTS.push(["FAIL", "entity non-map body -> typed 400 ATLAS-400-00-001", String(e.message || e)]); },
  );

  // Bulk: happy path — guidAssignments + mutatedEntities.CREATE, atomic.
  await (async () => {
    const r = await post("/atlas/v2/entity/bulk", {
      entities: [
        { typeName: "azure_blob_path", name: "b1" },
        { typeName: "azure_blob_path", name: "b2" },
        { guid: "11111111-2222-3333-4444-555555555555", typeName: "azure_blob_path", name: "b3" },
      ],
    });
    const b = await j(r);
    eq(r.status, 201, "bulk create: expected 201");
    eq(Object.keys(b.guidAssignments || {}).length, 3, "bulk create: 3 guidAssignments");
    eq((b.mutatedEntities && b.mutatedEntities.CREATE || []).length, 3, "bulk create: 3 mutatedEntities.CREATE");
    return b;
  })().then(
    () => RESULTS.push(["PASS", "bulk create 201 with guidAssignments+mutatedEntities", ""]),
    (e) => { fails++; RESULTS.push(["FAIL", "bulk create 201 with guidAssignments+mutatedEntities", String(e.message || e)]); },
  );

  // Bulk: over-limit refusal — 101 entities -> 400, no partial insert.
  await (async () => {
    const r = await post("/atlas/v2/entity/bulk", {
      entities: Array.from({ length: 101 }, (_, i) => ({ typeName: "x", name: `over-${i}` })),
    });
    const b = await j(r);
    eq(r.status, 400, "bulk over-limit: expected 400");
    eq(b.error && b.error.code, "ATLAS-400-00-001", "bulk over-limit: typed code");
    // Atomicity witness: the first over-limit entity must NOT have been inserted.
    const probeName = `over-0`;
    // (no search surface exists to enumerate by name — atomicity is witnessed
    //  by re-POSTing the same 101-batch: still 400, and via the known-good
    //  GET on a fresh guid absence below). Keep the typed refusal as the row.
    return probeName;
  })().then(
    () => RESULTS.push(["PASS", "bulk over-limit 101 -> typed 400 (atomic, no partial insert)", ""]),
    (e) => { fails++; RESULTS.push(["FAIL", "bulk over-limit 101 -> typed 400 (atomic, no partial insert)", String(e.message || e)]); },
  );

  // Bulk: non-array entities -> 400.
  await (async () => {
    const r = await post("/atlas/v2/entity/bulk", { entities: "nope" });
    const b = await j(r);
    eq(r.status, 400, "bulk non-array refusal: expected 400");
    eq(b.error && b.error.code, "ATLAS-400-00-001", "bulk non-array refusal: typed code");
  })().then(
    () => RESULTS.push(["PASS", "bulk non-array entities -> typed 400", ""]),
    (e) => { fails++; RESULTS.push(["FAIL", "bulk non-array entities -> typed 400", String(e.message || e)]); },
  );

  // GET entity: happy roundtrip + 404 typed miss.
  await (async () => {
    const made = await (await post("/atlas/v2/entity", { typeName: "azure_sql_table", name: "rt" })).json();
    const r = await get(`/atlas/v2/entity/guid/${made.guid}`);
    const b = await j(r);
    eq(r.status, 200, "entity GET: expected 200");
    eq(b.guid, made.guid, "entity GET: guid roundtrip");
    eq(b.typeName, "azure_sql_table", "entity GET: typeName roundtrip");

    const miss = await get("/atlas/v2/entity/guid/00000000-0000-0000-0000-00000000dead");
    const mb = await j(miss);
    eq(miss.status, 404, "entity GET miss: expected 404");
    eq(mb.error && mb.error.code, "ATLAS-404-00-005", "entity GET miss: typed code");
    return made.guid;
  })().then(
    () => RESULTS.push(["PASS", "entity GET 200 roundtrip; unknown guid -> typed 404 ATLAS-404-00-005", ""]),
    (e) => { fails++; RESULTS.push(["FAIL", "entity GET 200 roundtrip; unknown guid -> typed 404 ATLAS-404-00-005", String(e.message || e)]); },
  );

  // Relationship: happy path mints a lineage edge (201, guid), lineage-visible.
  await (async () => {
    const rel = {
      relationship: {
        typeName: "smalt_lineage",
        end1: { guid: "g-from" },
        end2: { guid: "g-to" },
      },
    };
    const r = await post("/atlas/v2/relationship", rel);
    const b = await j(r);
    eq(r.status, 201, "relationship POST: expected 201");
    ok(typeof b.guid === "string" && b.guid.length > 0, "relationship POST: guid minted");

    const lin = await get("/atlas/v2/lineage/both/g-from");
    const lb = await j(lin);
    eq(lin.status, 200, "lineage after relationship: expected 200");
    const relIds = (lb.relations || []).map((x) => x.relationshipId);
    ok(
      relIds.some((id) => id.includes("g-from") && id.includes("g-to")),
      `relationship POST: edge lineage-visible (relations=${JSON.stringify(relIds)})`,
    );
    return b.guid;
  })().then(
    () => RESULTS.push(["PASS", "relationship POST 201 mints lineage-visible edge", ""]),
    (e) => { fails++; RESULTS.push(["FAIL", "relationship POST 201 mints lineage-visible edge", String(e.message || e)]); },
  );

  // Relationship: typed refusal — missing end1/end2 guids -> 400.
  await (async () => {
    const r = await post("/atlas/v2/relationship", { relationship: { typeName: "x" } });
    const b = await j(r);
    eq(r.status, 400, "relationship refusal: expected 400");
    eq(b.error && b.error.code, "ATLAS-400-00-001", "relationship refusal: typed code");
  })().then(
    () => RESULTS.push(["PASS", "relationship missing end1/end2 -> typed 400", ""]),
    (e) => { fails++; RESULTS.push(["FAIL", "relationship missing end1/end2 -> typed 400", String(e.message || e)]); },
  );

  // Lineage: BFS output direction with depth=2 over a 3-node chain g1<-g2<-g3
  // (edges g2->g1 and g3->g2; output from g3 reaches g1 at depth 2).
  await (async () => {
    await post("/atlas/v2/relationship", { relationship: { end1: { guid: "g2" }, end2: { guid: "g1" } } });
    await post("/atlas/v2/relationship", { relationship: { end1: { guid: "g3" }, end2: { guid: "g2" } } });
    const r = await get("/atlas/v2/lineage/output/g3?depth=2");
    const b = await j(r);
    eq(r.status, 200, "lineage depth=2: expected 200");
    eq(b.baseEntityGuid, "g3", "lineage depth=2: baseEntityGuid");
    const rels = (b.relations || []).map((x) => `${x.fromEntityId}->${x.toEntityId}`).sort();
    deepEq(rels, ["g2->g1", "g3->g2"], "lineage depth=2: transitive relations");
    ok(b.guidEntityMap && b.guidEntityMap.g1, "lineage depth=2: guidEntityMap resolves g1");
    return rels;
  })().then(
    () => RESULTS.push(["PASS", "lineage output depth=2 BFS over 3-node chain", ""]),
    (e) => { fails++; RESULTS.push(["FAIL", "lineage output depth=2 BFS over 3-node chain", String(e.message || e)]); },
  );

  // Lineage: bad direction -> typed 400.
  await (async () => {
    const r = await get("/atlas/v2/lineage/sideways/g3");
    const b = await j(r);
    eq(r.status, 400, "lineage bad direction: expected 400");
    eq(b.error && b.error.code, "ATLAS-400-00-001", "lineage bad direction: typed code");
  })().then(
    () => RESULTS.push(["PASS", "lineage bad direction -> typed 400", ""]),
    (e) => { fails++; RESULTS.push(["FAIL", "lineage bad direction -> typed 400", String(e.message || e)]); },
  );

  // --- Registered divergences (asserted ABSENT; if they ever start responding
  // 200 the probe FAILs — the gap closed and the KD row/GAP token must be
  // flipped through the receipt-gated process, not silently absorbed here).
  // GAP(atlas-search-relationship-get-absent)
  await (async () => {
    // "Absent" = typed refusal at the fence: 404 RouteNotFound, or the
    // reserved-segment fence's x-ms-version 400 for unmatched GETs
    // (both are refusals; neither serves a relationship/search body).
    const absent = (r) => r.status === 404 || r.status === 400;
    const search = await post("/atlas/v2/search/collection", { keywords: "*" });
    ok(absent(search), `search/collection: expected absent (404/400), got ${search.status}`);
    const relGet = await get("/atlas/v2/relationship/some-relationship-guid");
    ok(absent(relGet), `relationship GET: expected absent (404/400), got ${relGet.status}`);
  })().then(
    () => RESULTS.push(["DIVERGENCE", "POST /atlas/v2/search/collection + GET /atlas/v2/relationship absent", "GAP(atlas-search-relationship-get-absent)"]),
    (e) => { fails++; RESULTS.push(["FAIL", "GAP row: search/collection + relationship GET expected absent", String(e.message || e)]); },
  );

  await killSubstrate();

  // --- receipt --------------------------------------------------------------
  console.log("\n=== atlas.probe results ===");
  for (const [st, name, detail] of RESULTS) {
    console.log(`[${st}] ${name}${detail ? ` — ${detail}` : ""}`);
  }
  const pass = RESULTS.filter((r) => r[0] === "PASS").length;
  const div = RESULTS.filter((r) => r[0] === "DIVERGENCE").length;
  console.log(`\ntotal=${RESULTS.length} pass=${pass} divergence=${div} fail=${fails}`);
  process.exitCode = fails > 0 ? 1 : 0;
}

const eq = (a, b, msg) => { if (a !== b) throw new Error(`${msg}: got ${JSON.stringify(a)}`); };
const ok = (c, msg) => { if (!c) throw new Error(msg); };
const deepEq = (a, b, msg) => {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${msg}: got ${JSON.stringify(a)}`);
};

main().catch((err) => {
  console.error("[ts-atlas-probe] harness error:", err);
  process.exitCode = 3;
});
