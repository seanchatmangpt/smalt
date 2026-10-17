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
    # Front door.
    check README.md
    exit $rc
