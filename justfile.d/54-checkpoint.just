# 54-checkpoint — SHIM-COURT checkpoint gate (BK-SHIMGATE, v26.10.22)
# Closes the BK-B4VW hazard: tick checkpoints landing in-flight shims as code.

# Gate only: scan STAGED files for SHIM-COURT markers, refuse (exit 1) if found.
checkpoint-gate:
    @bash scripts/checkpoint_gate.sh

# Durable checkpoint path — gate + git commit -F <msgfile>.
# Coordinator use: `just checkpoint /tmp/tick.msg` instead of bare `git commit`.
checkpoint MSGFILE:
    @bash scripts/checkpoint_gate.sh && git commit -F "{{MSGFILE}}"
