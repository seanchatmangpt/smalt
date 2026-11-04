# Module 06 — Solution Key

Every number below re-derives via `python3 courts/court.py` (exit 0). Derivations
are shown step by step; the court is the exit-checked authority.

## K1 — Baseline should-cost teardown, line by line

Raw parameters (`worksheets/01-should-cost-teardown.md`, court-verified): density
2.81 g/cm^3, billet 90 x 90 x 115 mm, part mass 0.98 kg, material $4.65/kg, chip
credit $1.20/kg, rate $52.0/h, cycle 22.40 min, in-cut fraction 0.78, 4 inserts,
edge life 52.0 min, insert price $4.50, setup 3.2 h, lot 250, QC 1.8 min, gauge
amortization $0.19, baseline Cpk 0.72, overhead 11%.

Step 1 — billet mass: 90 x 90 x 115 = 931,500 mm^3 = 931.5 cm^3;
931.5 x 2.81 = 2,617.5 g = **2.6175 kg**.

Step 2 — net material: charged mass 2.6175 kg x $4.65 = $12.17; chip credit on
swarf: (2.6175 - 0.98) x $1.20 = 1.6375 x 1.20 = $1.96;
matnet = 12.1714 - 1.9650 = **$10.21**.

Step 3 — machining: 22.40/60 h x $52.0 = **$19.41**.

Step 4 — setup per part: 3.2 h x $52.0 / 250 = $166.40/250 = **$0.67**.

Step 5 — tooling per part: in-cut minutes = 22.40 x 0.78 = 17.472 min;
insert burn rate = 4/52.0 = 0.0769 inserts/min x $4.50 = $0.3462/min;
tool = 17.472 x 0.3462 = **$6.05**.

Step 6 — QC per part: 1.8/60 h x $52.0 = $1.56 + $0.19 gauge amortization =
**$1.75**.

Step 7 — scrap: defect rate (centered normal) = 2 x Phi(-3 x 0.72) = 2 x
Phi(-2.16) = 0.030773. Scrap content = matnet + 0.55 x mach = 10.21 + 10.68 =
$20.88. Scrap = 0.030773 x 20.88 = **$0.64**.

Step 8 — overhead: 0.11 x (19.41 + 0.67 + 6.05 + 1.75) = 0.11 x 27.88 = **$3.07**.

Rollup: 10.21 + 19.41 + 0.67 + 6.05 + 1.75 + 0.64 + 3.07 = **$41.80** — matches
the pinned baseline (court `baseline-rounded-rollup`).

## K2 — Allowable cost and the gap

Allowable = price x (1 - ROS) = $30.00 x 0.95 = **$28.50** (court `allowable-cost`).
Gap = $41.80 - $28.50 = **$13.30** (court `gap`).

## K3 — WTP blend

wtp = (6500 x 31.80 + 3800 x 29.20 + 1700 x 27.40)/12000
    = (206,700 + 110,960 + 46,580)/12000 = 364,240/12000 = **$30.35** (court
`wtp-blend`, tolerance 0.005). $30.00 is selected inside the blended WTP to hold
ROS 5% exactly at the $28.50 ceiling.

## K4 — Future state, driver targets deployed

Future parameters: feed 630 vs 360 mm/min (ratio 1.75), air time 3.10 min,
billet 88 x 88 x 110 mm, setup 1.05 h, lot 400, QC 0.9 min, Cpk 1.33.

Step 1 — cycle: in-cut = 17.472/1.75 = 9.984 min; F_CYCLE = 9.984 + 3.10 =
**13.084 min** (court `future-cycle`, pinned 13.08).

Step 2 — future lines, same formulas as K1:
matnet: mass 88 x 88 x 110 = 851,840 mm^3 x 2.81 = 851.84 cm^3 x 2.81 g/cm^3 =
2.3937 kg; 2.3937 x 4.65 - (2.3937 - 0.98) x 1.20 = 11.1307 - 1.6964 = **$9.43**.
mach: 13.084/60 x 52.0 = **$11.34**. setup: 1.05 x 52.0/400 = **$0.14**.
tool: 9.984 x 0.3462 = **$3.46**. qc: 0.9/60 x 52.0 + 0.19 = **$0.97**.
scrap: content = 9.43 + 0.55 x 11.34 = $15.67; rate = 2 x Phi(-3.99) =
0.00006607; scrap = 0.00006607 x 15.67 = **$0.00** (rounded).
oh: 0.11 x (11.34 + 0.14 + 3.46 + 0.97) = 0.11 x 15.91 = **$1.75**.

Rollup: 9.43 + 11.34 + 0.14 + 3.46 + 0.97 + 0.00 + 1.75 = **$27.09** — under the
$28.50 ceiling by $1.41 (court `future-total`, `future-under-ceiling`).

## K5 — Savings decomposition (additivity proof)

Per-line savings = baseline minus future (court `savings-*`): matnet 10.21-9.43 =
**0.78**; mach 19.41-11.34 = **8.07**; setup 0.67-0.14 = **0.53**;
tool 6.05-3.46 = **2.59**; qc 1.75-0.97 = **0.78**; scrap 0.64-0.00 = **0.64**;
oh 3.07-1.75 = **1.32**. Line sum = 0.78+8.07+0.53+2.59+0.78+0.64+1.32 = **$14.71**
= 41.80 - 27.09 ✓ (court `savings-additive`). Residual $1.41 below the ceiling is
design margin, disclosed not absorbed.

## K6 — Yield math

Baseline: 2 x Phi(-3 x 0.72) = **3.0773%** defect (court `baseline-defect-rate`).
Target: 2 x Phi(-3 x 1.33) = 2 x Phi(-3.99) = **0.006607%** (court
`target-defect-rate`). Cpk 0.72 -> 1.33 cuts the centered-normal defect rate by
~466x (0.0307727/0.00006607).

---

Court: `python3 courts/court.py && echo COURT-PASS` — exit 0, 19/19 checks
(`baseline-rounded-rollup`, `baseline-defect-rate`, `gap`, `allowable-cost`,
`wtp-blend`, `future-cycle`, `future-under-ceiling`, `future-total`,
`savings-additive`, 7 x `savings-<line>`, `target-defect-rate`,
`scrap-content-base`, `scrap-content-future`).
