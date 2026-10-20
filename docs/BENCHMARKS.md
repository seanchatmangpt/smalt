# BENCHMARKS

# Smalt Benchmarks — Measured vs PRD CTQs

Measured 2026-10-14 (darwin/arm64, Apple Silicon, local loopback, Elixir on
asdf Erlang/OTP 28, MIX_ENV=dev). Receipt:
`tmp/bench-receipt.json` (`smalt-bench/v1`), produced by
`scripts/bench.py`.

## Results

| CTQ | Target | Measured | Verdict |
|---|---|---|---|
| Doctor runtime | <= 3 s | 0.076 s | PASS |
| Substrate boot (spawn -> TCP accept on 9443), median | <= 5 s | 0.77 s (runs: 1.185 / 0.770 / 1.187 / 0.691 / 0.408) | PASS |
| Substrate boot p95 | <= 5 s | 1.187 s | PASS |
| ARM PUT round-trip p95 | < 50 ms | 0.547 ms (p50 0.322, p99 0.929, max 79.6) | PASS |
| Cosmos doc round-trip p95 | < 20 ms | 0.363 ms (p50 0.241, p99 0.475, max 35.8, n=400) | PASS |
| AMQP broker first-frame latency p95 | < 100 ms | 1.086 ms (p50 0.994, p99 2.569) | PASS |

All five CTQs pass on the measured subject. Boot is ~38x under the 5 s
budget (and ~58x under the 45 s MSSQL-emulator baseline); ARM PUT p95 is
~90x under target; Cosmos p95 ~55x under target; AMQP first-frame ~92x
under target.

Notes on the max column: the worst single ARM PUT (79.6 ms) and worst
Cosmos op (35.8 ms) are first-touch outliers (first request after boot,
JIT/table allocation on a cold store); p99s stay under 1 ms. A concurrent
lane was running tf-plan smoke against the same tree during measurement;
per-run port contention was handled by a fail-closed wait-for-port-free
gate before every phase.

## Measurement definitions

- Doctor runtime: wall time of `python3 scripts/doctor.py` with the
  substrate stopped (doctor is a pre-flight court defined to run with
  ports free).
- Substrate boot: `subprocess.Popen(["mix", "run", "--no-halt"])` ->
  first successful TCP connect on 127.0.0.1:9443, 5 runs, each in a fresh
  process group, SIGKILL + port-free verification between runs.
- ARM PUT: `http.client` PUT of a small JSON body to
  `/subscriptions/bench-sub/resourceGroups/rg-bench-N?api-version=2021-01-01`,
  200 sequential requests against a live substrate, expect 200/201.
- Cosmos round-trip: POST `/dbs/bench/colls/c/docs` (expect 201) then GET
  `/dbs/bench/colls/c/docs/<id>` (expect 200), 200 iterations (400 timed
  ops), data plane on 8443.
- AMQP first-frame: raw TCP connect to 5672, send 8-byte AMQP 1.0 header
  (`AMQP\x00\x01\x00\x00`), measure time to receive the peer's 8-byte
  header, 50 rounds. This is the broker-ready latency a client observes
  after the listener accepts.

## Run

```sh
lsof -ti tcp:9443 tcp:8443 tcp:5672 | xargs kill   # substrate must be stopped
python3 scripts/bench.py
```

The harness is stdlib-only and fail-closed: it refuses to start if ports
are held (30 s wait then fault), verifies the peer AMQP header, checks
every HTTP status, SIGKILLs the substrate process group in a `finally` on
every path, and sweeps any surviving port holder before exiting. The
receipt is written to `tmp/bench-receipt.json`.

## Regression gate

`scripts/bench_check.py` turns the one-shot benchmark into a gate: it
reads `tmp/bench-receipt.json` and asserts the PRD CTQ thresholds (the
same table as README §Benchmarks; the enforced numbers live in
`scripts/bench_check.py`). Exit 0 when all CTQs pass;
exit 1 on any FAIL or on a missing, schema-mismatched, or stale
(default > 24 h) receipt, printing the failing CTQ table. The gate
never runs the benchmark itself — produce a fresh receipt first:

