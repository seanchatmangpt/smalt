# Worksheet 02 — Filled Charter Example 1 (Product): CPPC Gimbal Line

Template fields filled from the pinned running-case constants. Every number is
cited, none invented.

## Header

| Field | Entry |
|---|---|
| Project name | SR-71 gimbal CNC line: bore capability, lead time, unit cost |
| Business unit / line | CPPC, new 3-axis mill cell, OP30 finish bore |
| Black Belt / process owner / sponsor | (course role-play) / machine-shop mgr / VP ops |
| Gate weeks | W5/W9/W15/W21/W26 (26-week DMEDI program) |
| DMEDI or DMAIC, and why | DMEDI — the CNC line is NEW equipment; no stable process exists to improve |

## 1. Problem statement

- Y and baseline: bore diameter Cpk **0.72** (RUNNING-CASE.md, adjudicated pair
  mu 12.009 mm, sigma 7.407 um, spec 11.975/12.025). USL side binds: 16 um =
  2.16 sigma; LSL side 34 um = 4.59 sigma.
- Gap to target: 0.72 vs **>= 1.33 sustained 30 days**.
- Who is hurt: every oversize-tail bore at the W21 gate is scrap or rework; the
  USL tail is the escape driver (Module 09 USL-tail arithmetic 2.01e-2).

## 2. Goal statements

| CTQ | Y | Baseline | Target | OD | Gate |
|---|---|---|---|---|---|
| CTQ-1 | bore-diameter Cpk | 0.72 | >= 1.33 sustained 30 d | OD-1/OD-2 (CMM, 5 parts/shift, trailing 30 d, n >= 250) | W21 |
| CTQ-2 | order-to-ship lead time | 18.4 d registry (17.35 d sample median, Module 02) | <= 7 d | OD-11 | W15 |
| CTQ-3 | unit cost | $41.80 | <= $28.50 = $30.00 x 0.95 | OD-14/OD-15 | W26 |

## 3. Business case

- $41.80 - $28.50 = **$13.30/unit** gap (decomposition in Module 06
  worksheets 02-03); on the planned volume this funds the 26-week program.
- Cost of not closing: scrap at 12.0293-class bores + expedite freight on
  lead-time breaches (40/40 of the Module 02 sample over 7 days).

## 4. Scope

- In: OP30 finish bore (CTQ-1), order-to-ship flow (CTQ-2), cost drivers of
  Module 06's teardown (CTQ-3).
- Out: billet supply chain — OD-15 is a leading measure, not a project Y.

## 5. Team

Sponsor (admits gates), Black Belt (owns receipts), machine-shop manager
(process owner), ERP data steward (owns OD re-pins).

## 6. Sign-off conditions

All three goal rows carry a source file; `python3
modules/03-charter-mgpp-risk-comms/courts/court.py` exits 0; no UNVERIFIED
field without an action row.
