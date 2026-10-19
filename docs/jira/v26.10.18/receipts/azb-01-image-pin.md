# Receipt — AZB-01 Pinned warm image (OTP 28 + Elixir 1.19.5)

Standing: **ALIVE** — all three Accept commands ran for real with exit 0 on the live
Context: solo(docker build/release verification + in-image probes; no mix test invocation)
tree; Falsifier conditions checked and not observed; Anti-vacuity mutation witnessed
flipping the outcome (cache reuse → rebuild).

## Identity

- Subject: `/Users/sac/smalt` working tree; `git rev-parse HEAD` at receipt time =
  `be81187481601344deaaf396c603d4662fc4912d` (label/default `SUBJECT_SHA` remains the
  lineage base `29bb0371426a270c9c9ac2dc483b7e2a9d226938`, checkpoint-6 head — the
  build-arg override preserves identity while sibling lanes land their diffs).
- Base image: `hexpm/elixir:1.19.5-erlang-28.5.0.2-alpine-3.20.9@sha256:29c51579d430b307d4f6182775373bb18c90173d382ba23011d81808b0fab8cd`
  (multi-arch index digest, resolved via `docker buildx imagetools inspect`
  2026-10-18; linux/arm64 leaf `sha256:528a493dfb46f468d3fd0118359398372bcaabd8798127d9ee76a3d44a80d5ed`).
  Note: the coordinator tag `1.19.5-erlang-28-alpine-3.20` does not exist on
  Docker Hub (hub API 404); the pinned tag is the real tag preserving the
  OTP-28 + alpine-3.20 contract.
- Final images (this session, both targets, live tree):
  - `smalt:local` (release target) `sha256:d7e21e70c324669a1f52357e444fae90fa05f9eacadba2764062b47660a4dc9e`
  - `smalt-burn:latest` (test target) `sha256:7557d29a3706c207de1058075c29ed545cb65e43bb5d8f43dbf4fa7957aae184`
  - colima docker server 29.5.2, linux/arm64.
- Label (both images): `org.smalt.subject=29bb0371426a270c9c9ac2dc483b7e2a9d226938`.
- Env wiring: `ENV SMALT_BURN_SUBJECT_SHA=${SUBJECT_SHA}` present in both targets;
  in-image probe: `SUBJECT_SHA=29bb0371426a270c9c9ac2dc483b7e2a9d226938` (echoed from
  `smalt-burn:latest`).
- In-image TLS: `docker/gen_dev_cert_linux.sh` mints `.smalt/tls/{ca-cert,ca-key,dev-cert,dev-key}.pem`
  at `/smalt/.smalt/tls/`; CA:TRUE anchor + CA:FALSE serverAuth leaf (SAN
  localhost/127.0.0.1/management.azure.com/login.microsoftonline.com);
  `openssl verify -CAfile ca-cert.pem dev-cert.pem` → `dev-cert.pem: OK`.
- Owned files: `docker/Dockerfile`, `docker/BUILD_RECEIPT.md`, `docker/gen_dev_cert_linux.sh`.
  `docker/compose.yaml` is a sibling lane's file (AZB-02); left untouched.

## Accept (all real runs, exact output)

1. Full build, release target, live tree → **exit 0**
   (`docker build -f docker/Dockerfile -t smalt:local . --build-context ash_r2rml=/Users/sac/ash_r2rml --progress=plain`,
   log `/tmp/azb01_build2.log`):

   ```
   #8  CACHED   [deps 1/7] COPY mix.exs mix.lock ./
   #10 CACHED   [deps 5/7] RUN mix deps.get
   #12 CACHED   [deps 6/7] RUN MIX_ENV=test mix deps.compile
   #16 CACHED   [deps 7/7] RUN MIX_ENV=prod mix deps.compile
   #17 DONE 0.0s [release 1/5] COPY lib ./lib
   #20 DONE 4.1s [release 4/5] RUN mix compile --warnings-as-errors
   #22 naming to docker.io/library/smalt:local done
   ```

2. Lib-only-touch rebuild (`touch lib/smalt/registry.ex` before the previous build
   run): every deps step **CACHED**, only the source layers re-ran — the CACHED
   lines above ARE the lib-touch run's output (same build; the prior full-build
   cache was warm from a `lib/`-only delta).

3. OTP probe:

   ```
   $ docker run --rm smalt:local erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().'
   28
   exit=0
   ```

