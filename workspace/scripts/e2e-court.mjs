#!/usr/bin/env node
/**
 * Workspace E2E court (lane WS-12) — plain node, no test framework.
 *
 * Verdict vocabulary: PASS / FAIL / SKIP (skip states what and why, never
 * reads as a pass). Exit code: 0 only when zero FAILs.
 *
 * Legs:
 *   1. unit-import: compile lib/ with tsc to a temp outDir, dynamic-import
 *      every module, then assert:
 *        - ETF round-trip on representative terms
 *        - CRC-16/CCITT-FALSE check vector 0x29B1
 *        - Bellman determinism (two identical runs)
 *        - JCS canonical-JSON key ordering
 *        - verb-gate refuses a mutation, passes a read
 *        - attestation valid / tampered / unsupported trio
 *   2. composition smoke: panel components — node cannot execute DOM
 *      rendering, so rendering is honestly SKIPped; the component tree is
 *      witnessed at the type layer (tsc --noEmit) instead.
 *   3. optional live leg: ARM read-only probe when a smalt substrate is
 *      already listening; SKIP otherwise.
 */

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const WS_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const LIB = path.join(WS_ROOT, 'lib');
const COMPONENTS = path.join(WS_ROOT, 'components');
const APP = path.join(WS_ROOT, 'app');
const TSC = path.join(WS_ROOT, 'node_modules', 'typescript', 'bin', 'tsc');

const results = [];
function record(name, verdict, detail = '') {
  results.push({ name, verdict, detail });
  console.log(`[${verdict}] ${name}${detail ? ` — ${detail}` : ''}`);
}

// ---------------------------------------------------------------------------
// Leg 1a: compile lib/ to a temp outDir
// ---------------------------------------------------------------------------

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ws12-court-'));
const outDir = path.join(tmp, 'lib-js');
console.log(`# court outDir: ${outDir}`);
// Compiled JS lives outside WS_ROOT, so node's node_modules walk-up would
// never find @azure/* — link the workspace's node_modules into the tmp root.
fs.symlinkSync(path.join(WS_ROOT, 'node_modules'), path.join(tmp, 'node_modules'), 'dir');

// TS6 rejects CLI file globs + deprecated moduleResolution, so drive tsc
// through a generated tsconfig in the temp dir.
const tsconfigLib = {
  compilerOptions: {
    outDir: outDir,
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
    noEmitOnError: false,
  },
  include: [path.join(LIB, '**', '*.ts')],
};
const libTsconfigPath = path.join(tmp, 'tsconfig.lib.json');
fs.writeFileSync(libTsconfigPath, JSON.stringify(tsconfigLib, null, 2));
const tsc = spawnSync(process.execPath, [TSC, '-p', libTsconfigPath], { encoding: 'utf8' });
const tscOk = tsc.status === 0;
if (!tscOk) {
  // tsc emits JS even with type errors (noEmitOnError is off by default) —
  // record the diagnostics, then let each runtime check witness its own side.
  record('lib typecheck', 'FAIL', tsc.stdout.trim().split('\n').slice(0, 20).join(' | '));
} else {
  record('lib typecheck', 'PASS', 'tsc clean over lib/**');
}

const jsPath = (rel) => pathToFileURL(path.join(outDir, 'lib', rel)).href;

async function importLib(rel) {
  return import(jsPath(rel));
}

// ---------------------------------------------------------------------------
// Leg 1b: dynamic-import sweep over every lib module
// ---------------------------------------------------------------------------

const libModules = [];
(function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p);
    else if (e.name.endsWith('.ts')) libModules.push(path.relative(LIB, p));
  }
})(LIB);

for (const rel of libModules.sort()) {
  const jsRel = rel.replace(/\.ts$/, '.js');
  try {
    const mod = await importLib(jsRel);
    const n = Object.keys(mod).length;
    record(`import ${rel}`, 'PASS', `${n} export(s)`);
  } catch (e) {
    record(`import ${rel}`, 'FAIL', String(e.message).slice(0, 200));
  }
}

// ---------------------------------------------------------------------------
// Targeted checks (each isolated; an import failure fails only its own check)
// ---------------------------------------------------------------------------

