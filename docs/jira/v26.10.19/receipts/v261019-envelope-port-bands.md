# Receipt — v26.10.19 Envelope: Non-Overlapping Port Reservation Bands

Standing: FAIL — 6 band collisions (2 ports triple-owned), 14 unregistered
out-of-band blocks. Mechanical pairwise port-set intersection, reproducible
from the table below. Audit lane: read-only Explore, 2026-10-19; receipt
landed by coordinator (lane had no write tool).

## Verdict
FAIL. Root cause: bands are claimed in files other than the registry of
record (scripts/bench/REGISTRY.md) — dev-loop.md, in-script comments, and
court scripts claim blocks REGISTRY.md never registered.

## Collisions
1. 39643/39644 double-owned: legacy lc1 39640-50 ("do not move",
   REGISTRY.md:77-79) vs smalt-cli/tests/conftest.py:57-58,374-378
   (39643/39644/39646 — unregistered).
2. 39460/39464 (39464 triple): flood_autocannon.mjs:29-30 vs
   stress/gate_cost.py:40-45 vs nfr3_rss_gate.py:29-34 (unregistered).
3. 39474-76: shim_court/amqp_framing_court.sh:66-70 (unregistered) vs
   stress/ycsb_lite.py 39472-77.
4. 39382/39383: amqp_framing_court.sh:66-67 vs overlap_court.sh:56
   (39380-85, unregistered; also inside e-law formula e1).
5. e-law self-inconsistent: REGISTRY.md:57-58 text says e1=39370..39375,
   formula gives 39380; both blocks consumed on disk.
6. Unregistered constants: quiet_check.py 9445; bench_concurrent 39540-42;
   nfr3 39463-68; amqp_framing_court set; tf_plan_check 39330-35 (c13 slot);
   tf_cleanroom 39390-95 (b39 slot); overlap_court 39380-85; smalt-cli set.

## Compliant (verified)
config/test.exs (OS-ephemeral probes); container burn lanes
(namespace-isolated BURN_EXPECT_PORT); pf_redirect (443→9444 canonical);
canonical FRONT band single-owner.

## Required actions (owner: REGISTRY.md owner + block users)
1. Register + repoint: smalt-cli → fresh v-law block; amqp_framing_court,
   nfr3, overlap_court tf shift, tf_plan_check, tf_cleanroom → unclaimed
   blocks; flood_autocannon off 39460/39464.
2. Fix REGISTRY.md e-law: declare e a single owned block, not a formula.
3. Reconcile dev-loop.md stress table into REGISTRY.md (defer or mirror).

Context: solo(automated pairwise intersection over collected laws; sources
cited per row in the audit lane transcript)
