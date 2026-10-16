# Enclave Testbed — v26.10.14 Composite Validation Receipt

**FINAL: 9/9 PASS (2026-10-15, post-disposition rerun; ENCLAVE-1 RESOLVED-INVALID — see disposition section at bottom)**

Lane: ENCLAVE TESTBED. Subject: `/Users/sac/smalt` @ main (tree
`3fc2543` + in-flight v26.10.14 wave). Driver:
`test/enclave-testbed/enclave_testbed.exs` via
`test/enclave-testbed/run.sh` (log: `tmp/enclave-testbed.log`).

## Result: 8 PASS / 1 FAIL (defect FILED, not patched)

Boot: `mix run --no-start` boots the full `Smalt.Application` once
(Store, broker, endpoints). The enclave run uses a DEDICATED substrate on
private ports 29440-29444 under lock `/tmp/smalt-substrate-enclave.lock`
(the shared `/tmp/smalt-substrate.lock` was held ~40 min by another lane's
soak; the enclave never touches default ports 8443/9443/5672 so it stays
out of concurrent lanes' way).

| phase | verdict | evidence |
|---|---|---|
| A: SKR attest→release→replay | PASS | MAA attest (RS256 token, 795 B) → release 200 `transport=plain value len=43`, `keyMaterialVersion` 1→2; same key+policy releases deterministic material; jti replay → **403 TokenReplay**; no-bearer → **403 UnauthorizedAttestation**; non-exportable → **400 KeyNotExportable**; missing → **404 KeyNotFound**; hostile name (atom) → **400 InvalidParameter**; hostile measurement → 400 `attestationFailedVerdict` |
| B: WORM legal hold + immutability | **FAIL (filed)** | hold blocks overwrite+delete (409 `ContainerLocked`), lock requires `If-Match: "*"` (412 without), retention expiry via injected clock unlocks container — all correct. **FINDING ENCLAVE-1 below.** |
| C: Confidential Ledger | PASS | 25 appends (`1.1`→`25.1`), dup contents → **409 LedgerItemAlreadyExists**; independent re-derivation of the Merkle chain (zero-root head, `prev_hash == prev merkle_root`, `sha256(prev_hash <> data_hash) == merkle_root`) verified all 25; tampering one persisted `data_hash` → chain verify **fails**; hostile ledger name → **400 InvalidLedgerName**, hostile tx-id → typed `:error` |
| D: Governance | PASS | Purview: 3 entities, 2-hop lineage (2 relations, 3-node guidEntityMap), bad direction → 400 ATLAS-400-00-001. Sentinel: DCR ingest **204** + strict-mode `{:dcr_created, dcr}` marker written by the lib itself; KQL `take` (2 rows) and `where level == 'err' \| project msg` → `[["boom"]]`; wrong api-version → 400. Resource Graph: 3/3 cross-subscription rows, hostile subscriptions shape → **400 InvalidParameter**, unknown KQL pipeline → **400 BadQuery**, bare word admitted as documented table-ref passthrough, bad api-version → 400 |
| E1: Cosmos at scale | PASS | 500-doc container (5 partitions, 201 each); cross-partition `select * from c` walked **500 docs in 5 continuation pages** (limit 100/page); pk-scoped query 100 docs; **forged `x-ms-continuation` → typed 400** (never silent all-docs) |
| E2: ARM LRO + sweeper | PASS | 50 background PUTs (delay 15 ms) → at-rest `Sweeper.sweep_now/0` drove **50/50 to terminal Succeeded**; second sweep idempotent (zero regressions) |
| F1: SB sessions + DLQ | PASS | `session_acquire` first claimant wins, second → **`{:error, :already_locked}`**; locked msg skipped, session's next message delivered sequentially, drain → `:empty`; deadletter stamps `DeadLetterReason`/`DeadLetterErrorDescription` + custom props (`EnclaveProbe=F1`) preserved on the DLQ record (app-props form per `serviceBusMessage.js` parity) |
| F2: EH contention + CAS | PASS | 50 events delivered in order while a consumer CAS'd checkpoints under the producer (one benign typed conflict logged); 2-racer CAS with equal expect → **exactly 1 `:ok`, 1 `{:error, :conflict}`** |
| F3: chaos — sweeper child kill | PASS | `Process.exit(Sweeper, :kill)` mid-run → supervisor restart (new pid within 10 s), `sweep_now` serves again; post-kill LRO converges and ledger appends — **substrate kept serving** |

## Filed defects (not patched)

### ENCLAVE-1 — put_blob CREATE path bypasses the WORM gate

- **Where**: `lib/smalt/data_plane/blob_storage.ex`, `put_blob/6` —
  `worm_blocked?/3` is consulted only on the **overwrite** branch (blob
  exists); the `:error` branch (blob absent) checks only `If-Match`.
- **Witness** (reproducible, 2 consecutive runs): container under an
  ACTIVE legal hold; after the retention-expiry delete, `put_blob` with
  content `"v4"` at `now = created_at + 30 days` returned
  `{:ok, blob(content: "v4")}` — **admitted under the hold**. The
  overwrite refusals (`{:error, :worm_locked, ...}`) on the same container
  fired correctly moments earlier, isolating the gate to the create branch.
- **Expected**: real Azure refuses Put Blob in a container with a legal
  hold or locked immutability policy regardless of blob existence
  (409 `ContainerLocked`).
- **Suggested fix shape**: hoist the `worm_blocked?(container_meta, "put",
  now)` check above the exists/absent `case` in `put_blob/6`.
- **Owner**: blob lane. Phase B is recorded FAIL until this lands; rerun
  `bash test/enclave-testbed/run.sh` — the finding text flips to
  "legal hold survives retention expiry (create path gated)" when fixed.

## Script-bug iterations (mine, not lib defects)

Compile shapes, return-arity mismatches (put_blob 2-tuple, delete 4-tuple,
dequeue 3-tuple, RG 3-tuple, sentinel ingest/4, Purview module name
`Smalt.DataPlane.Purview`), ledger hex-case (engine emits lowercase hex
roots), CAS zero-checkpoint form `%{"seq"=>0,"offset"=>0,"etag"=>0}`, and
the documented RG bare-word passthrough. All fixed in the driver; zero lib
edits made.

## How to rerun

```sh
bash test/enclave-testbed/run.sh   # exit 0 = all phases PASS
```

Phase B remains FAIL by design until ENCLAVE-1 is fixed (typed finding in
the summary; exit 1).

---
## ENCLAVE-1 DISPOSITION (coordinator, 2026-10-15): RESOLVED-INVALID

The finding asserted put_blob's CREATE path must refuse under legal hold /
locked immutability policy. Real Azure immutable storage permits writing NEW
blobs into a locked/legal-hold container ("Once a container is in the Locked
state, new blobs can be written into it"; legal hold likewise permits new
writes) — that is how WORM containers are populated. Only overwrite/delete of
EXISTING blobs are refused (409 ContainerLocked), which smalt already did and
test/data_plane/blob_hardening_test.exs (91/0) pins.

Actions: reverted the coordinator's initial hoist fix (it broke 6 legitimate
create-under-WORM pins); phase B re-cut to the Azure-correct law (create
ADMITTED, overwrite/delete/purge REFUSED under active hold); testbed rerun:
**9 phases, 9 PASS** (witnessed 2026-10-15, run.sh exit 0).