// --- CRC-16/CCITT-FALSE check vector ---------------------------------------
try {
  const gw = await importLib('serial/gateway.js');
  const vector = gw.crc16CcittFalse(new TextEncoder().encode('123456789'));
  const selfTest = gw.crc16SelfTest();
  if (vector === 0x29b1 && selfTest === true) {
    record('crc16 vector 0x29B1', 'PASS', `crc16CcittFalse("123456789") = 0x${vector.toString(16).toUpperCase()}`);
  } else {
    record('crc16 vector 0x29B1', 'FAIL', `got 0x${vector.toString(16)}, selfTest=${selfTest}`);
  }
} catch (e) {
  record('crc16 vector 0x29B1', 'FAIL', `gateway import: ${e.message}`);
}

// --- ETF round-trip on representative terms ---------------------------------
try {
  const etf = await importLib('atomvm/etf.js');
  const { etfEncode, etfDecode, atom } = etf;
  const terms = [
    42,
    -7,
    0,
    255,
    256,
    -2000000000,
    2n ** 64n,
    new TextEncoder().encode('smalt sovereign'),
    atom('ok'),
    atom(''),
    { list: [1, 2, 3] },
    { list: [] },
    { elements: [atom('ok'), 1, new TextEncoder().encode('b')], },
    {
      map: [
        [atom('a'), 1],
        [new TextEncoder().encode('k'), { list: [atom('true'), 999999n] }],
      ],
    },
    { list: [{ elements: [{ map: [[1, { list: [] }]] }] }] },
  ];
  let roundTripped = 0;
  for (const t of terms) {
    const back = etfDecode(etfEncode(t));
    const same = etfDeepEqual(back, t);
    if (!same) {
      record('etf round-trip', 'FAIL', `term mismatch: ${termRepr(t)} -> ${termRepr(back)}`);
      throw new Error('mismatch');
    }
    roundTripped++;
  }
  record('etf round-trip', 'PASS', `${roundTripped}/${terms.length} representative terms (int/bigint/binary/atom/list/tuple/map)`);
} catch (e) {
  if (!String(e.message).includes('mismatch')) {
    record('etf round-trip', 'FAIL', `etf import/encode/decode: ${String(e.message).slice(0, 200)}`);
  }
}

function etfDeepEqual(a, b) {
  if (a === b) return true;
  if (typeof a === 'bigint' || typeof b === 'bigint') {
    return typeof a === typeof b && a === b;
  }
  if (a instanceof Uint8Array && b instanceof Uint8Array) {
    return a.length === b.length && a.every((v, i) => v === b[i]);
  }
  if (typeof a !== 'object' || typeof b !== 'object' || a === null || b === null) {
    return false;
  }
  if ('atom' in a && 'atom' in b) return a.atom === b.atom;
  if ('elements' in a && 'elements' in b) {
    return a.elements.length === b.elements.length &&
      a.elements.every((v, i) => etfDeepEqual(v, b.elements[i]));
  }
  if ('list' in a && 'list' in b) {
    return a.list.length === b.list.length &&
      a.list.every((v, i) => etfDeepEqual(v, b.list[i]));
  }
  if ('map' in a && 'map' in b) {
    return a.map.length === b.map.length &&
      a.map.every(([ka, va], i) => {
        const [kb, vb] = b.map[i];
        return etfDeepEqual(ka, kb) && etfDeepEqual(va, vb);
      });
  }
  return false;
}

function termRepr(t) {
  try { return JSON.stringify(t, (k, v) => (typeof v === 'bigint' ? `${v}n` : v instanceof Uint8Array ? `[u8 ${v.length}]` : v)); }
  catch { return String(t); }
}

