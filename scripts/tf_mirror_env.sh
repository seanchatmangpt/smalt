#!/usr/bin/env bash
# scripts/tf_mirror_env.sh — sourced by tf_smoke.sh / tf_plan_check.sh.
# NOT executable standalone. Requires $ROOT set to the repo root by the sourcer.
#
# M7: attempts a mirror refresh (scripts/tf_provider_mirror.sh) on EVERY run —
# terraform providers mirror is its own integrity validator (registry
# checksums, re-download on mismatch). If the connectivity probe fails, an
# existing mirror is trusted only LOUDLY (offline-trusted).
#
# M8: the terraform CLI rc is generated at run time into a mktemp path with
# the REAL mirror location, so no absolute /Users/... path is ever committed.
#
# Sets, for the sourcer:
#   TF_CLI_CONFIG_FILE  — temp rc (caller should clean it up on exit)
#   TF_MIRROR_RC        — same path, for trap-based cleanup
#   TF_MIRROR_MODE      — "online-revalidated" | "offline-trusted" | "none"
#   TF_MIRROR_REFRESH_LOG — refresh log path

tf_mirror_env_setup() {
  TF_MIRROR_REFRESH_LOG="${TMPDIR:-/tmp}/tf-mirror-refresh.$$"
  local mirror_dir="$ROOT/test/terraform_fixture/provider-mirror"

  # M7 amendment (2026-10-16, zero-dialog trust lane): the mirror script is
  # now self-validating (terraform providers mirror re-download + registry
  # checksums + re-sign receipt at provider-mirror/.smalt-resign-receipt.json,
  # mtime-gated). A receipt NEWER than the mirror's zips means the mirror was
  # validated and re-signed AFTER the last download — re-running the mirror
  # here would re-download PRISTINE zips and re-trigger the observed
  # flaky-pristine-install race (witnessed 3x this lane). Reuse it instead.
  local receipt="$mirror_dir/.smalt-resign-receipt.json"
  local newest_zip
  newest_zip=$(find "$mirror_dir" -name 'terraform-provider-*.zip' -newer "$receipt" 2>/dev/null | head -1)
  if [ -f "$receipt" ] && [ -z "$newest_zip" ] && [ "${TF_MIRROR_FORCE:-0}" != "1" ]; then
    TF_MIRROR_MODE="receipt-revalidated"
    TF_MIRROR_RC="$(mktemp "${TMPDIR:-/tmp}/tf-provider-mirror.XXXXXX")"
    cat > "$TF_MIRROR_RC" <<EOF
# Generated at run time by scripts/tf_mirror_env.sh — regenerate, do not commit.
provider_installation {
  filesystem_mirror {
    path    = "$mirror_dir"
    include = ["registry.terraform.io/*/*"]
  }
  direct {
    exclude = ["registry.terraform.io/*/*"]
  }
}
EOF
    export TF_CLI_CONFIG_FILE="$TF_MIRROR_RC"
    export TF_MIRROR_RC TF_MIRROR_MODE
    echo "[tf-mirror-env] mirror mode: $TF_MIRROR_MODE (receipt mtime-gated reuse); rc (temp): $TF_CLI_CONFIG_FILE"
    tf_mirror_env_trust_env
    return 0
  fi

  TF_MIRROR_MODE="none"
  if bash "$ROOT/scripts/tf_provider_mirror.sh" >"$TF_MIRROR_REFRESH_LOG" 2>&1; then
    TF_MIRROR_MODE="$(sed -n 's/.*mode: //p' "$TF_MIRROR_REFRESH_LOG" | tail -n 1)"
    TF_MIRROR_MODE="${TF_MIRROR_MODE:-online-revalidated}"
    cat "$TF_MIRROR_REFRESH_LOG" # loud provenance in the run output
  else
    echo "[tf-mirror-env] mirror refresh failed (log below); continuing with" >&2
    echo "[tf-mirror-env] whatever install path terraform falls back to:" >&2
    cat "$TF_MIRROR_REFRESH_LOG" >&2
    return 1
  fi

  # Runtime-generated rc (M8): temp path, real mirror location, never committed.
  # BSD mktemp requires trailing X's for uniqueness — no .rc suffix.
  TF_MIRROR_RC="$(mktemp "${TMPDIR:-/tmp}/tf-provider-mirror.XXXXXX")"
  cat > "$TF_MIRROR_RC" <<EOF
# Generated at run time by scripts/tf_mirror_env.sh — regenerate, do not commit.
provider_installation {
  filesystem_mirror {
    path    = "$mirror_dir"
    include = ["registry.terraform.io/*/*"]
  }
  direct {
    exclude = ["registry.terraform.io/*/*"]
  }
}
EOF
  export TF_CLI_CONFIG_FILE="$TF_MIRROR_RC"
  export TF_MIRROR_RC TF_MIRROR_MODE TF_MIRROR_REFRESH_LOG
  echo "[tf-mirror-env] mirror mode: $TF_MIRROR_MODE; rc (temp): $TF_CLI_CONFIG_FILE"

  tf_mirror_env_trust_env
}

# Zero-dialog trust path (2026-10-16): export the shim + leaf-pin env for
# terraform stages, mirroring scripts/smalt-tf. The mirror re-sign stage
# (tf_provider_mirror.sh, marker SHIM-COURT) already made the binaries
# injection-tolerant (ad-hoc signature); DELIVERY to the provider process is
# via scripts/tf_provider_wrap.sh (terraform strips DYLD_* from plugin env —
# witnessed). Exports kept for direct-Go/standalone consumers.
tf_mirror_env_trust_env() {
  if [ "$(uname)" = "Darwin" ]; then
    local shim_dylib="$ROOT/scripts/trust_shim/smalt_trust_shim.dylib"
    [ -f "$shim_dylib" ] || bash "$ROOT/scripts/trust_shim/build.sh" >&2 || true
    if [ -f "$shim_dylib" ] && [ -f "$ROOT/.smalt/tls/dev-cert.pem" ]; then
      SMALT_LEAF_SHA256="$(openssl x509 -in "$ROOT/.smalt/tls/dev-cert.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':')"
      if [ -n "$SMALT_LEAF_SHA256" ]; then
        export SMALT_LEAF_SHA256
        SMALT_CA_SHA256="$SMALT_LEAF_SHA256" # back-compat env (shim reads either)
        export SMALT_CA_SHA256
        SMALT_CA_FILE="$ROOT/.smalt/tls/ca-cert.pem" # v2: anchor-append surface
        export SMALT_CA_FILE
        export DYLD_INSERT_LIBRARIES="$shim_dylib"
        echo "[tf-mirror-env] trust shim active (pinned leaf fp ${SMALT_LEAF_SHA256:0:16}...)"
      fi
    fi
    if [ -f "$shim_dylib" ] && [ -z "${DYLD_INSERT_LIBRARIES:-}" ]; then
      echo "[tf-mirror-env] FAULT: no zero-dialog trust path (shim build failed) — remediation:" >&2
      echo "[tf-mirror-env]   bash $ROOT/scripts/trust_shim/build.sh" >&2
      echo "[tf-mirror-env]   or (explicit opt-in): $ROOT/scripts/tf_trust_setup.sh trust" >&2
      return 1
    fi
  fi
  return 0
}

tf_mirror_env_cleanup() {
  [ -n "${TF_MIRROR_RC:-}" ] && rm -f "$TF_MIRROR_RC"
  [ -n "${TF_MIRROR_REFRESH_LOG:-}" ] && rm -f "$TF_MIRROR_REFRESH_LOG"
}