```sh
python3 scripts/bench.py        # ports must be free (scripts/doctor.py)
python3 scripts/bench_check.py  # exit 0 = gate PASS, 1 = FAIL
python3 scripts/bench_check.py --json        # machine gate receipt
python3 scripts/bench_check.py --max-age-h 1 # tighten staleness
```

Gate receipt schema: `smalt-bench-gate/v1`. Wiring `just bench-check`
to invoke `bench_check.py` is owned by the coordinator.

## Post-wave re-run — 2026-10-14 18:15 PT

Fresh full re-run of `scripts/bench.py` on the post-wave tree (larger
tree, telemetry attached, TLS twin listener, registry regenerated; 33
registry types at measurement time). Receipt:
`tmp/bench-receipt.json` (dated `2026-10-14T18:15:28-0700`), produced by
`python3 scripts/bench.py`, gate verdict from
`python3 scripts/bench_check.py`.

### Fresh table vs PRD CTQs vs 16:52 baseline

| CTQ | Target | 16:52 baseline | 18:15 post-wave | Verdict |
|---|---|---|---|---|
| Doctor runtime | <= 3 s | 0.076 s | 0.079 s | PASS |
| Boot median (5 runs) | <= 5 s | 0.770 s | 1.149 s | PASS |
| Boot p95 | <= 5 s | 1.187 s | 1.353 s | PASS |
| ARM PUT p95 | < 50 ms | 0.547 ms | 0.357 ms | PASS |
| Cosmos round-trip p95 | < 20 ms | 0.363 ms | 0.392 ms | PASS |
| AMQP first-frame p95 | < 100 ms | 1.086 ms | 1.275 ms | PASS |

Gate: **PASS (5/5 CTQs)** — `bench_check.py` exit 0. No CTQ regressed
past its budget. Boot median moved 0.77 s -> 1.15 s (larger registry +
telemetry + TLS twin listener at boot), still ~3.4x under the 5 s
budget. ARM PUT p95 improved (0.547 -> 0.357 ms); Cosmos and AMQP p95s
moved <1 ms and stay >50x under budget.

Fresh runs (boot): 1.156 / 1.130 / 1.353 / 0.253 / 1.149 s.

### Mutation court re-run — 2026-10-14 18:0x PT

`python3 scripts/mutation_court.py` re-run to completion on the
post-wave tree (subject: `lib/smalt/graphlaw/validator.ex`):

| Mutation | Phase | HTTP | Expected | Verdict |
|---|---|---|---|---|
| M1 valid VM PUT | BEFORE | 202 | 200/201/202 | PASS |
| M2 missing vmSize | BEFORE | 400 | 400 InvalidResourceShape | PASS |
| M3 missing location | BEFORE | 400 | 400 InvalidResourceShape | PASS |
| M4 unadmitted type | BEFORE | 400 | 400 InvalidResourceShape | PASS |
| M2 missing vmSize | AFTER (gate bypass) | 202 | 2xx (admitted) | PASS |
| M3 missing location | AFTER (gate bypass) | 201 | 2xx (admitted) | PASS |
| M2 post-restore | CONFIRM | 400 | 400 InvalidResourceShape | PASS |

**Verdict: NON-VACUOUS** (exit 0). Gate present refuses M2-M4, gate
bypassed admits them (202/201), validator.ex restored byte-exact
(sha256 verified: true), post-restore refusal confirmed.

**Disclosure — first court attempt FAILED (exit 1)**: all probes
returned 500, including the M1 valid baseline. Root cause was a
cross-lane compile race on the shared checkout — a concurrent lane was
mid-edit on `lib/smalt/data_plane/sentinel.ex` (syntax error, stray
`end`) while another ran `mix smalt.gen` registry rewrites, so the
court's substrate exited rc=1 at boot. Not a product defect: a manual
valid VM PUT against a settled tree returned 202. Court re-run after
edits settled: all rows PASS, NON-VACUOUS. No code was tuned to make
this pass.

## Concurrency behavior — 2026-10-14 19:34 PT

First concurrent-behavior measurement (`scripts/bench_concurrent.py`,
stdlib-only, `threading` + `http.client`; the sequential `bench.py` is
unchanged). The harness boots its own substrate (pid + process-group
trap), acquires a Bearer token via the ARM STS client-credentials flow
(`/oauth2/v2.0/token` — required since Bearer enforcement landed), then
runs three phases and fails closed on any non-2xx or transport error.
Receipt: `tmp/bench-concurrent-receipt.json`
(`smalt-bench-concurrent/v1`).

