# 30-burn — saturation burn lane (docker/burn, v26.10.18)
#
# Host soak (burn-soak / burn-chaos) runs 4x yes-CPU hogs + an AMQP atom-flood
# generator (the i22 :closed logger-flood class,
# docs/jira/v26.10.17/receipts/i22-atom-flood-fix.md) across 3x
# (offline + wire tier); failures classify against
# docs/jira/v26.10.17/FLAKE_LEDGER.md into tmp/burn-soak-*.jsonl rows.
# burn-matrix runs the 4-container compose matrix and asserts 4/4 clean.
# burn-clean extends lane-clean with the docker burn-project volume teardown.
# Extra args are forwarded: `just burn-soak --dry-run`.

BURN_ROOT := justfile_directory()

# Full burn: host soak + container matrix.
burn: burn-soak burn-matrix

# Host saturation soak (3 rounds x offline+wire, 4 hogs, flood 20s/leg).
@burn-soak *args:
    bash {{BURN_ROOT}}/docker/burn/soak.sh {{args}}

# Chaos variant: 8 hogs, 1 round (degraded-host F9/F12 hammer shape).
@burn-chaos *args:
    bash {{BURN_ROOT}}/docker/burn/soak.sh --hogs 8 --rounds 1 {{args}}

# 4-container parallel burn matrix; asserts N/N clean.
@burn-matrix *args:
    bash {{BURN_ROOT}}/docker/burn/parallel-matrix.sh {{args}}

# AZB-22 burn ring: boot burn x50 -> chaos x50 -> matrix (N=8) -> soak, one
# image digest bound to one subject SHA, summary validated by the DfCM
# receipt validator. Stage-runnable/resumable:
#   just burn-ring --stage boot   (boot|chaos|matrix|soak|summary)
@burn-ring *args:
    bash {{BURN_ROOT}}/docker/burn/burn-ring.sh {{args}}

# Reclaim lane build roots + docker burn volumes + burn results.
@burn-clean:
    just lane-clean
    bash -c 'cd "{{BURN_ROOT}}" && docker compose -f docker/burn/compose.burn.yml -p smalt-burn down -v --remove-orphans >/dev/null 2>&1 || true; docker volume prune -f >/dev/null 2>&1 || true; rm -rf docker/burn/results; echo "[BURN-CLEAN] lane roots + burn volumes + results reclaimed"'

# Project smalt-burn JSONL receipts into conformant OCEL 2.0 documents and validate.
@burn-ocel:
    python3 scripts/burn_to_ocel2.py docs/jira/v26.10.18/burn/boot-burn.jsonl docs/jira/v26.10.18/burn/boot-burn.ocel.json
    python3 scripts/burn_to_ocel2.py docs/jira/v26.10.18/burn/chaos-kill.jsonl docs/jira/v26.10.18/burn/chaos-kill.ocel.json
    python3 scripts/validate_ocel2.py docs/jira/v26.10.18/burn/*.ocel.json

# In-container validation using mounted ~/beam4pm and ~/xaas
@burn-in-container-verify:
    docker run --rm \
      -v /Users/sac/beam4pm:/beam4pm:ro \
      -v /Users/sac/xaas:/xaas:ro \
      -v {{BURN_ROOT}}/docker/burn:/burn:ro \
      -v {{BURN_ROOT}}/docs/jira/v26.10.18/burn:/burn-evidence:ro \
      smalt:local elixir /burn/in_container_conformance.exs

# AZB-13 boot burn: 50 boot/probe/teardown cycles per plane inside containers
# (smalt:local), rows through validate_burn.py --gate. Jidoka: first
# ORPHAN_LISTENER / ZOMBIE_BEAM / UNHANDLED_EXIT row stops the line.
@burn-boot *args:
    bash {{BURN_ROOT}}/docker/burn/boot-burn.sh {{args}}

# ============================================================================
# AZB-19 overlap schedule (pipeline lane) — docs/jira/v26.10.18/azsim-burn/TICKETS.md
# Court stages declare resources (ports, build_root, dets_dir); the scheduler
# runs disjoint-resource stages in parallel:
#   p1 {t1-offline ∥ mutation-court ∥ tf-plan-smoke ∥ port-free statics}
#   p2 {t2-wire}   p3 {t3-sdk-smoke}
# Laws: never T1 ∥ T3 (load class); per-stage MIX_BUILD_ROOT; a shared
# MIX_BUILD_ROOT between overlapped stages is refused (RESOURCE_CONFLICT);
# serial-vs-overlapped verdict identity is checked by overlap-court-compare.
# @overlap-court-anti-vacuity must exit 0 (injected conflicts refused) —
# a pass from a vacuous scheduler is the failure.
@overlap-court:
    bash scripts/overlap_court.sh overlap
@overlap-court-serial:
    bash scripts/overlap_court.sh serial
@overlap-court-check:
    bash scripts/overlap_court.sh anti-vacuity
@overlap-court-compare *args:
    bash scripts/overlap_court.sh compare {{args}}
@overlap-court-report *args:
    bash scripts/overlap_court.sh report {{args}}
