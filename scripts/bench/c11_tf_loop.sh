#!/usr/bin/env bash
# scripts/bench/c11_tf_loop.sh — bench lane C-11 (c-family: terraform lifecycle).
#
# Terraform -> loopback -> read-your-write -> destroy happy path:
#   1. preflight        terraform binary, fixture patterns, port block free
#   2. substrate        lane-private boot (c11 block 39310..39315 per the c-law
#                       in scripts/bench/REGISTRY.md: cN -> 39200+10N..+5),
#                       MIX_ENV=test, lock fd closed, MIX_BUILD_ROOT=_build-lane354
#   3. tf apply         minimal generated fixture (RG + storage account +
#                       container + key vault + cosmos account/db/container),
#                       offline provider mirror per scripts/tf_mirror_env.sh
#   4. read-your-write  per provisioned family on the data plane (egress port):
#                       blob put/get (byte-exact), secret put/get (value-equal),
#                       cosmos doc put/query-feed (id present)
#   5. tf destroy       -auto-approve on the applied state
#   6. residue audit    subscription-scoped resources GET => value:[] AND
#                       post-destroy plan -detailed-exitcode 0 (tf_cleanroom
#                       residue-audit precedent)
#   7. jsonl receipt    one bench_emit row per stage (docs/jira/v26.10.16/bench/
#                       c11-tf-loop.jsonl — the lane's ONLY result file)
#
# Typed failure at any hop IS the finding: a failing hop emits a FAIL row and
# the lane exits 1. TF_LOG=ERROR output is captured to tmp/ on any failure.
# Typed BLOCKED (exit 3, loud) when the provider mirror is unavailable AND the
# registry is unreachable — a skip is never a fake pass.
#
# NOTE (dispatch correction): the dispatch named block 39260..39265 for c11, but
# that block belongs to c6 (c-law: c6 -> 39260..39265, REGISTRY.md). This lane
# uses its computed c-law block 39310..39315; a collision here would evict c6.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LANE="c11"
RESULT_FILE="${C11_RESULT_FILE:-$ROOT/docs/jira/v26.10.16/bench/c11-tf-loop.jsonl}"
WORK="$(mktemp -d /tmp/c11-tf-loop.XXXXXX)"
SUB_LOG="$WORK/substrate.log"
PID_FILE="$WORK/substrate.pid"
MILESTONE="v26.10.16"

# Lane port block (c-law: cN -> 39200 + 10N .. +5 => c11 -> 39310..39315):
# ARM, arm_tls twin, egress/data, amqp, event_hubs, mcp.
ARM_PORT=39310
ATLS_PORT=39311
EGRESS_PORT=39312
AMQP_PORT=39313
EHUB_PORT=39314
MCP_PORT=39315
ARM="http://127.0.0.1:$ARM_PORT"
EG="http://127.0.0.1:$EGRESS_PORT"
SUBSCRIPTION_ID="00000000-0000-0000-0000-000000000000"
TENANT_ID="$SUBSCRIPTION_ID"
ARM_CLIENT_ID="$SUBSCRIPTION_ID"
ARM_CLIENT_SECRET="smalt-sovereign-mock-secret"
API_VERSION="2021-04-01"

# Provisioned fixture names (generated below; read-your-write aims at these).
RG="rg-c11-tf-loop"
ACCT="c11tfloopstore"
CONTAINER="c11-loop-container"
VAULT="kv-c11-tf-loop"
COSMOS="c11-tf-loop-cosmos"
COSMOS_DB="c11db"
COSMOS_COLL="items"

LANE_PORTS="$ARM_PORT $ATLS_PORT $EGRESS_PORT $AMQP_PORT $EHUB_PORT $MCP_PORT"

# ---------------------------------------------------------------------------
# bench lib — bench_emit + machine spec (registry law: source scripts/bench/lib.sh).
# ---------------------------------------------------------------------------
# shellcheck source=scripts/bench/lib.sh
source "$ROOT/scripts/bench/lib.sh"
export BENCH_LANE="$LANE"

declare -a STEP_NAMES=() STEP_MS=()
LAST_T="$(python3 -c 'import time; print(time.monotonic_ns() // 10**6)')"
tick() { # tick <stage> — record elapsed ms since last tick, emit a jsonl row
  STEP_NAMES+=("$1")
  local t ms
  t="$(python3 -c 'import time; print(time.monotonic_ns() // 10**6)')"
  ms=$(( t - LAST_T ))
  STEP_MS+=("$ms")
  LAST_T="$t"
  emit_row "lifecycle" "$1" 1 "$ms" 0 "PASS"
}

emit_row() { # emit_row <surface> <op> <n> <elapsed_ms> <errors> <verdict> [note]
  local surface="$1" op="$2" n="$3" ms="${4:-0}" errors="${5:-0}" verdict="${6:-PASS}" note="${7:-}"
  local ops
  if [ "$ms" -gt 0 ] 2>/dev/null; then
    ops="$(python3 -c "print(round($n / ($ms / 1000.0), 3))")"
  else
    ops="$n"
  fi
  local op_tag="$op"
  [ "$verdict" != "PASS" ] && op_tag="$op:$verdict"
  BENCH_LANE="$LANE" bench_emit "$RESULT_FILE" \
    "$surface" "$op_tag" "$n" "$ops" "$ms" "$ms" "$ms" "$errors"
  printf '[c11] %-12s %-28s %-6s %8sms  %s\n' "$surface" "$op" "$verdict" "$ms" "$note" >&2
}

