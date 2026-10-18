# i21-leak-batch1 — leak-court batch 1 (env restore discipline)

Standing: PASS
Context: slice (three leased files + leak-court static scan)

## Scope (lease)

- `test/auth_enforce_test.exs` — tests at :459 and :488 only
- `test/smalt_ets_baseline_identity_test.exs`
- `test/smalt_ets_composite_identity_test.exs`

## Findings fixed

1. `auth_enforce_test.exs:459-462` and `:488-491` (post-edit :463/:492): `put_env(:trusted_proxies, ["10.0.0.0/8" | "10.0.0.0/16"])` with no restore — left 10.0.0.0/8 or /16 globally trusted for the rest of the suite (auth-security-relevant). Fix: save-prev (`Application.get_env(..., :__unset__)`) + `on_exit` restore (delete when previously unset, put otherwise), plus `:trusted_proxies` added to the setup snapshot list (line 31) so the per-suite restore covers it with the existing `:__unset__` sentinel pattern.
2. Baseline/composite identity tests: `put_env(:lro_retention_ms, 0)` + `on_exit delete_env` — delete destroys a pre-existing non-nil value. Fix: save-prev + restore via put when prev non-nil.

## Real output

```
$ MIX_BUILD_ROOT=_build-ft-leak1 mix test test/auth_enforce_test.exs test/smalt_ets_baseline_identity_test.exs test/smalt_ets_composite_identity_test.exs
Finished in 1.6 seconds (0.00s async, 1.6s sync)
132 tests, 0 failures
```

```
$ just leak-court-count
[LEAK-COURT] exit=1 1 uncovered-mutation lines (see /tmp/leak-court.out)
$ grep uncovered /tmp/leak-court.out
12:-- OFFENDERS (49 files, 109 mutations uncovered) --
```

Uncovered count: 122 → **109** (13 covered by this batch). Gate still exits 1 — remaining offenders are outside this lease (49 files).

## Notes

- Other trusted_proxies put_env sites in auth_enforce_test.exs (:285/:353/:823/:854/:1965) already had in-scope restores; not touched (out of lease).
- No git actions taken.
