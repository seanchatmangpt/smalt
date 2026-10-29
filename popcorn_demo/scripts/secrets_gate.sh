#!/usr/bin/env bash
# secrets_gate.sh — fail-closed secrets-hygiene gate for the popcorn_demo
# testbed (W4-13). Receipts/bench corpora are where tokens leak, so the scan
# scope is exactly where text lands: lib, test, scripts, receipts, bench,
# public, README.md, BENCH_*.md.
#
# Patterns (hard-fail, exit 1):
#   JWT-SHAPE      eyJ[A-Za-z0-9_-]{20,}
#   PRIVATE-KEY    PEM "BEGIN ... PRIVATE KEY" blocks
#   USER-PATH      /Users/ absolute paths
#
# Allowlist (each row documented here, the receipt is the evidence):
#   JWT fixtures — the two redaction-test files, pinned by content marker
#   ("f4ke-s1gn4tur3-v4lue" / "faketestsignature_do_not_use"), not line
#   number: live_test.exs moves under concurrent lanes; the fake literals
#   exist nowhere else in scope. A REAL token in those files still refuses
#   (it lacks the fake markers).
#   The gate script itself is excluded (it contains the patterns' literals).
#   USER-PATH — /Users/ paths inside receipts/*.md and bench/ are the
#   sanctioned record: witness receipts name the repo absolute path and bench
#   JSON pins real build/toolchain paths by law. Enforced as ADVO (advisory
#   listing, no refusal) there; hard-fail everywhere else in scope.
#   Current non-corpus USER-PATH allowlist (file:line, reviewed):
#     test/live_tls_test.exs:11   @ca dev CA path
#     scripts/bench_legs.sh:27    shellcheck source directive
#     scripts/close_kd122.sh:21   REPO default
#
# Exit codes: 0 PASS, 1 SECRETS_GATE_REFUSED.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="scripts/secrets_gate.sh"

refuse() { echo "SECRETS_GATE_REFUSED[$1]: $2" >&2; exit 1; }

JWT_RE='eyJ[A-Za-z0-9_-]{20,}'
KEY_RE='BEGIN[A-Za-z0-9 ]*PRIVATE KEY'
PATH_RE='/Users/'

TARGETS=(lib test scripts receipts bench public README.md BENCH_*.md)
[ -d "$ROOT/lib" ] && [ -d "$ROOT/test" ] && [ -d "$ROOT/scripts" ] && \
  [ -d "$ROOT/receipts" ] && [ -d "$ROOT/bench" ] || \
  refuse SCOPE_MISSING "popcorn_demo scope dirs unreadable at $ROOT (fail-closed)"

# grep wrapper: recursive, text-only, excludes _build/deps noise
scan() { # scan <regex> <root...>  -> matches on stdout
  local re="$1"; shift
  grep -rnE --binary-files=without-match "$re" "$@" 2>/dev/null \
    | grep -vE '(^|/)(_build|deps)/' || true
}

# --- JWT-SHAPE + PRIVATE-KEY: hard-fail over the whole scope -----------------
jwt_hits="$(scan "$JWT_RE" $ROOT/lib $ROOT/test $ROOT/scripts $ROOT/receipts $ROOT/bench $ROOT/public $ROOT/README.md $ROOT/BENCH_COOK.md $ROOT/BENCH_LEGS.md $ROOT/BENCH_SPEC.md)"
key_hits="$(scan "$KEY_RE" $ROOT/lib $ROOT/test $ROOT/scripts $ROOT/receipts $ROOT/bench $ROOT/public $ROOT/README.md $ROOT/BENCH_COOK.md $ROOT/BENCH_LEGS.md $ROOT/BENCH_SPEC.md)"

viol=""
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  rel="${hit#"$ROOT"/}"
  # drop the script itself if it ever self-matches
  case "$rel" in "$SELF":*) continue ;; esac
  # allowlist match: content-pinned fake-JWT markers, scoped to the two
  # redaction-fixture files (line numbers drift under concurrent lanes; the
  # literals are unique to these fixtures)
  hitfile="${rel%%:[0-9]*}"
  case "$hitfile" in
    test/popcorn_demo/live_test.exs|test/redact_test.exs)
      case "$hit" in
        *"f4ke-s1gn4tur3-v4lue"*|*"faketestsignature_do_not_use"*) continue 2 ;;
      esac ;;
    receipts/20261021T020000Z-secrets-gate.md)
      # this witness embeds its own flip-proof output; the synthetic token's
      # payload ("flip-proof", b64 "flip-proof") exists nowhere else in scope
      case "$hit" in
        *"eyJzdWIiOiJmbGlwLXByb29mIn0"*) continue 2 ;;
      esac ;;
  esac
  viol="$viol$hit
"
done <<EOF2
$jwt_hits
$key_hits
EOF2

[ -z "$viol" ] || refuse JWT_OR_KEY "JWT-shape / PRIVATE-KEY material outside the redaction-fixture allowlist:
$viol"

# --- USER-PATH: hard-fail outside the sanctioned corpora ---------------------
CORPUS="$ROOT/receipts $ROOT/bench"
NONCORPUS="$ROOT/lib $ROOT/test $ROOT/scripts $ROOT/public"
for f in "$ROOT"/README.md "$ROOT"/BENCH_COOK.md "$ROOT"/BENCH_LEGS.md "$ROOT"/BENCH_SPEC.md; do [ -f "$f" ] && NONCORPUS="$NONCORPUS $f"; done

p_hits="$(scan "$PATH_RE" $NONCORPUS)"
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  rel="${hit#"$ROOT"/}"
  case "$rel" in "$SELF":*) continue ;; esac
  # per-line prefix allowlist (file:line:prefix)
  case "$rel" in
    "test/live_tls_test.exs:11:"* | "scripts/bench_legs.sh:27:"* | "scripts/close_kd122.sh:21:"*) continue ;;
  esac
  refuse USER_PATH "/Users/ absolute path outside sanctioned corpora:
  $hit"
done <<EOF3
$p_hits
EOF3

# advisory census over the sanctioned corpora (listed, never refused)
adv="$(scan "$PATH_RE" $CORPUS | wc -l | tr -d ' ')"
echo "secrets_gate: corpus /Users/ advisory rows (sanctioned receipt/bench paths): $adv"

echo "SECRETS_GATE_PASS: no JWT-shape / PRIVATE-KEY material in scope (content-pinned redaction fixtures); /Users/ paths confined to sanctioned corpora + 3 reviewed non-corpus rows"
exit 0
