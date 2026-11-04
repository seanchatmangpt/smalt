# Module 15 — TRIZ for Transactional Processes

# TRIZ for Transactional Processes (Develop/Implement)

Course spine: CPPC. This module applies TRIZ on the transactional surface of
the running case: CTQ-2 (order-to-ship lead time, baseline 18.4 d, target
<= 7 d) and the administrative processes that feed it — warranty claims
handling and new-employee onboarding. Module 14's 40 x 2 index already carries
a transactional column; here two full cases are solved end to end and the
transactional contradiction matrix adaptation and trends-of-evolution primer
are introduced.

## Learning objectives

1. Adapt the contradiction-matrix method to transactional parameters
   (throughput, queue time, audit rigor, compliance risk) when the standard
   39 parameters do not map cleanly.
2. Apply trends of evolution to anticipate the next process state, not just
   fix the current one.
3. Solve two transactional contradictions end to end with reproducible
   arithmetic (simulations seeded per the data provenance law).

## The transactional contradiction matrix adaptation

Transactional contradictions rarely use the classic 39 engineering parameters.
Course adaptation: keep the METHOD (improving vs worsening, lookup, one
concept per recommended principle) but replace the parameter axes with a
transactional excerpt:

| Improving | Worsening | Principles | Worked meaning |
|---|---|---|---|
| Throughput (claims/hr) | Audit rigor (defects escaped) | 3, 20, 23, 26 | Case 1 |
| Onboarding speed (days to productive) | Compliance completeness | 1, 17, 19, 34 | Case 2 |
| Volume scale | Consistency of decision | 3, 22, 25 | risk-banded processing |
| Cost per transaction | Cycle time | 10, 21, 26 | pre-action + fast lane |

Rules for a lawful adaptation: (1) state both sides functionally with the
metric you will measure; (2) the excerpt row is a candidate generator, not a
proof; (3) the chosen concept must name its measurement and its reversion
trigger — a transactional concept without a reversion trigger is refused.

## Trends of evolution primer (transactional rendering)

Eight trends with a machining and a transactional rendering each. Use them to
ask "where is this process on the trend, and what is the next state?"

1. Toward segmentation: monolithic pass -> segmented passes; one giant form ->
   staged micro-approvals.
2. Toward controllability: fixed feed -> adaptive feed; fixed audit rate ->
   risk-scaled audit rate.
3. Uneven development of parts: the CNC cell is automated while offset-setting
   is manual (the gap IS the project); claims intake is digital while review
   is manual queue.
4. Toward dynamism: rigid serial chain -> parallel lanes (case 2).
5. Decreasing human involvement: trial cuts -> gauge-driven compensation;
   human audit sampling -> automated trigger rules.
6. Increasing ideality: function remains, cost/complexity falls — skip-lot
   keeps escape protection while queue time falls.
7. Coordination mismatch then rhythm match: inspection cadence eventually
   synchronizes with process cadence (SPC-gated, not calendar-gated).
8. Toward smaller scales / field use: contact measurement -> optical/air
   gauging; on-site document review -> system-of-record pulls.

## Case study 1 (solved in full): claims throughput vs audit rigor

### Step 1 — Contradiction

CPPC's warranty claims desk processes 200 claims/month. Full audit of every
claim costs 150 h/month (45 min/claim) and is the only current defense against
process defects; cutting audit raises escaped defects. Improving: throughput;
worsening: audit rigor.

### Step 2 — Quantify the current state

- 200 claims * 0.75 h = 150.0 audit h/month (full audit).
- Claim-process defect rate measured (Measure phase): p = 0.06 — 6% of claims
  carry a process defect (wrong part number, missing concession, wrong cost
  code).

### Step 3 — Excerpt lookup and concept

Row "Throughput vs audit rigor" recommends principles 3 (local quality),
20 (continuity), 23 (feedback), 26 (copying). Chosen concept: **risk-banded
audit (3) + sampled audit with automatic full trigger (23 + 26)**: audit 25%
of claims (50, sampled), and any defect found in the sample triggers a full
audit of all 200.

### Step 4 — Simulate (seed 1507)

Monte Carlo, 20,000 months, claims i.i.d. defective with p = 0.06
(`scripts/derive_keys.py`):

