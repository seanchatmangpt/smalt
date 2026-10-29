# ex8 — Multi-tenant SaaS provisioning

Fortune-500 archetype: a SaaS platform onboards a new tenant end-to-end on
the smalt substrate — and off-boards them just as completely.

## The story

A SaaS company sells to a new enterprise customer. Onboarding cuts the
tenant's Azure footprint from a single ARM resource group:

1. **Provision (control plane)** — the tenant resource group is created, then
   the tenant store (storage account) and the tenant feed (EventHub
   namespace) are walked through real ARM long-running operations:
   `beginCreateOrUpdateById` returns a poller on the 202, and
   `pollUntilDone` drives each to a terminal `provisioningState=Succeeded`.
2. **Tag for cost allocation** — the tenant's tags are PATCH-merged over
   time (`tenant`, `env`, `costCenter` accumulate — the merge law), and a
   full-replace PUT with an empty tags map clears them to `null` (the
   empty->null law), exactly how FinOps tooling expects ARM tags to behave.
3. **Register the data estate (governance)** — the tenant's store, the
   provisioning pipeline, and the feed are minted as Purview Atlas entities
   (`Database`, `Process`, `Asset`) on the catalog's `/atlas/v2` face, with
   `smalt_lineage` process edges store -> pipeline -> feed. A lineage query
   (`GET /atlas/v2/lineage/both/:guid?depth=2`) must return the process edge —
   if the catalog cannot answer "where does this tenant's data flow from",
   governance does not exist.
4. **Off-board (cascade delete)** — deleting the resource group runs as an
   LRO; every child resource (storage account, namespace) must answer a
   typed 404 within a bounded poll. A tenant that outlives its RG is a
   compliance incident.

## Run

```bash
bash examples/saas-provisioning/run.sh
```

Endpoints default to the canonical substrate (ARM STS :9443, SDKs ride the
TLS twin :9444, Atlas egress :8443) and are env-overridable
(`SMALT_ARM`, `SMALT_ARM_TLS`, `SMALT_EGRESS`). Exit contract:
0 pass / 1 fail (XFAIL present also exits 1) / 2 substrate down / 3 loud skip.

## Wire laws this harness rides

- Storage/namespace LRO via generic by-id PUT + `pollUntilDone` (ARM
  2021-04-01 / 2022-10-01-preview laws).
- Messaging-child (event hubs) generic by-id PUT is refused 400
  `InvalidResourceShape` ("at most one location") — typed XFAIL, never a
  silent pass.
- Tags: PATCH merge accumulates; PUT with empty tags -> `null`.
- Atlas v2 on egress requires the substrate STS bearer (401 tokenless).
