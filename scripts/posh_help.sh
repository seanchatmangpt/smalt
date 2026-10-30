#!/usr/bin/env bash
# posh_help.sh — annotated help for the posh/provider recipe family
# (gaps/64, v26.10.30 wave, lane 11/16).
#
# `just --list` renders only the LAST line of a recipe's doc comment
# (witnessed: just 1.56.0, temp justfile, 2026-10-30) — so multi-line doc
# comments truncate. This script carries the full surface: recipe -> summary
# -> usage example -> typical duration. Wire: `just posh-help`.
#
# Usage:
#   bash scripts/posh_help.sh            # full annotated help
#   bash scripts/posh_help.sh list       # one line per recipe
#   bash scripts/posh_help.sh posh-court # single recipe detail
#
# Exit contract: 0 green; 1 unknown recipe; 2 drift (help row with no recipe).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

emit_table() {
  # recipe | summary | example | typical duration
  cat <<'TABLE'
posh-bootstrap | Resumable clone-to-green, stages S1..S8 (POSH_BOOTSTRAP_STAGES selects a subset) | just posh-bootstrap | ~2-10 min (substrate-dependent)
posh-generate | ggen pack synthesis (loud SKIP exit 3 until packs/posh lands) | just posh-generate | <5 s (or SKIP)
posh-vet | Stage 1: golangci-lint over posh/ + provider dir | just posh-vet | ~10-30 s
posh-alloc-test | Stage 2: go test -race over posh/ | just posh-alloc-test | ~1-3 min
posh-build | make -C posh build + Go provider build | just posh-build | ~1-2 min
posh-fence-test | Stage 4: go test -race over egress+config fence packages | just posh-fence-test | ~30-90 s
posh-install | Transient dev_overrides rc at tmp/posh/tfrc; never touches ~/.terraformrc | just posh-install | ~1-2 min
posh-smalt-wire | Stage 5: STS mint + wire asserts + turnstile header assert | just posh-smalt-wire | ~30-60 s (SKIP 3 if substrate down)
posh-court | Full DoD 7-stage ladder (pre-stage kind + stages 1-7) | just posh-court | ~10-25 min
posh-court-sla-test | SLA-clock non-vacuity fixture (control + kill legs) | just posh-court-sla-test | ~7 s
posh-invariant-court | SPARQL invariant-gate non-vacuity shim-court | just posh-invariant-court | ~1-2 min
posh-mutation-court | POSH-006 non-vacuity mutation court | just posh-mutation-court | ~1-2 min
posh-regen-check | Regen -> gofmt-normalize -> byte-compare -> ceiling merge | just posh-regen-check | ~2-5 min
compat-check | Re-read truth, diff vs compat-pin-core.ttl + dialect compat-pin.ttl, typed exit ladder (0/1/3) | just compat-check | ~5-15 s
compat-court | Split mutation court: core+dialect legs MUST flip to exit 1, missing-pin probe MUST exit 3 | just compat-court | ~10-30 s
posh-status | One-glance typed status witness (exit 0 green / 2 RED) | just posh-status | ~2-5 s
posh-andon | Run the POSH andon driver (andon JSONL receipts) | just posh-andon | ~2 s
posh-doctor | Autonomous System Physician (TPS Andon + 5-Whys diagnostics) | just posh-doctor | ~5-30 s
posh-doctor-fix | Autonomous System Physician with Jidoka auto-heal (--fix) | just posh-doctor-fix | ~5-60 s
posh-up | Boot the posh membrane process, bounded-poll UDS socket up | just posh-up | ~5-60 s
posh-down | Stop the posh membrane process by pid file | just posh-down | ~1-5 s
posh-image | Build minimal static container image smalt/posh:latest | just posh-image | ~1-3 min
posh-coverage | POSH-009 surface coverage compiler + divergence checker | just posh-coverage | ~10-30 s
posh-clean | Remove tmp/posh, posh/bin, adapters binary (idempotent) | just posh-clean | ~1 s
provider-build | Build the provider as a mix escript (Elixir spike path) | just provider-build | ~30-90 s
provider-install | Build + install provider; prints TF_CLI_CONFIG_FILE export | just provider-install | ~1-2 min
provider-court-elixir | Elixir-spike admission ladder (GA path: posh-court) | just provider-court-elixir | ~5-15 min
provider-court | DEPRECATED alias delegating to provider-court-elixir | just provider-court | ~5-15 min
provider-status | Report-only provider surface witness (exit 0 always) | just provider-status | ~2-5 s
provider-clean | Remove _build-provider and bin/ (idempotent) | just provider-clean | ~1 s
tf-plan-smoke | Terraform fixture plan smoke (77 = skipped-network) | just tf-plan-smoke | ~10-40 s
TABLE
}

topic="${1:-all}"

case "$topic" in
  all)
    emit_table | awk -F' \\| ' '{
      printf "%s\n  summary : %s\n  usage   : %s\n  duration: %s\n\n", $1, $2, $3, $4
    }'
    ;;
  list)
    emit_table | awk -F' \\| ' '{printf "%-24s %s\n", $1, $2}'
    ;;
  *)
    row="$(emit_table | grep -E "^${topic} \|" || true)"
    if [ -z "$row" ]; then
      echo "[POSH-HELP-FAIL] unknown recipe: $topic (see: bash scripts/posh_help.sh list)" >&2
      exit 1
    fi
    printf '%s\n' "$topic"
    awk -F' \\| ' '$1 == topic {
      printf "  summary : %s\n  usage   : %s\n  duration: %s\n", $2, $3, $4
    }' topic="$topic" <<<"$row"
    ;;
esac

# Drift guard: every help row must exist in `just --list` (exit 2 on drift).
rc=0
while IFS= read -r name; do
  if ! just --justfile "$ROOT/justfile" --list 2>/dev/null | awk '{print $1}' | grep -qx "$name"; then
    echo "[POSH-HELP-DRIFT] recipe in help table but not in just --list: $name" >&2
    rc=2
  fi
done < <(emit_table | cut -d'|' -f1 | sed -e 's/[[:space:]]*$//')
exit "$rc"
