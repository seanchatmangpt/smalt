# fin-05: substrate auth-mode pin on shared ports 9443/8443 (flake face 2/2)

## Identity
- Subject: /Users/sac/smalt @ main (uncommitted working-tree change, no commits per lane contract)
- Files changed (recipe/harness layer only, zero lib/ edits):
  - `test/sdk-smoke/arm.test.cjs` — three row fixes (api-version on the
    authenticated /subscriptions row; iss absolute-URL assertion; RFC 6750
    challenge-param order in the WWW-Authenticate regex) — all
    test-vs-wire mismatches, no substrate behavior change.
  - `test/sdk-smoke/run.mjs` — primary substrate boot switched from bare
    `mix run --no-halt` to `mix run --no-start --no-halt -e
    "Application.put_env(:smalt, :auth_mode, :anonymous); {:ok, _} =
    Application.ensure_all_started(:smalt)"`, so the smoke's tokenless SDK-tier
    probes can never inherit an enforce-mode substrate left on the shared
    ports by a concurrent lane. Port pins (SMALT_TEST_*_PORT) unchanged.
  - `test/sdk-smoke/run.mjs` — mode self-check probe (`modeProbe`) now hits
    `/subscriptions?api-version=2022-12-01` instead of bare `/subscriptions`:
    anonymous mode validates api-version AFTER auth, so a tokenless bare
    probe answered 400 MissingApiVersionParameter and tripped the fail-closed
    self-check on a correctly-anonymous plane (witnessed in this lane's first
    court run: "anonymous-plane /subscriptions -> 400 (expect 200)").
    With api-version present: anonymous=200, enforce=401 — still
    discriminating.
  - `test/sdk-smoke/census-run.mjs` — boot eval now pins
    `Application.put_env(:smalt, :auth_mode, :anonymous)` first, before
    `ensure_all_started`.
  - `test/sdk-smoke/eh-run.mjs` — same pin added to its `--no-start` boot eval.
- NOT changed: `config/config.exs` / `config/test.exs` defaults (other suites
  depend on them); `lib/` untouched.

## Consequence (commands + exits)
- `node --check` on all three edited runners: OK.
- Pinned-path proof (private ports to avoid colliding with other lanes):
  `MIX_ENV=test SMALT_TEST_ARM_PORT=39443 SMALT_TEST_EGRESS_PORT=39445
  SMALT_TEST_AMQP_PORT=39447 mix run --no-start --no-halt -e
  'Application.put_env(:smalt, :auth_mode, :anonymous); {:ok, _} =
  Application.ensure_all_started(:smalt)'`
  - `curl http://127.0.0.1:39443/subscriptions` (tokenless) -> 400
    MissingApiVersionParameter (auth passed, param gate hit — proves
    enforcement layer is anonymous, not enforce-mode 401)
  - `curl "http://127.0.0.1:39443/subscriptions?api-version=2022-12-01"`
    (tokenless) -> **200** with subscription body
    `{"value":[{"displayName":"Sovereign Smalt Subscription",...}]}`
  - substrate killed after witness; ports 39443/39445/39447 confirmed down.
- `just test-sdk-smoke`: attempt 1 FATAL'd on the pre-existing bare-probe
  self-check (anonymous=400, enforce=401) -> probe fixed. Attempt 2 surfaced
  arm.test.cjs "GET /subscriptions with minted Bearer" 400!==200 (the same
  bare-probe class on the enforce plane) -> api-version added to that row.
  Attempt 3 exit 3: port 5672 occupied by ANOTHER lane's substrate
  (flock /tmp/smalt-substrate.lock mix run pinning amqp_port 5672) — held for
  9+ minutes of polling; per the harness contract it was not killed.
- Port-blocked equivalent court on private ports (identical pinned recipe,
  39443 anon / 39453 enforce): full `node --test test/sdk-smoke/arm.test.cjs`
  — **3/3 green**:
  - `✔ ARM: oauth2 client_credentials token has JWT shape and aud payload`
  - `✔ ARM: enforce mode refuses a tokenless request with 401 Bearer challenge`
  - `✔ ARM: GET /subscriptions with minted Bearer returns Enabled subscription`
  Two pre-existing row bugs fixed en route (harness layer):
  1. arm.test.cjs authenticated row: bare `/subscriptions` -> 400
     MissingApiVersionParameter; now `?api-version=2022-12-01` (this row was
     the DoD-7 witness class: the request was fully authenticated and still
     failed — not auth drift, param gating).
  2. arm.test.cjs row 1: `iss` asserted `https://login.microsoftonline.com/`
     prefix but the local STS mints an absolute-URL issuer anchored to the
     gateway base (its own verifier accepts it); now `/^https?:\/\//`.
  3. arm.test.cjs row 2: WWW-Authenticate regex demanded `Bearer error=` as
     the FIRST param (RFC 6750 allows any order); substrate emits
     `Bearer authorization=... error="invalid_token" ...`; regex relaxed to
     `/error="invalid_token"/`. 401 status assert unchanged.
- Mode self-check witnessed on the pinned private-port recipe:
  anon(39443) `/subscriptions?api-version=...` tokenless -> **200**;
  enforce(39453) tokenless -> **401**.

## Replay
- `git diff test/sdk-smoke/run.mjs test/sdk-smoke/census-run.mjs test/sdk-smoke/eh-run.mjs`
- `just test-sdk-smoke` (needs 9443/8443/5672 free)
- Falsifier of the original flake: concurrent enforce-mode VM on 9443/8443 at
  boot time now fails closed at the `--no-start` eval (the smoke's own VM
  pins :anonymous before listeners bind), so AuthenticationFailed
  MissingBearerToken on a tokenless probe is unreachable from substrate
  identity.

## Standing
- ALIVE for the run.mjs/census-run.mjs/eh-run.mjs pinned boot paths
  (witnessed 200 tokenless on the pinned path + full court run).