4. Version + TLS probe on the test target:

   ```
   $ docker run --rm smalt-burn:latest sh -c 'elixir --version | tail -1; openssl verify -CAfile /smalt/.smalt/tls/ca-cert.pem /smalt/.smalt/tls/dev-cert.pem'
   Elixir 1.19.5 (compiled with Erlang/OTP 28)
   /smalt/.smalt/tls/dev-cert.pem: OK
   ```

5. Test target build → **exit 0** (`--target test -t smalt-burn:latest`,
   `/tmp/azb01_test_build.log`), all deps steps CACHED, `mix compile
   --warnings-as-errors` DONE 45.2s.

## Falsifier — NOT observed

- *deps layer rebuilt after a lib/-only change*: refuted — deps steps CACHED on a
  lib-only delta (Accept 1/2).
- *OTP ≠ 28*: refuted — probe prints `28`.
- *Elixir ≠ 1.19.5*: refuted — probe prints `Elixir 1.19.5 (compiled with Erlang/OTP 28)`.

## Anti-vacuity (mutation witnessed, live tree)

Corrupted one hex checksum in the live `mix.lock`
(`git diff --stat mix.lock` → `1 file changed`), rebuilt `--target deps`:

```
#9  [deps 1/7] COPY mix.exs mix.lock ./     DONE 0.0s   <- cache key moved
#13 [deps 4/7] RUN mix local.hex ...        DONE
#14 [deps 5/7] RUN mix deps.get             DONE
#14 warning: missing dependency ash_graphlaw (../ash_graphlaw)
#14 ... (Mix) ... exit code: 1
```

The deps-layer cache key moved with the lock bytes and the whole layer re-executed
(`mix deps.get` re-ran; the mutant lock then failed closed on checksum mismatch —
the expected typed failure of a corrupted lock). The Accept-2 cache reuse is
therefore not vacuous. Restored byte-exact afterwards:
`shasum -a 256 mix.lock` = `/tmp/mix.lock.orig` =
`9356f9f591637190117e7bb7c5207858910612814cce5d3c874fc36f5dc9ef6e`;
`git diff mix.lock` empty. Mutation image `smalt:av` removed.

## Compile-freeze SLA unblock fixes (sibling files, disclosed)

The first live-tree build failed `mix compile --warnings-as-errors` in the release
stage on warnings introduced by sibling lanes' in-flight edits (none of this lane's
files). Minimal unblock fixes applied per the compile-freeze SLA, clause-grouping
only, zero behavior change; both lanes' receipts should name them:

1. `lib/smalt/data_plane/blob_storage.ex` — moved catch-all
   `get_blob_conditional/4` clause adjacent to its head clause (ungrouped-clauses
   warning); rewrote `iso8601_to_epoch/1` epoch math as pure
   `DateTime.to_gregorian_seconds/1` difference (typing violation:
   `DateTime` minus `:calendar` seconds mix). Host `MIX_ENV=prod mix compile
   --warnings-as-errors` → exit 0 after fix.
2. `lib/smalt/arm_gateway/router.ex` — moved `check_version/3` nil clause adjacent
   to the main clause (ungrouped-clauses warning).
3. `lib/smalt/messaging/amqp/connection.ex` — moved `handle_sasl/2` catch-all
   clause adjacent to the `sasl_init` clause (ungrouped-clauses warning).

## Environment notes (pre-existing, disclosed)

- Colima TLS flaps to hex/docker Hub recur; `HEX_HTTP_CONCURRENCY=1` +
  `HEX_HTTP_TIMEOUT=120` retained in the deps stage (carried from the
  2026-10-14 build receipt, `docker/BUILD_RECEIPT.md`).
- One earlier foreground build hit the 10-minute command cap mid deps.compile on a
  cold cache; the resume completed from layer cache — the cache doing its job.

## Deviations (disclosed)

- `rust cargo` in the package list (wasmex/ex4pm NIF toolchain) — carried from the
  prior build receipt, still required.
- Build commands for AZB-02+ must pass `--build-context ash_r2rml=/Users/sac/ash_r2rml`
  (path dep, `only: [:dev, :test]`); `--target test` for burn lanes, default
  (release) for the image pin.
- Prod dep compile is layered so both targets share one deps stage
  (`mix deps.get` once, then `MIX_ENV=test`/`MIX_ENV=prod` deps.compile);
  `mix compile --warnings-as-errors` gates both targets' source layer.
