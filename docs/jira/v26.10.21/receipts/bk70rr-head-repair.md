# BK-70rr Head Repair (relaunch of BK-70r relaunch)

**Standing: PARTIAL_ALIVE** — all four dispatch items executed; three deterministic
defects root-caused and fixed; census reconciled 6/6; every side gate green. The
terminal full-green mix-test seal is NOT reached: run 3 achieved 731/739 with 8
residual failures all in the load-sensitive kafka/ets files, each re-derived green
solo and in-pairs on retry; run 4 raced another lane's broken `maa.ex` mid-run
(compile smear → 154 failures, 6 invalid) — the same cross-lane churn class BK-70r
hit on runs 5–7, still active under the current relaunch wave.

**Context: full** — solo gate runs + 4 full-suite runs (`/tmp/bk70rr_full{,2,3,4}.log`).

## Dispatch items

### (1) AZ-wave census drift — REGISTERED, census 6/6

11 new test/internal files registered in `test/internal/internal_tier_census_test.exs`
(BK-134 reconcile pattern): `expl5r1`, `expl6r1_journal`, `kafka_exp4`, `kd_blob`,
`kd_conf`, `wps_exp4`, `wire_exp4`, `bkvc_consolidated`, `bk3_jsonsax`,
`bkcells_ard_cas_gate`, `bkcells_data04_resize_probe` — with typed per-file
exemption rows (`:client_token` ×4, `:status_literal` ×1) and 20 `@observables`
allowlist entries. No gate weakened beyond the observed behaviors. Census solo: 6/6.

### (2) Three deterministic mix-test defects — FIXED

| Failure | Root cause | Fix | File |
|---|---|---|---|
| KafkaWire F3 pair (recordsCount mismatch + builder non-vacuity) | Test builder `expl4_record/1` encoded record-v2 length/delta fields as PLAIN LEB128; the parser (matching the real kafka-python client) decodes zigzag signed varints — the builder's own batches were malformed (`svarint(<<18>>)` → 9, not 18) | Builder now zigzag-encodes (`u = (n<<1) ^ (n>>63)`, keyLen −1 encoded natively) | `test/internal/kafka_wire_test.exs` |
| Bk132CorpusTriage ×3 (set-tier GET echo, sync-copy 202/404) | (a) GET blob content arm omitted `tier_wire`/`copy_wire` headers; (b) sync-copy arm nested INSIDE the KD-139 `ensure_put_blob_type` gate → headerless Put-From-URL got 400 MissingRequiredHeader (Put Blob From URL does not carry x-ms-blob-type) | (a) attached `tier_wire`+`copy_wire` to the full-body GET content clause; (b) `ensure_put_blob_type` now bypasses the blob-type requirement when `x-ms-copy-source` is present (gate stays scoped to plain Put Blob; KD-139 law unchanged for Put Blob) | `lib/smalt/egress_router.ex` |
| TlsBlobDispatch ARM leg (404 SubscriptionNotFound on the dev sub) | TTV-5 Store ensemble rewrite dropped the boot-time default-subscription seed (it survived only in `clear/0`) — fresh boots served 404 | `Store.start_link/1` re-seeds after the ensemble is up (idempotent key-only insert, same semantics as `clear/0`) | `lib/smalt/store.ex` |

All three fixed solo: bk132 6/6, tls_blob_dispatch 2/2, spof3 2/2, kafka_wire 9/9
(after the AZ/KAFKA-EXP4 lane's in-flight `conn.ex`/`log.ex` wire fixes landed —
the produce/F4 failures were that lane's contested surface; not edited by this lane).

### (3) sleep-gate ja12/ja13 — ALREADY RESOLVED upstream

`just sleep-gate` on the settled HEAD: **PASS — 605 files, 0 unclassified sleep
primitives** (the BK-130 hooks/asyncfn surfaces re-derived clean; no violation set
to fix). Invariant-gates PASS 6/6 (×2 runs), docs-dod PASS ×2, receipt-index clean
(INDEX.md + RECEIPTS.md regenerated).

### (4) Full sweep

| Run | Result |
|---|---|
| 1 | 632/644 — 12 failures: the 3 deterministic clusters above (7 of them smear from the kafka F3 cascade) + census drift |
| 2 | compile-abort — in-flight `expl6r1_journal_court_test.exs` mid-edit (owner self-fixed) |
| 3 | **731/739 — 8 failures, all load-sensitive (kafka_wire ×5, kafka_exp4 ×2, ets_auto ×1); each re-run green solo and in file-pairs on retry** |
| 4 | 579/733, 6 invalid — compile smear: another lane's `lib/smalt/attestation/maa.ex` broke mid-run (self-fixed); not a defect on this lane's surfaces |

## Residual

Full-green seal blocked ONLY by concurrent-lane churn (in-flight shared-file edits
breaking compile mid-run; load interference on the kafka/ets timing-sensitive
files while ~10 lane beams are live). No deterministic failure remains on the
settled HEAD: every run-3 residual failed only under concurrent load and passes
in isolation. This is the BK-70r runs-2/4 signature, not the runs-1/3 defect class.

## Replay

```
export PATH="$HOME/.asdf/installs/erlang/29.1.2/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"
MIX_BUILD_ROOT=_build-bk70rr mix test          # run 3 = /tmp/bk70rr_full3.log (731/739)
just sleep-gate                                 # PASS 605 files, 0 violations
just invariant-gates                            # PASS 6/6
just docs-dod-check && just receipt-index       # PASS
```

**Falsifier**: a solo or paired run of `test/internal/kafka_wire_test.exs`,
`test/internal/kafka_exp4_court_test.exs`, `test/internal/ets_auto_court_test.exs`
with any failure falsifies the load-interference classification. A future
full-suite run on a quiet machine (no concurrent lane beams) that reproduces any
run-3 residual also falsifies it.
