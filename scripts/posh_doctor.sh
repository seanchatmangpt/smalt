#!/usr/bin/env bash
# posh_doctor.sh — unified preflight doctor (lane 2, gaps/55)
# Exit ladder: 0=green, 1=red (blocking FAIL), 2=degraded (WARN present), 3=loud skip.
set -u

# DX telemetry hook (lane 13, gaps/66): one dx-event per doctor invocation.
DX_TELEMETRY="$(cd "$(dirname "$0")" && pwd)/dx_telemetry.sh"
# shellcheck disable=SC1090
source "$DX_TELEMETRY" 2>/dev/null || dx_event() { :; }
dx_now() { python3 -c 'import time;print(int(time.time()*1000))'; }
DX_T0=$(dx_now)

RED=0 GREEN=0 WARN=0 SKIP=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISK_MIN_MB=20000

ok()   { printf '[DOCTOR-%s] %s: OK\n' "$1" "$2"; GREEN=$((GREEN+1)); }
warn() { printf '[DOCTOR-%s] %s: WARN — %s\n' "$1" "$2" "$3"; WARN=$((WARN+1)); }
fail() { printf '[DOCTOR-%s] %s: FAIL — %s\n' "$1" "$2" "$3"; RED=$((RED+1)); }
skip() { printf '[DOCTOR-%s] %s: SKIP — %s\n' "$1" "$2" "$3"; SKIP=$((SKIP+1)); }

# DOCTOR-1 colima/docker daemon up
if docker info >/dev/null 2>&1; then
  ok 1 "docker daemon (colima) up — server $(docker info --format '{{.ServerVersion}}' 2>/dev/null)"
else
  fail 1 "docker daemon" "docker info failed — run: colima start"
fi

# DOCTOR-2 tools present + versions
for t in go terraform kind kubectl; do
  if command -v "$t" >/dev/null 2>&1; then
    v=$("$t" version 2>/dev/null | head -1)
    ok 2 "tool $t — ${v:-present}"
  else
    fail 2 "tool $t" "not on PATH"
  fi
done

# DOCTOR-3 asdf Elixir 1.20.4 active
if command -v asdf >/dev/null 2>&1; then
  elx=$(asdf current elixir 2>/dev/null | awk '$1=="elixir"{print $2}')
  if [ "$elx" = "1.20.4-otp-29" ] || [ "$elx" = "1.20.4" ]; then
    ok 3 "asdf elixir 1.20.4-otp-29 active"
  elif [ -z "$elx" ]; then
    warn 3 "asdf elixir" "no active version — system mix $(mix --version 2>/dev/null | grep -o 'Elixir.*' | head -1) may fail mix.exs ~> 1.20 — run: asdf install elixir 1.20.4-otp-29"
  else
    warn 3 "asdf elixir" "active $elx, mix.exs requires ~> 1.20 (system mix 1.19.5 fails) — run: asdf install elixir 1.20.4-otp-29"
  fi
else
  warn 3 "asdf" "not on PATH — cannot verify Elixir ~> 1.20"
fi

# DOCTOR-4 substrate plane discrimination
DISC="$ROOT/scripts/court_plane_discriminator.sh"
if [ -x "$DISC" ]; then
  plane=$("$DISC" 2>/dev/null) && ok 4 "substrate plane: $plane" \
    || warn 4 "substrate plane" "$DISC exited nonzero"
else
  skip 4 "substrate plane" "scripts/court_plane_discriminator.sh not present in this repo (loud skip)"
fi

# DOCTOR-5 node disk >= ${DISK_MIN_MB}MB
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx smalt-control-plane; then
  avail_kb=$(docker exec smalt-control-plane df -P / 2>/dev/null | awk 'NR==2{print $4}')
  if [ -n "$avail_kb" ]; then
    avail_mb=$((avail_kb / 1024))
    if [ "$avail_mb" -ge "$DISK_MIN_MB" ]; then
      ok 5 "node disk ${avail_mb}MB available (>= ${DISK_MIN_MB}MB)"
    else
      fail 5 "node disk" "only ${avail_mb}MB available < ${DISK_MIN_MB}MB — prune: docker system prune"
    fi
  else
    skip 5 "node disk" "df failed inside smalt-control-plane"
  fi
else
  skip 5 "node disk" "no kind node smalt-control-plane running"
fi

# DOCTOR-6 kubeconfig current-context sanity
if command -v kubectl >/dev/null 2>&1; then
  ctx=$(kubectl config current-context 2>/dev/null)
  if [ -z "$ctx" ]; then
    warn 6 "kubeconfig" "no current-context set — run: kubectl config use-context kind-smalt"
  elif kubectl config get-contexts -o name 2>/dev/null | grep -qx "$ctx"; then
    ok 6 "kubeconfig current-context: $ctx"
  else
    fail 6 "kubeconfig" "current-context $ctx not found in kubeconfig"
  fi
else
  skip 6 "kubeconfig" "kubectl absent"
fi

# DOCTOR-7 provider binary freshness (adapters mtime vs newest internal/provider/*.go)
PROV_DIR="$ROOT/adapters/terraform-provider-smalt/internal/provider"
if [ -d "$PROV_DIR" ] && compgen -G "$PROV_DIR/*.go" >/dev/null; then
  newest_go=$(ls -t "$PROV_DIR"/*.go 2>/dev/null | head -1)
  bin="$ROOT/adapters/terraform-provider-smalt/terraform-provider-azurerm"
  if [ -x "$bin" ]; then
    if [ "$bin" -nt "$newest_go" ]; then
      ok 7 "provider binary fresh (newer than $(basename "$newest_go"))"
    else
      warn 7 "provider binary" "stale vs $(basename "$newest_go") — rebuild provider"
    fi
  else
    skip 7 "provider binary" "no built binary at $bin"
  fi
else
  skip 7 "provider freshness" "no internal/provider/*.go in this repo (loud skip)"
fi

echo "----"
printf 'DOCTOR SUMMARY: ok=%d warn=%d fail=%d skip=%d\n' "$GREEN" "$WARN" "$RED" "$SKIP"
DX_MS=$(( $(dx_now) - DX_T0 ))
if [ "$RED" -gt 0 ]; then dx_event doctor fail "$DX_MS"; exit 1; fi
if [ "$GREEN" -eq 0 ]; then dx_event doctor skip "$DX_MS"; exit 3; fi
if [ "$WARN" -gt 0 ]; then dx_event doctor pass "$DX_MS"; exit 2; fi
dx_event doctor pass "$DX_MS"
exit 0
