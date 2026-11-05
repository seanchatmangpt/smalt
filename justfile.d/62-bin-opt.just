# 62-bin-opt.just — AoQ bin_opt_info gate + non-vacuity shim court (lane C1)
#
# Gate: scripts/bin_opt_gate.sh — compiles the AoQ surface with
# ERL_COMPILER_OPTIONS=bin_opt_info and fails closed on scoped binary-match
# optimization warnings. Court: scripts/shim_court/bin_opt_gate_court.sh —
# BEFORE/SHIM/AFTER/RESTORE over lib/smalt/aoq/frame.ex proving the gate
# flips 0 -> 1 on an injected non-reusable binary construction.
# Exit 0 pass / 1 violations / 2 loud refuse; court 0/1/3 (skip is loud).
#
# Root resolution matches the 31-have.just convention: recipes run under
# root-import, where justfile_directory() IS the repo root.

BIN_OPT_ROOT := justfile_directory()

@bin-opt:
    cd {{BIN_OPT_ROOT}} && bash scripts/bin_opt_gate.sh

@bin-opt-court:
    cd {{BIN_OPT_ROOT}} && bash scripts/shim_court/bin_opt_gate_court.sh
