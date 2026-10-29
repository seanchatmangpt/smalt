# BK-62: HEAD Test Census (current HEAD, concurrent-lane tree)

**Standing:** **BLOCKED-LANE-COMPILE** (full suite never reached a summary line; three attempts, each aborted by a different concurrent-lane in-flight file)

Context: full

## Subject

- Repo: `/Users/sac/smalt`, branch `main`, HEAD `077f419777353b5a6c32a876c0beceeec400c466`
- Build root: `_build-bk62` (fresh, from-scratch dep compile)
- Toolchain: Elixir 1.20.4-otp-29 / OTP 29.1.2 (asdf pin; note: default PATH resolves homebrew Elixir 1.19.5/OTP 28 which mix.exs refuses — see Gotcha below)

## Commands / exits

```
export PATH="$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$HOME/.asdf/installs/erlang/29.1.2/bin:..."
MIX_BUILD_ROOT=_build-bk62 timeout 1200 mix test   # 4 attempts, 3 counted
```

| run | exit | abort mode |
|---|---|---|
| 1 | 1 | (not counted — wrong toolchain: homebrew Elixir 1.19.5/OTP 28, mix.exs refuses `~> 1.20`) |
| 2 | 1 | `== Compilation error in file test/internal/ja15_error_logger_court_test.exs` — SyntaxError 235:92 (`capture_log(metadata: [...], format: "...", fn ->` — kw list not last arg). File mtime was already stable ≥3 min before run started; **not mid-write, a static syntax error on disk**. |
| 3 | 1 at 21:21 | boot failure: `Smalt.Store.Heir` given as supervisor child but module does not exist (`lib/smalt/plane/data_supervisor.ex:23`), app start refused |
| 4 | 1 | `== Compilation error in file lib/smalt/store/heir.ex:76:34` SyntaxError (kw list not last in list) — file had appeared at 21:25, lane iterating; by 21:28 poll the lane had **removed** `heir.ex`/`partition.ex` again. |
| 4 (cont) | — | After run 4, poll shows `lib/smalt/store/` back to `dets_mirror.ex` only; `data_supervisor.ex` rewritten again (doc comment only). Tree churning under active lanes (git status changed twice during the window). |
| 5 | — | not attempted: protocol says one retry; tree still mid-landing by another lane (STO lane files `application.ex, integration_supervisor, journal_reader/sink` now `M`). STO lane files now `M` in git status. |

Attempt 2 partial ExUnit results (before the compile abort): **6 failures, all InternalTier.CensusTest** (`test/internal/internal_tier_census_test.exs`) —
allowlist/population-fence tests (#1 no ARM path literals, #2 no HTTP-status co-occurrence, #3 no unaudited pacing token, #4 no raw-HTTP-client token test, #5 module-reference allowlist, #6 population fence `test/internal` file set drifted — on_disk list includes many files not in @owned_files). All 6 share one root cause: the `test/internal` file population has drifted from the census allowlist (multiple lanes added internal-tier files without registering them). Single root cause, not 6 independent regressions.

Attempt 2 partial detail: an earlier log block (~line 1617) citing `test/json_compat_stream_test.exs:103:7: Smalt.JsonCompat.StreamTest` is a compiler **warning** context (unused-function style), not a failure — grep counts exactly 6 `N)` failure entries, all CensusTest. No summary line exists (run aborted before ExUnit finished printing totals), so pass/skip counts for run 2 are UNKNOWN.

## Load samples (1-min LA, during window 21:08–21:32)

92.59 → 67.83 → 97.62 → 119.06 → 110.40 → 62.02 → 75.17 → 79.20 (16-core machine, LA 60–120: heavily contended, compile/test wall-times inflated accordingly)

## Failure classification

- **BLOCKED-LANE-COMPILE**: `test/internal/ja15_error_logger_court_test.exs` (static syntax error, JA-15 lane owner) and `lib/smalt/store/heir.ex` (transient, lane added then removed the file mid-window; supervisor referenced it in between). Both are concurrent-lane in-flight files; per protocol no lane's file was touched.
- **Pre-existing, real (on-tree at this window)**: the 6 InternalTier.CensusTest failures are real content on disk at attempt 2, reproduced within one run (not a flake — no rerun possible to solo-confirm since runs 3-5 never reached ExUnit, but they are assertion failures over real on-disk content, not timing flakes).
 classified real, do-not-fix (census allowlist drift is owned by lanes landing internal-tier files; fixing the allowlist would mask the drift signal other lanes need).
- No load-flake classification is possible: no test reached a solo re-run.

## Gotcha (for the register)

Default PATH resolves homebrew Elixir 1.19.5/OTP 28; mix.exs refuses it: "You're trying to run :smalt on Elixir v1.19.5 but it has declared in its mix.exs file it supports only Elixir ~> 1.20". Any census harness must pin PATH to `~/.asdf/installs/elixir/1.20.4-otp-29/bin` + `~/.asdf/installs/erlang/29.1.2/bin` before `mix test`.

## Falsifier

A rerun on a quiesced tree (`just quiesce` + lanes idle) reaches a summary line: if it does, this BLOCKED receipt's classification of the 6 census failures as real on-disk content should be re-verified against that run's failure list.
