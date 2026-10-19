// arm-resources.probe.mjs — TS-1 lane: real @azure/arm-resources (v8) against
// the live smalt ARM TLS twin (:9444). Boot a substrate first (ts-run.mjs or
// an equivalent TLS-twin boot), then:
//   NODE_TLS_REJECT_UNAUTHORIZED=0 node arm-resources.probe.mjs
// (NODE_TLS_REJECT_UNAUTHORIZED=0 because the substrate's TLS twin currently
// serves a self-signed leaf; see docs/jira/v26.10.14/sdk-results/ts-arm-resources.md)
import { ResourceManagementClient } from "@azure/arm-resources";
import net from "node:net";

const PORTS = {
  arm: Number(process.env.SMALT_TS_ARM_PORT || 9443),
  armTls: Number(process.env.SMALT_TS_ARM_TLS_PORT || 9444),
};
const ARM_TLS = `https://localhost:${PORTS.armTls}`;
const SUB = "00000000-0000-0000-0000-000000000000";
const TENANT = "00000000-0000-0000-0000-000000000000";
const RG = "ts1-sdk-rg";
const NSG = "ts1-sdk-nsg";
const APIV = "2021-04-01"; // generic RP api-version (NSG)
const RG_APIV = "2021-04-01"; // resourceGroups api-version the emulator caps at

