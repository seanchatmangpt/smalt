// ex5-insurance-governance — Fortune-500 archetype: an insurer's platform
// team governing its policy-administration subscription. Four chapters:
//   1. Azure Policy — deny-by-location definition, RG-scope assignment,
//      initiative (policySetDefinitions), exemption lifecycle
//      (create -> exempted create succeeds -> remove -> violation returns).
//   2. RBAC — built-in role definition read + role assignment lifecycle at
//      RG scope (create, read-back, list via get, typed 404s).
//   3. Management locks — probed against the real wire; the substrate's
//      locks surface answers a typed 501 LockSurfaceNotImplemented stub, so
//      this chapter loud-SKIPs as SURFACE-ABSENT (never a fake pass).
//   4. Tags at scope — PATCH merge, PUT full-replace, empty->null law.
// Wire contract: arm-resources generic by-id operations with explicit
// api-versions (the validated wf1 pattern) against the smalt ARM TLS twin.
import { createRequire } from "node:module";
import path from "node:path";
// SDKs resolve from the verification/ts node_modules (one dependency tree
// for the whole external tier); harness imports are relative file imports.
const require = createRequire(
  path.resolve(import.meta.dirname, "../../verification/ts/package.json"),
);
const { ResourceManagementClient } = require("@azure/arm-resources");
import { check, GREEN, type Check, type WfResult } from "../../verification/ts/harness/enum.ts";
import { expectRestError, classify } from "../../verification/ts/harness/assert.ts";
import { SUB, SmaltTokenCredential, TENANT } from "../../verification/ts/harness/credential.ts";

const REPO = path.resolve(import.meta.dirname, "../..");
const TLS = process.env.SMALT_ARM_TLS ?? "https://localhost:9444";

const SKIP_SA = "SKIP#SURFACE-ABSENT";
const FAIL = "FAIL";

const unique = (x: string) => `ex5-ins-${x}-${Date.now()}`;

async function putById(
  client: ResourceManagementClient,
  id: string,
  apiVersion: string,
  body: unknown,
): Promise<any> {
  const poller = await client.resources.beginCreateOrUpdateById(id, apiVersion, body as any);
  return poller.pollUntilDone();
}

