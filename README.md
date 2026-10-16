# Smalt

Pure-Elixir, BEAM-native substrate that emulates a cloud edge locally:
an ARM-style control plane on **9443**, a TLS twin on **9444**, a data
plane on **8443**, an AMQP Service Bus surface on **5672**, an Event
Hubs surface on **5673**, and a read-only MCP tool surface on **9545**.
It exists for local development and testing — point SDKs, CLIs, and
Terraform-style tooling at loopback and exercise them without a cloud
connection.

See `NOTICE.md` for the clean-room interoperability and trademark
statement, and `LICENSE` (Apache-2.0) for terms.

## Quickstart

```sh
mix deps.get
just doctor                 # T0: binaries and ports are sane before anything runs
node test/sdk-smoke/run.mjs # SDK smoke tier — spawns its own substrate; run with 9443 free
just up                     # boot the substrate in the FOREGROUND (control HTTP 9443,
                            #   TLS 9444, data 8443, AMQP 5672/5673); Ctrl-C or `just down`
```

Note: the SDK smoke harness boots and kills its own substrate, so run it
while 9443/8443/5672 are free — not while a `just up` substrate is
holding the port. `just tf-plan-smoke` (T4) boots a substrate with dev
TLS material from `scripts/gen_dev_cert.sh` and plans terraform fixtures
against it. A docker quickstart lives in `docker/README.md` (multi-stage
image + loopback-only compose, same port map).

Stop the substrate with `just down`. Regenerate the projected registry
from the ontology pack with `mix smalt.gen`.

## SDK smoke harness environment

The SDK smoke harnesses require no `npm install` in this repo: the
Azure SDKs are consumed from an existing `node_modules` tree, resolved
through environment variables:

- `SMALT_SDK_ROOT` — required by every `test/sdk-smoke` harness: a
  `node_modules` directory containing the vendored `@azure/*` packages
  (`storage-blob`, `cosmos`, `service-bus`, `event-hubs`). Unset, the
  harness exits 3 immediately.
- `SMALT_REPO` — repo root for `run.mjs`, `census-run.mjs`, and
  `scripts/mutation_court.py`; defaults to the current directory (or
  `../..` when invoked from inside `test/sdk-smoke/`).

Example:

```sh
SMALT_SDK_ROOT=/path/to/node_modules SMALT_REPO=/path/to/smalt node test/sdk-smoke/run.mjs
```

The Event Hubs leg (`node test/sdk-smoke/eh-run.mjs`) and the Service
Bus census (`node test/sdk-smoke/census-run.mjs`) are separate
harnesses that mint their own `SMALT_SB_SHARED_KEY` and boot their own
substrate; `eh-run.mjs` defaults to alternate ports (19443/18443/15672/15673,
override with `SMALT_EH_ARM_PORT`/`SMALT_EH_EGRESS_PORT`/`SMALT_EH_AMQP_PORT`/`SMALT_EH_PORT`)
so it can run beside other tiers, while `census-run.mjs` uses the
default ports and needs them free.

## Terraform smoke

```sh
just tf-plan-smoke          # or: bash scripts/tf_smoke.sh
```

Boots a substrate with TLS enabled on 9444, runs `init`/`plan` against
`test/terraform_fixture` via `scripts/smalt-tf`, and prints a per-step
receipt (exit 0 pass, 1 preflight/substrate failure, 2 terraform
failure, 77 network-skip when registry.terraform.io is unreachable).

