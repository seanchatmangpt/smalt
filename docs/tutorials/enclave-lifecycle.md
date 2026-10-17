# enclave lifecycle tutorial

Provision a complete smalt enclave from an HCL fixture, verify it end to end, and tear it down with
  zero residue — the operator's golden path, end to end in about a minute.

By the end you will have: applied a terraform-style HCL fixture through the in-process native
  engine, watched a blob/secrets/cosmos read-your-write audit pass over real loopback HTTP, and
  destroyed everything with a fail-closed residue gate proving 17 resource-bearing tables are empty.

## What you need

- The smalt repo at `<repo>` (all commands run from there).
- Elixir toolchain (`mix`) on PATH, plus a working `erl` on PATH (the mix
  wrapper shells out to `erl`; a bare `elixir` install without OTP on PATH
  fails with `exec: erl: not found`). No terraform, no Azure, no cloud.
- The lifecycle steps below (doctor → apply → verify → destroy) run
  entirely in-process and do NOT need the SDK smoke node_modules or
  keychain trust. `scripts/bootstrap_env.sh` (Step 0) DOES check both —
  see the Step 0 note.
- Free ports 29445-29450. The native lifecycle boots its own private beam on these ports; it never
  touches the shared 9443/8443 substrate.

## The two tiers, in one paragraph

`just apply`/`just destroy`/`just verify` default to the **native tier**: smalt's own in-process
  engine parses your HCL and drives the ARM router directly, with no terraform binary involved. The
  **wire tier** (`tier=wire`) is an explicit opt-in that routes the same lifecycle through real
  external terraform (`scripts/tf_cleanroom.sh`) to validate wire parity — it is gated behind a
  trusted-machine check and prints a loud warning that it is not the native engine. For learning the
  lifecycle, stay on the native tier.

## Step 0: bootstrap the environment

```bash
bash scripts/bootstrap_env.sh
```

This wraps the 8-stage zero-to-green bootstrap (deps, certs, doctor, smoke), generates the loopback
  CA + leaf, probes trust, and reports `/etc/hosts` alias and pf-redirect status. It never mutates
  with sudo itself — if the summary shows `INACTIVE` for hosts aliases or the pf redirect, it tells
  you which `scripts/hosts_alias.sh enable` / `scripts/pf_redirect.sh enable` to run yourself. Exit
  0 means the golden path is green.

**Fresh-machine note (validated 2026-10-16):** on a machine without the
SDK smoke npm packages and without keychain trust, `bootstrap_env.sh`
exits 1 with exactly two failed stages, and BOTH are outside the native
lifecycle:

1. `[1/6] bootstrap.sh` fails in the dev-env check — `test/sdk-smoke/node_modules` has no `@azure`
  packages. Fix if you want SDK smoke: `(cd test/sdk-smoke && npm i @azure/cosmos
  @azure/event-hubs)`. Not needed for Steps 1-4.
2. `[3/6] trust-shim probe` fails (`SecTrustEvaluateWithError rejected the chain`). The printed
  remediation `bash scripts/trust_shim/build.sh` builds the shim but does NOT clear the probe — the
  probe still fails after a successful build. The real fix is macOS keychain trust of the loopback
  CA (the `ADVISORY keychain-trust` remediation printed by `just doctor`); it is optional for this
  tutorial.

The hosts-alias / pf-redirect `INACTIVE` stages are status reports, not failures. Steps 1-4 below
  pass with `bootstrap_env.sh` exiting 1 for the two stages above.

## Step 1: doctor

```bash
just doctor
```

You will see a sequence of check lines ending in an overall status. **`DEGRADED` is a fine outcome
  here.** A degraded verdict means some advisory checks (for example the trust WARN on the loopback
  CA) did not fully pass, and the doctor prints a remediation block that ends in switching the
  environment to native mode — remediation is automatic, so the lifecycle steps below work either
  way. Only a hard FAIL is a blocker; the doctor prints the exact remediation command next to it.

Prefer machine-readable output? `just doctor-json` writes `docs/jira/v26.10.16/doctor-receipt.json`.

## Step 2: apply (HCL to ETS, sub-200ms)

```bash
just apply
```

Defaults are `fixture=test/terraform_fixture tier=native`. What happens under the hood, and what you
  will see:

1. A dedicated beam boots on private ports 29445-29450 with `:anonymous` auth (this is a test/dev
  surface; the enforce-mode bearer gate would 401 the in-process router dispatches). A flock in
  `/tmp/smalt-substrate-native.lock` serializes lifecycle runs, and the lock fd is closed on spawn
  so the beam never inherits it.
