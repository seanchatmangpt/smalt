# Worksheet 04 — Filled Charter Example 3 (Service): Hospital ED Door-to-Provider

Template fields filled from `data/ed-door-to-provider-minutes.csv`
(python3 re-derivation: n = 80; mean 53.1 min; median 52.0 min; sd 16.5 min;
min 9; max 97; **75/80 = 93.8%** over the 30-minute standard). Contrast with
worksheet 03: timestamps present, baseline fully auditable — so a numeric
goal is lawful here.

## Header

| Field | Entry |
|---|---|
| Project name | ED door-to-provider time to the 30-minute standard |
| Business unit | Emergency department, main campus |
| Method | DMAIC — live process with a working EHR timestamp feed |
| Gate weeks | W5/W9/W15/W21 (21-week program) |

## 1. Problem statement

- Y and baseline: door-to-provider minutes, median **52.0** (n = 80, sd 16.5).
- Gap: 52.0 vs the **30-minute** standard — 22.0 minutes at the median, with
  **93.8%** of sampled visits breaching.
- Who is hurt: every boarding-bound patient; the breach rate compounds
  left-without-being-seen risk.

## 2. Goal statement

| CTQ | Y | Baseline | Target | OD | Gate |
|---|---|---|---|---|---|
| CTQ-S1 | door-to-provider median | 52.0 min | <= 30 min | EHR timestamp diff triage-start -> provider-first-contact, all visits | W21 |
| CTQ-S2 | % visits over 30 min | 93.8% | <= 25% | same OD, weekly census | W21 |

Two gates, one OD: a median gate and a breach-rate gate measure different
failure modes (central shift vs tail), so both are carried.

## 3. Business case

LWBS revenue leakage + EMTALA exposure; the ED administrator converts breach
volume (75/80 of sample, scaled to census) to annualized leakage at the W5 gate.

## 4. Scope

- In: arrival -> triage -> provider-first-contact for walk-in ESI 3-5.
- Out: EMS-direct admissions (bypass front-end; separate OD), ICU boarders.

## 5. Team

Sponsor: ED medical director. Process owner: charge-nurse lead. Data steward:
EHR analyst (timestamp validation is weekly from W1 — this dataset's feed works,
which is exactly why the numeric goal is lawful).

## 6. Sign-off conditions

Every number replays from the CSV (court-checked); the 30-minute standard is
cited to the hospital policy document, not asserted.
