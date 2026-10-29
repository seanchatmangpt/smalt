# TTV-5 — Partition Smalt.Store to bound the error kernel

**Standing:** **ALIVE**
Context: solo
Date: 2026-10-21
Lane build root: `MIX_BUILD_ROOT=_build-ttv5` (lease; coordinator deletes at integration)
Files owned/edited: `lib/smalt/store.ex` (facade + ensemble), `lib/smalt/store/heir.ex` (new), `lib/smalt/store/partition.ex` (new), `lib/smalt/plane/data_supervisor.ex` (coordinator-ordered restore, see below), `test/integration/ttv5_store_partitioning_court.exs` (new). `lib/smalt/storage/journal_reader.ex` unchanged.

## Design decision (per operator reference architecture + coordinator approval)

Implemented to the operator's 4-component reference: `Smalt.Store` is now the
FACADE of a supervised ensemble; the process named `Smalt.Store` is the
ensemble SUPERVISOR (whereis stays meaningful — killing it IS the full-node
crash):

    Heir (quiet, trap_exit, reclaim_table/2 give-away, ETS-TRANSFER hold logged)
      -> 16 permanent Partition workers (one_for_one, unique map-form child ids)
      -> Boot (TTV-4 sealed-journal replay)

Three coordinator-approved deviations, recorded verbatim in the reply
("Design APPROVED — all three deviations stand"):

1. **TABLE-level phash2 striping** (`:erlang.phash2(Atom.to_string(table), 16)`),
   not key-level: key-striping renames the canonical table namespace and
   breaks ~15 cross-lease modules' direct-ETS/readiness surface. BK-69's
   re-typed leg-1 line in the court carries the honest bound: affected
   registry share 3/35 = 8.6% of tables; the measured KEYSPACE ratio is NOT
   bounded by table-level striping — the ≤6.25% keyspace gate is carried by
   the STORE-4 key-level court subject (4/4 PASS ×3 per its receipt
   `docs/jira/v26.10.22/receipts/store4-partition-court.md`).
2. **whereis(Smalt.Store) = the ensemble supervisor** — the TTV-4 court's
   kill surface is preserved verbatim; killing it IS the full-node crash.
3. **Internal wiring** (`Smalt.Store.start_link/1` boots the whole tree) —
   DataSupervisor/application.ex need zero edits (the application.ex
   bar-lift was unused). STORE-2's DataSupervisor expansion (Heir + 16
   partitions listed under DataSupervisor per an earlier contract) was
   RESTORED to the single `Smalt.Store` child per the coordinator's
   reconciliation decision, keeping the later BK-58 WsAmqpRelay child.

Boot sequencing: **adopt-then-replay** — partitions cold-CREATE their tables
with `{:heir, heir_pid, []}` (reference contract) and reclaim heir-held
tables via a real `:ets.give_away/3`; `Smalt.Store.Boot` replays the sealed
journal LAST, before the ensemble finishes starting (no request is served
until all 18 children are up → serving-equivalent to replay-then-adopt).
This ordering is load-bearing for two courted facts:

* a cold VM has NO tables until the partitions create them — a
  Boot-first order refuses boot with `{:bad_payload, ...}` (witnessed,
  see defects);
* a full-node kill deletes the tables (the dead-heir chain below), so the
  replay must run after they are recreated.

## Defects caught mid-lane (all fixed, courted)

1. **phash2 atom clustering**: hashing the table ATOMS put 90.6% of tables
   in one partition (measured 0.90625 — court leg1 caught it). Fixed by
   hashing `Atom.to_string(table)`; measured distribution max 5/35 tables.
2. **`:ets.give_away` does NOT reset the heir option** — tables created
   heir-to-`:init` could never come back to the Heir (courted: after a
   partition kill the owner stayed #PID<0.0.0> and every reclaim was a
   no-op). Fixed per the reference contract: partitions cold-create with
   `{:heir, heir_pid, []}`.
3. **Heir-as-pid, not module**: `{:heir, Smalt.Store.Heir, []}` is an
   ArgumentError at :ets.new (heir must be a pid). 
4. **Cold-VM boot refusal**: with Boot ordered before the partitions, a
   cold boot replayed into nonexistent tables → `{:bad_payload, ...}` boot
   refusal (witnessed). Fixed by adopt-then-replay ordering.
5. **Orphan-name collision killed the app**: a `:kill`'d ensemble
   supervisor dies without stopping its trapping children — the surviving
   Heir kept its registered name, the respawned ensemble's start aborted on
   `{:already_started, ...}`, DataSupervisor gave up, the whole smalt app
   exited (witnessed: leg3 timeout + "Application smalt exited: shutdown").
   Fixed with orphan-takeover in `Heir.start_link` and
   `Partition.start_link` (kill the orphan, retry start) plus a proper
   `{:EXIT,...}` handler in the Heir.
