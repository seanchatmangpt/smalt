# BK-CELLS — VALIDATION v8 honest-PARTIAL cell triage (DATA-01..04, NFR-LATENCY, PRD-APIM, POWL-CEIL)

**Standing:** **ALIVE** — every disposition carries real output on disk with exit
codes embedded; two flips (NFR-LATENCY -> PASS, PRD-APIM -> ALIVE) and four
evidence-binding re-witnesses / typed residuals. No faked closures.

Context: solo

Lane: bkcells, 2026-10-22, repo /Users/sac/smalt, build root `_build-bkcells`,
substrate pid 30875 (booted by this lane after clearing two orphan
lock-holders, scripts/substrate.sh, lock fd closed per w876.4).

## Machine

Apple M3 Max (16 cores) - OTP 29 / Elixir 1.20.4-otp-29 (asdf shims first on
PATH) - node + @azure SDKs from verification/ts - Elixir 1.20.4
PartitionSupervisor source read for resize!/2 semantics before probing.

## Per-cell disposition table

| cell | verdict before | disposition | falsifier adoptable now? | output on disk |
|---|---|---|---|---|
| AR-DATA-01 | PARTIAL_ALIVE | evidence-bound: ARD-gate clause measured PASS; Store-CAS-tables adoption clause typed UNBUILT residual (code change on an other-lane-modified file - not landed this wave) | ARD gate: YES. Store CAS: NO | test/internal/bkcells_ard_cas_gate_test.exs (green) |
| AR-DATA-02 | PARTIAL_ALIVE | UNBUILT: next_lookup/update_element migration of ordered_walk/3 not landed (still ets.next-based at store.ex:395-409; zero next_lookup/update_element hits in lib/) | NO - code change, another lane owns store.ex in-flight | grep below; owner: next data-plane lane |
| AR-DATA-03 | PARTIAL_ALIVE | UNBUILT: no Registry.lock in lib/, no atomics-preserving redesign receipt exists; the naive-swap race refutation stands | NO | grep below |
| AR-DATA-04 | PARTIAL_ALIVE | evidence-bound: resize semantics re-witnessed at HEAD with a green court on disk; adoption clause (worker pool sized at max + shrink in lib/) UNBUILT - still 0 PartitionSupervisor hits in lib/ | re-witness: YES; adoption: NO | test/internal/bkcells_data04_resize_probe_test.exs (green) |
| NFR-LATENCY | PARTIAL | FLIPPED to PASS - falsifier closed by real measurement (serial blob-PUT receipt now exists; cosmos p99 outlier cleared on re-run) | YES | tmp/bench/bkcells-floor.jsonl |
| PRD-APIM | PARTIAL_ALIVE | FLIPPED to ALIVE - the pending witness-filing receipt is filed on a green 6/6 court re-run at HEAD | YES | bkcells-apim-witness.md (same dir) |
| AR-POWL-CEIL (PB-3) | PARTIAL_ALIVE | evidence-bound: escalated ramp run to L32768 (4x prior ceiling probe) - 0 errors at every rung, wall unreached; ceiling above L32768 remains UNKNOWN so the cell stays PARTIAL_ALIVE (an escalated run that does not fail can extend, never close, an unreached-wall cell) | extended, not closable | tmp/bench/pb3-escalated-bkcells.jsonl |
| PB-1 / PB-2 | PARTIAL_ALIVE | SKIPPED - owned by the in-flight BK-5 POWLBENCH lane; not touched by this lane | - | - |

## Embedded measurement output

### 1. NFR-LATENCY - serial floor re-run (n=1000/face, strictly serial, live 9444 twin)

$ NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem node tmp/bench/bkcells_floor.mjs

    STS bearer minted, 1290 chars
    {"face":"cosmos-point-read","n":1000,"ok":1000,"errors":0,"wall_ms":640.5,"min_ms":0.489,"p50_ms":0.62,"p99_ms":1.035,"max_ms":1.621,"ops_per_sec":1561.2}
    {"face":"blob-put-1kib","n":1000,"ok":1000,"errors":0,"wall_ms":781,"min_ms":0.559,"p50_ms":0.765,"p99_ms":1.06,"max_ms":3.682,"ops_per_sec":1280.4}
    WROTE tmp/bench/bkcells-floor.jsonl

Against the charter gates (ARD-PRD.md L355): cosmos p50 0.62 <= 0.8 ms and
p99 1.035 <= 3 ms - the 3.040 ms head-of-line outlier is cleared on re-run;
blob-PUT 1 KiB p50 0.765 <= 1.5 ms and p99 1.06 <= 4 ms - the missing serial
blob-PUT receipt now exists with real output. Both legs PASS. Honest typing:
one fresh quiet-window witness, not a min-of-N series. Harness
tmp/bench/bkcells_floor.mjs mirrors T23's scvd_floor.mjs shape (STS bearer,
single client, strictly serial, final blob state verified by download after
the PUT sweep - 1024 B asserted).

### 2. DATA-01 - ARD verification gate on the real adopted rate table

