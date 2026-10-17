# how-to-run-wire-parity

Run the opt-in external tier: real `terraform` against the smalt emulator's
ARM/TLS surfaces, to prove wire parity with the real azurerm provider. The
default tier is the in-process native engine (`just test-native`, see
[how-to-develop-native.md](how-to-develop-native.md)); the wire tier is
explicit opt-in.

## Prerequisites

- `terraform` on PATH (the probes loud-skip with exit 3 if absent — never a
  fake pass).
- `mix deps.get` done (substrate boot needs deps).
- Dev TLS material present: `bash scripts/gen_dev_cert.sh` (idempotent).

## Step 1: trust for the TLS twin (pick ONE path)

azurerm authenticates against the 9444-class TLS twin; the azurerm provider
validates the dev leaf cert. Two supported paths:

### Path A: zero-touch trust shim (default, non-interactive)

The per-resource probe (`scripts/tf_plan_check.sh`) and the cleanroom ladder
(`scripts/tf_cleanroom.sh`) build and inject the trust shim automatically on
darwin:

- `scripts/trust_shim/build.sh` compiles `smalt_trust_shim.dylib` (gitignored,
  source committed) — a loopback-only dylib that interposes Security.framework
  cert evaluation with a fingerprint-pinned leaf (`SMALT_LEAF_SHA256`).
- The probe exports `DYLD_INSERT_LIBRARIES` for the terraform stages only.
- Keychain status is INFORMATIONAL — never mutated, never a gate.

### Path B: persistent keychain trust (interactive)

If you want terraform to work without the shim (e.g. your own tf invocations):

```bash
just trust-status                                        # machine JSON gate
bash scripts/tf_trust_setup.sh trust                     # interactive: SecurityAgent dialog
```

- `trust` imports + trusts `.smalt/tls/ca-cert.pem` (idempotent).
- A fingerprint mismatch (keychain holds a dead CA after a local re-mint)
  routes to `retrust`; `untrust` removes everything.
- If the SecurityAgent dialog is dismissed, the script loud-fails and prints
  (never runs) the sudo System-keychain fallback.

## Step 2: run the tiers

### T2 mix wire tier

```bash
just test-wire        # mix test test/wire
```

### Per-resource terraform probe (six fixtures)

```bash
bash scripts/tf_plan_check.sh # add --write-receipt to land
  docs/jira/v26.10.16/sdk-results/tf-plan.md
```

Runs terraform init + plan + apply + post-apply plan per fixture against a
lane-private substrate (ARM 39330, TLS 39331, data 39332, amqp/ehub/mcp
39333-39335). Fixtures: `test/terraform_fixture_per_resource/` — rg, storage,
keyvault, servicebus, eventhub, cosmos (six `.tf` files, plus `versions.tf`
which is skipped by name).

Verdicts per fixture: PASS (`N to add` + apply OK + post-apply `No changes`),
DIVERGENCE (typed — azurerm's own error names the divergent ARM shape),
FAIL (untyped), SKIP (no terraform). Exit codes: 0 all PASS/DIVERGENCE / 1 any
FAIL / 2 substrate never up / 3 SKIP. DIVERGENCE cells are registered
findings, not hidden failures. Per-fixture logs persist in `/tmp/tf-plan-probe.*`
(clean up manually).

### T5 cleanroom ladder (opt-in, gated)

```bash
just cleanroom         # scripts/tf_cleanroom.sh
```

Nine stages on lane ports 39390-39395: fresh zero-state substrate, trust gate,
init/apply, `plan -detailed-exitcode` must be 0 ("No changes"), data-plane
read-your-write audit, console leg, destroy, residue audit (ETS identity gate),
timed receipt. Exit 0 / 1 / 3 (loud skip).

### Tier routing through `apply`/`destroy`

`just apply tier=wire` and `just destroy tier=wire` delegate to the cleanroom
ladder after a trust-gate check; without a trusted-machine PASS they refuse
with `REFUSED[TIER-WIRE-UNAVAILABLE]` (exit 3). Default tier is `native`.

## KD-78 note (monotonic api-version admission)

`Microsoft.Resources/resourceGroups` is pinned to `2023-07-01` in
`lib/smalt/registry.ex` (azurerm sends 2023-07-01; the old exact-string check
400'd every apply — that was KD-78). The ARM router now admits MONOTONICALLY:
any api-version <= the registry latest is admitted, malformed versions are
never admitted. Fence: `mix test test/apiversion_matrix_test.exs` (200 tests).
KD-78's canonical register row may still read OPEN pending `kd_flip.py` —
the code fence is the landed truth; see `docs/jira/v26.10.16/WRAP_LEDGER.md`.

## Fastest end-to-end recipe

```bash
terraform -install-autocomplete 2>/dev/null || true   # ensure on PATH first
just test-wire
bash scripts/tf_plan_check.sh --write-receipt
```

See Also: [how-to-develop-native.md](how-to-develop-native.md) ·
[how-to-debug-agent.md](how-to-debug-agent.md)
