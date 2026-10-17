# Cleanup Final Receipt

Date: 2026-10-14. Integration sweep per same-checkout cleanup law.

## Removed

| Item | Size |
|---|---|
| `_build-laneauth/` | 318M |
| `_build-laneco/` | 691M |
| `_build-laneco2/` | 340M |
| `_build-laneerr2/` | 691M |
| `erl_crash.dump` | — |

Total reclaimed: ~2.0 GB.

No `_build-ft-*` or `_build-dw` dirs existed. No `REMAINING_CANSUS.md` rename
needed — `docs/PACK_INTEGRATION/REMAINING_CENSUS.md` was already correctly
named; repo-wide grep for `CANSUS` (md files, excluding `_build`) returned zero
matches.

## Untouched

Canonical `_build/` and `deps/` verified present and unmodified.

## Compile state

`mix compile` — exit 0, **0 errors**. Warnings only (unused functions/aliases in
`lib/smalt/messaging/amqp/frame_codec.ex`, `lib/smalt/projection/admission.ex`,
`lib/smalt/projection/canonical.ex`, `lib/smalt/messaging/amqp/queue_store.ex`;
all pre-existing).
