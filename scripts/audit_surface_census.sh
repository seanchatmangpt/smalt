#!/usr/bin/env bash
# audit_surface_census.sh — AUD-5 deterministic wire-surface census
# Verifies SDK wire templates (docs/audit/census_table.tsv, from the AUD-1/AUD-3
# tables) against routes registered in lib/smalt/egress_router.ex and
# lib/smalt/arm_gateway/router.ex.
#   MAPS                  - a registered route matches method+path
#   NO-ROUTE (KD-xx)      - unmapped but covered by a KNOWN_DIVERGENCES row
#   MISSING-UNREGISTERED  - unmapped with no KD row -> census FAILS (exit 1)
# Registration is KD-ledger-only: a gap token mentioned in an audit doc is NOT
# registration (anti-vacuity: the gate must be able to fail).
# Deterministic: pure file reads + the embedded-table TSV. No server/network.
set -u
SMALT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EGRESS="$SMALT_ROOT/lib/smalt/egress_router.ex"
ARM="$SMALT_ROOT/lib/smalt/arm_gateway/router.ex"
KD="$SMALT_ROOT/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md"
TABLE="$SMALT_ROOT/docs/audit/census_table.tsv"
for f in "$EGRESS" "$ARM" "$KD" "$TABLE"; do
  [ -f "$f" ] || { echo "CENSUS-ERROR missing input $f" >&2; exit 2; }
done
extract_routes() {
  awk '/^[[:space:]]*(get|post|put|patch|delete|head|options|match)[[:space:]]+"/ {
    verb=$1; path=$2; gsub(/"/,"",path); printf "%s %s\n", toupper(verb), path
  }' "$1" | sort -u
}
ROUTES="$( { extract_routes "$EGRESS"; extract_routes "$ARM"; } )"
echo "== smalt registered routes: $(printf '%s\n' "$ROUTES" | grep -c .) =="
match_route() {
  local method="$1" tmpl="$2" m p segs tsegs
  tmpl="${tmpl%%\?*}"
  segs="$(printf '%s' "$tmpl" | awk -F/ '{print NF-1}')"
  while read -r m p; do
    [ "$m" = "$method" ] || continue
    tsegs="$(printf '%s' "$p" | awk -F/ '{print NF-1}')"
    case "$p" in *\**) [ "$tsegs" -le "$segs" ] || continue ;; *) [ "$tsegs" -eq "$segs" ] || continue ;; esac
    if match_pattern "$p" "$tmpl"; then printf '%s %s\n' "$m" "$p"; return 0; fi
  done <<EV
$ROUTES
EV
  return 1
}
match_pattern() {
  local p="$1" t="$2" pa ta
  pa="$(printf '%s' "$p" | tr '/' '\n' | tr '[:upper:]' '[:lower:]')"
  ta="$(printf '%s' "$t" | tr '/' '\n' | tr '[:upper:]' '[:lower:]')"
  printf '%s\n' "$pa" | paste -d'|' - <(printf '%s\n' "$ta") | \
  awk -F'|' '$1 ~ /^[*:]/ { next } $1 != $2 { exit 1 }' && return 0
  return 1
}
# --- census ------------------------------------------------------------------
# TSV: method<TAB>template<TAB>[marker]<TAB>token (token = last field; "-"=none)
# marker MISROUTE = maps but with wrong semantics (audit-documented class)
mapped=0; misroute=0; registered=0; unreg=0
unreg_list="$(mktemp)"; trap 'rm -f "$unreg_list"' EXIT
while IFS="$(printf '\t')" read -r method tmpl marker rest; do
  [ -n "${method:-}" ] || continue
  token="$rest"; [ -z "$token" ] && token="$marker"
  [ -z "$token" ] && token="-"
  hit=""
  for verb in $(printf '%s' "$method" | tr '/' ' '); do
    if r="$(match_route "$verb" "$tmpl")"; then hit="$r"; break; fi
  done
  if [ -n "$hit" ]; then
    case "$marker" in
      MISROUTE) echo "MISROUTE-MAPPED  [$token] $method $tmpl (maps to $hit)"
                misroute=$((misroute+1)); mapped=$((mapped+1)) ;;
      *) mapped=$((mapped+1)) ;;
    esac
    continue
  fi
  case "$token" in
    -) echo "MISSING-UNREGISTERED  $method $tmpl"; echo "$method $tmpl" >> "$unreg_list"; unreg=$((unreg+1)) ;;
    REGISTERED-UNSUPPORTED) echo "UNSUPPORTED-REGISTERED  $method $tmpl (typed refusal, routed)"
                            registered=$((registered+1)) ;;
    KD-*)
      if grep -q "| *$token " "$KD"; then
        echo "NO-ROUTE (KD-registered: $token)  $method $tmpl"; registered=$((registered+1))
      else
        echo "MISSING-UNREGISTERED  $method $tmpl (token $token not in KNOWN_DIVERGENCES)"
        echo "$method $tmpl" >> "$unreg_list"; unreg=$((unreg+1))
      fi ;;
    *)
      echo "MISSING-PROPOSED  $method $tmpl (proposed $token — no KD row yet)"
      unreg=$((unreg+1)) ;;
  esac
done < "$TABLE"
echo "== census totals: mapped=$mapped (incl $misroute misroute-class) registered-gaps=$registered unregistered=$unreg =="
[ "$unreg" -eq 0 ] && { echo "CENSUS PASS"; exit 0; }
echo "CENSUS FAIL: $unreg SDK wire paths MISSING-UNREGISTERED (no KD row)"
exit 1
