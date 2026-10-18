# 29-sleep.just — NO-SLEEP-DOCTRINE Law 3 gate (B8, v26.10.18)

smalt-root := justfile_directory()

# Sleep-leak gate: fail-closed Process.sleep classification check.
# Honest red on unannotated sites is the deliverable (repair WOs), not silence.
@sleep-gate:
    python3 {{smalt-root}}/scripts/sleep_gate.py

# Non-vacuity court for the sleep gate (clean PASSES, injected sleep REFUSED).
@sleep-gate-court:
    bash {{smalt-root}}/scripts/shim_court/sleep_gate_court.sh
