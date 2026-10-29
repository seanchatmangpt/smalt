#!/usr/bin/env node
/**
 * Y4 sync-fault probe — real HTTP against the BFF boundary
 * (POST http://127.0.0.1:3100/api/sync/state), no mocks, no test framework.
 *
 * PRD Phase 4 fault verification:
 *   Leg 1  simulated disconnection: 8 concurrent clients POST deltas for the
 *          SAME doc with DIFFERENT payloads + the SAME baseVersion; exactly
 *          one applied, all others typed version_conflict; final server state
 *          matches the single winner (read back over real HTTP).
 *   Leg 2  offline staging: 5 local mutations staged client-side, then the
 *          full batch posted once -> all 5 applied in order; final server
 *          state is the last staged mutation.
 *   Leg 3  repeat run: identical batch re-posted -> typed conflict rows
 *          (version_conflict) and doc_not_found (404-class) per contract.
 *
 * No fixed sleeps: readiness is a bounded poll on a real observable.
 * All HTTP goes through the lib/smalt.ts air-gap surface (smaltFetch, which
 * runs assertLocalUrl on every request) — compiled to a temp dir and imported
 * the same way scripts/enclave-loop.mjs does it.
 *
 * Usage: node scripts/sync_fault_probe.mjs
 * Exit: 0 all legs PASS, 1 any FAIL.
 */

const BASE = process.env.Y4_BFF_BASE ?? 'http://127.0.0.1:3100';
const TENANT = process.env.SMALT_TENANT ?? 'smalt';

// ---- air-gap surface: compile lib/smalt.ts, import the REAL guards ----------
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const WS_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const TSC = path.join(WS_ROOT, 'node_modules', 'typescript', 'bin', 'tsc');
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'y4-probe-'));
fs.symlinkSync(path.join(WS_ROOT, 'node_modules'), path.join(tmpDir, 'node_modules'), 'dir');
const tsconfigPath = path.join(tmpDir, 'tsconfig.json');
fs.writeFileSync(
  tsconfigPath,
  JSON.stringify({
    compilerOptions: {
      outDir: path.join(tmpDir, 'js'),
      rootDir: WS_ROOT,
      module: 'commonjs',
      moduleResolution: 'node10',
      ignoreDeprecations: '6.0',
      target: 'es2022',
      esModuleInterop: true,
      skipLibCheck: true,
      lib: ['es2022', 'dom'],
      typeRoots: [path.join(WS_ROOT, 'node_modules', '@types')],
      types: ['node'],
    },
    include: [path.join(WS_ROOT, 'lib', 'smalt.ts')],
  })
);
const tsc = spawnSync(process.execPath, [TSC, '-p', tsconfigPath], { encoding: 'utf8' });
if (tsc.status !== 0) {
  console.error(`[y4-probe] FAIL lib/smalt.ts typecheck: ${tsc.stdout.trim()}`);
  process.exit(1);
}
const { smaltFetch } = await import(
  pathToFileURL(path.join(tmpDir, 'js', 'lib', 'smalt.js')).href
);

const BFF = BASE.replace(/\/$/, '');
const ARM = (process.env.SMALT_ARM_URL ?? 'http://127.0.0.1:9443').replace(/\/$/, '');
const COSMOS_BASE = (process.env.SMALT_EGRESS_URL ?? 'http://127.0.0.1:8443').replace(/\/$/, '');

const results = [];
function record(name, verdict, detail = '') {
  results.push({ name, verdict, detail });
  console.log(`[${verdict}] ${name}${detail ? ` — ${detail}` : ''}`);
}

// ---- bounded poll on real observables (no fixed sleeps) ----------------------

async function pollUntil(fn, { timeoutMs = 60_000, what } = {}) {
  const deadline = Date.now() + timeoutMs;
  let lastErr = 'never evaluated';
  while (Date.now() < deadline) {
    try {
      const ok = await fn();
      if (ok) return true;
      lastErr = 'predicate false';
    } catch (err) {
      lastErr = String(err).slice(0, 200);
    }
    await new Promise((r) => setImmediate(r));
  }
  throw new Error(`poll timeout (${what}): ${lastErr}`);
}

// ---- real HTTP helpers --------------------------------------------------------

async function postBatch(batch) {
  const res = await smaltFetch(BFF, '/api/sync/state', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(batch),
  });
  const json = await res.json().catch(() => null);
  return { status: res.status, json };
}

