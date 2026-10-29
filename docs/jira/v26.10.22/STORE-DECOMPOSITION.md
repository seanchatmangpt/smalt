# STORE-DECOMPOSITION

TTV-5 store decomposition — the canonical record. Standing: **ALIVE**
(courts green: 8 passed, exit 0, re-run this session; see Verification).
Companion receipts: `receipts/store2-supervision-wiring.md`,
`receipts/store3-wire-regression.md`, `receipts/store4-partition-court.md`,
`receipts/bk69r-store-reconciliation.md`, `receipts/bk57-heir-guard.md`.

## Rationale

The pre-decomposition store was a single `Smalt.Store` GenServer owning all
Store ETS tables. One process was the whole error kernel: a crash deleted
every data table (dead-owner chain), and every serialized op (CAS, CAS-delete,
insert_new, next_seq) funneled through one mailbox — one slow caller stalls
every plane. TTV-5 decomposes it into a supervised ensemble that bounds the
blast radius to one stripe and keeps the crash/replay laws intact.

Three coordinator-approved deviations are load-bearing:

1. **Table-level, not key-level, striping.** Key-striping would rename the
   canonical table namespace and break ~15 cross-lease modules doing direct
   ETS/readiness checks (`lib/smalt/store.ex` moduledoc, lines 26-31).
2. **`whereis(Smalt.Store)` is the ensemble supervisor.** The process named
   `Smalt.Store` is the Supervisor itself; killing it IS the full-node crash
   (store.ex moduledoc lines 11-13; courted in leg3 of
   `test/integration/ttv5_store_partitioning_court.exs`).
