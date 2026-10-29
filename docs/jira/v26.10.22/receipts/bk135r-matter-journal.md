# BK-135r — matter-partitioned journal paths

**Standing: PARTIAL_ALIVE** — court + regressions + shim court all green on
the lane build root; not committed (per contract), pending coordinator
integration.

Context: solo

## What landed

Matter partitioning for the sealed journal (contract: `append_frame/5` gains
optional `:matter_scope`):

- `lib/smalt/storage/journal_sink.ex` — `append_frame/6` (opts:
  `:matter_scope`, `:ts`), `seal/2` (`matter_scope:`), `status/2`
  (`matter_scope:`), public `matter_root/2` (the ONE scope-naming law:
  `<dir>/matter_<scope>/segments/`) and `validate_scope/1`
  (`^[A-Za-z0-9][A-Za-z0-9._-]*$` — no path separators, no traversal).
  Scoped frames live entirely under
  `<dir>/matter_<scope>/segments/` with per-scope SeqIDs and mirrored
  SPOF-A1 (degrade/accept-and-drop/re-probe recovery, isolated per scope)
  and SPOF-A3 (triple-rename seal, per-scope quarantine) laws. Legacy
  no-scope path untouched: same handlers, same dirs, same names, same wire
  format.
- `lib/smalt/storage/journal_reader.ex` — `discover_sealed_segments/2`
  accepts `matter_scope:`, discovery +
  quarantine confined to the scope's own root (quarantine under
  `<dir>/matter_<scope>/segments/quarantine/`), via the sink's public
  `matter_root/2` (one path law, two consumers).
- `test/integration/bk135r_matter_journal_court.exs` — 3-leg court.
- `scripts/shim_court/bk135r_scoping_court.sh` — leg d.

## Court transcript (BK-135r court, exit 0)

```
$ MIX_BUILD_ROOT=_build-bk135r MIX_ENV=test mix test test/integration/bk135r_matter_journal_court.exs
...
Result: 3 passed
```

- leg (a): interleaved a1,b1,a2,b2 on ONE sink; per-scope seals;
  `discover_sealed_segments(dir, matter_scope:)` returns scope-confined
  paths; replay is strictly per-scope (alpha=[a1@seq0, a2@seq1], bravo
  likewise); unseen scope → `{:ok, []}`; invalid scopes
  (`../escape`, `a/b`) → `{:error, {:bad_matter_scope, _}}` with zero
  filesystem effect; exactly the two lawful scope roots exist.
- leg (b): alpha crash-tail (sealed, `.seal` withheld) quarantined under
  alpha's root ONLY (`[:smalt, :journal, :quarantined]` telemetry with
  `dir:` = alpha root); bravo discovery + replay untouched; a REAL probe
  Store boots twice against bravo's scope root and restores its committed
  key; alpha's quarantined bytes preserved.

## Regressions (exit 0)

```
$ MIX_BUILD_ROOT=_build-bk135r MIX_ENV=test mix test \
    test/integration/sj1_journal_sink_court.exs \
    test/integration/ttv4_journal_boot_replay_court.exs \
    test/integration/spofa_journal_court_test.exs
Result: 7 passed
$ MIX_BUILD_ROOT=_build-bk135r MIX_ENV=test mix test test/integration/sj4_journal_wire_court.exs
SJ-4 COURT: PASS
```

- leg (c) evidence: legacy SJ-1 (sink court) and TTV-4 (boot replay court)
  stay green; in the BK-135r court's leg (c) the legacy path mints NO
  matter_* dirs and `append_frame` with no scope rides the legacy path
  (default path byte-identical: same handlers, same dir layout, same
  segment names).

## Shim court (leg d, exit 0)

```
$ scripts/shim_court/bk135r_scoping_court.sh
[COURT] bk135r scoping court subject: lib/smalt/storage/journal_sink.ex
[SHIM] baseline sha256(lib/smalt/storage/journal_sink.ex) = c8556f273fccd14a129c9e42b1eca9f62c9323e57be855ed7d6e0c560894388a
[AFTER] leg a green on the landed matter scoping (3 tests, 0 failures)
[SHIM] matter_root/2 shimmed: scoped frames no longer partition (SHIM-COURT marker in place)
[BEFORE] leg a RED with scoping disabled — non-vacuity witnessed
[RESTORE] byte-exact restore verified (sha256 match)
[COURT] bk135r scoping court: PASS
```

Post-shim: `shasum -a 256` of journal_sink.ex matches the baseline
(`c8556f27...4388a`), zero `SHIM-COURT` markers remain, and the full court +
regression set re-ran green (7 passed) on the restored tree.

## Diffs (uncommitted, one canonical checkout /Users/sac/smalt, branch main)

- `lib/smalt/storage/journal_sink.ex` (modified)
- `lib/smalt/storage/journal_reader.ex` (modified)
- `test/integration/bk135r_matter_journal_court.exs` (new)
- `scripts/shim_court/bk135r_scoping_court.sh` (new)

## Falsifiers

- A court that can't flip is vacuous: disabling `matter_root/2` scope
  routing turns leg (a) red — witnessed in the shim court ABOVE phase.
- Invalid scope names are typed-refused before any filesystem effect
  (leg a).

## Boundary / residue

- Store's `replay_sealed/1` is scope-agnostic by design (boots against a
  base dir; a per-scope boot points `journal_sink_dir` at the scope root —
  exercised in leg b). No Store changes made or needed.
- Lane build root `_build-bk135r` left in place per lane-lease law
  (coordinator deletes at integration).