// --- Bellman determinism (two identical runs) --------------------------------
try {
  const { solve } = await importLib('solver/bellman.js');
  const { extractPolicyPath } = await importLib('solver/policy.js');
  const problem = {
    assets: ['asset-alpha', 'asset-beta'],
    windows: [
      [
        { index: 0, asset: 'asset-alpha', actions: [
          { id: 'imager-hi', reward: 42_000, batteryCost: 10_000, thermalCost: 5_000 },
          { id: 'imager-lo', reward: 20_000, batteryCost: 4_000, thermalCost: 2_000 },
        ] },
        { index: 1, asset: 'asset-alpha', actions: [
          { id: 'spectro', reward: 30_000, batteryCost: 8_000, thermalCost: 6_000 },
        ] },
        { index: 2, asset: 'asset-alpha', actions: [
          { id: 'relay', reward: 12_000, batteryCost: 3_000, thermalCost: 1_000 },
        ] },
      ],
      [
        { index: 0, asset: 'asset-beta', actions: [
          { id: 'imager-hi', reward: 42_000, batteryCost: 10_000, thermalCost: 5_000 },
        ] },
        { index: 1, asset: 'asset-beta', actions: [] },
        { index: 2, asset: 'asset-beta', actions: [
          { id: 'beacon', reward: 9_000, batteryCost: 2_000, thermalCost: 1_000 },
        ] },
      ],
    ],
    initialBudget: 30_000,
    horizon: 3,
  };
  const run1 = solve(problem);
  const run2 = solve(problem);
  const s1 = JSON.stringify({ value: run1.value, policy: run1.policy });
  const s2 = JSON.stringify({ value: run2.value, policy: run2.policy });
  if (s1 !== s2) {
    record('bellman determinism', 'FAIL', 'two identical runs produced different value/policy tables');
  } else {
    const steps = extractPolicyPath(problem, run1, 0);
    const spentOk = steps.every((st) => Number.isInteger(st.qValue) && Number.isInteger(st.budgetAfter));
    record('bellman determinism', 'PASS',
      `2 runs bit-identical (${s1.length} bytes of value+policy tables); policy path ${steps.map((s) => s.actionId).join('->')}; integer fixed-point: ${spentOk}`);
  }
} catch (e) {
  record('bellman determinism', 'FAIL', e.message);
}

// --- JCS canonical JSON ordering ---------------------------------------------
try {
  const { jcsCanonical } = await importLib('attestation/canonical.js');
  const nested = { z: 1, a: { y: 2, b: [3, { n: 1, c: 2 }] }, m: 'x' };
  const out = jcsCanonical(nested);
  const expected = '{"a":{"b":[3,{"c":2,"n":1}],"y":2},"m":"x","z":1}';
  if (out !== expected) {
    record('jcs canonical ordering', 'FAIL', `got ${out}`);
  } else {
    const differentInsertion = jcsCanonical({ b: 1, a: 2 }) === jcsCanonical({ a: 2, b: 1 });
    record('jcs canonical ordering', 'PASS',
      `${out}${differentInsertion ? '; insertion-order invariant holds' : ''}`);
  }
} catch (e) {
  record('jcs canonical ordering', 'FAIL', e.message);
}

// --- verb-gate: refuse mutation, pass read -----------------------------------
try {
  const { isMutation, checkSuggestion } = await importLib('copilot/verb-gate.js');
  const mutationUrl = 'https://management.azure.com/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1?api-version=2021-11-01';
  const readUrl = 'https://management.azure.com/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1/read?api-version=2021-11-01';
  const cases = [
    [isMutation('PUT', mutationUrl) === true, 'PUT on VM URL refused'],
    [isMutation('DELETE', mutationUrl) === true, 'DELETE on VM URL refused'],
    [isMutation('POST', mutationUrl) === true, 'POST on VM URL refused'],
    [isMutation('PATCH', mutationUrl) === true, 'PATCH on VM URL refused'],
    [isMutation('GET', mutationUrl) === false, 'GET on VM URL passes'],
    [isMutation('GET', readUrl) === false, 'GET /read URL passes'],
    [checkSuggestion({ op: 'Microsoft.Compute/virtualMachines/vm1/write' }) === 'SUGGESTION_MUTATION_VERB', 'suggestion write op refused'],
    [checkSuggestion({ op: 'Microsoft.Compute/virtualMachines/vm1/read' }) === null, 'suggestion read op passes'],
  ];
  const bad = cases.filter(([ok]) => !ok).map(([, d]) => d);
  if (bad.length > 0) record('verb-gate refuse/pass', 'FAIL', bad.join('; '));
  else record('verb-gate refuse/pass', 'PASS', `${cases.length} gate cases (4 mutation verbs refused, GET + /read pass, suggestion layer agrees)`);
} catch (e) {
  record('verb-gate refuse/pass', 'FAIL', e.message);
}

