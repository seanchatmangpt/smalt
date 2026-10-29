#!/usr/bin/env bash
# egress_gate.sh — fail-closed zero-external-egress gate for the popcorn_demo
# testbed (S3).
#
# Stage 1 (static, grep-class) over <root>/lib + <root>/public:
#   URI-DNS      an http(s):// URL literal whose host is not allowed. Matched
#                per-URL (grep -o), so a line mixing loopback + foreign URLs
#                still refuses. Allowlist classes, each narrow, content-pinned:
#                  a) token scopes of the exact shape <host>/.default —
#                     OAuth audience identifiers handed to the loopback STS,
#                     never dialed;
#                  b) the EventGrid delivery-endpoint fixture, pinned to the
#                     exact file+URL lib/popcorn_demo/live_eg.ex :
#                     https://example.com/hook — a JSON payload value
#                     asserted against, never fetched;
#                  c) URLs on `//`-comment lines of the generated bundle
#                     public/out/*.mjs — compiler-emitted provenance/doc
#                     comments, never executed. URL/IP literals in bundle
#                     CODE still refuse; the only code-form IP literals in
#                     the shipped bundle are the inet canonicalization
#                     constants "0.0.0.0"/"0.0.0.1" (exact-value pin, not
#                     routable destinations).
#   URI-HOSTVAR  host interpolation entering a URI literal (`://<host>#{`)
#                — DNS names must never enter URI construction via variables
#   IP-LITERAL   a dotted-quad literal that is not loopback 127.x, except
#                the exact inet constants 0.0.0.0/0.0.0.1 in public/out
#   DNS-NAME     DNS-name literal in connect/URI context
#                (:gen_tcp.connect / %URI{ / host:)
# Any hit -> typed refusal, exit 1.
#
# Stage 2 (runtime): if <root>/lib/popcorn_demo/concurrency.ex exists, run
# the S1 ramp (EGRESS_RAMP_CMD override; default mix run on the pinned
# EGRESS_TOOLCHAIN 1.20.3-otp-28, lane-private MIX_BUILD_ROOT=_build-egress)
# in its OWN PROCESS GROUP under a 1 Hz lsof sampler scoped to exactly that
# pgid's pids — unrelated OS traffic can never contaminate the verdict. The
# stage passes only if ALL of: (i) ramp exits within the 12 min bounded poll,
# (ii) the ramp row shows verified > 0 AND breaches == 0 (a breached or
# crashed ramp can never certify "no egress"), and (iii) zero non-loopback
# remote sockets were observed on ramp pids. Missing concurrency.ex = LOUD
# skip (exit 3, RAMP_ABSENT).
#
# Non-vacuity, both directions (witnessed in the S3 receipt):
#   - static flip: gate aimed at a /tmp root with a deliberate non-loopback
#     URL -> exit 1.
#   - runtime flip: a deliberate non-loopback :gen_tcp.connect under
#     EGRESS_RAMP_CMD -> NON_LOOPBACK_SOCKET refusal, exit 1 (the sampler
#     detector is proven to fire).
#   - ramp-verdict flip: a ramp row with verified=0 or breaches>0 ->
#     RAMP_NOT_VERIFIED.
#
# NOTE: never edit this file while a gate run is in flight — bash reads the
# script incrementally and a mid-run edit corrupts the running parse (F9).
#
# Exit codes: 0 PASS, 1 EGRESS_GATE_REFUSED, 2 usage, 3 RAMP_ABSENT (loud).
#
# Usage: egress_gate.sh [--static] [target-root]
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_ROOT="$(cd "$SELF_DIR/.." && pwd)"
MODE=runtime
ROOT="$DEFAULT_ROOT"
while [ $# -gt 0 ]; do
  case "$1" in
    --static) MODE=static; shift ;;
    -h|--help) sed -n '2,60p' "$0"; exit 2 ;;
    -*) echo "usage: egress_gate.sh [--static] [target-root]" >&2; exit 2 ;;
    *) ROOT="$1"; shift ;;
  esac
done

refuse() { echo "EGRESS_GATE_REFUSED[$1]: $2" >&2; exit 1; }

[ -d "$ROOT/lib" ] && [ -d "$ROOT/public" ] || \
  refuse SCOPE_MISSING "target root $ROOT lacks lib/ + public/ (fail-closed)"

# --- Stage 1: static grep-class scan ----------------------------------------

# URL literals as "file:line:URL" rows (build/deps noise excluded)
urls() {
  grep -rnoE --binary-files=without-match \
    'https?://[^"'"'"'` )<>{}]+' "$ROOT/lib" "$ROOT/public" 2>/dev/null \
    | grep -vE '(^|/)(_build|deps|node_modules|\.out)/' || true
}

