# Module 36 — Intro to Reliability (Slides Outline)

**Module**: 36-intro-reliability
## Learning objectives

After this module the candidate can:
1. State the exponential and Weibull reliability models and read the Weibull shape parameter
   beta from plotted-shape descriptions.
2. Distinguish MTBF from B10 and show that the spine's pair (MTBF 1200 h, B10 900 h) is only
   jointly consistent under a wear-out Weibull (beta ~ 6.24, derived in court).
3. Allocate a system MTBF target across series components (lambda summation) for the spindle
   assembly and verify the allocation re-derives MTBF 1200 h exactly.
4. Compute system availability from component MTBF/MTTR and a parallel redundancy case.
5. Derive a preventive-maintenance interval from the B10 requirement.

**Timing estimate**: 4.5 h (slides 1.5 h, lab 1.0 h, exercises 1.5 h, court 0.5 h).
**Required tools**: python3 (stdlib only: `math`, `random`, `statistics`).

---

## Slide 1 — Two failure laws (20 min)
- Exponential: constant hazard, R(t) = exp(-t/MTBF). Memoryless; appropriate for electronic
  random failures, NOT for wearing mechanical parts.
- Weibull: R(t) = exp(-(t/eta)^beta). beta < 1 infant mortality (decreasing hazard — plotted
  as a falling curve on hazard-vs-time); beta = 1 reduces to exponential (flat hazard);
  beta > 1 wear-out (rising hazard); beta ~ 3-7 classic mechanical wear (hazard rises steeply
  after a near-zero early period — the plot looks like a hockey stick).
- eta = characteristic life: 63.2% of units have failed by t = eta for ANY beta.

## Slide 2 — MTBF vs B10 (20 min)
- MTBF = mean of the failure distribution. For Weibull: MTBF = eta x Gamma(1 + 1/beta).
- B10 = the 10th percentile of failure time (10% of units failed): B10 = eta x (-ln 0.9)^(1/beta).
- Exponential check: B10 = 0.10536 x MTBF. Spindle MTBF 1200 h -> exponential B10 = 126.4 h.
  **126.4 != 900** — the spine's pair is impossible under exponential.
- Joint consistency: MTBF/B10 = Gamma(1+1/beta) / (-ln 0.9)^(1/beta) = 1200/900 = 4/3 has a
  unique solution **beta = 6.24** (court bisection) -> eta = 1290.7 h. The spine pair silently
  encodes a strong wear-out law; this module makes it explicit.

## Slide 3 — Series allocation (20 min)
- Series system: R_sys(t) = product of R_i(t); for exponential components,
  1/MTBF_sys = sum of lambda_i.
- Spindle assembly target MTBF 1200 h -> lambda_sys = 8.333e-4 /h, allocated:
  bearing set 4.50e-4 (MTBF 2222 h), motor 1.50e-4 (6667 h), encoder 1.00e-4 (10000 h),
  drawbar 0.833e-4 (12000 h), cartridge electronics 0.50e-4 (20000 h).
  Sum = 8.33333e-4 = 1/1200 exactly -> re-derives MTBF 1200.0 h.

## Slide 4 — Availability (20 min)
- Component availability A = MTBF/(MTBF + MTTR). Series availability = product of A_i.
- Worked problem (MTTR: bearing 6 h, motor 4 h, encoder 2 h, drawbar 1.5 h, cartridge 3 h):
  A_sys = 0.9962 -> expected downtime 0.0038 x 8760 = **33 h/year**.
- Parallel redundancy: two independent coolant pumps, A = 0.99 each -> 1 - 0.01^2 = 0.9999.
- Lesson: series math punishes; parallel redundancy is the only escape, and it costs a second
  pump.

## Slide 5 — Maintenance interval from the target (15 min)
- PM at interval T with Weibull(beta, eta): probability a fresh unit fails within T is
  F(T) = 1 - exp(-(T/eta)^beta).
- Solve F(T) = 1% -> T = eta x (-ln 0.99)^(1/beta) = **617.7 h** (beta 6.24, eta 1290.7).
- F(T) = 0.1% -> T = **426.8 h**. The B10 anchor (900 h) sits BETWEEN these: at T = 900 h,
  F = 10% by definition — B10 is a risk statement, not a maintenance schedule.

## Slide 6 — Estimating from real failure data (15 min)
- Dataset: 40 seeded bearing failure times (`data/weibull-failure-times.csv`, seed 42114,
  inverse-CDF sampling of the beta=6.24/eta=1290.7 law).
- Weibull plot by linear regression: ln(t) vs ln(-ln(1-F)) with F = i/(n+1) on ranked times;
  slope = 1/beta, intercept = ln(eta).
- Sample results (court-re-derived): mean 1203.4 h (true 1200), beta_hat 6.29 (true 6.24),
  eta_hat 1291.3 h (true 1290.7).
