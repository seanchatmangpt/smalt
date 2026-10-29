# IMPL-9: popcorn re-pin to OTP 29.1.2 / Elixir 1.20.4-otp-29

**Standing:** ALIVE

## Pin diff

`popcorn_demo/.tool-versions` did not exist (verified: no file on disk, no
`*.tool-versions` anywhere in the repo git history). Created:

```
erlang 29.1.2
elixir 1.20.4-otp-29
```

asdf inventory: erlang 29.1.2 installed (TOOLUP had installed it; 29.1.1 also
present). Elixir builds available: `1.20.4-otp-29` only (no `-29.1.2`-suffixed
build exists; the generic `otp-29` build is used — binary reports "compiled
with Erlang/OTP 29" and runs on 29.1.2).

## Environment hazard (disclosed)

Homebrew elixir 1.19.5 (`/opt/homebrew/bin/elixir`) shadows asdf in the shell
PATH and erlmcp otp-28.3.1 shadows erlang. Gate runs required explicit PATH
prefix:

```
export PATH="/Users/sac/.asdf/installs/elixir/1.20.4-otp-29/bin:/Users/sac/.asdf/installs/erlang/29.1.2/bin:$PATH"
```

Verified before each step: `erl` resolves to OTP 29, `elixir --version` →
`Elixir 1.20.4 (compiled with Erlang/OTP 29)`.

## Compile (fresh build root)

```
MIX_BUILD_ROOT=_build-otp29p mix compile
```

Exit 0. Compiled clean on OTP 29.1.2; only pre-existing warnings (undefined
Smalt.EventGridWebhook / ThousandIsland references in
`lib/popcorn_demo/live_egd.ex` — same warnings as prior build roots, not
introduced by the pin).

## Tests

`MIX_BUILD_ROOT=_build-otp29p mix test test/empirical_kv_latency_test.exs`
→ `3 passed` (0.7s). E4KV fence held: best-round p99=2254us < 10000us.

```
[E4KV get latency] n=100 fresh-conn loopback wire round-trips x 3 rounds
  round 3: p50=840us  p95=1331us  p99=2254us  max=2254us
Result: 3 passed
```

`MIX_BUILD_ROOT=_build-otp29p mix test test/guideline_offline_test.exs`
→ `4 passed` (0.1s). One pre-existing type warning (debug_info raise arm,
`test/guideline_offline_test.exs:194`), not pin-related.

## Context

Context: solo

## Falsifier status

Re-pin compiles and passes representative tests on OTP 29.1.2. Not covered:
full test census under the new pin, Popcorn/Apex WASM packaging legs — those
ride separate lanes.
