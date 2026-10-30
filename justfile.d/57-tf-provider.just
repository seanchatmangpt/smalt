# ============================================================================
# 57-tf-provider.just — terraform-provider-smalt build/install/court (lane 14,
# v26.10.22 wave).
#
# Engineer path:
#   just provider-build     (mix escript.build in terraform-provider-smalt)
#   just provider-install   (build + scripts/build_install.sh + tfrc.sh)
#   just provider-court-elixir (kind ladder -> healthz poll -> build -> court;
#                              Elixir spike — NOT the GA admission path)
#   just provider-court     (DEPRECATED alias -> provider-court-elixir;
#                           GA path is just posh-court in 58-posh.just)
#   just provider-status / provider-clean
#
# F13 reconciliation (v26.10.30): the Elixir spike (this module) and the Go
# path (58-posh.just) overlap but do not collide — distinct rc writers
# (terraform-provider-smalt/.terraformrc here vs tmp/posh/tfrc in 58) and
# distinct binaries (mix escript vs Go plugin). posh-court is the GA court.
#
# TFROOT: for an IMPORTED module, justfile_directory() is already the repo
# root (imports merge into the root namespace); parent_directory would
# resolve outside the repo (KROOT witness: justfile.d/52-kind.just header).
# ============================================================================

TFROOT := justfile_directory()

# Provider subtree identity (override via env: SMALT_TF_*).
SMALT_TF_DIR     := env_var_or_default("SMALT_TF_DIR", "terraform-provider-smalt")
SMALT_TF_HEALTHZ := env_var_or_default("SMALT_TF_HEALTHZ", "http://127.0.0.1:9443/healthz")

# Fail-closed tool check — typed error naming the install command, exit 3.
# NOTE: go is deliberately NOT checked — the provider is a mix escript
# (BEAM), not a Go plugin, so `go` is not a prerequisite.
_check_provider_tools:
    @for t in just kubectl terraform mix; do \
        command -v "$t" >/dev/null 2>&1 || { \
          echo "[TF-PREREQ-FAIL] tool not on PATH: $t — install: brew install $t" >&2; \
          exit 3; }; \
      done; echo "[TF-PREREQ] just/kubectl/terraform/mix present (go not required)"

# Build the provider as a mix escript in terraform-provider-smalt.
[no-cd]
provider-build: _check_provider_tools
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f "{{TFROOT}}/{{SMALT_TF_DIR}}/mix.exs" ]; then
      echo "[TF-ARCHIVED] {{SMALT_TF_DIR}}/mix.exs absent — Elixir spike tree archived to tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz; active implementation: adapters/terraform-provider-smalt (GA court: just posh-court, 58-posh.just)" >&2
      exit 4
    fi
    cd {{TFROOT}}/{{SMALT_TF_DIR}}
    mix escript.build \
      || { echo "[TF-BUILD-FAIL] mix escript.build exited nonzero in {{SMALT_TF_DIR}} — fix the escript source in {{SMALT_TF_DIR}}, never the built artifact" >&2; exit 1; }
    echo "[TF-BUILD] escript built ({{SMALT_TF_DIR}})"

# Usage: just provider-install — build, then run build_install.sh + tfrc.sh
# and print the TF_CLI_CONFIG_FILE export line the shell needs to pin
# terraform at the local provider.

# provider-install — build + install provider; prints TF_CLI_CONFIG_FILE export.
[no-cd]
provider-install: provider-build
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f "{{TFROOT}}/{{SMALT_TF_DIR}}/mix.exs" ]; then
      echo "[TF-ARCHIVED] {{SMALT_TF_DIR}}/mix.exs absent — Elixir spike tree archived to tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz; active implementation: adapters/terraform-provider-smalt (GA court: just posh-court, 58-posh.just)" >&2
      exit 4
    fi
    cd {{TFROOT}}/{{SMALT_TF_DIR}}
    for s in scripts/build_install.sh scripts/tfrc.sh; do
      [ -f "$s" ] || { echo "[TF-INSTALL-FAIL] $s missing in {{SMALT_TF_DIR}} — land it first" >&2; exit 1; }
      bash "$s" || { echo "[TF-INSTALL-FAIL] $s exited nonzero" >&2; exit 1; }
    done
    echo "export TF_CLI_CONFIG_FILE=\"$PWD/.terraformrc\""