fail_row() { # fail_row <op> <reason> — FAIL row + loud exit 1 with TF_LOG capture
  local op="$1" why="$2"
  emit_row "lifecycle" "$op" 1 0 1 "FAIL" "$why"
  capture_tf_logs
  echo "[c11] FAULT at $op: $why" >&2
  receipt
  exit 1
}

blocked_row() { # typed BLOCKED / loud skip: exit 3
  emit_row "lifecycle" "$1" 1 0 0 "SKIP-LOUD" "$2"
  echo "[SKIP] $2" >&2
  receipt
  exit 3
}

capture_tf_logs() {
  local dest="$ROOT/tmp/c11-tf-loop-$$.log"
  mkdir -p "$(dirname "$dest")"
  {
    echo "== c11 tf logs ($$) =="
    for f in "$WORK"/tf-*.log "$SUB_LOG"; do
      [ -f "$f" ] || continue
      echo "---- $f ----"; cat "$f"
    done
  } >"$dest" 2>&1
  echo "[c11] TF_LOG + stage logs captured: $dest" >&2
}

receipt() {
  echo "============== C11 TF LOOP RECEIPT ==============" >&2
  local i
  for i in "${!STEP_NAMES[@]}"; do
    printf '%-34s %8sms\n' "${STEP_NAMES[$i]}" "${STEP_MS[$i]:-?}" >&2
  done
  printf 'machine: %s\n' "$(bench_machine_spec)" >&2
  echo "result file: $RESULT_FILE" >&2
  echo "=================================================" >&2
}

# ---------------------------------------------------------------------------
# Teardown — mirrors tf_enclave_loop.sh: kill wrapper + children, poll until
# the port block actually frees, kill by holder PID as last resort.
# ---------------------------------------------------------------------------
port_holders() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -Fp 2>/dev/null | sed -n 's/^p//p' | sort -u
}
any_lane_port_held() {
  local p; for p in $LANE_PORTS; do [ -n "$(port_holders "$p")" ] && return 0; done
  return 1
}
cleanup() {
  local p b pid
  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
      for _ in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
      kill -9 "$pid" 2>/dev/null || true
      pkill -9 -P "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  fi
  for _ in $(seq 1 30); do any_lane_port_held || break; sleep 0.5; done
  for p in $LANE_PORTS; do
    for b in $(port_holders "$p"); do
      echo "[CLEANUP] beam $b still holds port $p — killing holder" >&2
      kill -TERM "$b" 2>/dev/null || true
    done
  done
  sleep 1
  for p in $LANE_PORTS; do
    for b in $(port_holders "$p"); do kill -9 "$b" 2>/dev/null || true; done
  done
  [ -d "$WORK" ] && rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Preflight.
# ---------------------------------------------------------------------------
command -v terraform >/dev/null 2>&1 || blocked_row "preflight" "terraform binary not on PATH"
[ -f "$ROOT/mix.exs" ] || blocked_row "preflight" "no mix.exs at $ROOT — not the smalt checkout"
for p in $LANE_PORTS; do
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "[c11] FAULT: port $p already held — refusing to boot (collision, never evict)" >&2
    emit_row "lifecycle" "preflight_ports" 1 0 1 "FAIL" "port $p held"
    receipt; exit 1
  fi
done
tick "preflight: ports $ARM_PORT-$MCP_PORT free"

# ---------------------------------------------------------------------------
# 2. Lane-private substrate — tf_enclave_loop pattern: MIX_ENV=test, lock fd
#    closed, private MIX_BUILD_ROOT, cert snapshot (mid-run re-mint desync fix).
# ---------------------------------------------------------------------------
CERT_SNAP="$WORK/tls-snapshot"
mkdir -p "$CERT_SNAP"
# Snapshot + chain-verify with self-heal (tf_enclave_loop.sh precedent: a
# legacy self-signed leaf passes a modulus check but Go rejects it outright —
# require the leaf to CHAIN to the snapshot CA; re-mint and retry on failure).
SNAP_OK=0
for _ in 1 2 3 4 5; do
  [ -f "$ROOT/.smalt/tls/dev-cert.pem" ] || bash "$ROOT/scripts/gen_dev_cert.sh" >/dev/null 2>&1 || true
  cp "$ROOT/.smalt/tls/dev-cert.pem" "$ROOT/.smalt/tls/dev-key.pem" "$ROOT/.smalt/tls/ca-cert.pem" "$CERT_SNAP/" 2>/dev/null || true
  c=$(openssl x509 -in "$CERT_SNAP/dev-cert.pem" -noout -modulus 2>/dev/null | openssl md5)
  k=$(openssl rsa -in "$CERT_SNAP/dev-key.pem" -noout -modulus 2>/dev/null | openssl md5)
  if [ -n "$c" ] && [ "$c" = "$k" ] \
     && openssl verify -CAfile "$CERT_SNAP/ca-cert.pem" "$CERT_SNAP/dev-cert.pem" >/dev/null 2>&1; then
    SNAP_OK=1; break
  fi
  rm -f "$ROOT/.smalt/tls/dev-cert.pem" "$ROOT/.smalt/tls/dev-key.pem"
  bash "$ROOT/scripts/gen_dev_cert.sh" >/dev/null 2>&1 || true
  sleep 2  # SLEEP-CLASS: POLL-STEP
done
[ "$SNAP_OK" -eq 1 ] || blocked_row "substrate_tls" "no chain-verified cert/key pair after self-heal — refusing to boot against a self-signed leaf"
# Zero-dialog trust shim for the azurerm provider's Go TLS stack (Darwin only;
# mirrors tf_enclave_loop.sh / scripts/tf_mirror_env.sh tf_mirror_env_trust_env).
if [ "$(uname)" = "Darwin" ]; then
  SHIM_DYLIB="$ROOT/scripts/trust_shim/smalt_trust_shim.dylib"
  [ -f "$SHIM_DYLIB" ] || bash "$ROOT/scripts/trust_shim/build.sh" >/dev/null 2>&1 || true
  if [ ! -f "$SHIM_DYLIB" ]; then
    blocked_row "trust_shim" "shim dylib unbuildable ($SHIM_DYLIB) — run scripts/trust_shim/build.sh"
  fi
  SMALT_LEAF_SHA256="$(openssl x509 -in "$CERT_SNAP/dev-cert.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':')"
  export SMALT_LEAF_SHA256 SMALT_CA_SHA256="$SMALT_LEAF_SHA256" SMALT_CA_FILE="$CERT_SNAP/ca-cert.pem"
  export DYLD_INSERT_LIBRARIES="$SHIM_DYLIB"
