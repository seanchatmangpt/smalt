# DoD-3 Receipt — CLI wiring (lane 03-cli-wiring)

Date: 2026-10-15 · Owner: DoD-3 · Repo /Users/sac/smalt · Branch main @ 3fc2543
Files owned/edited: `justfile.d/03-cli-wiring.just` (rewritten),
`smalt-cli/smalt_cli/cli.py` (registration edits only).

## What landed

1. **hw sub-app registered** (`smalt-cli/smalt_cli/cli.py`): scaffold `hw`
   command retired; `app.add_typer(hw_app, name="hw")` from
   `smalt_cli/hw/cli.py` (conditional on typer availability). Witnessed:
   `python -m smalt_cli.cli hw --help` shows discover/enroll/sign/flash.
2. **gate sub-app registered**: documented one-liner applied —
   `app.add_typer(gate_app(), name="gate", ...)`. Typer refuses a command and
   a group with the same name, so the scaffold `gate (verb, url)` command was
   retired. Witnessed: `gate --help` shows sdk-wire-conformance /
   hil-attestation / zero-actuation / audit-integrity.
3. **`justfile.d/03-cli-wiring.just`** (all witnessed green):
   `cli-test` · `cli-gates` · `cli-gate1/2/3/4` · `cli-daemon` · `cli-smoke`.
   GATE1 reconciliation: gates.py has NO env seam (SUITE_GLOBS hardcoded), so
   cli-gate1 calls `run_gate1(ROOT, targets=[tests/test_*.py])` directly and
   satisfies ADR-PY-002 per-lane venv resolution via `.venvs/<lane>`
   symlinks → `.venv-cli` (created idempotently by the recipe).
4. **Missing SDKs installed into `.venv-cli`** (pre-existing venv gap,
   collection-error class): azure-servicebus, azure-eventhub, azure-keyvault.

## Witnessed runs (real outputs)

- `cli-test` (final, anonymous substrate 39643/39644):
  **tests/ 24 passed, 5 skipped, 4 failed**; **smalt_cli/ 101 passed**.
  - The 24 passes include CLI-4 blob 6/6, cosmos 5/5, resourcegraph 3/3,
    keyvault 4/4, resourcegraph graph lanes — over real wire + SDK clients.
  - 4 failures are all `tests/test_identity.py` authn-rejection tests
    (tokenless/tampered/wrong-secret/expired → expect 401, got 200): the
    CLI-4 conftest substrate (anonymous test mode) cannot satisfy them, while
    an enforce-mode substrate breaks blob/cosmos raw unauthenticated PUTs.
    **CLI-4's own lanes require mutually exclusive substrate auth modes on
    the shared 39643 substrate** — cross-lane finding, not wiring.
  - sk Technical note: cli-test aborts after tests/ failure (set -e), so the
    101/101 smalt_cli/ figure is witnessed from a separate invocation
    (`just ... cli-test` segments + direct `.venv/bin/python -m pytest smalt_cli/`
    = 101 passed in 7.86s, witnessed twice).
- `cli-gates` (twice, identical standings): **GATE1 SKIP-LOUD** (gates.py
  SUITE_GLOBS still mismatched to the landed tests/ layout — by design,
  gates.py not mine to edit; use `cli-gate1` for the real-layout GATE1),
  **GATE2 SKIP-LOUD** (see stale-reason finding), **GATE3 PASS** (PUT and
  DELETE both typed-403, ledger entries, zero upstream mutation, rg_count
  3→3), **GATE4 PASS** (manifest intact, 17 records, coverage_ok).
- `cli-gate1` (real-layout GATE1 over all 7 tests/ files, .venv-cli
  interpreters, no venv-fallback notes): identity 6/6 PASS, keyvault 4/4
  PASS, resourcegraph 3/3 PASS, eventhub 1 SKIP-loud (no substrate), blob
  6 FAIL, cosmos 9 errors, servicebus 600s timeout — **gate verdict FAIL**
  (blob/cosmos/servicebus are CLI-4/CLI-5 lane scope; that run also hit the
  shared-substrate state pollution / cli5-lock contention windows; keyvault
  and identity passed under the enforce-mode substrate).
- `cli-daemon`: boots, `POST /rpc {"method":"ledger.tail","params":{"n":1}}`
  → `{"result":{"intact":true,"tailHash":"GENESIS",...}}` over loopback.
- `cli-smoke`: `--help` + `hw discover` (real pyserial enumeration) +
  `gate audit-integrity` (PASS) — all green.

## Cross-lane findings (not acted on — outside ownership)

1. **CLI-4 substrate auth-mode conflict**: identity lane needs
   `:auth_mode, :enforce` (+ sts_signing_secret); blob raw-PUT lanes need
   anonymous. One shared 39643 substrate cannot serve both. Suggest per-lane
   ports (the CLI-5 files already do this) or conftest-driven boot.
2. **GATE2's exact_command contract is stale vs the landed hw lane**:
   gates.py runs `hw sign --device <PORT>`, but `hw/cli.py` sign takes a
   positional port (typer refuses `--device` → SKIP-LOUD "not landed"). hw
   IS registered now; gates.py or hw/cli.py needs flag reconciliation.
3. **gates.py SUITE_GLOBS mismatch**: default `run_gates.py` GATE1 stays
   SKIP because discovery patterns never match the landed `tests/test_*.py`
   layout. cli-gate1 bridges it without editing gates.py; a gates.py owner
   may fold the same targets in later.
4. **Substrate lock hygiene**: CLI-5 files boot substrates at import time
   under /tmp/smalt-substrate-cli5.lock with 120s waits — under the v26.10.14
   fan-out this collides across lanes (measured ~5 min lock queues, several
   SUBSTRATE_LOCK_TIMEOUT collection errors this session).

## Environment note

Concurrent DoD lanes were landing/editing the same tests/ files mid-session
(observed transient SyntaxError / NameError at collection, self-healing).
Substrate boots used the run.sh/BOOT_HINT protocol under
/tmp/smalt-substrate.lock; my substrate was left running on 39643/39644 at
receipt time (kill line: `pkill -f "arm_port, 39643"`).