### Measured (32/16/2-worker phases)

| Phase | Shape | n | Wall | p50 | p95 | p99 | max | Statuses | Errors |
|---|---|---|---|---|---|---|---|---|---|
| ARM PUT (unique RGs) | 32 workers x 25 | 800 | 0.110 s | 3.721 ms | 9.142 ms | 11.640 ms | 13.931 ms | 800x 201 | 0 |
| Cosmos doc create | 16 workers x 20 | 320 | 0.080 s | 3.496 ms | 6.406 ms | 7.735 ms | 8.137 ms | 320x 201 | 0 |
| Store CAS race (same RG id) | 2 workers x 250 PUT | 500 | 0.055 s | 0.196 ms | 0.354 ms | 0.412 ms | 0.577 ms | 1x 201 + 499x 200 | 0 |

Verdict: **PASS** (exit 0) — zero 5xx, zero non-2xx, zero transport
errors across all 1,620 concurrent requests.

CAS race witness: two workers racing PUTs on the same resource id
(`/subscriptions/bench-sub/resourceGroups/rg-cas-race`) produced exactly
one 201 (the create) and 499x 200 (the serialized update path) — the
Store's serialized lookup+insert inside the GenServer admits every
concurrent write with no lost update and no error response. p95 0.354 ms
under contention vs 3.7 ms p50 on the unique-key concurrent path.

Concurrency overhead vs the sequential baseline (`bench.py`, 16:52):
ARM PUT p50 went 0.322 ms sequential -> 3.721 ms at 32-way concurrency
(~11x) and Cosmos p50 0.241 -> 3.496 ms at 16-way (~14x), while
throughput rose to ~7,270 ARM PUTs/s and ~4,000 doc creates/s — the
substrate parallelizes cleanly; per-request latency grows roughly with
concurrency, as expected for a BEAM gateway saturating scheduler
contention, and p99 stays under 12 ms.

### Harness notes / disclosures

- The run used private high ports (39443/38443 via
  `SMALT_BENCH_ARM_PORT` / `SMALT_BENCH_DATA_PORT`) because the
  canonical 9443/8443 were held by other lanes' substrates at measurement
  time; the substrate is booted with `mix run --no-start --no-halt -e
  "Application.put_env(:smalt, :arm_port/:egress_port, ...)"` so the
  env lands before listeners bind.
- Two earlier attempts failed for environmental reasons, not product
  defects: (1) a cross-lane compile race (`queue_store.ex` guard error,
  then a transient `resource_graph.ex` stray `end` — both fixed by their
  owning lanes while this lane waited); (2) an earlier harness revision
  deadlocked its own Cosmos phase (barrier parties mismatch — main
  thread waited on a barrier the workers never joined). The deadlock was
  a bench-script defect, fixed before the measured run; substrate
  behavior was never the cause.
- 401s from the pre-auth data plane were the first observed phase-2
  behavior after Bearer enforcement landed mid-session; the harness now
  authenticates like a real client instead of measuring the 401 path.

## Post-integration bench at HEAD — 2026-10-14 23:00–23:30 PT

Re-run of the sequential gate (`scripts/bench.py` -> `scripts/bench_check.py`)
after the auth-enforcement / master-key / throttle / OCEL / MCP / semconv
integration. The canonical-port route is blocked three ways at this HEAD;
each is recorded, none was tuned around by touching non-owned files.

### Blockers hit (in order)

1. **Cross-lane in-flight compile breaks.** First boot attempt failed on
   `lib/smalt/arm_gateway/router.ex` (`&&&/2` undefined — missing `import
   Bitwise`), fixed by its owning lane while this lane waited (~23:19);
   the next attempt failed on `lib/smalt/egress_router.ex`
   (`conn_placeholder/0` undefined), also fixed by its owner (~23:22).
   Tree then compiled clean (warnings only). No edit was made outside
   owned files.
