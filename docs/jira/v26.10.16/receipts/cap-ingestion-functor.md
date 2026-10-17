# Capability: affidavit ingestion functor (ARM PUT / RG-delete seal sideband)

Standing: PASS — sideband wire-up landed in the ARM gateway, real-run
green, anti-vacuity flip witnessed.

## Surface

`/Users/sac/smalt/lib/smalt/arm_gateway/router.ex` (SHIM-COURT
affidavit-seal ingestion functor, lane 611, lines ~2078-2160):

- **Wire-up law**: on every successful resource PUT (line ~796) and on the
  RG-delete cascade (capture-then-sweep, line ~697), the canonical
  stored-record bytes are admitted through the affidavit WASM engine
  (seal). Modality from tariff: `< 5_000_000_000` cents → modality 1,
  else modality 2.
- **Fail-safe**: the seal is a SIDEBAND — a dead engine, a refused seal,
  or an unavailable tariff calculator NEVER changes the HTTP outcome and
  never crashes the PUT/DELETE (`rescue` → typed `:PQC_NOT_PROVISIONED`
  witness-absent). Witnessed by the engine-down leg below.
- **Wire parity**: witnesses land in an ETS sideband table
  (`:smalt_affidavit_witnesses`) plus the log — never in the wire records —
  so stored/wire byte-parity is untouched. Reader:
  `Router.affidavit_witness/1`.

## Court

`/Users/sac/smalt/test/affidavit_ingestion_functor_test.exs` — real
router + real engine + real ETS table, no mocks:

1. PUT produces a sealed witness on the sideband receipt when the engine
   is up (`sealed == true`, non-empty `ctrt`, modality in [1,2], integer
   `tariff_cents`).
2. PUT still answers 2xx when the engine is down (typed witness-absent,
   `sealed == false`, `receipt == "PQC_NOT_PROVISIONED"`).
3. RG-delete cascade seals the deleted RG record (sideband, 202
   unchanged).
4. SHIM-COURT leg: PUT emits an `affidavit.seal` event to the OCEL NDJSON
   sink (registry-gated, matter-isolation attributes subject_sha / verdict
   / engine_hash, relationships close); anti-vacuity flip: mutated type
   `affidavit.seal.MUTATED` is dropped (`{:ok, :dropped}`), never admitted.

## Real run

This lane, `MIX_BUILD_ROOT=_build-lane11` via `scripts/fast_test.sh`:

```
$ scripts/fast_test.sh test/affidavit_ingestion_functor_test.exs
15:16:55.238 [info] Sent 201 in 1ms
.
Finished in 0.3 seconds (0.00s async, 0.3s sync)
4 tests, 0 failures
[15:16:55] wall: 186s (build root: _build-ft-c6dc7cd8)
```

4 tests, 0 failures. The run log shows the fail-safe leg live: the
engine-down PUT answers 201 with the loud
`SHIM-COURT affidavit-seal: :PQC_NOT_PROVISIONED witness-absent ...
(engine_unavailable)` warning — fail-safe, no crash, no wire change.
