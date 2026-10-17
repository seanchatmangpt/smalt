# Receipt — R141 (Event Hubs multi-event batch body discriminator, KD-53)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W6 wave-5 docs lane)

## Subject files

- `lib/smalt/messaging/event_hubs.ex:145`/`:181` (SHIM-COURT / R141 markers):
  a tail group with NO body section previously slipped the batch boundary —
  the decoder now returns `:incomplete` when the buffer ends mid-message and
  discriminates complete-vs-incomplete on body-section presence, so inner
  messages 2..N of a multi-event batch are no longer dropped (KD-53 close
  condition).

## Verification (2026-10-16, W6 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w6docs mix test test/amqp/event_hubs_test.exs
22 tests, 0 failures (2 excluded)
```

Cross-reference: `scripts/kd_flip.py` reports
`KD-53: [CLOSED-SIMULATED] lib/smalt/messaging/event_hubs.ex` (dry-run output
embedded in `r121-kd-flip-dry.md`).

## W9 re-citation (2026-10-16, docs lane W9, `_build-lane205`)

Per DoD lane D121: the W5-10 session figure "attack A/E, 104/0" has no repo
artifact and is withdrawn. The real adversarial evidence for the AMQP/EH
attack surface is:

1. **`test/redteam/r3_amqp/`** (live-broker redteam,
   `zsh test/redteam/r3_amqp/run.sh`, exit 0, node --test `pass 1 / fail 0`):
   **46 attacks, 46 findings, 43 kill_tests, 1 loud hang** (H4 slow-start,
   `HANG-no-response-in-5s` — reported, not a fake pass). Results:
   `/tmp/r3_amqp_results.json` (sb_port 45682 / eh_port 45683, this lane's
   run). Framing (F1-F10), header (H1-H5), SASL/security (S1-S7),
   transfer/cap (T1-T6), disposition (D1-D6), mgmt-RPC (M1-M5), EH lane
   (E1-E2) — including E2 "2MiB declared frame -> clean-close" and T6
   "1.016MB body vs 1MB cap -> link-message-size-exceeded gate held".
2. **`test/amqp/event_hubs_test.exs`** = 22 tests, 0 failures (2 excluded,
   `:amqp_wire` tier) — re-run fresh below, matching the W6 verification.

```
$ MIX_BUILD_ROOT=_build-lane205 mix test test/amqp/event_hubs_test.exs
22 tests, 0 failures (2 excluded)
```

Standing: PASS (evidence re-grounded; session figure 104/0 withdrawn).

## SUPERSEDED (2026-10-16)

R141's body-section-presence discriminator was superseded by R185e
(duplicate-section-KIND detection per group + shape-sequence homogeneity,
fail-closed to ONE event), which supersedes R166's count-based multiplicity
check — R166 rejected the real `@azure/event-hubs` SDK inner shape
`[header, message_annotations, properties, application_properties,
body_data]` and resurrected KD-53 silent-drop. See
`docs/jira/v26.10.16/receipts/r185e-eh-batch-dup-kind.md`.
