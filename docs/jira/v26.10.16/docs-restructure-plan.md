# Docs Restructure Plan — Diátaxis Mapping (design lane, v26.10.16)

Status: PLAN (design + inventory; no md moved in this lane).
Scope: every tracked `.md` outside `_build/`, `node_modules/`, `.git/`, `deps/`,
`.venv*/`, `.pytest_cache/`, `tmp/` (scratch, never docs surface), and
`docs/jira/**` (milestone windows are receipts, NOT docs-site content).
`.claude/agents/*.md` and `.claude/skills/*/SKILL.md` are harness config,
not docs-site content — out of scope.

## 1. Target tree

```
docs/
  tutorials/        # learning-oriented, one guaranteed-success path
    first-enclave-walkthrough.md      (NEW — from test/enclave-testbed/README.md prose)
  how-to/
    dev-loop.md                       (from docs/DEV_LOOP.md)
    dev-env-bootstrap.md              (from docs/DEV_ENV.md)
    first-run.md                      (from docs/FIRST_RUN.md)
    migration-from-emulators.md       (from docs/MIGRATION_FROM_EMULATORS.md)
    terraform-trust.md                (from docs/TERRAFORM_TRUST.md)
    publish-check.md                  (from docs/PUBLISH_CHECK.md)
    docker-packaging.md               (from docker/README.md)
    bench-lanes.md                    (from scripts/bench/REGISTRY.md)
    shim-courts.md                    (from scripts/shim_court/README.md)
    trust-shim.md                     (from scripts/trust_shim/README.md)
  reference/
    just-reference.md                 (from docs/JUST_REFERENCE.md + justfile.d/* recipes)
    error-codes.md                    (from docs/ERROR_CODES.md — GENERATED, regen retarget)
    error-codes-generator.md          (from docs/ERROR_CODES_GENERATOR.md)
    wire-parity.md                    (from docs/WIRE_PARITY.md)
    known-divergences.md              (from docs/jira/v26.10.14/KNOWN_DIVERGENCES.md — promoted copy)
    census.md                         (from docs/CENSUS.md)
    benchmarks.md                     (from docs/BENCHMARKS.md)
    capabilities.json-adjacent: capabilities.md   (new reference from docs/capabilities.json)
    third-party.md                    (from docs/THIRD_PARTY.md)
    cli-command-reference.md          (from cli/docs/command-reference.md)
    cli-schema-admitted.md            (from cli/docs/SCHEMA_ADMITTED.md)
    cli-gates.md                      (from smalt-cli/GATES.md — promoted copy; original stays)
    compliance/                       (docs/compliance/C1..C7, unchanged relative layout)
  explanation/
    architecture.md                   (from docs/ARCHITECTURE.md)
    test-isolation.md                 (from docs/TEST_ISOLATION.md)
    semantic-projection.md            (from docs/SEMANTIC_PROJECTION.md)
    wire-compat-pinions.md            (extracted "do not clean up" pinions from CLAUDE.md/plan)
    pack-integration/                 (docs/PACK_INTEGRATION/*.md, 16 files, unchanged layout)
    prior-art.md                      (from docs/XAAS_PRIOR_ART.md)
  archive/
    release-notes-v26.10.14.md        (from docs/RELEASE_NOTES_v26.10.14.md)
    quickstart-receipt.md             (from docs/QUICKSTART_RECEIPT.md)
    cleanup-final.md                  (from docs/CLEANUP_FINAL.md)
    cheat-scan.md                     (from docs/CHEAT_SCAN.md)
    dep-audit-v26.10.14.md            (from docs/DEP_AUDIT.md)
    naming-sweep.md                   (from docs/NAMING_SWEEP.md)
    auth-regression-sweep.md          (from docs/auth_regression_sweep.md)
    error-sweep.md                    (from docs/ERROR_SWEEP.md)
    sdk-surface-parity-audit.md       (from docs/audit/ whole tree)
    stress/                           (docs/STRESS/ whole tree — dated stress receipts)
    xaas-prior-art-transfer-plan.md   (from docs/XAAS_PRIOR_ART.md — superseded transfer plan)
  jira/                               # KEEP-IN-PLACE, untouched
```

## 2. Per-file disposition table

Dispositions: MOVE (git mv, minimal header fix), REWRITE (new file absorbing
prose from source), ARCHIVE (git mv to docs/archive/), KEEP (stays put),
GENERATED (regen retarget, never hand-move).

### Root