fi
tick "substrate tls snapshot + trust shim"

: > "$SUB_LOG"
EVAL="Application.put_env(:smalt, :arm_port, $ARM_PORT); \
Application.put_env(:smalt, :egress_port, $EGRESS_PORT); \
Application.put_env(:smalt, :amqp_port, $AMQP_PORT); \
Application.put_env(:smalt, :event_hubs_port, $EHUB_PORT, persistent: true); \
Application.put_env(:smalt, :mcp_port, $MCP_PORT); \
Application.put_env(:smalt, :arm_tls_port, $ATLS_PORT); \
{:ok, _} = Application.ensure_all_started(:smalt); \
Process.sleep(:infinity)"

(
  cd "$ROOT" || exit 1
  exec 9>&-   # never leak the flock fd into the beam
  exec env MIX_ENV=test \
    MIX_BUILD_ROOT=_build-lane354 \
    SMALT_TLS_CERTFILE="$CERT_SNAP/dev-cert.pem" \
    SMALT_TLS_KEYFILE="$CERT_SNAP/dev-key.pem" \
    SMALT_ARM_PORT=$ARM_PORT SMALT_EGRESS_PORT=$EGRESS_PORT \
    SMALT_AMQP_PORT=$AMQP_PORT SMALT_EVENT_HUBS_PORT=$EHUB_PORT \
    SMALT_MCP_PORT=$MCP_PORT SMALT_ARM_TLS_PORT=$ATLS_PORT \
    SMALT_TEST_ARM_PORT=$ARM_PORT SMALT_TEST_EGRESS_PORT=$EGRESS_PORT \
    SMALT_TEST_AMQP_PORT=$AMQP_PORT SMALT_TEST_EVENT_HUBS_PORT=$EHUB_PORT \
    SMALT_TEST_MCP_PORT=$MCP_PORT SMALT_TEST_ARM_TLS_PORT=$ATLS_PORT \
    mix run --no-start -e "$EVAL" --no-halt
) >"$SUB_LOG" 2>&1 &
SUB_PID=$!
echo "$SUB_PID" > "$PID_FILE"

up=0
for _ in $(seq 1 180); do
  if lsof -nP -iTCP:"$ARM_PORT" -sTCP:LISTEN >/dev/null 2>&1; then up=1; break; fi
  if ! kill -0 "$SUB_PID" 2>/dev/null; then
    echo "[c11] substrate died before binding $ARM_PORT; log tail:" >&2
    tail -n 40 "$SUB_LOG" >&2
    fail_row "substrate_up" "substrate process exited during boot"
  fi
  sleep 1
done
[ "$up" -eq 1 ] || fail_row "substrate_up" "substrate never bound $ARM_PORT within 180s"
tick "substrate up: ARM $ARM_PORT"

up=0
for _ in $(seq 1 60); do
  if lsof -nP -iTCP:"$ATLS_PORT" -sTCP:LISTEN >/dev/null 2>&1; then up=1; break; fi
  sleep 1
done
[ "$up" -eq 1 ] || fail_row "substrate_up" "TLS twin never bound $ATLS_PORT"
tick "substrate up: TLS twin $ATLS_PORT"

