# Module 01 Lab — First Receipt: Derive the Baseline Yourself

90 min. Tools: python3 stdlib only. Deliverable: a five-field receipt for your
own derivation of the CPPC baseline Cpk from the raw CSV.

## Setup

From the curriculum root `/Users/sac/smalt/docs/dmedi-bb-curriculum`. Dataset:
`modules/01-intro-dmedi/data/baseline-bore-diameter.csv`
(50 rows: run, date, operator, bore_diameter_mm).

## Part 1 — derive (30 min)

1. Load the CSV with `csv.DictReader`; report n.
2. Compute mean and sample sd (n-1 denominator).
3. Compute the distance from mu to USL (12.025) and to LSL (11.975) in um.
4. Compute Cpk = min(gap)/(3 s).
5. Re-derive the pinned constant: Cpk = (12.025 - 12.009)/(3 x 0.007407).
6. Compute what the STALE sigma (4.17 um) would imply for Cpk and note the
   contradiction (this is the adjudicated 2026-11-04 correction; see
   RUNNING-CASE.md and slides-outline Slide 6).

## Part 2 — reconcile (20 min)

Answer in writing, each one sentence:
1. Does sample mu agree with the pinned mu? To how many decimals?
2. Sample s (5.82 um) vs pinned sigma (7.407 um): state which of the two lawful
   explanations applies (sampling variation vs process shift) and the evidence.
3. Which spec side governs, and why does that make the baseline an upper-tail
   problem?

## Part 3 — write the receipt (25 min)

Write your receipt in the five-field format (Slide 7), then exchange with a
partner who must REPLAY it:

- identity: subject = the CSV path + row count + spec limits used
- authority: who admits (instructor court / self-check court)
- consequence: the actual printed numbers, pasted
- replay: the exact command (`python3 - <<EOF ... EOF`), runnable from the
  curriculum root
- standing: PASS as of <date>, against which pin

## Part 4 — vacuity probe (15 min)

Partner mutation: silently change one number in your consequence field. The
replaying court (partner) must REFUSE — the replayed output no longer matches
the receipt. If your receipt format allowed the mutation to pass, your receipt
was narrative, not evidence. Record which field caught the mutation (it is
always consequence + replay together).

## Receipts

- Dataset: 50 rows, verified `python3`-derived (see `solution-key.md` output).
- Court: `python3 modules/01-intro-dmedi/courts/court.py` — exit 0 = all
  derivations and pinned-pair checks pass.
