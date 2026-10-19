# 34-nightly — nightly aggregate gate (honest exit aggregation).
#
# First failure wins in the summary exit code, but ALL stages run (set +e) so
# one red stage never hides the state of the others. test-stress is retired
# from this aggregate (loud note, not a silent drop).

# Retired from the aggregate: `just test-stress` (:stress tier). Excluded from
# nightly by decision, not omission — reintroduce only with a receipt.
nightly:
    #!/usr/bin/env bash
    set -uo pipefail
    cd "{{justfile_directory()}}"
    declare -a names=() rcs=()
    run_stage() {
      local name="$1"; shift
      local rc
      echo "== [nightly] $name =="
      "$@"
      rc=$?
      names+=("$name"); rcs+=("$rc")
      [ "$rc" -eq 0 ] && echo "== [nightly] $name PASS ==" || echo "== [nightly] $name FAIL rc=$rc =="
      return 0
    }
    overall=0
    run_stage court        just court
    run_stage sdk-ts-court just sdk-ts-court || true
    run_stage sdk-py-court just sdk-py-court || true
    run_stage soak         bash docker/burn/cgroup-soak.sh --cycles 1 || true
    echo "== [nightly] summary =="
    i=0
    for name in "${names[@]}"; do
      rc=${rcs[$i]}
      printf '  %-14s %s\n' "$name" "$( [ "$rc" -eq 0 ] && echo PASS || echo "FAIL rc=$rc" )"
      [ "$rc" -eq 0 ] || overall=$rc
      i=$((i+1))
    done
    # Retired stage (loud): test-stress NOT run here — see header comment.
    echo "[nightly] test-stress: RETIRED from aggregate (run 'just test-stress' explicitly)"
    exit $overall