// Direct cosmos-face read on the data plane — the corruption check reads the
// stored doc itself, not the BFF's echoed row. Mints its own bearer from the
// loopback STS (any client_id/secret accepted in :enforce mode).
async function mintToken() {
  const res = await smaltFetch(ARM, `/${TENANT}/oauth2/v2.0/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'client_credentials',
      client_id: 'y4-sync-fault-probe',
      client_secret: 'local-loopback',
      scope: 'https://smalt.local/.default',
    }).toString(),
  });
  if (!res.ok) throw new Error(`sts_mint_failed_${res.status}`);
  const json = await res.json();
  if (typeof json.access_token !== 'string') throw new Error('sts_mint_no_token');
  return json.access_token;
}

let token = null;
async function readDocDirect(id) {
  if (token === null) token = await mintToken();
  const res = await smaltFetch(
    COSMOS_BASE,
    `/dbs/sync/colls/state/docs/${encodeURIComponent(id)}`,
    { headers: { authorization: `Bearer ${token}`, 'x-ms-version': '2018-12-31_preview', accept: 'application/json' } }
  );
  if (res.status !== 200) throw new Error(`direct_read_${res.status}`);
  return res.json();
}

// ---- Legs --------------------------------------------------------------------

async function leg1_simulated_disconnection() {
  const docId = `y4-fault-l1-${process.pid}-${Date.now()}`;
  const CLIENTS = 8;

  // Seed the doc once (no baseVersion -> create path), capture its etag.
  const seed = await postBatch([{ id: docId, data: { kind: 'y4-seed', rev: 0 } }]);
  if (seed.status !== 200 || seed.json.applied.length !== 1) {
    record('leg1-seed', 'FAIL', `status=${seed.status} json=${JSON.stringify(seed.json)}`);
    return;
  }
  const baseVersion = seed.json.applied[0].etag;
  if (typeof baseVersion !== 'string' || baseVersion.length === 0) {
    record('leg1-seed', 'FAIL', `no etag echoed: ${JSON.stringify(seed.json)}`);
    return;
  }
  record('leg1-seed', 'PASS', `doc=${docId} etag=${baseVersion}`);

  // 8 concurrent clients, same doc, same baseVersion, different payloads.
  const fires = Array.from({ length: CLIENTS }, (_, k) =>
    postBatch([{ id: docId, data: { kind: 'y4-l1', client: k, rev: 1 }, baseVersion }])
  );
  const settled = await Promise.all(fires);
  const outcomes = settled.map((r, k) => ({ client: k, status: r.status, json: r.json }));

  const wellFormed = outcomes.every(
    (o) => o.status === 200 && o.json && Array.isArray(o.json.applied) && Array.isArray(o.json.conflicts)
  );
  if (!wellFormed) {
    record('leg1-concurrent', 'FAIL', `non-200/malformed: ${JSON.stringify(outcomes.filter((o) => o.status !== 200 || !o.json))}`);
    return;
  }

  const appliedClients = outcomes.filter((o) => o.json.applied.length === 1);
  const conflictClients = outcomes.filter((o) =>
    o.json.conflicts.length === 1 &&
    o.json.conflicts[0].reason === 'version_conflict' &&
    o.json.applied.length === 0
  );

  if (appliedClients.length !== 1) {
    record('leg1-concurrent', 'FAIL', `exactly-one-applied violated: applied=${appliedClients.length} detail=${JSON.stringify(outcomes.map((o) => ({ c: o.client, a: o.json.applied.length, cf: o.json.conflicts })))}`);
    return;
  }
  if (conflictClients.length !== CLIENTS - 1) {
    record('leg1-concurrent', 'FAIL', `expected ${CLIENTS - 1} typed version_conflict clients, got ${conflictClients.length}: ${JSON.stringify(outcomes.map((o) => ({ c: o.client, a: o.json.applied, cf: o.json.conflicts })))}`);
    return;
  }
  const winnerClient = appliedClients[0].client;
  record('leg1-concurrent', 'PASS', `1 applied (client ${winnerClient}), ${CLIENTS - 1} version_conflict`);

  // Corruption check: the stored doc itself matches the single winner.
  const stored = await readDocDirect(docId);
  const winnerData = { kind: 'y4-l1', client: winnerClient, rev: 1 };
  const matches = stored.kind === winnerData.kind && stored.client === winnerData.client && stored.rev === winnerData.rev;
  record('leg1-final-state', matches ? 'PASS' : 'FAIL',
    matches ? `stored doc == winner payload (client ${winnerClient})` : `stored=${JSON.stringify(stored)} expected=${JSON.stringify(winnerData)}`);
}

async function leg2_offline_staging() {
  const docId = `y4-fault-l2-${process.pid}-${Date.now()}`;
  const N = 5;
  // Stage 5 mutations locally — nothing posted yet.
  const staged = Array.from({ length: N }, (_, i) => ({
    id: docId,
    data: { kind: 'y4-l2', step: i + 1, note: `offline mutation ${i + 1}` },
  }));
  // Post the full batch in one shot (server applies entries sequentially).
  const res = await postBatch(staged);
  if (res.status !== 200) {
    record('leg2-batch', 'FAIL', `status=${res.status} json=${JSON.stringify(res.json)}`);
    return;
  }
  const allApplied = res.json.applied.length === N && res.json.conflicts.length === 0 && res.json.errors.length === 0;
  record('leg2-batch', allApplied ? 'PASS' : 'FAIL',
    `applied=${res.json.applied.length} conflicts=${res.json.conflicts.length} errors=${JSON.stringify(res.json.errors)}`);
  if (!allApplied) return;

  const stored = await readDocDirect(docId);
  const last = staged[N - 1].data;
  const inOrder = stored.kind === last.kind && stored.step === N && stored.note === last.note;
  record('leg2-final-state', inOrder ? 'PASS' : 'FAIL',
    inOrder ? `final server state == staged mutation #${N}` : `stored=${JSON.stringify(stored)} expected=${JSON.stringify(last)}`);
}

async function leg3_repeat_run() {
  const docId = `y4-fault-l3-${process.pid}-${Date.now()}`;
  // Seed the doc, then run the IDENTICAL batch twice — both passes carry the
  // SAME baseVersion (the seed etag). Pass 1 is still current -> applied and
  // the etag rotates; pass 2's baseVersion is now stale -> typed conflict.
  const seed = await postBatch([{ id: docId, data: { kind: 'y4-l3', rev: 0 } }]);
  if (seed.status !== 200 || seed.json.applied.length !== 1) {
    record('leg3-seed', 'FAIL', `status=${seed.status} json=${JSON.stringify(seed.json)}`);
    return;
  }
  const etag = seed.json.applied[0].etag;
  const batch = [{ id: docId, data: { kind: 'y4-l3', rev: 42 }, baseVersion: etag }];

  const p1 = await postBatch(batch);
  if (p1.status !== 200 || p1.json.applied.length !== 1) {
    record('leg3-pass1', 'FAIL', `status=${p1.status} json=${JSON.stringify(p1.json)}`);
    return;
  }
  const newEtag = p1.json.applied[0].etag;
  record('leg3-pass1', 'PASS', `applied, etag rotated ${etag} -> ${newEtag}`);

  // Pass 2: byte-identical batch replayed — baseVersion now stale.
  const replay = await postBatch(batch);
  const conflictRow = replay.json?.conflicts?.[0];
  const isConflict = replay.status === 200 &&
    replay.json.applied.length === 0 &&
    conflictRow && conflictRow.reason === 'version_conflict' &&
    typeof conflictRow.currentEtag === 'string' && conflictRow.currentEtag !== etag;
  record('leg3-replay-conflict', isConflict ? 'PASS' : 'FAIL',
    isConflict ? `typed version_conflict, currentEtag=${conflictRow.currentEtag}` : `status=${replay.status} json=${JSON.stringify(replay.json)}`);

  // 404-class: baseVersion claimed against a doc that does not exist.
  const ghost = await postBatch([{ id: `y4-fault-l3-ghost-${process.pid}-${Date.now()}`, data: { kind: 'y4-l3' }, baseVersion: etag }]);
  const ghostRow = ghost.json?.conflicts?.[0];
  const isGhost = ghost.status === 200 && ghost.json.applied.length === 0 &&
    ghostRow && ghostRow.reason === 'doc_not_found';
  record('leg3-doc-not-found', isGhost ? 'PASS' : 'FAIL',
    isGhost ? 'typed doc_not_found' : `status=${ghost.status} json=${JSON.stringify(ghost.json)}`);
}

// ---- main ---------------------------------------------------------------------

// EXPLORE-1 W9: pollUntil resolves true or THROWS on timeout — it never
// returns false, so the old `if (!ready)` branch was dead and a timeout
// surfaced as an unhandled-rejection stack instead of the court's own typed
// verdict line. Catch the timeout, print the typed [FAIL], exit 1.
try {
  await pollUntil(async () => {
    const res = await smaltFetch(BFF, '/api/sync/state', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify([{ id: `y4-ready-${process.pid}`, data: { kind: 'y4-ready' } }]),
    });
    return res.status === 200;
  }, { timeoutMs: 90_000, what: 'BFF route readiness on :3100' });
} catch (e) {
  console.error(`[FAIL] BFF route never became ready (${String(e).slice(0, 200)})`);
  process.exit(1);
}
record('bff-ready', 'PASS', `${BFF}/api/sync/state`);

await leg1_simulated_disconnection();
await leg2_offline_staging();
await leg3_repeat_run();

const fails = results.filter((r) => r.verdict === 'FAIL');
console.log(`\n# SUMMARY: ${results.length - fails.length}/${results.length} PASS, ${fails.length} FAIL`);
if (fails.length > 0) {
  for (const f of fails) console.log(`# FAIL: ${f.name}: ${f.detail}`);
  process.exit(1);
}
