# Receipt — AZB-01 Pinned warm image (OTP 28 + Elixir 1.19.5)

Standing: **ALIVE** — all three Accept commands ran for real with exit 0; Falsifier
conditions checked and not observed; Anti-vacuity mutation witnessed flipping the outcome.

## Identity

- Subject: `/Users/sac/smalt` @ `29bb0371426a270c9c9ac2dc483b7e2a9d226938`
  (checkpoint-6 head; `git rev-parse HEAD` at receipt time).
- Base image: `hexpm/elixir:1.19.5-erlang-28.5.0.2-alpine-3.20.9@sha256:29c51579d430b307d4f6182775373bb18c90173d382ba23011d81808b0fab8cd`
  (multi-arch index digest, resolved via `docker buildx imagetools inspect`
  2026-10-18; linux/arm64 leaf `sha256:528a493dfb46f468d3fd0118359398372bcaabd8798127d9ee76a3d44a80d5ed`).
  Note: the coordinator tag `1.19.5-erlang-28-alpine-3.20` does not exist on
  Docker Hub (hub API 404); the pinned tag is the real tag preserving the
  OTP-28 + alpine-3.20 contract (carried disclosure from the prior build).
- Image: `smalt:local` (test target), ID/digest
  `sha256:1fc62d357a4cb11eb4e7d76762f19cd1e2fe3f75094363da024cd78dd213ffa9`,
  created 2026-10-18T15:28:10-07:00, linux/arm64, colima docker server 29.5.2.
- Label: `org.smalt.subject=29bb0371426a270c9c9ac2dc483b7e2a9d226938`
  (`docker image inspect` Labels; overridable via `--build-arg SUBJECT_SHA=`,
  default baked to the checkpoint head).
- Owned files: `docker/Dockerfile` (rewritten: digest pin, multi-stage
  base→deps→test/release, spec layer order, label), `docker/BUILD_RECEIPT.md`.

## Accept (all real runs, exact output)

1. `docker build -f docker/Dockerfile -t smalt:local --target test
   --build-context ash_r2rml=/Users/sac/ash_r2rml --progress=plain .`
   → **exit 0**. Key steps: `#15 [deps 6/7] RUN MIX_ENV=test mix deps.compile`
   DONE 569.2s; `#21 DONE 47.5s`; `naming to docker.io/library/smalt:local done`.
2. Lib-only-touch rebuild: `touch lib/smalt/registry.ex` then same build →
   **exit 0**, deps layers all CACHED
   (`/tmp` logs `azb01-build1.log`/`azb01-build2.log`, excerpts below):

   ```
   #10 [deps 5/7] RUN mix deps.get
   #10 CACHED
   #11 [deps 6/7] RUN MIX_ENV=test mix deps.compile
   #11 CACHED
   #16 [deps 7/7] RUN MIX_ENV=prod mix deps.compile
   #16 CACHED
   #17 [test 1/4] COPY lib config test scripts priv ./
   #17 DONE 8.1s          <- source layer rebuilt
   #20 [test 4/4] RUN mix compile --warnings-as-errors
   ```

3. OTP probe:

   ```
   $ docker run --rm smalt:local erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().'
   28
   $ docker run --rm smalt:local elixir --version
   Erlang/OTP 28 [erts-16.4.0.2] [source] [64-bit] [smp:4:4] [ds:4:4:10] [jit]
   Elixir 1.19.5 (compiled with Erlang/OTP 28)
   ```

## Falsifier — NOT observed

- *deps layer rebuilt after a lib/-only change*: refuted by Accept 2 — all
  deps steps CACHED; only `COPY lib config test scripts priv ./` and
  downstream steps re-ran.
- *OTP ≠ 28*: refuted — probe prints `28`.
- *Elixir ≠ 1.19.5*: refuted — probe prints `Elixir 1.19.5`.

## Anti-vacuity (mutation witnessed, scratch context only)

Scratch copy via `git archive 29bb0371...` into `/tmp/azb01-scratch` (frozen
checkout untouched; frozen `mix.lock` md5 `21180a55c1f4a901620d069f3c0d2aab`
re-verified identical after the run). Bumped `jason 1.4.5 → 1.4.6` in the
scratch `mix.lock` and rebuilt:

```
#8 CACHED
#9 CACHED
#14 [deps 5/7] RUN mix deps.get        <- re-executed, NOT CACHED
#14 4.144 ** (Mix) Unknown package version jason 1.4.6 in lockfile
#14 ERROR: process "/bin/sh -c mix deps.get" did not complete successfully: exit code: 1
```

The deps layer cache key moved with the lock bump — the mutation flips the
outcome (cache reuse → rebuild), so the Accept-2 cache reuse is not vacuous.
The mutant build fails at deps.get (invalid lock entry) which is the expected
typed failure of a corrupted lock; scratch context deleted after the run.
Disclosed: the mutation witnesses the *cache-key* flip at the first deps step;
the full rebuild-to-completion was not run (mutant lock is not buildable, by
construction).

## Environment notes (pre-existing, disclosed)

- One build was canceled at the 10-minute foreground command cap mid
  deps.compile; the resume from layer cache completed — this is the cache
  doing its job, not a build defect.
- Colima TLS flaps to hex/docker Hub recur; `HEX_HTTP_CONCURRENCY=1`
  + `HEX_HTTP_TIMEOUT=120` retained in the deps stage (carried from the
  2026-10-14 build).

## Deviations (disclosed)

- `rust cargo` in the package list (NIF toolchain) — carried from the prior
  build receipt, still required.
- Build commands for AZB-02+ must pass `--target test` (or `--target release`)
  plus `--build-context ash_r2rml=/Users/sac/ash_r2rml`; the bare Accept
  command form `docker build -f docker/Dockerfile -t smalt:local .` from the
  ticket defaults to the **release** target and needs the ash_r2rml context.
- Multi-stage note: prod dep compile is layered so both targets share one
  deps stage (`mix deps.get` once, then `MIX_ENV=test`/`MIX_ENV=prod`
  deps.compile); `mix compile --warnings-as-errors` gates both targets'
  source layer.
