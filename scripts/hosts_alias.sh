#!/usr/bin/env bash
# hosts_alias.sh — /etc/hosts loopback aliases for the smalt TLS twin.
#
# Adds a marked block:
#   # BEGIN smalt-zero-touch
#   127.0.0.1 management.azure.com
#   127.0.0.1 login.microsoftonline.com
#   # END smalt-zero-touch
#
# First enable backs /etc/hosts up to /etc/hosts.smalt.bak (never overwrites
# an existing backup). Remove deletes ONLY the marked block.
#
# All writes go through sudo tee — the script prints the sudo context as it
# runs. No dry-run mode: running `enable` edits /etc/hosts (sudo prompts).
#
# Usage: hosts_alias.sh status|enable|remove
# Exit: 0 ok, 1 failure.
set -euo pipefail

HOSTS="/etc/hosts"
BACKUP="/etc/hosts.smalt.bak"
BEGIN="# BEGIN smalt-zero-touch"
END="# END smalt-zero-touch"

say() { printf '[hosts-alias] %s\n' "$*"; }
die() { printf '[hosts-alias] FAIL: %s\n' "$*" >&2; exit 1; }

block_present() {
  grep -qF "$BEGIN" "$HOSTS"
}

cmd_status() {
  if block_present; then
    say "state: ACTIVE"
    sudo sed -n "/${BEGIN}/,/${END}/p" "$HOSTS" | sed 's/^/[hosts-alias]   /'
  else
    say "state: INACTIVE (no $BEGIN block in $HOSTS)"
  fi
  return 0
}

cmd_enable() {
  if block_present; then
    say "already present — nothing to do"
    return 0
  fi
  if ! sudo test -f "$BACKUP"; then
    say "backing up $HOSTS -> $BACKUP (sudo cp)"
    sudo cp "$HOSTS" "$BACKUP"
  else
    say "backup $BACKUP already exists — leaving it untouched"
  fi
  say "appending marked block to $HOSTS via sudo tee -a"
  printf '\n%s\n127.0.0.1 management.azure.com\n127.0.0.1 login.microsoftonline.com\n%s\n' \
    "$BEGIN" "$END" | sudo tee -a "$HOSTS" >/dev/null
  block_present || die "block not present after write"
  say "ACTIVE:"
  sudo sed -n "/${BEGIN}/,/${END}/p" "$HOSTS" | sed 's/^/[hosts-alias]   /'
}

cmd_remove() {
  if ! block_present; then
    say "already absent — nothing to do"
    return 0
  fi
  say "deleting marked block from $HOSTS (sudo + sed, BEGIN..END only)"
  sudo sed -i.bak-smalt-tmp "/^${BEGIN}$/,/^${END}$/d" "$HOSTS"
  sudo rm -f "$HOSTS.bak-smalt-tmp"
  block_present && die "block still present after remove"
  say "REMOVED"
}

case "${1:-}" in
  status) cmd_status ;;
  enable) cmd_enable ;;
  remove) cmd_remove ;;
  *) die "usage: $0 status|enable|remove" ;;
esac
