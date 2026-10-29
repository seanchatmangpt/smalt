# 43-scvd.just — SCVD tier runner (SCVD-T9, v26.10.20 wave).
#
# One-command surface over scripts/scvd_ramp.sh: preflights the LIVE
# substrate (boots nothing — loud exit 2 when down), runs the requested
# SCVD tier harness(es), aggregates tmp/bench/scvd-*.jsonl into a stdout
# table. Exit codes: 0 pass / 1 tier fail / 2 substrate down / 3 skip.
# Never starts/stops a substrate.

SCVD_ROOT := justfile_directory()
SCVD_RAMP := SCVD_ROOT / "scripts" / "scvd_ramp.sh"

# Run SCVD tier ramp: `just scvd-ramp` (all tiers) or tier1|tier2|tier3.
@scvd-ramp tier="all":
    bash {{SCVD_RAMP}} {{tier}}
