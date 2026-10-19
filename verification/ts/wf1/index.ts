// wf1-provisioning — arm-resources: RG/policy/LRO/policy-deny/tag-merge/delete lifecycle.
import { ResourceManagementClient } from "@azure/arm-resources";
import { check, GREEN, RD, type WfResult } from "../harness/enum.ts";
import { expectRestError } from "../harness/assert.ts";
import { boundedPoll } from "../harness/poll.ts";
import { SUB, type SubstrateCoords, type CredMode } from "../harness/credential.ts";

type Ctx = { coords: SubstrateCoords; runid: string; cred: any; credMode: CredMode };

export async function run(ctx: Ctx): Promise<WfResult> {
  const checks: WfResult["checks"] = [];
  const client = new ResourceManagementClient(ctx.cred, SUB, {
    baseUri: ctx.coords.tls,
    retryOptions: { maxRetries: 0 },
  });
  // arm-resources v8 carries only the generic resource surface; policy
  // definitions/assignments and storageAccounts ride resources.* by-id /
  // generic LRO with explicit api-versions (ARM "2021-04-01" law).
  const rg = `wf1-${ctx.runid}`;
  const p = (n: string, v: string, d: string) => checks.push(check(n, v, d));

  await client.resourceGroups.createOrUpdate(rg, { location: "smalt" });
  p("rg-create", GREEN, `rg ${rg} created`);

  // red-against-missing-plane: dead port must fail as real transport error.
  try {
    const dead = new ResourceManagementClient(ctx.cred, SUB, {
      baseUri: "http://127.0.0.1:1",
      retryOptions: { maxRetries: 0 },
    });
    await dead.resourceGroups.get(rg);
    p("dead-port-plane-check", "FAIL", "call against dead port resolved — fake plane");
    return { id: "wf1", checks };
  } catch (err: any) {
    const real =
      /ECONNREFUSED|fetch failed|UND_ERR|ECONNRESET/i.test(
        String(err?.message ?? "") + String(err?.code ?? err?.cause?.code ?? ""),
      ) || typeof err?.statusCode === "undefined";
    p(
      "dead-port-plane-check",
      real ? GREEN : "FAIL",
      `dead authority typed as real transport failure (${err?.name})`,
    );
  }

  // policy definition + assignment (deny westus2)
  const defName = `ts-deny-${ctx.runid}`;
  const defId = `/subscriptions/${SUB}/providers/Microsoft.Authorization/policyDefinitions/${defName}`;
  await (
    await client.resources.beginCreateOrUpdateById(defId, "2021-06-01", {
      properties: {
        policyType: "Custom",
        mode: "All",
        policyRule: { if: { field: "location", equals: "westus2" }, then: { effect: "deny" } },
      },
    } as any)
  ).pollUntilDone();
  p("policy-def-create", GREEN, `definition ${defName} PUT by-id resolved`);

  const asgId = `/subscriptions/${SUB}${rg === "" ? "" : ""}/resourceGroups/${rg}/providers/Microsoft.Authorization/policyAssignments/${defName}`;
  await (
    await client.resources.beginCreateOrUpdateById(
      asgId,
      "2022-06-01",
      { properties: { policyDefinitionId: defId, enforcementMode: "Default" } } as any,
    )
  ).pollUntilDone();
  p("policy-assignment-create", GREEN, `assignment at RG scope by-id resolved`);

  // vnet sync PUT 201 (flat addressPrefixes shape)
  const vnet = `wf1-vnet-${ctx.runid}`;
  const vnetRes = await (
    await client.resources.beginCreateOrUpdateById(
      `/subscriptions/${SUB}/resourceGroups/${rg}/providers/Microsoft.Network/virtualNetworks/${vnet}`,
      "2021-04-01",
      { location: "smalt", addressPrefixes: ["10.42.0.0/16"], properties: { addressPrefixes: ["10.42.0.0/16"] } } as any,
    )
  ).pollUntilDone();
  p("vnet-put-201", GREEN, `vnet ${vnet} provisioningState=${(vnetRes as any).properties?.provisioningState}`);

  // storage account LRO via beginCreateOrUpdate + pollUntilDone
  const acct = `wf1acc${ctx.runid.replace(/-/g, "").slice(0, 10)}`;
  const poller = await client.resources.beginCreateOrUpdateById(
    `/subscriptions/${SUB}/resourceGroups/${rg}/providers/Microsoft.Storage/storageAccounts/${acct}`,
    "2021-04-01",
    { location: "smalt", kind: "StorageV2", sku: { name: "Standard_LRS" } } as any,
  );
  const final = await poller.pollUntilDone();
  p("storage-lro", GREEN, `LRO terminal, provisioningState=${(final as any)?.provisioningState ?? (final as any)?.properties?.provisioningState}`);

  // noncompliant PUT (westus2) must be a typed 400 PolicyViolation
  try {
    await (
      await client.resources.beginCreateOrUpdateById(
        `/subscriptions/${SUB}/resourceGroups/${rg}/providers/Microsoft.Network/virtualNetworks/wf1-bad-${ctx.runid}`,
        "2021-04-01",
        { location: "westus2", addressPrefixes: ["10.99.0.0/16"], properties: { addressPrefixes: ["10.99.0.0/16"] } } as any,
      )
    ).pollUntilDone();
    p("policy-deny", "FAIL",
      `noncompliant westus2 PUT resolved — policy deny not enforced over the wire ` +
      `(witnessed pre-suite: definition PUT 201 -> exact GET 404, LIST empty; ` +
      `assignment PUT 201 -> GET 404; Policy table not surviving across requests on this substrate)`);
  } catch (err: any) {
    const code = err?.parsedBody?.error?.code ?? err?.details?.error?.code;
    if (err?.statusCode === 400 && code === "PolicyViolation") {
      p("policy-deny", GREEN, "westus2 PUT refused 400 PolicyViolation");
    } else {
      p("policy-deny", "FAIL", `expected 400 PolicyViolation got ${err?.statusCode}/${code}: ${String(err?.message).slice(0, 160)}`);
    }
  }

  // Tags: PATCH merges (RG PATCH merge law); PUT is FULL-REPLACE —
  // omitted/empty tags REMOVE stored tags and GET renders "tags": null.
  await client.resourceGroups.update(rg, { tags: { env: "ts-court" } });
  const tagged = await client.resourceGroups.get(rg);
  p("rg-tag-merge", tagged.tags?.env === "ts-court" ? GREEN : "FAIL", `tags after PATCH merge: ${JSON.stringify(tagged.tags)}`);
  await client.resourceGroups.createOrUpdate(rg, { location: "smalt", tags: {} });
  const untagged = await client.resourceGroups.get(rg);
  p("rg-tags-null",
    untagged.tags === null || untagged.tags === undefined ? GREEN : "FAIL",
    `tags after PUT full-replace with empty tags: ${JSON.stringify(untagged.tags ?? null)}`);

  // red-against-missing-plane #2: GET a nonexistent RG -> 404 ResourceGroupNotFound
  await expectRestError(
    () => client.resourceGroups.get(`wf1-missing-${ctx.runid}`),
    { status: 404, code: "ResourceGroupNotFound" },
    "missing-rg-404",
  ).then((got) => p("missing-rg-404", GREEN, `typed 404 ${got.code}`))
   .catch((e) => p("missing-rg-404", "FAIL", String(e.message).slice(0, 200)));

  // beginDelete LRO + re-GET 404
  const delPoller = await client.resourceGroups.beginDelete(rg);
  await delPoller.pollUntilDone();
  p("rg-delete-lro", GREEN, "beginDelete pollUntilDone terminal");
  await expectRestError(
    () => client.resourceGroups.get(rg),
    { status: 404, code: "ResourceGroupNotFound" },
    "rg-gone-404",
  ).then(() => p("rg-gone-404", GREEN, "re-GET after delete 404"))
   .catch((e) => p("rg-gone-404", "FAIL", String(e.message).slice(0, 200)));

  return { id: "wf1", checks };
}
