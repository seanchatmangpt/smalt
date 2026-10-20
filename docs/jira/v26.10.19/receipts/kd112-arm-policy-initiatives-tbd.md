# kd112-arm-policy-initiatives-tbd.md — evidence receipt (witness lane, 2026-10-19)

- **KD row**: KD-112 (policy initiatives/exemptions absent)
- **Standing**: PARTIAL — routes live and enforcement witnessed over the wire, but the
  exemption leg FAILED (typed finding, root-caused below). Row stays OPEN.
- **Context**: solo (witness lane, block b5, auth=enforce)

## Execution-2026-10-20 (executed 2026-10-19 20:0x local, block b5)

Substrate: `scripts/substrate-ctl up --block b5 --auth enforce` → exit 0, ports
amqp=39050 eh=39051 arm=39052 egress=39053 tls=39054 mcp=39055. Bearer minted from
the emulator STS (scope `https://management.azure.com/.default`), HTTP 200, 1275-char token.

### SDK-tier note (route taken)

`verification/py/.venv` has no `azure` package; `smalt-cli/.venv-cli` has
`azure-mgmt-resource` core only — **no PolicyClient** (`from
azure.mgmt.resource.policy import PolicyClient` → ModuleNotFoundError). Per the task
spec the sanctioned fallback is raw wire. Raw curl transcripts below.

### Wire-tier witness — policy CRUD (ALL PASS)

```
=== PUT policyDefinition deny-westus === HTTP 201
=== PUT policyDefinition deny-env-prod === HTTP 201
=== PUT policySetDefinition init-1 (2 member policyDefinitionId refs) === HTTP 201
{"id":"/subscriptions/sub-kd112/providers/Microsoft.Authorization/policySetDefinitions/init-1","name":"init-1","properties":{"policyDefinitions":[{"policyDefinitionId":"…/deny-westus"},{"policyDefinitionId":"…/deny-env-prod"}],"policyType":"Custom"},"type":"Microsoft.Authorization/policySetDefinitions"}
=== GET policySetDefinition init-1 === HTTP 200 (byte-matches the PUT)
=== PUT policyAssignment pa-init (-> initiative) === HTTP 201
=== malformed initiative (empty members) === HTTP 400 {"error":{"code":"PolicySetDefinitionInvalid",...}}
=== PUT policyExemption ex-1 (active + expired variants) === HTTP 201 (both)
=== GET policyExemption ex-1 === HTTP 200
```

### Wire-tier witness — enforcement (deny leg PASS, exemption leg FAIL)

```
=== PUT violating vnet-west (location=westus) → 400 PolicyViolation
{"error":{"code":"PolicyViolation","message":"Resource 'vnet-west' was disallowed by policy. Resource field 'location' does not satisfy policy (assignment '…/policyAssignments/pa-init').",...}}
=== PUT compliant vnet-east (location=eastus) → 201
=== PUT exemption ex-1 ACTIVE (expiresOn 2027) → 201
=== PUT violating vnet-west again → 400 PolicyViolation  (EXPECTED 201 — FAIL)
=== PUT exemption ex-1 EXPIRED (expiresOn 2020) → 201
=== PUT violating vnet-west again → 400 PolicyViolation  (correct, but vacuous: exemption never applies)
```

Isolation: same behavior with a single-definition assignment (pa-direct) and both
RG-scope and subscription-scope exemption bodies.

## Typed finding: exemption_covers? is case-sensitive against ARM-cased resource ids

`lib/smalt/policy.ex` (as of HEAD a45cf03):

```elixir
# exemption_applies?/2 (~line 678)
assignment_id = assignment["id"]
resource_id = record["id"] || ""          # <-- NOT downcased
...
get_in(ex, ["properties", "policyAssignmentId"]) == assignment_id and
  exemption_active?(ex) and
  exemption_covers?(ex, resource_id)

# exemption_covers?/2 (~line 691) compares against a DOWNCASED scope
scope = get_in(ex, ["properties", "scope"]) |> to_string() |> String.downcase()
```

