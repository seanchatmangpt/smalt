# Module 10 Exercises

Keyed answers (with derivations) in `solution-key.md`; automated gate
`courts/court.py` (exit 0). Data: `data/xbar-r-subgroups.csv` (seed 42011),
`data/bore-baseline-100.csv` (seed 42008), `data/lead-defectives.csv`
(seed 42012) — all in the curriculum root `data/` directory.

1. Pick the chart for each scenario and justify in one clause: (i) bore diameter,
   3 consecutive parts per hour, 25 hours; (ii) single daily bore check over 100
   days; (iii) billing errors per 100 reports, exposure constant per report;
   (iv) late orders per day, daily shipment count varies 80-120. (10 min)
2. Why must a subgroup contain only within-group common cause (one shift, one
   setup, one operator)? State precisely what a mixed-shift subgroup does to
   R-bar, to the limits, and to sigma-hat. (10 min)
3. Derive A2 for n = 5 from A2 = 3/(d2 x sqrt n) using d2 = 2.326. Do not quote
   a table. (5 min)
4. Compute the X-bar/R limits for `xbar-r-subgroups.csv` (all 25 subgroups) and
   list the Test-1 breaches. Show each multiplication. (10 min)
5. Remove subgroups 18-20 (confirmed special cause) and recompute the limits.
   Which previously-inside subgroup now breaches, and what bias did the
   all-data limits carry? (10 min)
6. (i) The I-chart puts observation 41 below its LCL while the same value sits
   inside the 11.975-12.025 spec. What distinction is being taught, and what
   must you never do? (ii) A chart signals — what are you licensed to do, and
   what are you NOT licensed to do? (10 min)
7. p-chart: day 19 (frac 0.240) sits inside its own UCL (0.259) even though
   days 17-18 signal. Give both lawful readings of day 19 and name the deciding
   datum. (10 min)
8. Phase I sigma-hat comes out ~8.2 um against the 7.407 um spine sigma. Give
   the lawful explanation(s) for the gap and the condition under which you must
   investigate rather than explain. (10 min)
