# T29b — Cosmos RU throttle retry-after: remaining-window fraction

**Standing:** **PARTIAL_ALIVE** (fix landed + tested; wire-level @azure/cosmos re-witness pending, was T29's scope)

## Change

`lib/smalt/data_plane/cosmos.ex` — `throttle/1` (over-limit branch) + `throttled/1`:

- 429 `x-ms-retry-after-ms` was the constant `"1"` — @azure/cosmos burns all
  9 retries inside one 1 s fixed window (retry-storm class; T29 witness: 35
  rejections with throttle-retry-count 9 in 166 ms).
- Now: `retry_after_ms = clamp(remaining_ms ± jitter, 10, 1000)` where
  `remaining_ms = 1000 - rem(now_ms, 1000)` from the epoch-second ETS window
  key, jitter deterministic (±5, `:erlang.phash2({route_key, window})`).
- KD-110 `:infinity` default untouched; the shaped hint only applies when an
  integer RU limit is configured (env/profile/app-env resolution unchanged).
- Rationale documented inline at the patch site.

## Test (Chicago — real dispatch, real ETS, no mocks)

`test/data_plane/cosmos_ru_throttle_retry_after_test.exs` (new, 2 tests):

```
MIX_BUILD_ROOT=_build-rafix2 mix test test/data_plane/cosmos_ru_throttle_retry_after_test.exs
...
Finished in 0.5 seconds
2 tests, 0 failures
```

- Sets `SMALT_COSMOS_RU_LIMIT=3`, bursts 15 real `get_doc/4` dispatches on a
  unique route link, asserts every 429 hint ∈ [10, 1000] ms, hint ≤
  remaining_ms+5, ≥3 429s on the real counter, and that the hint changes
  across a window flip when the two observations are >10 ms apart in drain
  phase (bounded spin on the wall-clock observable, no fixed sleep).

## Tier slice

```
MIX_BUILD_ROOT=_build-rafix2 mix test test/data_plane
Finished in 0.7 seconds
54 tests, 0 failures
```

## Notes

- Window-flip wait is a bounded spin on `System.system_time/1` (observable
  poll), not `Process.sleep`.
- Session-introduced transient: another lane's in-flight
  `lib/smalt/powl2/compiler.ex` briefly broke the shared compile; it compiled
  clean on retry — no unblock edit applied, nothing disclosed beyond this note.
- `SMALT_COSMOS_RU_LIMIT` is saved/restored in `on_exit`; mix test boots its
  own VM per run, so no cross-lane env leak.