$ MIX_BUILD_ROOT=_build-bkcells mix test test/internal/bkcells_ard_cas_gate_test.exs

    [BKCELLS ARD gate] n=256 (min-of-3) p99=0.333us exact=yes
    [BKCELLS ARD gate] n=1024 (min-of-3) p99=0.709us exact=yes
    [BKCELLS ARD gate] n=4096 (min-of-3) p99=0.5us exact=yes
    .
    Finished in 0.03 seconds
    Result: 1 passed

Exit 0. Real table Smalt.ArmGateway.Router.rate_table_for_test/0
(write_concurrency :auto default-ON), 16 workers x distinct keys
(decentralized counters - the AR-DATA-01 profile), exactness asserted on real
table state, min-of-3 p99 per rung. P99 is flat sub-microsecond across
256/1024/4096 rungs (0.333/0.709/0.5 us). Typed honestly: a 16-writers-on-ONE-
hot-key profile measured p99 spikes up to ~160 us at n=4096 in a discarded
first harness revision - single-hot-key contention is a different, harder
contention class than the decentralized profile the charter gate names; typed
here as a residual observation, not gated.

### 3. DATA-04 - PartitionSupervisor.resize!/2 re-witness at HEAD

$ MIX_BUILD_ROOT=_build-bkcells mix test test/internal/bkcells_data04_resize_probe_test.exs

    [BKCELLS DATA-04] 4->2->4 ok; resize returned prev count (4, then 2);
    resize to 8 raised with the max_partitions bound message; state preserved at 4
    .
    Result: 1 passed

Exit 0. Elixir 1.20.4 semantics re-witnessed: resize! within [0, max]
resizes, returns the PREVIOUS count (4 then 2), resize beyond the bound
raises ArgumentError "the number of partitions to resize to must be a number
between 0 and 4, got: 8", state preserved. Probe note typed: a Registry
child_spec template collides at partition 1 under 1.20.4
(PartitionSupervisor does not rewrite a fixed :name per partition -
"already started: #PID<0.631.0>"); the probe uses the unnamed
DynamicSupervisor template. The AR-DATA-04 adoption clause remains UNBUILT
(still zero PartitionSupervisor hits in lib/).

### 4. POWL-CEIL - escalated executor ramp (PB-3 falsifier leg)

$ MIX_BUILD_ROOT=_build-bkcells mix run --no-start tmp/bench/pb3_escalated_bkcells.exs

    N=8192 wall_ms=1641 errors=0 p50=681 p95=810 p99=828 lat_count=8192
    N=16384 wall_ms=7617 errors=0 p50=801 p95=856 p99=860 lat_count=16384
    N=32768 wall_ms=68039 errors=0 p50=4000 p95=4114 p99=4121 lat_count=32768
    wrote tmp/bench/pb3-escalated-bkcells.jsonl
    wall_level=unreached-at-32768 total_errors=0

Exit 0. 0 errors at every rung through L32768 - 4x past the wire face's typed
wall (L8192, T3) and 4x past PB-3's prior probe. The slow-but-never-wrong
decay continues (p99 828 -> 860 -> 4121 ms; throughput decays, correctness
never breaks). The executor ceiling above L32768 remains UNKNOWN - the cell
stays PARTIAL_ALIVE; the escalated receipt extends the evidence, it cannot
close an unreached-wall cell by not failing. Harness:
tmp/bench/pb3_escalated_bkcells.exs (derived from
scripts/bench/pb3_executor_ceiling.exs, sweep [8192, 16384, 32768],
real DETS, same executor entrypoint execute_admitted/6).

### 5. PRD-APIM - dedicated witness receipt filed

test/integration/apim_wire_test.exs (real EgressRouter, real ETS rate-limit
table, real JWT verify) re-run at HEAD -> 6 passed, 0 failed:

    04:49:21.332 info[] GET /apim-gw/apimwire-be085b76db7b/orders/42
    04:49:21.332 info[] Sent 200 in 26us
    Result: 6 passed

6 legs: default-off 404 face, echo-backend 200 with post-transform header,
over-quota typed 429, invalid-JWT typed 401, valid emulator-STs JWT admits,
jwt-refusal-wins chain order. Full detail:
docs/jira/v26.10.22/receipts/bkcells-apim-witness.md.

### 6. UNBUILT greps (DATA-02 / DATA-03 residuals)

$ grep -rn "next_lookup\|update_element" lib/ | wc -l
    0
$ grep -rn "Registry.lock" lib/ | wc -l
    0
$ grep -rn "PartitionSupervisor" lib/ test/ --include="*.ex" --include="*.exs" -l
    test/internal/bkcells_data04_resize_probe_test.exs   (this lane's probe only)

## Disclosures

- First harness revision of the DATA-01 court used per-op send/receive into
  the test parent - the parent mailbox, not the ETS table, produced the
  p99 42.7us artifact at n=4096; replaced with task-local aggregation before
  any receipt was written. The surviving single-hot-key observation (p99
  spikes ~160us at 4096) is typed above as residual, not gated.
- Compile-freeze event: another lane's in-flight lib/smalt/storage/
  journal_reader.ex was syntactically broken at first court attempt; owner
  recovered it before retry (no unblock fix applied by this lane).
- tmp/bench/pb3_escalated_bkcells.exs and tmp/bench/bkcells_floor.mjs are
  lane scratch (tmp/, not staged).
