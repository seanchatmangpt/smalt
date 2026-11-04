# Module 03 Exercises

Answers with shown derivations in `keys/solution-key.md`. Sources: this module's
two CSVs plus the pinned constants listed in the README.

1. From `data/ed-door-to-provider-minutes.csv`: compute median, sd, and the
   percentage of visits over 30 minutes. Then write a one-sentence quantified
   problem statement. (10 min)
2. From `data/insurance-claims-cycle-time.csv`: compute mean, median, and sd of
   `cycle_time_days`. What fraction of rows can be audited against a closed
   timestamp, and what does that do to the number's standing? (10 min)
3. Show the arithmetic that turns the Cpk pins into "the upper spec limit binds":
   distance from mu = 12.009 to USL and to LSL in sigma units. Which side is
   2.16 sigma, which is 4.60 sigma? (5 min)
4. Build the CTQ->Y->x trace for CTQ-2 (delivery): the Y, one OD from Module 07's
   OD-1..OD-15 table that measures it, and two candidate x's a team could scope.
   (10 min)
5. Risk register for the CPPC program: three risks, each with likelihood (1-5) x
   impact (1-5) score, mitigation, and a named owner. One risk must be the
   claims-style data-integrity class from the README. (15 min)
6. Scope math: the sponsor offers to cut the program before the Develop gate to
   save 8 weeks. Using the pinned constants, state which pinned target is
   abandoned (Cpk 1.33 sustained 30 days? $28.50? <= 7 days?) and what the $13.30
   gap implies about the cost of that cut. (10 min)