# Usage: just provider-court-elixir — full admission ladder (Elixir spike):
# kind prereq -> kind-up -> kind-images -> kind-deploy -> healthz bounded
# poll (60x1s) -> provider-build -> provider-install ->
# scripts/provider_court.sh. NOTE: spike path — the GA admission court is
# `just posh-court` (58-posh.just).

# provider-court-elixir — Elixir-spike admission ladder (GA path: posh-court).
[no-cd]
provider-court-elixir: _check_kind_tools _check_provider_tools
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f "{{TFROOT}}/{{SMALT_TF_DIR}}/mix.exs" ]; then
      echo "[TF-ARCHIVED] {{SMALT_TF_DIR}}/mix.exs absent — Elixir spike tree archived to tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz; active implementation: adapters/terraform-provider-smalt (GA court: just posh-court, 58-posh.just)" >&2
      exit 4
    fi
    cd {{TFROOT}}
    just kind-up
    just kind-images
    just kind-deploy
    echo "[TF-COURT] polling {{SMALT_TF_HEALTHZ}} (bounded 60x1s)"
    ok=0
    for i in $(seq 1 60); do
      if curl -fsS --max-time 2 "{{SMALT_TF_HEALTHZ}}" >/dev/null 2>&1; then
        ok=1; echo "[TF-COURT] healthz OK after ${i} poll(s)"; break
      fi
      sleep 1
    done
    [ "$ok" = 1 ] || { echo "[TF-COURT-FAIL] healthz never answered within 60s — witness: just kind-status" >&2; exit 1; }
    just provider-build
    just provider-install
    cd {{SMALT_TF_DIR}}
    [ -f scripts/provider_court.sh ] || { echo "[TF-COURT-FAIL] scripts/provider_court.sh missing in {{SMALT_TF_DIR}} — land it first" >&2; exit 1; }
    bash scripts/provider_court.sh \
      || { echo "[TF-COURT-FAIL] provider_court.sh exited nonzero" >&2; exit 1; }
    echo "[TF-COURT] ALIVE — full ladder passed"

# Usage: just provider-court — DEPRECATED alias (Elixir spike court); GA path
# is `just posh-court` (58-posh.just). Delegates to provider-court-elixir.

# provider-court — deprecated alias delegating to provider-court-elixir.
[no-cd]
provider-court:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f "{{TFROOT}}/{{SMALT_TF_DIR}}/mix.exs" ]; then
      echo "[TF-ARCHIVED] {{SMALT_TF_DIR}}/mix.exs absent — Elixir spike tree archived to tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz; active implementation: adapters/terraform-provider-smalt (GA court: just posh-court, 58-posh.just)" >&2
      exit 4
    fi
    echo "[TF-COURT-DEPRECATED] 'just provider-court' is deprecated — the Elixir court is now 'just provider-court-elixir'; the GA admission path is 'just posh-court' (58-posh.just). Delegating to provider-court-elixir." >&2
    exec just provider-court-elixir

# Usage: just provider-status — witness the provider surface (escript
# present, k8s surface, healthz). Report only, exit 0 always.

# provider-status — report-only provider surface witness (exit 0 always).
[no-cd]
provider-status:
    #!/usr/bin/env bash
    set -uo pipefail
    cd {{TFROOT}}/{{SMALT_TF_DIR}}
    if [ -f escript ]; then
      echo "[TF-STATUS] escript present: $(ls -l escript | awk '{print $5, $9}')"
    else
      echo "[TF-STATUS] escript absent — run: just provider-build"
    fi
    echo "[TF-STATUS] k8s surface:"
    kubectl -n default get statefulset,pods,svc 2>/dev/null || true
    curl -fsS --max-time 2 "{{SMALT_TF_HEALTHZ}}" 2>/dev/null \
      && echo "[TF-STATUS] healthz OK" \
      || echo "[TF-STATUS] healthz not answering ({{SMALT_TF_HEALTHZ}})"

# Remove build artifacts (_build-provider, bin/). Idempotent.
[no-cd]
provider-clean:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{TFROOT}}/{{SMALT_TF_DIR}}
    rm -rf _build-provider bin
    echo "[TF-CLEAN] removed _build-provider and bin/"
