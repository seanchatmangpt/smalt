# Receipt — V261019-10 (residual-elixir-tier)

Context: solo(V261019-10) — executed by the receipt-writer lane this session,
2026-10-19 10:08 PDT.
Standing: **ALIVE** — `MIX_BUILD_ROOT=_build-lane-rc1 mix test test/internal/`
ran green in this session: **20 tests, 0 failures, exit 0** (full tail below).
Base: 64f6099663a4ec32fd9478c4c39fca49ab1961f8 (shared checkout, 143 dirty paths)
Date: 2026-10-19

## What changed

- The residual ExUnit tier is the 6 untracked files under `test/internal/`:
  `dets_mirror_recovery_test.exs`, `internal_tier_census_test.exs`,
  `plane_blast_radius_test.exs`, `poll_helper.exs` (helper, not a test),
  `vm_zero_growth_test.exs`, `wasm_nif_lifecycle_test.exs`.
- Tier gate wiring: `scripts/non_duplication_gate.py` scans
  `test/internal/**` for transport/Azure-literal/JSON-shape assertions
  (R1 absolute, R2/R3 with structural exemptions; fail-closed exit 1 on
  zero files scanned) — ran **PASS, 6 files clean, exit 0** this session
  (output also recorded in V261019-15).
- Governance disclosure: this lane's first two compile attempts (10:05–10:07)
  hit a shared-`lib/` compile error in `lib/smalt/auth/x_arr_cert.ex`
  (undefined `hex/1` at lines 89/90). The identity lane landed the fix
  (file mtime 10:05, `defp hex` present at line 110) and the 10:08 retry
  compiled clean. Recorded per the compile-freeze disclosure law; no edit
  made by this lane to `lib/`.

## Verification (real output tails)

```
$ MIX_BUILD_ROOT=_build-lane-rc1 mix test test/internal/
10:08:42.166 [info] dets: file ~c"/Users/sac/.cache/tmp/smalt-dets-lane-25479/smalt_appconfig.dets" not properly closed, repairing ...
......
Finished in 1.9 seconds (0.1s async, 1.8s sync)
20 tests, 0 failures
exit=0
```

```
$ python3 scripts/non_duplication_gate.py
[PASS] non-duplication gate: 6 file(s) clean
exit=0
```

```
$ git ls-files test/
test/test_helper.exs
```

(only `test/test_helper.exs` is tracked; the 6 residual files are untracked
in-flight, owned by the residual-tier WO.)

## Acceptance greps

- `grep -rn "restore_app\|ensure_store_up" test/ | wc -l` => `0` — legacy
  reset surface absent from the residual tier (see V261019-07).
- `grep -c "def test_" test/internal/*_test.exs` — not separately censused;
  the executed 20-test count is the authoritative leaf count for the tier.

## Deviations

1. Skeleton's `FAST_TEST_BUILD_ROOT=... scripts/fast_test.sh
   test/semconv_replay_identity_test.exs ...` commands reference files
   deleted by `64f6099`; not executable. The residual tier census above
   replaces them. The v26.10.18 LOAD-FLAKE residual faces
   (`semconv_replay_identity_test.exs`, `chaos/crash_isolation_test.exs`,
   `azsim/dr_scenarios_test.exs`) died with the deleted suite and carry no
   re-classification this window — they are names in git history only.
