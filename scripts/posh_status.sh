#!/usr/bin/env bash
# posh_status.sh — GAP60: the operator's single glance. Backs `just posh-status`.
#
# Sections, each typed OK/WARN/FAIL/SKIP(reason); overall exit 0 (no FAIL)
# or 2 (any FAIL). Report-only: never builds, never applies.
#
# Sections:
#   PLANE      — court_plane_discriminator.sh verdict (exit 0 NATIVE / 2
#                KIND|SPLIT / 3 NONE|UNKNOWN). SPLIT is WARN (both planes up).
#   PODS       — kubectl get pods -o wide (context kind-smalt, ns default).
#   ENDPOINTS  — metadata/endpoints anchor via the correct plane + in-pod
#                /.well-known/health/ready when kubectl is reachable.
#   PROVIDER   — binary exists? mtime vs newest source file => FRESH/STALE.
#   GATES      — coverage/compat/invariant fast re-run (each <2s, measured).
#   LAST COURT — newest JSON verdict under
#                docs/jira/posh/v26.10.30/receipts/posh-court/.
#   LAST ANDON — tail posh/var/andon.jsonl, last composite signal.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CTX="${KCTX:-kind-smalt}"
NS="${NS:-default}"
PORT="${PORT:-9443}"
META_URL="${SMALT_POSH_META:-http://127.0.0.1:$PORT/metadata/endpoints?api-version=2020-01-01}"
PROVIDER_DIR="${SMALT_POSH_PROVIDER:-adapters/terraform-provider-smalt}"
PROVIDER_BIN="$PROVIDER_DIR/terraform-provider-azurerm"
COURT_RECEIPTS="docs/jira/posh/v26.10.30/receipts/posh-court"
ANDON="${SMALT_POSH_ANDON:-posh/var/andon.jsonl}"
any_fail=0

# --json: machine-readable mode (one JSON object per verdict line + final
# OVERALL line). Prose remains the default; exit contract unchanged (0 / 2).
JSON=0
[ "${1:-}" = "--json" ] && JSON=1

# verdict <section> <OK|WARN|FAIL|SKIP> [detail]
verdict() {
  local s="$1" t="$2" d="${3:-}"
  [ "$t" = FAIL ] && any_fail=1
  if [ "$JSON" = 1 ]; then
    printf '{"section":"%s","verdict":"%s","detail":"%s"}\n' \
      "$(printf '%s' "$s" | sed 's/"/\\"/g')" "$t" "$(printf '%s' "$d" | sed 's/"/\\"/g')"
    return 0
  fi
  case "$t" in
    OK)   printf '[POSH-STATUS] %-10s OK   %s\n' "$s" "$d" ;;
    WARN) printf '[POSH-STATUS] %-10s WARN %s\n' "$s" "$d" ;;
    FAIL) printf '[POSH-STATUS] %-10s FAIL %s\n' "$s" "$d" ;;
    SKIP) printf '[POSH-STATUS] %-10s SKIP (%s)\n' "$s" "$d" ;;
  esac
  [ "$t" != SKIP ] || return 0
}

emit() { # raw passthrough that is silent in --json mode
  [ "$JSON" = 1 ] || printf '%s\n' "$1"
}

emit "[POSH-STATUS] === $ROOT @ $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# ---- PLANE -----------------------------------------------------------------
if [ -x scripts/court_plane_discriminator.sh ]; then
  plane_out=$(bash scripts/court_plane_discriminator.sh "$PORT" 2>&1); plane_rc=$?
  plane_name=$(printf '%s\n' "$plane_out" | sed -n 's/.*PLANE=\([A-Z]*\).*/\1/p' | tail -1)
  case "$plane_rc" in
    0) verdict PLANE OK "PLANE=NATIVE (host beam owns :$PORT)" ;;
    2) verdict PLANE WARN "PLANE=${plane_name:-KIND/SPLIT} (rc 2)" ;;
    *) verdict PLANE FAIL "PLANE=${plane_name:-NONE/UNKNOWN} (rc $plane_rc)" ;;
  esac
else
  verdict PLANE SKIP "scripts/court_plane_discriminator.sh not executable"
fi

# ---- PODS -------------------------------------------------------------------
if command -v kubectl >/dev/null 2>&1 && kubectl --context "$CTX" get ns default >/dev/null 2>&1; then
  [ "$JSON" = 1 ] || echo "[POSH-STATUS] PODS      --- kubectl --context $CTX -n $NS get pods -o wide"
  [ "$JSON" = 1 ] || kubectl --context "$CTX" -n "$NS" get pods -o wide | head -10
  if kubectl --context "$CTX" -n "$NS" get pods \
      -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' \
      | grep -Eqv '^(Running|Succeeded|Completed)$'; then
    verdict PODS WARN "at least one pod not Running/Completed"
  else
    verdict PODS OK "all pods Running/Completed"
  fi
else
  verdict PODS SKIP "kubectl unreachable for context $CTX"
fi