3. **Store-internal tree.** Wiring lives inside `Smalt.Store.start_link/1`;
   `DataSupervisor` keeps a single `Smalt.Store` child
   (`receipts/bk69r-store-reconciliation.md` row 1, coordinator decision
   2026-10-21, superseding STORE-2's DataSupervisor expansion).

## The ensemble

Booted by `Smalt.Store.start_link/1` (`lib/smalt/store.ex`):

| # | child | role |
|---|---|---|
| 1 | `Smalt.Store.Heir` | quiet heir, boots FIRST, holds dead partitions' tables |
| 2..17 | `Smalt.Store.Partition` × 16 | permanent workers, one per stripe |
| 18 | `Smalt.Store.Boot` | TTV-4 sealed-journal replay, last |

18 children total under `:one_for_one`, `max_restarts: 200` /
`max_seconds: 5` (store.ex lines 95-100). Every serialized write
(`compare_and_swap/4`, `compare_and_swap_delete/3`, `insert_new/3`,
`next_seq/3`) routes via `GenServer.call` to the owning partition worker
with `@call_timeout 5_000` (store.ex line 47). Reads, `put/3` and
`delete/2` bypass the processes entirely (direct ETS on public named
tables); `put`/`delete` are caller-side journaled.

## Table-stripe scheme

Striping is per TABLE: table `t` belongs to partition
`:erlang.phash2(Atom.to_string(t), 16)` (`Smalt.Store.partition_of/1`,
`lib/smalt/store/partition.ex` `owner_of/1`).

- Table population: **35 registry tables** in
  `lib/smalt/store_tables.ex` `@tables` (lines 36-141; machine-generated
  from `smalt-substrate-pack/ontology.ttl`; moduledoc: "the 33
  Store-created tables" — the moduledoc prose count is stale, the list is
  ground truth; counted 2026-10-22 via
  `sed -n '36,141p' ... | grep -o ':[a-z_0-9]*' | sort -u | wc -l` → 35).
  - The `partition.ex` moduledoc's "35 registry tables" matches; the
    registry moduledoc's "33" does not — known prose drift, list wins.
- Stripe distribution (measured 2026-10-22,
  `elixir -e ':erlang.phash2(name, 16)'` over the 35 names): **13 of 16
  stripes carry at least one table**; 3 stripes are empty at rest
  (p4, p11, p12). Full mapping pinned in
  `test/integration/store_partition_wire_regression_test.exs` leg4a
  (a→p9, b→p15, c→p2 in `receipts/store3-wire-regression.md`).
- Per-table serialization is identical to the pre-partition single
  GenServer guarantee: all ops for table `t` serialize on the ONE worker
  owning t's stripe (`partition.ex` moduledoc lines 6-11).
- Partition names are compile-time-bounded (`name_for/2` builds
  `:"Partition#{i}"` for i∈0..15 at boot, never wire input) — same
  safe-by-construction argument as the Erlang twin
  (`receipts/store4-partition-court.md`).

## Heir ownership

`lib/smalt/store/heir.ex` — zero-business-logic quiet GenServer:

- **Creation-time heir option**: the OWNING partition creates each table
  with `{:heir, heir_pid, []}` (partition.ex init, lines 61-83), so a
  partition death transfers the table to the Heir (logged
  `ETS-TRANSFER` hold, heir.ex handle_info line 114). `:ets.give_away`
  does NOT reset the heir option — the creation heir must be the Heir,
  never `:init` (heir.ex lines 77-80; the store4 Erlang receipt records
  the same law on its twin).
- **Reclaim** is a real `:ets.give_away/3` executed BY the Heir
  (`reclaim_table/2`), no-op-with-log when not held (heir.ex lines 89-111).
  Give-away from a non-owner is a documented no-op, never an error.
- **Heir must die with its ensemble** (BK-69 fold, heir.ex lines
  122-135): a trap-exited heir otherwise survives a `:kill` of the
  ensemble supervisor and answers `{:error, {:already_started, pid}}` to
  every restart — witnessed permanent restart loop (court leg3, recorded
  in heir.ex comment and `receipts/bk69r-store-reconciliation.md`).
  Non-normal parent EXIT → the Heir stops; its tables fall through to the
  `:init` fallback heir. Ownership RESTS WITH the heir lineage, never
  reclaimed from `:init` by force.
- **Residual (bounded, documented)**: if the Heir itself dies while
  holding an already-orphaned table, that table is deleted; the sealed
  journal replays it next boot (heir.ex lines 81-84).
- Mechanical gate: `just heir-guard` — 37 heir `:ets.new` sites, 37/37
  GUARDED, exit 0 (`receipts/bk57-heir-guard.md`, census 2026-10-21).

## Boot-replay path (TTV-4)

`Smalt.Store.Boot` is ensemble child #18 and runs the TTV-4 sealed-journal
replay in `init/1` (`Smalt.Store.boot_replay_for_boot/1` →
`replay_sealed/1`). Contract:

- **Adopt-then-replay**: partitions create/adopt tables first; the sealed
  journal is applied before the ensemble finishes starting — no request is
  served until all 18 children are up (store.ex lines 85-92). Serving-
  equivalent to replay-then-adopt.
- **Fail-closed**: first typed reader refusal (manifest mismatch, CRC,
  truncation, seq regression) or first uninterpretable Store frame
  (`{:unknown_table_id, id}`, `{:bad_payload, ...}`) stops the boot with
  `{:stop, {:journal_replay_failed, reason}}` (store.ex lines 542-568,
  `Smalt.Store.Boot`). A typed reader refusal is a boot refusal — never a
  silent skip.
- **Frame law**: frames carry u16 table ids (index into the generated
  registry) + event types 0x0A01 put / 0x0A02 delete, disjoint from
  OcelEmitter codes 0x0001..0x0004, which are skipped by event type —
  another writer's records are not corruption (store.ex lines 49-58,
  200-204).
- **Journal-then-apply (WAL order)** at the write side, best-effort:
  sink down or config unset → the mutation still applies, append is
  logged and dropped (store.ex lines 254-261). The crash court exercises
  the sink-up face.
