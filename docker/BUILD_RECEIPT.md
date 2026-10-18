# Build receipt — smalt:local (AZB-01, 2026-10-18)

Standing: **ALIVE** (full receipt: `docs/jira/v26.10.18/receipts/azb-01-image-pin.md`).

## Identity

- Tree: `/Users/sac/smalt` @ `29bb0371426a270c9c9ac2dc483b7e2a9d226938` (label
  `org.smalt.subject` on the image carries the same SHA).
- Image: `smalt:local` (target `test`), ID/digest
  `sha256:1fc62d357a4cb11eb4e7d76762f19cd1e2fe3f75094363da024cd78dd213ffa9`,
  linux/arm64, colima docker 29.5.2.
- Base pinned by digest:
  `hexpm/elixir:1.19.5-erlang-28.5.0.2-alpine-3.20.9@sha256:29c51579d430b307d4f6182775373bb18c90173d382ba23011d81808b0fab8cd`.
- Versions in image: OTP 28 (erts 16.4.0.2), Elixir 1.19.5 (probed via
  `docker run ... elixir --version`, exact output in the full receipt).

## Build

```sh
docker build -f docker/Dockerfile -t smalt:local --target test \
  --build-context ash_r2rml=/Users/sac/ash_r2rml --progress=plain .
# exit 0; second build after `touch lib/smalt/registry.ex` shows
# mix deps.get / MIX_ENV=test mix deps.compile / MIX_ENV=prod mix deps.compile
# all CACHED — the warm deps layer moves only when mix.lock moves.
# Release target: same file, --target release (MIX_ENV=prod, mix release
# smalt --path /app/_release), same shared deps stage.
```

## Anti-vacuity (witnessed)

`jason 1.4.5 → 1.4.6` bump in a `git archive` scratch context: the deps layer
cache key moved — `RUN mix deps.get` re-executed (not CACHED) and failed typed
with `(Mix) Unknown package version jason 1.4.6 in lockfile`. Frozen checkout
untouched (mix.lock md5 unchanged before/after).

## Deviations (disclosed)

- `rust cargo` added to the apk set (rustler/explorer NIFs build from source
  on musl; no precompiled triplet for this OTP/ABI).
- The ticket's literal `1.19.5-erlang-28-alpine-3.20` tag does not exist on
  Docker Hub (hub API 404, 2026-10-18); the digest-pinned
  `1.19.5-erlang-28.5.0.2-alpine-3.20.9` is the real tag preserving the
  contract.

## Downstream contract (AZB-02+)

Burn builds must pass `--target test` (or `--target release`) and
`--build-context ash_r2rml=/Users/sac/ash_r2rml`. A bare `docker build -f
docker/Dockerfile -t smalt:local .` builds the release target and needs the
context.
