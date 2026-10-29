# EXPL11-R3 — planes + ConfidentialLedger seg_meta repairs (EXPL-11 F4/F5)

- **Date**: 2026-10-22
- **Lane**: EXPL11-R3, repo /Users/sac/smalt (canonical checkout, MIX_BUILD_ROOT=_build-expl11r3)
- **Surface**: `lib/smalt/planes.ex` (F4), `lib/smalt/confidential_ledger/service.ex` seg_meta surface (F5)
- **Standing**: ALIVE
- **Context**: solo

## F4 — empty plane selection refuses typed

planes.ex carried the EXPL-11 F4 fix on disk at session open (EXPL11-R lane's
landed work, committed in the coordinator checkpoints): `resolve/0` raises
`Smalt.Planes.InvalidPlane` (`{:invalid_plane, []}`) on the app-env `[]`
path; `SMALT_PLANES=""` -> `:all` and non-empty selections unchanged. My
contribution: verification + the falsifier court the finding names — a REAL
subprocess boot:

```
$ MIX_BUILD_ROOT=_build-expl11r3 mix test test/internal/expl11r3_court_test.exs --include expl11r3
Result: 7 passed          # 3 F4 legs + 4 F5 legs, 14.3s sync
```

Subprocess leg: `mix run --no-start` with `Application.put_env(:smalt, :planes, [])`
then `Application.ensure_all_started(:smalt)` refuses; the script surfaces
`Smalt.Planes.resolve()` typed refusal, exit 3, `TYPED-REFUSAL: {:invalid_plane, []}`,
no `BOOTED-NO-REFUSAL`. `SMALT_PLANES=""` -> :all witnessed unchanged in-proc.

## F5 — seg_meta typed missing/corrupt-meta handling

`lib/smalt/confidential_ledger/service.ex`:

- `seg_meta/1` was `%{}`-on-error (success-on-unknown); now typed
  `{:ok, meta} | {:error, :missing_meta | :corrupt_meta}` (matches
  JournalReader's `{:missing_meta, path}` idiom).
- `certify_segment/2` now refuses missing/corrupt meta and a frame-bearing
  segment whose meta lacks integer `first_seq`/`last_seq` typed
  (`:missing_meta` / `:corrupt_meta` / `:empty_segment` preserved), instead
  of feeding `nil` into `committing_seg` (`seq >= nil` certify-tick crash
  class). `refuse_segment/4` extracted; the re-read of meta in the committed
  body is gone (bounds taken from the validated map).

Court legs (real JournalSink on real disk, real service GenServer, no mocks;
`Service.certify/0` forced synchronously after meta tamper + restart):

- non-vacuity positive leg: healthy segment certifies, `first_seq: 0,
  last_seq: 0`, meta file present
- F5a corrupt meta JSON -> seg record `{:refused, :corrupt_meta}`, service
  alive after the certify pass
- F5b bounds-less meta (frames=1, no first_seq/last_seq) -> `:corrupt_meta`,
  no nil-compare crash — pre-fix this shape crashed the certify tick
- F5c meta file removed -> fail-closed at discovery (never committed);
  service alive

```
$ MIX_BUILD_ROOT=_build-expl11r3 mix test test/internal/expl11r3_court_test.exs \
    test/internal/expl11r_court_test.exs test/internal/expl11r1_ledger_range_court_test.exs \
    test/internal/expl6r1_journal_court_test.exs test/internal/journal_reader_court_test.exs \
    test/internal/kql_sealed_court_test.exs
Result: 45 passed

$ MIX_BUILD_ROOT=_build-expl11r3 mix test test/integration/az3_confidential_ledger_court_test.exs
Result: 6 passed

$ MIX_BUILD_ROOT=_build-expl11r3 mix test test/internal/expl11r3_court_test.exs \
    test/internal/internal_tier_census_test.exs --include internal
Result: 13 passed
```

Census registration: `expl11r3_court_test.exs => :internal` row added to
`test/internal/internal_tier_census_test.exs` (additive row; the census
Jason-decode scan forced removing `Jason.decode!` from the court — the
in-memory seg_record carries the same facts).

## Disclosure

The coordinator tick checkpoints swept my in-flight files (service.ex F5
fix, court test, census row) into HEAD before I could commit — same pattern
BK-FONDSD disclosed. This commit is the receipt alone; code truth is at
HEAD (verified by re-read + the green runs above). Census fails observed
mid-wave on unregistered expl11r3 were mine, resolved by the registration.

## Falsifiers

- F4: `config :smalt, :planes, []` boots — REFUTED (subprocess exit 3,
  TYPED-REFUSAL witnessed; exit 0/`BOOTED-NO-REFUSAL` asserts make the court
  fail on regression).
- F5: corrupt/bounds-less/missing meta produces nil-compare crash or
  committed-over segment — REFUTED (typed refusals witnessed, service alive
  after forced certify; positive leg proves the certify path still works).