# ---- ENDPOINTS --------------------------------------------------------------
host_code=$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' "$META_URL" 2>/dev/null) || host_code=000
if [ "$host_code" = 200 ]; then
  verdict ENDPOINTS OK "metadata anchor 200 on host loopback :$PORT"
  if command -v kubectl >/dev/null 2>&1 \
     && kubectl --context "$CTX" -n "$NS" get pod smalt-backend-0 >/dev/null 2>&1; then
    pod_ip=$(kubectl --context "$CTX" -n "$NS" get pod smalt-backend-0 \
      -o jsonpath='{.status.podIP}')
    ready=$(kubectl --context "$CTX" -n "$NS" exec smalt-backend-0 -c smalt -- \
      curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
      "http://$pod_ip:$PORT/.well-known/health/ready" 2>/dev/null)
    if [ "$ready" = 200 ]; then
      [ "$JSON" = 1 ] || echo "[POSH-STATUS] ENDPOINTS  in-pod /.well-known/health/ready 200 (pod $pod_ip)"
    else
      [ "$JSON" = 1 ] || echo "[POSH-STATUS] ENDPOINTS  in-pod /.well-known/health/ready $ready (pod $pod_ip)"
      verdict ENDPOINTS WARN "in-pod health probe returned $ready"
    fi
  else
    [ "$JSON" = 1 ] || echo "[POSH-STATUS] ENDPOINTS  smalt-backend-0 absent — in-pod probe skipped"
  fi
else
  verdict ENDPOINTS FAIL "metadata anchor HTTP $host_code on $META_URL"
fi

# ---- PROVIDER ---------------------------------------------------------------
if [ -x "$PROVIDER_BIN" ]; then
  newest_src=$(find "$PROVIDER_DIR" \( -name '*.go' -o -name 'main.go' \) -newer "$PROVIDER_BIN" \
    -not -path '*/examples/*' 2>/dev/null | head -1)
  if [ -n "$newest_src" ]; then
    verdict PROVIDER WARN "STALE: $newest_src newer than binary"
  else
    verdict PROVIDER OK "FRESH: binary newer than all *.go in $PROVIDER_DIR"
  fi
else
  verdict PROVIDER FAIL "$PROVIDER_BIN missing — run: just posh-build"
fi

# ---- GATES ------------------------------------------------------------------
gate() {
  local name="$1"; shift
  out=$(python3 "$@" 2>&1); rc=$?
  if [ "$rc" = 0 ]; then
    verdict GATES OK "$name PASS"
  else
    verdict GATES FAIL "$name exit $rc — $(printf '%s' "$out" | tail -1 | cut -c1-120)"
  fi
}
gate coverage   scripts/posh_coverage.py
gate compat-pin-core    scripts/compat_pin_check.py --core-pin
gate compat-pin-dialect scripts/compat_pin_check.py --dialect-pin
gate invariant  scripts/posh_invariant_gate.py

# ---- LAST COURT -------------------------------------------------------------
latest_court=$(ls -t "$COURT_RECEIPTS"/*.json 2>/dev/null | head -1)
if [ -n "$latest_court" ]; then
  info=$(python3 - "$latest_court" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("standing", "?"), "| exit", d.get("exit_code", "?"), "|", d.get("timestamp", "?"))
PY
) || info="(unparseable JSON)"
  case "$info" in
    PASS*|CONFORMANT*) verdict "LAST COURT" OK "$latest_court: $info" ;;
    FAIL*)             verdict "LAST COURT" FAIL "$latest_court: $info" ;;
    *)                 verdict "LAST COURT" WARN "$latest_court: $info" ;;
  esac
else
  verdict "LAST COURT" SKIP "no JSON verdict in $COURT_RECEIPTS"
fi

# ---- LAST ANDON -------------------------------------------------------------
if [ -s "$ANDON" ]; then
  last=$(tail -1 "$ANDON")
  comp=$(printf '%s' "$last" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("composite","?"))' 2>/dev/null) || comp="?"
  gate_name=$(printf '%s' "$last" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("gate","?"), d.get("outcome","?"), d.get("ts","?"))' 2>/dev/null) || gate_name="?"
  case "$comp" in
    GREEN) verdict "LAST ANDON" OK "composite GREEN (last: $gate_name)" ;;
    RED)   verdict "LAST ANDON" FAIL "composite RED (last: $gate_name)" ;;
    *)     verdict "LAST ANDON" WARN "composite $comp (last: $gate_name)" ;;
  esac
else
  verdict "LAST ANDON" SKIP "$ANDON empty or absent"
fi

if [ "$JSON" = 1 ]; then
  printf '{"section":"OVERALL","verdict":"%s","exit":%d}\n' \
    "$([ $any_fail = 0 ] && echo GREEN || echo RED)" "$((any_fail ? 2 : 0))"
else
  echo "[POSH-STATUS] === overall: $([ $any_fail = 0 ] && echo GREEN || echo RED) (exit $((any_fail ? 2 : 0))) ==="
fi
exit $((any_fail ? 2 : 0))
