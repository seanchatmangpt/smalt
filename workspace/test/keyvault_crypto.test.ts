/**
 * Key Vault console client court — real substrate, real crypto, real challenge.
 *
 * Ladder (Chicago): boots a private-port smalt substrate (MIX_ENV=test) and
 * exercises the wire: challenge handshake, key create → encrypt → wrap →
 * secret rotate → unwrap → decrypt exact-payload round trip, typed envelopes,
 * ARM PUT → data-plane cross-plane seed.
 *
 * Exit: 0 pass / 1 fail. Run: test/keyvault/run.sh (boots substrate, compiles
 * TS, node --test).
 */
import test from "node:test";
import assert from "node:assert/strict";
import {
  SmaltKeyVaultClient,
  KvError,
  parseChallenge,
  type KvKey,
} from "../lib/azure/keyvault.js";
import { assertLocalUrl } from "../lib/smalt.js";

const ARM = process.env.KV_TEST_ARM ?? "http://127.0.0.1:39710";
const DATA = process.env.KV_TEST_DATA ?? "http://127.0.0.1:39711";
const RUN = `kvconsole-${Date.now()}`;

/** fetch wrapper that records 401 challenge responses (handshake evidence). */
function challengeRecordingFetch(log: { challenges: number[] }): typeof fetch {
  return (async (input: RequestInfo | URL, init?: RequestInit) => {
    const res = await fetch(input, init);
    if (res.status === 401 && res.headers.get("www-authenticate")?.includes("authorization=")) {
      log.challenges.push(res.status);
    }
    return res;
  }) as typeof fetch;
}

function client(log: { challenges: number[] } = { challenges: [] }): SmaltKeyVaultClient {
  return new SmaltKeyVaultClient({
    dataBase: DATA,
    armBase: ARM,
    fetchImpl: challengeRecordingFetch(log),
  });
}

test("parseChallenge extracts authorization and resource", () => {
  const c = parseChallenge(
    'Bearer authorization="http://127.0.0.1:39710/organizations", resource="http://127.0.0.1:39711", error="invalid_token"',
  );
  assert.equal(c.authorization, "http://127.0.0.1:39710/organizations");
  assert.equal(c.resource, "http://127.0.0.1:39711");
});

