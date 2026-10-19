#!/usr/bin/env bash
# Deterministic dev-environment bootstrap for the smalt canonical checkout.
#
# Usage:
#   eval "$(scripts/dev_env.sh)"          # exports into the current shell
#   scripts/dev_env.sh --check            # validate everything + doctor pass
#
# Exports (all idempotent, stable across runs):
#   SMALT_SB_SHARED_KEY  deterministic per-host SAS shared key
#   SMALT_SDK_ROOT       vendored Azure SDK node_modules root
#   SMALT_REPO           repo root (dir containing mix.exs)
#   SMALT_TLS_CERTFILE / SMALT_TLS_KEYFILE  dev TLS leaf (when minted)
#   SSL_CERT_FILE        dev CA anchor (when minted; Go/Apple chain trust)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMALT_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

die() { echo "[dev_env] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. SMALT_SB_SHARED_KEY — deterministic per-host dev key.
# sha256(hostname + "smalt-dev-sb") base64-encoded (44 chars, >= 32 bytes).
# Stable across runs so census/SDK probes and the substrate agree without a
# shared-secret ceremony. Substrate contract (scripts/substrate.sh): it reads
# SMALT_SB_SHARED_KEY from the environment, defaulting to the historical
# pinned key "ws8sharedkey" when unset — source this file (or export the key
# yourself) before `substrate.sh up` if your probes use the per-host key;
# see lib/smalt/messaging/amqp/connection.ex.
# ---------------------------------------------------------------------------
export SMALT_SB_SHARED_KEY="$(printf '%s' "$(hostname)smalt-dev-sb" | openssl dgst -sha256 -binary | base64)"

# ---------------------------------------------------------------------------
# 2. SMALT_SDK_ROOT — vendored SDK node_modules convention.
# ---------------------------------------------------------------------------
# In-repo default (v26.10.19): the SDK node_modules home is verification/ts
# (V261019-08). A user-provided SMALT_SDK_ROOT always wins.
DEFAULT_SDK_ROOT="$SMALT_REPO_ROOT/verification/ts/node_modules"
if [ -n "${SMALT_SDK_ROOT:-}" ]; then
  [ -d "$SMALT_SDK_ROOT" ] || die "SMALT_SDK_ROOT=$SMALT_SDK_ROOT is set but not a directory."
elif [ -d "$DEFAULT_SDK_ROOT" ]; then
  export SMALT_SDK_ROOT="$DEFAULT_SDK_ROOT"
else
  # LOUD WARN (never a silent default): leave SMALT_SDK_ROOT UNSET until the
  # verification/ts deps land; census legs SKIP loudly without it.
  echo "[dev_env] WARNING: SMALT_SDK_ROOT not set and verification/ts/node_modules not found (V261019-08)." >&2
  echo "[dev_env] Install it with: (cd verification/ts && npm i @azure/cosmos @azure/event-hubs) or export SMALT_SDK_ROOT=<node_modules dir>" >&2
fi

# ---------------------------------------------------------------------------
# 3. SMALT_REPO — cwd when it contains mix.exs.
# ---------------------------------------------------------------------------
if [ -n "${SMALT_REPO:-}" ]; then
  [ -f "$SMALT_REPO/mix.exs" ] || die "SMALT_REPO=$SMALT_REPO is set but has no mix.exs."
elif [ -f "$PWD/mix.exs" ]; then
  export SMALT_REPO="$PWD"
else
  die "SMALT_REPO: no mix.exs in $PWD — run from the repo root (or export SMALT_REPO=<repo>)."
fi

# ---------------------------------------------------------------------------
# 4. TLS material — minted by scripts/gen_dev_cert.sh.
# ---------------------------------------------------------------------------
if [ -f "$SMALT_REPO/.smalt/tls/dev-cert.pem" ] && [ -f "$SMALT_REPO/.smalt/tls/dev-key.pem" ]; then
  export SMALT_TLS_CERTFILE="$SMALT_REPO/.smalt/tls/dev-cert.pem"
  export SMALT_TLS_KEYFILE="$SMALT_REPO/.smalt/tls/dev-key.pem"
  export SSL_CERT_FILE="$SMALT_REPO/.smalt/tls/ca-cert.pem"
fi

if [ "${1:-}" = "--check" ]; then
  echo "[dev_env] --check: validating"
  echo "  SMALT_SB_SHARED_KEY = ${SMALT_SB_SHARED_KEY:0:8}... ($(printf '%s' "$SMALT_SB_SHARED_KEY" | wc -c | tr -d ' ') bytes)"
  echo "  SMALT_SDK_ROOT      = $SMALT_SDK_ROOT"
  ls "$SMALT_SDK_ROOT/@azure" >/dev/null 2>&1 || die "no @azure packages under $SMALT_SDK_ROOT"
  echo "  SMALT_REPO          = $SMALT_REPO"
  if [ -n "${SMALT_TLS_CERTFILE:-}" ]; then
    # Same freshness policy as scripts/gen_dev_cert.sh: expired or expiring
    # within 30 days (2592000s) counts as invalid, so --check agrees with the
    # minter instead of accepting a cert gen_dev_cert.sh would remint.
    openssl x509 -in "$SMALT_TLS_CERTFILE" -noout -subject -enddate -checkend 2592000 >/dev/null 2>&1 \
      || die "SMALT_TLS_CERTFILE=$SMALT_TLS_CERTFILE is not parseable, or expires within 30 days (re-mint with scripts/gen_dev_cert.sh)"
    echo "  SMALT_TLS_CERTFILE  = $SMALT_TLS_CERTFILE"
    echo "  SMALT_TLS_KEYFILE   = $SMALT_TLS_KEYFILE"
    echo "  SSL_CERT_FILE       = $SSL_CERT_FILE"
  else
    echo "  SMALT_TLS_*         = unset (mint with scripts/gen_dev_cert.sh)"
  fi
  echo "[dev_env] env validation passed; running scripts/doctor.py"
  python3 "$SMALT_REPO/scripts/doctor.py"
  exit $?
fi

# eval-able env block.
cat <<EOF
export SMALT_SB_SHARED_KEY="$SMALT_SB_SHARED_KEY"
export SMALT_SDK_ROOT="$SMALT_SDK_ROOT"
export SMALT_REPO="$SMALT_REPO"
${SMALT_TLS_CERTFILE:+export SMALT_TLS_CERTFILE="$SMALT_TLS_CERTFILE"
export SMALT_TLS_KEYFILE="$SMALT_TLS_KEYFILE"
export SSL_CERT_FILE="$SSL_CERT_FILE"
}# Then run consumers, e.g. (verification/ successors, V261019-08/09):
#   node verification/ts/census-run.mjs
EOF
