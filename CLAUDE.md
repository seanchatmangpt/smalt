# smalt

Pure-Elixir, BEAM-native local cloud-edge emulator: ARM-style control plane
on 9443, TLS twin 9444, data plane 8443, AMQP Service Bus 5672, Event Hubs
5673, MCP tool surface 9545. Point SDKs/CLIs at loopback, no cloud needed.

## Agents

Never dispatch the built-in generic agents (`general-purpose`, `claude`).
Only use agents defined in `.claude/agents/` (bench-runner, kd-registrar,
milestone-doc, shim-court-author, substrate-op) plus read-only Explore.
Subagent prompts always carry the absolute repo path (this repo's root).

## Commands

```bash
just doctor        # preflight: deps/ports/certs/toolchain (~2s)
just status        # beams, listening ports, latest receipts (report-only)
just up / down     # boot/stop substrate (up is FOREGROUND; PID in /tmp/smalt.pid)
just substrate-up / substrate-down / substrate-status   # flock-managed, lane-safe (scripts/substrate.sh)
just court         # full admission court: doctor + test tiers + tf smoke + bench-check + mutation-court + census + invariant-gates + naming-sweep
just court-x2      # two-green release receipt gate (~8 min)
just verify-all    # offline stages: doctor, test-offline, ws-court, cli pytest, naming-sweep, invariant-gates, test-stress, test-budget, sleep-gate
just publish-dry   # publish gates dry-run (tarball leak greps, ERROR_CODES identity)
just receipts      # recent court/bench receipts
just shim-courts   # shim-court anti-vacuity mutations
just invariant-gates  # 6 fail-closed gates (cosmos-etag-cas, appconfig-etag-cas, blob-worm, ledger-chain, queue-capacity, lock-clamp)
just logs          # tail newest tmp/*.log
just bootstrap     # zero-to-green first-run (deps, certs, doctor, boot smoke)
```

Substrate management goes through `scripts/substrate.sh` (lock manager);
start it with the lock fd closed (`9>&-`) so beams don't inherit the flock.
`just up` writes `/tmp/smalt.pid` and is a global collision point — for
concurrent lanes always use `substrate-up/down` (state in
`/tmp/smalt-substrate-state/`; `substrate.sh` never reads `/tmp/smalt.pid`).
Never pattern-pkill beams — use `scripts/port_sweep.sh` (dry-run default,
`-y` to kill). SDK smoke: RETIRED with the v26.10.19 reset (test/sdk-smoke deleted at
64f6099) — successor verification/ts SDK probes (V261019-08, not landed);
`just sdk-ts` / `sdk-ts-court` exit 1 loudly until then.

### Test ladder

```bash
mix test                        # offline suite: self-boots app on EPHEMERAL ports, no external substrate needed
mix test --include amqp_wire    # wire tier is excluded by default (:amqp_wire tag)
scripts/fast_test.sh test/internal/vm_zero_growth_test.exs[:LINE] [--watch]  # per-hash private build root (_build-ft-<hash>; suites live in test/internal/)
just sdk-ts / sdk-census / sdk-py / sdk-all   # real-Azure-SDK probes; exit 0 pass / 1 fail / 2 substrate down / 3 SKIP
just ws-lint / ws-build / ws-court / ws-converge   # Next.js workspace gates
just cli-test                   # smalt-cli pytest (two venvs)
just test-stress                # :stress tier (expensive bodies, excluded from plain mix test; mix test --include stress)
just test-budget                # per-test timing budget gate (seed once via test-budget-seed)
just sleep-gate                 # no-sleep doctrine gate (fail-closed); non-vacuity: just sleep-gate-court
```

Exit-code contract for self-booting harnesses (e2e, sdk-*): 0 pass / 1 test
fail / 2 substrate never up / 3 harness-skip (SKIP is loud, never a fake
pass).

### Env setup

```bash
eval "$(just relay-env)"     # SMALT_*/AZURE_* endpoints, TLS paths, SDK cheat sheet
eval "$(scripts/dev_env.sh)" # per-host SAS key (base64(sha256(host+"smalt-dev-sb"))), SSL_CERT_FILE
scripts/gen_dev_cert.sh      # .smalt/tls/ CA + leaf (Apple needs CA:TRUE anchor + CA:FALSE leaf)
bash scripts/bootstrap.sh    # fresh machine: 8 idempotent stages, exit 2 prints brew installs
```

Auth modes: `:enforce` (default; HS256 Bearer from emulator STS
`POST /{tenant}/oauth2/v2.0/token`, any client_id/secret accepted) vs
`:anonymous` (test only). Real Azure SDKs refuse Bearer over http — SDK legs
ride the 9444 TLS twin with `NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem`.

## Layout

- `lib/smalt/` — data_plane (blob/cosmos/kv/arm), messaging/amqp,
  egress_router, mcp (gen/ templates → generated/)
- `workspace/` — Next.js 16 Sovereign Console (air-gapped, zero-egress).
  Networking ONLY through `lib/smalt.ts` (`smaltFetch`, `assertLocalUrl`);
  ESLint bans raw `fetch` literals + http clients. Tests =
  `workspace/scripts/e2e-court.mjs`
  (`just ws-court`), no jest/vitest.
- `smalt-cli/` — Python CLI + probe tests (two venvs: `.venv`, `.venv-cli`)
- `gates/` — invariant gates with negative-fixture non-vacuity contracts
  (verdict must REFUSE mutated observations; a gate that can't exit 1 is the failure)
- `docs/jira/v26.10.14/` — closed milestone (the pattern exemplar);
  active window per `docs/jira/` newest dir. KD register
  (`KNOWN_DIVERGENCES.md`), `receipts/`, `bench/`, `_LANES.md`
- `scripts/` — bench lanes, `shim_court/`, `substrate.sh`, `kd_flip.py`,
  `naming_sweep.sh`
- `justfile.d/` — per-concern just modules (NN-*.just), imported by root
  justfile (concurrent lanes add modules, never edit the root)

## Generated artifacts (never hand-edit)

| File | Regenerate |
|---|---|
| `docs/ERROR_CODES.md` | `just gen-error-codes` (drift-fenced: `--check`) |
| `docs/jira/v*/RECEIPTS.md`, `receipts/INDEX.md` | `just receipt-index` |
| `docs/jira/v*/BENCH_RESULTS.md` | `just bench-report` |
| `docs/jira/v*/SDK_MATRIX.md` | `just sdk-matrix-md` (fails on MISSING/UNREGISTERED-GAP) |
| `lib/smalt/mcp/generated/mcp_descriptor.ex` | ggen_igniter.sync from `lib/smalt/mcp/gen/smalt_mcp_surface.ttl` |
| `lib/smalt/registry.ex` | `mix smalt.gen` (byte-identical replay test-fenced) |
| `lib/smalt/config.ex`, `lib/smalt/store_tables.ex`, `lib/smalt/cascade_edges.ex`, `lib/smalt/telemetry/semconv/registry.ex` | `mix smalt.gen` (byte-identical replay test-fenced; semconv from
`lib/smalt/telemetry/semconv/model/smalt.yaml`) |
| `docs/capabilities.json`, `docs/THIRD_PARTY.md` | `mix run -e 'Smalt.Projection.Canonical.write()'` (Canonical.write riders) |

## Conventions

- **Corpus premise pins (v26.10.17 lessons, receipts r239/r240 chain)**: KV
  corpus clients must perform the KD-15 challenge handshake (send tokenless,
  take the 401 + `WWW-Authenticate`, resend bearer) or the legacy-SKR
  fallthrough — tokenless-only clients are premise rot. Api-version refusal
  pins use a FUTURE version (`2099-01-01`), never a past one (KD-78 monotonic
  admission admits anything ≤ latest). Every witness receipt carries
  `Context: solo|pair|slice|full`
  (`docs/jira/v26.10.17/RECEIPT_CONTEXT_LAW.md`; `receipt_index.py`
  flags **NO-CONTEXT**). Court precondition: `just quiet-check` before any
  court; `just quiesce` when the machine was busy (both court-x2 attempts
  failed cold run 1, passed warm run 2). Helpers: `just leak-court`,
  `just rewitness <KD-nn>`, `just kd-stale`, `just wt-scratch <sha>`,
  `just corpus-soak <n>`.
- **KD register**: divergences get a `KD-nn` row in `KNOWN_DIVERGENCES.md`
  (surface, divergence, evidence receipt, close condition). A shim landed
  in `lib/` carries `# KD-COVERS: KD-nn`. Flip rows only via
  `scripts/kd_flip.py --apply`, gated on witness receipt mtime > shim mtime.
  The census prose count can lag the table — the table is ground truth.
- **Shim courts**: `scripts/shim_court/<name>_court.sh` — BASELINE →
  BEFORE → SHIM (marker `SHIM-COURT` mandatory) → AFTER (the flip IS the
  non-vacuity proof) → RESTORE (sha256 byte-exact, fail-closed). `just
  shim-court <name>` / `just shim-courts`. Exit 0/1/3; a skip is loud.
- **Bench lanes**: `a*` adversarial / `b*` SDK surface / `c*` cross+chaos /
  `n*` Next.js lifecycle. Port law: lane bN → `39000+10N..+5`. Script uses
  underscore, result jsonl uses hyphen. Source `scripts/bench/lib.sh`
  (`bench_boot`/`bench_emit`); lanes write ONLY their own result file.
  `flood_autocannon.mjs` is a load harness, not a lane — never emits jsonl.
- **GAP tokens**: `GAP(name)` in `docs/WIRE_PARITY.md` names an OPEN gap and
  disappears when it closes. Flip is receipt-gated: no receipt, no flip.
  Do not mint new GAP tokens unilaterally.
- **Receipts**: markdown receipts in `docs/jira/v*/receipts/` carry a
  standing line (ALIVE/PARTIAL_ALIVE/PASS/SUSPECT…); `receipt_index.py`
  flags any receipt with no embedded command output as SUSPECT. JSON
  receipts in `tmp/` are scratch, not indexed.
- **Commits**: `git commit -F <file>`, never inline `-m`.
- **Lane builds**: `MIX_BUILD_ROOT=_build-lane<N>`; coordinator deletes all
  lane build roots at integration before the final commit (`just lane-clean`
  reclaims orphans; backlog measured 2026-10-16: 168 roots holding ~88 GiB).
- **No stash** in shared checkouts — snapshot via
  `git show HEAD:path > /tmp/...`.
- **Wire-compat pinions (do not "clean up")**: SASL ANONYMOUS only;
  sasl-outcome descriptor 0x44; attach top-level <=14 with locale fields
  omitted (source=8/target=7 composite arity tripwires);
  .NET-GUID lock-token byte reordering; EH fixed partitions `["0","1"]`.
  Each was pinned by a real-SDK census — changes regress real handshakes.
- **Docs**: milestone artifacts live under `docs/jira/v<version>/`; final
  wrap sequence is WOs → receipts → GAP → court-x2 → commits → publish-dry
  → FINAL.md/RECEIPTS.md. Docs DoD gate: `just docs-dod-check` (every
  receipt path named in docs must exist).
- **Planes**: `SMALT_PLANES` (comma list) or `config :smalt, :planes`
  boots a subset of `control,data,integration,identity` (`:all` default,
  byte-identical); unknown names refuse boot `{:invalid_plane, name}`
  (`lib/smalt/planes.ex`). Plane-profile SDK interop: `just azsim-sdk`
  (RETIRED: test/sdk-full/azb20 deleted at 64f6099; verification/ts successor pending, V261019-08).
- **Stress tier**: the `:stress` tag excludes expensive test bodies from
  plain `mix test`; `just test-stress` runs them, population-fenced by
  population fence RETIRED with the 64f6099 reset (test/stress_tier_census_test.exs deleted); `just test-stress` re-runs stress bodies only after the residual tier re-authors them (bounds table `docs/STRESS/BOUNDS.md`).
- **Budget gate**: `just test-budget` fail-closed-checks per-test timings
  against the seeded manifest (`just test-budget-seed`; regressions,
  renamed/deleted tests, unbudgeted new tests all exit 1;
  `scripts/test_budget_gate.py`).
- **No-sleep doctrine**: `Process.sleep` is not acceptable test or production
  methodology — tests poll observables via `SmaltTest.AssertEventually`
  (or a `# SLEEP-CLASS:` annotated exception); `lib/` sleeps only as
  SCHEDULING (`send_after`) — readiness is monitors/GenServer/
  `handle_continue`. Enforced by `just sleep-gate` (fail-closed) +
  `just sleep-gate-court` (non-vacuity). See `docs/NO_SLEEP_DOCTRINE.md`.
- **Ratchet mod**: `mods/ratchet` enforces the 20-agent invariant + ticket
  DAG (timer-dispatched prompts, court-gated DONE, PreToolUse deny gate);
  panel + `/ratchet` commands. See `mods/ratchet/README.md`.
- **HAVE supervisory engine**: L1 fleet-saturation guard + state ledger
  (`scripts/have/`); `just have:*` recipes (`justfile.d/31-have.just`),
  telemetry catalog, and crontab templates in
  `docs/reference/have-runbook.md`. Ledger: `tmp/have/` (gitignored).
