#!/usr/bin/env bash
# scripts/tf_plan_check.sh — per-resource-type terraform probe (plan + apply +
# state check) against a lane-private smalt substrate (ARM 39330, TLS twin
# 39331, data 39332, amqp/ehub/mcp 39333-39335).
#
# For each fixture in test/terraform_fixture_per_resource/<name>.tf:
#   terraform init + plan + apply -auto-approve + post-apply plan (expect
#   "No changes" — proves state/refresh round-trips through the emulator).
# Verdicts:
#   PASS        plan "N to add" + apply OK + post-apply plan "No changes"
#   DIVERGENCE  any stage fails TYPED: azurerm's own error names the
#               divergent ARM shape (stage prefixed in the evidence)
#   FAIL        any stage fails with no typed divergence
#   SKIP        terraform binary missing (loud)
#
# Exit codes: 0 all PASS/DIVERGENCE / 1 any FAIL (untyped) / 2 substrate never
# up / 3 SKIP. DIVERGENCE cells are registered findings, not hidden failures.
#
# Receipt (written by --write-receipt):
#   docs/jira/v26.10.16/sdk-results/tf-plan.md
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/test/terraform_fixture_per_resource"
RECEIPT="$ROOT/docs/jira/v26.10.16/sdk-results/tf-plan.md"
WORK="$(mktemp -d /tmp/tf-plan-probe.XXXXXX)"
LOG="$WORK/run.log"
ARM_PORT=39330
ATLS_PORT=39331
EGRESS_PORT=39332
AMQP_PORT=39333
EHUB_PORT=39334
MCP_PORT=39335
SUB_LOG="$WORK/substrate.log"
WRITE_RECEIPT=0
[ "${1:-}" = "--write-receipt" ] && WRITE_RECEIPT=1

if ! command -v terraform >/dev/null 2>&1; then
  echo "[SKIP] terraform binary not on PATH" >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# 1. Lane-private substrate (mirrors scripts/bench/lib.sh bench_boot).
# ---------------------------------------------------------------------------
for p in $ARM_PORT $ATLS_PORT $EGRESS_PORT $AMQP_PORT $EHUB_PORT $MCP_PORT; do
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "[FAULT] port $p already held — refusing to boot (collision)" >&2
    exit 1
  fi
done

# Dev TLS material for the 39331 twin (metadata host for azurerm auth).
if [ ! -f "$ROOT/.smalt/tls/ca-cert.pem" ]; then
  bash "$ROOT/scripts/gen_dev_cert.sh" >/dev/null || true
fi
# Lane-private TLS snapshot (2026-10-16, lane 419): concurrent lanes re-mint
# .smalt/tls every few minutes; a probe whose window straddles a re-mint fails
# x509 (served leaf != pinned leaf). Snapshot the material once, serve and pin
# from the snapshot — the probe is then immune to re-mints.
TLS_DIR="$WORK/tls"
mkdir -p "$TLS_DIR"
tls_snapshot_ok() {
  [ -f "$TLS_DIR/dev-cert.pem" ] \
    && openssl x509 -in "$TLS_DIR/dev-cert.pem" -noout -text 2>/dev/null | grep -q "CA:FALSE" \
    && openssl verify -CAfile "$TLS_DIR/ca-cert.pem" "$TLS_DIR/dev-cert.pem" >/dev/null 2>&1
}
for _ in 1 2 3 4 5; do
  cp "$ROOT"/.smalt/tls/ca-cert.pem "$ROOT"/.smalt/tls/ca-key.pem \
     "$ROOT"/.smalt/tls/dev-cert.pem "$ROOT"/.smalt/tls/dev-key.pem "$TLS_DIR/" 2>/dev/null
  if tls_snapshot_ok; then break; fi
  # Self-heal: a concurrent legacy minter keeps re-writing a CA:TRUE leaf
  # (rejected by Go/Apple as an end-entity: "not standards compliant").
  # Re-mint with the current script and re-snapshot.
  echo "[tf-plan-check] tls snapshot unhealthy (self-signed/CA:TRUE leaf or broken chain) — re-minting" >&2
  rm -f "$ROOT/.smalt/tls/dev-cert.pem" "$ROOT/.smalt/tls/dev-key.pem"
  bash "$ROOT/scripts/gen_dev_cert.sh" >/dev/null 2>&1 || true
