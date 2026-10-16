// kv_challenge_witness.mjs — KD-15 mutation-court witness (S-3 lane).
// Real @azure/keyvault-keys KeyClient, NO injected Authorization header:
// the SDK's keyVaultAuthenticationPolicy sends the first request tokenless
// and only attaches a token after a 401 + WWW-Authenticate whose parsed
// challenge contains `resource` (keyVaultAuthenticationPolicy.js:
// scope = resource + "/.default"; no resource/scope => the 401 is returned
// to the caller and getKey throws).
//
// BEFORE (guard stripped / plain challenge): tokenless GET /keys/:name is
//   refused with the legacy plain challenge (no `resource`) => the policy
//   cannot recover => getKey throws ResourceNotFoundError/401.
// AFTER: enriched challenge (authorization + resource echoing the request
//   origin) => policy fetches a token and retries => 200.
//
// Run: NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem node test/sdk-full/kv_challenge_witness.mjs
import { KeyClient } from "@azure/keyvault-keys";

const ARM = process.env.SMALT_ARM || "http://127.0.0.1:9443";
const VAULT = process.env.SMALT_VAULT || "https://127.0.0.1:9444";
const KEY = "kd15-chal";

async function mintBearer() {
  const body = new URLSearchParams({
    grant_type: "client_credentials",
    client_id: "kd15-witness",
    client_secret: "dev",
  });
  const res = await fetch(`${ARM}/oauth2/v2.0/token`, { method: "POST", body });
  if (!res.ok) throw new Error(`STS mint failed ${res.status}: ${await res.text()}`);
  return (await res.json()).access_token;
}

class StaticCredential {
  constructor(token) {
    this.token = token;
  }
  async getToken() {
    return { token: this.token, expiresOnTimestamp: Date.now() + 3600_000 };
  }
}

const bearer = await mintBearer();

// Seed the key via the substrate's own create route with the token attached.
const seed = await fetch(`${VAULT}/keys/${KEY}/create`, {
  method: "POST",
  headers: {
    authorization: `Bearer ${bearer}`,
    "content-type": "application/json",
  },
  body: JSON.stringify({ kty: "oct-HSM" }),
});
const seedText = await seed.text();
if (!seed.ok) {
  console.log(`SEED_FAIL ${seed.status} ${seedText}`);
  process.exit(2);
}

// THE WITNESS: real SDK, no injected header, zero retries. Challenge-based
// handshake only — token attaches if and only if the challenge parses.
const client = new KeyClient(VAULT, new StaticCredential(bearer), {
  allowInsecureConnection: true,
  retryOptions: { maxRetries: 0 },
  disableChallengeResourceVerification: true,
});

try {
  const key = await client.getKey(KEY);
  console.log(`HANDSHAKE_OK ${key.name} kid=${key.id ? "present" : "absent"}`);
  process.exit(0);
} catch (err) {
  console.log(`HANDSHAKE_FAIL ${err.name || "Error"}: ${String(err.message).slice(0, 200)}`);
  process.exit(1);
}
