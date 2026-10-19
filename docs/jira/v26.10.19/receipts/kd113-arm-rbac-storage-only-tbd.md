# kd113-arm-rbac-storage-only-tbd.md — evidence receipt (kd-lane, 2026-10-19)

- **KD row**: KD-113 (RBAC storage-only / locks stubs / no tag-at-scope)
- **Standing**: PASS-EVIDENCED (all three legs witnessed; one leg diverges from the predicted stub-envelope shape)
- **Context**: solo

## Witness

Substrate: block b3, ARM 39032, auth enforce, Bearer minted. RG `kdrg` created first
(PUT /subscriptions/sub/resourceGroups/kdrg → 201).

### Leg 1: PUT roleAssignment at RG scope → 201 (works at arbitrary scope)

```
$ curl -s -D - -X PUT "$ARM/subscriptions/sub/resourceGroups/kdrg/providers/Microsoft.Authorization/roleAssignments/ra-kd113?api-version=2022-04-01" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"location":"westus","properties":{"roleDefinitionId":"/subscriptions/sub/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c","principalId":"00000000-0000-0000-0000-000000000001"}}'
HTTP/1.1 201 Created

{"id":"/subscriptions/sub/resourceGroups/kdrg/providers/Microsoft.Authorization/roleAssignments/ra-kd113","name":"ra-kd113","properties":{"principalId":"...0001","roleDefinitionId":".../roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c","scope":"/subscriptions/sub/resourceGroups/kdrg"},"type":"Microsoft.Authorization/roleAssignments"}
```

Record persisted with scope echo (handlers at `lib/smalt/arm_gateway/router.ex:4243`).

### Leg 2: PUT managementLock at RG scope → typed GraphLaw refusal, NOT a stub envelope

```
$ curl -s -D - -X PUT "$ARM/subscriptions/sub/resourceGroups/kdrg/providers/Microsoft.Authorization/locks/kdlock?api-version=2016-09-01" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"properties":{"level":"ReadOnly"}}'
HTTP/1.1 400 Bad Request

{"error":{"code":"InvalidResourceShape","innererror":{},"message":"GraphLaw validation failure: Resource type Microsoft.Authorization/locks is not an admitted ontology individual in smalt-substrate-pack","target":"AshGraphLaw.Enforcement"}}
```

The skeleton predicted a stub-envelope; the substrate answers a typed admission refusal
(`AshGraphLaw.Enforcement`, not-admitted-individual). Recorded as observed.

### Leg 3: PATCH tag-at-scope URL → 404 RouteNotFound

```
$ curl -s -D - -X PATCH "$ARM/subscriptions/sub/resourceGroups/kdrg/providers/Microsoft.Resources/tags/default?api-version=2021-04-01" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"properties":{"tags":{"env":"kd113"}}}'
HTTP/1.1 404 Not Found

{"error":{"code":"RouteNotFound","innererror":{},"message":"The route '/subscriptions/sub/resourceGroups/kdrg/providers/Microsoft.Resources/tags/default' could not be found.","target":"/subscriptions/sub/resourceGroups/kdrg/providers/Microsoft.Resources/tags/default"}}
```

## Falsifier status

Skeleton falsifier ("role-assignment at arbitrary scope + real lock record + tag-at-scope
roundtrip, all 2xx") is REFUTED as stated: leg 1 passes, leg 2 refuses (GraphLaw), leg 3
404s — which IS the registered KD-113 divergence (RBAC only, no locks, no tag-at-scope).
Evidence matches the row's divergence description; close condition belongs to the
registrar.