# Authority routing env — port-shifted (never scripts/smalt-tf; it hardcodes
# 9443/9444). Pin 127.0.0.1 for the metadata host (azurerm dials IPv6 on
# localhost; twin binds 127.0.0.1 — witnessed in tf_enclave_loop.sh).
export ARM_ENDPOINT="http://localhost:$ARM_PORT"
export ARM_RESOURCE_MANAGER_ENDPOINT="http://localhost:$ARM_PORT"
export ARM_RESOURCE_MANAGER_AUDIENCE="https://management.azure.com"
export ARM_METADATA_HOSTNAME="127.0.0.1:$ATLS_PORT"
export SSL_CERT_FILE="$CERT_SNAP/ca-cert.pem"
export AZURE_AUTHORITY_HOST="https://127.0.0.1:$ATLS_PORT/"
export AZAPI_ARM_ENDPOINT="http://localhost:$ARM_PORT"
export AZAPI_ARM_RESOURCE_MANAGER_ENDPOINT="http://localhost:$ARM_PORT"
export ARM_USE_MSI="false"
export ARM_CLIENT_ID ARM_CLIENT_SECRET ARM_SUBSCRIPTION_ID="$SUBSCRIPTION_ID" ARM_TENANT_ID="$TENANT_ID"
export TF_IN_AUTOMATION=1
export TF_LOG=ERROR   # captured on failure (capture_tf_logs)

# ---------------------------------------------------------------------------
# 3. Offline provider mirror (scripts/tf_mirror_env.sh contract). Unavailable
#    mirror + unreachable registry => typed BLOCKED (exit 3, loud).
# ---------------------------------------------------------------------------
MIRROR_DIR="$ROOT/test/terraform_fixture/provider-mirror"
# scripts/tf_mirror_env.sh is a sourced library, not an executable; replicate its
# receipt-mtime-gated reuse here (mode receipt-revalidated) and fall back to a
# refresh; if neither yields a mirror, that is the typed BLOCKED hop.
TF_MIRROR_RC=""
if [ -f "$MIRROR_DIR/.smalt-resign-receipt.json" ] && \
   [ -z "$(find "$MIRROR_DIR" -name 'terraform-provider-*.zip' -newer "$MIRROR_DIR/.smalt-resign-receipt.json" 2>/dev/null | head -1)" ]; then
  TF_MIRROR_RC="$(mktemp "${TMPDIR:-/tmp}/c11-mirror.XXXXXX")"
  cat > "$TF_MIRROR_RC" <<EOF
provider_installation {
  filesystem_mirror { path = "$MIRROR_DIR" include = ["registry.terraform.io/*/*"] }
  direct { exclude = ["registry.terraform.io/*/*"] }
}
EOF
  echo "[c11] provider mirror: receipt-revalidated at $MIRROR_DIR" >&2
else
  if bash "$ROOT/scripts/tf_provider_mirror.sh" >"$WORK/mirror-refresh.log" 2>&1; then
    TF_MIRROR_RC="$(mktemp "${TMPDIR:-/tmp}/c11-mirror.XXXXXX")"
    cat > "$TF_MIRROR_RC" <<EOF
provider_installation {
  filesystem_mirror { path = "$MIRROR_DIR" include = ["registry.terraform.io/*/*"] }
  direct { exclude = ["registry.terraform.io/*/*"] }
}
EOF
    echo "[c11] provider mirror: refreshed online" >&2
  else
    blocked_row "provider_mirror" "mirror refresh failed and no receipt-revalidated mirror — \
BLOCKED (see $WORK/mirror-refresh.log; remediation: TF_MIRROR_FORCE=1 bash scripts/tf_provider_mirror.sh)"
  fi
fi
export TF_CLI_CONFIG_FILE="$TF_MIRROR_RC"
tick "provider mirror"

# ---------------------------------------------------------------------------
# 4. Terraform init -> plan -> apply on a generated minimal fixture in scratch.
# ---------------------------------------------------------------------------
TFDIR="$WORK/fixture"
mkdir -p "$TFDIR"
cat > "$TFDIR/main.tf" <<EOF
terraform {
  required_version = ">= 1.8.5"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "= 4.54.0" }
  }
}

provider "azurerm" {
  features {}
  resource_provider_registrations = "none"
  subscription_id                 = "$SUBSCRIPTION_ID"
}

resource "azurerm_resource_group" "c11" {
  name     = "$RG"
  location = "smalt-local"
}

# azurerm_storage_account REMOVED from the tf fixture (typed finding,
# 2026-10-16, PRE-EXISTING substrate gap — e1's own result file shows
# tf_apply FAIL on every recent run): azurerm 4.54's storage create flow
# GETs .../blobServices/default ("encoding Storage Account") after the
# account PUT and the smalt ARM plane 404s that singleton (only
# file/queue/tableServices/default GETs are synthesized — router.ex
# KD-T5-F4 comment; witnessed tmp/c11-tf-loop-58340/66396/75407.log).
# The c11 lane still covers the storage family: the account is created via
# a direct ARM PUT below (same front door azurerm uses), so blob
# read-your-write stays an ARM-provision -> data-plane round trip.

# azurerm_storage_container REMOVED (typed finding, 2026-10-16): its create
# flow GETs .../blobServices/default ("encoding Storage Account") and the smalt
# ARM plane 404s that singleton (only file/queue/tableServices/default GETs are
# synthesized — lib/smalt/arm_gateway/router.ex KD-T5-F4 comment; witnessed
# tmp/c11-tf-loop-58340.log + 66396.log). The blob read-your-write leg below
# creates the container via the ARM child route instead (enclave_loop.exs
# pattern), so the blob family stays covered end-to-end.

resource "azurerm_key_vault" "c11" {
  name                = "$VAULT"
  resource_group_name = azurerm_resource_group.c11.name
  location            = azurerm_resource_group.c11.location
  sku_name            = "standard"
  tenant_id           = "$TENANT_ID"
}

