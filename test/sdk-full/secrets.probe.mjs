// secrets.probe.mjs — AZB-08: real @azure/keyvault-secrets set/get
// round-trip against the smalt substrate. Challenge-based handshake: the
// substrate answers the SDK's tokenless first touch with the KD-15 enriched
// challenge, so the SDK attaches the token itself (same court shape as
// kv_challenge_witness.mjs).
//
// Run: NODE_EXTRA_CA_CERTS=../../.smalt/tls/ca-cert.pem node secrets.probe.mjs
import { SecretClient } from "@azure/keyvault-secrets";
import net from "node:net";

const ARM = process.env.SMALT_TS_ARM || "http://127.0.0.1:9443";
const VAULT = process.env.SMALT_TS_ARM_TLS || "https://127.0.0.1:9444";
const NAME = `azb8-sdk-${Date.now()}`;

async function mintBearer() {
  const body = new URLSearchParams({
    grant_type: "client_credentials",
    client_id: "azb8-sdk-secrets",
    client_secret: "dev",
  });
  const res = await fetch(`${ARM}/oauth2/v2.0/token`, { method: "POST", body });
  if (!res.ok) throw new Error(`STS mint failed ${res.status}: ${await res.text()}`);
  return (await res.json()).access_token;
}

class StaticCredential {
  constructor(token) {
    this.token = token;
    this.expiresOnTimestamp = Date.now() + 3600_000;
  }
  async getToken() {
    return { token: this.token, expiresOnTimestamp: this.expiresOnTimestamp };
  }
}

// Preflight: attach-only, exit 2 when the substrate is down (loud SKIP,
// never a fake pass).
for (const [label, url] of [["ARM", ARM], ["VAULT", VAULT]]) {
  const port = Number(new URL(url).port) || (url.startsWith("https") ? 443 : 80);
  await new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port, timeout: 2000 });
    s.once("connect", () => { s.destroy(); resolve(); });
    const down = () => { s.destroy(); console.error(`[secrets-probe] substrate down: ${label}:${port}. Exit 2.`); process.exit(2); };
    s.once("timeout", down);
    s.once("error", down);
  });
}

const bearer = await mintBearer();
const cred = new StaticCredential(bearer);
const client = new SecretClient(VAULT, cred, {
  allowInsecureConnection: true,
  disableChallengeResourceVerification: true,
  retryOptions: { maxRetries: 0 },
});

// THE ROUND-TRIP: SDK set, then SDK get.
const value = `azb8-secret-${Date.now()}`;
await client.setSecret(NAME, value);
console.log(`[set] ${NAME} ok`);

const got = await client.getSecret(NAME);
const ok = got.value === value && got.name === NAME;
console.log(`[get] name=${got.name} value-match=${got.value === value}`);
console.log(ok ? "PASS azb8-sdk-secrets-roundtrip" : "FAIL azb8-sdk-secrets-roundtrip");
process.exitCode = ok ? 0 : 1;