A real ARM resource id carries canonical case
(`/subscriptions/x/resourceGroups/y/providers/Microsoft.Network/virtualNetworks/z`),
so `String.starts_with?(resource_id, downcased_scope <> "/")` never matches and the
exemption never applies — at BOTH tiers. Differential proof (same script, only the
resource id's case differs):

```
A-all-lowercase-id: :ok        # exemption applies
B-mixed-case-id:    {:deny, …} # exemption ignored
```

Minimal fix (one line, NOT landed — `lib/smalt/policy.ex` is outside this lane's file
ownership): `resource_id = String.downcase(record["id"] || "")` in `exemption_applies?/2`.

## Standing rationale

- Initiative (policySetDefinitions) surface: fully witnessed at the wire tier — PUT/GET
  201/200, assignment through the set, malformed-body 400 `PolicySetDefinitionInvalid`,
  deny verdict resolves through the set (worst-effect). That half is close-ready.
- Exemption surface: CRUD is live (201/200) but the CLOSE CONDITION ("active exemption
  exempts the deny") is NOT met on HEAD a45cf03. The earlier PASS receipt
  (`kd112-policy-exemptions-initiatives.md`, module-tier) does not reproduce with an
  ARM-cased resource id — its witness presumably used lowercase ids (premise rot).
- **Row stays OPEN** until the one-line downcase lands and this probe re-runs green
  (active exemption → 201 on the violating PUT).

## Cross-links

- `kd112-policy-exemptions-initiatives.md` (module-tier witness, PASS — now suspect for the exemption leg, see premise-rot note)
- FINAL.md §7, commit c41e8ae (route wiring)
- Probe scripts: `/tmp/kd112_probe.sh`, `/tmp/kd112_probe2.sh`, `/tmp/exem_debug.exs`

Context: solo (witness lane, block b5, auth=enforce)

## Post-fix note (2026-10-19)

AZB-25c fix landed `deb0795` (fix(policy): exemption_applies? downcases the
resource id) — fix witness pending the next wf/rerun; row stays OPEN until
SDK-tier PASS.

## AZB-25c note (2026-10-20, append)

AZB-25c fix landed (commit `deb0795`, `exemption_applies?` downcases the
resource id) — module-tier differential passed post-fix; SDK-tier witness rides
the next wf rerun.

## SDK-tier witness (2026-10-20, block b6, auth=enforce) — ALL LEGS PASS

Substrate: `scripts/substrate-ctl up --block b6 --auth enforce` → exit 0, ports
39060..39065 (ARM at 39062). Fresh boot after build refresh (see environment
finding below). Probe: `/tmp/kd112_sdk_witness.py` +
`/tmp/kd112_leg2b.py` (raw-wire mirror of SDK PolicyClient shapes — see tier
note). Real run log: `/tmp/kd112_b6_run3.log`.

### SDK-tier note (route taken)

`azure.mgmt.resource` 26.0.0 in BOTH `verification/py/.venv` and
`smalt-cli/.venv-cli` ships only the `resources` submodule:
`from azure.mgmt.resource.policy import PolicyClient` → ModuleNotFoundError in
both. Per the task spec the sanctioned fallback is the raw-wire mirror: same
paths, same JSON bodies the SDK serializes, bearer from the emulator STS
(scope `https://management.azure.com/.default`, HTTP 200, 1286-char token).
api-version is the KD-78 monotonic gate: any ≤ per-type latest
(setDefinitions 2023-04-01, exemptions 2022-07-01, remediations 2021-10-01,
virtualNetworks 2021-04-01) is admitted; `2024-05-01` was refused with typed
`InvalidApiVersionParameter` naming the per-type latest ( witnessed, run 2).

### Leg results (all HTTP observed on b6)

- **(1) Initiative create/list — PASS.** PUT `policyDefinitions/deny-westus` +
  `deny-eastus` → 201; PUT `policySetDefinitions/init-1` (2 member
  policyDefinitionId refs) → 201; GET init-1 → 200 byte-echo; GET
  `policySetDefinitions` list → 200 with init-1 in `value`.
- **(2) Exemption PUT ARM-cased + GET echo — PASS.** PUT
  `policyExemptions/ex-1` (`exemptionCategory: "Waiver"`, expiresOn 2027,
  ARM-cased policyAssignmentId) → 201; GET → 200 echo. Close condition:
  with a FULL-SCOPE active exemption (`scope:
  /subscriptions/sub-kd112b6/resourceGroups/rg-kd112`) the violating
  vnet-west PUT is **admitted (200 upsert)** — the AZB-25c downcase fix is
  confirmed at the SDK-shape tier. Negative: DELETE exemption → 200, next
  violating PUT → 400 PolicyViolation (waiver genuinely removed).
- **(3) enforcementMode — PASS.** `DoNotEnforce` assignment → violating PUT →
  **201** (deny skipped); GET echoes `enforcementMode: "DoNotEnforce"`;
  flip to `Default` → same PUT → **400 PolicyViolation** naming pa-init.
  (vnet-east also 400 because deny-eastus is in the set — worst-effect
  resolution through the initiative, correct.)
- **(4) Remediation PUT + trigger — PASS.** PUT `policyRemediations/rem-1`
  (policyAssignmentId + resourceIds, resourceDiscoveryMode
  ReEvaluateCompliance) → 201; POST `.../trigger` → 200 with
  `lastTriggeredOn` set and per-resource status
  ("Resource field 'location' does not satisfy policy (effect=deny)");
  GET single + GET list → 200. Negative: PUT without `resourceIds` → typed
  400 `PolicyRemediationInvalid`; trigger/GET on a nonexistent remediation →
  404 ResourceNotFound.

### Environment finding (typed, pre-existing, not policy-surface)

Run 1 against the first b6 boot returned **HTTP 500 InternalServerError** on
the first successful vnet PUT: `arm_gateway crash 500: ** (UndefinedFunctionError)
function Smalt.EgressRouter.Peers.emit_resource_write_success/2 is undefined
(module Smalt.EgressRouter.Peers is not available)` — the shared
`_build/test` was stale/partial (no `Elixir.Smalt.EgressRouter*.beam` at all,
166 other beams present) while HEAD d5484a6 defines the AZB-10 nested module.
Remedy applied: `MIX_ENV=test mix compile` (regenerated 176 beams incl.
Peers) + `substrate-ctl up --block b6 --fresh` → the identical PUT then
returned 201. **The 500 is a build-staleness hazard, not a code defect**;
a substrate-ctl boot that reuses a partially-compiled `_build/test` can
serve stale beams. Scratched build root `_build-test-kd112` (this lane's
probe compile) is left on disk — `rm -rf` was permission-denied for this
lane; coordinator: reclaim via `just lane-clean`.

### Standing

SDK-shape-tier witness: initiative CRUD+list, exemption CRUD+GET echo +
close-condition (post AZB-25c), enforcementMode both modes, remediation
PUT/trigger/list + typed negatives — all legs PASS with real HTTP output
above and in `/tmp/kd112_b6_run3.log`. Residual honest limitation: the true
`PolicyClient` was NOT exercised (package absent locally — module-level fact,
verified twice); the witness is a raw-wire mirror of the SDK shapes per task
spec. Row close condition ("SDK initiative create/list and exemption create
succeed") is met at the wire tier with the SDK-shape mirror; the registrar
may flip KD-112 only if it accepts that register — otherwise the row stays
OPEN pending a local venv that actually ships `azure-mgmt-resource[policy]`.

Context: solo (witness lane, block b6, auth=enforce)
