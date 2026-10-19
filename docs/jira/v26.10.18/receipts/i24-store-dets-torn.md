# i24 — store_dets_test torn-DETS probe flake (F12 family)

Standing: ALIVE (fix landed, red→green witnessed, load-replayed 3/3 green)
Context: solo (test/store_dets_test.exs)

Repo: /Users/sac/smalt. Lane build root `_build-ft-sdt`. No git (coordinator owns transitions;
note: coordinator commit 2a82b29 swept this lane's in-flight test edit into `feat(affidavit):
WasmEngine supervised-restart completion` mid-session).

## Face

`test/store_dets_test.exs` "mirror captures writes within interval + epsilon" — raw
`:dets.open_file(repair: false)` closed-read probes at the old lines 38/43 failed under
full-suite fleet load with `{:needs_repair, ~c"...dm_t_resources.dets"}` /
`:not_a_dets_file`. Witnessed pre-session 2/2 + 1/3 (FLAKE_LEDGER F12 family, new
mechanism: torn DETS file raced by a `repair: false` closed read).

## Mechanism

`Smalt.Store.DetsMirror` holds `dm_t_resources.dets` open and rewrites it on every sync
(tab2list → stale delete → insert → `:dets.sync/1`). A probe landing while the mirror
GenServer is mid-sync observes the transient header/footer tear; `repair: false` correctly
refuses and returns the torn-state error even though the file is healthy. Probe-side race,
not mirror corruption — widening `repair: true` was rejected (it would mask real corruption
and break the no-clobber invariant; the "corrupt dets file fails start_link closed" test
pins the fail-closed behavior).

## Fix (test-side only; lib/ untouched)

`test/store_dets_test.exs`: replaced the two bare `{:ok, res} = :dets.open_file(...)`
probes with `probe_rows/1` — a bounded retry (20 attempts x 250ms = 5s budget, sized to
cover the 4008ms sync fat tail measured in receipts/i20b-contention-mechanism.md) that
retries ONLY the torn states `{:error, {:needs_repair, _}}` and
`{:error, {:not_a_dets_file, _}}` (plus bare-atom defensive clause) and raises a typed
message naming the torn state if still torn after budget. Any other open error raises
immediately with the reason. `repair: false` is never widened.

## Red→green pair (this session, 4 yes-hogs on top of ambient fleet load)

- RED 1/3 — with the intermediate matcher matching only bare `:not_a_dets_file`, the real
  OTP torn shape `{:not_a_dets_file, ~c"/Users/sac/.cache/tmp/smalt_dets_mirror_2380/dm_t_resources.dets"}`
  escaped into the unexpected-error raise under load:

  ```
  === RED run 1 ===
       ** (RuntimeError) dets probe of /Users/sac/.cache/tmp/smalt_dets_mirror_2380/dm_t_resources.dets failed with unexpected error: {:not_a_dets_file, ~c"/Users/sac/.cache/tmp/smalt_dets_mirror_2380/dm_t_resources.dets"}
  5 tests, 1 failure (1 excluded)
  === RED run 2 ===
  5 tests, 0 failures (1 excluded)
  === RED run 3 ===
  5 tests, 0 failures (1 excluded)
  ```

  This red doubles as a live load witness of the torn mechanism itself (the probe DID
  observe the mid-sync tear). The original bare-open face is witnessed pre-session per the
  F12 face above; this session's red witnessed the corrected matcher's necessity.

- Matcher corrected to the tuple shapes; GREEN 3/3 under the same 4-hog load:

  ```
  === GREEN run 1 ===
  5 tests, 0 failures (1 excluded)
  === GREEN run 2 ===
  5 tests, 0 failures (1 excluded)
  === GREEN run 3 ===
  5 tests, 0 failures (1 excluded)
  ```

- Solo confirmation (ambient fleet load avg 275): `5 tests, 0 failures (1 excluded)`.
- Non-stress runs (stress tag excluded) keep runtime bounded; the tagged churn court was
  separately observed `6 tests, 0 failures` 2/3 under hog load earlier in-session with the
  probe fix in place, 1 run failing only the 30s per-round timeout budget under machine
  load avg ~170 (separate face: round-timeout sizing, NOT the torn-probe mechanism —
  filed for the coordinator to lane or drop).

## Replay

```
MIX_BUILD_ROOT=_build-ft-sdt mix test test/store_dets_test.exs
# for i in 1 2 3: spawn 4 `yes` hogs, run the file, kill hogs → 3x "5 tests, 0 failures"
```

Residue: probe budget is time-based (5s); a sync tail exceeding it still fails loudly with
the typed torn-state message rather than hanging — fail-closed preserved.
