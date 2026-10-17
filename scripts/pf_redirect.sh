#!/usr/bin/env bash
# pf_redirect.sh — loopback port-443 -> 9444 TLS-twin redirect via a pf anchor.
#
# Lets real Azure SDKs hit https://management.azure.com:443 on loopback and
# land on the smalt TLS twin (9444) without touching the SDK's TLS stack.
#
# Anchor:  com.smalt/redirect
# Rule:    rdr pass on lo0 proto tcp from any to any port 443 -> 127.0.0.1 port 9444
#
# Every operation shells out to sudo pfctl — the script encodes the exact
# commands and prints them as they run. It performs NO dry-run mode: if you
# run `enable`, you are installing the rule (sudo will prompt).
#
# Usage:
#   pf_redirect.sh status|enable|remove
# Exit: 0 ok, 1 failure.
set -euo pipefail

ANCHOR="com.smalt/redirect"
RULE="rdr pass on lo0 proto tcp from any to any port 443 -> 127.0.0.1 port 9444"

say() { printf '[pf-redirect] %s\n' "$*"; }
die() { printf '[pf-redirect] FAIL: %s\n' "$*" >&2; exit 1; }

need_sudo() {
  [[ $(id -u) -eq 0 ]] || say "requires sudo — running: sudo $*"
}

anchor_is_active() {
  sudo pfctl -a "$ANCHOR" -s rules 2>/dev/null | grep -qF "port 9444"
}

cmd_status() {
  say "anchor: $ANCHOR"
  if sudo pfctl -a "$ANCHOR" -s rules 2>/dev/null | grep -qF "port 9444"; then
    say "state: ACTIVE"
    sudo pfctl -a "$ANCHOR" -s rules | sed 's/^/[pf-redirect]   /'
  else
    say "state: INACTIVE"
  fi
  say "pf enable-state: $(sudo pfctl -s info 2>/dev/null | awk '/Status:/{print $2}')"
  return 0
}

cmd_enable() {
  need_sudo "pfctl -a $ANCHOR -f -"
  if anchor_is_active; then
    say "already active — nothing to do"
    return 0
  fi
  say "loading rule into anchor $ANCHOR:"
  say "  $RULE"
  printf '%s\n' "$RULE" | sudo pfctl -a "$ANCHOR" -f -
  # Enable pf only if it is currently disabled; remember nothing — remove
  # restores the state found at enable time by re-checking at remove time.
  if ! sudo pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then
    say "pf was disabled — enabling (sudo pfctl -e)"
    sudo pfctl -e || die "pfctl -e failed"
  fi
  anchor_is_active || die "rule not present after load"
  say "ACTIVE: $RULE"
}

cmd_remove() {
  need_sudo "pfctl -a $ANCHOR -F all"
  # Capture pf enable-state BEFORE flushing so we restore as found.
  local pf_was_enabled=0
  if sudo pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then
    pf_was_enabled=1
  fi
  if ! anchor_is_active; then
    say "anchor already inactive — nothing to flush"
  else
    say "flushing anchor $ANCHOR (sudo pfctl -a $ANCHOR -F all)"
    sudo pfctl -a "$ANCHOR" -F all
  fi
  if [[ $pf_was_enabled -eq 0 ]]; then
    say "pf was disabled before remove — disabling again (sudo pfctl -d)"
    sudo pfctl -d || die "pfctl -d failed"
  fi
  anchor_is_active && die "rule still present after flush"
  say "REMOVED"
}

case "${1:-}" in
  status) cmd_status ;;
  enable) cmd_enable ;;
  remove) cmd_remove ;;
  *) die "usage: $0 status|enable|remove" ;;
esac
