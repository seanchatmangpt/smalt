# Receipt — R164 (tag aliases + TEST_ISOLATION + convergence doc)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W7 docs lane)

## Subject files

- `docs/TEST_ISOLATION.md:43` (R164 marker): the `:cross_seat` tag row —
  default-excluded so the offline tier stays broker-free, with the documented
  re-enable command `mix test --only cross_seat test/auth_enforce_test.exs` and
  owner R164.
- `test/test_helper.exs:1-3`: the isolation contract points at
  `docs/TEST_ISOLATION.md` and names every default-excluded tag — the
  convergence-doc side of the same lane.

## Verification (2026-10-16, W7 docs lane, unedited output)

```
$ grep -n "R164" docs/TEST_ISOLATION.md
43:| `:cross_seat` | Auth cross-seat suite inside `test/auth_enforce_test.exs` (out-of-seat token/seat-boundary cases). Default-excluded so the offline tier stays broker-free; run in isolation via `mix test.cross_seat`. | R164 | Included-only run: `mix test --only cross_seat test/auth_enforce_test.exs` |
```

## W10 re-run (2026-10-16, docs lane W10)

```
$ grep -n "R164" docs/TEST_ISOLATION.md
43:| `:cross_seat` | Auth cross-seat suite inside `test/auth_enforce_test.exs` (out-of-seat token/seat-boundary cases). Default-excluded so the offline tier stays broker-free; run in isolation via `mix test.cross_seat` | R164 | Included-only run: `mix test --only cross_seat test/auth_enforce_test.exs` |
```

Standing: PASS.