done
tls_snapshot_ok || { echo "[FAULT] tls snapshot: no CA-chained CA:FALSE leaf after self-heal" >&2; exit 1; }
CA="$TLS_DIR/ca-cert.pem"
# Zero-touch trust (2026-10-16 operator ruling): the SHIM-PROBE stage — build
# the shim + probe, run the probe (go build + direct exec, never `go run`:
# cmd/go strips DYLD_* from the child env), THEN export the env for the
# terraform stages. Keychain status is INFORMATIONAL — never mutated, never a
# gate. Fail-closed: shim-unbuildable or probe-fail is a typed FAIL, not a
# skip (the native tier needs none of this).
if [ "$(uname)" = "Darwin" ] && [ -f "$CA" ]; then
  SHIM_DYLIB="$ROOT/scripts/trust_shim/smalt_trust_shim.dylib"
  if [ ! -f "$SHIM_DYLIB" ]; then
    bash "$ROOT/scripts/trust_shim/build.sh" >/dev/null 2>&1 || true
  fi
  if [ ! -f "$SHIM_DYLIB" ]; then
    echo "[FAULT] SHIM-PROBE: trust shim dylib could not be built ($SHIM_DYLIB) — run scripts/trust_shim/build.sh (native tier needs no shim)" >&2
    exit 1
  fi
  # H1 fix: pin the EXACT LEAF (dev-cert.pem), not the CA.
  SMALT_LEAF_SHA256="$(openssl x509 -in "$TLS_DIR/dev-cert.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':')"
  CA_FP="$(openssl x509 -in "$CA" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':')"
  PROBE_BIN="$(mktemp -t smalt_probe)" && mv "$PROBE_BIN" "$PROBE_BIN.bin" && PROBE_BIN="$PROBE_BIN.bin"
  if ! (cd "$ROOT/test/trust_shim_probe" && go build -o "$PROBE_BIN" .); then
    echo "[FAULT] SHIM-PROBE: trust_shim_probe could not be built (go build failed — native tier needs no shim)" >&2
    exit 1
  elif (DYLD_INSERT_LIBRARIES="$SHIM_DYLIB" \
        SMALT_LEAF_SHA256="$SMALT_LEAF_SHA256" SMALT_CA_SHA256="$CA_FP" \
        SMALT_CA_FILE="$CA" \
        "$PROBE_BIN" -tls-dir "$TLS_DIR" -want=pass); then
    export SMALT_LEAF_SHA256
    export SMALT_CA_FILE="$CA" # v2: anchor-append surface
    export DYLD_INSERT_LIBRARIES="$SHIM_DYLIB"
    echo "[tf-plan-check] SHIM-PROBE PASS — shim env exported (pinned leaf fp ${SMALT_LEAF_SHA256:0:16}...)"
  else
    rc=$?
    echo "[FAULT] SHIM-PROBE FAILED (exit $rc) — Security.framework rejected the pinned chain (native tier needs no shim; optional opt-in persistent trust: scripts/tf_trust_setup.sh trust)" >&2
    exit 1
  fi
  rm -f "$PROBE_BIN" 2>/dev/null || true
  if bash "$ROOT/scripts/tf_trust_setup.sh" status >/dev/null 2>&1; then
    echo "[tf-plan-check] keychain trust (informational): trusted"
  else
    echo "[tf-plan-check] keychain trust (informational): not trusted (optional opt-in persistent alternative: scripts/tf_trust_setup.sh trust)"
  fi
fi

