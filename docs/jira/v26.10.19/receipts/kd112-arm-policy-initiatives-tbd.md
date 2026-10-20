# kd112-arm-policy-initiatives-tbd.md — evidence receipt (kd-lane, 2026-10-19)

- **KD row**: KD-112 (policy initiatives/exemptions absent)
- **Standing**: PASS-EVIDENCED (module-tier witness + routes wired and live; SDK-tier PolicyClient probe not yet run)
- **Context**: solo

## LANDED: routes wired + live witness

### 1. Routes wired into the ARM gateway (commit c41e8ae)

Commit `c41e8ae` ("feat(arm): policy exemptions+initiatives routes, X-ARR plug,
crash-envelope, ResourceGraph route, throttle repair (WO-03/WO-15/KD-112)") wired the
routes into `lib/smalt/arm_gateway/router.ex` (+364 lines alongside policy.ex +350):
`put/get/list/delete` for
`/subscriptions/:sub_id/providers/Microsoft.Authorization/policyExemptions[...]`
(subscription AND resourceGroup scopes) and
`/subscriptions/:sub_id/providers/Microsoft.Authorization/policySetDefinitions[...]`.
FINAL.md §7 confirms: "KD-112 exemptions/initiatives routes landed (c41e8ae)".

### 2. Module-tier live witness (PASS)

Sibling receipt `kd112-policy-exemptions-initiatives.md` (policy.ex lane, standing
**PASS**, context full) carries the real witness output: exemption put → enforce skip +
`smaltReceiptType: "policyExemption"` receipt; expired exemption still denies;
`PolicyExemptionInvalid` / `PolicySetDefinitionInvalid` typed refusals; initiative
assignment resolving through the set with worst-effect-wins across members (deny-west +
deny-east deny, central `:ok`); get/list/delete roundtrips all as-specified. Two
in-witness defects fixed forward (string-effect normalization, verdict-tuple Access.get).

### 3. Wire-tier

No curl/SDK-tier transcript of the wired routes exists in this window (the
route-table block in the sibling receipt was written for the coordinator BEFORE wiring;
commit c41e8ae is the wiring). The skeleton falsifier — SDK `PolicyClient` initiative
create/list + exemption create — has not run. The 404 that originally minted the row is
gone at the route layer (c41e8ae), but the closing falsifier is unexecuted.

## Standing rationale

Witnessed at the module tier (PASS receipt, real output) and wired at the route tier
(c41e8ae); **row stays OPEN** until the SDK-tier falsifier (PolicyClient initiative
create/list + exemption create succeed) lands a closing receipt. Registrar may
downgrade the divergence prose or flip only on that receipt.

## Cross-links

- `kd112-policy-exemptions-initiatives.md` (module-tier witness, PASS)
- `v261019-12-court-x2-close.md` / FINAL.md §7 (route-landing pointer)
- kd105/kd107/kd109/kd110/kd111 evidence receipts in this directory.
