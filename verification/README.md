# verification

This directory documents the verification contract for the smalt sovereign
Azure drop-in substrate, and hosts the external SDK suites
(`verification/ts/`, `verification/py/`) plus this registry
(`workflows.json`). Every claim below is grounded in a file path; paths are
the falsifiers. Materialized from the v26.10.19 clean-room reset design
(draft reconciled to the post-deletion tree: the legacy `test/` surface is
gone at commit `64f6099`; the residual tier lives in `test/internal/`).

## the-boundary-law

The verification surface is split by who owns the Azure wire contract, and
there is nothing in between:

- **external TS/PY suites own 100% of the Azure wire contract.**
  `verification/ts/` (TypeScript, official `@azure/*` SDKs) and
  `verification/py/` (official `azure-*` SDKs) are the only places wire
  behavior is asserted end-to-end over real sockets with real client
  libraries.
- **residual `test/internal/` owns ONLY VM-observable invariants.** ExUnit
  assertions over pid liveness, ETS row stability, process monitors,
  NIF/wasmex lifecycle, and DETS mirror recovery. Internal tests never
  re-state wire behavior; the tier is fenced by
  `test/internal/internal_tier_census_test.exs` (forbidden-token scan +
  observables allowlist) and counted by `scripts/non_duplication_gate.py`.
- **nothing in between.** A test is either an external socket/SDK probe or a
  VM-internal invariant. There is no middle tier of "internal wire-ish"
  assertions; anything that looks like one is either promoted to an SDK probe
  or reduced to a VM invariant.

Corollary: a wire behavior with no SDK probe coverage is uncovered, no matter
how many internal tests exist.

## the-portable-azure-target-law

- **Official SDKs only.** Probes use official Microsoft client libraries
  (`@azure/arm-resources`, `@azure/storage-blob`, `@azure/cosmos`,
  `@azure/keyvault-keys`, `@azure/service-bus`, `@azure/event-hubs`, ... in
  `verification/ts/`; the pinned per-lane venvs in `verification/py/`).
  No hand-rolled HTTP client stands in for an SDK where an SDK exists.
- **Env-var retarget to real Azure.** Every probe derives its endpoints from
  environment variables with localhost defaults. Pointing the
  `SMALT_AZURE_*` / `AZURE_*` families (`SMALT_TS_*_PORT`,
  `SMALT_PY_*_PORT`, `SMALT_ARM_BASE`, `SMALT_EGRESS_BASE`) at a real Azure
  endpoint retargets the same probe to real Azure with zero code change.
- **No emulator-internal imports.** Probes must not import smalt's `lib/`
  modules, ETS helpers, or test support. The only coupling is the wire
  (TCP/TLS/AMQP) plus the environment contract. Enforced by
  `scripts/portable_target_gate.py` (import whitelist: `@azure/*`,
  `azure-*`, stdlib, relative imports; hard violations: `lib/smalt`,
  `Smalt.*`, `mix`).
- **Allowed environment = `SMALT_AZURE_*` / `AZURE_*` prefixes + endpoint
  overrides.** Suite-level knobs live under those prefixes; anything else an
  agent tries to thread into a probe is a review finding.

## the-non-duplication-law

A contract is stated once, in one language, at one layer:

- The external tier owns every wire assertion exactly once across TS and PY
  (disposition per the reset census,
  `docs/jira/v26.10.19/receipts/reset-delete-manifest.txt`); the
  non-duplication gate is `scripts/non_duplication_gate.py` (R1 wrapper
  purity, R2 delegated-primitive census, R3 receipt-evidence law).
- The residual tier is fenced by its own census guard
  (`test/internal/internal_tier_census_test.exs`): no HTTP client, no status
  literals, no ARM paths in `test/internal/`.
- Each retry/timeout/poll primitive has exactly one implementation per
  language: the TS bounded-poll harness (`verification/ts/harness/poll.ts`),
  the PY poll helper (`verification/py/harness/poll.py`), and
  `assert_eventually` (`test/internal/poll_helper.exs`) for the residual
  tier.
