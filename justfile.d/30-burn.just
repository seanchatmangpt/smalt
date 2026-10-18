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

# 4-container parallel burn matrix; asserts 4/4 clean.
@burn-matrix *args:
    bash {{BURN_ROOT}}/docker/burn/parallel-matrix.sh {{args}}

# Reclaim lane build roots + docker burn volumes + burn results.
@burn-clean:
    just lane-clean
    bash -c 'cd "{{BURN_ROOT}}" && docker compose -f docker/burn/compose.burn.yml -p smalt-burn down -v --remove-orphans >/dev/null 2>&1 || true; docker volume prune -f >/dev/null 2>&1 || true; rm -rf docker/burn/results; echo "[BURN-CLEAN] lane roots + burn volumes + results reclaimed"'

# Project smalt-burn JSONL receipts into conformant OCEL 2.0 documents and validate.
@burn-ocel:
    python3 scripts/burn_to_ocel2.py docs/jira/v26.10.18/burn/boot-burn.jsonl docs/jira/v26.10.18/burn/boot-burn.ocel.json
    python3 scripts/burn_to_ocel2.py docs/jira/v26.10.18/burn/chaos-kill.jsonl docs/jira/v26.10.18/burn/chaos-kill.ocel.json
    python3 scripts/validate_ocel2.py docs/jira/v26.10.18/burn/*.ocel.json
