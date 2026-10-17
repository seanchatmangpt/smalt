# R166 — EH discriminator + dead clause

Standing: PARTIAL_ALIVE

## Scope

EH multi-event batch discriminator landing (KD-53 family, `lib/smalt/messaging/event_hubs.ex:84`
KD-COVERS marker — split at ingest) plus the dead/unreachable clause removal
on the EH read path. KD-53: a producer `createBatch` envelope carrying N
inner events must yield N events, not one blob.

## Re-run output (docs lane, 2026-10-16, `_build-lane207`)

```
$ MIX_BUILD_ROOT=_build-lane207 mix test test/amqp/event_hubs_test.exs
Finished in 0.5 seconds (0.00s async, 0.00s sync)
26 tests, 2 failures (3 excluded)
```

Both failures are the in-flight R185e discriminator-hardening surface
(`test/amqp/event_hubs_test.exs:912` and `:959`, "R185e real-SDK batch
shape and duplicate-kind discriminator"):

```
1) R185e ... 4. KD-53 minimal inners [body]/[header,body] still split
   code: assert Enum.map(events, & &1["seq"]) == [2, 3, 4]
   left:  [1, 2, 3]
   right: [2, 3, 4]

2) R185e ... 1. real-SDK shape: 3 inners of [header, ma, props, app_props, body] -> 3 events
   real-SDK batch stayed ONE event
```

The remaining 24 tests PASS, including the pre-existing discriminator
cases. V47's cited 104/0 is not reproducible as a single-file count on the
current tree (the suite is 26 tests); 104/0 plausibly cites a larger W-batch
run that no longer exists as named. Recorded as-of-date, not faked.

## Open

The two R185e failures are a distinct in-flight EH lane's red test — the
minimal-inners split (KD-53 core) currently FAILS on the working tree.
Open defect, owner: EH batch lane. R166's own discriminator + dead-clause
surface is the passing 24/0 remainder; standing stays PARTIAL_ALIVE until
the R185e pair goes green.