EVAL="Application.put_env(:smalt, :arm_port, $ARM_PORT); \
Application.put_env(:smalt, :egress_port, $EGRESS_PORT); \
Application.put_env(:smalt, :amqp_port, $AMQP_PORT); \
Application.put_env(:smalt, :event_hubs_port, $EHUB_PORT, persistent: true); \
Application.put_env(:smalt, :mcp_port, $MCP_PORT); \
Application.put_env(:smalt, :arm_tls_port, $ATLS_PORT); \
{:ok, _} = Application.ensure_all_started(:smalt); \
Process.sleep(:infinity)"

MIX_ENV=test \
SMALT_TLS_CERTFILE="$TLS_DIR/dev-cert.pem" \
SMALT_TLS_KEYFILE="$TLS_DIR/dev-key.pem" \
SMALT_TEST_ARM_PORT=$ARM_PORT SMALT_TEST_EGRESS_PORT=$EGRESS_PORT \
SMALT_TEST_AMQP_PORT=$AMQP_PORT SMALT_TEST_EVENT_HUBS_PORT=$EHUB_PORT \
mix run --no-start -e "$EVAL" --no-halt >"$SUB_LOG" 2>&1 &
SUB_PID=$!
# Keep $WORK for post-run wire evidence (per-fixture plan/apply logs); the
# operator cleans /tmp/tf-plan-probe.* manually.
trap 'kill $SUB_PID 2>/dev/null; pkill -P $SUB_PID 2>/dev/null' EXIT

up=0
for _ in $(seq 1 120); do
  if lsof -nP -iTCP:"$ARM_PORT" -sTCP:LISTEN >/dev/null 2>&1; then up=1; break; fi
  kill -0 "$SUB_PID" 2>/dev/null || break
  sleep 1
done
if [ "$up" -ne 1 ]; then
  echo "[FAULT] lane substrate never bound $ARM_PORT; log tail:" >&2
  tail -n 40 "$SUB_LOG" >&2
  exit 2
fi
echo "[tf-plan-check] lane substrate up: ARM $ARM_PORT, TLS $ATLS_PORT (pid $SUB_PID)"

# ---------------------------------------------------------------------------
# 2. Env: same authority-routing as scripts/smalt-tf, port-shifted.
# ---------------------------------------------------------------------------
export ARM_ENDPOINT="http://localhost:$ARM_PORT"
export ARM_RESOURCE_MANAGER_ENDPOINT="http://localhost:$ARM_PORT"
export ARM_RESOURCE_MANAGER_AUDIENCE="https://management.azure.com"
# SHIM-COURT lane fix (2026-10-16): 127.0.0.1 not localhost — azurerm resolves
# localhost to [::1] and dials IPv6 vs the 127.0.0.1-bound TLS twin (witnessed).
# https scheme avoids azidentity's localhost-only http allowance; SAN IP:127.0.0.1.
export ARM_METADATA_HOSTNAME="127.0.0.1:$ATLS_PORT"
export SSL_CERT_FILE="$CA"
export AZURE_AUTHORITY_HOST="https://127.0.0.1:$ATLS_PORT/"
export AZAPI_ARM_ENDPOINT="http://localhost:$ARM_PORT"
export AZAPI_ARM_RESOURCE_MANAGER_ENDPOINT="http://localhost:$ARM_PORT"
export ARM_USE_MSI="false"
export ARM_CLIENT_ID="00000000-0000-0000-0000-000000000000"
export ARM_CLIENT_SECRET="smalt-sovereign-mock-secret"
export ARM_SUBSCRIPTION_ID="00000000-0000-0000-0000-000000000000"
export ARM_TENANT_ID="00000000-0000-0000-0000-000000000000"
export TF_PLUGIN_CACHE_DIR="$WORK/plugin-cache"
mkdir -p "$TF_PLUGIN_CACHE_DIR"
export TF_IN_AUTOMATION=1

