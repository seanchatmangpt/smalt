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
# run the corpus N times, gate on flake rate. Exits 1 if any round fails.
@corpus-soak N="3":
    #!/usr/bin/env bash
    set -euo pipefail
    n="{{N}}"
    for i in $(seq 1 "$n"); do
      echo "[CORPUS-SOAK] round $i/$n"
      MIX_BUILD_ROOT=_build-soak mix test test/compliance_test.exs 2>&1 | tail -1
    done
    rm -rf _build-soak
    echo "[CORPUS-SOAK] $n rounds done — any failure line above is a flake witness"