- When you are about to copy a contract into a second file or language, stop:
  cite the first one instead.

## the-zero-sleep-law

`Process.sleep` / bare `time.sleep` / `setTimeout`-as-coordination is not an
acceptable synchronization methodology in tests or production. Canonical
statement: `docs/NO_SLEEP_DOCTRINE.md`.

- **SDK pollers / LRO pollers / bounded polls only.** Waiting on a condition
  means polling an observable with a deadline and a typed failure: the
  harness poll helpers (`verification/ts/harness/poll.ts` with
  `POLL_DEADLINE_MS = 90_000` shape lifted from the deleted
  `test/sdk-full/ts-run.mjs`, preserved in
  `docs/jira/v26.10.19/lifts/ts-run.mjs`; `verification/py/harness/poll.py`;
  `test/internal/poll_helper.exs`), or the SDKs' own LRO pollers.
- Time-advance is the only admitted sleep class, and only with an adjacent
  `# SLEEP-CLASS: TIME-ADVANCE` annotation (Elixir/Python) or
  `// SLEEP-CLASS: TIME-ADVANCE` (TypeScript).
- The gate is `scripts/sleep_gate.py` (`just sleep-gate`), stdlib-only and
  fail-closed; its TS and PY scopes cover `verification/{ts,py}` and
  `test/internal` (WO-15). Non-vacuity is witnessed by the shim-court
  protocol (`just shim-court sleep_gate`). An unclassified sleep fails the
  gate.
- Duration claims are relative-ratio fences against a sleep-free baseline,
  never absolute ms bounds (ratio-fence sub-law).

## exit-code-contract

One typed exit-code vocabulary across all external harnesses:

| exit | meaning |
|---|---|
| `0` | all probes pass (or pass-with-registered-divergence) |
| `1` | test/probe failure (includes documented SDK limitations) |
| `2` | substrate never came up (substrate-down, not a test failure) |
| `3` | harness/skip failure — a LOUD SKIP, never a silent pass |
| `124` | watchdog kill (`timeout`/internal watchdog fired) |

Grounded in the lifted boot machinery (`docs/jira/v26.10.19/lifts/ts-run.mjs`
header and `process.exitCode = 124`; the lifted conftest at
`docs/jira/v26.10.19/lifts/conftest.py`: exit 2 on readiness timeout, exit 3
on lock failure). Never soften: exit 3 means "environment could not be
established" and is reported, not swallowed. Court-level SKIP policy is
declared in the `just` recipe, not in the harness.

## substrate-profile-mechanics

- **Shared boot library.** One boot implementation everywhere:
  `scripts/lib/substrate_boot.sh` + `substrate-ctl` (WO-14) — fd-9 law
  (children spawned `9>&-` so beams never inherit the flock), boot markers,
  formula blocks, tree-aware orphan sweep, 250ms bounded readiness poll.
  `mix run --no-start --no-halt -e "$BOOT_EVAL"` sets `:smalt` Application
  env via `Application.put_env/2`, then `Application.ensure_all_started(:smalt)`.
- **vN port family.** Port blocks are versioned per lane so concurrent lanes
  never collide: `vN = 39700 + 10N .. +5` (v1..v12; 39700 band verified free;
  39826-39839 spare), alongside the fixed listener set (ARM 9443, TLS twin
  9444, egress/data 8443, AMQP 5672, EH 5673, MCP 9545).
- **Throttle profile via boot-eval put_env.** Non-default traffic shapes are
  injected through the boot eval, never patched at runtime:
  `Application.put_env(:smalt, :arm_rate_limit, N)` enables the ARM-wide
  fixed-window 429 + `Retry-After` (default `:infinity` keeps responses
  byte-identical); `:cosmos_ru_limit`, `:sb_shared_key`, `:auth_mode`, and
  port keys work the same way.
