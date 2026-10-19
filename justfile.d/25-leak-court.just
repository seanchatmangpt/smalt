# 25-leak-court — test-isolation leak court (v26.10.17, receipts/i20e-leak-court).
# NOT wired into `just court` until the 122 flagged mutations are remediated
# (a gate that currently exits 1 on 122 findings must not gate the ladder);
# the recipe makes it runnable and the court wiring is a NEXT_WINDOW item.
# v26.10.19 staleness-repair note: the gate's scan root (test/) now contains
# only the residual tier test/internal (+ test_helper.exs) after the 64f6099
# reset — the scan surface is therefore test/internal without a gate edit
# (gates/*.py are contracts; not edited by this lane).

# Static test-isolation leak court: flags Application env / :persistent_term /
# named-ETS mutations in test/ (post-reset: test/internal) without
# save-restore discipline.
@leak-court:
    python3 gates/test_isolation_leak_gate.py

# Advisory count only — never fails (for `just status`-style reporting).
@leak-court-count:
    #!/usr/bin/env bash
    set +e
    python3 gates/test_isolation_leak_gate.py > /tmp/leak-court.out 2>&1
    rc=$?
    echo "[LEAK-COURT] exit=$rc $(grep -c 'uncovered' /tmp/leak-court.out 2>/dev/null || echo '?') uncovered-mutation lines (see /tmp/leak-court.out)"

# AZB-11 isolation court: static (start_supervised! + put_env restore
# discipline, inline `# isolation-court: exempt <reason>` only) over test/.
@isolation-court:
    python3 scripts/isolation_court.py

# Runtime twin: serial offline suite with per-module registered()/env diffs.
@isolation-court-runtime:
    python3 scripts/isolation_court.py --runtime-only
