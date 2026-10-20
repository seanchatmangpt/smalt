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
