# Module 36 Solution Key (all numbers python3-re-derived; see courts/court.py)

## Part 1 — Sample statistics (data/weibull-failure-times.csv, seed 42114)
- Sample mean = **1203.4 h** (generating-law MTBF 1200.0; sampling error +0.3%).
- Empirical B10: rank position (n+1) x 0.1 = 4.1 -> interpolate rank 4 (875.1) and rank 5
  (918.2): 875.1 + 0.1 x 43.1 = **879.4 h** (spine B10 900 h; sampling error -2.3%).
- Weibull regression (ranked times, F = i/(n+1), ln t vs ln(-ln(1-F))):
  slope **0.1585** -> beta_hat = 1/0.1585 = **6.31** (true 6.24); intercept -> eta_hat =
  **1291.3 h** (true 1290.7).

## Part 2 — Exponential check
- Exponential B10 = -ln(0.9) x 1200 = 0.105361 x 1200 = **126.4 h**, not 900 h.
- Sentence: the spine's pair (MTBF 1200, B10 900) cannot be exponential — it requires a
  Weibull wear-out with beta = 6.24 (unique solution of Gamma(1+1/beta)/(-ln0.9)^(1/beta) =
  4/3, found by bisection in the court), eta = 1290.7 h.

## Part 3 — Allocation
- lambda sum = 4.50 + 1.50 + 1.00 + 0.83333 + 0.50 (e-4) = 8.33333e-4 /h
  -> MTBF = 1/0.000833333 = **1200.0 h** exactly (drawbar lambda = 1/12000).

## Part 4 — Availability
- Component A: bearing 2222.2/2228.2 = 0.99731; motor 6666.7/6670.7 = 0.99940;
  encoder 10000/10002 = 0.99980; drawbar 12000/12001.5 = 0.99988;
  cartridge 20000/20003 = 0.99985.
- Series A_sys = product = **0.9962**; downtime = 0.0038 x 8760 = **33 h/year**.
- Bearing MTBF -> 1500 h: A_bearing = 1500/1506 = 0.99602 -> A_sys = **0.9949**,
  downtime **44.3 h/year**. The bearing set still dominates the downtime budget (it already
  carried 45% of system unavailability at baseline).
- Parallel exercise (full-precision A = 0.996236): 1 - (1-A)^2 = **0.9999858** ->
  0.12 h/year downtime, saving 32.88 h/year x $150 = **$4,927/year**. Justified only if the
  second line costs less than ~$4.9k/year of ownership — the exercise's point is that the number, not enthusiasm, decides.

## Part 5 — Maintenance interval (beta 6.24, eta 1290.7)
- F(T) = 1%: T = 1290.7 x (-ln 0.99)^(1/6.2417) = **617.7 h**.
- F(T) = 0.1%: T = 1290.7 x (-ln 0.999)^(1/6.2417) = **426.8 h**.
- F(900 h) = 1 - exp(-(900/1290.7)^6.2417) = **10.0%** (B10 by definition).
- Correction sentence: "B10 = 900 h means 10% of units FAIL by 900 h — scheduling PM AT 900 h
  accepts a 10% per-interval failure probability; a 1%-risk schedule requires 617.7 h."

## Exercise answers
1. (a) beta < 1 (infant mortality) — e.g. cartridge electronics with shipping/assembly defects;
   (b) beta = 1 exponential — encoder electronics, random failures; (c) beta >> 1 wear-out —
   bearing set (hockey-stick hazard).
2. 1 - (1 - A)^2 with full-precision A = 0.996236 gives 0.9999858 (Part 4). Decision rule
   shown; $4,927/year saving sets the ceiling on justifiable purchase price.
3. Exponential B10_i = 0.10536 x MTBF_i — a per-component percentile; percentiles of series
   systems do not combine multiplicatively or additively (the system 10th percentile is not a
   function of the component percentiles alone). What IS additive: lambdas. So allocate
   lambda_i (or full eta+beta pairs per component), never B10_i.
4. Excluding the 2 unfailed removals biases the mean toward SHORT times (failed units only)
   — it understates MTBF. The right estimator is maximum-likelihood with right-censoring
   (or Kaplan-Meier / median-rank regression for Weibull).
5. "Under exponential, B10 = 0.10536 x MTBF = 126.4 h, not 900 h. The datasheet pair is only
   consistent with Weibull beta = 6.24 — the vendor must state beta and eta or the claim is
   internally contradictory."

## Court
`python3 courts/court.py` re-derives: mean 1203.4, empirical B10 879.4, beta_hat 6.31,
eta_hat 1291.3, exponential B10 126.4, spine beta 6.2417/eta 1290.7 (bisection, MTBF
re-derived to 1200.0), allocation lambda sum -> 1200.0, A_sys 0.9962 / 33 h per year,
bearing-1500 case 0.9949 / 44.3 h, parallel 0.9999858 / $4,927, PM 617.7 / 426.8 h,
F(900) = 10.0%. Exit 0 = match.