// Substrate STS client_credentials over the real TLS wire. ClientSecretCredential
// itself cannot be used: msal-node resolves tenant endpoints via OIDC instance
// discovery against the authority host, which the emulator does not serve
// (documented limitation, same class as ts-reality.test.mjs KV rows).
async function mintToken() {
  const res = await fetch(`${ARM_TLS}/${TENANT}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: "smalt-ts1-client",
      client_secret: "smalt-ts1-secret",
      scope: "https://management.azure.com/.default",
    }),
  });
  if (res.status !== 200) throw new Error(`STS ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const body = await res.json();
  return { token: body.access_token, expiresOnTimestamp: Date.now() + 55 * 60_000 };
}

// Substrate preflight: this probe attaches, it does not boot. Exit 2
// (substrate down) loud, never a fake "1 = test fail" on a dead plane.
const armTlsPort = Number(new URL(ARM_TLS).port) || 443;
await new Promise((resolve) => {
  const s = net.connect({ host: "127.0.0.1", port: armTlsPort, timeout: 2000 });
  s.once("connect", () => { s.destroy(); resolve(); });
  s.once("timeout", () => {
    s.destroy();
    console.error(`[arm-resources] substrate down: no listener on 127.0.0.1:${armTlsPort} (ARM_TLS=${ARM_TLS}). Exit 2.`);
    process.exit(2);
  });
  s.once("error", () => {
    console.error(`[arm-resources] substrate down: no listener on 127.0.0.1:${armTlsPort} (ARM_TLS=${ARM_TLS}). Exit 2.`);
    process.exit(2);
  });
});

// Guard the unguarded top-level mint: a rejection here would exit 1
// (harness error masquerading as test fail) — exit 3 per contract.
let CACHED;
try {
  CACHED = await mintToken();
} catch (e) {
  console.error(`[arm-resources] harness error minting STS token: ${e?.name}: ${e?.message}`);
  process.exit(3);
}
const cred = { getToken: async () => CACHED };
const results = [];
function record(name, ok, detail) {
  results.push({ name, ok, detail: String(detail).slice(0, 500) });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name} :: ${String(detail).slice(0, 400)}`);
}
async function step(name, fn) {
  try {
    record(name, true, await fn());
  } catch (e) {
    record(name, false, `${e.name}: ${e.message}${e.statusCode ? ` [statusCode=${e.statusCode}]` : ""}${e.response?.body ? ` body=${e.response.body.slice(0, 200)}` : ""}`);
  }
}

await step("sts: client_credentials token over TLS (raw fetch)", async () => {
  const t = await mintToken();
  return `token len=${t.token.length} JWT-segments=${t.token.split(".").length}`;
});

await step("subscriptions list (raw GET with STS-minted Bearer)", async () => {
  const { token } = await mintToken();
  const res = await fetch(`${ARM_TLS}/subscriptions?api-version=2022-12-01`, { headers: { authorization: `Bearer ${token}` } });
  if (res.status !== 200) throw new Error(`status ${res.status}: ${(await res.text()).slice(0, 150)}`);
  const body = await res.json();
  if (!body.value?.length) throw new Error("no subscriptions");
  return `${body.value.length} sub(s): ${body.value[0].subscriptionId} state=${body.value[0].state}`;
});

await step("locations list (raw GET)", async () => {
  const { token } = await mintToken();
  const res = await fetch(`${ARM_TLS}/subscriptions/${SUB}/locations?api-version=2022-12-01`, { headers: { authorization: `Bearer ${token}` } });
  if (res.status !== 200) throw new Error(`status ${res.status}: ${(await res.text()).slice(0, 150)}`);
  const body = await res.json();
  return `${body.value.length} location(s): ${body.value.slice(0, 5).map((l) => l.name).join(",")}`;
});

const client = new ResourceManagementClient(cred, SUB, { endpoint: ARM_TLS, apiVersion: RG_APIV, allowInsecureConnection: true });

await step("resourcegroup createOrUpdate", async () => {
  const rg = await client.resourceGroups.createOrUpdate(RG, {
    location: "westus2",
    tags: { lane: "ts1", suite: "sdk-ts-arm" },
  });
  return `name=${rg.name} location=${rg.location} provisioningState=${rg.properties?.provisioningState} tags=${JSON.stringify(rg.tags)}`;
});

await step("generic resource create: NSG (LRO beginCreateOrUpdateById + pollUntilDone)", async () => {
  const NSG_ID = `/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.Network/networkSecurityGroups/${NSG}`;
  const poller = await client.resources.beginCreateOrUpdateById(NSG_ID, APIV,
    { location: "westus2", properties: { securityRules: [] } });
  const res = await poller.pollUntilDone();
  return `LRO terminal; id=${res.id} provisioningState=${res.properties?.provisioningState}`;
});

await step("generic resource get: NSG (getById)", async () => {
  const NSG_ID = `/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.Network/networkSecurityGroups/${NSG}`;
  const res = await client.resources.getById(NSG_ID, APIV);
  return `id=${res.id} keys=${Object.keys(res).join(",")}`;
});

await step("resources listByResourceGroup", async () => {
  const items = [];
  for await (const r of client.resources.listByResourceGroup(RG)) items.push(`${r.name}(${r.type})`);
  return `items=[${items.join(",")}]`;
});

await step("resourcegroup update (tags PATCH)", async () => {
  const rg = await client.resourceGroups.update(RG, { tags: { lane: "ts1", patched: "to-be-overwritten" } });
  return `tags=${JSON.stringify(rg.tags)}`;
});

await step("generic resource delete: NSG (LRO beginDeleteById + pollUntilDone)", async () => {
  const NSG_ID = `/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.network/networkSecurityGroups/${NSG}`;
  const poller = await client.resources.beginDeleteById(NSG_ID, APIV);
  await poller.pollUntilDone();
  return "LRO terminal; deleted";
});

await step("resourcegroup delete (LRO beginDelete + pollUntilDone)", async () => {
  const poller = await client.resourceGroups.beginDelete(RG);
  await poller.pollUntilDone();
  return "LRO terminal; deleted";
});

await step("resourcegroup get-after-delete -> expect 404", async () => {
  try {
    await client.resourceGroups.get(RG);
    return "UNEXPECTED: get succeeded after delete";
  } catch (e) {
    if (e.statusCode === 404) return `statusCode=404 (correct) message=${e.message.slice(0, 120)}`;
    throw e;
  }
});

const pass = results.filter((r) => r.ok).length;
console.log(`\nSUMMARY: ${pass}/${results.length} probes passed`);
console.log(JSON.stringify(results, null, 2));
process.exitCode = pass === results.length ? 0 : 1;