- Mean escaped bad claims: 0.41/month; P(zero escapes in a month) = 0.954.
- P(trigger fires, i.e. at least one defect in the 50 sampled) = 0.955.

### Step 5 — Cost arithmetic

- Expected audit hours: 50 sampled always (37.5 h) + trigger fires 95.5% of
  months adding 150 claims * 0.75 h = 112.5 h:
  37.5 + 0.955 * 112.5 = 144.9 h/month expected.
- Saving vs full audit: only 5.1 h/month (~3.4%).

### Step 6 — Honest read and sensitivity

The scheme's near-certain trigger (0.955) means a hot defect stream buys
almost nothing: sampling saves 3.4% at p = 0.06. Sensitivity (same formula,
P(hit in 50) = 1 - (1-p)^50; hours = 37.5 + P(hit) * 112.5):

| p | P(detect in sample) | Expected audit h/month |
|---|---|---|
| 0.005 | 0.222 | 62.5 |
| 0.01 | 0.395 | 81.9 |
| 0.02 | 0.636 | 109.1 |
| 0.06 | 0.955 | 144.9 |

Laws the case teaches: (1) sampling audit pays when the stream is cold — at
p = 0.005 it saves 87.5 h/month with detection 0.222; (2) the trigger is what
buys escape protection, not the sampling — with the trigger, escapes are
0.41/month even at p = 0.06; (3) the real lever is defect prevention (drive p
down in Improve), after which sampling cost collapses.

## Case study 2 (solved in full): onboarding speed vs compliance

### Step 1 — Contradiction

New-hire onboarding runs 27 steps in a serial chain (legal, IT, HR, quality,
manager sign-offs). Serial ordering maximizes compliance (each gate completes
before the next begins) but delays productive start. Improving: onboarding
speed; worsening: compliance completeness.

### Step 2 — Quantify the serial baseline

Twelve recent hires' stage durations are registered
(`datasets/onboarding-durations.csv`, seed 1511; five stages in business
days: legal, IT, HR, quality, manager). Serial completion = sum of the five
stages per hire:

- Serial mean: 11.1 days; P90: 12.6 days.

### Step 3 — Excerpt lookup and concept

Row "Onboarding speed vs compliance completeness" recommends principles
1 (segmentation), 17 (another dimension -> parallel lanes), 19 (periodic
action), 34 (discard/recover). Chosen concept: **parallel lanes (17) with a
segmented compliance gate (1)**: legal and IT run in parallel; HR and quality
run in parallel; manager sign-off last. Nine of twelve mandatory checks stay
pre-start; the three lowest-risk checks move post-start with a fixed day-10
audit (19).

### Step 4 — Compute the parallel plan

Per hire: max(legal, IT) + max(HR, quality) + manager.

- Parallel mean: 7.1 days (saving 4.0 days, 36%); P90: 8.5 days (saving
  4.1 days). Script-verified against the CSV.

### Step 5 — Compliance risk arithmetic

Moving 3 checks post-start risks late completion. Per-check on-time
probability in the post-start window: 0.9. P(all 3 on time) = 0.9^3 = 0.723
— one hire in four misses a post-start check without a forcing mechanism.
Mitigation (principle 19, periodic action): a fixed day-10 audit sweeps all 3
checks and blocks system access if any is open. With the sweep, late checks
are caught at a bounded, known moment (day 10) instead of never — completeness
is enforced by the audit, not by the serial chain.

### Step 6 — Decision

Adopt the parallel plan: mean 11.1 -> 7.1 days contributes to CTQ-2 (the
transactional lead-time target <= 7 days), with the day-10 sweep as the
non-negotiable counterparty to the speed gain. The contradiction is resolved
by moving compliance in time (day-10 sweep), not by deleting it.

## Files in this bundle

- `workshop.md` — learner exercises.
- `solution-key.md` — numbered steps with script receipts.
- `datasets/onboarding-durations.csv` — seed 1511, 12 hires x 5 stages.
- `scripts/derive_keys.py` — re-derives both cases' keys (claims sim seed
  1507; onboarding from the CSV).

## See Also

- `../14-triz-product/README.md` — product-side method and 40 x 2 index.
- `../13-concept-generation/README.md` — toolkit introduced on CTQ-1.
- `../../RUNNING-CASE.md` — pinned constants.
