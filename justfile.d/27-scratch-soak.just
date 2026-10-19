# 27-scratch-soak — session-learned helpers (v26.10.17):
# exact-SHA read-only scratch materialization (never worktrees) + corpus
# load-condition repetition gate.

# Materialize an exact SHA into a throwaway read-only scratch dir for
# cross-SHA inspection. Doctrine-compliant (git archive, no worktree).
@wt-scratch SHA:
    #!/usr/bin/env bash
    set -euo pipefail
    sha="{{SHA}}"
    dir=$(mktemp -d "/tmp/smalt-scratch-${sha}.XXXXXX")
    git archive "$sha" | tar -x -C "$dir"
    echo "$dir"

# Load-condition repetition gate for the compliance corpus timing window:
# RETIRED — the compliance corpus was deleted at 64f6099; soak of a deleted
# subject is not runnable. LOUD no-op (exit 1) naming the deleted subject.
@corpus-soak N="3":
    #!/usr/bin/env bash
    echo "[RETIRED] corpus-soak: test/compliance_test.exs deleted at 64f6099; no successor corpus. Exit 1."
    exit 1
