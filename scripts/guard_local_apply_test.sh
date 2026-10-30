#!/usr/bin/env bash
# ============================================================================
# guard_local_apply_test.sh — non-vacuity court for guard_local_apply.sh.
#
# A court that cannot flip is FAIL: each case asserts the guard's typed exit
# code on a real fixture root (no mocks). Cases:
#   1. backend present + empty .terraform + apply        -> exit 1 REFUSE
#   2. backend present + initialized .terraform + apply  -> exit 0 PASS
#   3. backend absent + apply                            -> pos 0 PASS
#   4. backend present + empty .terraform + plan         -> exit 0 PASS
#   5. backend present + empty .terraform + apply -backend=false -> exit 1 REFUSE
#   6. SMALT_LOCAL=1 escape hatch                        -> exit 0 PASS
#   7. missing root dir                                  -> exit 2 usage
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/guard_local_apply.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0

backend_tf='terraform { backend "azurerm" { resource_group_name = "rg-x" } }'

fixture() { # $1=name $2=backend? -> prints dir; creates root with main.tf (+ state)
  local d="$TMP/$1"; mkdir -p "$d"
  if [ "$2" = backend ]; then printf '%s\n' "$backend_tf" > "$d/main.tf"; fi
  printf 'resource "terraform_data" "x" { input = "v" }\n' >> "$d/main.tf"
  printf '%s\n' "$d"
}

expect() { # $1=expected-rc $2=label; runs guard via $G (set by caller)
  local want="$1" label="$2"; shift 2
  "$GUARD" "$@" >"$TMP/out" 2>&1; local got=$?
  if [ "$got" != "$want" ]; then
    echo "[GUARD-TEST-FAIL] $label: expected exit $want, got $got"; cat "$TMP/out" >&2
    fails=$((fails+1))
  else
    echo "[GUARD-TEST] PASS $label (exit $got)"
  fi
}

d1=$(fixture be-empty backend)                 # backend HCL, no .terraform
d2=$(fixture be-init backend); mkdir -p "$d2/.terraform"; : > "$d2/.terraform/terraform.tfstate"
d3=$(fixture nobe none)                        # no backend block
d4=$(fixture be-plan backend)
d5=$(fixture be-strip backend)
expect 1 "backend+empty .terraform+apply refused"            "$d1" apply
expect 0 "backend+initialized+apply passes"                  "$d2" apply -auto-approve
expect 0 "backend absent + apply passes"                     "$d3" apply
expect 0 "backend present + plan passes"                     "$d4" plan -out=tfplan
expect 1 "apply -backend=false refused"                      "$d5" apply -backend=false
# escape hatch via env only
SMALT_LOCAL=1 expect 0 "SMALT_LOCAL=1 env escape hatch"      "$d1" apply
# missing dir
expect 2 "missing root dir is usage error"                   "$TMP/nope" apply

if [ "$fails" -ne 0 ]; then
  echo "[GUARD-TEST] FAIL: $fails case(s) failed" >&2
  exit 1
fi
echo "[GUARD-TEST] all cases pass"