// --- attestation valid / tampered / unsupported trio --------------------------
try {
  const { checkBootDigest } = await importLib('attestation/boot-digests.js');
  const serial = 'SMALT-SE-0000000001';
  const valid = checkBootDigest(serial, 'aa'.repeat(32));
  const tampered = checkBootDigest(serial, 'cc'.repeat(32));
  const unsupported = checkBootDigest('SMALT-SE-DOES-NOT-EXIST', 'aa'.repeat(32));
  const ok =
    valid.allowed === true &&
    tampered.allowed === false && tampered.reason === 'DIGEST_MISMATCH' &&
    unsupported.allowed === false && unsupported.reason === 'UNKNOWN_DEVICE';
  if (ok) {
    record('attestation trio', 'PASS', 'valid=allowed; tampered=DIGEST_MISMATCH; unsupported=UNKNOWN_DEVICE');
  } else {
    record('attestation trio', 'FAIL', JSON.stringify({ valid, tampered, unsupported }));
  }
} catch (e) {
  record('attestation trio', 'FAIL', e.message);
}

// --- session-ledger chain + guardedFetch refusal (zero-actuation seam) --------
try {
  const ledger = await importLib('copilot/session-ledger.js');
  const { makeRefusal } = await importLib('copilot/typed-refusal.js');
  ledger.resetLedger();
  const refusal = makeRefusal('ZERO_ACTUATION', 'PUT', 'https://management.azure.com/x', 1_700_000_000_000);
  ledger.appendRefusal(refusal, 'PUT', 'https://management.azure.com/x');
  ledger.appendLedger({ ts: 1_700_000_000_001, kind: 'read', verb: 'GET', url: 'https://management.azure.com/y' });
  const snap = ledger.getLedgerSnapshot();
  const intact = ledger.verifyLedgerChain(snap) && snap.intact && snap.length === 2;
  const gf = await ledger.guardedFetch('https://management.azure.com/z', { method: 'DELETE' }).catch((e) => ({ error: e }));
  const refused = gf && gf.ok === false && gf.refusal?.reason === 'ZERO_ACTUATION';
  const after = ledger.getLedgerSnapshot();
  if (intact && refused && after.length === 3 && ledger.verifyLedgerChain(after)) {
    record('ledger chain + guardedFetch refusal', 'PASS', 'chain intact across refusal + read + guarded DELETE refusal (3 entries)');
  } else {
    record('ledger chain + guardedFetch refusal', 'FAIL',
      `intact=${intact} refused=${refused} len=${after.length}`);
  }
  ledger.resetLedger();
} catch (e) {
  record('ledger chain + guardedFetch refusal', 'FAIL', e.message);
}

// --- frame codec round-trip (byte-stuffing path) -------------------------------
try {
  const gw = await importLib('serial/gateway.js');
  const payload = new Uint8Array(64).fill(0x7e); // worst case: all flags -> full stuffing
  const frame = gw.encodeFrame(payload);
  const dec = new gw.FrameDecoder();
  dec.push(frame);
  if (dec.frames.length === 1 && dec.frames[0].every((b, i) => b === payload[i])) {
    record('serial frame codec round-trip', 'PASS', `64x 0x7E payload survives stuffing/destuffing (${frame.length}-byte frame)`);
  } else {
    record('serial frame codec round-trip', 'FAIL', `frames=${dec.frames.length}`);
  }
} catch (e) {
  record('serial frame codec round-trip', 'FAIL', e.message);
}

// ---------------------------------------------------------------------------
// Leg 2: composition smoke — components
// ---------------------------------------------------------------------------

// DOM rendering is not executable in plain node. Honest SKIP, never a fake pass.
record('composition: panel rendering', 'SKIP',
  'DOM/Web Serial rendering is not executable in node — witnessed instead at the type layer below');

