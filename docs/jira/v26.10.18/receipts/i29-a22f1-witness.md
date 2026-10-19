# Receipt — i29 audit-A22-F1 witness (multi-data-section batch split heuristic)

Context: pair(lib/smalt/messaging/event_hubs.ex :136 heuristic, test/amqp/event_hubs_test.exs new describe, host)

- **Subject:** `/Users/sac/smalt` @ main working tree; marker `lib/smalt/messaging/event_hubs.ex:136` (`SHIM-COURT / audit-A22-F1`), inside `batch_inner_messages/1`'s `Enum.all?(data_sections, &complete_inner_message?/1)` guard
- **Standing:** PASS
- **Context:** pair(lib/smalt/messaging/event_hubs.ex :136 heuristic, test/amqp/event_hubs_test.exs new describe, host)
- **Date:** 2026-10-18
- **KD row:** KD-98 (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`)

## Behavior under witness

AMQP §3.2.5 permits one message body to carry MULTIPLE `body_data` sections.
The KD-53 batch discriminator splits the outer message into events ONLY when
EVERY outer data section decodes as a complete inner AMQP message (non-empty
section list carrying at least one body section — the F1 discriminator at
`lib/smalt/messaging/event_hubs.ex:160-169`); if ANY section fails, the whole
outer message stays ONE event. The marker id `A22-F1` had zero occurrences in
docs/ before this receipt (audited orphaned,
`docs/jira/v26.10.18/receipts/i29-eh-shim-audit.md`).

## Test added

`test/amqp/event_hubs_test.exs`, describe
"audit-A22-F1 multi-data-section split-when-all-inners-complete" (3 tests,
appended at the file tail; no lib edits, shim code byte-preserved):

1. **2 complete inner sections → 2 events** — outer message
   `[message_annotations(pk), body_data(inner1), body_data(inner2)]`, each
   inner a complete encoded AMQP message; asserts split into 2 events with
   monotonic seqs [1,2], one inner payload per event, sender pk on every event.
2. **3 complete inner sections → 3 events** — same shape ×3, seqs [1,2,3],
   one payload per event.
3. **incomplete inner → fail-closed ONE event** — section 2 is raw non-AMQP
   bytes (`raw-not-an-amqp-message`); asserts the whole outer message is
   stored as exactly ONE event containing both payloads (the F1 fallback).

## Verification (2026-10-18, unedited output)

Focused describe, private build root (`MIX_BUILD_ROOT=_build-ft-a22`):

Focused describe (private build root `MIX_BUILD_ROOT=_build-ft-a22`):

```
..............................
Finished in 0.7 seconds (0.00s async, 0.7s sync)
3 tests, 0 failures (34 excluded)
```

Full EH suite, run 1 (same private build root; warm-up run via
`scripts/fast_test.sh` private root `_build-ft-4c91e7d9`, identical result
30/0):

```
..............................
Finished in 0.7 seconds (0.00s async, 0.7s sync)
30 tests, 0 failures (7 excluded)
```

Full EH suite, run 2 (`MIX_BUILD_ROOT=_build-ft-a22`, captured verbatim to
`/tmp/a22-run2.txt`):

```
..............................
Finished in 0.7 seconds (0.00s async, 0.7s sync)
30 tests, 0 failures (7 excluded)
```

Witness receipt mtime (2026-10-18) > shim lineage d02c241 (2026-10-16 20:24
-0700); the Oct 18 22:33:54 file mtime on event_hubs.ex is a shim-court
touch-and-restore artifact (content byte-clean vs HEAD, disclosed in
i29-eh-shim-audit.md).

## Bound

No lib edits; no flips; register row KD-98 minted in the same session as this
receipt (registrant action per the audit's remedy — "add the row + witness",
not a flip). Pinions preserved.
