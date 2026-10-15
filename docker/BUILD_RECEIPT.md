# Build receipt — smalt:local (2026-10-14)

## Identity

- Tree: `/Users/sac/smalt` (not a git checkout — no SHA available).
- Image: `smalt:local`, ID `461e8cb08c84`, 262 MB, built 2026-10-14 ~18:17 PT.
- Docker: Colima `default` profile, docker server 29.5.2 / client 28.0.4,
  macOS Virtualization.Framework, aarch64.

## Build

Full-context build with both sibling path deps injected:

```sh
docker build -f docker/Dockerfile -t smalt:local . \
  --build-context ash_graphlaw=/Users/sac/ash_graphlaw \
  --build-context ggen_igniter=/Users/sac/ggen_igniter
```

- Result: exit 0. `mix deps.get`, `mix deps.compile`, `mix compile`, and
  `mix release smalt --path /app/_release` all succeeded inside the build
  (`_release/bin/smalt start|remote|stop` listed by the release step).
- Full context (not trimmed) worked; no Dockerfile changes needed.

## Environment repair (pre-existing, disclosed)

- The Colima docker daemon socket was dead at session start:
  `Cannot connect to the Docker daemon at unix:///Users/sac/.colima/default/docker.sock`
  Two `colima restart` cycles later it served requests; it flapped (daemon
  socket refused connections) twice more mid-session, once during a census
  run. Each time `colima restart` recovered it. This instability is
  environment-level, not image-level.

## Run + verification (compose profile)

- `docker compose -f docker/compose.smalt.yml up -d` → container `smalt`
  reached `healthy`.
- `curl http://127.0.0.1:9443/common/discovery/instance` → 200:
  `{"authorization_endpoint":"https://login.smalt.local/00000000-.../oauth2/authorize","issuer":"https://login.smalt.local/00000000-.../v2.0","name":"smalt-sovereign",...}`
- `curl http://127.0.0.1:9443/subscriptions` → 200:
  `{"value":[{"displayName":"Sovereign Smalt Subscription","id":"/subscriptions/00000000-...","state":"Enabled",...}]}`

## Census against the containerized broker — FAILING (fail-closed)

The container mints an unknown dev SAS key at boot
(`SasVerifier.shared_key/0` falls back to a random `:persistent_term` key
when `:sb_shared_key` is nil), so the container was re-run with a pinned
key via a release eval override (same ports/hardening):

```sh
docker run -d --name smalt ... smalt:local eval \
  'Application.put_env(:smalt, :sb_shared_key, "<key>"); {:ok,_}=Application.ensure_all_started(:smalt); Process.sleep(:infinity)'
```

`node --test census.test.cjs` with `SMALT_SDK_ROOT=/Users/sac/cai/athena/playground/node_modules`
and the matching `SMALT_SB_SHARED_KEY` → **0/8 probes pass**:

- probe: authentication — FAIL (timeout; broker log shows the SDK's CBS
  `put-token` arriving and answering `401 INVALID_LOCAL_SAS`)
- probe: bytes / exclusive-session / renewal-peek / abandon-complete /
  stale-handle / dead-letter / ordered-session — FAIL

Rerun after a daemon flap reproduced 0/8 identically: the failure is
deterministic, not infra noise.

## Control run: host substrate (`census-run.mjs`) — also FAILING

To separate container-specific failure from census convergence state, the
harness was run as designed against a host `mix run` substrate:

- 0/8 probes. probe: authentication → 401 `INVALID_LOCAL_SAS` + timeout;
  probes 2–8 → `ECONNREFUSED 127.0.0.1:5672` because the substrate's
  `QueueStore.dequeue_matching/2` hit a **typing violation**
  (`lib/smalt/messaging/amqp/queue_store.ex:134`, Elixir 1.19 set-theoretic
  type check) and the beam process died mid-run.
- So the census is mid-convergence against the host substrate too: the SAS
  verification scheme (`sig = HMAC(key, "#{sr}\n#{se}")` in
  `lib/smalt/messaging/amqp/sas_verifier.ex:246`) does not match the Azure
  Service Bus SDK's CBS put-token signature derivation, and the substrate
  crashes on `dequeue_matching/2`. Both defects are in `lib/`, outside
  this lane's owned files — reported, not touched.

## Harness notes (read-only observations)

- `census-run.mjs` must be launched from the repo root: it resolves the
  test path as `test/sdk-smoke/census.test.cjs` relative to `process.cwd()`;
  launched from `test/sdk-smoke/` it prints
  `Could not find 'test/sdk-smoke/census.test.cjs'` (exit 1).
- Stray `mix run --no-halt` substrates from killed runs hold 5672/9443 and
  must be `kill -9`'d before the next run.

## Cleanup

- `docker compose -f docker/compose.smalt.yml down` — done (network removed,
  container removed).
- Stray substrate/node processes killed; ports 5672/9443 free at handoff.
- Image `smalt:local` (461e8cb08c84) retained.