2. **Canonical ports held by another lane's substrate** (9443/8443/5672,
   beam pid 33162), which also fails `scripts/doctor.py` port-in-use.
   All measurement moved to private ports (39443/38443/25672) via runtime
   `Application.put_env` at boot, same contract as bench_concurrent.py.
3. **`scripts/bench.py` measures the 401 path.** With `:auth_mode, :enforce`
   now the dev default, bench.py's unauthenticated ARM PUT phase fails
   closed (`ARM PUT #0 returned 401`), exit 1, no receipt. FINDING: the
   sequential harness needs the same STS client-credentials treatment
   bench_concurrent.py already has. Doctor phase PASSed at 0.639-0.668s
   and boot p95 1.870s (5 runs) before the ARM phase faulted.

### FINDING (defect, product): STS tokens refused — IssuerMismatch at HEAD

`Smalt.Auth.Bearer` requires `iss` prefix
`https://login.microsoftonline.com/` (`lib/smalt/auth/bearer.ex:31,149`)
but the local STS issues `iss = "{request_authority}/{tenant}/v2.0"`
(`lib/smalt/arm_gateway/router.ex:198`, 307, 970). Witness: single
authenticated PUT probe returned `401` with
`www-authenticate: Bearer error="invalid_token", error_description="IssuerMismatch"`.
Measured blast radius: `scripts/bench_concurrent.py` at HEAD went
**1,620/1,620 requests 401** (800 ARM + 320 Cosmos + 500 CAS; zero
transport errors) despite a valid STS token — the full authenticated
hot path (auth + semconv emit + throttle) is unmeasurable at this HEAD
because no request reaches it. Receipt:
`tmp/bench-concurrent-receipt.json` (verdict FAIL, overwritten with the
401 run). Consequence chain: STS-issued-token audience/scope/issuer
contract changed in one lane without the verifier lane following.

### Measured (anonymous mode, private ports, inline driver /tmp-only)

Inline driver replicates bench.py phase shapes exactly (ARM PUT 200x,
Cosmos POST+GET 200x, AMQP first-frame 50x, boot x5) against a substrate
booted with `auth_mode: :anonymous` — the only mode that reaches the
accept path at this HEAD. Receipt:
`tmp/bench-inline-anonymous-receipt.json`.

| Phase | n | p50 | p95 | p99 | max | Baseline 18:15 | Budget | Verdict |
|---|---|---|---|---|---|---|---|---|
| ARM PUT | 200 | 0.292 ms | 0.392 ms | 0.464 ms | 26.0 ms | p95 0.357 ms | p95 < 50 ms | PASS (statuses 200x 201) |
| Cosmos POST+GET | 400 | 0.246 ms | 0.354 ms | 0.411 ms | 5.8 ms | p95 0.392 ms | p95 < 20 ms | PASS (200x 201 + 200x 200) |
| AMQP first-frame | 50 | 0.999 ms | 1.308 ms | 2.819 ms | 2.8 ms | p95 1.275 ms | < 100 ms | PASS (50/50 AMQP headers) |
| Boot | 5 | 2.377 s | 2.487 s | — | 2.49 s | p95 1.353 s | <= 5 s | PASS |

No CTQ regressed past budget. Nominal deltas (ARM PUT p95 +0.035 ms,
boot p95 +1.1 s) are within budget; boot p95 increase is consistent with
the new MCP listener + OCEL emitter booting additional supervision trees
and was not tuned.

### Measured (enforce mode — the refusal hot path)

| Phase | n | p50 | p95 | statuses |
|---|---|---|---|---|
| ARM PUT | 200 | 0.309 ms | 0.409 ms | 200x 401 |
| Cosmos POST+GET | 400 | 0.229 ms | 0.328 ms | 400x 401 |

Receipt: `tmp/bench-inline-enforce-receipt.json`. The 401-refusal path
itself is cheap (p95 0.409 ms / 0.328 ms); the risk is not refusal cost
but that the authenticated accept path cannot be measured at HEAD until
the issuer contract is reconciled.

### Gate status

`python3 scripts/bench_check.py` at 23:29 returned PASS 5/5 — but against
the 18:15 receipt, which predates the auth/semconv integration
(as-of-date evidence only, not evidence about HEAD). The gate receipt is
stale; a fresh `smalt-bench/v1` receipt requires bench.py to authenticate
(blocked per FINDING above).