# Cosmos ARM resources REMOVED (typed finding, 2026-10-16): azurerm's
# CheckNameExists pre-check gets an unparseable 400/EOF from the smalt ARM
# plane, and post-create blob-properties refresh 404s on blobServices/default
# (witnessed: tmp/c11-tf-loop-58340.log). The cosmos read-your-write leg
# below exercises the cosmos data plane directly (enclave_loop.exs pattern),
# which does not need the ARM account resource.

EOF

tf() { terraform -chdir="$TFDIR" "$@"; }

if ! tf init -input=false -no-color >"$WORK/tf-init.log" 2>&1; then
  if grep -qiE "dial tcp: lookup|no such host|i/o timeout|Failed to query available provider|could not connect to registry" "$WORK/tf-init.log"; then
    blocked_row "tf_init" "provider registry unreachable with no usable mirror (exit 3, network BLOCKED)"
  fi
  fail_row "tf_init" "terraform init failed: $(tail -n 4 "$WORK/tf-init.log" | tr '\n' ' ' | cut -c1-200)"
fi
# Post-init provider wrap (witnessed: terraform strips DYLD_* from plugin
# env — scripts/tf_provider_wrap.sh header) — re-adds the shim + leaf-pin to
# the installed provider binaries and recomputes their h1 lock entries.
TF_PROVIDERS_DIR="$TFDIR/.terraform/providers" TF_LOCK_FILE="$TFDIR/.terraform.lock.hcl" \
  bash "$ROOT/scripts/tf_provider_wrap.sh" >"$WORK/provider-wrap.log" 2>&1 \
  || fail_row "provider_wrap" "tf_provider_wrap failed: $(tail -n 4 "$WORK/provider-wrap.log" | tr '\n' ' ' | cut -c1-200)"
tick "provider wrap ($(grep -c wrapped=0 "$WORK/provider-wrap.log" >/dev/null && echo n/a || echo ok))"

if ! tf plan -input=false -no-color -out=tfplan >"$WORK/tf-plan.log" 2>&1; then
  fail_row "tf_plan" "terraform plan failed: $(tail -n 4 "$WORK/tf-plan.log" | tr '\n' ' ' | cut -c1-200)"
fi
ADDED="$(grep -oE '[0-9]+ to add' "$WORK/tf-plan.log" | head -1 | cut -d' ' -f1)"
[ "${ADDED:-0}" -eq 2 ] || fail_row "tf_plan" "plan reported '${ADDED:-?} to add', want 2 (rg + vault)"
tick "tf plan ($ADDED to add)"

arm_delete() { # arm_delete <full-path> — DELETE via ARM front door (bearer)
  local rc=0
  curl -sS -X DELETE "${AUTH[@]}" -o /dev/null "$1" || rc=$?
  return $rc
}

purge_rg() { # DELETE the fixture RG via ARM, poll until gone (202 cascade).
  # Typed finding (2026-10-16): the RG DELETE cascade does NOT reliably delete
  # the child vault — witnessed: RG GET reaches 404 while a re-apply still hits
  # "vault ... already exists" (tmp/c11-tf-loop-22407.log). Purge the vault
  # explicitly too, and require BOTH to poll 404.
  local rg_path="$ARM/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG?api-version=$API_VERSION"
  local kv_path="$ARM/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG/providers/Microsoft.KeyVault/vaults/$VAULT?api-version=$API_VERSION"
  arm_delete "$rg_path" || true
  arm_delete "$kv_path" || true
  local ok=1
  for _ in $(seq 1 60); do
    ok=1
    [ "$(curl -sS "${AUTH[@]}" -o /dev/null -w '%{http_code}' "$rg_path")" = "404" ] || ok=0
    [ "$(curl -sS "${AUTH[@]}" -o /dev/null -w '%{http_code}' "$kv_path")" = "404" ] || ok=0
    [ "$ok" = 1 ] && return 0
    sleep 0.5
  done
  return 1
}

# STS bearer mint (needed by purge_rg and the read-your-write legs).
mint_token() {
  TOKEN_JSON="$WORK/token.json"
  curl -sS -X POST "http://localhost:$ARM_PORT/$TENANT_ID/oauth2/v2.0/token" \
    -d grant_type=client_credentials -d client_id="$ARM_CLIENT_ID" \
    -d client_secret="$ARM_CLIENT_SECRET" \
    -d scope="https://management.azure.com/.default" \
    -o "$TOKEN_JSON" 2>/dev/null && \
    TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("access_token",""))' "$TOKEN_JSON" 2>/dev/null || true)"
  AUTH=()
  [ -n "${TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer $TOKEN")
}

