#!/usr/bin/env node
/**
 * enclave-loop.mjs — Sovereign Console leg of the enclave loop.
 *
 * Drives the terraform-fixture resources the way the console does: raw HTTP
 * through the lib/smalt.ts air-gap surface (smaltFetch/assertLocalUrl), no
 * @azure/* SDKs. Node cannot import .ts directly, so lib/smalt.ts is compiled
 * to a temp outDir with the workspace's own tsc (the e2e-court.mjs pattern)
 * and imported — the console's REAL guard functions run on every request.
 *
 * Env (e2e convention, test/e2e/s9_lro_chain/run.sh):
 *   SMALT_TEST_ARM_PORT    (default 9443)
 *   SMALT_TEST_EGRESS_PORT (default 8443)
 *   SMALT_TENANT           (default 'dev')
 *   SMALT_ENCLAVE_COSMOS_DB / SMALT_ENCLAVE_COSMOS_COLL — cosmos surface probe
 *
 * Fixture resource names (test/terraform_fixture/main.tf):
 *   rg-smalt-fixture / kv-smalt-fixture / t5smaltfixturestore
 *
 * Verdict rows: PASS / FAIL / SKIP-LOUD (an absent surface is loud, never a
 * fake pass). Exit: 0 zero FAIL, 1 any FAIL, 3 substrate never up (loud skip
 * of the whole leg).
 */

