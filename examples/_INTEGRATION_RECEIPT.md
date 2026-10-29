# examples/ integration receipt — coordinator, 2026-10-19

## Gate

All 8 archetype harnesses executed against a live canonical substrate
(`substrate-ctl up --block front --auth enforce`, bearer-over-TLS for SDK
legs, real AMQP wire for sb/eh legs). Final consolidated pass — zero FAIL
verdicts across the wave; non-GREEN verdicts are the typed loud vocabulary
(XFAIL / REGISTERED-DIVERGENCE / SKIP-SURFACE-ABSENT), never fake passes.

| Example | Verdict | rc | Non-green states |
|---|---|---|---|
| ex1 bank-ledger-nightly | 8/10 GREEN, 0 FAIL | 1* | 2 XFAIL (child-resource LRO shape, blob bearer-over-http SDK policy) |
| ex2 retail-order-pipeline | 8/8 GREEN | 0 | — |
| ex3 healthcare-archive | 15/17 GREEN, 0 FAIL | 0 | 2 XFAIL (KV deleted-secrets plane, KD-102) |
| ex4 telco-event-grid | 9/10 GREEN, 0 FAIL | 0 | 1 SKIP-SURFACE-ABSENT (KQL bin literal, SYN0002) |
| ex5 insurance-governance | 15/19 GREEN, 0 FAIL | 3* | 4 SURFACE-ABSENT skips (loud) |
| ex6 media-drm-custody | 5/8 GREEN, 0 FAIL | 0 | 1 RD#KD-119 (sign digest double-hash), 1 XFAIL, 1 SKIP |
| ex7 fintech-throttle | 10/10 GREEN | 0 | — |
| ex8 saas-provisioning | 11/12 GREEN, 0 FAIL | 1* | 1 XFAIL (EH child LRO) |

\* non-zero rc is the harnesses' own exit contract for XFAIL/skip present —
loud, by design.

## Coordinator actions (fix-forward, disclosed)

### examples/ authored
- `media-drm-custody/run.sh` — written (was absent); same exit contract.
- `retail-order-pipeline/index.ts` — receiver-overload fix
  (`createReceiver(q, {receiveMode})` — the `createReceiver(q, "peekLock")`
  positional string resolved as topic+subscription and attached the wrong
  source address), settlement API shape (`receiver.completeMessage/abandon`),
  DLQ receiver via `{subQueueType: "deadLetter"}`, scoped messageIds.
- `telco-event-grid/index.ts` — partitionId must be the positional first arg
  of `subscribe()`; the `(handlers, {partitionId})` overload does not pin the
  partition (fan-in of all partitions into one handler set — witnessed
  cross-partition overlap), and the isolation assertion was rebuilt from the
  send leg's actual per-batch alternation instead of a stale n-split.
- `fintech-throttle/index.ts` — child queue PUT requires `location`
  (substrate queue shape).
- `README.md` — archetype index + verdicts + substrate-fix note.

### Substrate fixes (lib/, wire-verified by the harnesses)
- `messaging/amqp/queue_store.ex` — DLQ copy preserves `delivery_count`
  (real Azure: the DLQ message is the same message; a reset count hides
  delivery history). Retail DLQ leg: deliveryCount 4 observed post-fix.
- `scripts/lib/substrate_boot.sh` — `SMALT_SB_SHARED_KEY` operator-pinnable;
  per-boot key persisted into the boot marker (umask 077) so lane-private
  boots are client-reachable. Verified in marker JSON.
- Compile repairs (pre-existing breaks blocking ALL boots): purview_atlas
  bare-head default; kql `_` in expression position (x2, pos bound in heads);
  event_grid_webhook private `read_body/2` vs imported Plug.Conn conflict.
- EH cross-partition "bleed" hypothesis was FALSIFIED with a positional-
  overload probe: substrate partition isolation is intact; the observed
  overlap was the harness's SDK overload misuse. Debug instrumentation
  landed and fully reverted (0 residue; compile clean).

### Validated as-is (lane-owned)
- ex1/ex3/ex6/ex8 non-green states are the in-flight capabilities their
  receipts already register (KD-102 deleted-secrets, KD-119 digest sign,
  container/EH child LRO shape, blob bearer-over-http).

## Environment notes (honesty)
- Two mid-session substrate sweeps by concurrent lanes invalidated two runs
  (retail SAS mismatch epoch, fintech cross-substrate 401); both re-ran
  green after re-boot. Front substrate left UP (block=front, enforce) for
  the other lanes still in flight.
- `examples/__pycache__` removal was permission-denied; harmless artifact.
