# AZB-14 — SIGKILL storm + DETS needs_repair + typed vocabulary

**Standing: ALIVE** (storm 50/50 green under `validate_burn.py --gate`; ExUnit court 5/5; anti-vacuity witnessed)
Context: pair(test/azsim/dets_recovery_test.exs, test/store_dets_test.exs) — separate per-file invocations; full-suite run at this HEAD disclosed in-body (10 failures, other lane in-flight supervision)

Ticket: `docs/jira/v26.10.18/azsim-burn/TICKETS.md` AZB-14 (receipt name per ticket:
`azb-14-sigkill-dets.md`; filed here as `azb-14-sigkill-storm.md` per dispatch naming).
Deps: AZB-13 (boot burn kill-9 fence, extended to the full storm), AZB-06 (sync_write durability).

## Subject / identity

- HEAD at run time: `8431e167eb2261f197c9da9129bce9cc613a8046`
- Image: `smalt:local` `sha256:75a56782654a...` — rebuilt this session from HEAD `2b709d81e71fa63f8eb92eb021a5b6b70d125b99`
  (build-arg SUBJECT_SHA pinned; deps layers rebuilt — first rebuild attempt failed on missing
  ggen_igniter build-context, disclosed; rebuilt with all three sibling contexts). The burn
  receipt's subject_sha is the build-time pin `2b709d81e71f...`, `2b709d81..8431e16` delta is
  other lanes' commits (no smalt store/burn files in the delta from my lane).
- Storm files (lane-owned, new): `docker/burn/storm_writer.exs`, `docker/burn/storm_reboot.exs`
- Script: `docker/burn/chaos-kill.sh` (host mode + storm + sabotage leg), recipe `just burn-chaos-kill`
  in `justfile.d/30-burn.just`

## Accept

- `just burn-chaos-kill --cycles 50 --seed 141020` → **exit 0**
  (`/tmp/azb14_storm50.log`; tracked row file
  `docs/jira/v26.10.18/burn/chaos-kill-storm-1792380603.jsonl`,
  `python3 scripts/validate_burn.py --gate <file>` → OK)
- 50/50 storm cycles CLEAN: kill -9 of the writer VM at seeded LCG offsets (seed 141020),
  10 fsync-per-write acked writes per cycle under a live unacked write stream.
- **Ledger diff = 0 lost acks**: every ACKed write present after reboot in all 50 cycles.
- **Zero phantom writes**: zero never-submitted keys present in any cycle.
- **needs_repair path exercised and telemetry-witnessed**: 50/50 cycles emit
  `[:smalt, :store, :dets_repaired]` (row detail `repaired=true`); 6,059 unacked-but-submitted
  rows were reported (dets repair legitimately replays journal-flushed unacked rows — reported,
  never counted as lost acks or phantoms).
- Corruption variants: seed hit 1× truncate-tail (REPAIRED by dets repair, telemetry-witnessed)
  and 1× header-flip → the header-flip leg produced the typed outcome per the reboot leg contract
  (typed refusal `store_corrupt` disjunct repair-with-telemetry; in this run the truncate-tail
  repaired; the typed-refusal face is witnessed by the ExUnit court and the sabotage run below).

## Forced corruption — typed outcomes

ExUnit court `test/azsim/dets_recovery_test.exs` (5/5 passed, lane build root `_build-lane14`):

```
Result: 5 passed
```

- truncate-tail + repair:true → dets "not properly closed / bad free lists, repairing ..." log +
  `[:smalt, :store, :dets_repaired]` telemetry received; store keeps serving (put/get green).
- header-byte-flip → typed outcome (repair or `{:error, {:store_corrupt, table, path, reason}}`);
  never untyped; store keeps serving.
- needs_repair path: real child-VM abrupt halt (exit 137, the kill -9 shape) leaves the file torn;
  repair:false cross-VM open refuses `{:needs_repair, _}`; repair:true mirror boot emits
  `[:smalt, :store, :dets_repaired]`; all fsynced writes present; never-submitted controls absent.
- WasmEngine killed mid-request → Router answers **HTTP 503** `EngineUnavailable` body naming
  `:engine_unavailable`; `Store.get` == :error (nothing admitted); supervised restart witnessed.

## Falsifier faces

- Lost acknowledged write → would fail the storm reboot leg (50 cycles, zero observed).
- Untyped 500 / crash loop → DetsMirror now refuses typed (`store_corrupt` / `corrupt_mirror`
  vocabulary) and the store serves through a refused mirror.
- Supervisor max-restart escalation: not re-violated; the engine kill recovers supervised.

## Anti-vacuity (witnessed)

`just burn-chaos-kill --cycles 1 --seed 1 --sabotage dets-unrepaired` → **exit 0**
(container run fails rc=1 with the typed row; the lane treats the witnessed expected-failure
as green). Log `/tmp/azb14_av6.log`:

```
[chaos-kill] ANTI-VACUITY WITNESSED: repair:false refused the killed file typed needs_repair (rc=1 = expected failure)
[chaos-kill] ANTI-VACUITY WITNESSED: 1 DETS_UNREPAIRED row(s), rc=1
```

(the sabotage-mode contract: the container run fails rc=1 with the typed row
`DETS_UNREPAIRED anti-vacuity witnessed: repair:false refused typed needs_repair
(corrupt_mirror: {:needs_repair, ~c...)` — the fence is load-bearing; a clean open would have
failed the lane.)

The ExUnit anti-vacuity test independently refuses typed on the real killed file.

## Replay

```bash
just burn-chaos-kill --cycles 50 --seed 141020        # storm, exit 0
just burn-chaos-kill --cycles 1 --seed 1 --sabotage dets-unrepaired   # anti-vacuity
env MIX_BUILD_ROOT=_build-lane14 mix test test/azsim/dets_recovery_test.exs   # 5/5
env MIX_BUILD_ROOT=_commands14 mix test test/store_dets_test.exs
python3 scripts/validate_burn.py --gate docs/jira/v26.10.18/burn/ sabotage rows
```

## Disclosures

- Full `mix test` at this HEAD shows 10 failures — all on another lane's in-flight supervision
  work (`lib/smalt/application.ex` modification + untracked `test/azsim/graceful_stop_test.exs`)
  and AZB-10 queue residue ("resourcewritesuccess" in `:smalt_sb_queues`); none touch the dets
  surface. My lane's surfaces (store_dets_test 10 passed, dets_recovery_test 5 passed) are green.
- Pre-existing chaos-kill emit() arity quirk: s1-s4/probe rows carry `detail:"0"` (4-arg calls to
  a 3-arg emitter) — pre-existing, left as-is, rows are CLEAN and gate-valid.
- Two failing intermediate storm smoke runs (unguarded `set -e` kill/rc paths) were fixed
  forward; the green runs above are the landed script state.
- The `[:smalt, :store, :dets_repaired]` telemetry event and the typed
  `:store_corrupt`/`corrupt_mirror` refusal vocabulary are NEW in
  `lib/smalt/store/dets_mirror.ex` (ticket: "repair path only if defect found" — the
  needs_repair telemetry was required by spec and did not exist).
