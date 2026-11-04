# Module 06 Exercises

Every numeric answer must re-derive from the pinned parameters in
`worksheets/01-should-cost-teardown.md` via `python3 courts/court.py` (exit 0).
Show derivations; the court is the exit-checked authority — this file only
points at the worksheets and the court.

**E1.** From `worksheets/01-should-cost-teardown.md`: re-derive billet mass.
Volume = 90 x 90 x 115 mm = 931,500 mm³ = 931.5 cm³; at the pinned density
2.81 g/cm³ the charged mass is 2.6175 kg. Then show why the chip credit applies
only to swarf (2.6175 − 0.98 = 1.6375 kg), never to the finished part mass.

**E2.** Re-derive the eight-term baseline rollup from the worksheet parameters
(material net $10.21 + machining $19.41 + setup $0.67 + tooling $6.05 + QC
$1.75 + scrap $0.64 + overhead $3.07). Which single line dominates, and what
does that imply about where target-costing effort belongs — machine rate or
insert price? Confirm with the court's `baseline-rounded-rollup` check.

**E3.** From `worksheets/02-cost-driver-table.md`: the two largest cost drivers
are machining ($19.41) and tooling ($6.05). Compute the tooling term by hand:
in-cut minutes 22.40 x 0.78 = 17.472 min; insert burn rate 4/52.0 = 0.0769
inserts/min x $4.50 = $0.3462/min; tool = 17.472 x 0.3462 = $6.05. If edge life
drops from 52.0 to 26.0 min at the same feed, what happens to the tooling term
and to the baseline total?

**E4.** Scrap re-derivation: with baseline Cpk = 0.72, the centered-normal
defect rate is 2 x Phi(−3 x 0.72) = 2 x Phi(−2.16) = 3.0773%. The scrap term
charges this rate against matnet + 0.55 x mach = $10.21 + $10.68 = $20.88, so
scrap = $0.64. Explain why the scrap term uses matnet + 0.55 x mach (what is
the 0.55 modeling?) and why QC/tooling/setup are excluded.

**E5.** Gap and ceiling chain from `worksheets/03-gap-worksheet.md` and
`worksheets/04-price-point.md`: WTP blend $30.35 (court `wtp-blend`), price
$43.80 x (1 − ROS) → allowable cost = ceiling **$28.50** (court
`allowable-cost`). Baseline $41.80 − ceiling $28.50 = gap **$13.30** (court
`gap`). A teammate proposes closing the $13.30 gap by renegotiating the insert
price from $4.50 to $2.00. Re-derive the new tooling term
(burn rate 0.0769 x $2.00 = $0.1538/min x 17.472 = $2.69) and the new total
($41.80 − $6.05 + $2.69 = $38.44) — does this close the gap? What does the
result teach about attack order on cost drivers?

**E6.** Future-state tie-out: the future cycle 13.08 min (court
`future-cycle`) and future total **$27.09** (court `future-total`) sit below
the ceiling (court `future-under-ceiling`). Explain the relationship between
the projected $27.09 and the ceiling $28.50 in terms the Module 07 scorecard
can carry as a metric (why the ceiling, not the projection, becomes the
tracked value).
