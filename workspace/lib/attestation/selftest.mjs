// Lane WS-10 self-test: node selftest.mjs
// Generates real keypairs via node:crypto webcrypto, signs JCS-canonical
// receipts, and witnesses: valid=true, tampered valid=false, ML-DSA-65 typed
// refusal, plus malformed-input totality.
import { strict as assertStrict } from 'node:assert';
import { webcrypto } from 'node:crypto';
import { verify, sha256Hex } from './validator.ts';
import { jcsCanonical } from './canonical.ts';
import { KNOWN_BOOT_DIGESTS } from './boot-digests.ts';

const subtle = webcrypto.subtle;

async function makeReceipt(algorithm, keys, payload, signerId = 'device-α-1') {
  const data = new TextEncoder().encode(jcsCanonical(payload));
  let params, sig;
  if (algorithm === 'RS256') {
    params = { name: 'RSASSA-PKCS1-v1_5' };
    sig = await subtle.sign(params, keys.rsa.privateKey, data);
  } else {
    params = { name: 'ECDSA', hash: 'SHA-256' };
    sig = await subtle.sign(params, keys.ec.privateKey, data);
  }
  const b64u = (b) =>
    Buffer.from(b).toString('base64url');
  const receipt = {
    algorithm,
    signerId,
    payload,
    signature: b64u(sig),
    key: keys.jwk,
  };
  return receipt;
}

async function genKeys() {
  const rsa = await subtle.generateKey(
    {
      name: 'RSASSA-PKCS1-v1_5',
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: 'SHA-256',
    },
    true,
    ['sign', 'verify']
  );
  const ec = await subtle.generateKey(
    { name: 'ECDSA', namedCurve: 'P-256' },
    true,
    ['sign', 'verify']
  );
  const rsaJwk = await subtle.exportKey('jwk', rsa.publicKey);
  const ecJwk = await subtle.exportKey('jwk', ec.publicKey);
  return { rsa, ec, rsaJwk, ecJwk };
}

const keys = await genKeys();
const payload = {
  kind: 'SIGNED_RECEIPT',
  chipsetSerial: 'SMALT-SE-0000000001',
  monotonicCounter: 7,
  digest: await sha256Hex('challenge-bytes'),
};

let pass = 0;
function check(name, cond) {
  if (!cond) {
    console.error(`FAIL ${name}`);
    process.exitCode = 1;
  } else {
    pass++;
    console.log(`PASS ${name}`);
  }
}

// 1. RS256 valid
{
  const rec = await makeReceipt('RS256', { ...keys, jwk: keys.rsaJwk }, payload);
  const res = await verify(rec);
  check('RS256 valid=true', res.valid === true && res.signer === 'device-α-1');
}
// 2. ECDSA-P256 valid
{
  const rec = await makeReceipt('ECDSA-P256', { ...keys, jwk: keys.ecJwk }, payload);
  const res = await verify(rec);
  check('ECDSA-P256 valid=true', res.valid === true && res.signer === 'device-α-1');
}
// 3. Tampered payload -> valid=false
{
  const rec = await makeReceipt('RS256', { ...keys, jwk: keys.rsaJwk }, payload);
  const tampered = {
    ...rec,
    payload: { ...payload, monotonicCounter: 8 },
  };
  const res = await verify(tampered);
  check('tampered -> valid=false', res.valid === false);
}
// 4. Wrong key -> valid=false
{
  const rec = await makeReceipt('ECDSA-P256', { ...keys, jwk: keys.rsaJwk }, payload);
  const res = await verify(rec); // EC sig verified under RSA JWK -> error path
  check('cross-algorithm key -> valid=false', res.valid === false);
}
// 5. ML-DSA-65 typed refusal
{
  const rec = {
    algorithm: 'ML-DSA-65',
    signerId: 'pq-device',
    payload,
    signature: 'AAAA',
    key: keys.ecJwk,
  };
  const res = await verify(rec);
  check(
    'ML-DSA-65 -> refused ALGORITHM_UNSUPPORTED',
    res.refused === 'ALGORITHM_UNSUPPORTED' && res.algorithm === 'ML-DSA-65'
  );
}
// 6. Boot-digest allowlist
{
  const known = KNOWN_BOOT_DIGESTS.get('SMALT-SE-0000000001');
  const rec = await makeReceipt('RS256', { ...keys, jwk: keys.rsaJwk }, {
    ...payload,
    bootDigest: known.digest,
  });
  rec.chipsetSerial = 'SMALT-SE-0000000001';
  rec.bootDigest = known.digest;
  const resOk = await verify(rec);
  check('boot digest allowlisted -> valid=true', resOk.valid === true);

  const recBad = { ...rec, bootDigest: 'cc'.repeat(32) };
  const resBad = await verify(recBad);
  check(
    'boot digest mismatch -> valid=false BOOT_DIGEST_DIGEST_MISMATCH',
    resBad.valid === false && resBad.reason === 'BOOT_DIGEST_DIGEST_MISMATCH'
  );

  const recUnknown = { ...rec, chipsetSerial: 'UNKNOWN-SE-1' };
  const resUnknown = await verify(recUnknown);
  check(
    'unknown device -> valid=false BOOT_DIGEST_UNKNOWN_DEVICE',
    resUnknown.valid === false &&
      resUnknown.reason === 'BOOT_DIGEST_UNKNOWN_DEVICE'
  );
}
// 7. Totality: malformed inputs never throw
{
  for (const bad of [
    null,
    undefined,
    42,
    'receipt',
    [],
    {},
    { algorithm: 'RS256' },
    { algorithm: 'RS256', signerId: 'x' },
    {
      algorithm: 'RS256',
      signerId: 'x',
      payload: {},
      signature: '!!!not-encodable!!!',
      key: keys.rsaJwk,
    },
    {
      algorithm: 'ED25519',
      signerId: 'x',
      payload: {},
      signature: 'AA',
      key: keys.ecJwk,
    },
  ]) {
    const res = await verify(bad); // must not throw
    check(
      `total on malformed ${JSON.stringify(bad)?.slice(0, 40)}`,
      res && (res.valid === false || res.refused !== undefined)
    );
  }
}
// 8. Canonical form determinism / key ordering
{
  const a = jcsCanonical({ b: 1, a: { d: 2, c: [3, { z: 1, y: 2 }] } });
  const b = jcsCanonical({ a: { c: [3, { y: 2, z: 1 }], d: 2 }, b: 1 });
  assertStrict.equal(a, b);
  assertStrict.equal(a, '{"a":{"c":[3,{"y":2,"z":1}],"d":2},"b":1}');
  check('JCS canonical sorted keys / no whitespace', true);
}

console.log(`\n${pass} checks passed${process.exitCode ? ' (with FAILURES)' : ''}`);