macOS caveat: the azurerm provider verifies the substrate's dev
certificate through Go's `crypto/x509`, which ignores `SSL_CERT_FILE`
on darwin, so `scripts/smalt-tf` installs the dev CA into the login
keychain with `security add-trusted-cert`. The first run needs ONE
interactive approval in the macOS dialog; headless/SSH sessions see
this silently fail (the wrapper's `|| true` masks it) and the plan step
then reports `x509: certificate signed by unknown authority`. Approve
the dialog once (or run `security add-trusted-cert -r trustRoot -k
"$HOME/Library/Keychains/login.keychain-db" .smalt/tls/ca-cert.pem`
from a GUI session) and later runs are unattended. Linux needs no
keychain: the provider honors `SSL_CERT_FILE` (exported by
`scripts/smalt-tf` to `.smalt/tls/ca-cert.pem`).

## Benchmarks

```sh
python3 scripts/bench.py    # measures CTQs against a substrate it spawns (ports must be free)
just bench-check            # asserts tmp/bench-receipt.json against PRD thresholds
```

`bench.py` writes `tmp/bench-receipt.json` (schema `smalt-bench/v1`,
freshness-checked by `bench_check.py`); `bench_check.py` never runs the
bench itself. Gate thresholds: doctor <= 3s, boot p95 <= 5s, ARM PUT
p95 < 50ms, Cosmos round-trip p95 < 20ms, AMQP first frame < 100ms.

## Mutation court

```sh
python3 scripts/mutation_court.py              # boots its own substrate on 9443
python3 scripts/mutation_court.py --self-check # restore-failure detection only
```

Proves the GraphLaw admission gate (`lib/smalt/graphlaw/validator.ex`)
is non-vacuous by injecting a marked gate-bypass mutation, re-probing,
and restoring the file byte-exact (sha256-verified). Exit 0
non-vacuous, 1 vacuous/failed, 2 blocked. Details:
`test/mutation_court/README.md`.

## Authentication

All HTTP planes honor `config :smalt, :auth_mode`:

- `:enforce` (default) — every non-exempt route on `:9443`/`:8443` requires
  a valid `Authorization: Bearer` HS256 token signed with the same STS
  secret (`Smalt.Auth.Bearer`, exp/aud/iss checked; 401 + ARM error envelope
  otherwise). The Cosmos plane additionally validates master-key
  Authorization headers (real string-to-sign HMAC) and applies an optional
  RU throttle (`config :smalt, :cosmos_ru_limit`); the ARM plane applies a
  fixed-window 429 throttle with `Retry-After`.
- `:anonymous` — explicit opt-out (the test suite sets it).

Two auth details worth knowing in enforce mode: `x-forwarded-*` headers are
honored only from configured trusted proxies
(`config :smalt, :trusted_proxies` — exact IPv4 tuples or CIDR strings) and
ignored on direct connections (fail-closed); and the STS's cross-seat
trusted-authority set is VM-local (`:persistent_term`), so a substrate
restart wipes it — pre-restart tokens minted at a sibling seat are refused
after restart (restart implies re-authentication).

Exempt paths: `/oauth2/*`, `/.well-known/*`, `/metadata/endpoints`,
`/common/discovery/*`, `/tenant(s)`, `/attest/*`.

CORS on the 8443 data plane is configurable via
`config :smalt, :egress_cors_origins` (list of exact origins). The default is
`["*"]` — the documented dev posture for the emulator; in production configure
an explicit allowlist (a non-listed origin receives no allow-origin header).

## Compliance courts

Seven per-service courts fence the wire contract against real HTTP/AMQP
traffic (no doubles): `test/compliance/c1_arm.exs` ... `c7_events.exs`,
receipts in `docs/compliance/C1_ARM_REST.md` ... `C7_EVENT_PLANES.md`.

```sh
mix test test/compliance/c1_arm.exs          # c2..c7 likewise
mix test test/compliance/c5_servicebus.exs --include amqp_wire
```

## Stress suite

Load/chaos harnesses under `scripts/stress/` (soak, spike, TLS churn,
AMQP throughput/fanout, ARM scale, blob scale, cosmos bulk, LRO storm,
YCSB-lite, azurite comparison, telemetry overhead, chaos kill, gate cost),
receipts in `docs/STRESS/`. Just recipes: `just soak` (25-min), `just spike`,
`just tls-churn`; the rest run as `python3 scripts/stress/<harness>.py`
or `mix run scripts/stress/<driver>.exs`.

The authoritative measured-bounds table (queue capacity, message/frame
size, lock clamp, CBS claims cap, KQL caps, ledger dedup) lives in
`docs/STRESS/BOUNDS.md`, gated fail-closed by
`python3 scripts/stress/bounds.py` (receipt:
`tmp/invariant-gates/bounds-receipt.json`).

## smaltctl CLI

`cli/` builds `smaltctl`, a Rust control-plane CLI (blob put/get/list/delete,
cosmos query, kv create, court/doctor runners) generated from
`cli/ontology.ttl` via the clap-noun-verb pack. `cd cli && cargo test`.

## Verification ladder

| Tier | Command | What it proves |
|---|---|---|
| T0 | `just doctor` | environment and ports are sane before anything runs |
| T1 | `just test-offline` (`mix test`) | unit suite, no sockets |
| T2 | `just test-wire` (`mix test test/wire`) | wire-tier protocol behavior over real listeners |
| T3 | `just test-sdk-smoke` | real SDK clients vs harness-spawned substrate |
| T4 | `just tf-plan-smoke` | terraform fixture plans against the substrate |
| T5 | `node test/sdk-smoke/census-run.mjs` | Service Bus SDK census probes vs the AMQP surface |
| T6 | `mix test test/chaos` | crash isolation: kill the Store mid-run, listeners survive |
| — | `node test/sdk-smoke/eh-run.mjs` | Event Hubs SDK probes on dedicated alternate ports |
| — | `mix test test/compliance/c1_arm.exs` (+ c2..c7) | per-service wire-contract courts (ARM, Key Vault, Cosmos, Blob, Service Bus, OAuth/OIDC, Event planes); c5 needs `--include amqp_wire` |
| — | `python3 scripts/mutation_court.py` | GraphLaw admission gate non-vacuous |
| — | `python3 scripts/bench.py` + `just bench-check` | PRD perf CTQs hold, fresh bench receipt |
| — | `just gate` | T0..T4 plus the bench gate in sequence; full court |

(T3/T5 need `SMALT_SDK_ROOT` in the environment — see the harness
environment section above.)

All port-bound tiers (T3-T5, terraform, bench, mutation court) boot
their own substrate; run them one at a time with the ports free.

## Layout

- `lib/smalt/` — gateway, egress router, AMQP broker, Event Hubs, store
  (keyed ETS + DETS mirror; atomic `compare_and_swap` transitions).
- `lib/smalt/mcp/` — read-only MCP tool surface on `:9545` (`Smalt.Mcp.Router`):
  generated tool descriptor with `readOnlyHint`, real Store reads, actuation
  refused by name.
- `lib/smalt/ocel/` — object-centric event log registry, conformance
  (fitness + deviations), and deviation admission over the substrate's own
  event stream.
- `lib/smalt/pplan/` — durable P-PLAN task store (`Smalt.PPlan.Task`):
  court-validated `admitted -> running -> succeeded | failed` transitions,
  exclusive claim via CAS, crash recovery.
- `lib/smalt/projection/` + `lib/smalt/semantic/` — semantic projection
  surface (canonical registry projection, admission matrix, semantic epoch;
  R2RML/ex4pm-style mappings in `lib/smalt/semantic/`). See
  `docs/SEMANTIC_PROJECTION.md`.
- `cli/` — `smaltctl` Rust CLI (see above).
- `lib/smalt/registry.ex` — projected first-class from the ontology pack
  (`mix smalt.gen`); there is no separate `generated/` surface.
- `test/` — offline, wire, SDK-smoke, census, terraform-fixture, and chaos tiers.
- `scripts/doctor.py` — pre-flight environment check used by the gate.

## Workspaces & Tooling

- `workspace/` — Smalt Sovereign Console: air-gapped Next.js evaluation console
  for the local emulator; only `127.0.0.1` endpoints are reachable, mutations are
  refused by a verb gate. `just ws-install` / `ws-build` / `ws-lint` / `ws-court`
  (e2e court) / `ws-converge`. Receipts: `docs/jira/v26.10.14/receipts/ws-*.md`.
- `smalt-cli/` — headless Python CLI companion; zero-actuation gate (AU-10) and
  a four-gate verification runner (`run_gates.py`; see `smalt-cli/GATES.md`).
  A `cli-gates` just recipe is pending (lane 03-cli-wiring).
- `test/sdk-full` / `test/sdk-smoke` / `test/sdk-python` — real official Azure
  SDK probes against the local substrate (full probes, T3 smoke tier, Python
  lanes). `just test-sdk-smoke`; `just census` for the Service Bus census
  (needs `SMALT_SDK_ROOT`).
- `test/enclave-testbed/` — composite enclave-grade stress testbed (SKR, WORM,
  Ledger, Purview, Sentinel, RG, Cosmos, LRO, SB, EH plus a chaos overlay):
  `bash test/enclave-testbed/run.sh` (exclusive substrate lock, exit 0 = all
  phases PASS). Current standing: 9 phases, 9 PASS.
- DoD tooling (all landed as Justfile recipes): `just court-x2` (double-run
  flake court), `just publish-dry` (hex publish dry-run), `just verify-all`
  (offline verify ladder), `just sdk-matrix` (SDK registration matrix),
  `just substrate-up` / `substrate-down` / `substrate-status` (lock-protected
  substrate lifecycle), plus `doctor-dod`, `gap-sync`, `receipt-index`,
  `docs-dod-check`, and `lane-clean` for lane-build-root cleanup. Receipts:
  `docs/jira/v26.10.14/receipts/dod-*.md`.

## Legal

Smalt is an independent, clean-room implementation of publicly documented
wire protocols for local testing. It is not affiliated with, sponsored by,
or endorsed by any cloud provider. Product and company names appearing in
protocol strings are trademarks of their owners, used solely for protocol
compatibility. See `NOTICE.md`.

## First Run

Zero-to-green on a fresh checkout:

```bash
brew install elixir terraform just   # python3 ships with macOS
bash scripts/bootstrap.sh            # 8 staged steps; ends with GREEN
just up                              # substrate on http://localhost:9443
```

Success = `bash scripts/bootstrap.sh` prints `[8/8] Proof test ...` and
`GREEN: bootstrap complete.` — prereqs checked, deps fetched, code
compiled, dev env validated, TLS material minted, doctor clean, and a
real boot smoke (`GET http://127.0.0.1:9443/metadata/endpoints` ->
200) before tearing the substrate back down. Details:
`docs/FIRST_RUN.md`; environment variables: `.env.example`.
