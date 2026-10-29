# EXPL6-R1 — journal reader/sink repairs: EXPL-6 F1/F2/F3

**Standing:** ALIVE
Context: solo
Date: 2026-10-22
Lane: EXPL6-R1
Build root: `_build-expl6r1` (lane-local, deleted at integration)

## Scope

Repairs the three journal-surface findings from
`docs/jira/v26.10.22/receipts/expl6-messaging-arm-errc.md`:

- **F1 (HIGH)** — `lib/smalt/storage/journal_reader.ex`: two unguarded header
  matches raised raw MatchError on corrupt sealed segments.
- **F2 (HIGH)** — `lib/smalt/storage/journal_sink.ex` `handle_call({:seal_scope, ...})`
  crashed with CaseClauseError on `{nil, sc}` when sealing a never-appended
  matter scope.
- **F3 (MEDIUM)** — both pre-write rotation legs (legacy `do_append/6` and
  scoped `maybe_rotate_scope/4`) matched seal-success only; a
  `{:error, {:seal_failed, _}}` crashed the sink mid-append (SPOF-A1
  violation). The legacy `handle_call(:seal)` case also matched success-only
  and is repaired in the same class.

## Diff

### F1 — `journal_reader.ex`

- Added `{:bad_magic, keyword()}` to the `@type refusal` vocabulary.
- `parse_frames/4`: the `<<@magic, frame_len::32, _>>` unguarded match is
  replaced by an explicit header decode + `cond`:
  - `magic != @magic` → `{:error, {:bad_magic, offset: offset}}`
  - `frame_len < 4` (CRC width) →
    `{:error, {:truncated_frame, reason: :bad_frame_len, ...}}` — this keeps
    `decode_one/3`'s `body_size = frame_len - 4` non-negative, closing the
    F1b MatchError window at its root.
  - otherwise recurse into `parse_frame_at/5` (extracted; unchanged logic:
    truncation, CRC, monotonic SeqID checks).
- No wire change: sealed segments written by the sink are always well-formed;
  this is strictly corrupt-input hardening of the replay path.

### F2 — `journal_sink.ex`

- `handle_call({:seal_scope, ...})` gains the `{nil, sc}` clause replying
  `{:error, :empty_segment}` (mirrors legacy `do_seal`'s `{nil, state}`
  contract), storing the scope state so the scope can still be appended to
  and sealed later.

### F3 — `journal_sink.ex`

- Legacy `do_append/6` rotation: the case gains
  `{{:error, {:seal_failed, _}}, st} -> {st, byte_size(frame)}` — `do_seal`
  has already degraded the sink (io closed, reprobe armed), so the frame
  falls through to the degraded accept-and-drop path: `{:ok, seq}` reply,
  dropped counter increments, no crash.
- Scoped `maybe_rotate_scope/4`: same error clause; `do_scope_seal` has
  degraded only that scope (BK-135r isolation preserved — other scopes and
  the legacy journal keep journaling, court-verified in leg F3-scoped).
- `handle_call(:seal)`: gains `{{:error, reason}, state} -> {:reply, {:error, reason}, state}` —
  a direct seal on an active sink with a real filesystem seal failure now
  answers `{:error, {:seal_failed, detail}}` instead of CaseClauseError.

## Court (test/internal/expl6r1_journal_court_test.exs, 9 legs, all green)

```
$ MIX_BUILD_ROOT=_build-expl6r1 mix test test/internal/expl6r1_journal_court_test.exs
Running ExUnit with seed: 824261, max_cases: 32
Result: 9 passed
```

Legs (all real files on disk / real sink processes, no mocks, no sleeps):

- F1a: corrupt magic segment → `{:error, {:bad_magic, offset: 0}}`
- F1b: `"SMAL"` + frame_len 0..3 → `{:error, {:truncated_frame, reason: :bad_frame_len}}` (4 sub-legs)
- F1c: magic-only truncated tail → `{:truncated_tail, ...}` (regression)
- F1 round-trip: real sink-sealed segment reads back `{:ok, [frame]}`
- F2: `seal(matter_scope: "neverused")` → `{:error, :empty_segment}`, sink alive, mode :active
- F3 legacy: rotation-leg seal failure (directory planted at the sealed
  target → real `:eisdir`) → append still `{:ok, seq}`, mode :degraded,
  dropped == 1, reason `{:rename, _, :eisdir}`
- F3 scoped: same fault scoped — scope t1 degraded + dropped 1, legacy
  journal + scope t2 keep journaling (isolation law)
- F3 seal/1: direct `seal/1` on active sink with a real rename failure →
  `{:error, {:seal_failed, {:rename, _, :eisdir}}}`, mode :degraded

Degraded-mode telemetry observed during the F3 legs (real Logger.error
output, verbatim):

```
04:38:39.928 error[] Smalt.Storage.JournalSink: matter scope t1 entering DEGRADED mode (rename) path=.../matter_t1/segments/sealed/seg-00000000000000000000.journal reason=:eisdir; scoped appends accepted-and-dropped until the volume returns
04:38:39.930 error[] Smalt.Storage.JournalSink: matter scope t1: append dropped (degraded scope, reason={:rename, ..., :eisdir}) [dropped_total=1]
04:38:39.934 error[] Smalt.Storage.JournalSink: entering DEGRADED mode (rename) path=.../sealed/seg-00000000000000000000.journal reason=:eisdir; appends accepted-and-dropped until the volume returns
```

## Regression courts (all exit 0)

```
$ for f in sj1_journal_sink_court.exs sj4_journal_wire_court.exs \
    bk135r_matter_journal_court.exs spofa_journal_court_test.exs \
    ttv4_journal_boot_replay_court.exs ttv5_store_partitioning_court.exs \
    store_partition_wire_regression_test.exs; do mix test test/integration/$f; echo "$f exit=$?"; done
sj1_journal_sink_court.exs exit=0            (SJ-1 COURT: PASS)
sj4_journal_wire_court.exs exit=0            (SJ-4 COURT: PASS)
bk135r_matter_journal_court.exs exit=0       Result: 3 passed
spofa_journal_court_test.exs exit=0          Result: 4 passed
ttv4_journal_boot_replay_court.exs exit=0    Result: 4 passed
ttv5_store_partitioning_court.exs exit=0     Result: 4 passed
store_partition_wire_regression_test.exs exit=0  Result: 6 passed
journal_reader_court_test.exs exit=0         Result: 15 passed
```

Known pre-existing red (NOT session-introduced by this lane): the
internal-tier census (`test/internal/internal_tier_census_test.exs`) fails 4
legs on OTHER lanes' in-flight unregistered files (`kd173r_audience_scope_court_test.exs`,
`bkamqpf_f2a_boundary_court_test.exs`, `eplaw_ephemeral_boot_court_test.exs`).
My file `expl6r1_journal_court_test.exs` is registered in the census list
(internal_tier_census_test.exs:47). Census exit=2 pre-dates this lane's diff.

## Falsifier

Each repair flips a witnessed crash to a typed answer:
F1a/F1b probes that raised raw MatchError (EXPL-6 receipt witness) now return
typed refusals; F2's CaseClauseError becomes `{:error, :empty_segment}`;
F3's mid-append sink crash becomes SPOF-A1 degrade-and-drop. The court legs
are the falsifiers: any regression re-raises/crashes exactly as the EXPL-6
witness described.
