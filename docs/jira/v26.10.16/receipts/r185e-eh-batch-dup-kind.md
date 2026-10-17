# Receipt — R185e (Event Hubs batch discriminator rewrite: duplicate-section-KIND detection, KD-53)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Supersedes:** R166's count-based multiplicity check
- **Standing:** PASS
- **Date:** 2026-10-16 (milestone-doc lane, lane226 build root)

## What changed and why

R166's count-based multiplicity check rejected the real `@azure/event-hubs`
SDK inner shape `[header, message_annotations, properties,
application_properties, body_data]` — a 5-section inner message whose section
count does not match the assumed shape, which resurrected the KD-53
silent-drop (inner events 2..N lost).

R185e replaces the discriminator with:

- **Duplicate-section-KIND detection per group**: sections are keyed by AMQP
  section KIND within each inner-message group; a repeated KIND inside one
  group marks the group boundary.
- **Shape-sequence homogeneity**: groups are validated for a consistent
  section sequence; any group that fails inner-message decode fails closed
  to ONE event (never a silent partial drop).

Subject file: `lib/smalt/messaging/event_hubs.ex` (KD-COVERS: KD-53 token at
line 84; batch-envelope detection at ~line 121; R166-supersession note at
~line 204; reconcile matching noted at ~line 413).

## Verification (2026-10-16, unedited output)

```
$ MIX_BUILD_ROOT=_build-lane226 mix test test/amqp/event_hubs_test.exs
..........................
Finished in 0.5 seconds (0.00s async, 0.5s sync)
26 tests, 0 failures (3 excluded)
```

```
$ just shim-court eh_batch
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] eh_batch_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
(exit 0)
```

```
$ just shim-court wire_norm
[COURT] WIRE-NORM COURT: ALL LEGS PASSED
(exit 0)
```

- KD-53 row (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:136`): CLOSED-SIMULATED
  — unchanged; shim + witness receipt already registered, R185e is the
  discriminator-mechanism rewrite on the same closed seam, not a row flip.

Standing: PASS (26/0 suite green, both courts non-vacuous, restore
byte-exact; no register flips performed — none authorized to this lane).
