# L38 — AoQ epoch-rotate handler (frame 0x03)

Standing: PASS

## Subject

`Smalt.Aoq.Tables` dispatch table binds 0x03 → `{Smalt.Aoq.Frame, :handle_epoch_rotate}`
with no implementation (Explore-flagged HIGH). Implemented per spec
`docs/jira/v26.11.5/aq-architecture-spec.md` §5.

## Diff

- `lib/smalt/aoq/frame.ex` — added `handle_epoch_rotate/2` (dispatch-handler section):
  header epoch = CURRENT epoch (decode-admitted), payload = exactly 2 bytes
  (new epoch id, u16 BE). Appends via `Tables.rotate_epoch/2`, storing
  `{:rotated_from, current_epoch, seq}`. Typed refusals: `{:bad_rotate_payload, p}`,
  `:tables_unbooted`, `{:epoch_regression, new, max}`.
- `lib/smalt/aoq/tables.ex` — **disclosure: lane-owned edit (explicitly allowed
  narrow lawful update path)**. Added `rotate_epoch/2`: the one lawful post-boot
  mutation per spec §5 ("any future mutation must re-derive and put the whole map") —
  whole-map `:persistent_term.put`, append-only (new id must be strictly greater
  than every existing epoch id; old epochs retained for late frames). Refuses
  pre-boot (`:tables_unbooted`) and regression, typed tuples, never raises.
  The refuse-on-mutate guard (`guarded_put/2`) is untouched.
- `test/smalt/aoq/frame_epoch_rotate_test.exs` — new court.

## Courts

- (a) lawful rotate: 0x03 frame appends new epoch, old epoch retained
- (b) stale/regressing epoch → `{:epoch_regression, new, max}`, table untouched
  (both: below max, and equal-to-existing)
- (c) pre-boot rotate → `:tables_unbooted`, seal absent, epochs empty
- (d) malformed payload (≠2 bytes) → `{:bad_rotate_payload, payload}`

No sleeps; async: false + synchronous boot re-derivation (structural sync).

## Verification

```
MIX_BUILD_ROOT=_build-lane38 mix test test/smalt/aoq/frame_epoch_rotate_test.exs test/smalt/aoq/tables_test.exs
# 12 passed, 0 failures, 0 skipped — EXIT=0
```

## Bounds

Owned files respected: frame.ex (append), tables.ex (narrow path, disclosed),
new test file, this receipt. No cursor/transport/supervisor/listener/flags/
justfile.d/scripts edits.