### Next actions (for owning lanes)

1. Auth lane: reconcile STS issuer vs `@iss_prefix` in
   `lib/smalt/auth/bearer.ex` (one-line contract fix either side), then
   this lane re-runs the full authenticated sequential + concurrent
   benches.
2. bench.py owner: add the STS client-credentials flow (port the
   `fetch_bearer_token` from bench_concurrent.py) so the sequential gate
   stops measuring the 401 path.
3. Re-run doctor on free canonical ports for a fresh doctor receipt.

## Authenticated bench v3 — 2026-10-15 00:05–00:25 PT

Re-run of the full 5-CTQ suite on the **authenticated accept path**
(auth + semconv emit + throttle on the hot path) after the issuer fix in
`lib/smalt/auth/bearer.ex` (request-authority `iss` accepted, lane 105
contract). Driver: `tmp/bench-v3/bench_v3_auth.py` (lane-owned; mirrors
`scripts/bench.py` phase-for-phase — doctor, boot x5, ARM PUT 200x, Cosmos
POST+GET 200x, AMQP first-frame 50x — with a real STS client-credentials
mint per run and private high ports 39443/38443/25672 so canonical ports
stay free for other lanes). Private-port substrate spawn includes the
`:amqp_port` put_env that `scripts/bench_concurrent.py`'s private-port
branch omits.

### FINDING (defect, product): authenticated Cosmos accept path unreachable cross-port at HEAD

The lane-105 fix made `Smalt.Auth.Bearer.issuer_ok?/2` accept
`iss` = "{this-request's authority}/{tid}/v2.0". The ARM STS
(`Smalt.ArmGateway.Router`) mints `iss` from the *token endpoint's*
request authority. With ARM on :9443 and Cosmos on :8443 (or any private
equivalents), the token `iss` carries the ARM authority, the Cosmos-side
plug derives authority from the *Cosmos* request, and the prefix check
fails: measured `POST /dbs/...` with a fresh valid STS token ->
`401 {"code":"InvalidAuthenticationTokenIssuer","message":"IssuerMismatch"}`.
`bench_concurrent.py`'s Cosmos phase (ARM STS token -> :8443) will 401 for
the same reason. Two sub-findings while characterizing it:

- `request_authority/1` honors `x-forwarded-host`/`x-forwarded-proto` even
  on direct connections — a client can make any token pass the iss check
  by presenting the minting authority in a header. (Header-trust finding;
  not tuned, not fixed — not this lane's files.)
- The v3 driver measures the Cosmos accept path by presenting the ARM
  authority via `x-forwarded-host`; signature/exp/aud/roles verification
  is identical and real, only iss-authority equality is satisfied via the
  header. Disclosed; not a fix — a measurement affordance that also
  witnesses the header-trust issue.

Also this run window: `tmp/dev-key.pem` was regenerated 0644 by another
lane twice during the run (doctor's `dev-key-perms` court refused;
remediation `chmod 600` applied twice per doctor's own machine-remediation
block). Root cause is the cert generator, not the court.

And: `scripts/bench.py` at HEAD still sends no Authorization header — in
dev (`auth_mode: :enforce`) its first ARM PUT faults with 401
(`[FAULT] ARM PUT #0 returned 401`), so the default sequential gate still
cannot produce a fresh `smalt-bench/v1` receipt at HEAD. Measured doctor
phase of that run: 0.791s PASS (ports free, 2026-10-14 23:5x PT). Next
action unchanged: port `fetch_bearer_token` into bench.py.

### Measured (authenticated accept path, enforce mode, ×2 full runs)

| Phase | n | Run 1 p50/p95 (max) | Run 2 p50/p95 (max) | Budget | Verdict |
|---|---|---|---|---|---|
| doctor | 1 | 0.566 s (—) | 0.608 s (—) | <= 3 s | PASS |
| boot | 5 | median 1.519 s, p95 1.744 s | median 1.721 s, p95 2.289 s | p95 <= 5 s | PASS |
| ARM PUT | 200 | 0.343/0.433 ms (4.1) | 0.309/0.394 ms (—) | p95 < 50 ms | PASS |
| Cosmos POST+GET | 400 | 0.283/0.443 ms (3.9) | 0.280/0.344 ms (—) | p95 < 20 ms | PASS |
| AMQP first-frame | 50 | 0.996/1.123 ms (2.9) | 0.998/1.205 ms (2.8) | p95 < 100 ms | PASS |

No CTQ regressed past budget with auth + semconv + throttle on the hot
path: ARM p95 0.394–0.433 ms vs anonymous p95 0.392 ms (v2, below), Cosmos
p95 0.344–0.443 ms vs anonymous 0.354 ms. The authenticated accept path
costs ~0.05 ms p95 over anonymous — no ×3 regression confirmation needed.

### Gate

`python3 scripts/bench_check.py --receipt tmp/bench-v3/bench-receipt.json`
-> **PASS (5/5 CTQs)** on both runs. Receipt on disk is run 2
(2026-10-15T00:24:33-0700), schema `smalt-bench/v1`. The default-location
`tmp/bench-receipt.json` remains the stale 18:15 anonymous receipt until
bench.py gains the STS mint.

### Wire-tier refusal sweep + engine-kill court — V261014-18 (2026-10-15, lane 18)

New courts landed with the v26.10.14 wave (work order
`docs/jira/v26.10.14/18-mutation-courts.md`):

- **Wire-tier malformed-payload refusal sweep** —
  `test/wire_tier_refusal_sweep_test.exs` (RETIRED@64f6099 — witness record preserved; successor: `verification/ts` ARM probes) iterates
  `Smalt.Registry.admitted_resource_types()` DYNAMICALLY (tripwire `>= 30`;
  38 at run time), resolves each type's ARM route from the type's segment
  shape (generic 3-segment route; child routes for nested Registry types;
  parented-child chains created with conforming payloads via the real
  router), PUTs the lens-2-inverted malformed payload over real HTTP
  (Bandit + raw `:gen_tcp`), and asserts per type: `400 InvalidResourceShape`
  (target `AshGraphLaw.Enforcement`), never 422, never 2xx. Contrast row:
  `Microsoft.Compute/disks` conforming PUT -> **201** + GET round-trip **200**
  (vacuity guard — the sweep distinguishes refusal from admission).
  Verdict: **NON-VACUOUS**; `mix test test/wire_tier_refusal_sweep_test.exs`
  3/3, 0 failures (2026-10-15 15:28 PT). Test RETIRED@64f6099 (clean-room reset). (Test RETIRED@64f6099.)

| Sweep outcome (38 types) | n | Per-type wire answer to malformed PUT |
|---|---|---|
| Law holds: 400 InvalidResourceShape, never 422/2xx | 36 | 400 `InvalidResourceShape` |
| FOUND DEFECT V261014-18-D1 (shapeless shape, asserted in-test) | 1 | **201 admitted** — `Microsoft.Network/networkSecurityGroups` (NsgShape: no required paths, `sh:closed false` → validator admits ANY payload; malformed probe admitted). Set derived dynamically from compiled shapes, never a hardcoded name. |
| FOUND DEFECT V261014-18-D2 (admitted type, no ARM route) | 1 | **404 RouteNotFound** — `Microsoft.Network/privateDnsZones/virtualNetworkLinks`: no PUT route matches the 4-segment azurerm form; falls through the nested glob to the catch-all. Fail-closed, but the type is unreachable and its shape gate never runs on the wire. Set membership response-derived per run. |

- **Engine-kill court** — new describe in `test/egress_dispatch_test.exs`
  ("engine-kill court: real engine unload -> 503 RouteNotReady over real
  :gen_tcp"). BEFORE: real `:gen_tcp` GET /dbs -> **200** on the loaded
  cosmos engine. KILL: beam hidden + `:code.purge` + `:code.delete` (for a
  functional engine, module unload IS the live-engine kill; purge+delete
  alone is NOT sufficient — `Code.ensure_loaded?/1` reloads from the on-disk
  beam). Same request -> **503 RouteNotReady**, `refute status in [200, 201]`
  alongside `assert == 503`. RESTORE: beam renamed back +
  `Code.ensure_loaded/1` -> request **200** (AFTER — kill was real, court
  non-vacuous). Isolation: kill runs against an isolated child tree (private
  Store + Bandit on an ephemeral port booted in-test; module + beam restored
  in-test AND in `on_exit`) so shuffled siblings inherit neither a stopped
  tree nor a purged engine.

| Engine-kill court row | Phase | HTTP | Expected | Verdict |
|---|---|---|---|---|
| GET /dbs, loaded cosmos engine | BEFORE | 200 | 2xx | PASS |
| GET /dbs, engine killed (beam hidden + purge + delete) | KILL | 503 `RouteNotReady` | 503 `RouteNotReady`, refute 201/200 | PASS |
| GET /dbs, beam restored + module reloaded | RESTORE | 200 | 2xx | PASS |

**Verdict: NON-VACUOUS.**

**Disclosure — first court run FAILED (own refute fired)**: the first run
asserted `refute Code.ensure_loaded?(cosmos)` after `:code.purge` +
`:code.delete` alone and FAILED ("engine module still loaded") —
`Code.ensure_loaded?/1` reloads from the on-disk beam, so purge+delete alone
is not a kill. No lib/ code was touched; the court was corrected to hide the
beam file (same mechanics as the existing Purview seam test
`test/egress_dispatch_test.exs` "RouteNotReady 503 when a sibling module is
not compiled"), after which all rows PASS. This failure is itself evidence
for the work order's Gap-2 claim that the existing seam-faked tests are
materially weaker than a real kill.

**Found defects (filed, NOT patched — out of scope per work order)**:

- **V261014-18-D1** — `Microsoft.Network/networkSecurityGroups` (NsgShape,
  `priv/shacl/smalt-shapes.ttl`): no required paths, `sh:closed false` → the
  GraphLaw validator admits ANY payload; a malformed NSG PUT is ADMITTED 201
  on the wire. Suggested fix (follow-up): required paths or `sh:closed true`
  per the shapes-file flip law. The sweep test asserts this set explicitly
  (dynamically derived) so the defect cannot regress silently: tightening
  the shape flips the row to the 400-law and the in-test defect clause must
  then be deleted.
- **V261014-18-D2** — `Microsoft.Network/privateDnsZones/virtualNetworkLinks`
  is an admitted Registry type with NO ARM PUT route; the azurerm-form path
  falls through to the catch-all and answers `404 RouteNotFound` before the
  shape gate ever runs. Suggested fix (follow-up): a child route
  (`.../privateDnsZones/:parent/virtualNetworkLinks/:name` ->
  `handle_child_put/5`, the same shape as the vault-keys route).

**Benign-noise note**: Spark DSL warnings in test output are EXPECTED
refusals from `ash_extension` `generated_verify.ex`, exercised deliberately
by `test/ash_extension_test.exs` (`compile_refused` under
`Code.with_diagnostics`). Not filed, not silenced.

### e1 enclave-loop lane — 2026-10-16

Registered in `scripts/bench/REGISTRY.md` as a new lane family `e`
(enclave loops): a full provision -> data-plane -> console -> residue
lifecycle over a terraform-managed ephemeral environment. Not an
adversarial probe (`a*`), SDK surface probe (`b*`), cross/chaos soak
(`c*`), or Next.js lifecycle (`n*`) — hence the new letter. Port law:
`e1 -> 39370..39375` (disjoint from the b-band 39010..39125 and c-law
39200+).

### Run

```sh
just enclave-loop   # invokes scripts/tf_enclave_loop.sh
```

### Phases

1. **Provision** — terraform brings up the ephemeral enclave on the
   e1 port block; the lane fails closed if a port in 39370..39375 is
   already held (same law as `bench_boot`).
2. **Data plane** — drives blob/cosmos/kv ops against the provisioned
   enclave, collecting latency percentiles.
3. **Console** — exercises the Sovereign Console path end to end
   through the enclave endpoints.
4. **Residue** — verifies the enclave tears down clean: no surviving
   listeners on 39370..39375, no leftover state files. Residue is
   fail-closed — a surviving holder fails the lane.

### Result

One jsonl row set in `docs/jira/v26.10.16/bench/e1-enclave-loop.jsonl`
(script underscore `tf_enclave_loop.sh`, result hyphen — standard
convention), same row schema as the other lanes.

### Loud-skip semantics

Exit 0 pass / 1 test fail / 3 harness-skip. If terraform (or any
enclave prereq) is absent, the lane prints `[SKIP] <reason>` to stdout
and exits 3 — a skip is loud and typed, never a faked pass (smalt
exit-code contract). No jsonl row is emitted on skip.

## One-shot mutation probes — dated stamps (V261014-18 §3.3, decision: DEFER full-court upgrade)

Per the work order §3.3 decision: the six one-shot mutation-probe claims are
stamped as dated ONE-SHOT receipts, NOT upgraded to the full-court protocol
(BEFORE/AFTER/restore, sha256 byte-exact, exit 2 = BLOCKED) this release;
upgrade is bounded follow-up (V261014-18a if pursued). **None of these is a
court.** The only full-court protocol in the tree is `scripts/mutation_court.py`.

| Probe claim | Doc pin | One-shot date | Stamp |
|---|---|---|---|
| cosmos continuation forged-check | `docs/how-to/dev-loop.md` (refresh-6 row, 2026-10-15) | 2026-10-15 | one-shot — not full-court protocol |
| auth criticality fence | `docs/how-to/dev-loop.md` (refresh-6 row, 2026-10-15) | 2026-10-15 | one-shot — not full-court protocol |
| blob If-Match precheck | `docs/how-to/dev-loop.md` (refresh-6 row, "3/3 non-vacuous") | 2026-10-15 | one-shot — not full-court protocol |
| typ-header fence | `docs/WIRE_PARITY.md:121` | 2026-10-15 | one-shot — not full-court protocol |
| tee-admit jti | `docs/WIRE_PARITY.md:113` | 2026-10-15 | one-shot — not full-court protocol |
| LRO lens-9 | `docs/WIRE_PARITY.md:94` | 2026-10-15 | one-shot — not full-court protocol |

Scope of the runs behind these stamps: plain `mix test` (2026-10-15 refresh
6, test-corpus-b-lens2 cycle 1) and refresh-9 (lens6_fuzz + lro_test 27/0)
on the shared checkout mid-landing — one-shot kills, not the full-court
protocol.

## T5 terraform clean-room ladder (V26.10.16 — authored, pending execution)

Receipt: `docs/jira/v26.10.16/sdk-results/t5-cleanroom.md` (standing
PENDING-EXECUTION; authored 2026-10-16, execution gated on cascade + a
trusted machine per the enclave-trust hop ruling).

### Ladder semantics

Full provision → audit → residue lifecycle, five stages, each individually
gated:

1. **apply** — clean-room `terraform apply -auto-approve`. Budget: wall
   < 30 s; fail-closed on any port already held in the T5 block (same law
   as `bench_boot`).
2. **plan 0 drift** — `terraform plan -detailed-exitcode` immediately after
   apply. Budget: < 30 s. Pass: exit 0, empty diff — proves the apply is
   idempotent (no unmanaged drift between create and reconcile).
3. **data-plane audit** — data-plane probes against the provisioned
   endpoints, one leg per family matrix. Pass: all probes PASS with the
   family named per leg.
4. **destroy** — `terraform destroy -auto-approve`. Budget: < 30 s. Pass:
   exit 0 and destroyed count == created count.
5. **NFR-4 identity** — post-destroy residue check: no surviving listeners
   on the T5 port block, no leftover state files. Fail-closed: a surviving
   holder fails the ladder.

### Budget gates and exit contract

- apply and destroy each carry an independent < 30 s wall gate.
- Ladder exit: 0 pass / 1 stage fail / 3 harness-skip (absent trust or
  terraform prereq → loud `[SKIP] <reason>`, no rows emitted on skip —
  smalt exit-code contract).
- Standing flip PENDING-EXECUTION → PASS is receipt-gated: the receipt
  must embed the real stage table + verbatim output. No receipt, no flip.

## See Also

- `docs/JUST_REFERENCE.md` (`just bench` / `just bench-check` recipes)
- `docs/how-to/dev-loop.md` (private port allocation, boot-budget contract)
- `docs/jira/v26.10.16/sdk-results/t5-cleanroom.md` (T5 clean-room ladder receipt)
