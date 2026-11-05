# 63-aoq.just — AoQ egress fence + court stage (lane L29, spec §3/§4)
#
# aoq-fence: runs the LANE-13 egress fence (scripts/aoq_egress_fence.sh)
# fail-closed — any un-allowlisted `<>` at an AoQ egress site exits 1.
# aoq-court-stage: the non-vacuity shim court over a SCRATCH fixture scope
# (tmp/aoq-court/), proving the fence flips 0 -> 1 on an injected violation.
# Court receipts land under tmp/aoq-court/.

AOQ_ROOT := justfile_directory()

@aoq-fence:
    cd {{AOQ_ROOT}} && bash scripts/aoq_egress_fence.sh

@aoq-court-stage:
    cd {{AOQ_ROOT}} && bash scripts/shim_court/aoq_fence_court.sh
