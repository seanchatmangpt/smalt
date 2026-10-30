# 33 Compatibility Pin: courtroom-platform-az ↔ smalt (POSH provider)

Status: PARTIAL — spec only this session; no pin file, no gate executed. The
pin file itself lives in the substrate tree (smalt owns the registry tops);
the consumer-side arm is the posh-court gate. Closes S8 of
`gaps/24-cross-repo-skew.md`.

## Law

One compat pin, one writer, one consumer. The pin is the single durable
statement of the cross-repo coupling; both trees' constants are projections
of it. A registry-top or provider-constant change that skips the pin fails
the gate (exit 1) instead of landing silently. This is the mechanical arm of
GAP5(b) — referenced, not duplicated (smalt
`docs/jira/posh/v26.10.30/gaps/05-ci-cd.md` row b).

## File: `/Users/sac/smalt/compat-pin.ttl`

RDF-first (house law: canonical graph → generated artifacts; hand-edited YAML
is the O(N²) drift form). One file, substrate-owned (smalt is the
authoritative side — it holds the registry tops the provider must stay ≤).

Sketch:

```turtle
@prefix pin:  <https://smalt.dev/compat-pin#> .
@prefix reg:  <https://smalt.dev/registry#> .
@prefix prov: <https://smalt.dev/provider#> .

<https://smalt.dev/compat-pin> a pin:CompatibilityPin ;
    pin:clusterName "smalt" ;                 # S5: kind cluster name
    pin:terraformFloor "1.14" ;               # S6: posh path floor
    pin:providerContract
        [ pin:resources "12" ; pin:dataSources "7" ] ;  # binary surface
    pin:apiVersion [
        pin:type "Microsoft.ContainerRegistry/registries" ;
        pin:version "2023-06-01" ;            # S1: aligned, no fallback
    ] , [
        pin:type "Microsoft.App/containerApps" ;
        pin:version "2024-03-01" ;            # S3: 400-fallback to 2023-05-01
        pin:fallback "2023-05-01" ;
    ] , [
        pin:type "Microsoft.App/managedEnvironments" ;
        pin:version "2024-03-01" ;            # S3
        pin:fallback "2023-05-01" ;
    ] , [
        pin:type "Microsoft.KeyVault/vaults" ; pin:version "2023-07-01" ;
    ] , [
        pin:type "Microsoft.KeyVault/vaults/secrets" ; pin:version "2023-07-01" ;
    ] , [
        pin:type "Microsoft.ManagedIdentity/userAssignedIdentities" ;
        pin:version "2023-04-01" ;
    ] , [
        pin:type "Microsoft.Authorization/roleAssignments" ;
        pin:version "2022-04-01" ;
    ] ;
    pin:payloadLaw
        [ pin:shape "managedEnvironmentId" ; pin:law "dual-key set" ] ,
        [ pin:shape "resources.memory" ; pin:law "numeric on wire" ] ,
        [ pin:shape "location" ; pin:law "always set, kv-secret incl." ] .
```

### Why .ttl not .yaml

YAML pin = second serialization of registry.ex's `@api_versions` map — two
sources of truth, O(N²) drift (dfcm law). TTL keeps one graph: `compat-pin.ttl`
cross-links `reg:` individuals to (a future projection of)
`lib/smalt/registry.ex` tops; the gate diffs graph-vs-code, not yaml-vs-code.

Long form (if the team prefers YAML): same keys, but the gate must carry an
explicit "pin ⊑ registry" subsumption check so the pin can never claim a top
the registry does not have.

## Contents (authoritative sources)

| Pin entry | Authoritative source (re-read at gate time) | Today's value |
|---|---|---|
| per-type api-version | smalt `lib/smalt/registry.ex` `@api_versions` (tops) × provider `internal/provider/*.go` constants (sent) | see gaps/24 matrix; ACR = 2023-06-01 aligned (`resource_remaining_v1.go:1612`); containerApp/CAE 2024-03-01 first + `2023-05-01` fallback (`resource_container_app.go:29-30`, `resource_container_app_environment.go:25-26`) |
| cluster name | smalt `k8s/kind-config.yaml:19` | `smalt` |
| TF floor | posh stage requirements | `>= 1.14` |
| provider binary contract | `internal/provider/server.go` `Resources()` / `DataSources()` dedup counts | 12 resources / 7 data sources |
| payload-shape laws | smalt `lib/smalt/arm_gateway/providers/container_apps.ex` | `managedEnvironmentId` dual-key; memory numeric on wire; `location` always set (kv-secret incl.) |

## Consumer: posh-court compat-pin stage

New named stage in smalt `justfile.d/58-posh.just` (7-stage ladder), after
install, before plan-against-smalt:

Contract:

- Inputs (re-read from disk at gate time, never from the pin's own claims):
  - pin graph: `/Users/sac/smalt/compat-pin.ttl` (parse with rdflib/ggen)
  - registry tops: `smalt/lib/smalt/registry.ex` `@api_versions` (parse)
  - provider constants: grep-able `const <name> = "YYYY-MM-DD"` in
    `internal/provider/*.go`
  - surface counts: `go test ./internal/provider -run TestProviderResourcesAndDataSources`
    (real binary census, not a literal count)
  - consumer TF: `courtroom-platform-az/infra/**/versions.tf`
- Checks (each independently typed, exit 1 on any):
  1. pin api-version per type == registry top or registered-fallback ≤ top
  2. provider constant == pin entry (per type)
  3. surface counts == pin (12 resources / 7 data sources)
  4. TF floor: courtroom `required_version >= 1.14` on the posh path
  5. cluster name `smalt` present in courtroom README (S5 close witness)
  6. payload laws: provider memory coercion + kv-secret `location` covered by
     existing provider tests passing (live_f4_test.go wires already assert
     numeric memory on the wire)
- Output: `compat-pin` verdict line; exit 0 green / 1 FAIL / 3 SKIP (ladder
  contract), same as other stages.

### Non-vacuity (court must be able to fail)

Mutation court, same shape as the shim courts: on a temp copy of the pin, bump
one entry wrongly (ACR → `2024-03-01`) → gate MUST exit 1 (`PIN-REGISTRY-SKEW`);
revert (sha256 byte-exact restore). A gate that accepts the mutated pin exits 1
itself as `VACUOUS GATE`. Also mutate provider constant in a scratch checkout
of the provider → gate MUST flip for the provider side.

## Open arms

- GAP5(b) cross-repo CI gate is the consumer-side CI arm, open by design;
  the posh-court stage above is the local mechanical arm — same pin, same
  checks, different trigger.
- S2 (`azurerm_role_definition` unregistered) is NOT a pin row — it is a
  registry UNSUPPORTED, tracked in smalt gap 01. The gate loud-fails it via
  check 2 (no pin row ⇒ provider must not register it as supported) — or it
  stays a separate plan-gate guard per gaps/24 S2.