2. `Smalt.Enclave.Hcl.parse/1` reads `test/terraform_fixture/main.tf` into resource terms; engine
  labels are rewritten to `type.name` and normalized to ARM types.
3. `Smalt.Enclave.Engine.apply/2` provisions through the in-process ARM router. The apply is fast —
  each resource lands in well under 200ms; total wall time is dominated by the beam boot, not the
  apply.
4. Outcomes are written to `tmp/native-enclave-state.json`.

You will see the resource outcomes printed, then the state-file path. The console (Sovereign Console
  workspace) can now browse this live enclave — the same beam the verify step later drives a console
  leg against.

## Step 3: verify (read-your-write over the real data plane)

```bash
just verify
```

`verify` requires applied state; if `tmp/native-enclave-state.json` is missing or empty it exits 3
  with `[SKIP-LOUD] verify: no applied fixture state ... run 'just apply' first` — a loud skip,
  never a fake pass. On a green run you will see, in order:

1. `state-file parity ok (N resources), zero drift` — the freshly applied outcomes match the
  recorded state and `Smalt.Enclave.State.plan` reports no drift against the store.
2. The data-plane families, each over real loopback HTTP on the private beam:
   - `[native] verify blob: arm container + blob PUT + byte-exact GET PASS`
   - `[native] verify secrets: PUT + GET read-your-write PASS`
   - `[native] verify cosmos: seed + query feed read-your-write PASS`
3. The console leg: the enclave-loop console harness (`workspace/scripts/enclave-loop.mjs`) drives
  the same live beam the way the console does, including a real STS token mint
  (`client_id=native-verify`).
4. `[native] verify data-plane: all families read-your-write PASS`

Exit 0. Any family failing is a hard exit 1 naming the family; a missing secrets surface is a loud
  SKIP, not a pass.

## Step 4: destroy (cascade, zero residue)

```bash
just destroy
```

Destroy is a cascade: `Smalt.Enclave.State.destroy/1` deletes the resource group and everything
  under it, then runs a fail-closed per-table residue audit. The store has 28 ETS tables; 11 are
  metadata (LRO history, monotonic counters, lock/session plumbing — legitimately surviving
  bookkeeping, not residue), so the audit covers the **17 resource-bearing tables** and refuses
  (non-zero exit) if any key remains in any of them. A clean run prints:

```text
[native] residue clean across 17 tables
```

## If something goes wrong

- **Doctor says DEGRADED with a trust WARN.** Expected on a fresh machine: the loopback CA is not in
  your keychain. No action needed for the native lifecycle — the doctor's remediation block handles
  it, and the native tier does not depend on keychain trust.
- **`bootstrap_env.sh` fails the trust-shim probe even after `scripts/trust_shim/build.sh`.** Known:
  the build succeeds but the probe re-run still rejects the chain. Treat this stage as optional;
  keychain trust (`sudo security add-trusted-cert ...` from the `just doctor` advisory) is what
  actually clears it.
- **`verify` exits 3 with SKIP-LOUD.** You skipped Step 2. Run `just apply` first; `verify` reads
  the state file it wrote.
- **`just apply` hangs ~10 minutes then exits 3.** Another lifecycle run holds
  `/tmp/smalt-substrate-native.lock`. Find and finish that run (or wait — the lock is released when
  its beam exits) and retry.
- **Port conflict on 29445-29450.** Something else owns the private port set. Use
  `scripts/port_sweep.sh` (dry-run default, `-y` to kill) to identify the holder.
- **Wire tier refused with `REFUSED[TIER-WIRE-UNAVAILABLE]`.** The wire tier needs a trusted-machine
  gate (`just trust-status` shows `PASS`). It is opt-in for wire-parity work; not needed for this
  tutorial.
- **Console leg fails.** Confirm the console harness exists (`workspace/scripts/enclave-loop.mjs`)
  and that the private beam is up (`just apply` first, always).

## Next steps

- Read the lifecycle internals: `lib/smalt/enclave/` (`hcl.ex`, `engine.ex`, `state.ex`) and
  `justfile.d/22-native.just`.
- Try your own fixture: `NATIVE_FIXTURE=path/to/fixture just apply` (a directory containing
  `main.tf`).
- `just audit-residue` re-runs apply + destroy + the per-table residue audit without a separate
  verify.
- Advance to the wire tier (`just apply fixture=... tier=wire`) only for wire-parity work, with the
  trust gate green.
