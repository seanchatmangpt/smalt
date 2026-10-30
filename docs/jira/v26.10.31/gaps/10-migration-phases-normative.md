# Migration Phases — Normative Charter (v26.10.31, consolidation lane 10)

Promoted from M16 (`/Users/sac/smalt/docs/jira/posh/v26.10.31/gaps/16-migration-sequencing.md`)
into a normative charter. Consolidation lane 10 of 15. BLOCKING.

## Normative-path corrections (vs M16, verified on disk this session)

M16's guard commands contained three path errors; this charter is authoritative:

1. Harness vitest config is `apps/web/vitest.harness.config.ts` (consumer repo
   `/Users/sac/cai/courtroom-platform-az`), not repo-root `vitest.harness.config.ts`.
2. No `dev.tfvars` exists in `infra/environments/dev/platform/` (only
   `imports.tf main.tf outputs.tf secrets.tf variables.tf versions.tf`) — the
   `-var-file=dev.tfvars` flag is DROPPED from the plan leg.
3. `oidc_idp.ex` lives at `lib/smalt/identity/oidc_idp.ex`, not
   `lib/smalt/arm_gateway/plug/` (only `oidc_sts.ex` is there).
4. No `~/.terraformrc` exists on this machine (and no `.tfrc` in the consumer
   repo); the dev_overrides mechanism is documented in the consumer README
   (`README.md:114-123`, attribute-form-only under Terraform 1.14). The P0
   hash target is therefore the consumer README's documented override
   mechanism where it materially lives — the smalt provider binary plus the
   `dev_overrides` attribute in whatever local TF CLI config exists at P0 run
   time; if none exists, record that absence in the P0 receipt rather than a
   hash of a nonexistent file.

Every command path below was verified to exist this session.

## Byte-Identity Guard (normative form; runs at EVERY phase)

The azurerm swap surface is the single load-bearing invariant: consumer config
(`infra/`), the vendored Go provider, and `dev_overrides` against the smalt
ARM plane. All three legs must pass or the phase FAILs (or BLOCKEDs, below).

### Leg 1 — Harness gates (consumer side)

Run from `/Users/sac/cai/courtroom-platform-az/apps/web`:

    npx vitest run --config vitest.harness.config.ts test/harness/tenant \
      test/harness/version
    # expect exit 0

### Leg 2 — Terraform 0-drift plan (consumer side)

Run from `/Users/sac/cai/courtroom-platform-az`:

    terraform -chdir=infra/environments/dev/platform plan -detailed-exitcode -lock=false
    # exit 0 = no drift (pass); 2 = drift (phase FAIL); 1 = error (phase FAIL)

### Leg 3 — smalt-side wire witness

From the smalt checkout:

    bash /Users/sac/smalt/scripts/tf_cleanroom.sh

- STS POST legs at tf_cleanroom.sh lines 291 (zero-state leg) and 527
  (residue/ETS-identity leg) must pass — both verified as real POST token
  legs on disk this session.
- sha256 of `lib/smalt/arm_gateway/plug/oidc_sts.ex` and
  `lib/smalt/identity/oidc_idp.ex` unchanged across the phase:

      shasum -a 256 /Users/sac/smalt/lib/smalt/arm_gateway/plug/oidc_sts.ex \
        /Users/sac/smalt/lib/smalt/identity/oidc_idp.ex

### Guard input-lane closure rule

A phase whose input lanes are still open (gap file status != closed) cannot
pass its exit gate — the phase is BLOCKED, not failed; sequence does not skip
ahead.

## P0 — Baseline freeze

- **Entry**: harness suites green on main; tf_cleanroom STS + plan legs pass.
- **Consumes**: nothing (records the present).
- **Actions**: run the full guard; record sha256 of `oidc_sts.ex`,
  `oidc_idp.ex`, the Go provider binary, the dev_overrides config (see
  correction 4 — hash what exists; record absence if none), and plan exit
  code 0 into
  `/Users/sac/cai/courtroom-platform-az/receipts/p0-baseline-freeze.md`.
- **P0 freeze witnesses — M10 W1–W4 spike wire-laws** (from
  `gaps/10-spike-residuals.md`, lane 10 of 17): the P0 freeze pins the Go
  provider binary, so the NEUTRAL-CORE wire laws ride the guard as frozen
  witnesses, not re-derived per phase:
  - **W1** unknown sentinel: msgpack fixext1 `D4 00 00`, never long-form
    `C7 05 00 "value"`.
  - **W2** schema type round-trip: cty JSON types round-trip exactly (no
    flattening to string, no double-wrap under `:type`).
  - **W3** diagnostics-only error channel: state-adjacent payloads and errors
    ride the proto diagnostics field; no private/tuple channels.
  - **W4** null DynamicValues: (a) null/empty msgpack DynamicValue on the
    destroy face decodes to nil state, never raises; (b) proto bytes fields
    take a single binary, never an iolist.
  W1–W4 are protocol-6/go-cty law, dialect-independent by construction; the
  frozen provider binary at P0 is the witness that they hold, and any guard
  leg failing after a phase is read first against W1–W4.