- Witnessed in this session's court run: `journal replay restored 30000
  frame(s)` (leg4 replay-window adversarial), and store3's leg5:
  "journal replay restored 5 frame(s)", 5 keys recovered across 4 plane
  tables after a real ensemble kill + restart
  (`receipts/store3-wire-regression.md` leg5).

## Courts and falsifiers

### `test/integration/ttv5_store_partitioning_court.exs` (4 tests)

- Pins: stripe routing, heir hold/reclaim, ensemble-kill=replay path,
  replay-window convergence.
- Falsifier: any FAIL, a lost key after a partition kill, or boot
  deadlock in the replay window.

### `test/integration/ttv4_journal_boot_replay_court.exs` (4 tests)

- Pins: sealed-journal boot replay, fail-closed refusals (CRC,
  truncation, seq regression), delete frames.
- Falsifier: a corrupted segment that boots, or a silent frame skip.

### `test/integration/store_partition_wire_regression_test.exs`
(6 tests, two green seeds — store3 receipt, ALIVE)

- Pins: per-plane wire legs; ≤6.25% blast radius (1/16); sibling-stripe
  service during a kill window; heir give-away recovery; leg5 journal
  restart.
- Falsifier: a test that also passes under a single-owner store —
  leg4a's during-window asserts ran green only after partitioning
  landed, so the court distinguishes the designs (store3 receipt,
  Non-vacuity).

### Erlang twin court (`receipts/store4-partition-court.md`, 4/4 PASS ×3)

- Pins: same contract on `src/smalt_store*.erl` — heir-first boot, kill
  P4, respawn, K4 survives via heir transfer.
- Falsifier: STEP 9 passes via anything other than heir transfer.

### `just heir-guard` (+ self-test; vacuity = exit 2)

- Pins: every heir `:ets.new` site guarded (37/37, bk57 receipt).
- Falsifier: the gate accepts an unguarded heir site.

### BK-69r stale-premise witness

- leg4b asserted pre-TTV-5 single-owner semantics; fails solo (exit 2,
  0/1) against the ensemble — subsumed by leg4a (partition crash) and
  leg5 (full restart).
- Falsifier: a re-introduced single-owner store that makes leg4b green.

## Verification (this session, 2026-10-22)

```
$ export PATH="$HOME/.asdf/shims:$PATH"
$ MIX_BUILD_ROOT=_build-bk140 mix test \
    test/integration/ttv5_store_partitioning_court.exs \
    test/integration/ttv4_journal_boot_replay_court.exs --seed 0
...
    journal replay restored 30000 frame(s) from
    /Users/sac/.cache/tmp/ttv5-test leg4: adversarial — kills during the
    replay window converge, never deadlock boot-609219
Finished in 12.4 seconds (0.00s async, 12.4s sync)

Result: 8 passed
```

Exit 0, 8 passed (4 TTV-5 + 4 TTV-4), fresh run against the current tree.

## Standing

**ALIVE** — the ensemble is the production boot path
(`Smalt.Plane.DataSupervisor` single `Smalt.Store` child,
`receipts/bk69r-store-reconciliation.md` row 1) and every pinning court
returned green on the current tree. Known residuals are typed and
documented: 3 empty stripes at rest, the bounded dead-heir residual, the
stale "33" count in the registry moduledoc prose, and the Erlang twin
coexisting un-rewired (`store4` receipt, honest integration note).

### Store4 disposition (BK-ST4W, 2026-10-22)

The "Erlang twin coexisting un-rewired" residual is typed as
**DEAD/UNWIRED in production — retained reference capital**. Census
(`receipts/bkst4w-store4-disposition.md`): zero `smalt_store*` references in
`lib/` or the boot path (`Smalt.Application` boots only the Elixir ensemble);
the only start site is the lazy `smalt_store:start()` (`whereis(smalt_store_sup)`
guard), called solely by `src/`-internal consumers (`smalt_proposer_gate`,
`smalt_wormhole`) that are themselves driven only by the
`test/courts/*_SUITE.erl` Erlang courts. The store3/store4 relationship:
store3 is the wire-regression court over the **Elixir** ensemble (production
path); store4 is the operator-mandated Erlang 16-partition decomposition —
same crash/isolation laws, independent implementation, no shared state
(table namespaces are disjoint: `smalt_store_p0..15` vs the ensemble's
`:smalt_<table>` names; `court_store_partition_SUITE` guards the dual-boot
name collision). Pinned by the typed no-boot assertion
`test/internal/store4_no_boot_test.exs` (green on the current tree: after a
real production boot, `whereis(smalt_store_sup) == undefined`, zero
`smalt_store_pN` tables live, ensemble up); the store4 family keeps its own
court (`court_store_partition_SUITE`, re-run green 4/4 PASS exit 0,
2026-10-22). Migration plan: none owed — store4 is not shadowing anything;
any future re-wiring of `src/` consumers onto production surfaces is a new
work order, not this one.