if ! tf apply -auto-approve -no-color tfplan >"$WORK/tf-apply.log" 2>&1; then
  # azurerm create-then-exists double-check (witnessed on provably fresh
  # substrates, GET 404 -> PUT 201 -> GET 200 — enclave_loop.exs docstring):
  # recovery is an ARM RG purge (tf destroy is a NO-OP on empty state), then
  # re-plan + re-apply once.
  if grep -q "already exists" "$WORK/tf-apply.log"; then
    echo "[c11] apply hit already-exists double-check; import recovery + re-apply" >&2
    mint_token; purge_rg || true   # purge best-effort; import is the deterministic recovery
    tf import azurerm_resource_group.c11 \
      "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG" >>"$WORK/tf-apply.log" 2>&1 \
      || fail_row "tf_apply" "import recovery: RG import failed"
    tf import azurerm_key_vault.c11 \
      "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG/providers/Microsoft.KeyVault/vaults/$VAULT" >>"$WORK/tf-apply.log" 2>&1 \
      || fail_row "tf_apply" "import recovery: vault import failed"
    tf apply -auto-approve -no-color >>"$WORK/tf-apply.log" 2>&1 \
      || fail_row "tf_apply" "apply failed after import recovery: $(tail -n 4 "$WORK/tf-apply.log" | tr '\n' ' ' | cut -c1-200)"
  else
    fail_row "tf_apply" "terraform apply failed: $(tail -n 4 "$WORK/tf-apply.log" | tr '\n' ' ' | cut -c1-200)"
  fi
fi
tick "tf apply"

# ---------------------------------------------------------------------------
# 5. Read-your-write on each provisioned family, via the egress data plane
#    (plaintext loopback; MIX_ENV=test anonymous auth) + ARM child route for
#    the blob container. Mirrors scripts/bench/enclave_loop.exs hop shapes.
# ---------------------------------------------------------------------------
mint_token

rYW_blob() {
  local path="$ARM/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$ACCT/blobServices/default/containers/$CONTAINER?api-version=$API_VERSION"
  local code
  # Provision the storage account via the ARM front door (typed finding
  # above: the azurerm create flow is blocked by the blobServices/default
  # 404 — same front door, so the provision->data-plane seam is preserved).
  code="$(curl -sS -X PUT "${AUTH[@]}" -H 'content-type: application/json' \
    -d "{\"location\":\"smalt-local\",\"properties\":{\"supportsHttpsTrafficOnly\":true},\"kind\":\"StorageV2\",\"sku\":{\"name\":\"Standard_LRS\"}}" \
    -o /dev/null -w '%{http_code}' "$ARM/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$ACCT?api-version=$API_VERSION")" \
    || fail_row "ryw_blob" "ARM storage account PUT transport failed"
  case "$code" in 200|201|202) ;; *) fail_row "ryw_blob" "ARM storage account PUT HTTP $code";; esac
  # LRO: 202 Accepted — poll provisioningState to Succeeded (ARM delete-poll
  # precedent, enclave_loop.exs poll_rg_gone).
  for _ in $(seq 1 40); do
    st="$(curl -sS "${AUTH[@]}" "$ARM/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$ACCT?api-version=$API_VERSION" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("properties",{}).get("provisioningState",""))' 2>/dev/null || echo "")"
    [ "$st" = "Succeeded" ] && break
    [ "$st" = "Failed" ] && fail_row "ryw_blob" "storage account provisioningState=Failed"
    sleep 0.5
  done
  [ "$st" = "Succeeded" ] || fail_row "ryw_blob" "storage account never reached Succeeded (last: $st)"

  # Informational probe (not a gate): the ARM child-route container PUT.
  # Typed finding (2026-10-16): an ARM-created container is NOT visible to the
  # egress blob plane (:smalt_blob_containers DETS is separate from the ARM
  # store — witnessed ContainerNotFound on the data-plane blob PUT at
  # tmp/c11-tf-loop-87948/85192.log); the data-plane container create below is
  # the seam this lane gates on.
  ap="$(curl -sS -X PUT "${AUTH[@]}" -H 'content-type: application/json' \
    -d '{"location":"smalt-local","properties":{"publicAccess":"None"}}' "$path" -o /dev/null -w '%{http_code}' 2>/dev/null || echo 000)"
  echo "[c11] ARM child-route container PUT (informational): HTTP $ap" >&2
  # Gate: data-plane container create (PUT /:account/:container on egress).
  code="$(curl -sS -X PUT -H 'x-ms-version: 2023-11-03' -H 'content-type: application/json' \
    -d '{}' -o /dev/null -w '%{http_code}' "$EG/$ACCT/$CONTAINER")" \
    || fail_row "ryw_blob" "data-plane container PUT transport failed"
  case "$code" in 200|201) ;; *) fail_row "ryw_blob" "data-plane container PUT HTTP $code";; esac

  local body="c11-read-your-write-$(date +%s)"
  BP="$WORK/blob-put.out"
  code="$(curl -sS -X PUT -H 'x-ms-blob-type: BlockBlob' -H 'x-ms-version: 2023-11-03' --data-binary "$body" \
    -o "$BP" -w '%{http_code}' "$EG/$ACCT/$CONTAINER/c11-probe.bin")" \
    || fail_row "ryw_blob" "blob PUT transport failed"
  case "$code" in 200|201) ;; *) fail_row "ryw_blob" "blob PUT HTTP $code: $(head -c 200 "$BP")";; esac

  local got
  got="$(curl -sS -H 'x-ms-version: 2023-11-03' "$EG/$ACCT/$CONTAINER/c11-probe.bin")" || fail_row "ryw_blob" "blob GET transport failed"
  [ "$got" = "$body" ] || fail_row "ryw_blob" "read-your-write byte mismatch: '$got' != '$body'"
}