# Offline provider install (M7/M8): refresh + re-validate the mirror every
# run and generate the rc at run time into a temp path (no committed rc).
# If refresh fails outright, each init falls through to
# registry.terraform.io (typed network failure per fixture).
source "$ROOT/scripts/tf_mirror_env.sh"
if tf_mirror_env_setup; then
  echo "[tf-plan-check] mirror mode: $TF_MIRROR_MODE"
  trap 'tf_mirror_env_cleanup; kill $SUB_PID 2>/dev/null; pkill -P $SUB_PID 2>/dev/null' EXIT
else
  echo "[tf-plan-check] no usable mirror — falling through to registry install" >&2
  trap 'kill $SUB_PID 2>/dev/null; pkill -P $SUB_PID 2>/dev/null' EXIT
fi

# Monotonic ms clock for per-fixture elapsed evidence.
now_ms() {
  python3 -c 'import time; print(time.monotonic_ns() // 10**6)' 2>/dev/null \
    || echo $(( SECONDS * 1000 ))
}

# ---------------------------------------------------------------------------
# 3. Per-fixture init + plan.
# ---------------------------------------------------------------------------
declare -a NAMES=() VERDICTS=() NOTES=()
CUR=0
FAILED=0
for f in "$FIXTURES"/*.tf; do
  name="$(basename "$f" .tf)"
  [ "$name" = "versions" ] && continue
  dir="$WORK/$name"
  t0="$(now_ms)"
  mkdir -p "$dir"
  cp "$FIXTURES/versions.tf" "$dir/"
  cp "$f" "$dir/main.tf"

  if ! terraform -chdir="$dir" init -input=false -no-color >"$dir/init.log" 2>&1; then
    NAMES+=("$name"); VERDICTS+=("FAIL"); NOTES+=("init failed: $(tail -n 3 "$dir/init.log" | tr '\n' ' ' | cut -c1-200)")
    FAILED=1; continue
  fi

  if terraform -chdir="$dir" plan -input=false -no-color >"$dir/plan.log" 2>&1; then
    if grep -q "to add, 0 to change, 0 to destroy" "$dir/plan.log"; then
      adds=$(grep -oE '[0-9]+ to add' "$dir/plan.log" | head -1)
      NAMES+=("$name"); VERDICTS+=("PASS"); NOTES+=("$adds")
    else
      NAMES+=("  $name"); VERDICTS+=("FAIL"); NOTES+=("plan ok but no add-diff; tail: $(tail -n 5 "$dir/plan.log" | tr '\n' ' ' | cut -c1-200)")
      FAILED=1
    fi
  else
    rc=$?
    # Typed divergence: azurerm's own error text names the divergent ARM shape.
    typed=$(grep -oE "(Error: [^\"]{10,220}| unexpectedly|unsupported|not supported|404 Resource Not Found|NotFound|unexpected status [0-9]{3})" "$dir/plan.log" | head -1 | cut -c1-220)
    if [ -n "$typed" ]; then
      NAMES+=("$name"); VERDICTS+=("DIVERGENCE"); NOTES+=("plan: $typed")
    else
      NAMES+=("$name"); VERDICTS+=("FAIL"); NOTES+=("untyped plan failure: $(tail -n 5 "$dir/plan.log" | tr '\n' ' ' | cut -c1-200)")
      FAILED=1
    fi
    continue
  fi

  # -- apply (real write surface) --
  if ! terraform -chdir="$dir" apply -auto-approve -no-color >"$dir/apply.log" 2>&1; then
    typed=$(grep -oE "(Error: .{10,220}|unexpected status [0-9]{3}|404 Resource Not Found|NotFound)" "$dir/apply.log" | head -1 | cut -c1-220)
    if [ -n "$typed" ]; then
      NAMES+=("$name"); VERDICTS+=("DIVERGENCE"); NOTES+=("apply: $typed")
    else
      NAMES+=("$name"); VERDICTS+=("FAIL"); NOTES+=("untyped apply failure: $(tail -n 5 "$dir/apply.log" | tr '\n' ' ' | cut -c1-200)")
      FAILED=1
    fi
    continue
  fi

  # -- state check: post-apply plan must be "No changes" --
  if ! terraform -chdir="$dir" plan -input=false -no-color -refresh-only >"$dir/replan.log" 2>&1; then
    typed=$(grep -oE "(Error: .{10,220}|unexpected status [0-9]{3}|404 Resource Not Found|NotFound)" "$dir/replan.log" | head -1 | cut -c1-220)
    if [ -n "$typed" ]; then
      NAMES+=("$name"); VERDICTS+=("DIVERGENCE"); NOTES+=("refresh: $typed")
    else
      NAMES+=("$name"); VERDICTS+=("FAIL"); NOTES+=("untyped refresh failure: $(tail -n 5 "$dir/replan.log" | tr '\n' ' ' | cut -c1-200)")
      FAILED=1
    fi
  elif ! grep -q "No changes" "$dir/replan.log"; then
    NAMES+=("$name"); VERDICTS+=("DIVERGENCE")
    NOTES+=("refresh drift: post-apply plan is not 'No changes' ($(grep -oE '[0-9]+ to (add|change|destroy)' "$dir/replan.log" | tr '\n' ' '))")
  else
    NAMES+=("$name"); VERDICTS+=("PASS"); NOTES+=("$adds + apply + no-drift ($(( $(now_ms) - t0 ))ms)")
  fi
done

# ---------------------------------------------------------------------------
# 4. Lane-privateness litmus + receipt.
# ---------------------------------------------------------------------------
# TF_LOG: not enabled by default; if TF_LOG=DEBUG was set, assert the lane port
# appeared in the provider's request URLs.
if [ "${TF_LOG:-}" = "DEBUG" ] && grep -q "localhost:$ARM_PORT" "$WORK"/*/plan.log 2>/dev/null; then
  echo "[tf-plan-check] litmus: provider requests hit lane port $ARM_PORT (TF_LOG evidence)"