- **Exit gate**: all three guard legs pass; hashes recorded.
- **Rollback**: none (read-only phase; no mutation).

## P1 — smalt-core.ttl above existing families (M13 phase-1)

- **Entry**: P0 receipt exists (`receipts/p0-baseline-freeze.md`); lane 13
  (`gaps/13-admission-split.md`) closed; lane 1 (`gaps/01-sts-migration.md`)
  CC-1 (dialect #0 registration via regen, no hand-edit) closed.
- **Consumes**: lane 13 core ttl; lane 1 STS reclassification via regen.
- **Actions**: land `smalt-core.ttl` ABOVE the existing registry families
  (containerApps, kv, storage, messaging, RBAC, identity), core classes
  derived FROM those families — a reclassification layer, not a rewrite.
  Registry stays generated (regen receipt; never hand-edit, law 2).
- **Exit gate**: guard (all three legs) + admission-corpus court: replay the
  frozen v26.10.30 witness corpus against the core-above-families registry
  and diff verdicts pre/post P1. Empty diff closes the phase; any verdict
  flip = phase FAIL.
- **Rollback**: delete `smalt-core.ttl` + regen from the pre-P1 graph
  (single-file revert; registry is generated).

## P2 — core/dialect pin split (M12) + credential model spec (M9, spec-only)

- **Entry**: P1 closed; lane 12 (`gaps/12-compat-pin-split.md`) closed; lane 9
  (`gaps/09-credential-model.md`) closed at spec level.
- **Consumes**: P1; lane 12 pin split (CORE pins → `compat-pin-core.ttl`,
  vendor-neutral; dialect pins stay in the dialect layer); lane 9 credential
  spec (principal = oid/sub/appid; credential = minted token + authority +
  TTL; roles = core authorization roles). ARM face + STS face wires do not
  move.
- **M9 spec-only fence**: ttl + regen receipt only; no runtime behavior
  change in P2 (runtime use is P3+). Spec without runtime use = zero drift by
  construction, but the guard still runs. posh never mints (CC-4).
- **Exit gate**: guard (all three legs) + admission-corpus replay diff empty
  + CC-4 grep court:

      grep -r "JWT\|sign\|StsKey" posh/
      # zero mint-capable hits; any hit = REFUSED

- **Rollback**: regen from the pre-P2 graph (core pins + dialect pins
  reunified in one rollback regen); single-file revert of the ttl diff.

## P3 — dialect #2 (Stripe or Datadog)

- **Pick criteria (first-real-consumer)**: Stripe if the billing consumer
  work order is admitted first; Datadog if the observability consumer is.
  By first admitted work order, not best-architecture argument.
- **Entry**: P2 closed; a real consumer work order admitted (charter consumer
  list); lane 9 credential spec sufficient for a non-Azure principal model.
- **Consumes**: lane 9, lane 13, the P2 pin split — dialect #2 maps INTO core
  classes, proving the core is genuinely vendor-neutral (the core's
  falsifier).
- **First shim**: posh dialect package projecting into core classes — never
  smalt. smalt never grows a per-vendor face (law 1). The shim is disposable
  (law 4: posh stays stateless).
- **Exit gate**: guard (all three legs) + new-dialect court: dialect #2 shim
  projects into core IRIs (not Azure vocabulary); guard must still be
  0-drift — dialect #2 touches the core's consumers, not the ARM wire. Guard
  rerun after landing; 0-drift proves dialect #2 touched no wire-proven
  surface.
- **Rollback**: delete the posh dialect package (disposable shim, law 4);
  smalt tree untouched by construction; guard re-run to witness 0-drift after
  delete.

## P4 — ARM-face inversion evaluation (conditional, deferred)

- **Entry**: P3 closed.
- **Consumes**: decision record additive path last step.
- **Rule**: evaluation only, no landing without an admitted work order — any
  P4 landing without an admitted work order is **UNSUPPORTED** (typed
  refusal). No landing in v26.10.31 regardless.
- **Gate**: guard + a written evaluation against law 1 (smalt never grows a
  per-vendor face — already satisfied by reclassification; inversion is a
  posh-port of the dialect #1 wire face and must keep tf_cleanroom legs
  passing throughout any landing, guard at every step).
- **Rollback**: smalt tree revert to pre-inversion SHA.

## Status line

- P0: UNVERIFIED (guard commands written and path-verified this session, not
  executed this session).
- P1–P3: UNVERIFIED (input lanes open; lane 9 PARTIAL, lanes 12/13 open).
- P4: UNSUPPORTED (no admitted work order; deferred by the decision record).
- Byte-Identity Guard: ALIVE as a normative specification — all three legs
  path-verified on disk this session; not executed this session.
- This charter file: **ALIVE** (written this session, exit 0 from Write).
