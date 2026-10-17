#!/usr/bin/env bash
# stage_atomic_commits.sh — per-family atomic commit staging (Q-4, for F-7).
#
# Partitions the dirty tree into 5 families and stages+commits each one
# atomically. Msgfiles are pre-written to /tmp/stage-msgs/.
#
# Contract:
#  - each family: git add <paths> && git commit -F <msgfile>
#  - verify per-family staging with `git diff --cached --stat` before commit
#  - untracked files classified explicitly, never silently swept
#  - --dry-run prints the plan and exits
#  - REFUSES to run if `git status --porcelain` shows files matching NO family
#
# Usage: scripts/stage_atomic_commits.sh [--dry-run]

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

MSGS=/tmp/stage-msgs

# ---------------------------------------------------------------------------
# Family membership lives in classify() below (first match wins). The
# pathspec arrays that used to duplicate it here were unread and deleted.
# ---------------------------------------------------------------------------

FAMILIES=(bench shims errc enclave-native-tf planning receipts gates audit repo tools)

classify() { # echo family for a path
  local p="$1"
  case "$p" in
    docs/jira/v26.10.14/bench/*|scripts/bench/*|docs/jira/v26.10.14/BENCH_RESULTS.md|\
    scripts/stress/*|scripts/wave_telemetry.sh|justfile.d/15-bench.just|justfile.d/19-wave-telemetry.just|\
    scripts/bench.py) echo bench ;;
    lib/smalt/messaging/amqp/connection.ex|lib/smalt/messaging/amqp/management_rpc.ex|\
    lib/smalt/auth/bearer.ex|lib/smalt/auth/sas.ex|lib/smalt/egress_router.ex|\
    lib/smalt/data_plane/blob_storage.ex|\
    lib/smalt/data_plane/cosmos.ex|lib/smalt/hw/*|lib/smalt/substrate_identity.ex|\
    lib/smalt/application.ex|lib/smalt/data_plane/blob_service.ex|lib/smalt/messaging/amqp/cbs_router.ex|\
    lib/smalt/*) echo shims ;; # lib/ repair shims + security surface (default for lib/)
    scripts/shim_court/*|test/amqp/*|test/data_plane/*|test/wire/*|test/compliance/*|\
    test/chaos/*|test/egress_dispatch_test.exs|test/smalt_egress_router_test.exs|\
    test/egress_wiring_test.exs|test/wire/egress_wire_test.exs|test/auth_enforce_test.exs|\
    test/apiversion_matrix_test.exs|\
    test/azapi_actions_test.exs|test/property/*|test/smalt_hw_virtual_serial_test.exs|\
    test/smalt/*|test/smalt/hw_test.exs|\
    test/sdk-smoke/eventhubs.test.cjs|test/sdk-smoke/sb-extra.probe.cjs|\
    justfile.d/18-shim-court.just|proxy/*) echo shims ;;
    mix.exs|mix.lock|smalt-cli/*|test/sdk-full/package.json|test/sdk-full/package-lock.json|\
    Justfile|justfile.d/04-sdk-recipes.just|justfile.d/06-lane-cleanup.just|\
    justfile.d/10-gap-register-sync.just|justfile.d/20-sobelow.just|\
    scripts/naming_sweep.sh|scripts/sdk_coverage.py|scripts/kd_flip.py|\
    scripts/stage_atomic_commits.sh|workspace/*) echo errc ;;
    scripts/tf_*.sh|scripts/tf_h1_dirhash.py|scripts/trust_shim/*|\
    scripts/enclave_native.sh|scripts/nfr3_rss_gate.py|scripts/spc_gate.py|\
    config/bands.yaml|scripts/pf_redirect.sh|scripts/hosts_alias.sh|\
    scripts/bootstrap_env.sh|scripts/test_freeze_gate.sh|test/trust_shim_probe/*|\
    lib/smalt/spc/*|lib/mix/*) echo enclave-native-tf ;;
    docker/*) echo enclave-native-tf ;;
    priv/wasm/*|scripts/affidavit_wasm_build.sh|lib/smalt/affidavit/*|\
    lib/smalt/fin_ops/*|lib/smalt/telemetry/affidavit_ocel.ex) echo enclave-native-tf ;;
    scripts/mint_release_receipt.py) echo tools ;;
    docs/jira/v26.10.16/receipts/*) echo receipts ;; # receipts/ subdir wins over planning
    docs/jira/v26.10.15/*|docs/jira/v26.10.16/*) echo planning ;;
    gates/*) echo gates ;;
    docs/audit/*|docs/CENSUS.md) echo audit ;;
    CLAUDE.md|.gitignore|CHANGELOG.md|NOTICE.md|ggen_igniter.pack.lock|justfile.d/*|popcorn_demo/*) echo repo ;;
    scripts/court_x2.sh|scripts/doctor.py|scripts/port_sweep.sh|scripts/receipt_index.py|\
    scripts/substrate.sh|scripts/dev_env.sh|scripts/gen_dev_cert.sh|scripts/gen_error_codes.py|\
    scripts/mutation_court.py|scripts/fast_test.sh|scripts/audit_surface_census.sh|\
    scripts/verify_all.sh|scripts/sb_census_replay.sh|scripts/dev_watch.sh|\
    scripts/smalt-tf) echo tools ;;
    priv/shacl/*) echo gates ;;
    docs/jira/v26.10.14/receipts/*|docs/jira/v26.10.14/sdk-results/*|\
    docs/jira/v26.10.14/RECEIPTS.md|docs/jira/v26.10.14/FINAL.md|\
    docs/jira/v26.10.14/KNOWN_DIVERGENCES.md|docs/jira/v26.10.14/SDK_MATRIX.md|\
    docs/jira/v26.10.14/ws/*|.ggen_igniter/*|\
    docs/WIRE_PARITY.md|docs/KNOWN_DIVERGENCES.md|docs/SDK_MATRIX.md|docs/STRESS/*|\
    README.md|\
    docs/how-to/dev-loop.md|docs/README.md|docs/CHANGELOG.md|docs/ERROR_CODES.md|\
    docs/PACK_INTEGRATION.md|docs/*|test/*) echo receipts ;;
    *) echo UNMATCHED ;;
  esac
}

# ---------------------------------------------------------------------------
# Build the partition
# ---------------------------------------------------------------------------
declare -a FILES_BENCH=() FILES_SHIMS=() FILES_ERRC=() FILES_ENCLAVE_NATIVE_TF=() FILES_PLANNING=() FILES_RECEIPTS=() \
  FILES_GATES=() FILES_AUDIT=() FILES_REPO=() FILES_TOOLS=()
UNMATCHED=()

while IFS= read -r raw; do
  [[ -z "$raw" ]] && continue
  p="${raw:3}"                       # strip XY prefix
  p="${p%% -> *}"                    # keep original side of renames
  f="$(classify "$p")"
  case "$f" in
    bench)    FILES_BENCH+=("$p") ;;
    shims)    FILES_SHIMS+=("$p") ;;
    errc)     FILES_ERRC+=("$p") ;;
    enclave-native-tf) FILES_ENCLAVE_NATIVE_TF+=("$p") ;;
    planning) FILES_PLANNING+=("$p") ;;
    receipts) FILES_RECEIPTS+=("$p") ;;
    gates)    FILES_GATES+=("$p") ;;
    audit)    FILES_AUDIT+=("$p") ;;
    repo)     FILES_REPO+=("$p") ;;
    tools)    FILES_TOOLS+=("$p") ;;
    *)        UNMATCHED+=("$p") ;;
  esac
done < <(git status --porcelain)

# ---------------------------------------------------------------------------
# Refuse loudly on unmatched files
# ---------------------------------------------------------------------------
if (( ${#UNMATCHED[@]} )); then
  echo "REFUSED: ${#UNMATCHED[@]} dirty file(s) match NO family:" >&2
  printf '  %s\n' "${UNMATCHED[@]}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Commit messages
# ---------------------------------------------------------------------------
write_msgs() {
  cat > "$MSGS/bench" <<'EOF'
bench(v26.10.14): benchmark suite, harness and results

docs/jira/v26.10.14/bench/, scripts/bench/, BENCH_RESULTS.md.
EOF
  cat > "$MSGS/shims" <<'EOF'
feat(shims): wire-normalization + shim-court surface (connection, mgmt RPC, bearer, egress, blob storage, cosmos, hw)

lib/ shims, scripts/shim_court/, and their dedicated test surfaces
(broker facade, cosmos, egress dispatch, auth enforce, apiversion matrix,
azapi actions, property tests, EH smoke + sb-extra probe).
EOF
  cat > "$MSGS/errc" <<'EOF'
chore(errc): pyjwt/hypothesis deps + refactors

mix.exs, mix.lock, smalt-cli/, test/sdk-full/package(.lock).json,
Justfile + justfile.d recipe updates, scripts tooling, workspace property files.
EOF
  cat > "$MSGS/enclave-native-tf" <<'EOF'
feat(enclave-native-tf): enclave-native terraform lane (tf scripts, trust shim, SPC/NFR3 gates, bands config)

scripts/tf_*, scripts/trust_shim/, scripts/enclave_native.sh,
scripts/nfr3_rss_gate.py, scripts/spc_gate.py, config/bands.yaml,
scripts/pf_redirect.sh, scripts/hosts_alias.sh, scripts/bootstrap_env.sh,
scripts/test_freeze_gate.sh, test/trust_shim_probe/, lib/smalt/spc/, lib/mix/.
EOF
  cat > "$MSGS/planning" <<'EOF'
docs(planning): v26.10.15 work orders (wholesale)

docs/jira/v26.10.15/.
EOF
  cat > "$MSGS/receipts" <<'EOF'
docs(receipts): v26.10.14 receipts, wire parity, divergences, SDK matrix, stress docs, test stragglers

docs/jira/v26.10.14/receipts/ + sdk-results/ + RECEIPTS.md + FINAL.md,
docs/ (WIRE_PARITY, KNOWN_DIVERGENCES, SDK_MATRIX, STRESS, DEV_LOOP,
README, CHANGELOG, ERROR_CODES, PACK_INTEGRATION), test/test_helper.exs,
test/canonical_projection_test.exs, remaining test/ stragglers.
EOF
  cat > "$MSGS/gates" <<'EOF'
chore(gates): invariant gate updates (fail-closed negative fixtures)
EOF
  cat > "$MSGS/audit" <<'EOF'
docs(audit): audit-surface findings + census
EOF
  cat > "$MSGS/repo" <<'EOF'
chore(repo): repo config (CLAUDE.md, .gitignore, ggen pack lock, justfile.d modules)
EOF
  cat > "$MSGS/tools" <<'EOF'
chore(tools): substrate/doctor/court/receipt tooling
EOF
}
# SHIM-COURT: msgfile writes are side effects — skip entirely under --dry-run
# so a dry run mutates nothing on disk (not even /tmp/stage-msgs).
if (( ! DRY_RUN )); then
  write_msgs
fi

# ---------------------------------------------------------------------------
# Plan / execute
# ---------------------------------------------------------------------------
commit_family() {
  local name="$1"; shift
  local -a files=("$@")
  (( ${#files[@]} )) || { echo "[$name] no files, skipping"; return 0; }
  echo "=== [$name] ${#files[@]} file(s) ==="
  printf '  %s\n' "${files[@]}"

  if (( DRY_RUN )); then
    echo "[$name] DRY-RUN: would git add ${#files[@]} path(s), verify --cached --stat, commit -F $MSGS/$name"
    return 0
  fi

  # Skip paths that no longer exist on disk (deleted/renamed files are already
  # staged in the index from the git mv; git add on a vanished pathspec is fatal)
  local existing=()
  local p
  for p in "${files[@]}"; do
    [[ -e "$p" || -L "$p" ]] && existing+=("$p")
  done
  (( ${#existing[@]} > 0 )) || return 0
  git add -- "${existing[@]}"
  echo "--- staged stat ---"
  git diff --cached --stat
  local staged
  staged="$(git diff --cached --name-only | wc -l | tr -d ' ')"
  (( staged > 0 )) || { echo "[$name] nothing staged after add, aborting"; exit 1; }
  git commit -F "$MSGS/$name"
  echo "[$name] committed"
}

echo "Partition (classified from git status --porcelain):"
for fam in "${FAMILIES[@]}"; do
  var="FILES_$(echo "$fam" | tr - _ | tr '[:lower:]' '[:upper:]')"
  echo "  $fam: ${#var} -> $(eval "echo \${#$var[@]}") file(s)"
done
echo

commit_family bench "${FILES_BENCH[@]}"
commit_family shims "${FILES_SHIMS[@]}"
commit_family errc "${FILES_ERRC[@]}"
commit_family enclave-native-tf "${FILES_ENCLAVE_NATIVE_TF[@]}"
commit_family planning "${FILES_PLANNING[@]}"
commit_family receipts "${FILES_RECEIPTS[@]}"
commit_family gates "${FILES_GATES[@]}"
commit_family audit "${FILES_AUDIT[@]}"
commit_family repo "${FILES_REPO[@]}"
commit_family tools "${FILES_TOOLS[@]}"

if (( DRY_RUN )); then
  echo
  echo "DRY-RUN complete — no commits made. F-7 may execute without --dry-run."
else
  echo
  echo "All families committed. Remaining dirty files (should be empty):"
  git status --porcelain
fi