// ---------------------------------------------------------------------------
// Air-gap base URLs + the console's real guard, compiled from lib/smalt.ts
// ---------------------------------------------------------------------------

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const WS_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const TSC = path.join(WS_ROOT, 'node_modules', 'typescript', 'bin', 'tsc');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'enclave-loop-'));
fs.symlinkSync(path.join(WS_ROOT, 'node_modules'), path.join(tmp, 'node_modules'), 'dir');
const tsconfigPath = path.join(tmp, 'tsconfig.json');
fs.writeFileSync(
  tsconfigPath,
  JSON.stringify({
    compilerOptions: {
      outDir: path.join(tmp, 'js'),
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
  console.error(`[enclave-loop] FAIL lib/smalt.ts typecheck: ${tsc.stdout.trim()}`);
  process.exit(1);
}
const { smaltFetch } = await import(
  pathToFileURL(path.join(tmp, 'js', 'lib', 'smalt.js')).href
);

// Env override: NEXT_PUBLIC_* bake into lib/smalt.ts defaults; the wrapper
// lane provisions on ephemeral ports, so rebind here before any request.
const ARM_PORT = Number(process.env.SMALT_TEST_ARM_PORT || 9443);
const EGRESS_PORT = Number(process.env.SMALT_TEST_EGRESS_PORT || 8443);
const ARM = `http://127.0.0.1:${ARM_PORT}`;
const EGRESS = `http://127.0.0.1:${EGRESS_PORT}`;
const TENANT = process.env.SMALT_TENANT || 'dev';
const DB = process.env.SMALT_ENCLAVE_COSMOS_DB || 'enclave';
const COLL = process.env.SMALT_ENCLAVE_COSMOS_COLL || 'markers';
const STAMP = `enclave-${Date.now()}`;

const results = [];
function record(name, verdict, detail = '') {
  results.push({ name, verdict, detail });
  console.log(`[${verdict}] ${name}${detail ? ` — ${detail}` : ''}`);
}
const T = (ms) => AbortSignal.timeout(ms);

// ---------------------------------------------------------------------------
// STS bearer mint (substrate default :enforce auth refuses tokenless calls)
// ---------------------------------------------------------------------------

let token = null;
try {
  const res = await smaltFetch(
    ARM,
    `/${TENANT}/oauth2/v2.0/token`,
    {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'client_credentials',
        client_id: 'enclave-loop',
        client_secret: 'enclave-loop-secret',
        scope: 'https://management.azure.com/.default',
      }).toString(),
      signal: T(5000),
    }
  );
  const sts = await res.json();
  token = sts.access_token;
  if (typeof token !== 'string' || !token) {
    record('sts mint', 'FAIL', `POST ${ARM}/${TENANT}/oauth2/v2.0/token -> ${res.status}: ${JSON.stringify(sts).slice(0, 160)}`);
  } else {
    record('sts mint', 'PASS', `bearer minted from ${ARM}/${TENANT}/oauth2/v2.0/token (${token.length}-char token)`);
  }
} catch (e) {
  console.log(`# SKIP-LOUD: no substrate on ARM ${ARM} (${e.cause?.code ?? e.name}) — console leg not run`);
  console.log('# court verdict: PASS=0 FAIL=0 SKIP=1 (substrate down)');
  fs.rmSync(tmp, { recursive: true, force: true });
  process.exit(3);
}

const auth = () => ({ authorization: `Bearer ${token}` });

/** One data-plane hop: returns {status, body, headers} or throws on transport. */
async function hop(name, method, requestPath, { body, headers = {}, base = EGRESS } = {}) {
  const res = await smaltFetch(base, requestPath, {
    method,
    headers: { ...auth(), ...headers },
    body,
    signal: T(10_000),
  });
  const text = await res.text();
  return { name, status: res.status, text, headers: res.headers };
}

// EXPLORE-1 W10: every hop below is POST-MINT — the STS mint above is a
// liveness proof and pre-mint transport failure exits 3 before any hop runs.
// A transport timeout on a substrate that already answered the mint means the
// substrate is UP but HUNG: that is a FAIL, never a skip. (The old
// is5xxOrNetError classified AbortError/TimeoutError as SKIP-LOUD, disclosing
// a faulted leg as a skip.) ALL hop errors therefore FAIL.
const hopVerdict = (_e) => 'FAIL';

// ---------------------------------------------------------------------------
// Hop 1: ARM read — the tf fixture resource group must be visible
// ---------------------------------------------------------------------------

{
  const requestPath = `/subscriptions/rg-smalt-fixture?api-version=2020-06-01`;
  try {
    const r = await hop('arm: fixture rg read', 'GET', requestPath, { base: ARM });
    if (r.status === 200 && JSON.stringify(r.text).includes('rg-smalt-fixture')) {
      record('arm: fixture rg read', 'PASS', `GET ${requestPath} -> 200 names rg-smalt-fixture`);
    } else if (r.status === 404) {
      record('arm: fixture rg read', 'SKIP-LOUD', `rg-smalt-fixture not provisioned on this substrate (404) — tf fixture not applied`);
    } else {
      record('arm: fixture rg read', 'FAIL', `GET ${requestPath} -> ${r.status}: ${r.text.slice(0, 160)}`);
    }
  } catch (e) {
    record('arm: fixture rg read', hopVerdict(e), String(e.message ?? e).slice(0, 160));
  }
}

// ---------------------------------------------------------------------------
// Hop 2: blob — PUT container + PUT/GET marker blob on t5smaltfixturestore
// (fixture storage account; the account itself is what tf creates — the
// marker container/blob are created by the loop, Azure-faithfully)
// ---------------------------------------------------------------------------

const ACCOUNT = 't5smaltfixturestore';
const CONTAINER = 'enclave-marker';
const BLOB = `${STAMP}.txt`;
const MARKER = `enclave-alive-${STAMP}`;
const XMSV = { 'x-ms-version': '2021-12-02' };

{
  try {
    const created = await hop('blob: container ensure', 'PUT', `/${ACCOUNT}/${CONTAINER}?restype=container`, {
      headers: { ...XMSV, 'content-type': 'text/plain' },
    });
    if (![200, 201].includes(created.status)) {
      record('blob: container ensure', 'FAIL', `PUT /${ACCOUNT}/${CONTAINER}?restype=container -> ${created.status}: ${created.text.slice(0, 160)}`);
    } else {
      record('blob: container ensure', 'PASS', `PUT /${ACCOUNT}/${CONTAINER}?restype=container -> ${created.status}`);
      const put = await hop('blob: marker PUT', 'PUT', `/${ACCOUNT}/${CONTAINER}/${BLOB}`, {
        body: MARKER,
        headers: { ...XMSV, 'x-ms-blob-type': 'BlockBlob', 'content-type': 'text/plain' },
      });
      if (put.status !== 201) {
        record('blob: marker PUT', 'FAIL', `PUT -> ${put.status}: ${put.text.slice(0, 160)}`);
      } else {
        const get = await hop('blob: marker GET', 'GET', `/${ACCOUNT}/${CONTAINER}/${BLOB}`, { headers: XMSV });
        if (get.status === 200 && get.text === MARKER) {
          record('blob: marker PUT+GET', 'PASS', `PUT -> 201, GET -> 200, byte-exact round-trip (${MARKER.length} bytes)`);
        } else {
          record('blob: marker PUT+GET', 'FAIL', `GET -> ${get.status}, body ${JSON.stringify(get.text.slice(0, 80))} != ${JSON.stringify(MARKER)}`);
        }
      }
    }
  } catch (e) {
    record('blob: marker PUT+GET', hopVerdict(e), String(e.message ?? e).slice(0, 160));
  }
}

// ---------------------------------------------------------------------------
// Hop 3: vault secret — PUT then GET on the /secrets plane
// (tf creates only the vault kv-smalt-fixture; the secret itself is seeded
// by this loop under the fixture vault's secret plane, loud if refused)
// ---------------------------------------------------------------------------

const SECRET = 'enclave-loop-secret';
const SECRET_VALUE = `kv-open-${STAMP}`;
{
  try {
    const put = await hop('vault: secret PUT', 'PUT', `/secrets/${SECRET}?api-version=7.4`, {
      headers: { ...XMSV, 'content-type': 'application/json' },
      body: JSON.stringify({ value: SECRET_VALUE }),
    });
    if (![200, 201].includes(put.status)) {
      record('vault: secret read-back', 'FAIL', `PUT /secrets/${SECRET} -> ${put.status}: ${put.text.slice(0, 160)}`);
    } else {
      const get = await hop('vault: secret GET', 'GET', `/secrets/${SECRET}?api-version=7.4`, { headers: XMSV });
      let value = null;
      try { value = JSON.parse(get.text)?.value ?? null; } catch { /* non-JSON -> FAIL below */ }
      if (get.status === 200 && value === SECRET_VALUE) {
        record('vault: secret read-back', 'PASS', `PUT /secrets/${SECRET} -> ${put.status}, GET -> 200, value round-trips (kv-smalt-fixture plane)`);
      } else {
        record('vault: secret read-back', 'FAIL', `GET -> ${get.status}, value ${JSON.stringify(value)} != ${JSON.stringify(SECRET_VALUE)}`);
      }
    }
  } catch (e) {
    record('vault: secret read-back', hopVerdict(e), String(e.message ?? e).slice(0, 160));
  }
}

// ---------------------------------------------------------------------------
// Hop 4: cosmos — provision db+coll (best-effort), POST a doc, query it
// (PUT /dbs/:db is measured 400 on this substrate — ws9 witness; tolerate
// the db-route refusal, provision the collection and docs, query SELECT)
// ---------------------------------------------------------------------------

{
  try {
    const dbPut = await hop('cosmos: db ensure', 'PUT', `/dbs/${DB}`, {
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ id: DB }),
    });
    const dbOk = [200, 201, 409].includes(dbPut.status);
    if (!dbOk) {
      record('cosmos: db ensure', 'SKIP-LOUD', `PUT /dbs/${DB} -> ${dbPut.status} (measured substrate db-route refusal, ws9 witness) — collection hop not run against a synthetic parent`);
    } else {
      const collPost = await hop('cosmos: coll ensure', 'POST', `/dbs/${DB}/colls`, {
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ id: COLL, partitionKey: { paths: ['/pk'], kind: 'Hash' } }),
      });
      if (![200, 201, 409].includes(collPost.status)) {
        record('cosmos: doc + query', 'FAIL', `POST /dbs/${DB}/colls -> ${collPost.status}: ${collPost.text.slice(0, 160)}`);
      } else {
        const docId = `${STAMP}-doc`;
        const docPost = await hop('cosmos: doc POST', 'POST', `/dbs/${DB}/colls/${COLL}/docs`, {
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ id: docId, pk: STAMP, marker: MARKER }),
        });
        if (![200, 201].includes(docPost.status)) {
          record('cosmos: doc + query', 'FAIL', `POST docs -> ${docPost.status}: ${docPost.text.slice(0, 160)}`);
        } else {
          const q = await hop('cosmos: query', 'POST', `/dbs/${DB}/colls/${COLL}/docs`, {
            headers: {
              'content-type': 'application/query+json',
              'x-ms-documentdb-isquery': 'true',
              'x-ms-documentdb-query-enablecrosspartition': 'true',
            },
            body: JSON.stringify({ query: 'SELECT * FROM c WHERE c.pk = @pk', parameters: [{ name: '@pk', value: STAMP }] }),
          });
          let hits = [];
          try { hits = JSON.parse(q.text)?.Documents ?? []; } catch { /* non-JSON -> FAIL below */ }
          if (q.status === 200 && hits.length === 1 && hits[0].marker === MARKER) {
            record('cosmos: doc + query', 'PASS', `doc POST -> ${docPost.status}, query -> 200, 1/1 marker match (${docId})`);
          } else {
            record('cosmos: doc + query', 'FAIL', `query -> ${q.status}, hits=${hits.length}: ${q.text.slice(0, 160)}`);
          }
        }
      }
    }
  } catch (e) {
    record('cosmos: doc + query', hopVerdict(e), String(e.message ?? e).slice(0, 160));
  }
}

