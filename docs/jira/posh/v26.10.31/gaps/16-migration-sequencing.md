# Migration Sequencing — v26.10.31 unification-dialect migration (lane 16)

Lane 16 of 17, unification-dialect migration. BLOCKING. Reads:
`00-unification-dialect-decision.md` (additive path, laws 1-4), gaps/01 (STS lane
verdict: STS wire face stays byte-identical in smalt as dialect #0), and the
outputs of lanes 2-15 as they land. This file sequences the whole migration; every
phase is fenced by the BYTE-IDENTITY GUARD.

## Byte-Identity Guard (runs at EVERY phase)

The azurerm swap surface is the single load-bearing invariant: consumer config
(this repo `infra/`), the vendored Go provider, and `dev_overrides` against the
smalt ARM plane. After every phase:

    # 1. Harness gates (consumer side, /Users/sac/cai/courtroom-platform-az;
    #    MUST run from apps/web — vitest.harness.config.ts lives there)
    cd apps/web && npx vitest run --config vitest.harness.config.ts \
      test/harness/tenant test/harness/version
    # expect exit 0

    # 2. Terraform 0-drift plan (consumer side)
    terraform -chdir=infra/environments/dev/platform plan -detailed-exitcode -lock=false \
      -var-file=dev.tfvars
    # expect exit code 0 (0 = no drift, 2 = drift = phase FAIL, 1 = error = phase FAIL)

    # 3. smalt-side wire witness (dialect #0 + #1 mint/plan legs, smalt checkout)
    bash /Users/sac/smalt/scripts/tf_cleanroom.sh
    tf_cleanroom STS POST legs (the `POST /{tenant}/oauth2/v2.0/token` legs, currently
    lines 300 and 536 of tf_cleanroom.sh) must pass; sha256 of
    lib/smalt/arm_gateway/plug/oidc_sts.ex + lib/smalt/identity/oidc_idp.ex
    (exact paths; tf_cleanroom.sh preflight pins their sha256s and stage 8b
    re-checks them within the run) unchanged across the phase.

Input lane closure rule: a phase whose input lanes are still open (gap file
status != closed) cannot pass its exit gate — the phase is BLOCKED, not failed;
sequence does not skip ahead.

## P0 — Baseline freeze (current green set recorded)

- **Entry**: harness suites green on main today; tf_cleanroom STS + plan legs pass.
- **Consumes**: nothing (records the present).
- **Actions**: run the full guard; record hashes of `oidc_sts.ex`, `oidc_idp.ex`,
  Go provider binary, `~/.terraformrc` dev_overrides block, and plan exit code 0
  into `receipts/p0-baseline-freeze.md` (this repo) and referenced here.
- **Exit gate**: all three guard legs pass, hashes recorded.
- **Rollback**: nothing to roll back (read-only phase; no mutation).

## P1 — smalt-core.ttl above existing families (M13 phase-1)

- **Entry**: P0 receipt exists; lane 13 (smalt-core.ttl) output closed; lane 1
  CC-1 (dialect #0 registration via regen, no hand-edit) closed.
- **Consumes**: lane 13 (core ttl), lane 1 (STS reclassification via regen).
- **Actions**: land `smalt-core.ttl` ABOVE the existing registry families
  (containerApps, kv, storage, decision record names them; also messaging, RBAC,
  identity), with core classes derived FROM those families — a reclassification
  layer, not a rewrite. Registry stays generated (regen receipt, never hand-edit,
  law 2).
- **Exit gate**: guard (all three legs) + the admission-corpus court: replay a
  frozen corpus of admission decisions (the v26.10.30 witness set) against the
  core-above-families registry and diff verdicts pre/post P1; empty diff closes
  the phase. Any verdict flip = phase FAIL (M13 phase-1 definition of done).
- **Rollback**: delete `smalt-core.ttl` + regen (single-file revert; registry is
  generated, so rollback is regen from the pre-P1 graph).

## P2 — core/dialect pin split (M12) + credential model spec (M9, spec-only)

- **Core/dialect pin split (M12)**: registry pins currently bind core semantics to
  dialect vocabulary in one pin set. Split into: core pins (vendor-neutral IRIs,
  versions pinned in smalt-core.ttl space) and dialect pins (Azure vocabulary,
  pinned in the dialect layer). The ARM face + STS face wires do not move.
- **Credential model spec (M9)**: per gaps/01 CC-3, spec-only — `smalt-core.ttl`
  principal/credential classes (principal = oid/sub/appid, credential = minted
  token + authority + TTL, roles = core authorization roles) — ttl + regen receipt;
  no runtime behavior change. STS claims set maps onto the core classes 1:1.
  posh never mints (CC-4 grep court over posh tree stays zero-hit).
  The M9 spec-only fence: ttl + regen receipt only; no runtime change permitted
  in P2 (runtime use is P3+; spec without runtime use = zero drift by
  construction, but the guard still runs).
- **Consumes**: P1 closed; lane 12 (pin split) closed; lane 9 (credential model)
  closed at spec level.
- **Exit gate**: guard (all three legs) + admission-corpus replay diff empty.
  CC-4 grep court: `grep -r "JWT\|sign\|StsKey" posh/` zero mint-capable hits.
  Verify this at each phase: any hit = REFUSED.
- **Rollback**: regen from the pre-P2 graph (core pins + dialect pins reunified
  in one rollback regen); single-file revert of the ttl diff.

## P3 — dialect #2 (Stripe or Datadog)

- **Pick criteria (first-real-consumer)**: the dialect whose consumer lands first
  on the charter consumer list with a real work order. Stripe if the billing
  consumer work order is admitted first; Datadog if the observability consumer is.
  Not by best-architecture argument — by first admitted work order.
- **Entry**: P2 closed; a real consumer work order admitted (charter consumer
  list); lane 9 credential model spec sufficient for a non-Azure principal model
  (per gaps/01: core classes named before first non-Azure dialect).
- **Consumes**: lane 9 (credential spec), lane 13 (core classes), the P2 pin
  split — dialect #2 maps INTO core classes, proving the core is genuinely
  vendor-neutral (the core's falsifier).
- **First shim**: posh dialect package projecting into core classes — never
  smalt. smalt never grows a per-vendor face (law 1). The shim is disposable
  (law 4: posh stays stateless).
- **Exit gate**: guard (all three legs) + new-dialect court: the dialect #2 shim
  projects into core IRIs (not Azure vocabulary) — a court asserting a dialect #2
  resource resolves to core IRIs and NOT Azure IRIs resolves. Guard must still be
  0-drift (dialect #2 touches the core's consumers, not the ARM wire).
  Guard rerun after landing; 0-drift proves dialect #2 touched no wire-proven
  surface.
- **Rollback**: delete the posh dialect package (disposable shim, law 4). smalt
  tree untouched by construction; guard re-run to witness 0-drift after delete.

P4 — (conditional, deferred): ARM-face inversion evaluation — evaluation only,
no landing without an admitted work order. Entry: P3 closed. Consumers: decision
record additive path last step. Gate: guard + a written evaluation against law 1
(smalt never grows a per-vendor face — already satisfied by reclassification;
inversion is a posh-port of the dialect #1 wire face and must keep tf_cleanroom
legs passing throughout any landing, with the guard at every step, rollback =
smalt tree revert to pre-inversion SHA). No landing without an admitted work
order; no landing in v26.10.31.

## Cross-references

- Lane 2 output (`gaps/02-*.md`, azurerm swap / consumer-config surface): the
  consumer config + Go provider + dev_overrides surface this doc's guard runs
  against.
- Lane 9 output (`gaps/09-*.md`, expected `09-credential-model.md`): M9 spec
  consumed at P2 entry; CC-3 mapping court is its close condition.
- Lane 12 output (`gaps/12-*.md` exact name lands with the lane; expected
  `12-core-dialect-pin-split.md`): M12 pin split consumed at P2 entry.
- Lane 13 output (`gaps/13-*.md`, expected `13-smalt-core.md`): M13 phase-1 core
  ttl consumed at P1 entry; admission-corpus court is its close condition.
- Lane 1 (gaps/01, closed): dialect #0 classification, CC-1..CC-4 close
  conditions folded into P1/P2 gates above.

## Status line

- P0: PARTIAL — guard rerun 2026-10-30 (second run, wave-2 gap lane): leg 1 ALIVE
  (harness vitest exit 0, 8/8, from apps/web per corrected command); leg 2 BLOCKED (unchanged —
  `terraform init -reconfigure` decision pending, NOT run this session); leg 3 preflight SKIP
  REMOVED (tf_cleanroom preflight re-pinned from the deleted
  `test/smalt_ets_baseline_identity_test.exs` (64f6099) to direct STS-face sha256 pins of
  `lib/smalt/arm_gateway/plug/oidc_sts.ex` + `lib/smalt/identity/oidc_idp.ex`, re-checked at
  stage 8b); the ladder now advances through stage 2 then FAILS typed at stage 3 terraform plan
  (provider azurerm x509 "unknown authority" — pre-existing since v26.10.16 BLOCKED-TRUST, out
  of lane lease); STS mint legs exercised directly: HTTP 200 Bearer from the pinned face.
  Receipt: `docs/jira/v26.10.31/receipts/m16-byte-identity-guard-run.md` (second-run section).
  Pins confirmed unchanged: oidc_sts.ex `20867639…`, oidc_idp.ex `8fc6ad22…`.
  Note: bare `mix` on PATH must be the asdf shims (Homebrew 1.19.5 is refused by the pin).
- P1-P3: UNVERIFIED (inputs open)
- P4: UNSUPPORTED (no admitted work order; deferred by the decision record)
- Byte-Identity Guard: PARTIAL (second run 2026-10-30: leg 1 green from apps/web; leg 2
  BLOCKED pending terraform-init decision; leg 3 preflight-green, typed FAIL at stage 3 on the
  pre-existing darwin provider-trust blocker; remaining actions in the receipt's
  "Guard-runnability findings").
- Falsifier / non-vacuity: ALIVE — tamper probe re-proven on the second run
  (`20867639…` → `b1e01b73…`, PIN-CHECK FAIL). The guard can go red.
- Lane 16 file itself: **ALIVE** (status rows updated this session from the guard run).