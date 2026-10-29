# BK-WIT3R — triage of the six BK-WIT3 witnessed stderr reds

**Standing:** PARTIAL_ALIVE (4 of 6 RESOLVED by green re-run; 1 RESOLVED-as-load-sensitive with a typed follow-up; 1 real defect → typed ticket, owner BK-KFKC)
Context: solo
Date: 20261022
Owner: BK-WIT3R
Repo: /Users/sac/smalt (canonical checkout)
Parent: `bkwit3-witness-final.md` (Class-4 six)

## Method

Chicago: every item re-run from its receipt's embedded command, real runs,
fresh lane build roots `_build-bkwit3r-*`, substrate UP (pid 81426, ports
9443/9444/5672/5673, lock FREE). No mocks.

## Per-item verdicts

### 1. az1c-kafka-receipt.md — CorruptRecordException [Error 2] — RESOLVED

Re-run: `MIX_BUILD_ROOT=_build-bkwit3r-az1c mix test test/internal/kafka_wire_test.exs`

```
Result: 9 passed
EXIT=0
```

The witness RED tail (`kafka.errors.CorruptRecordException: [Error 2]` /
`PolicyViolationError: [Error 44]`) is the expected negative-probe stderr
embedded mid-run of a green suite — the KIP-183 error-44 downgrade face and
typed err=2 CORRUPT_RECORD legs are *supposed* to raise in the python probe
subprocess. Not the BK-KFKC2 0x42424242 corruption class: that class is fixed
on this tree (BK-KFKC2 receipt, ALIVE) and the same file passes 9/9 here. The
witness gate extracted a red-looking stderr line from a passing run.

### 2. bkkfkskep-kafka-audit.md — PolicyViolationError [Error 44] — RESOLVED

Re-run: `MIX_BUILD_ROOT=_build-bkwit3r-kfkskep mix test test/internal/kafka_exp4_court_test.exs test/internal/kafka_wire_test.exs`

```
Result: 19 passed
EXIT=0
```

Same class as item 1: error-44 is the documented KIP-183 downgrade face
(conn.ex:133-142, BK-KFKC2 receipt). Green on the current tree.

### 3. kdblob-error-contract.md — Mix.Sync.Lock failure — RESOLVED (compile race)

Re-run: `MIX_BUILD_ROOT=_build-bkwit3r-kdblob asdf exec mix test test/internal/kd_blob_court_test.exs`

```
Result: 12 passed
EXIT=0
```

The Mix.Sync.Lock crash was the transient parallel-compiler lock race BK-WIT3
named (Class 3); clean re-run green in a fresh build root.

### 4. bk7-warnings-cleanup.md — warning-surface drift — RESOLVED (compile race)

Re-run (receipt's full 6-file suite):

```
$ MIX_BUILD_ROOT=_build-bkwit3r-bk7 asdf exec mix test test/data_plane/kql_test.exs \
    test/internal/powl2_law_compiler_court.exs test/internal/az2_maa_attestation_court_test.exs \
    test/internal/journal_reader_court_test.exs test/integration/sj1_journal_sink_court.exs \
    test/integration/bk135r_matter_journal_court.exs
Result: 46 passed
EXIT=0
```

The `kql_test.exs:10:3` line the witness captured is a warning-context line,
not a failure; the whole suite is green on the current tree.

### 5. bk7c-kafka-warnings.md — REAL DEFECT (typed ticket, owner BK-KFKC lane)

Re-run: `MIX_BUILD_ROOT=_build-bkwit3r-bk7c mix test test/internal/kafka_exp4_court_test.exs test/internal/wps_exp4_court_test.exs test/internal/webpubsub_test.exs`
→ `Result: 26/27 passed` repeatedly; the 1 failure is always
`BK-KFKC real-client probe ... consume probe never returned PASS within 4
bounded tries` (test/internal/kafka_exp4_court_test.exs:189).

Reproduced across seeds 100, 200, 300 on exp4 alone (`Result: 9/10 passed`,
same failure), so not machine load: **order/state dependence**. Mechanism:
the KFKC legs at `kafka_exp4_court_test.exs:152/:172/:183` produce to
`@kfkc_part` (= partition 1); the :189 probe (`tmp/bkkfkc_probe.py`) consumes
partition 1 **from the beginning** and asserts `sorted(all values) ==
[value]` — any prior partition-1 produce in the same run makes all 4 bounded
retries fail identically (retrying cannot repair state dependence). Secondary
structural hazard: retry budget 4×20s consumer timeout vs the 60s ExUnit
default timeout — under load the test dies as ExUnit.TimeoutError before the
assertion (witnessed twice today).

Witnessed in passing: tick 8b771322 (07:41) snapshotted a mid-edit
`lib/smalt/messaging/amqp/connection.ex` that broke the shared compile
("unexpected reserved word: end" :3379); the owner repaired it in-flight
within the compile-freeze SLA window (working tree re-verified green at 07:47).

**Ticket for BK-KFKC owner**: either scope the probe's consume to a fresh
topic/partition (or filter by a unique per-run prefix), and/or raise the test
timeout above the 4×20s retry budget. No code changed by this lane — the
kafka_exp4 court surface belongs to the BK-KFKC/BK-KFKSKEP lanes.

### 6. expl10r2-med-repairs.md — GL-9 µs-fence — RESOLVED (load-sensitive; typed note)

Re-run: `MIX_BUILD_ROOT=_build-bkwit3r-e10r2 asdf exec mix test test/internal/powl2_law_guard_court.exs`

```
Result: 14 passed
EXIT=0
```

GL-9 (`powl2_law_guard_court.exs:438`, <= 15µs/step absolute µs bound) passes
on a quiet machine; the witness-all red fired under 155-concurrent-rerun
load. Per the no-sleep doctrine's ratio-fence law, the absolute ms/µs bound
fences machine state, not the claim under test — typed follow-up for the
EXPL10-R2 owner: convert GL-9 to a ratio fence against a sleep-free baseline.
No code changed by this lane (POWL2 surface not this lane's).

## Summary

| item | verdict |
|---|---|
| az1c CorruptRecord | RESOLVED (green re-run; expected negative-probe stderr) |
| bkkfkskep PolicyViolation | RESOLVED (green re-run) |
| kdblob Mix.Sync.Lock | RESOLVED (compile race) |
| bk7 warning-surface | RESOLVED (compile race) |
| bk7c GL-9-adjacent warnings leg | → actually the KFKC probe: REAL DEFECT, ticket to BK-KFKC |
| expl10r2 GL-9 µs-fence | RESOLVED (load-sensitive; ratio-fence follow-up to EXPL10-R2) |

5 of 6 resolved on the current tree; 1 real order-dependence defect typed and
routed. Zero code changes by this lane; receipt-only commit.

## Falsifier

Re-run the five RESOLVED commands above — each must exit 0 (bk7c's exp4 probe
failure reproduces across seeds until the BK-KFKC owner lands the scoping
fix). Any item flipping red re-opens its verdict.
