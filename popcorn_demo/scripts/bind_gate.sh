#!/usr/bin/env bash
# bind_gate.sh — fail-closed loopback-only binding gate (W2-12).
#
# Verifies the running substrate's control (9443), data (8443) and TLS-twin
# (9444) security surfaces are bound to 127.0.0.1 ONLY. The substrate's
# posture is loopback-only-by-default (lib/smalt/application.ex bind_ip/0:
# nil -> {127,0,0,1}, KD-54). The real config key is :bind_ip — there is no
# :bind_all_interfaces key in this tree; the accessor is
# Smalt.Config.bind_ip/0 (env-first, nilable).
#
# Refusal classes (typed, exit 1):
#   CONFIG_MISSING         static source files unreadable
#   BIND_DEFAULT_DRIFT     accessor/default/wildcard-literal drift in source
#   LSOF_EMPTY             lsof census empty -> cannot verify (fail-closed)
#   LISTENER_ABSENT        none of the checked ports listening
#   NON_LOOPBACK_LISTENER  a checked listener is bound off 127.0.0.1/::1
#
# Exit codes: 0 PASS, 1 BIND_GATE_REFUSED, 2 usage.
#
# Usage: bind_gate.sh [port ...]   (default: 9443 8443 9444)
#        Ports are positional so the non-vacuity flip proof can aim the same
#        lsof parse at a deliberately-wildcard listener it boots itself.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG_EX="$ROOT/lib/smalt/config.ex"
APPLICATION_EX="$ROOT/lib/smalt/application.ex"

refuse() { echo "BIND_GATE_REFUSED[$1]: $2" >&2; exit 1; }

# --- Stage 1: source-of-truth assertion (static, grep-fenced) ---------------
[ -r "$CONFIG_EX" ] || refuse CONFIG_MISSING "cannot read $CONFIG_EX"
[ -r "$APPLICATION_EX" ] || refuse CONFIG_MISSING "cannot read $APPLICATION_EX"

# accessor must remain env-first and nilable (no wildcard default)
grep -n 'def bind_ip, do: System.get_env("SMALT_BIND_IP") || Application.get_env(:smalt, :bind_ip)' \
  "$CONFIG_EX" >/dev/null || \
  refuse BIND_DEFAULT_DRIFT "lib/smalt/config.ex bind_ip/0 no longer the env-first nilable accessor"

# application.ex must resolve nil -> {127,0,0,1}
grep -n -A1 'nil ->' "$APPLICATION_EX" | grep -q '{127, 0, 0, 1}' || \
  refuse BIND_DEFAULT_DRIFT "lib/smalt/application.ex no longer resolves bind_ip nil -> {127,0,0,1}"

# no wildcard bind literal outside the historical KD-54 comment
# strip Elixir comments before the literal check (KD-54 comment mentions
# 0.0.0.0 historically; only CODE wildcards refuse)
CODE="$(sed 's/#.*//' "$APPLICATION_EX" "$CONFIG_EX")"
if printf '%s\n' "$CODE" | grep -nE '0\.0\.0\.0|\{0,0,0,0\}|\{0, 0, 0, 0\}'; then
  refuse BIND_DEFAULT_DRIFT "wildcard bind literal present in config.ex/application.ex code"
fi

# --- Stage 2: runtime listener census (lsof, fail-closed) -------------------
PORTS="${*:-9443 8443 9444}"
PORTS="${PORTS:-9443 8443 9444}"   # empty-arg guard falls back to law ports
[ "$PORTS" = "9443 8443 9444" ] || echo "bind_gate: non-default port set: $PORTS" >&2

CENSUS="$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null)"
[ -n "$CENSUS" ] || refuse LSOF_EMPTY "lsof LISTEN census empty; cannot verify (fail-closed)"

seen=0
for port in $PORTS; do
  rows="$(printf '%s\n' "$CENSUS" | awk -v p=":${port}\$" '$9 ~ p {print}')"
  [ -n "$rows" ] || { echo "BIND_GATE_REFUSED[LISTENER_ABSENT]: port ${port} not listening (fail-closed)" >&2; exit 1; }
  seen=$((seen + 1))
  # name column (col 9) must be loopback addr:port; macOS renders IPv6
  # loopback as [::1]:port or localhost:port
  bad="$(printf '%s\n' "$rows" | awk '{print $9}' | grep -vE '^(127\.0\.0\.1|localhost|\[::1\]):' || true)"
  if [ -n "$bad" ]; then
    refuse NON_LOOPBACK_LISTENER "port ${port} bound off-loopback: $(echo "$bad" | tr '\n' ' ')"
  fi
  echo "bind_gate: port ${port} loopback OK ($(printf '%s\n' "$rows" | awk '{print $9}' | tr '\n' ' '))"
done

[ "$seen" -gt 0 ] || refuse LISTENER_ABSENT "none of the checked ports listening; substrate down? (fail-closed)"

echo "BIND_GATE_PASS: ${seen} surface(s) loopback-bound; static default asserted (config.ex accessor + application.ex nil->{127,0,0,1})"
exit 0
