// resourcegraph.probe.mjs — KD-38 lane: Azure Resource Graph surface
// (`POST /providers/Microsoft.ResourceGraph/resources`) via the real TLS twin.
// @azure/resource-graph is not vendored in test/sdk-full/node_modules, so the
// probe drives raw REST in the probe harness (same envelope the SDK emits).
// Attach-only: boots nothing. Lane-private substrate required:
//   MIX_BUILD_ROOT=_build-lane326 MIX_ENV=test mix run --no-start --no-halt -e '...arm_port=39308; arm_tls_port=39309; egress_port=39310...'
//   NODE_TLS_REJECT_UNAUTHORIZED=0 SMALT_TS_ARM_TLS_PORT=39309 node resourcegraph.probe.mjs
// Exit contract: 0 all pass / 1 test fail / 2 substrate down / 3 harness error.
import net from "node:net";

const ARM_TLS = `https://localhost:${process.env.SMALT_TS_ARM_TLS_PORT || 9444}`;
const SUB = "00000000-0000-0000-0000-000000000000";
const TENANT = "00000000-0000-0000-0000-000000000000";
const RG_APIV = "2022-10-01"; // Resource Graph api-version the emulator serves

// Substrate STS client_credentials over the real TLS wire (raw fetch — msal-node
// needs OIDC instance discovery, which the emulator does not serve; see
// arm-resources.probe.mjs for the documented limitation).
async function mintToken() {
  const res = await fetch(`${ARM_TLS}/${TENANT}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: "smalt-rg-client",
      client_secret: "smalt-rg-secret",
      scope: "https://management.azure.com/.default",
    }),
  });
  if (res.status !== 200) throw new Error(`STS ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const body = await res.json();
  return body.access_token;
}

// Substrate preflight: attach, don't boot. Exit 2 loud on a dead plane.
const armTlsPort = Number(new URL(ARM_TLS).port) || 443;
await new Promise((resolve) => {
  const s = net.connect({ host: "127.0.0.1", port: armTlsPort, timeout: 2000 });
  s.once("connect", () => { s.destroy(); resolve(); });
  s.once("timeout", () => {
    s.destroy();
    console.error(`[resourcegraph] substrate down: no listener on 127.0.0.1:${armTlsPort} (ARM_TLS=${ARM_TLS}). Exit 2.`);
    process.exit(2);
  });
  s.once("error", () => {
    console.error(`[resourcegraph] substrate down: no listener on 127.0.0.1:${armTlsPort} (ARM_TLS=${ARM_TLS}). Exit 2.`);
    process.exit(2);
  });
});

let TOKEN;
try {
  TOKEN = await mintToken();
} catch (e) {
  console.error(`[resourcegraph] harness error minting STS token: ${e?.name}: ${e?.message}`);
  process.exit(3);
}

const results = [];
function record(name, ok, detail) {
  results.push({ name, ok, detail: String(detail).slice(0, 500) });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name} :: ${String(detail).slice(0, 400)}`);
}
async function step(name, fn) {
  try {
    record(name, true, await fn());
  } catch (e) {
    record(name, false, `${e.name}: ${e.message}`);
  }
}

// POST the Resource Graph query endpoint. Returns {status, body}.
async function rgQuery(payload, apiVersion = RG_APIV) {
  const res = await fetch(
    `${ARM_TLS}/providers/Microsoft.ResourceGraph/resources?api-version=${apiVersion}`,
    {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${TOKEN}` },
      body: JSON.stringify(payload),
    },
  );
  let body;
  try { body = await res.json(); } catch { body = null; }
  return { status: res.status, body };
}

// ---------------------------------------------------------------------------
// Seed: one ARM generic resource (NSG) so the graph has inventory to return.
// ---------------------------------------------------------------------------
await step("seed: ARM generic PUT Microsoft.Network/networkSecurityGroup", async () => {
  const id = `/subscriptions/${SUB}/resourceGroups/rg-kd38/providers/Microsoft.Network/networkSecurityGroups/rg-kd38-nsg`;
  const res = await fetch(`${ARM_TLS}${id}?api-version=2021-04-01`, {
    method: "PUT",
    headers: { "content-type": "application/json", authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify({ location: "westus2", properties: { securityRules: [] } }),
  });
  if (res.status !== 200 && res.status !== 201) throw new Error(`seed PUT ${res.status}: ${(await res.text()).slice(0, 150)}`);
  return `seeded ${res.status} id=${id}`;
});

// ---------------------------------------------------------------------------
// Happy path: real Resource Graph query over subscription scope.
// ---------------------------------------------------------------------------
await step("rg.query happy path: count/data/totalRecords envelope", async () => {
  const { status, body } = await rgQuery({
    subscriptions: [SUB],
    query: "project name",
  });
  if (status !== 200) throw new Error(`status ${status}: ${JSON.stringify(body).slice(0, 200)}`);
  if (typeof body.count !== "number" || !Array.isArray(body.data)) {
    throw new Error(`envelope malformed: count=${body.count} data=${Array.isArray(body.data)}`);
  }
  const hit = body.data.find((r) => r.name === "rg-kd38-nsg");
  if (!hit) throw new Error(`seeded NSG not in graph: ${JSON.stringify(body.data).slice(0, 200)}`);
  return `count=${body.count} totalRecords=${body.totalRecords} seeded NSG present`;
});

// ---------------------------------------------------------------------------
// Typed refusals.
// ---------------------------------------------------------------------------
await step("rg.wrong api-version -> 400 InvalidApiVersion", async () => {
  const { status, body } = await rgQuery({ subscriptions: [SUB], query: "project name" }, "2019-04-01");
  if (status !== 400) throw new Error(`expected 400, got ${status}`);
  const code = body?.error?.code;
  if (code !== "InvalidApiVersion") throw new Error(`code=${code}`);
  return `400 InvalidApiVersion (typed)`;
});

await step("rg.subscriptions as string -> 400 InvalidParameter", async () => {
  const { status, body } = await rgQuery({ subscriptions: SUB, query: "project name" });
  if (status !== 400) throw new Error(`expected 400, got ${status}: ${JSON.stringify(body).slice(0, 150)}`);
  if (body?.error?.code !== "InvalidParameter") throw new Error(`code=${body?.error?.code}`);
  return `400 InvalidParameter (typed, never 500)`;
});

await step("rg.bad KQL -> 400 BadQuery (typed)", async () => {
  const { status, body } = await rgQuery({ subscriptions: [SUB], query: "totally not kql ~~~" });
  if (status !== 400) throw new Error(`expected 400, got ${status}: ${JSON.stringify(body).slice(0, 150)}`);
  if (body?.error?.code !== "BadQuery") throw new Error(`code=${body?.error?.code}`);
  return `400 BadQuery (typed)`;
});

const pass = results.filter((r) => r.ok).length;
console.log(`\nSUMMARY: ${pass}/${results.length} probes passed`);
console.log(JSON.stringify(results, null, 2));
process.exitCode = pass === results.length ? 0 : 1;