// ---------------------------------------------------------------------------
// Hop 5: event ingest — CloudEvents POST + read-back on /topics/:topic/events
// (the substrate's HTTP ingest plane; AMQP 5673 EH lane is not a console
// surface — the console is HTTP-only through smaltFetch)
// ---------------------------------------------------------------------------

{
  const topic = 'enclave-loop';
  const body = JSON.stringify([
    {
      specversion: '1.0',
      type: 'com.smalt.enclave.loop',
      source: '/enclave/loop/console',
      id: STAMP,
      data: { marker: MARKER },
    },
  ]);
  try {
    const post = await hop('eh: cloudevents ingest', 'POST', `/topics/${topic}/events?api-version=2018-01-01`, {
      headers: { 'content-type': 'application/cloudevents-batch+json' },
      body,
    });
    if (post.status === 404) {
      record('eh: cloudevents ingest', 'SKIP-LOUD', `POST /topics/${topic}/events -> 404 — no HTTP ingest plane on this substrate build`);
    } else if (![200, 201, 204].includes(post.status)) {
      record('eh: cloudevents ingest', 'FAIL', `POST -> ${post.status}: ${post.text.slice(0, 160)}`);
    } else {
      const get = await hop('eh: ingest read-back', 'GET', `/topics/${topic}/events`, {});
      const found = get.text.includes(MARKER);
      if (get.status === 200 && found) {
        record('eh: cloudevents ingest', 'PASS', `POST -> ${post.status}, GET read-back contains the loop marker`);
      } else {
        record('eh: cloudevents read-back', 'FAIL', `GET -> ${get.status}, marker present=${found}`);
      }
    }
  } catch (e) {
    record('eh: cloudevents ingest', hopVerdict(e), String(e.message ?? e).slice(0, 160));
  }
}

// ---------------------------------------------------------------------------
// Verdict
// ---------------------------------------------------------------------------

const fails = results.filter((r) => r.verdict === 'FAIL');
const passes = results.filter((r) => r.verdict === 'PASS');
const skips = results.filter((r) => r.verdict === 'SKIP-LOUD');
console.log('\n# enclave loop verdict');
console.log(`# PASS=${passes.length} FAIL=${fails.length} SKIP-LOUD=${skips.length}`);
for (const f of fails) console.log(`# FAIL: ${f.name}: ${f.detail}`);
for (const s of skips) console.log(`# SKIP-LOUD: ${s.name}: ${s.detail}`);
fs.rmSync(tmp, { recursive: true, force: true });
process.exit(fails.length === 0 ? 0 : 1);
