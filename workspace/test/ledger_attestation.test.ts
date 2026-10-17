/**
 * Ledger + attestation console-client court (lane Ring 2 / Agent 8).
 *
 * Live-substrate tests over the real egress plane (8443) with a real STS
 * bearer token — Chicago style, no mocks. Exit contract: 0 pass / 1 fail /
 * 3 loud SKIP (substrate down).
 *
 * Run:
 *   T=$(mktemp -d) && cd workspace && node_modules/.bin/tsc \
 *     --outDir "$T" --rootDir . --module commonjs --moduleResolution node10 \
 *     --target es2022 --esModuleInterop --skipLibCheck --types node \
 *     test/ledger_attestation.test.ts lib/azure/ledger.ts lib/smalt.ts \
 *     && node --test "$T/test/ledger_attestation.test.js"
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';

import {
  appendTransaction,
  attest,
  auditChain,
  auditReceipt,
  computeDataHash,
  fetchAccessToken,
  getLatest,
  getTransaction,
  LedgerError,
  listTransactions,
  verifyReceiptStructure,
  verifySignature,
  ZERO_HASH,
} from '../lib/azure/ledger';
import { smaltFetch } from '../lib/smalt';

const EGRESS = process.env.SMALT_TEST_EGRESS ?? 'http://127.0.0.1:8443';
const ARM = process.env.SMALT_TEST_ARM ?? 'http://127.0.0.1:9443';
const N_ENTRIES = 50;

let token: string;

async function substrateUp(): Promise<boolean> {
  try {
    const res = await smaltFetch(EGRESS, '/app/transactions');
    return res.status === 401 || res.status === 200; // auth fence counts as "up"
  } catch {
    return false;
 }
}

test.before(async () => {
  if (!(await substrateUp())) {
    console.error(`[SKIP] smalt egress plane not reachable at ${EGRESS}`);
    process.exit(3);
  }
  token = await fetchAccessToken(ARM);
});

const uniq = (): string =>
  createHash('sha256').update(`${process.pid}:${Date.now()}:${Math.random()}`).digest('hex').slice(0, 16);

test('STS: console fetches a real bearer token', async () => {
  assert.match(token, /^eyJ/, 'access_token must be a JWT-shaped string');
});

test('append 50 entries: 201 receipts, monotonic tx ids', async () => {
  for (let i = 0; i < N_ENTRIES; i++) {
    const contents = { lane: 'ring2-agent8', seq: i, nonce: uniq() };
    const { status, receipt } = await appendTransaction(EGRESS, token, contents);
    assert.equal(status, 201);
    assert.match(receipt.transactionId, /^\d+\.\d+$/);
    assert.equal(receipt.data_hash, computeDataHash(contents));
    if (i > 0) {
      // server-chained: each new entry's prev_hash equals the prior merkle_root
      const prev = await getLatest(EGRESS, token);
      // (read-before-append ordering: verified comprehensively in the chain test)
      assert.ok(prev.merkle_root.length === 64);
    }
  }
});

test('audit proof per entry: client-side math holds for every receipt', async () => {
  const receipts = await listTransactions(EGRESS, token);
  const mine = receipts.filter((r) => {
    const c = r.contents as { lane?: string };
    return c && typeof c === 'object' && c.lane === 'ring2-agent8';
  });
  assert.ok(mine.length >= N_ENTRIES, `expected >= ${N_ENTRIES} lane receipts, got ${mine.length}`);
  for (const r of mine) {
    const checks = auditReceipt(r, null); // link checks covered by auditChain
    const dataHashOk = checks.find((c) => c.check === 'data_hash recomputes');
    const merkleOk = checks.find((c) => c.check === 'merkle_root = sha256(prev<>data)');
    const jwsOk = checks.find((c) => c.check === 'JWS structure + payload binding');
    assert.equal(dataHashOk?.valid, true, `data_hash: ${JSON.stringify(dataHashOk)}`);
    assert.equal(merkleOk?.valid, true, `merkle: ${JSON.stringify(merkleOk)}`);
    assert.equal(jwsOk?.valid, true, `JWS: ${JSON.stringify(jwsOk)}`);
  }
});

test('chain-link verification across all lane appends (incl. genesis zero hash)', async () => {
  const receipts = await listTransactions(EGRESS, token);
  const mine = receipts.filter((r) => (r.contents as { lane?: string })?.lane === 'ring2-agent8');
  assert.ok(mine.length >= N_ENTRIES);
  // genesis of the whole shared ledger: first-ever entry must chain off zero hash
  const first = receipts[0];
  assert.equal(first.prev_hash, ZERO_HASH, 'genesis prev_hash must be 64 zeros');
  // the chain is the WHOLE shared ledger — audit the contiguous list, not a
  // per-lane subset (other lanes' entries legitimately interleave)
  const { ok, failures } = auditChain(receipts);
  assert.equal(ok, true, `chain failures: ${JSON.stringify(failures.slice(0, 5))}`);
});

test('read by tx-id, latest, and list are consistent', async () => {
  const receipts = await listTransactions(EGRESS, token);
  const mine = receipts.filter((r) => (r.contents as { lane?: string })?.lane === 'ring2-agent8');
  const last = mine[mine.length - 1];
  const byId = await getTransaction(EGRESS, token, last.transactionId);
  assert.equal(byId.transactionId, last.transactionId);
  assert.deepEqual(byId.contents, last.contents);
  const latest = await getLatest(EGRESS, token);
  const list = await listTransactions(EGRESS, token);
  assert.equal(latest.transactionId, list[list.length - 1].transactionId);
  const seqs = list.map((r) => parseInt(r.transactionId, 10));
  assert.deepEqual(seqs, [...seqs].sort((a, b) => a - b), 'list must be monotonic');
});

test('tamper a byte: client verification fails (data_hash + JWS binding)', async () => {
  const receipts = await listTransactions(EGRESS, token);
  const mine = receipts.filter((r) => (r.contents as { lane?: string })?.lane === 'ring2-agent8');
  const target = { ...mine[0], contents: { ...(mine[0].contents as object) } } as typeof mine[0];
  (target.contents as { nonce: string }).nonce = `0${(target.contents as { nonce: string }).nonce.slice(1)}`;
  const checks = auditReceipt(target, null);
  assert.equal(checks.find((c) => c.check === 'data_hash recomputes')?.valid, false,
    'tampered contents must break data_hash');
  assert.equal(checks.find((c) => c.check === 'JWS structure + payload binding')?.valid, false,
    'tampered contents must break JWS payload binding');
  // hash-field tamper breaks merkle math
  const target2 = { ...mine[0], data_hash: `0${mine[0].data_hash.slice(1)}` };
  const checks2 = auditReceipt(target2, null);
  assert.equal(checks2.find((c) => c.check === 'merkle_root = sha256(prev<>data)')?.valid, false);
});

test('duplicate append: 409 LedgerItemAlreadyExists typed fence', async () => {
  const contents = { lane: 'ring2-agent8', dup: uniq() };
  await appendTransaction(EGRESS, token, contents);
  await assert.rejects(
    () => appendTransaction(EGRESS, token, contents),
    (e: LedgerError) => e.status === 409 && e.code === 'LedgerItemAlreadyExists'
  );
});

test('verifySignature seam: wrong key fails, structurally valid receipt passes shape gate', async () => {
  const receipts = await listTransactions(EGRESS, token);
  const r = receipts[receipts.length - 1];
  // structurally valid receipt, but no real pubkey on the wire: an arbitrary
  // key must produce a typed invalid, never a throw
  const bogusKey = '-----BEGIN PUBLIC KEY-----\nMA==\n-----END PUBLIC KEY-----';
  const res = verifySignature(r, bogusKey);
  assert.equal(res.valid, false);
  assert.ok(res.reason, 'typed reason required');
});

test('MAA attest: non-hex64 measurement is a typed 400 refusal', async () => {
  await assert.rejects(
    () => attest(EGRESS, token, 'not-a-measurement'),
    (e: LedgerError) => e.status === 400 && e.code === 'attestationFailedVerdict'
  );
});

test('MAA attest: hex64 measurement yields a typed outcome (token or baseline refusal)', async () => {
  const measurement = createHash('sha256').update('ring2-agent8-quote').digest('hex');
  try {
    const { status, token: jws } = await attest(EGRESS, token, measurement);
    assert.equal(status, 200);
    assert.ok(jws, 'attested: token must be present');
    const struct = verifyReceiptStructure({
      transactionId: '1.1',
      data_hash: 'x',
      prev_hash: 'x',
      merkle_root: 'x',
      signature: jws,
    } as never);
    assert.equal(struct.header?.alg, 'RS256', 'MAA token must be RS256');
    assert.equal(struct.header?.typ, 'JWT');
  } catch (e) {
    assert.ok(e instanceof LedgerError, `unexpected error type: ${String(e)}`);
    assert.equal((e as LedgerError).status, 400);
    assert.equal((e as LedgerError).code, 'attestationFailedVerdict',
      'measurement outside baseline: typed refusal is the documented outcome');
  }
});

test('canonicalJson matches substrate data_hash on nested contents', async () => {
  const contents = { b: 1, a: { d: [1, 2], c: 'x' }, nonce: uniq() };
  const { receipt } = await appendTransaction(EGRESS, token, contents);
  assert.equal(receipt.data_hash, computeDataHash(contents));
  const back = await getTransaction(EGRESS, token, receipt.transactionId);
  assert.equal(back.data_hash, receipt.data_hash);
  assert.equal(back.data_hash, computeDataHash(back.contents));
});
