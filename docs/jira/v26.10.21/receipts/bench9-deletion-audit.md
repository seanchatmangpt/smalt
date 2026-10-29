# BENCH-9 receipt — benchee deletion audit (PRD-DEL-01)
Context: pair (read-only deletion audit over shared mix/lib/test/scripts surface)
**Standing:** PASS

- **Date**: 2026-10-21
- **Repo**: /Users/sac/smalt
- **Lane**: BENCH-9, v26.10.21 OTP-29 window
- **Contract**: `docs/jira/v26.10.21/BENCH-ERLANG.md` (see caveat, §5)
- **Receipt path**: `docs/jira/v26.10.21/receipts/bench9-deletion-audit.md`

## 1. Grep audit — benchee / benchee_html

Expected per PRD-DEL-01: zero hits in mix.exs / lib / test / scripts.
**Actual: NOT zero.** `benchee_html` is zero everywhere (pass). `benchee`
itself is present in three places:

| hit | file | context |
|---|---|---|
| dep declaration | `mix.exs:147` (`{:benchee, "~> 1.3", only: [:dev, :test], runtime: false}`) with explanatory comment at mix.exs:144-146 | statistical counterpart to hand-rolled b7/b8/b9 |
| lock entry | `mix.lock:9` (benchee 1.5.1, sha256 `a539301f...`) | resolves the dep |
| runner | `scripts/bench/benchee_runner.exs` (18 hits) | b7b/b8b/b9b JSONL emitter |

lib/ and test/: zero hits. scripts/: only the one runner file.

## 2. Census — scripts/bench/*.exs vs AR-BENCH-01/02

`test/bench/**` does not exist (census empty there). 22 `.exs` files in
`scripts/bench/`. Pattern scan (monotonic_time / statistics(:reductions) /
timer.tc / sleep / benchee hit counts per file) plus targeted reads:

| harness | model | classification |
|---|---|---|
| a1_change_feed.exs | aggregate monotonic_time; 8 sleeps are load-shape/backoff outside measured sections | AR-BENCH-01 compliant (load generator) |
| a2_cas_contention.exs | aggregate mt, no tc/sleep | compliant |
| a3_cross_partition_tx.exs | aggregate mt | compliant |
| a4_crypto_throughput.exs | aggregate mt | compliant |
| a7_hns_rename.exs | aggregate mt; 1 sleep (setup/backoff) | compliant |
| a8_lro_storm.exs | aggregate mt; sleeps are LRO poll backoff | compliant (load generator) |
| b42_dataplane_saturation.exs | aggregate mt | compliant |
| b7_store_beam.exs | aggregate mt (11 sites), no per-call timing | compliant (cited falsifier, errc2-benchee.md) |
| b8_amqp_beam.exs | **:timer.tc per-call at L46/L100** | per-call timing — contaminating vs AR-BENCH-01 |
| b9_eh_beam.exs | aggregate mt | compliant (cited falsifier) |
| benchee_runner.exs | **Benchee.run at L95/L333 — framework in measured path** | framework contaminating vs AR-BENCH-01 goal 1; cited evidence record (errc2-benchee.md) |
| c10_affidavit_seal.exs | **:timer.tc per seal at L35** | per-call timing — contaminating vs AR-BENCH 01 |
| enclave_loop.exs | aggregate mt | compliant |
| gl9_governance_tax.exs | aggregate mt, median-of-N tax, non-vacuity arm | compliant |
| impl17_amqp_reductions.exs | mt + statistics(:reductions) delta, body in measuring process | compliant — the PRD's cited exemplar |
| pb1_fond_sweep.exs | aggregate mt; 1 sleep (setup) | compliant |
| pb2_reductions_step.exs | reductions delta in measuring process | compliant — PRD exemplar |
| pb3_executor_ceiling.exs | aggregate mt | compliant |
| pb5_crosslang.exs | mt + reductions delta | compliant |
| pb6_dual_boundary.exs | **:timer.tc per step (7 sites)** | per-call timing — contaminating |
| recon_soak.exs | aggregate mt; 1 sleep (interval sampling) | compliant (soak sampler) |
| t42_json.exs | aggregate mt | compliant |

18/22 aggregate-model compliant; 3 use :timer.tc per-call (b8, pb6, c10); 1
runs the benchee framework in the measured path (benchee_runner).

AR-BENCH-02 (heap fencing): the only "cheap on the caller" claims live in
pb2/pb5/impl17, which measure caller-side reductions with isolated/inline
stages; no heap claim in the census lacks a fence. No AR-BENCH-02 violation
found.

## 3. Deletion verdict

**Deletion pass is a no-op; the migration is additive.**

Zero files qualify for deletion:

- The 18 compliant harnesses are the live AR-BENCH-01 harness set — measuring
  infrastructure, not artifacts.
- The 3 :timer.tc harnesses (b8, pb6, c10) are wire/boundary probes and cited
  falsifier records (b8 is half of the errc2-benchee comparison table; pb6 and
  tc-per-step probes were the point of those probes), not framework residue.
- The one genuine framework artifact — `scripts/bench/benchee_runner.exs` +
  the mix.exs dep — is a **cited evidence record**
  (docs/jira/v26.10.14/receipts/errc2-benchee.md, incl. the benchee-vs-hand-rolled
  comparison table and the b7b/b8b/b9b JSONL rows). Deleting it would orphan
  that evidence and contradict mix.exs:144-146 which names it explicitly.
  If the zero-framework goal is to be enforced, it must be prospective
  (deprecation note / CI fence), never a deletion of cited evidence.

## 4. Standing

Audit-only lane. No harness, dep, or doc was modified or deleted. The only
write is this receipt. Verdict recorded: **no-op deletion pass; migration
additive; benchee dep + runner retained as cited evidence.**

## 5. Caveat — PRD file corruption

`docs/jira/v26.10.21/BENCH-ERLANG.md` (as of 2026-10-21 15:32) is
self-declared corrupted mid-write (two in-place STOP markers; recurring
editing artifact). This audit was run against the requirements as stated in
the lane task and the PRD's clean sections (aggregate monotonic_time +
reductions delta; heap fencing; zero framework in measured path). A second
finding while there: the PRD cites `scripts/bench/impl17_amqp_redues.exs` —
the actual file is `scripts/bench/impl17_amqp_reductions.exs`. Fix in the
clean re-land.
