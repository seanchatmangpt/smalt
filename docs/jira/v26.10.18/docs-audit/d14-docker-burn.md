# D14 — docker/burn docs audit (2026-10-18)
Highest severity (commands that fail): BUILD_RECEIPT.md:6-13 build contexts missing ash_graphlaw/ggen_igniter; README.md:15-25 wrong sibling set (ex4pm hex now); compose.smalt.yml:14-17 missing ash_r2rml.
Next: REGISTRY.md:94 v1->v2 schema; chaos-kill.sh:25-28 BURN_GATES_UNAVAILABLE_IN_IMAGE/rc=3 superseded; parallel-matrix.sh:9 N=4 vs checked-in N=8; boot-burn/burn-ring stage-matrix mismatch (recover every cycle required, emitted every 10th — ring green unreachable as written).
Minor: README HEALTHCHECK (compose-only), /opt/smalt stale, soak.sh exit-3 preflight claim, per-leg log truncation.
Verified: digest pin, TLS mint, warm layers, subject-SHA, storm/scenario names, preflight exit 2, per-plane ports, saboteur legs.
