# Worksheet 03 — Filled Charter Example 2 (Transactional): Insurance Claims Cycle Time

Template fields filled from `data/insurance-claims-cycle-time.csv`
(python3 re-derivation: n = 60; mean 16.07 d; median 15.8 d; sd 4.88 d; max
26.6 d; `closed_date` blank on **60/60** rows). This example teaches the
honest charter: a baseline you cannot replay gets an action row, not a quote.

## Header

| Field | Entry |
|---|---|
| Project name | Claims cycle time: close the loop from FNOL to disbursement |
| Business unit | Personal-lines claims operations |
| Method | DMAIC — the claims process exists and produces data daily |
| Gate weeks | W5/W9/W15 (13-week program) |

## 1. Problem statement

- Reported Y: claims cycle time, mean 16.07 d (n = 60).
- Evidentiary standing: **UNVERIFIED** — `closed_date` is blank on all 60 rows,
  so no cycle-time figure in the extract can be replayed against its own
  timestamps. The number describes the metric; it cannot yet audit it.
- Customer impact (claimed, pending re-pin): payments delayed ~16 days median
  against an internal 10-day service standard.

## 2. Goal statements

| CTQ | Y | Baseline | Target | OD | Gate |
|---|---|---|---|---|---|
| CTQ-T1 | claims cycle time | UNVERIFIED (16.07 d reported) | <= 10 d median | NEW OD: ERP timestamp diff opened_date -> closed_date, full population | W5 (re-pin) then W15 |
| CTQ-T2 | data integrity | 0/60 rows auditable | 100% of rows carry both timestamps | OD: field-completeness report, weekly | W5 |

Note the two-row structure: you cannot honestly promise a cycle-time target on
a baseline that does not yet exist as evidence, so the first gate buys the
measurement, the second buys the result.

## 3. Business case

- Penalty interest + regulatory exposure on late settlements, scaled by the
  confirmed (post-re-pin) baseline delta; placeholder arithmetic is refused at
  this gate — the number ships after W5.

## 4. Scope

- In: FNOL -> assignment -> estimate -> approval -> disbursement timestamps.
- Out: fraud-investigation claims (different OD; different tail).

## 5. Team

Sponsor: claims VP. Data steward: **named, gate W5** — the critical role here.

## 6. Sign-off conditions

The charter signs WITH the UNVERIFIED standing recorded and the W5 re-pin
action row attached. Signing against the unverifiable 16.07 d is the failure
mode this example exists to teach.