{
  const tsconfigUi = {
    compilerOptions: {
      noEmit: true,
      jsx: 'react-jsx',
      module: 'esnext',
      moduleResolution: 'bundler',
      target: 'es2022',
      esModuleInterop: true,
      skipLibCheck: true,
      lib: ['es2022', 'dom'],
      paths: { '@/*': [path.join(WS_ROOT, '*')].map((p) => p.replaceAll('\\', '/')) },
      strict: true,
      typeRoots: [path.join(WS_ROOT, 'node_modules', '@types')],
      types: ['node'],
    },
    include: [
      path.join(COMPONENTS, '**', '*.tsx'),
      path.join(APP, '**', '*.tsx'),
      path.join(LIB, '**', '*.ts'),
    ],
  };
  const uiTsconfigPath = path.join(tmp, 'tsconfig.ui.json');
  fs.writeFileSync(uiTsconfigPath, JSON.stringify(tsconfigUi, null, 2));
  const t2 = spawnSync(process.execPath, [TSC, '-p', uiTsconfigPath], { encoding: 'utf8' });
  if (t2.status === 0) {
    record('composition: panel component type-surface', 'PASS', 'tsc --strict --noEmit clean over components+app+lib');
  } else {
    record('composition: panel component type-surface', 'FAIL', t2.stdout.trim().split('\n').slice(0, 20).join(' | '));
  }
}

// ---------------------------------------------------------------------------
// Leg 3: optional live leg — ARM read-only probe (only if substrate is up)
// ---------------------------------------------------------------------------

{
  // Air-gap host guard: mirrors lib/smalt.ts assertLocalUrl for this
  // plain-node harness — only localhost smalt endpoints are reachable.
  // Same pattern as scripts/azure-arm-probe.mjs (SHIM-COURT sibling).
  function assertLocalUrl(url) {
    const u = new URL(url);
    if (!['127.0.0.1', 'localhost', '[::1]', '::1'].includes(u.hostname)) {
      throw new Error(`Air-gap violation: refused non-local host "${u.hostname}"`);
    }
    return u;
  }
  const armBase = process.env.SMALT_ARM_BASE || 'http://127.0.0.1:9443';
  const tenant = process.env.SMALT_TENANT || 'dev';
  const probeUrl = `${armBase}/subscriptions?api-version=2020-01-01`;
  try {
    // Mint a bearer from the local STS first (same as azure-arm-probe.mjs);
    // substrate default :enforce auth refuses tokenless GETs (401).
    const stsRes = await fetch(assertLocalUrl(`${armBase}/${tenant}/oauth2/v2.0/token`), {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'client_credentials',
        client_id: 'e2e-court',
        client_secret: 'e2e-court-secret',
        scope: 'https://management.azure.com/.default',
      }).toString(),
      signal: AbortSignal.timeout(3000),
    });
    const sts = await stsRes.json().catch(() => ({}));
    const token = sts.access_token;
    if (typeof token !== 'string' || !token) {
      record('live: ARM read-only probe', 'FAIL', `STS mint at ${armBase}/${tenant}/oauth2/v2.0/token -> ${stsRes.status}: ${JSON.stringify(sts).slice(0, 120)}`);
    } else {
      const res = await fetch(assertLocalUrl(probeUrl), {
        headers: { authorization: `Bearer ${token}` },
        signal: AbortSignal.timeout(3000),
      });
      const body = await res.text();
      if (res.ok) {
        record('live: ARM read-only probe', 'PASS', `GET ${probeUrl} -> ${res.status} (${body.slice(0, 120)})`);
      } else {
        record('live: ARM read-only probe', 'FAIL', `GET ${probeUrl} -> ${res.status}: ${body.slice(0, 120)}`);
      }
    }
  } catch (e) {
    record('live: ARM read-only probe', 'SKIP', `no smalt substrate on ${armBase} (${e.cause?.code ?? e.name}) — live leg not run`);
  }
}

// ---------------------------------------------------------------------------
// Verdict
// ---------------------------------------------------------------------------

const fails = results.filter((r) => r.verdict === 'FAIL');
const passes = results.filter((r) => r.verdict === 'PASS');
const skips = results.filter((r) => r.verdict === 'SKIP');
console.log('\n# court verdict');
console.log(`# PASS=${passes.length} FAIL=${fails.length} SKIP=${skips.length}`);
for (const f of fails) console.log(`# FAIL: ${f.name}: ${f.detail}`);
for (const s of skips) console.log(`# SKIP: ${s.name}: ${s.detail}`);
fs.rmSync(tmp, { recursive: true, force: true });
process.exit(fails.length === 0 ? 0 : 1);
