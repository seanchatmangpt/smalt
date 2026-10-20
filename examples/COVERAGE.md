# examples/ coverage — Fortune-500 archetypes × KD/workflow cells

Generated 2026-10-19 by the examples/ wave (8 lanes, coordinator-integrated).
Every row below is grounded in the example's `receipt.md` (embedded run
output) and the KD register (`docs/jira/v26.10.19/KNOWN_DIVERGENCES.md` —
ground truth). "wfN" = `verification/ts/wfN` (+ `verification/py` mirror).

| Example | Checks | GREEN | Typed XFAIL/skip | Registered divergence | KD/workflow cells exercised |
|---|---|---|---|---|---|
| bank-ledger-nightly | 10 | 8 | 2 XFAIL (blob auth channel; child by-id PUT shape) | — | wf1 (arm LRO), wf4 (kv wrap/unwrap), wf2 (cosmos etag CAS; blob divergence), KD-102-era deletedkeys probe |
| retail-order-pipeline | 8 | 4 | 1 loud skip (scheduleMessage, KD-118) | 4 × KD-115 (SB plain-queue zero-delivery, differential vs wf3) | wf3 (eh partitions pinion, checkpoint CAS, cosmos), KD-115/116/118 |
| healthcare-archive | 17 | 15 | 2 XFAIL (deletedsecrets plane, KD-102) | — | wf2 (blob WORM/legal-hold/snapshot), KD-60 (`?sharesnapshot`), KD-102; ledger append+Merkle+409 dup |
| telco-event-grid | 10 | 8 | 1 skip (KQL `bin()` literal → SYN0002) | 1 FAIL: per-partition $Default receive NOT isolated (KD candidate, evidence in receipt) | wf3 (eh 200-event pinning), sentinel/kql summarize, resource-graph fleet query, diagnosticSettings/DCR ingest |
| insurance-governance | 19 | 15 | 4 skip (locks 501 LockSurfaceNotImplemented at witness time; custom RBAC roles GET-only) | RA `location` required (KD candidate) | wf1 (policy deny, PolicyViolation 400, exemptions lifecycle, initiatives, tags empty→null), KD-113 (RBAC/locks) |
| media-drm-custody | 8 | 5 | 1 XFAIL (deletedkeys, KD-102); 1 skip (SKR absent) | KD-119 reconfirmed (RS256 signs raw message; external node:crypto proof) | wf4 (kv sign/JWK), KD-14/KD-119 |
| fintech-throttle | 10 | 10 | — | — | wf5 (arm_rate_limit burst, Retry-After honored, typed-429-only), CBS claim-capacity 128 ceiling |
| saas-provisioning | 12 | 11 | 1 XFAIL (eventhub child by-id PUT shape) | — | wf1 (LRO 202→terminal, cascade delete, tags law), atlas lineage (`/atlas/v2/lineage/both`) |

## Cross-cutting wire laws witnessed (KD-register candidates where unregistered)

1. ARM generic by-id PUT for child resources refused 400 `InvalidResourceShape`
   ("at most one location") — bank-ledger (container), saas-provisioning
   (eventhub child). Consistent across two independent lanes.
2. Role-assignment / SB queue payloads require top-level `location` —
   insurance-governance, fintech-throttle. Divergence class vs real Azure.
3. RS256 sign input polarity (raw message, not submitted digest) — KD-119,
   externally reconfirmed from TS (media-drm-custody).
4. EH per-partition consumer isolation absent (both $Default per-partition
   subscriptions deliver all events) — telco-event-grid, evidence-backed
   FAIL; not yet a KD row (coordinator: register via kd-registrar).
5. KQL `bin()` literal unsupported (SYN0002); collector-side `timeBin` column
   equivalent green — telco-event-grid.
6. `?sharesnapshot` frozen-read arm (KD-60) reconfirmed byte-exact —
   healthcare-archive.

## Flip log (capability commit 8ca1b82 landed mid-wave)

KV deleted-keys plane + secrets backup/restore + RBAC/locks landed in-tree
in commit `8ca1b82` DURING the wave (that commit also absorbed the examples
tree — lane files and `_WAVE.md` are tracked as of it). Flip attempt,
2026-10-19 integration window:

- Rebooted the canonical substrate twice (`just substrate-up`, fresh
  compile) and re-ran all 8 harnesses. Verdict: `GET /deletedkeys/:name`
  and `GET /deletedsecrets` still answer **404**, RG-scope locks still
  answer **501 `LockSurfaceNotImplemented`**
  (`lib/smalt/arm_gateway/router.ex:982`) on every beam observed —
  the routes exist in `lib/smalt/egress_router.ex` (get "/deletedkeys",
  unconditional) but no observed beam served them.
- Therefore the typed XFAILs **stay** (never faked): healthcare-archive
  (deletedsecrets), media-drm-custody (deletedkeys), insurance-governance
  (locks). Each receipt carries the integration note below.
- Confounder disclosed: an outside actor (capability wave) cycled the
  shared substrate repeatedly during the flip window (beam pids
  73748→18405→93219→96406→98110, SIGTERMs in
  `/tmp/smalt-substrate-state/substrate.log`), so flip verdicts are
  as-of-beam, not as-of-tree. Close condition unchanged: the flips activate
  the first time a serving beam answers `/deletedkeys` 200-shape; the
  pre-coded assertions are already in all three harnesses.