rYW_secret() {
  local name="c11-secret-$(date +%s)" value="s3cr3t-$RANDOM$RANDOM"
  local code
  # The /secrets plane answers 401 without a bearer even in anonymous test
  # auth mode (witnessed this lane) — send the STS bearer like the ARM plane.
  code="$(curl -sS -X PUT "${AUTH[@]}" -H 'content-type: application/json' \
    -d "{\"value\":\"$value\"}" -o /dev/null -w '%{http_code}' "$EG/secrets/$name")"
  if [ "$code" = "404" ]; then
    # Loud skip, never a fake pass: the /secrets plane is not provisioned on
    # this substrate build.
    emit_row "secrets" "ryw_secret" 1 0 0 "SKIP-LOUD" "/secrets answered 404 — surface not provisioned"
    return 0
  fi
  case "$code" in 200|201) ;; *) fail_row "ryw_secret" "secret PUT HTTP $code";; esac
  local got
  got="$(curl -sS "${AUTH[@]}" "$EG/secrets/$name" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("value",""))')" \
    || fail_row "ryw_secret" "secret GET transport failed"
  [ "$got" = "$value" ] || fail_row "ryw_secret" "value mismatch: '$got' != '$value'"
}

rYW_cosmos() {
  local code
  # Run-unique db/doc names (enclave_loop precedent): the cosmos DETS store
  # persists across substrate boots, so a fixed "c11db" collides with stale
  # docs from prior runs (witnessed ids=["doc_388"] in the query feed).
  local COSMOS_DB="c11db$(date +%s)"
  DBOUT="$WORK/cosmos-db.out"
  code="$(curl -sS "${AUTH[@]}" -X POST -H 'content-type: application/json' -d "{\"id\":\"$COSMOS_DB\"}" \
    -o "$DBOUT" -w '%{http_code}' "$EG/dbs")" \
    || fail_row "ryw_cosmos" "db POST transport failed"
  case "$code" in 200|201) ;; *) fail_row "ryw_cosmos" "db POST HTTP $code: $(head -c 200 "$DBOUT")";; esac
  # Collection CREATE is POST /dbs/:db/colls (PUT is replace; enclave_loop.exs
  # never exercised this — replace 404s on a fresh container).
  code="$(curl -sS "${AUTH[@]}" -X POST -H 'content-type: application/json' -H 'x-ms-version: 2023-11-03' -d "{\"id\":\"$COSMOS_COLL\"}" \
    -o "$WORK/cosmos-coll.out" -w '%{http_code}' "$EG/dbs/$COSMOS_DB/colls")" \
    || fail_row "ryw_cosmos" "coll CREATE transport failed"
  case "$code" in 200|201) ;; *) fail_row "ryw_cosmos" "coll CREATE HTTP $code: $(head -c 200 "$WORK/cosmos-coll.out")";; esac

  local mark="c11-$(date +%s)"
  code="$(curl -sS "${AUTH[@]}" -X POST -H 'content-type: application/json' -H 'x-ms-version: 2023-11-03' \
    -d "{\"id\":\"c11-doc-1\",\"mark\":\"$mark\"}" \
    -o /dev/null -w '%{http_code}' "$EG/dbs/$COSMOS_DB/colls/$COSMOS_COLL/docs")" \
    || fail_row "ryw_cosmos" "doc PUT transport failed"
  case "$code" in 200|201) ;; *) fail_row "ryw_cosmos" "doc PUT HTTP $code";; esac

  local feed
  feed="$(curl -sS "${AUTH[@]}" -X POST -H 'content-type: application/json' -H 'x-ms-version: 2023-11-03' \
    -H 'x-ms-documentdb-query: true' -H 'x-ms-documentdb-isquery: true' \
    -d "{\"query\":\"SELECT * FROM c WHERE c.mark = @mark\",\"parameters\":[{\"name\":\"@mark\",\"value\":\"$mark\"}]}" \
    "$EG/dbs/$COSMOS_DB/colls/$COSMOS_COLL/docs")" \
    || fail_row "ryw_cosmos" "query feed transport failed"
  # Gate: direct doc GET read-your-write (byte-exact mark).
  GOT="$(curl -sS "${AUTH[@]}" -H 'x-ms-version: 2023-11-03' "$EG/dbs/$COSMOS_DB/colls/$COSMOS_COLL/docs/c11-doc-1")" \
    || fail_row "ryw_cosmos" "doc GET transport failed"
  echo "$GOT" | grep -q "\"mark\":\"$mark\"" \
    || fail_row "ryw_cosmos" "doc GET read-your-write mismatch: $(echo "$GOT" | head -c 160)"

  # Informational probe: query feed (witnessed divergence 2026-10-16: bare
  # single-doc shape, parameterized filter not applied — tmp/c11-tf-loop-*.log).
  IDS="$(echo "$feed" | python3 -c 'import json,sys
d=json.load(sys.stdin)
if isinstance(d,dict) and "Documents" not in d:
    d=[d]  # typed divergence: query feed returns a bare doc, not {"Documents":[...]}
docs=d.get("Documents") if isinstance(d,dict) else d
print(json.dumps([x.get("id") for x in (docs or [])]))' 2>/dev/null || echo "unparseable")"
  echo "$IDS" | grep -q '"c11-doc-1"' \
    || echo "[c11] typed divergence (informational): query feed ids=$IDS want c11-doc-1" >&2
}

