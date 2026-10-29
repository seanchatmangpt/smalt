# BK-69r — Store decomposition reconciliation receipt

**Standing: ALIVE** · Context: solo · Date: 2026-10-21 · Lane: BK-69 relaunch (BK-69r) · Build root: `_build-bk69r` · Toolchain: asdf elixir 1.20.4-otp-29 / erlang 29.1.2 (repo `.tool-versions`)

## Reconciliation matrix

| # | Item | Disposition | Evidence |
|---|---|---|---|
| 1 | `lib/smalt/plane/data_supervisor.ex` single `Smalt.Store` child | **ALREADY RESTORED — no edit.** File is clean vs HEAD (`git status --porcelain`: empty); TTV-5's lane landed the single-child form: children are `[Smalt.Store, Bandit egress (shutdown 10s), Bandit WS relay (shutdown 10s)]`; moduledoc records the 2026-10-21 coordinator decision (store-internal tree canonical, superseding STORE-2 expansion). | File read; git status |
| 2 | `lib/smalt/store/heir.ex`, `lib/smalt/store/partition.ex` | **CANONICAL — keep.** The `Smalt.Store` internal tree boots `{Smalt.Store.Heir, opts}` first, then 16 `{Smalt.Store.Partition, i}` permanent workers (store.ex:71-82), and routes serialized writes via `Smalt.Store.Partition.whereis_owner/2` throughout. Not orphaned duplicates. | grep of store.ex; module heads |
| 3 | leg4b classification | **STALE PREMISE — neither a real regression nor cross-leg contamination.** Witnessed solo failure with identical shape as in-file; probe (below) shows the tested mechanism no longer exists under the canonical tree. | Solo runs + probe witness |
| 4 | Regression suite | **GREEN: `mix test ttv5_store_partitioning_court.exs ttv4_journal_boot_replay_court.exs` → exit 0, 8 passed.** | Command output below |

## Leg classification — solo re-runs (line-filtered, one test per BEAM)

| Leg | Line | Solo exit | Verdict |
|---|---|---|---|
| leg1 blob etag round-trip | 165 | 0 | pass |
| leg2 cosmos CRUD+query | 235 | 0 | pass |
| leg3 SB AMQP round-trip | 336 | 0 | pass |
| leg4a partition-isolation crash | 665 | 0 | pass |
| leg4b ensemble-kill content recovery | 753 | **2 (excluded count quirk: 0/1, 5 excluded — test failed)** | **fails solo** |
| leg5 journal-sealed restart | 786 | 0 | pass |
| whole file (all legs together) | — | 1 | 5/6, only leg4b fails |

leg4b fails identically solo and in-file → **no cross-leg contamination anywhere**; the file's only failure is leg4b's own premise.

## leg4b probe witness (temp test, deleted after run)

```
WITNESS whereis=#PID<0.593.0>
WITNESS new_sup=#PID<0.2177.0>
WITNESS table_exists=true
WITNESS get=:error
WITNESS raw=[]
```

`Process.whereis(Smalt.Store)` is now the **ensemble supervisor** (Heir + 16 partitions + replay Boot), not the single-owner GenServer leg4b was written against. Killing it is a full-ensemble kill: tables transfer through the dead-heir chain and are **recreated fresh — non-journaled content is lost by design** (`journal_sink_dir` is nil in test env; leg4b itself asserts that). The content-intact guarantee leg4b asserts was **subsumed**: partition-crash content-intact recovery is leg4a (green), full-restart recovery is leg5 (green). leg4b asserts pre-TTV-5 single-owner semantics against a tree that no longer has a single owner — same class as the parity-register "test premise predates substrate capability" rot, here inverted (test predates the substrate *replacement*).

## Commands / exits

```
MIX_BUILD_ROOT=_build-bk69r mix compile                                   # exit 0 (warnings only)
for L in 165 235 336 665 753 786: MIX_BUILD_ROOT=_build-bk69r mix test \
  test/integration/store_partition_wire_regression_test.exs:$L            # 0,0,0,0,1(fail),0
MIX_BUILD_ROOT=_build-bk69r mix test test/integration/bk69r_probe_tmp_test.exs   # exit 0 (witness above; file deleted)
MIX_BUILD_ROOT=_build-bk69r mix test test/integration/ttv5_store_partitioning_court.exs \
  test/integration/ttv4_journal_boot_replay_court.exs                     # exit 0, 8 passed
MIX_BUILD_ROOT=_build-bk69r mix test test/integration/store_partition_wire_regression_test.exs  # exit 1, 5/6 (leg4b only)
```

## Residual

leg4b needs re-authoring against the partitioned tree (e.g. kill one partition owner, assert heir give-away + sibling service + journal-sealed restart restores all planes) — that is a test-authoring work order, not a lib defect. No lib/ changes made this lane; no commit (per contract).