| File | Disposition | Target |
|---|---|---|
| README.md | REWRITE | README.md (front door: golden path `just doctor → apply → verify → destroy`; native tier primary, wire tier (SDK/TLS/AMQP) opt-in section; links into all four quadrants + archive) |
| CHANGELOG.md | KEEP | — (generated-adjacent, in-place) |
| CLAUDE.md | KEEP | — (harness config) |
| NOTICE.md | KEEP | — (legal) |
| docs/jira/** | KEEP | — (receipts) |
| .claude/** md | KEEP | — (harness config, out of scope) |
| .pytest_cache/README.md, .venv/... LICENSE.md | EXCLUDE | untracked/cached junk, not docs surface |

### docs/ top level

| File | Disposition | Target | Quadrant |
|---|---|---|---|
| docs/DEV_LOOP.md | MOVE→REWRITE | docs/how-to/dev-loop.md | how-to |

| docs/DEV_ENV.md | MOVE | docs/how-to/dev-env-bootstrap.md | how-to |
| docs/FIRST_RUN.md | MOVE | docs/how-to/first-run.md | how-to |
| docs/MIGRATION_FROM_EMULATORS.md | MOVE | docs/how-to/migration-from-emulators.md | how-to |
| docs/TERRAFORM_TRUST.md | MOVE | docs/how-to/terraform-trust.md | how-to |
| docs/PUBLISH_CHECK.md | MOVE | docs/how-to/publish-check.md | how-to |
| docs/JUST_REFERENCE.md | MOVE | docs/reference/just-reference.md | reference |
| docs/ERROR_CODES.md | GENERATED | docs/reference/error-codes.md (retarget `just gen-error-codes` output path + drift-fence path) | reference |
| docs/ERROR_CODES_GENERATOR.md | MOVE | docs/reference/error-codes-generator.md | reference |
| docs/WIRE_PARITY.md | MOVE | docs/reference/wire-parity.md | reference |
| docs/CENSUS.md | MOVE | docs/reference/census.md | reference |
| docs/BENCHMARKS.md | MOVE | docs/reference/benchmarks.md | reference |
| docs/THIRD_PARTY.md | MOVE | docs/reference/third-party.md | reference |
| docs/ARCHITECTURE.md | MOVE | docs/explanation/architecture.md | explanation |
| docs/TEST_ISOLATION.md | MOVE | docs/explanation/test-isolation.md | explanation |
| docs/SEMANTIC_PROJECTION.md | MOVE | docs/explanation/semantic-projection.md | explanation |
| docs/XAAS_PRIOR_ART.md | ARCHIVE | docs/archive/xaas-prior-art.md | archive |
| docs/QUICKSTART_RECEIPT.md | ARCHIVE | docs/archive/quickstart-receipt.md | archive |
| docs/CLEANUP_FINAL.md | ARCHIVE | docs/archive/cleanup-final.md | each is a dated receipt-in-prose |
| docs/CHEAT_SCAN.md | ARCHIVE | docs/archive/cheat-scan.md | |
| docs/DEP_AUDIT.md | ARCHIVE | docs/archive/dep-audit-v26.10.14.md | |
| docs/NAMING_SWEEP.md | ARCHIVE | docs/archive/naming-sweep.md | |
| docs/auth_regression_sweep.md | ARCHIVE | docs/archive/auth-regression-sweep.md | |
| docs/ERROR_SWEEP.md | ARCHIVE | docs/archive/error-sweep.md | self-labeled "Receipt, not a living contract" |
| docs/RELEASE_NOTES_v26.10.14.md | ARCHIVE | docs/archive/release-notes-v26.10.14.md | old-window release notes |
| docs/RELEASE_NOTES_v26.10.16.md | KEEP (temp) | stays until v26.10.16 closes, then archive per window-rotation law | — |
| docs/capabilities.json | KEEP | — (not md; machine-readable) |

### docs/ subtrees

| Tree | Disposition | Target | Quadrant |
|---|---|---|---|
| docs/compliance/C1..C7 (7 files) | MOVE | docs/reference/compliance/ (layout unchanged) | reference |
| docs/PACK_INTEGRATION/ (16 md) | MOVE | docs/explanation/pack-integration/ | explanation |
| docs/audit/ (SDK_SURFACE_PARITY_AUDIT.md + sections/aud1..4) | ARCHIVE | docs/archive/audit/ | dated audit receipts |
| docs/STRESS/ (17 md) | ARCHIVE | docs/archive/stress/ | dated stress run receipts |

### Component docs — KEEP-IN-PLACE

Component front doors stay beside their code (moving them breaks the
"README lives next to the thing" convention and 5 of the 9 docs-dod pins):

| File | Disposition | Role |
|---|---|---|
| workspace/README.md, workspace/ARCHITECTURE | KEEP | component front door / explanation symlink-target |
| smalt-cli/README.md, smalt-cli/GATES.md | KEEP | component front door / reference copy stays |
| smalt-cli/smalt_cli/ledger/README.md | KEEP | module readme |
| cli/docs/command-reference.md, cli/docs/SCHEMA_ADMITTED.md | KEEP (promote-copy into docs/reference/) | original stays with the CLI code |
| docker/README.md | KEEP (promote-copy how-to into docs/how-to/docker-packaging.md) | original stays beside Dockerfile |
| proxy/README.md | KEEP | scaffold readme stays with scaffold |
| scripts/bench/REGISTRY.md | KEEP (promote-copy how-to into docs/how-to/bench-lanes.md) | original stays beside lib.sh |
| scripts/shim_court/README.md | KEEP (promote-copy into docs/how-to/shim-courts.md) | original stays beside lib.sh |
| scripts/trust_shim/README.md | KEEP (promote-copy into docs/how-to/trust-shim.md) | original stays beside code |
| test/enclave-testbed/README.md | KEEP (source prose for the new tutorial) | pinned by docs-dod-check |
| test/e2e/s1_iac_chain/README.md | KEEP | scenario readme |
| test/mutation_court/README.md | KEEP | scenario readme |
| test/fixtures/runtime_contracts/ggen/ROTATION-NOTE.md, cli/.ggen-v2/ROTATION-NOTE.md | KEEP | rotation notes stay with subject |
| test/redteam/r1..r3 findings.md | KEEP | raw findings stay with court |
| test/sdk-python/README.md | KEEP | harness readme |
| test/terraform_fixture/README.md | KEEP | fixture readme (strip the stale troubleshooting-log appendix into docs/archive/ if still present — task names it; verify before cut) |
| docker/BUILD_RECEIPT.md | ARCHIVE-CANDIDATE | dated receipt-in-prose; move to docs/archive/ at cut time |

### NEW files

| File | Quadrant | Source prose |
|---|---|---|
| docs/tutorials/first-enclave-walkthrough.md | tutorial | test/enclave-testbed/README.md + FIRST_RUN + DEV_ENV bootstrap stages, sequenced as guaranteed-success path with checkpoints |
| docs/explanation/wire-compat-pinions.md | explanation | CLAUDE.md "Wire-compat pinions" section + WIRE_PARITY status vocabulary |

## 3. docs-dod-check impact (justfile.d/12-docs-dod.just)

Current 9 pins and post-restructure status:

| # | Pinned path | Post-restructure |
|---|---|---|
| 1 | docs/jira/v26.10.14/receipts/ws-12-e2e.md | UNCHANGED — jira receipts never move |
| 2 | docs/jira/v26.10.14/receipts/cli-08-gates.md | UNCHANGED |
| 3 | docs/jira/v26.10.14/receipts/08-servicebus-census.md | UNCHANGED |
| 4 | docs/jira/v26.10.14/receipts/12-gate-closure.md | UNCHANGED |
| 5 | workspace/README.md | UNCHANGED — component docs keep-in-place |
| 6 | workspace/ARCHITECTURE.md | UNCHANGED |
| 7 | smalt-cli/README.md | UNCHANGED |
| 8 | smalt-cli/GATES.md | UNCHANGED |
| 9 | test/enclave-testbed/README.md | UNCHANGED |

All 9 pins survive the restructure unchanged because (a) jira receipts stay in
their window and (b) component front doors stay beside their code. The
restructure does NOT break the gate. Recommended additions (separate lane,
receipt-gated at cut time):

```just
    # Diátaxis tree (v26.10.16 docs restructure).
    check docs/tutorials/first-enclave-walkthrough.md
    check docs/how-to/dev-loop.md
    check docs/reference/just-reference.md
    check docs/reference/error-codes.md
    check 5 more: docs/explanation/architecture.md, docs/reference/wire-parity.md,
        docs/explanation/test-isolation.md, docs/how-to/first-run.md,
        docs/archive/README.md
```

One casualty to fix at cut time: ERROR_CODES.md moves from
`docs/ERROR_CODES.md` to `docs/reference/error-codes.md` — that path is named
in CLAUDE.md (generated-artifacts table), the root Justfile / justfile.d
recipes (`gen-error-codes`, `publish-dry` tarball leak grep), and
`scripts/gen_error_codes.py` defaults. Re-pin all of those in the same commit
that retargets the generator; `just docs-dod-check` itself does not pin it.

## 3.1. Generated-artifact retargets (coordinator checklist, not this lane)

- `docs/ERROR_CODES.md` → `docs/reference/error-codes.md`: update
  `scripts/gen_error_codes.py` default output, `justfile.d` `gen-error-codes`
  + `--check` fence path, CLAUDE.md table row, `publish-dry` ERROR_CODES
  identity grep. Same-commit retarget or the drift fence fails.
- `docs/WIRE_PARITY.md` move: named in CLAUDE.md GAP-token convention and
  `justfile.d/10-gap-register-sync.just` — re-pin in same commit.
- RECEIPTS.md/INDEX.md/BENCH_RESULTS.md/SDK_MATRIX.md are per-window under
  `docs/jira/v*/` — unaffected.

## 3.2. Link/re-pin sweep list (mechanical, at cut time)

Paths named in user-facing docs that must be re-pointed in the same commit:
README.md (rewrite lands with moves), CLAUDE.md generated-artifacts table +
Conventions (WIRE_PARITY path), justfile.d/10-gap-register-sync.just,
justfile.d/12-docs-dod.just (additions above), docs/jira/v26.10.14/FINAL.md
(do NOT edit — closed window; leave stale links as historical record),
CHANGELOG.md links.

## 4. Content map for writers

| New file | Feed from |
|---|---|
| README.md (front door) | Current README + FIRST_RUN; golden path `just doctor → just apply → just verify → just destroy` (recipes confirmed: Justfile:20 `doctor`, justfile.d/22-native.just:491 `apply`, :537 `verify`, :512 `destroy` — native tier default, `tier="wire"` opt-in) |
| docs/tutorials/first-enclave-walkthrough.md | test/enclave-testbed/README.md prose + DEV_ENV bootstrap stages + FIRST_RUN |
| docs/how-to/dev-loop.md | DEV_LOOP.md as-is (already how-to register) |
| docs/how-to/first-run.md | FIRST_RUN.md as-is |
| docs/how-to/dev-env-bootstrap.md | DEV_ENV.md + scripts/bootstrap.sh stage list |
| docs/how-to/migration-from-emulators.md | MIGRATION_FROM_EMULATORS.md as-is |
| how-to/terraform-trust.md | TERRAFORM_TRUST.md as-is |
| how-to/docker-packaging.md | docker/README.md prose |
| how-to/bench-lanes.md | scripts/bench/REGISTRY.md prose |
| how-to/shim-courts.md | scripts/shim_court/README.md + CLAUDE.md shim-court conventions |
| how-to/trust-shim.md | scripts/trust_shim/README.md |
| how-to/publish-check.md | PUBLISH_CHECK.md (refresh to current window at cut) |
| reference/just-reference.md | JUST_REFERENCE.md + `just --list` full recipe table |
| reference/error-codes.md | GENERATED (retarget) |
| reference/error-codes-generator.md | ERROR_CODES_GENERATOR.md (refresh: policy receipt cite is tmp/ — rewrite cite to its jira window receipt) |
| reference/wire-parity.md | WIRE_PARITY.md as-is |
| reference/known-divergences.md | promoted copy of newest-window KNOWN_DIVERGENCES.md (regen/copy at each window rotation) |
| reference/census.md | CENSUS.md as-is |
| reference/benchmarks.md | BENCHMARKS.md |
| reference/third-party.md | THIRD_PARTY.md |
| reference/compliance/* | docs/compliance/C1..C7 as-is |
| explanation/architecture.md | ARCHITECTURE.md as-is |
| explanation/test-isolation.md | TEST_ISOLATION.md as-is |
| explanation/semantic-projection.md | SEMANTIC_PROJECTION.md |
| explanation/wire-compat-pinions.md | CLAUDE.md pinions + WIRE_PARITY vocabulary |
| explanation/pack-integration/* | PACK_INTEGRATION/ 16 files as-is |
| explanation/prior-art.md | XAAS_PRIOR_ART.md — rewrite: strip transfer-plan register, keep the prior-art survey prose |
| archive/README.md | NEW: 3-line README stating archive scope + "no receipt = no flip" does not apply here |

## Notes

- Moves are `git mv` + header/line-length normalization only; content rewrites
  land per the content map in a later wave.
- `docs/RELEASE_NOTES_v26.10.16.md` archives at window close per the standing
  window-rotation law; not moved mid-window.
- Excluded from scope: `tmp/**` (scratch, never indexed), `.venv*/**`,
  `.pytest_cache/**`, `.claude/**` (harness), `docs/jira/**` (receipts).
