# Receipt — ex8-saas-provisioning (lane ex8)

- Date: 2026-10-19
- Lane: ex8 (owns ONLY `/Users/sac/smalt/examples/saas-provisioning/**`)
- Subject: `bash examples/saas-provisioning/run.sh` against the shared
  canonical substrate (ARM :9443, TLS twin :9444, egress/Atlas :8443,
  enforce auth, smalt STS credential)
- Files: `index.ts`, `run.sh`, `README.md`, `receipt.md` (this file),
  `node_modules` symlink -> `verification/ts/node_modules` (pinned
  `@azure/arm-resources`, no installs)
- Standing: **PASS-with-XFAIL (ALIVE)** — 11/12 GREEN, 1 typed XFAIL
  (messaging-child generic by-id PUT, pre-registered wire law), 0 FAIL,
  0 SKIP, exit code 1 per the harness convention that an XFAIL leg means
  not-all-checks-pass.

## What ran

Real wire, official `@azure/arm-resources` (arm-resources v8 generic surface,
`beginCreateOrUpdateById` + `pollUntilDone`), raw Atlas v2 over the egress
plane with the substrate STS bearer, zero mocks, no fixed sleeps — the only
waits are SDK LRO pollers and `boundedPoll` on the cascade-404 observables.
Cascade delete convergence is observed, never timed.

## Final run output (verbatim, 2026-10-19)

```
== ex8-saas-provisioning: 11/12 GREEN, 1 XFAIL, 0 SKIP, 0 FAIL ==
  [GREEN] rg-create — tenant RG ex8-saas-rg-mvg8905xfde7 location=smalt
  [GREEN] storage-lro — storage account PUT -> LRO terminal provisioningState=Succeeded
  [GREEN] eventhub-namespace-lro — namespace LRO terminal provisioningState=Succeeded
  [XFAIL] eventhub-hub-lro — child by-id PUT refused 400 InvalidResourceShape ("at most one location") — messaging-child generic PUT plane in flight
  [GREEN] tags-patch-merge — tags after two PATCH merges: {"costCenter":"cc-saas-8","env":"prod","tenant":"mvg8905xfde7"}
  [GREEN] tags-empty-null — tags after PUT full-replace with empty tags: null
  [GREEN] atlas-entity-register — 3 entities minted; GET roundtrip guid=ab9dd43a-0380-4cb3-b3b7-fa4b76c2c1f0 typeName=Database
  [GREEN] atlas-lineage-edge — lineage/both depth=2 returned 2 relation(s); process edge d1e24ccc-597f-4596-ada3-7e9c5d52291a->84dc5b6c-4082-4343-9643-99be8ee605f5 present; map has 3 entities
  [GREEN] rg-delete-lro — RG beginDelete pollUntilDone terminal
  [GREEN] cascade-storage-404 — storage account ex8saasmvg8905xfde7 typed 404 after boundedPoll
  [GREEN] cascade-namespace-404 — namespace ex8-saas-ns-mvg8905xfde7 gone
  [GREEN] rg-gone-404 — re-GET after delete typed 404 ResourceGroupNotFound
```

Exit code: **1** (XFAIL leg present; summarize treats not-all-green as 1,
matching the ex1 bank-ledger convention).

## Goal coverage

1. **Full ARM LRO lifecycle — done, GREEN.** RG createOrUpdate; storage
   account and EventHub namespace via `beginCreateOrUpdateById` (202) ->
   `pollUntilDone` -> terminal `provisioningState=Succeeded`.
2. **Cascade delete — done, GREEN.** RG `beginDelete` LRO terminal; storage
   account and namespace each answer a typed 404 within `boundedPoll`
   (30s deadline, exponential backoff); RG re-GET typed 404
   `ResourceGroupNotFound`.
3. **Tags law — done, GREEN.** Two PATCH merges accumulate
   (`tenant`+`env`+`costCenter` all present); PUT with empty tags map
   renders `tags: null`.
4. **Atlas/lineage — done, GREEN (surface IS exposed).** Three entities
   minted (`Database`/`Process`/`Asset`, builtin typedefs), GET-by-guid
   roundtrip 200, `smalt_lineage` relationship 201 x2
   (store -> pipeline -> feed), and `GET /atlas/v2/lineage/both/<feed-guid>?depth=2`
   returns the process edge plus all 3 entities in `guidEntityMap`. No
   SURFACE-ABSENT skip was needed.

## Typed findings (honest, not failures of this harness)

1. **Event hub (child of namespace) create: XFAIL.** `PUT .../namespaces/<ns>/
   eventhubs/<hub>` via generic by-id LRO is refused 400
   `InvalidResourceShape` ("A resource payload may carry at most one
   location") — the same witnessed wire law the lane brief pre-registered
   for child-resource generic PUT. The namespace itself provisions fine and
   the tenant feed leg is exercised through Atlas lineage instead. Candidate
   for the KD register if not already rowed (evidence = this receipt).
2. **Atlas auth channel (witnessed, not a defect):** `/atlas/v2/*` on egress
   :8443 answers 401 tokenless and 200 with the substrate STS bearer — the
   harness carries the bearer on every Atlas call.