- **Ownership gate.** Before attach probes run, the harness proves it owns
  the substrate (anonymous ARM answers 200; a foreign enforce-mode substrate
  answering 401 forces a re-boot) — the R177b marker-identity guard from the
  lifted conftest.

## how-to-run

The external suites landed (2026-10-19) but their `just` recipes are still
RETIRED exit-1 placeholders pending rewiring (V261019-08 / V261019-09), so
the working entry points today are the direct commands:

```
node verification/ts/run-all.mjs   # TS suite: wf1..wf4 on one shared
                                   # v-block substrate, wf5 on a private
                                   # throttle-profile substrate
bash verification/py/run.sh        # PY suite: substrate-ctl up (block v1,
                                   # enforce) -> venv ensure -> pytest
```

Both derive endpoints from the `SMALT_*` env contract; `run-all.mjs` needs
`NODE_EXTRA_CA_CERTS` at `.smalt/tls/ca-cert.pem` (set inside the harness).
Exit codes per the exit-code-contract above; `run.sh` adds exit 4 (wf5
loud typed skip on the infinite-limit substrate). Other entry points are
`just` recipes (root `Justfile` + `justfile.d/*.just`; `just --list`).
Post-reset ladder:

```
just doctor            # preflight: deps, ports, certs, toolchain
just up / down         # canonical-port substrate lifecycle
just status / logs     # report-only substrate + receipt status

just sdk-ts            # RETIRED exit-1 placeholder (successor: run-all.mjs)
just sdk-py            # RETIRED exit-1 placeholder (successor: run.sh)
just sdk-all           # honestly red while members are retired

just test-offline      # residual tier: mix test test/internal/
just tf-plan-smoke     # terraform fixture plan smoke
just invariant-gates   # fail-closed invariant gates
just mutation-court    # prove gates are non-vacuous
just sleep-gate        # zero-sleep gate (fail-closed, TS+PY scopes)
just court             # full 11-stage admission court
just bootstrap         # zero-to-green first run
```

First-time setup: `just bootstrap` (prereqs, deps, compile, certs via
`scripts/gen_dev_cert.sh`, doctor, boot smoke). TS runs need
`NODE_EXTRA_CA_CERTS` pointing at `.smalt/tls/ca-cert.pem` (the recipes set
this); Python probes run in `verification/py` with azure deps declared as
the pyproject optional-extra.

## the-surface-enum-vocabulary

SDK coverage status is a closed enum compiled mechanically by
`scripts/sdk_coverage.py` into `docs/jira/v*/SDK_MATRIX.md`:

- **GREEN (PASS)** — probe passed with zero failing checks. Divergences
  already registered against the surface may still be cited.
- **REGISTERED-DIVERGENCE** — the probe surfaced a real deviation from
  Azure's wire contract, and a KD row exists in the window's
  `KNOWN_DIVERGENCES.md` citing the witness receipt on disk
  (`docs/jira/*/receipts/*.md`). A divergence without a KD row is not
  registered.
- **MISSING** — no probe, no receipt, or a KD row names a receipt that is
  not on disk. MISSING is a finding: the gate exits 1. `UNREGISTERED-GAP`
  (FAIL-token with no KD citation) is also a finding.

Workflow-to-surface mapping lives in `verification/workflows.json` (20
inventory ids from `scripts/sdk_coverage.py`, 5 workflows, zero orphans);
per-assertion receipt tags follow the grammar
`<surface>:<op>[@lang][#KD-xx][=VERDICT]` documented there.

Gate rule (`scripts/sdk_coverage.py`): exit 0 = every cell pass-or-registered;
exit 1 = any MISSING cell or UNREGISTERED-GAP. Findings are surfaced, not
hidden. The KD citation requirement keeps the enum honest: a cell is green or
registered only because a specific file proves it, and the citation is
re-checked on every compile.