6. **Heir crash on parent death**: no `{:EXIT,...}` handler while
   trap_exit — the Heir crashed `:killed` when the ensemble sup died
   (witnessed). Fixed by the handler in (5).

## Crash court — `test/integration/ttv5_store_partitioning_court.exs` (4 legs, Chicago, no mocks, no sleeps)

- **Leg 1 — partition kill**: journaling DISABLED (survival cannot be
  replay's credit). Kills a real partition worker (`Process.exit(:kill)`);
  the Heir HOLDS its tables during the window (ownership poll); the other
  15 partitions serve SERIALIZED writes (next_seq) DURING the window; the
  supervisor restarts the worker, which RECLAIMS via real give-away
  (ownership verified back with the respawned pid); zero key loss; affected
  registry share 3/35 = 8.6% (BK-69 re-typed line). Honest note (BK-69):
  the measured keyspace ratio in the court's small-N workload is not
  bounded by table-level striping; the ≤6.25% keyspace gate is carried by
  the STORE-4 key-level court.
- **Leg 2 — monotonicity across a partition kill**: next_seq 101..105, kill,
  counter survives, next_seq continues at 106 (never resets); CAS on the
  heir-preserved row :ok with live etag, {:error, :conflict} on stale.
- **Leg 3 — full-node crash**: kill `whereis(Smalt.Store)` (the ensemble
  supervisor) with a sealed journal; tables are deleted by the dead-heir
  chain; the restarted ensemble recreates + replays — 100% of committed
  (sealed) keys survive; tombstone does not resurrect. 
- **Leg 4 — adversarial kill during the replay window**: 30,000 real sealed
  frames; a kill-poller kills the booting ensemble as soon as it registers
  (registration precedes child starts, so kills land in the boot/replay
  window or just after — either in-contract; the claim is convergence);
  the clean boot after the kill replays all 30,000 frames, samples verify
  values, boot never deadlocks.

## Command output

```
$ PATH=/Users/sac/.asdf/shims:$PATH MIX_BUILD_ROOT=_build-ttv5 mix test \
    test/integration/ttv5_store_partitioning_court.exs --seed 0
Result: 4 passed          EXIT=0   (seeds 0 / 12345 / 7 → 4 passed each)

$ MIX_BUILD_ROOT=_build-ttv5 mix test test/integration/ttv4_journal_boot_replay_court.exs --seed 0
Result: 4 passed          EXIT=0   (no regression; kill surface = ensemble sup)

$ MIX_BUILD_ROOT=_build-ttv5 mix test test/internal/journal_reader_court_test.exs \
    test/internal/rg404_concurrent_lifecycle_court.exs test/internal/ets_auto_court_test.exs --seed 0
Result: 19 passed         EXIT=0

$ MIX_BUILD_ROOT=_build-ttv5 mix compile 2>&1 | grep -cE "store.ex|store/partition|store/heir"
0                          (zero warnings from the lane's files)
```

## Cross-lane notes

- **STORE-2 supersession**: per the coordinator's reconciliation, restored
  `lib/smalt/plane/data_supervisor.ex` to the single `Smalt.Store` child
  (keeping BK-58's WsAmqpRelay child); STORE-2's Heir+16-partitions
  DataSupervisor expansion is superseded by the internal tree. Disclosed
  as directed.
- BK-65 fixed the 16× duplicate child-id (map-form ids) inside store.ex's
  child list mid-lane — kept (disclosed in its receipt).
- BK-69 re-typed court leg-1's keyspace clause to the table-share bound +
  the STORE-4 keyspace carrier — kept (its receipt owns that re-type).
- Two compile-freeze windows rode through other lanes' in-flight files
  (`SyncRoutes.ex`, `journal_sink.ex` — both fixed by their owners; no SLA
  unblock was applied by this lane; one earlier `store.ex` restore-from-HEAD
  during this lane's own edit sequence is disclosed as self-inflicted
  churn, final state compiles clean).
- Residual (documented, bounded): if the Heir dies while holding a dead
  partition's tables, those tables are deleted (heir not alive at transfer);
  bounded to tables already orphaned by a live partition crash, and the
  sealed journal replays them on next boot.

## Falsifier

Re-run the court on a fresh build root (delete `_build-ttv5`); any FAIL leg
or nonzero exit flips this receipt to SUSPECT. Leg 1 runs with journaling
DISABLED — zero loss there proves the heir+give-away path, not replay;
leg 3 proves the replay-only recovery face (tables deleted by the full-node
kill); leg 4 proves convergence under kills inside the boot/replay window.