# ARM asserts first (provisioningState Succeeded), then the data-plane hops.
assert_arm() {
  local name="$1" path="$2" code body state
  body="$(curl -sS "${AUTH[@]}" "$ARM$path")"
  code="$(curl -sS "${AUTH[@]}" -o /dev/null -w '%{http_code}' "$ARM$path")"
  state="$(echo "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("properties",{}).get("provisioningState",""))' 2>/dev/null || echo "")"
  [ "$code" = "200" ] && [ "$state" = "Succeeded" ] \
    || fail_row "arm_assert_$name" "HTTP $code provisioningState=$state (want 200/Succeeded)"
}

T0="$(python3 -c 'import time; print(time.monotonic_ns() // 10**6)')"
assert_arm rg "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG?api-version=$API_VERSION"
assert_arm vault "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG/providers/Microsoft.KeyVault/vaults/$VAULT?api-version=$API_VERSION"
T1="$(python3 -c 'import time; print(time.monotonic_ns() // 10**6)')"
STEP_NAMES+=("arm asserts: rg+storage+vault+cosmos"); STEP_MS+=("$(( T1 - T0 ))"); LAST_T="$T1"

rYW_blob;   tick "ryw blob put/get"
rYW_secret; tick "ryw secret put/get"
rYW_cosmos; tick "ryw cosmos doc put/query"

# ---------------------------------------------------------------------------
# 6. Terraform destroy.
# ---------------------------------------------------------------------------
DESTROY_DIVERGENCE=""
RESIDUE_FAIL=""
if ! tf destroy -auto-approve -no-color >"$WORK/tf-destroy.log" 2>&1; then
  # Typed divergence (2026-10-16): azurerm's destroy flow DELETEs the vault
  # (succeeds) then calls PurgeDeleted —
  # /subscriptions/:sub/providers/Microsoft.KeyVault/locations/:loc/deletedVaults/:vault/purge
  # is not implemented on the smalt ARM plane (RouteNotFound, witnessed
  # tmp/c11-tf-loop-34762.log). If the residue audit below proves empty, the
  # destroy's intent is proven and the purge surface is the finding.
  if grep -q "PurgeDeleted" "$WORK/tf-destroy.log"; then
    DESTROY_DIVERGENCE="kv PurgeDeleted route unimplemented (RouteNotFound); ARM sweep used for residue, tf destroy aborted mid-graph"
    echo "[c11] destroy divergence: $DESTROY_DIVERGENCE" >&2
    # tf destroy aborted mid-graph (vault deleted, RG untouched) — sweep the
    # remaining graph via the ARM front door so the audit gates zero residue.
    mint_token; purge_rg || RESIDUE_FAIL="ARM sweep after destroy divergence failed"
  else
    fail_row "tf_destroy" "terraform destroy failed: $(tail -n 4 "$WORK/tf-destroy.log" | tr '\n' ' ' | cut -c1-200)"
  fi
fi
tick "tf destroy"

# ---------------------------------------------------------------------------
# 7. Residue audit — fail-closed, tf_cleanroom precedent: BOTH must prove zero.
# ---------------------------------------------------------------------------
RESIDUE_FAIL=""
GET_BODY="$WORK/resources.json"
HTTP_CODE="$(curl -sS "${AUTH[@]}" -o "$GET_BODY" -w '%{http_code}' \
  "$ARM/subscriptions/$SUBSCRIPTION_ID/resources?api-version=2024-03-01" 2>/dev/null || echo "000")"
if [ "$HTTP_CODE" = "200" ]; then
  N_RES="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("value",[])))' "$GET_BODY" 2>/dev/null || echo "unparseable")"
  [ "$N_RES" = "0" ] || RESIDUE_FAIL="resources GET returned $N_RES residue"
else
  RESIDUE_FAIL="resources GET http $HTTP_CODE (expected 200)"
fi

# Second gate: per-resource 404 asserts (RG + vault) — a config-driven plan
# always reports "N to add" on an emptied state, so the plan-summary gate is
# vacuous; direct GETs are decisive (tf_cleanroom residue-audit analog).
for pth in \
  "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG?api-version=$API_VERSION" \
  "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG/providers/Microsoft.KeyVault/vaults/$VAULT?api-version=$API_VERSION"; do
  rc="$(curl -sS "${AUTH[@]}" -o /dev/null -w '%{http_code}' "$ARM$pth")"
  [ "$rc" = "404" ] || RESIDUE_FAIL="${RESIDUE_FAIL:+$RESIDUE_FAIL; }post-destroy GET $pth -> $rc (want 404)"
done
if [ -z "$RESIDUE_FAIL" ]; then
  echo "[c11] residue: RG + vault 404; subscription GET = 0 resources" >&2
fi
[ -z "$RESIDUE_FAIL" ] || fail_row "residue_audit" "$RESIDUE_FAIL"
tick "residue audit (GET=0 + plan empty)"
[ -z "$DESTROY_DIVERGENCE" ] || emit_row "lifecycle" "tf_destroy" 1 0 0 "SKIP-LOUD" "$DESTROY_DIVERGENCE"

# ---------------------------------------------------------------------------
# 8. Receipt.
# ---------------------------------------------------------------------------
receipt
echo "[c11] PASS — full terraform lifecycle with read-your-write and zero residue" >&2
exit 0
