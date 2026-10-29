# SPOF-A1/A-3 — JournalSink degraded mode + seal-window quarantine (SPOF-1)

**Standing**: ALIVE — both audit findings fixed on the working tree, falsification court 3/3 green (real disk-error injection, real crash-window simulation, real Store boot), SJ-1 + TTV-4 regression courts green on the patched tree.
**Context**: solo
**Date**: 2026-10-21
**Lane**: SPOF-1 (A-1 JournalSink crash-loop + A-3 .seal crash window), per `docs/jira/v26.10.22/receipts/spofa-beam-audit.md`
**Repo**: /Users/sac/smalt @ main (work done against 8006cc1-era tree; coordinator checkpoint sweep subsequently committed the in-flight files — see "Commit note")

## Findings fixed

### A-1 — JournalSink root crash-loop → typed-degraded mode

`lib/smalt/storage/journal_sink.ex`:

- init/continue/append/sync/seal never raise on File errors. `File.mkdir_p!/open!/write!/rename!/touch!` bangs replaced with checked calls; every failure path funnels through `degrade/2`: `Logger.error` with path+reason, `[:smalt, :journal, :degraded]` telemetry, `send_after(:reprobe)` bounded re-probe (`:reprobe_ms` opt, default 5_000), and the sink runs degraded — appends accepted-and-dropped (each drop `Logger.error` + counted in `:status.dropped`), seal typed-refused `{:error, :degraded}`, sync typed `{:error, _}`.
- Recovery: `handle_info(:reprobe)` re-probes dirs+open each cycle; success emits `[:smalt, :journal, :recovered]` + `Logger.info` and resumes active journaling; failure reschedules.
- `lib/smalt/application.ex`: sink child demoted to `Supervisor.child_spec(..., restart: :transient)`.
- `:status` widened additively: `%{path, bytes, frames, next_seq, mode, degraded_reason, dropped}`.

### A-3 — .seal rename-window wedge → rename-carries-completeness + quarantine

- Writer (`journal_sink.ex do_seal/1`): fsync → close → manifest + `.seal` sentinel STAGED BESIDE the segment in `active/` → rename triple into `sealed/` (segment, manifest, sentinel LAST rename). Any crash inside the rename window now leaves an incomplete triple in `sealed/` — a completeness failure, not a wedge.
- Reader (`lib/smalt/storage/journal_reader.ex discover_sealed_segments/1`): a `sealed/*.journal` missing its sealed `.seal` or `.meta.json` is renamed into `<dir>/quarantine/` (bytes preserved, `Logger.warning`, `[:smalt, :journal, :quarantined]` telemetry with `%{path, dir, reason}`; if quarantine rename/mkdir fails the segment is excluded loudly, never crashed on). `read_sealed_segment/1` keeps the typed `{:not_sealed, path}` refusal for direct callers — SJ-2 law preserved. Integrity failures (manifest/CRC/truncation/seq) still boot-refuse fail-closed — TTV-4 law preserved.

## Court

`test/integration/spofa_journal_court_test.exs` (new; committed to HEAD by the coordinator sweep, sha `3374a345…`). Legs:

- **(a)** real disk-error injection (journal dir under a regular file → `:enotdir`): sink boots `{:ok, _}` in `:degraded` mode, process alive, `[:smalt,:journal,:degraded]` telemetry fired with path+reason, appends `{:ok, seq}` + `dropped == 2` counted, seal `{:error, :degraded}` typed, no restart (same pid), recovery after blocker removal via 25ms re-probe emits `[:smalt,:journal,:recovered]` and post-recovery appends hit real disk bytes. No mocks, no sleeps (bounded `Poll.eventually` only).
- **(b)** crash-in-seal-window: two real sealed segments (seg1 complete, seg2 sentinel withheld = the exact audit crash state), real Store probe-boot against the dir → **boot succeeds**, seg2 renamed to `<dir>/quarantine/`, `[:smalt,:journal,:quarantined]` telemetry with `reason: :not_sealed`, committed keys from seg1 survive via replay (replay restored 2 frames), seg2's key absent from replay (bytes preserved in quarantine), second boot stable.
- **(c)** corrupt sealed segment (1-bit flip vs honest manifest) → typed boot refusal `{:journal_replay_failed, {seg, {:manifest_mismatch, _}}}` (refusal surfaces verbatim through the failure wrapper) — fail-closed preserved.

## Verification (commands + exits)

```
MIX_BUILD_ROOT=_build-spofa mix compile                                    → OK (pre-existing warnings only)
MIX_BUILD_ROOT=_build-spofa mix test test/integration/spofa_journal_court_test.exs
  final run (/tmp/spofa-final.log): Result: 3 passed, exit 0
MIX_BUILD_ROOT=_build-spofa mix run test/integration/sj1_journal_sink_court.exs
  (/tmp/sj1-final2.log): LEG 1..5 + "SJ-1 COURT: PASS", exit 0
MIX_BUILD_ROOT=_build-spofa mix test test/integration/ttv4_journal_boot_replay_court.exs
  (/tmp/ttv4-final.log): Result: 4 passed, exit 0
```

TTV-4 A/B note: earlier runs showed TTV-4 2/4 on both baseline AND patched tree during heavy concurrent-lane
noise (port collisions `:eaddrinuse`, a mid-edit amqp compile break from another lane); in the quiet window
the patched tree is **4/4**. SJ-1 required the shared substrate down for the fixed court ports; it was taken
down through `just substrate-down`, run executed, substrate restored (`just substrate-up`, pid 26384, lock FREE).

## Non-vacuity face

The court's leg (a) is a real filesystem-structured injection (regular file where the journal parent dir
should be → real `:enotdir`), not a mock: the pre-patch sink RAISED in `init/1` on exactly this input
(`File.mkdir_p!`), killing the root supervisor's restart budget. Leg (b)'s withheld sentinel is the audit's
exact crash state (segment in `sealed/` without `.seal`), which pre-patch wedged boot with
`{:journal_replay_failed, {:not_sealed, ...}}` forever.

## Commit note

The coordinator's checkpoint sweep (HEAD fc57ba2-era) committed the in-flight lane files, including this
lane's `lib/smalt/storage/journal_sink.ex` (sha `874a0ec0…`), `journal_reader.ex`, `application.ex`
(`restart: :transient`), and the new court file. Disk == HEAD verified byte-identical at receipt time.
This lane performed no commits.

## Residuals (out of lane, disclosed)

- Concurrent-lane WIP (STORE-2 Store→supervisor refactor) mid-receipt changed the boot-refusal wrapper shape;
  my court's leg (c) asserts through a small unwrap helper. TTV-4's own assertions are green in a quiet window.
- Pre-existing lib warnings (law_compiler read_block, Mcp.Router clause shadows) — not this lane's diff.
