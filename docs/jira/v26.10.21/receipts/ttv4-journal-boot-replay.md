# TTV-4 — JournalReader boot-replay wired into Smalt.Store

**Standing:** **ALIVE**
Context: solo
Date: 2026-10-21
Lane build root: `MIX_BUILD_ROOT=_build-ttv4` (lease; delete at integration)
Files owned/edited: `lib/smalt/store.ex`, `test/integration/ttv4_journal_boot_replay_court.exs` (new). `lib/smalt/storage/journal_reader.ex` read, **unchanged** (the SJ-2 fail-closed API needed no edits).

## Diff summary

`lib/smalt/store.ex` (TTV-4):

- `init/1` now runs **replay-then-listen**: after table creation,
  `boot_replay/1` resolves the journal dir from the existing
  `:journal_sink_dir` config (per-instance `opts` override supported for
  courts), and when set, replays every SEALED segment via the existing SJ-2
  fail-closed reader (`discover_sealed_segments/1` +
  `read_sealed_segment/1`) BEFORE the GenServer finishes init. When the
  config is unset the whole path is a no-op — byte-identical default boot.
- New public `Smalt.Store.replay_sealed/1`:
  `{:ok, applied_count}` | `{:error, {seg_path, typed_reason}}`, halting at
  the first typed refusal. Non-Store frames (OcelEmitter codes
  0x0001..0x0004) are skipped BY EVENT TYPE — they are another writer's
  records, not corruption.
- Frame contract: Store-owned u16 event types 0x0A01 (put) / 0x0A02
  (delete tombstone). Wire table identity = index into the generated
  `Smalt.StoreTables` registry (u16), compiled to `@table_id_by_name` /
  `@table_name_by_id` maps at module compile time. Frames are appended
  through `Smalt.Storage.JournalSink.append/5` (full module name — a bare
  alias inside `Smalt.Store` would expand to `Smalt.Store.JournalSink`),
  journal-then-apply (WAL order) from put/delete (caller side) and inside
  `handle_call` for the serialized ops (insert_new / CAS / cas_delete /
  next_seq). Best-effort log-drop on sink down, same fail-safe law as the
  SJ-4 OcelEmitter journal path.
- `start_link/1` gains an optional `:name` opt (default `Smalt.Store`
  unchanged) so courts can boot scratch instances against scratch dirs.
- Zero compile warnings for the module
  (`mix compile | grep -c "lib/smalt/store.ex"` = 0).

## Crash court (`test/integration/ttv4_journal_boot_replay_court.exs`) — 4 legs, Chicago, no mocks, no sleeps

- **Leg 1 — OFF default byte-identical**: config unset, no sink process,
  put/get/delete behave exactly as before.
- **Leg 2 — real crash court**: real sink, real puts across two tables,
  real `Store.delete` tombstone, real `JournalSink.seal/1`, real
  `Process.exit(pid, :kill)` of the live Store under
  `Smalt.Plane.DataSupervisor` — supervisor restart, init replays the
  sealed journal, bounded poll (`SmaltTest.Internal.Poll.eventually/2`)
  confirms restart; every committed key survives; the tombstoned key does
  NOT resurrect. Also a sealed-bytes face: the segment's frames decode to
  exactly the 4 mutations (3 puts + 1 tombstone) with the tombstone typed
  0x0A02.
  `MIX_BUILD_ROOT=_build-ttv4 mix test ... --seed 0 | 12345 | 7` — all
  `Result: 4 passed`, EXIT=0 (also re-run post-commit-tick, EXIT=0).
- **Leg 3 — corrupt segment boot-refusal**: 1-bit flip against the honest
  manifest → `{:error, {:journal_replay_failed, {seg,
  {:manifest_mismatch, ...}}}}` (reader refuses before any frame parse).
- **Leg 4 — truncated tail boot-refusal**: truncation to 5 bytes with a
  re-stamped manifest sha256 so the refusal reaches the per-frame gate →
  `{:error, {:journal_replay_failed, {seg, {:truncated_tail,
  [offset: 0, have: 5]}}}}`. Boot-refuse, never a silent skip. (Booted in
  a trap-exiting probe process because an `init {:stop, ...}` exit
  propagates to a linked non-trapping caller.)

## Command output

```
$ PATH=/Users/sac/.asdf/shims:$PATH MIX_BUILD_ROOT=_build-ttv4 mix test \
    test/integration/ttv4_journal_boot_replay_court.exs --seed 0
...
Finished in 0.4 seconds (0.00s async, 0.4s sync)
Result: 4 passed
EXIT=0   (seeds 0 / 12345 / 7 all 4 passed; final receipt run EXIT=0)

$ MIX_BUILD_ROOT=_build-ttv4 mix compile 2>&1 | grep -c "lib/smalt/store.ex"
0
```

## application.ex note (per dispatch: report, do not edit)

`lib/smalt/application.ex` needs **no changes**: the sink child
(`journal_sink_child/0`) is already config-gated there, and Store's replay
reads the same `:journal_sink_dir` config in its own init — replay works
because the reader is pure file access (the sink process is not needed at
replay time; it is a later sibling in the boot order).

## Defect caught during the lane

The first append probe exposed a real latent bug in my own first cut: the
bare alias `JournalSink` inside `Smalt.Store` expands to
`Smalt.Store.JournalSink` (noproc exit → log-dropped appends, seal counted
0 frames). Fixed by calling the full name `Smalt.Storage.JournalSink`.

## Cross-lane notes

- A mid-session flake of `test/internal/bk14_kd143_sqlfilter_persistence_test.exs`
  (assert n >= 1, left: 0) was investigated with a true-baseline run
  (pre-TTV-4 store.ex from `08acebf^`): baseline 3/3 PASS; my version
  initially 1 failure, then 3 consecutive re-runs 3/3 PASS. The single
  failure coincided with the coordinator's in-flight edit tick on that
  file (009ad2c, 12-line edit). Reading of the evidence: not attributable
  to the TTV-4 diff; flagged for the bk14 lane to re-census.
- Pre-existing, not session-introduced: `mix compile --warnings-as-errors`
  fails on `Smalt.Mcp.Router.flatten_children/2` (disjoint comparison,
  lib/smalt/mcp/router.ex:1516) — file unmodified by this lane; store.ex
  contributes 0 warnings.

## Falsifier

Re-run the court on a fresh build root; any FAIL leg or nonzero exit flips
this receipt to SUSPECT.