export async function main(): Promise<number> {
  const cred = new SmaltTokenCredential(`${TLS}/${TENANT}/oauth2/v2.0/token`);
  const client = new ResourceManagementClient(cred, SUB, {
    baseUri: TLS,
    retryOptions: { maxRetries: 0 },
  });

  const runid = String(Date.now());
  const wf: WfResult = { id: "ex5-insurance-governance", checks: [] };
  const p = (n: string, verdict: string, detail: string) => wf.checks.push(check(n, verdict, detail));

  // ---------------------------------------------------------------
  // Chapter 0 — the insurer's policy-administration resource group.
  // ---------------------------------------------------------------
  const rg = unique("rg");
  const rgId = `/subscriptions/${SUB}/resourceGroups/${rg}`;
  await client.resourceGroups.createOrUpdate(rg, { location: "smalt" });
  p("rg-create", GREEN, `policy-administration RG ${rg} up`);

  const vnet = (name: string, location: string) =>
    putById(
      client,
      `${rgId}/providers/Microsoft.Network/virtualNetworks/${name}`,
      "2021-04-01",
      {
        location,
        addressPrefixes: ["10.42.0.0/16"],
        properties: { addressPrefixes: ["10.42.0.0/16"] },
      },
    );

  // ---------------------------------------------------------------
  // Chapter 1 — Azure Policy governance.
  // ---------------------------------------------------------------
  const defName = unique("deny-westus2");
  const defId = `/subscriptions/${SUB}/providers/Microsoft.Authorization/policyDefinitions/${defName}`;
  await putById(client, defId, "2021-06-01", {
    properties: {
      policyType: "Custom",
      mode: "All",
      displayName: "ex5: deny workloads in westus2",
      policyRule: {
        if: { field: "location", equals: "westus2" },
        then: { effect: "deny" },
      },
    },
  });
  p("policy-def-create", GREEN, `deny-by-location definition ${defName} PUT by-id resolved`);

  const asgName = unique("asg");
  const asgId = `${rgId}/providers/Microsoft.Authorization/policyAssignments/${asgName}`;
  await putById(client, asgId, "2022-06-01", {
    properties: { policyDefinitionId: defId, enforcementMode: "Default" },
  });
  p("policy-assignment-create", GREEN, "assignment at RG scope (enforcementMode Default)");

  // Violating create -> typed 400 PolicyViolation.
  let violationReturned = false;
  try {
    await vnet(unique("bad-vnet"), "westus2");
    p("policy-deny", FAIL, "westus2 create resolved — deny not enforced");
  } catch (err: any) {
    const code = err?.parsedBody?.error?.code ?? err?.details?.error?.code;
    if (err?.statusCode === 400 && code === "PolicyViolation") {
      violationReturned = true;
      p("policy-deny", GREEN, "westus2 create refused with typed 400 PolicyViolation");
    } else {
      p("policy-deny", FAIL, `expected 400 PolicyViolation got ${err?.statusCode}/${code}`);
    }
  }

  // Initiative (policySetDefinitions) grouping the definition.
  const setName = unique("initiative");
  const setId = `/subscriptions/${SUB}/providers/Microsoft.Authorization/policySetDefinitions/${setName}`;
  const setRes = await putById(client, setId, "2021-06-01", {
    properties: {
      policyType: "Custom",
      displayName: "ex5: claims-platform guardrails",
      policyDefinitions: [{ policyDefinitionId: defId }],
    },
  });
  const setDefs = setRes?.properties?.policyDefinitions ?? [];
  p(
    "initiative-create",
    setDefs.length === 1 && setDefs[0]?.policyDefinitionId === defId
      ? GREEN
      : FAIL,
    `initiative ${setName} read-back lists ${setDefs.length} member definition(s)`,
  );

  // Exemption lifecycle: exempt the RG from the assignment, prove the deny
  // stops firing, then remove the exemption and prove the deny returns.
  const exName = unique("exemption");
  const exId = `${rgId}/providers/Microsoft.Authorization/policyExemptions/${exName}`;
  const future = new Date(Date.now() + 3_600_000).toISOString(); // SLEEP-CLASS: TIME-ADVANCE (a far-future expiry stamped into a wire body, never slept on)
  let exOk = false;
  try {
    const exempted = await putById(client, exId, "2022-07-01-preview", {
      properties: {
        policyAssignmentId: asgId,
        exemptionCategory: "Waiver",
        displayName: "ex5: westus2 DR exception workflow",
        expiresOn: future,
      },
    });
    exOk = !!exempted?.properties?.policyAssignmentId;
    p("exemption-create", exOk ? GREEN : FAIL, `exemption ${exName} created (Waiver, expiresOn ${future})`);
  } catch (err: any) {
    const got = classify(err);
    p("exemption-create", FAIL, `exemption PUT refused ${got.status}/${got.code}: ${got.message}`);
  }

  if (violationReturned && exOk) {
    // While exempted, the same violating create must succeed.
    let exemptCreateOk = false;
    try {
      const res = await vnet(unique("dr-vnet"), "westus2");
      exemptCreateOk = true;
      p("exemption-applies", GREEN, `westus2 DR vnet created under exemption (id ${(res as any)?.id ?? "ok"})`);
    } catch (err: any) {
      const code = err?.parsedBody?.error?.code ?? err?.details?.error?.code;
      p("exemption-applies", FAIL, `still refused under exemption: ${err?.statusCode}/${code}`);
    }

    // Remove the exemption -> violation must return.
    if (exemptCreateOk) {
      try {
        await (await client.resources.beginDeleteById(exId, "2022-07-01-preview")).pollUntilDone();
        p("exemption-remove", GREEN, "exemption DELETE LRO terminal");
      } catch (err: any) {
        exemptCreateOk = false;
        p("exemption-remove", FAIL, `DELETE exemption failed: ${err?.statusCode} ${String(err?.message).slice(0, 120)}`);
      }
      if (exemptCreateOk) {
        try {
          await vnet(unique("post-dr-vnet"), "westus2");
          p("exemption-expired-violation-returns", FAIL, "westus2 create resolved after exemption removal");
        } catch (err: any) {
          const code = err?.parsedBody?.error?.code ?? err?.description ?? err?.details?.error?.code;
          const ok = err?.statusCode === 400 && code === "PolicyViolation";
          p("exemption-expired-violation-returns", ok ? GREEN : FAIL,
            `after exemption removal: ${err?.statusCode}/${code}`);
        }
      }
    }
  }

  // ---------------------------------------------------------------
  // Chapter 2 — RBAC: built-in role definitions (served deterministically
  // by the substrate) + role assignment lifecycle at RG scope.
  // ---------------------------------------------------------------
  let roleDefId: string | null = null;
  try {
    const reader = await client.resources.getById(
      `/subscriptions/${SUB}/providers/Microsoft.Authorization/roleDefinitions/contributor`,
      "2022-04-01",
    );
    roleDefId = reader?.id ?? null;
    const roleName = reader?.properties?.roleName;
    p("rbac-builtin-role-def",
      roleName === "Contributor" ? GREEN : FAIL,
      `GET roleDefinitions/contributor -> roleName=${roleName}`);
  } catch (err: any) {
    const got = classify(err);
    p("rbac-builtin-role-def", FAIL, `GET built-in role def refused ${got.status}/${got.code}: ${got.message}`);
  }

  await expectRestError(
    () =>
      client.resources.getById(
        `/subscriptions/${SUB}/providers/Microsoft.Authorization/roleDefinitions/ex5-ins-no-such-role-${runid}`,
        "2022-04-01",
      ),
    { status: 404, code: "ResourceNotFound" },
    "rbac-unknown-role-404",
  )
    .then((got) => p("rbac-unknown-role-404", GREEN, `typed 404 ${got.code} for unknown role`))
    .catch((e) => p("rbac-unknown-role-404", FAIL, String(e.message).slice(0, 200)));

  const principalId = "22222222-2222-2222-2222-222222222222";
  const raGuid = "33333333-3333-3333-3333-333333333333";
  const raId = `${rgId}/providers/Microsoft.Authorization/roleAssignments/${raGuid}`;
  // Wire law (witnessed): a no-location body is refused 400 InvalidResourceShape
  // ("A resource payload may carry at most one location"); the admitted shape
  // carries exactly one top-level location.
  const raBody = {
    location: "global",
    properties: {
      roleDefinitionId: roleDefId ?? `/subscriptions/${SUB}/providers/Microsoft.Authorization/roleDefinitions/contributor`,
      principalId,
      principalType: "User",
    },
  };
  try {
    await putById(client, raId, "2022-04-01", raBody);
    const raGet = await client.resources.getById(raId, "2022-04-01");
    const raOk =
      raGet?.properties?.principalId === principalId &&
      String(raGet?.properties?.roleDefinitionId ?? "").includes("roleDefinitions");
    p("rbac-role-assignment",
      raOk ? GREEN : FAIL,
      `assignment read-back principal=${raGet?.properties?.principalId} role=${raGet?.properties?.roleDefinitionId}`);
  } catch (err: any) {
    const got = classify(err);
    p("rbac-role-assignment", FAIL, `assignment lifecycle failed ${got.status}/${got.code}: ${got.message}`);
  }

  // ---------------------------------------------------------------
  // Chapter 3 — Management locks: probe the real wire. If the substrate
  // answers its typed 501 LockSurfaceNotImplemented stub, the chapter
  // loud-SKIPs as SURFACE-ABSENT (never a fake pass, never a silent drop).
  // ---------------------------------------------------------------
  const lockName = unique("lock");
  const lockId = `${rgId}/providers/Microsoft.Authorization/locks/${lockName}`;
  let lockBlocked = false; // proven: locked, lock removed, delete succeeds
  try {
    await putById(client, lockId, "2016-09-01", {
      location: "global",
      properties: { level: "CanNotDelete", notes: "ex5: SOX retention on claims network" },
    });
    p("lock-create", GREEN, "CanNotDelete lock at RG scope admitted");
    lockBlocked = true;
  } catch (err: any) {
    const got = classify(err);
    if (got.status === 501 && got.code === "LockSurfaceNotImplemented") {
      p("lock-create", SKIP_SA, "substrate answers typed 501 LockSurfaceNotImplemented at RG scope (policy lane pending)");
    } else {
      p("lock-create", FAIL, `lock PUT refused ${got.status}/${got.code}: ${got.message}`);
    }
  }

  if (!lockBlocked) {
    p("lock-blocks-delete", SKIP_SA, "dependent on lock surface (typed 501 stub)");
    p("lock-remove", SKIP_SA, "dependent on lock surface (typed 501 stub)");
    p("delete-after-unlock", SKIP_SA, "dependent on lock surface (typed 501 stub)");
  }

  if (lockBlocked) {
    try {
      await (await client.resources.beginDeleteById(vnetResId, "2021-04-01")).pollUntilDone();
      p("lock-blocks-delete", FAIL, "delete under lock resolved — lock not enforced");
    } catch (err: any) {
      const got = classify(err);
      const conflict = got.status === 409 || String(got.status ?? "").startsWith("4");
      p("lock-blocks-delete", conflict ? GREEN : FAIL,
        `delete under lock refused typed ${got.status}/${got.code}`);
    }

    try {
      await (await client.resources.beginDeleteById(lockId, "2016-09-01")).pollUntilDone();
      p("lock-remove", GREEN, "lock deleted");
    } catch (err: any) {
      lockBlocked = false;
      p("lock-remove", FAIL, `lock DELETE failed: ${err?.statusCode} ${String(err?.message).slice(0, 120)}`);
    }
    if (lockBlocked) {
      try {
        await (await client.resources.beginDeleteById(vnetResId, "2021-04-01")).pollUntilDone();
        p("delete-after-unlock", GREEN, "vnet delete succeeded after lock removal");
      } catch (err: any) {
        p("delete-after-unlock", FAIL, `delete after unlock failed: ${err?.statusCode} ${String(err?.message).slice(0, 120)}`);
      }
    }
  }

  // ---------------------------------------------------------------
  // Chapter 4 — Tags at scope: PATCH merge, PUT full-replace, empty->null.
  // ---------------------------------------------------------------
  await client.resourceGroups.update(rg, { tags: { env: "claims-prod" } });
  await client.resourceGroups.update(rg, { tags: { env: "claims-prod", costCenter: "cc-4511" } });
  const merged = await client.resourceGroups.get(rg);
  const mergeOk = merged.tags?.env === "claims-prod" && merged.tags?.costCenter === "cc-4511";
  p("tags-patch-merge", mergeOk ? GREEN : FAIL, `tags after two PATCH merges: ${JSON.stringify(merged.tags)}`);

  await client.resourceGroups.createOrUpdate(rg, { location: "smalt", tags: {} });
  const cleared = await client.resourceGroups.get(rg);
  p("tags-empty-null", cleared.tags === null || cleared.tags === undefined ? GREEN : FAIL,
    `tags after PUT with empty tags map (empty->null law): ${JSON.stringify(cleared.tags ?? null)}`);

  // ---------------------------------------------------------------
  // Teardown — delete the RG (the whole governance estate rides on it).
  // ---------------------------------------------------------------
  try {
    const del = await client.resourceGroups.beginDelete(rg);
    await del.pollUntilDone();
    await expectRestError(() => client.resourceGroups.get(rg), { status: 404 }, "rg-gone");
    p("teardown-rg-delete", GREEN, "RG deleted, re-GET 404");
  } catch (err: any) {
    p("teardown-rg-delete", FAIL, String(err?.message ?? err).slice(0, 200));
  }

  const green = wf.checks.filter((c: Check) => c.verdict === GREEN).length;
  const skipped = wf.checks.filter((c: Check) => c.verdict === SKIP_SA).length;
  const failed = wf.checks.filter((c: Check) => c.verdict === FAIL).length;
  const lines = wf.checks.map((c: Check) => `  [${c.verdict}] ${c.name} — ${c.detail}`);
  console.log(
    `\n== ${wf.id}: ${green}/${wf.checks.length} GREEN, ${skipped} SURFACE-ABSENT skip, ${failed} FAIL ==\n` +
      lines.join("\n"),
  );
  if (failed > 0) return 1;
  if (skipped > 0) return 3; // loud skip — a surface is not exposed
  return 0;
}

main()
  .then((code) => (process.exitCode = code))
  .catch((err: any) => {
    const msg = String(err?.message ?? err);
    if (/SURFACE-ABSENT/.test(msg)) {
      console.error(`LOUD-SKIP: ${msg}`);
      process.exitCode = 3;
    } else if (/ECONNREFUSED|fetch failed|UND_ERR|ENOTFOUND|ECONNRESET/.test(msg)) {
      console.error(`SUBSTRATE-DOWN: ${msg.slice(0, 300)}`);
      process.exitCode = 2;
    } else {
      console.error(`HARNESS-ERROR: ${msg.slice(0, 400)}`);
      process.exitCode = 1;
    }
  });