# true when the source line of a "path:line:URL" row is a // comment.
# Row shape: <path>:<line>:<url>; path may itself contain colons on macOS
# is impossible here (only :line:url after the file), so split on the last
# two colon-separated fields with awk.
comment_line() {
  local row="$1" f l rest
  f=""
  for cand in "$ROOT"/public/out/*; do
    [ -f "$cand" ] || continue
    case "$row" in
      "$cand":*) f="$cand"; break ;;
    esac
  done
  [ -n "$f" ] || return 1
  rest="${row#"$f":}"
  l="${rest%%:*}"
  [ -f "$f" ] || return 1
  sed -n "${l}p" "$f" 2>/dev/null | grep -qE '^[[:space:]]*//'
}

allowed_url() { # $1 = file:line:URL row
  case "$1" in
    # loopback hosts only
    *'://127.0.0.1'*|*'://localhost'*|*'://[::1]'*) return 0 ;;
    # ellipsis doc-comment URLs (https://…)
    *'://…'*) return 0 ;;
    # (a) token scopes <host>/.default
    *'/.default'*) return 0 ;;
    # (b) EventGrid endpointUrl fixture, pinned to file+exact URL
    */lib/popcorn_demo/live_eg.ex:*'https://example.com/hook') return 0 ;;
  esac
  # (c) // comment lines in the generated bundle only
  case "$1" in
    */public/out/*) comment_line "$1" && return 0 ;;
  esac
  return 1
}

viol=""
while IFS= read -r row; do
  [ -n "$row" ] || continue
  allowed_url "$row" && continue
  viol="$viol$row
"
done <<EOF1
$(urls)
EOF1
[ -z "$viol" ] || refuse URI_DNS "non-loopback URL literal outside the documented allowlist (.../.default token scopes; live_eg.ex example.com/hook fixture; public/out // comment lines):
$viol"

# host interpolation entering URI construction (loopback hosts excluded)
h=$(grep -rnoE --binary-files=without-match 'https?://[^/"'"'"' ]*#\{' \
      "$ROOT/lib" "$ROOT/public" 2>/dev/null \
    | grep -vE '(^|/)(_build|deps|node_modules|\.out)/' \
    | grep -vE '://(127\.0\.0\.1|localhost|\[::1\]):' || true)
[ -z "$h" ] || refuse URI_HOSTVAR "variable host interpolated into a URI literal (DNS names must never enter URI construction):
$h"

# non-loopback IP literals; public/out may carry ONLY the exact inet
# canonicalization constants 0.0.0.0 / 0.0.0.1 (not routable destinations)
ip=$(grep -rnoE --binary-files=without-match \
       '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
       "$ROOT/lib" "$ROOT/public" 2>/dev/null \
     | grep -vE '(^|/)(_build|deps|node_modules|\.out)/' \
     | grep -vE ':127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' \
     | grep -vE ':(0\.0\.0\.0|0\.0\.0\.1)$' \
     | grep -v '/public/out/' || true)
[ -z "$ip" ] || refuse IP_LITERAL "non-loopback IP address literal:
$ip"

# DNS-name literal in connect/URI context
dns=$(grep -rnE --binary-files=without-match \
        '(:gen_tcp\.connect|%URI\{|host:[[:space:]]*)["'"'"']?[A-Za-z0-9-]+\.[A-Za-z0-9-]+' \
        "$ROOT/lib" "$ROOT/public" 2>/dev/null \
      | grep -vE '(^|/)(_build|deps|node_modules|\.out)/' \
      | grep -vE '"(127\.0\.0\.1|localhost)"' || true)
[ -z "$dns" ] || refuse DNS_NAME "DNS-name literal in connect/URI context:
$dns"

echo "egress_gate stage1: static scan PASS over $ROOT/lib + $ROOT/public (URI-DNS / URI-HOSTVAR / IP-LITERAL / DNS-NAME; allowlist classes a-c)"
[ "$MODE" = static ] && { echo "EGRESS_GATE_PASS (static)"; exit 0; }

# --- Stage 2: runtime lsof sampling over the S1 ramp -------------------------
RAMP_EX="$ROOT/lib/popcorn_demo/concurrency.ex"
if [ ! -f "$RAMP_EX" ]; then
  echo "EGRESS_GATE_SKIP[RAMP_ABSENT]: $RAMP_EX not landed — stage 2 skipped LOUDLY (exit 3); rerun when the S1 ramp lands"
  exit 3
fi

TOOLCHAIN="${EGRESS_TOOLCHAIN:-$HOME/.asdf/installs/elixir/1.20.3-otp-28}"
export PATH="$TOOLCHAIN/bin:$PATH"
[ -x "$TOOLCHAIN/bin/mix" ] || refuse TOOLCHAIN_MISSING "pinned Elixir 1.20.3-otp-28 not found at $TOOLCHAIN (set EGRESS_TOOLCHAIN)"

# ramp in its own process group so the sampler can scope to it exactly
set -m
RAMP_CMD="${EGRESS_RAMP_CMD:-cd $ROOT && MIX_BUILD_ROOT=_build-egress mix run -e 'IO.inspect(PopcornDemo.Concurrency.ramp(64), label: :s1_ramp)'}"
RAMP_LOG="$(mktemp /tmp/egress_ramp.XXXXXX)"
SAMPLE_FILE="$(mktemp /tmp/egress_sample.XXXXXX)"

( eval "$RAMP_CMD" ) >"$RAMP_LOG" 2>&1 &
RAMP_PID=$!
PGID="$(ps -o pgid= -p "$RAMP_PID" | tr -d ' ')"

# sampler: 1 Hz, rows scoped to the ramp process group ONLY
( while kill -0 "$RAMP_PID" 2>/dev/null; do
    pids="$(pgrep -g "$PGID" 2>/dev/null | tr '\n' '|')"
    if [ -n "$pids" ]; then
      lsof -i -n -P 2>/dev/null | awk -v pids="^(${pids%|})\$" 'NR==1 || $2 ~ pids'
    fi
    sleep 1  # SLEEP-CLASS: POLL-STEP (1Hz sampler tick, bounded lsof poll)
  done ) >> "$SAMPLE_FILE" 2>/dev/null &
SAMPLER_PID=$!

# bounded poll: up to 12 min for the ramp process to exit
DEADLINE=$(( $(date +%s) + 720 ))
while kill -0 "$RAMP_PID" 2>/dev/null; do
  [ "$(date +%s)" -lt "$DEADLINE" ] || {
    kill -9 "$RAMP_PID" 2>/dev/null; wait "$RAMP_PID" 2>/dev/null
    kill "$SAMPLER_PID" 2>/dev/null; wait "$SAMPLER_PID" 2>/dev/null
    refuse RAMP_TIMEOUT "S1 ramp exceeded the 12 min bounded poll — killed; sampler rows at $SAMPLE_FILE, ramp log $RAMP_LOG"
  }
  sleep 2  # SLEEP-CLASS: POLL-STEP (2s tick inside the deadline-checked kill -0 poll)
done
kill "$SAMPLER_PID" 2>/dev/null; wait "$SAMPLER_PID" 2>/dev/null

# verdict gate (F4): the ramp must produce a row, and the row must show
# verified > 0 AND breaches == 0 — a breached/crashed/silent ramp can never
# certify "zero egress during verified work"
RAMP_ROW="$(sed -n '/s1_ramp:/,$p' "$RAMP_LOG" || true)"
[ -n "$RAMP_ROW" ] || refuse RAMP_NO_ROW "the S1 ramp produced no s1_ramp row (crashed or silent) — runtime stage refuses fail-closed rather than passing on a dead ramp
(ramp log: $RAMP_LOG; sampler rows: $SAMPLE_FILE)"
printf '%s\n' "$RAMP_ROW" | grep -qE 'verified: [1-9][0-9]*' || \
  refuse RAMP_NOT_VERIFIED "ramp row shows verified == 0 — no verified work, no egress certification:
$RAMP_ROW"
printf '%s\n' "$RAMP_ROW" | grep -qE 'breaches: 0[,}%]' || \
  refuse RAMP_NOT_VERIFIED "ramp row shows breaches > 0 — invariance breach, egress certification refused:
$RAMP_ROW"

# read-back: drop header rows and loopback/wildcard rows; any survivor is a
# non-loopback remote socket held by a ramp-group process during the run
foreign="$(grep -vE '^COMMAND' "$SAMPLE_FILE" \
           | grep -vE '127\.0\.0\.1|\[::1\]|localhost|\*:' || true)"
if [ -n "$foreign" ]; then
  refuse NON_LOOPBACK_SOCKET "lsof sampler observed non-loopback remote sockets on ramp-group processes during the S1 ramp:
$foreign
(ramp log: $RAMP_LOG)"
fi
echo "egress_gate stage2: ramp row verified>0 + breaches=0; pgid-scoped sampler saw 0 non-loopback remote sockets"
echo "$RAMP_ROW"
echo "EGRESS_GATE_PASS (static+runtime)"
exit 0