test("challenge-response handshake: tokenless 401 -> STS mint -> retry 200", async () => {
  const log = { challenges: [] as number[] };
  const kv = client(log);
  // Tokenless first touch must observe a real 401 challenge on the wire.
  const probeUrl = assertLocalUrl(DATA + "/secrets/" + RUN + "-probe");
  const bare = await fetch(probeUrl);
  assert.equal(bare.status, 401, "tokenless GET /secrets must 401");
  assert.match(bare.headers.get("www-authenticate") ?? "", /authorization="/);

  const secret = await kv.setSecret(`${RUN}-handshake`, "v1");
  assert.ok(secret.id.includes(`/${RUN}-handshake/`));
  assert.equal((await kv.getSecret(`${RUN}-handshake`)).value, "v1");
  assert.ok(log.challenges.length >= 1, "client must have observed the 401 challenge");
  await kv.deleteSecret(`${RUN}-handshake`);
});

test("key create -> encrypt -> decrypt exact payload (RSA-OAEP-256)", async () => {
  const kv = client();
  const key: KvKey = await kv.createKey(`${RUN}-rsa`, { kty: "RSA-HSM" });
  assert.equal(key.kty, "RSA-HSM");
  assert.ok(key.kid.includes(`/keys/${RUN}-rsa/`));
  assert.ok(key.n && key.e === "AQAB");

  const plaintext = new TextEncoder().encode("smalt kv exact payload 0123456789");
  const ct = await kv.encrypt(`${RUN}-rsa`, plaintext);
  assert.notDeepEqual(Buffer.from(ct), Buffer.from(plaintext));
  const pt = await kv.decrypt(`${RUN}-rsa`, ct);
  assert.deepEqual(Buffer.from(pt), Buffer.from(plaintext), "decrypt must invert encrypt");
});

test("wrap -> secret rotate -> unwrap -> exact CEK round trip", async () => {
  const kv = client();
  await kv.createKey(`${RUN}-wrap`, { kty: "RSA-HSM" });
  const cek = crypto.getRandomValues(new Uint8Array(32));

  const wrapped = await kv.wrapKey(`${RUN}-wrap`, cek);
  assert.notDeepEqual(Buffer.from(wrapped), Buffer.from(cek));

  // Secret rotation: re-PUT accumulates a new version id.
  const v1 = await kv.setSecret(`${RUN}-wrapped-cek`, "seed-v1");
  const v2 = await kv.setSecret(`${RUN}-wrapped-cek`, "seed-v2");
  assert.ok(v1.id !== v2.id, "rotation must mint a new version id");
  assert.equal((await kv.getSecret(`${RUN}-wrapped-cek`)).value, "seed-v2");

  const unwrapped = await kv.unwrapKey(`${RUN}-wrap`, wrapped);
  assert.deepEqual(Buffer.from(unwrapped), Buffer.from(cek), "unwrap must invert wrap");

  await kv.deleteSecret(`${RUN}-wrapped-cek`);
});

test("key re-create accumulates versions; versioned GET resolves old version", async () => {
  const kv = client();
  const k1 = await kv.createKey(`${RUN}-vers`, { kty: "RSA-HSM" });
  const k2 = await kv.createKey(`${RUN}-vers`, { kty: "RSA-HSM" });
  assert.ok(k1.kid !== k2.kid);
  const v1 = k1.kid.split("/").pop() as string;
  const old = await kv.getKey(`${RUN}-vers`, v1);
  assert.equal(old.kid, k1.kid, "named version must resolve the original kid");
});

test("RS256 sign/verify: true for exact payload, false when tampered", async () => {
  const kv = client();
  await kv.createKey(`${RUN}-sig`, { kty: "RSA-HSM" });
  const msg = new TextEncoder().encode("sign me");
  const sig = await kv.sign(`${RUN}-sig`, msg);
  assert.equal(await kv.verify(`${RUN}-sig`, msg, sig), true);
  const tampered = Buffer.from(sig, "base64url");
  tampered[0] ^= 0xff;
  assert.equal(await kv.verify(`${RUN}-sig`, msg, tampered.toString("base64url")), false);
});

test("typed envelopes: SecretNotFound, SecretExpired, KeyNotFound", async () => {
  const kv = client();
  await assert.rejects(
    () => kv.getSecret(`${RUN}-missing`),
    (e: KvError) => e instanceof KvError && e.code === "SecretNotFound" && e.status === 404,
  );
  await assert.rejects(
    () => kv.getKey(`${RUN}-missing-key`),
    (e: KvError) => e instanceof KvError && e.code === "KeyNotFound" && e.status === 404,
  );
  // Expired secret: expiration attribute in the past -> typed SecretExpired.
  await kv.setSecret(`${RUN}-expired`, "stale", {
    expires: Math.floor(Date.now() / 1000) - 60,
  });
  await assert.rejects(
    () => kv.getSecret(`${RUN}-expired`),
    (e: KvError) => e instanceof KvError && e.code === "SecretExpired",
  );
  await kv.deleteSecret(`${RUN}-expired`);
});

test("ARM vault PUT -> ARM secret PUT -> data-plane GET (cross-plane seed)", async () => {
  const kv = client();
  const vault = await kv.createVault("00000000-0000-0000-0000-000000000000", RUN, `${RUN}-vault`);
  assert.ok(
    String((vault as { properties?: { vaultUri?: string } }).properties?.vaultUri ?? "").includes(
      "127.0.0.1",
    ),
    "vault envelope must carry a loopback vaultUri",
  );
  await kv.putArmVaultSecret(
    "00000000-0000-0000-0000-000000000000",
    RUN,
    `${RUN}-vault`,
    `${RUN}-seeded`,
    "cross-plane-value",
  );
  const seeded = await kv.getSecret(`${RUN}-seeded`);
  assert.equal(seeded.value, "cross-plane-value", "ARM PUT must seed the 8443 data plane");
  await kv.deleteSecret(`${RUN}-seeded`);
});
