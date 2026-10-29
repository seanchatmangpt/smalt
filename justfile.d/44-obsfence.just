# 44-obsfence — AR-OBS-03 tprof memory-ceiling fence (v26.10.21)
# Gate: scripts/tprof_memory_gate.py; non-vacuity: tprof-memory-gate shim court.

OBSF_ROOT := justfile_directory()

# CI memory-ceiling fence: profile one real cosmos put_doc via tprof
# call_memory, fail-closed vs ceiling 200 words (49% headroom over the
# VAL-OBS 134-word baseline). Re-baseline: `just memory-gate-seed`.
memory-gate:
    @cd {{OBSF_ROOT}} && MIX_BUILD_ROOT=_build-obsfence python3 scripts/tprof_memory_gate.py

# Re-baseline: measures and rewrites CEILING_WORDS (measured * 1.5).
memory-gate-seed:
    @cd {{OBSF_ROOT}} && MIX_BUILD_ROOT=_build-obsfence python3 scripts/tprof_memory_gate.py --seed

# Non-vacuity court (ceiling shim 200 -> 100 must flip the gate to FAIL).
memory-gate-court:
    @bash {{OBSF_ROOT}}/scripts/shim_court/tprof_memory_gate_court.sh
