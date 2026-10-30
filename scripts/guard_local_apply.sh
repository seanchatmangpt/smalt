#!/usr/bin/env bash
# ============================================================================
# guard_local_apply.sh — GAP6(b) mechanical fence.
#
# Refuses (exit 1, typed message) a local terraform apply/destroy against a
# root whose backend is declared in HCL but has never been initialized
# (stripped imports / empty .terraform) — that command would CREATE real
# Azure resources instead of reconciling existing ones.
#
# Refusal condition (ALL must hold):
#   (a) a `backend "..."` block is present in the root's *.tf files, AND
#   (b) the command being run is apply/destroy, AND
#   (c) the run is backend-stripped: -backend=false on the command line, OR
#       no backend init present (.terraform/terraform.tfstate missing).
#
# Pass conditions: backend absent (module/example root), plan/init/get/fmt,
# backend initialized, or escape hatch SMALT_LOCAL=1 (explicit local-only
# intent, e.g. a root with a backend block pinned to a local/mock provider).
#
# Usage:
#   guard_local_apply.sh <tf-root-dir> <terraform-args...>
#   e.g. guard_local_apply.sh infra/environments/dev/platform apply -auto-approve
#        guard_local_apply.sh . plan -out=tfplan
#
# Local install (recommended alias):
#   terraform() {
#     case "$1" in apply|destroy)
#       bash /path/to/guard_local_apply.sh . "$@" || return $? ;;
#     esac; command terraform "$@"
#   }
#
# Exit contract: 0 pass / 1 REFUSE / 2 usage error.
# ============================================================================
set -euo pipefail

usage() {
  echo "[GUARD-LOCAL-APPLY-USAGE] usage: guard_local_apply.sh <tf-root-dir> <terraform-args...>" >&2
  exit 2
}

[ $# -ge 1 ] || usage
ROOT="$1"
shift
[ -d "$ROOT" ] || { echo "[GUARD-LOCAL-APPLY-FAIL] root dir not found: $ROOT" >&2; exit 2; }

CMD="${1:-}"
shift || true

# (b) mutating commands only; everything else passes.
case "$CMD" in
  apply|destroy) ;;
  *)
    echo "[GUARD-LOCAL-APPLY] PASS (non-mutating command '${CMD:-<none>}')"
    exit 0
    ;;
esac

# Escape hatch: explicit local-only intent.
if [ "${SMALT_LOCAL:-0}" = "1" ]; then
  echo "[GUARD-LOCAL-APPLY] PASS (SMALT_LOCAL=1 escape hatch — operator asserted local-only target)"
  exit 0
fi

# (a) backend block present in the root's HCL?
if ! grep -RqsE 'backend[[:space:]]+"[^"]+"' "$ROOT" --include="*.tf"; then
  echo "[GUARD-LOCAL-APPLY] PASS (no backend block in $ROOT — local-state root is lawful)"
  exit 0
fi

# (c) backend-stripped run? -backend=false on the command line, or the root
# has never been backend-initialized (.terraform/terraform.tfstate absent).
STRIPPED=0
for a in "$@"; do
  case "$a" in
    -backend=false) STRIPPED=1 ;;
  esac
done
if [ "$STRIPPED" = 0 ] && [ ! -f "$ROOT/.terraform/terraform.tfstate" ]; then
  STRIPPED=1
  REASON="no backend init (.terraform/terraform.tfstate missing in $ROOT)"
else
  REASON="-backend=false on the command line"
fi

if [ "$STRIPPED" = 1 ]; then
  cat >&2 <<EOF
[GUARD-LOCAL-APPLY-REFUSE] terraform $CMD refused in $ROOT
  reason: backend block present but run is backend-stripped ($REASON).
  An apply/destroy with empty local state would CREATE real Azure resources
  under the configured names instead of reconciling the managed ones.
  Remedy: terraform init (backend init) and re-run, or SMALT_LOCAL=1 if this
  root is intentionally local (GAP6(b) fence, scripts/guard_local_apply.sh).
EOF
  exit 1
fi

echo "[GUARD-LOCAL-APPLY] PASS (backend initialized in $ROOT — mutating command permitted)"
exit 0
