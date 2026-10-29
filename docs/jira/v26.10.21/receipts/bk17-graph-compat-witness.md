# BK-17 — powl2 graph-compat court witness (receipt anchor for the "8 tests" claim)

**Standing**: PASS
- **Context**: solo · Date: 2026-10-21 · Repo: /Users/sac/smalt @ main
- **Subject**: `test/internal/powl2_graph_compat_court.exs` @ HEAD `250e86d19c391cff849b4e80de0f27eb66010063`
- **Resolves**: BK-10 flag "operator-asserted, no receipt anchor" — the
  "8 tests, 0 failures" replay claim cited in FINAL-RELEASE.md and
  VALIDATION.md now has an on-disk anchor.

## Command (exact)

First attempt on the default host toolchain compile-refused (expected —
IMPL-11 standing falsifier):

```
$ MIX_BUILD_ROOT=_build-bk17 mix test test/internal/powl2_graph_compat_court.exs
** (Mix) You're trying to run :smalt on Elixir v1.19.5 but it has declared in its mix.exs file it supports only Elixir ~> 1.20
exit 1
```

Pinned-toolchain replay (asdf shims: OTP 29.1.2 / Elixir 1.20.4-otp-29):

```
$ export PATH="$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$HOME/.asdf/installs/erlang/29.1.2/bin:$PATH"
$ elixir -v
Erlang/OTP 29 [erts-17.1.1] ... Elixir 1.20.4 (compiled with Erlang/OTP 29)
$ MIX_BUILD_ROOT=_build-bk17 mix test test/internal/powl2_graph_compat_court.exs
Running ExUnit with seed: 93267, max_cases: 32
........
Finished in 0.1 seconds (0.1s async, 0.00s sync)
Result: 8 passed
exit 0
```

Fresh lane build root `_build-bk17` (full compile from clean). No sleeps;
self-booting app on ephemeral ports.

## Measured vs operator-asserted

- Count: **8 tests, 0 failures — matches** the operator-asserted figure.
- Time: operator asserted **0.07 s**; this run measured **0.1 s**
  ("Finished in 0.1 seconds (0.1s async, 0.00s sync)"). Docs updated to
  the measured figure.

## Cleanup

`_build-bk17` is a lane build-root lease; delete at integration
(`rm -rf _build-bk17` or `just lane-clean`).
