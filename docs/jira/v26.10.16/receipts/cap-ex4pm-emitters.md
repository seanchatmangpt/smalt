# Receipt: cap-ex4pm-emitters

- **Lane**: DoD (capability receipts), v26.10.16
- **Date**: 2026-10-16
- **Repo / subject**: /Users/sac/smalt @ main (docs lane; no build/test runs performed by this lane)
- **Standing**: ALIVE

## Scope (what landed)

CourtOcel emitters close the court→OCEL loop: court infrastructure itself
now emits object-centric events into the NDJSON sink (`tmp/ocel/events.ndjson`).

- **doctor.receipt emitter** — `lib/mix/tasks/smalt.doctor.ex` L50–55:
  after each completed doctor run, `Smalt.Telemetry.CourtOcel.doctor_receipt/2`
  emits one `doctor.receipt` event (fail-safe, registry-gated —
  `{:ok, :dropped}` is loud, never a crash).
- **court.run emitter** — `lib/smalt/telemetry/court_ocel.ex`
  `court_run/2`, wired into the gate via
  `lib/mix/tasks/smalt.court_emit.ex` (`mix smalt.court_emit --receipt
  <log> --run <run> --verdict <verdict>`, always exit 0, fail-safe).
- **Gate wiring** — `scripts/court_x2.sh` L74: post-judge, each court log
  is emitted as one `court.run` event
  (`MIX_BUILD_ROOT=… mix smalt.court_emit --receipt "$log" --run "$run"
  --verdict "$verdict" >/dev/null 2>&1 || true`) — telemetry can never
  break the gate.
- **Anti-vacuity (mutated-event flip test)** —
  `test/court_ocel_test.exs` L69: `registry gate is non-vacuous: an
  unknown event type is dropped, not admitted` — a mutated event type is
  DROPPED into `bad_events.ndjson` (kept for adjudication, never silently
  dropped), proving the registry gate can refuse, not just admit.
- **Assembly closure** — implementing lane reported **6972 events,
  ASSEMBLY_OK** via `Smalt.Telemetry.OcelNdjson.assemble_document/1`
  (registry-declared types + every type actually used; assembly fails
  closed on undeclared types, ocel_ndjson.ex L16–22, L75–78). Static
  check at receipt time (real output; sink has grown past the reported
  count — growth is append-only, consistent with closure):

```
$ wc -l /Users/sac/smalt/tmp/ocel/events.ndjson /Users/sac/smalt/tmp/ocel/bad_events.ndjson
    6983 /Users/sac/smalt/tmp/ocel/events.ndjson
      12 /Users/sac/smalt/tmp/ocel/bad_events.ndjson
    6995 total
```

## Evidence (cited, not re-run — DoD lane: no build/test runs)

- Suite: `test/court_ocel_test.exs` — **4 tests, 0 failures** as landed by
  the implementing lane (cited per dispatch; not re-executed by this lane).
  Test names verified on disk (real grep): doctor.receipt emission with
  enclave + document objects (L33), court.run with stages/verdicts/run
  (L58), registry non-vacuity mutated-event flip (L69), court_emit task
  judging a synthetic green receipt (L83). `court.run` and `doctor.receipt`
  are both declared in `lib/smalt/ocel/event_registry.ex` L27–28.

## Consequence

`docs/jira/v26.10.16` capability ledger row: courts are first-class OCEL
subjects — every doctor and court-x2 run leaves a receipted event in the
process log, with a refuse-capable (non-vacuous) registry gate.

## Falsifier

A court-x2 run whose log yields no `court.run` line in
`tmp/ocel/events.ndjson`, or a mutated/unknown event type admitted past
the registry gate, falsifies this receipt.

## Replay

```
grep -n "court_emit" /Users/sac/smalt/scripts/court_x2.sh
grep -n "doctor_receipt\|CourtOcel" /Users/sac/smalt/lib/mix/tasks/smalt.doctor.ex
grep -c "test " /Users/sac/smalt/test/court_ocel_test.exs
wc -l /Users/sac/smalt/tmp/ocel/events.ndjson /Users/sac/smalt/tmp/ocel/bad_events.ndjson
```
