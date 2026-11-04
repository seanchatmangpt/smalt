#!/usr/bin/env node
/**
 * Route-smoke court — real next-dev boots, real HTTP, plain node.
 *
 * Three boots over the kd173c-harness idiom:
 *   boot1 :39761 plain — 14 page legs (GET -> 200 + canary) + ungated handler
 *                        legs + SSE leg.
 *   boot2 :39762 SMALT_DEBUG_FACES=1 (+ provisioned SMALT_INGEST_HMAC_KEY so
 *                        the HMAC 401 leg is reachable past the KD-173C
 *                        dev-plane gate) — gated handler legs: ingest GET
 *                        debug face, HMAC 401/202, isr-revalidate, isr-stats
 *                        POST reset.
 *   boot3 :39763 plain — mutation leg: app/api/v1/stream/route.ts is mutated
 *                        in try/finally with byte-compare restore; the SSE leg
 *                        MUST fail against the mutant, else "court did not
 *                        flip".
 *
 * Verdict vocabulary: PASS / FAIL / SKIP. Exit 0 only on zero FAILs.
 * Air-gap: every fetch goes through assertLocalUrl (scripts/lib/airgap.mjs).
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHmac } from 'node:crypto';
import { assertLocalUrl } from './lib/airgap.mjs';
import { nextDev } from './lib/kd173c-harness.mjs';

const WS_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const STREAM_ROUTE = path.join(WS_ROOT, 'app', 'api', 'v1', 'stream', 'route.ts');

const PORT_PLAIN = 39761;
const PORT_DEBUG = 39762;
const PORT_MUTANT = 39763;
const base = (p) => `http://127.0.0.1:${p}`;

const results = [];
function record(name, verdict, detail = '') {
  results.push({ name, verdict, detail });
  console.log(`[${verdict}] ${name}${detail ? ` — ${detail}` : ''}`);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function fetchText(url, init) {
  const res = await fetch(assertLocalUrl(url), init);
  const body = await res.text();
  return { res, body };
}

// ---------------------------------------------------------------------------
// Page legs: GET -> 200 + canary substring in the served HTML
// ---------------------------------------------------------------------------

// 12 static pages + 2 dynamic instances = 14 routes. The audit [id] page
// streams three Suspense chunks (100/300/600ms); reading the full body
// witnesses all three chunks land. News slugs are real isr-counter fixtures.
const PAGE_LEGS = [
  ['/', 'Smalt Sovereign Console'],
  ['/console', 'Sovereign Console'],
  ['/migrate', 'Migration'],
  ['/terminal', 'Sovereign Console — Terminal'],
  ['/process', 'Process Mining'],
  ['/popcorn', 'Popcorn Testbed'],
  ['/bench/action', 'N2 action storm bench'],
  ['/bench/audit', 'bench-audit-index'],
  ['/bench/compute', 'N-5 Compute Saturation Bench'],
  ['/bench/grid', 'N-1 Grid Bench — 10k rows'],
  // streamed read: canary is the data-page attr (React splits the h1 text
  // with <!-- --> markers) plus the LAST Suspense chunk, so only a full
  // streamed read witnesses all three chunks land.
  ['/bench/audit/smoke-a1', ['data-page="bench-audit"', 'data-chunk="c"']],
  ['/bench/news/isr-stampede-primary', 'Bench article isr-stampede-primary'],
  ['/bench/news/isr-dependent-00', 'Bench article isr-dependent-00'],
  ['/bench/news/isr-dependent-01', 'Bench article isr-dependent-01'],
];

async function runPageLegs(port, label) {
  for (const [route, canaries] of PAGE_LEGS) {
    const wanted = Array.isArray(canaries) ? canaries : [canaries];
    const name = `page ${route} (${label})`;
    try {
      const { res, body } = await fetchText(base(port) + route, {
        signal: AbortSignal.timeout(60_000), // dev-mode first-compile budget
      });
      const missing = wanted.filter((c) => !body.includes(c));
      if (res.ok && missing.length === 0) {
        record(name, 'PASS', `${res.status} ${res.headers.get('content-type') ?? ''} ${body.length}b`);
      } else {
        record(name, 'FAIL', `status=${res.status} missing=${JSON.stringify(missing)} len=${body.length}`);
      }
    } catch (e) {
      record(name, 'FAIL', `${e.name}: ${String(e.message).slice(0, 160)}`);
    }
  }
}

// ---------------------------------------------------------------------------
// Handler legs
// ---------------------------------------------------------------------------

async function jsonLeg(name, url, init, expect) {
  try {
    const { res, body } = await fetchText(url, init);
    let parsed = null;
    try {
      parsed = JSON.parse(body);
    } catch {
      // predicate receives null — a non-JSON body fails a JSON shape leg
    }
    if (expect(parsed, res, body) === true) {
      const keys = parsed && typeof parsed === 'object'
        ? ` keys=${Object.keys(parsed).slice(0, 8).join(',')}`
        : '';
      record(name, 'PASS', `status=${res.status}${keys}`);
    } else {
      record(name, 'FAIL', `status=${res.status} body=${body.slice(0, 160)}`);
    }
  } catch (e) {
    record(name, 'FAIL', `${e.name}: ${String(e.message).slice(0, 160)}`);
  }
}

// --- boot1: ungated handler legs ---------------------------------------------

async function handlerLegsPlain(port) {
  await jsonLeg(
    'handler sync/state malformed -> 400',
    `${base(port)}/api/sync/state`,
    { method: 'POST', body: 'this-is-not-json', signal: AbortSignal.timeout(30_000) },
    (parsed, res) => res.status === 400 && parsed?.error === 'sync_state_invalid_json',
  );

  await jsonLeg(
    'handler isr-stats GET shape',
    `${base(port)}/api/bench/isr-stats`,
    { signal: AbortSignal.timeout(30_000) },
    (parsed, res) =>
      res.status === 200 &&
      typeof parsed?.regenerations === 'number' &&
      typeof parsed?.staleServed === 'number' &&
      typeof parsed?.eventsPath === 'string' &&
      parsed.eventsPath.length > 0,
  );

  await jsonLeg(
    'handler bench/metrics shape rss>0',
    `${base(port)}/bench/metrics`,
    { signal: AbortSignal.timeout(30_000) },
    (parsed, res) =>
      res.status === 200 &&
      parsed?.ok === true &&
      typeof parsed?.rss_mb === 'number' &&
      parsed.rss_mb > 0 &&
      // mean is legitimately null before the histogram has samples; the
      // shape contract is ok:true + numeric rss + a percentile object.
      typeof parsed?.event_loop_delay_ms?.p50 === 'number',
  );

  await jsonLeg(
    'handler process/api available:boolean',
    `${base(port)}/process/api`,
    { signal: AbortSignal.timeout(30_000) },
    (parsed, res) => res.status === 200 && typeof parsed?.available === 'boolean',
  );

  await jsonLeg(
    'handler ingest GET debug-face disabled -> 404',
    `${base(port)}/api/v1/ingest`,
    { signal: AbortSignal.timeout(30_000) },
    (parsed, res) => res.status === 404,
  );

  const body = 'route-smoke-court-payload';
  await jsonLeg(
    'handler ingest POST dev-default key, non-dev plane -> 503',
    `${base(port)}/api/v1/ingest`,
    {
      method: 'POST',
      headers: { 'x-smalt-signature': createHmac('sha256', 'n4-dev-key').update(body).digest('hex') },
      body,
      signal: AbortSignal.timeout(30_000),
    },
    (parsed, res) => res.status === 503 && parsed?.error === 'dev_default_key_refused',
  );
}

// --- boot2: gated handler legs (SMALT_DEBUG_FACES=1 + provisioned HMAC key) --

async function handlerLegsDebug(port) {
  const KEY = 'route-smoke-provisioned-key';
  const body = 'route-smoke-court-hmac-payload';
  const sig = (k) => createHmac('sha256', k).update(body).digest('hex');

  await jsonLeg(
    'handler ingest GET debug-face enabled -> 200 shape',
    `${base(port)}/api/v1/ingest`,
    { signal: AbortSignal.timeout(30_000) },
    (parsed, res) =>
      res.status === 200 &&
      typeof parsed?.capacity === 'number' &&
      typeof parsed?.tokens === 'number' &&
      typeof parsed?.accepted === 'number' &&
      typeof parsed?.rejected401 === 'number' &&
      typeof parsed?.heap?.rss === 'number',
  );

  // HMAC 401 leg: wrong signature under the provisioned key -> typed 401.
  await jsonLeg(
    'handler ingest POST wrong sig -> 401',
    `${base(port)}/api/v1/ingest`,
    {
      method: 'POST',
      headers: { 'x-smalt-signature': sig('wrong-key') },
      body,
      signal: AbortSignal.timeout(30_000),
    },
    (parsed, res) => res.status === 401 && parsed?.error === 'invalid_signature',
  );

  // Admitted leg: correct HMAC under the provisioned key -> 202 accepted.
  await jsonLeg(
    'handler ingest POST good sig -> 202 accepted',
    `${base(port)}/api/v1/ingest`,
    {
      method: 'POST',
      headers: { 'x-smalt-signature': sig(KEY) },
      body,
      signal: AbortSignal.timeout(30_000),
    },
    (parsed, res) => res.status === 202 && parsed?.accepted === true,
  );
}

// --- boot2 continued: ISR revalidate + reset (gated debug faces) --------------

async function handlerLegsDebugIsr(port) {
  await jsonLeg(
    'handler isr-revalidate -> ok:true',
    `${base(port)}/api/bench/isr-revalidate`,
    {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ slugs: ['isr-stampede-primary', 'isr-dependent-00'] }),
      signal: AbortSignal.timeout(30_000),
    },
    (parsed, res) => res.status === 200 && parsed?.ok === true && parsed?.revalidated === 2,
  );

  await jsonLeg(
    'handler isr-stats POST reset (debug face)',
    `${base(port)}/api/bench/isr-stats`,
    {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ reset: true }),
      signal: AbortSignal.timeout(30_000),
    },
    (parsed, res) => res.status === 200 && parsed?.reset === true,
  );
}

// ---------------------------------------------------------------------------
// SSE leg: bounded read of /api/v1/stream
// ---------------------------------------------------------------------------

// Reads the opening frames of the SSE stream under an overall deadline.
// Returns { ok, detail }: ok=false when the transport contract is violated
// (wrong content-type, no retry frame, stream error). expectRetry is the
// retry-frame value the leg demands (mutated under the mutation boot).
async function sseLeg(port, expectRetry = 'retry: 1000') {
  const ctrl = new AbortController();
  try {
    const res = await fetch(assertLocalUrl(`${base(port)}/api/v1/stream`), { signal: ctrl.signal });
    const ctype = res.headers.get('content-type') ?? '';
    if (!ctype.includes('text/event-stream')) {
      return { ok: false, detail: `content-type=${ctype}` };
    }
    const reader = res.body.getReader();
    try {
      const decoder = new TextDecoder();
      let acc = '';
      const deadline = Date.now() + 1500;
      while (Date.now() < deadline) {
        const chunk = await reader.read();
        if (chunk.done) break;
        acc += decoder.decode(chunk.value, { stream: true });
        if (acc.includes('\n\n')) break; // first complete frame(s) arrived
      }
      const retryOk = acc.includes(`${expectRetry}\n\n`);
      const retryWrong = acc.includes('retry:') && !acc.includes(`${expectRetry}\n\n`);
      if (acc.length === 0) return { ok: false, detail: 'no frames within 1500ms' };
      if (retryWrong) return { ok: false, detail: `retry frame mismatch: ${JSON.stringify(acc.slice(0, 80))}` };
      if (!retryOk) return { ok: false, detail: `no retry frame yet: ${JSON.stringify(acc.slice(0, 80))}` };
      const delta = /id: \d+\ndata: \{.+\}\n\n/.test(acc);
      return {
        ok: true,
        detail: `retry=${expectRetry} delta-first-frame=${delta} ${JSON.stringify(acc.slice(0, 60))}`,
      };
    } finally {
      await reader.cancel().catch(() => {});
    }
  } catch (e) {
    if (ctrl.signal.aborted) return { ok: false, detail: 'aborted before first frame' };
    return { ok: false, detail: `${e.name}: ${String(e.message).slice(0, 120)}` };
  } finally {
    ctrl.abort(); // abort in finally — always
  }
}

// ---------------------------------------------------------------------------
// Mutation leg: stream-route mutant MUST flip the SSE leg
// ---------------------------------------------------------------------------

async function mutationLeg() {
  const original = fs.readFileSync(STREAM_ROUTE, 'utf8');
  const mutant = original.replace('"retry: 1000\\n\\n"', '"retry: 1701\\n\\n"');
  if (mutant === original) {
    record('mutation: retry-interval mutant applies', 'FAIL',
      'target "retry: 1000\\n\\n" not found in app/api/v1/stream/route.ts');
    return;
  }

  fs.writeFileSync(STREAM_ROUTE, mutant);
  try {
    const kill = await nextDev(WS_ROOT, PORT_MUTANT, {});
    try {
      // Hot-recompile readiness: bounded poll until the mutant is observable
      // (SSE leg FAILs because the first frame now carries retry: 1701), or
      // the deadline expires -> "court did not flip".
      const deadline = Date.now() + 90_000;
      let flipped = false;
      let last = '';
      while (Date.now() < deadline) {
        const r = await sseLeg(PORT_MUTANT, 'retry: 1000'); // demand the ORIGINAL
        last = r.detail;
        if (!r.ok) { // mutant live: the original retry frame is gone
          flipped = true;
          break;
        }
        await sleep(750);
      }
      if (flipped) {
        record('mutation: stream retry mutant flips SSE leg', 'PASS',
          `mutant observable (leg failed as required): ${last}`);
      } else {
        record('mutation: stream retry mutant flips SSE leg', 'FAIL',
          `court did not flip — SSE leg still passed against the mutant: ${last}`);
      }
    } finally {
      await kill();
    }
  } catch (e) {
    record('mutation: stream retry mutant flips SSE leg', 'FAIL',
      `mutant boot failed: ${String(e.message).slice(0, 200)}`);
  } finally {
    // Byte-compare restore, fail-closed.
    fs.writeFileSync(STREAM_ROUTE, original);
    const restored = fs.readFileSync(STREAM_ROUTE, 'utf8');
    if (restored !== original) {
      record('mutation: byte-exact restore', 'FAIL', 'restored file differs from original');
    } else {
      record('mutation: byte-exact restore', 'PASS',
        `${STREAM_ROUTE} restored byte-exact (${original.length}b)`);
    }
  }
}

// ---------------------------------------------------------------------------
// Main: three sequential boots, then the verdict
// ---------------------------------------------------------------------------

const t0 = Date.now();

// boot1: plain — pages + ungated handlers + SSE
{
  const kill = await nextDev(WS_ROOT, PORT_PLAIN, {});
  try {
    await runPageLegs(PORT_PLAIN, 'plain');
    await handlerLegsPlain(PORT_PLAIN);
    const sse = await sseLeg(PORT_PLAIN, 'retry: 1000');
    record('sse stream first-frame contract', sse.ok ? 'PASS' : 'FAIL', sse.detail);
  } finally {
    await kill();
  }
}

// boot2: debug faces + provisioned HMAC key — gated handlers
{
  const kill = await nextDev(WS_ROOT, PORT_DEBUG, {
    SMALT_DEBUG_FACES: '1',
    SMALT_INGEST_HMAC_KEY: 'route-smoke-provisioned-key',
  });
  try {
    await handlerLegsDebug(PORT_DEBUG);
    await handlerLegsDebugIsr(PORT_DEBUG);
  } finally {
    await kill();
  }
}

// boot3: mutation leg
await mutationLeg();

const dt = ((Date.now() - t0) / 1000).toFixed(1);
const fails = results.filter((r) => r.verdict === 'FAIL');
const passes = results.filter((r) => r.verdict === 'PASS');
const skips = results.filter((r) => r.verdict === 'SKIP');
console.log('\n# route-smoke court verdict');
console.log(`# runtime: ${dt}s`);
console.log(`# PASS=${passes.length} FAIL=${fails.length} SKIP=${skips.length}`);
for (const f of fails) console.log(`# FAIL: ${f.name}: ${f.detail}`);
for (const s of skips) console.log(`# SKIP: ${s.name}: ${s.detail}`);
process.exit(fails.length === 0 ? 0 : 1);
