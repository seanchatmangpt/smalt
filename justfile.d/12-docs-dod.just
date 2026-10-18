# 12-docs-dod — DoD lane module (owned by its lane; see docs/jira/v26.10.14)
# Docs definition-of-done: every receipt path named in user-facing docs
# (README, DEV_LOOP, CHANGELOG Unreleased) must exist on disk.

DOCS_ROOT := parent_directory(justfile_directory())

@docs-dod-check:
    #!/usr/bin/env bash
    set -euo pipefail
    # DOCS_ROOT is unreliable: under `import`, justfile_directory() is the
    # repo root so parent_directory() overshoots; under `just -f
    # justfile.d/...` it is justfile.d. Anchor on the git toplevel of the
    # actual working directory, falling back to a downward search from
    # DOCS_ROOT.
    root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
    if [ -z "$root" ]; then
        probe="{{DOCS_ROOT}}"
        while [ "$probe" != "/" ] && [ ! -e "$probe/docs/jira" ]; do
            probe="$(dirname "$probe")"
        done
        root="$probe"
    fi
    rc=0
    check() {
        if [ -e "$root/$1" ]; then
            echo "OK    $1"
        else
            echo "MISS  $1"
            rc=1
        fi
    }
    # Receipts cited by README/DEV_LOOP/CHANGELOG (v26.10.14 fan-out).
    check docs/jira/v26.10.14/receipts/ws-12-e2e.md
    check docs/jira/v26.10.14/receipts/cli-08-gates.md
    check docs/jira/v26.10.14/receipts/08-servicebus-census.md
    check docs/jira/v26.10.14/receipts/12-gate-closure.md
    # Surfaces the docs name.
    check workspace/README.md
    check workspace/ARCHITECTURE.md
    check smalt-cli/README.md
    check smalt-cli/GATES.md
    check test/enclave-testbed/README.md
    # Diátaxis tree (v26.10.16 docs restructure, docs/jira/v26.10.16/
    # docs-restructure-plan.md). Pinned to the landed set.
    check docs/tutorials/enclave-lifecycle.md
    check docs/how-to/dev-loop.md
    check docs/how-to/how-to-clean.md
    check docs/how-to/how-to-debug-agent.md
    check docs/how-to/how-to-develop-native.md
    check docs/how-to/how-to-run-wire-parity.md
    check docs/reference/just-recipes.md
    check docs/explanation/architecture.md
    check docs/explanation/cascade-teardown.md
    check docs/explanation/semantic-kernel-roadmap.md
    check docs/explanation/two-tier-enclave.md
    check docs/explanation/zero-drift-model.md
    check docs/archive/README.md
    check docs/how-to/how-to-verify-pqc-seals.md
    check docs/reference/reference-affidavit-wasm.md
    check docs/reference/kd-register.md
    check docs/reference/ports-and-planes.md
    check docs/reference/arm-gateway.md
    check docs/reference/ets-tables.md
    check docs/explanation/affidavit-evidentiary-design.md
    check docs/WIRE_PARITY.md
    check docs/TERRAFORM_TRUST.md
    # Receipts cited by the v26.10.16 user-facing docs (CHANGELOG 26.10.16,
    # docs/RELEASE_NOTES_v26.10.16.md).
    check docs/jira/v26.10.14/receipts/dod-07-court-x2.md
    check docs/jira/v26.10.14/receipts/2026-10-15-kd53-eh-batch-witness.md
    check docs/jira/v26.10.16/receipts/INDEX.md
    check docs/jira/v26.10.16/receipts/r141-eh-batch-body-discriminator.md
    check docs/jira/v26.10.16/receipts/cap-ingestion-functor.md
    check docs/jira/v26.10.16/receipts/r178e-census-replay-repair.md
    check docs/jira/v26.10.16/receipts/r119-r123-arm-list-store-reseed.md
    check docs/jira/v26.10.16/receipts/r200a-kd70-delivery-annotations.md
    check docs/jira/v26.10.16/receipts/r200b-kd71-xopt-props.md
    check docs/jira/v26.10.16/receipts/r200d-kd68-selector-impl.md
    check docs/jira/v26.10.16/receipts/r200f-kd46-mgmt-surface.md
    check docs/jira/v26.10.16/receipts/r200h-kd76-pk-witness-repair.md
    # Milestone wrap artifacts the docs name.
    check docs/jira/v26.10.16/FINAL.md
    check docs/jira/v26.10.16/RECEIPTS.md
    check docs/jira/v26.10.16/WRAP_LEDGER.md
    check docs/jira/v26.10.16/PUBLISH_RECORD.md
    check docs/jira/v26.10.16/KNOWN_DIVERGENCES.md
    check docs/RELEASE_NOTES_v26.10.16.md
    # v26.10.17 active window (gate closed TYPED-RED, r241: no wrap artifacts
    # FINAL.md/WRAP_LEDGER.md yet — version stays 26.10.16; receipts ledger exists).
    check docs/jira/v26.10.17/receipts/r241-court-x2-attempt3-typed-red.md
    check docs/jira/v26.10.17/RECEIPTS.md
    # Front door.
    check README.md
    exit $rc