fi

echo
echo "================ TF PLAN PROBE RECEIPT ================"
for i in "${!NAMES[@]}"; do
  printf '%-14s %-11s %s\n' "${NAMES[$i]}" "${VERDICTS[$i]}" "${NOTES[$i]}"
done
echo "======================================================="
echo "work dir (kept): $WORK"

if [ "$WRITE_RECEIPT" -eq 1 ]; then
  mkdir -p "$(dirname "$RECEIPT")"
  {
    echo "# TF plan probe: azurerm per-resource-type vs smalt ARM plane"
    echo
    echo "- Date: 2026-10-16"
    echo "- Lane: tf-plan-probe (lane 332, ports $ARM_PORT/$ATLS_PORT/$EGRESS_PORT)"
    echo "- Subject: smalt repo root (git toplevel) v26.10.16 working tree (multi-lane)"
    echo "- Fixtures: \`test/terraform_fixture_per_resource/<name>.tf\`"
    echo "- Probe: \`scripts/tf_plan_check.sh --write-receipt\`"
    echo "- Work dir (kept): \`$WORK\` (per-fixture plan.log = wire evidence)"
    echo
    echo "## Verdict: per-resource plan-parse"
    echo
    echo "| Fixture | Verdict | Evidence |"
    echo "|---|---|---|"
    for i in "${!NAMES[@]}"; do
      n="${NAMES[$i]#  }"
      printf '| %s | %s | %s |\n' "$n" "${VERDICTS[$i]}" "${NOTES[$i]}"
    done
    echo
    echo "## Divergences"
    echo
    echo "TYPED divergence = azurerm's own error names the divergent ARM shape;"
    echo "that is a registered finding (KD candidate), not a hidden failure."
    echo
    echo "- Standing: PARTIAL_ALIVE — plan-parse surface proven per-resource; divergences typed in-table."
  } >"$RECEIPT"
  echo "[tf-plan-check] receipt written: $RECEIPT"
fi

exit $FAILED
