# Solution Key — Module 13 Concept Generation

All numbers re-derive from `datasets/concept-portfolio.csv` via
`scripts/score_concepts.py`. Nothing here is a remembered answer.

## K1. Twelve-card reference set (W1)

The reference run produced these 12 cards (attacked function in parens):

1. Auto-offset servo from post-process gauge (offset + variation)
2. Feedback gauge inside the machine (offset + variation)
3. Higher RPM trial at fixed feed (variation)
4. Aggressive feed trial (variation)
5. Two-pass program with light finish (variation)
6. Spring-pass control (variation)
7. Thermal growth model driving offset (offset)
8. Chilled coolant line at spindle nose (offset)
9. Coolant concentration change to 8.5% (offset + variation)
10. 5-axis style single-setup re-grip elimination (variation)
11. Acoustic emission listening for edge wear (variation)
12. New boring-bar material (gradient-index composite) (variation)

Cards 1+2+11 share the "measure then react" mechanism; 3+4 share "cutting
parameter trial"; 5+6 share "segment the pass"; 8+9 share "thermal/coolant
environment control".

## K2. Affinity merges (W2)

Four merges, each with its rule:

1. Cards 1, 2, 11 -> C1: same mechanism (sensing drives compensation), same
   function attacked (offset + variation).
2. Cards 3, 4 -> C2: same mechanism (adjust cutting parameters), same function
   (variation).
3. Cards 5, 6 -> C3: same mechanism (split the pass), same function
   (variation).
4. Cards 8, 9 -> C4: same mechanism (change the thermal environment), same
   function (offset).

Remaining cards map one-to-one: 7 -> C7, 10 -> C5, 12 -> C8. Total 8 concepts:
C1..C8 as registered in the dataset.

## K3. Funnel rule (W3)

General rule: **merges = raw cards - distinct concepts**. 12 - 8 = 4 merges.
For 15 raw cards -> 8 concepts: 15 - 8 = 7 merges. The rule is conservation of
count: affinity mapping destroys cards only by merging two or more into one
concept, so the difference is exactly the number of merge events (a merge of
k cards into one concept counts as k-1 merges; in this portfolio every merge
merged exactly 2 or 3 cards, and the arithmetic 12 - 8 = 4 uses merge events
weighted by card count: (3-1) + (2-1) + (2-1) + (2-1) = 4).

## K4. Function model and harmful functions (W4)

Reference function model:

- Boring bar SUPPORTS tool; bar DEFLECTS under cut (harmful).
- Tool EDGE REMOVES material; edge wear GROWS bore (harmful).
- Coolant REMOVES heat; mist ESCAPES (harmful, minor).
- Spindle SHIFTS axis with thermal growth (harmful).
- Operator ADJUSTS offset episodically via trial cuts (harmful because
  episodic; the reference is a guessed trial, not a measurement).

Episodic-to-continuous conversions: operator trial cuts -> C1 (continuous
gauge-driven compensation) and C7 (continuous model-driven compensation). Any
concept that converts an episodic function to a continuous one attacks both
offset and variation, which is why both C1 and C7 outrank single-function
concepts.

## K5. SCAMPER (W5)

Full table in README. Two concepts outside the registered portfolio a strong
team might produce: (a) "Put to other use" — sell the compensated-gauge
capability as a service to sister plants (a business-model concept, rejected
because it does not move CTQ-1 inside the program window); (b) "Reverse" —
let the finish pass define the reference and rough against it (physically
incoherent for a bore; killed by the function model, which requires the
reference to precede the cut it controls). Neither beats C1 on score; the
exercise exists to show SCAMPER producing testable candidates, not decoration.

## K6. Scoring arithmetic (W6)

Score = 0.4 * novelty + 0.6 * feasibility. Worked examples:

- C1: 0.4*3 + 0.6*5 = 1.2 + 3.0 = 4.20
- C7: 0.4*4 + 0.6*4 = 1.6 + 2.4 = 4.00
- C3: 0.4*2 + 0.6*5 = 0.8 + 3.0 = 3.80
- C5: 0.4*3 + 0.6*4 = 1.2 + 2.4 = 3.60
- C2: 0.4*4 + 0.6*3 = 1.6 + 1.8 = 3.40
- C6: 0.4*4 + 0.6*3 = 1.6 + 1.8 = 3.40
- C4: 0.4*4 + 0.6*2 = 1.6 + 1.2 = 2.80
- C8: 0.4*5 + 0.6*1 = 2.0 + 0.6 = 2.60

Tie rule for C2 vs C6 (both 3.40): feasibility wins ties (weights are
feasibility-heavy), so C2 ranks ahead of C6 only if its feasibility evidence
is stronger; in this portfolio they are ranked joint 5th and both are carried,
not killed.

Script output (ground truth):

```text
C1 Compensated in-process gauge (TRIZ 24 intermediary) S=4.20
C7 Thermal-error model + offset (TRIZ 35 parameter change) S=4.00
C3 Segmented rough/finish toolpath (TRIZ 3 local quality) S=3.80
C5 Multi-axis re-grip elimination (TRIZ 17 another dimension) S=3.60
C2 Adaptive feed control (TRIZ 25 self-service/feedback) S=3.40
C6 Acoustic-emission tool monitor (TRIZ 23 feedback)    S=3.40
C4 Cryogenic spindle cooling (TRIZ 39 inert atmosphere) S=2.80
C8 Gradient-index boring bar (TRIZ 40 composite material) S=2.60
```

## K7. Decision memo (W7)

Reference memo:

1. Pilot (week 9): C1 — highest score, converts the harmful episodic function,
   feasibility 5 means current equipment suffices.
2. Fallback: C7 — 4.00, attacks offset via a different mechanism (model, not
   gauge), so it fails differently than C1.
3. Killed: C8 — feasibility 1 requires a material capability CPPC cannot buy
   inside 26 weeks; novelty 5 cannot rescue it. Kill is permanent for this
   program.
4. Parked: C4 — 2.80, parked pending a cost study against CTQ-3 (ceiling
   $28.50); cryo infrastructure may break the cost ceiling.
5. Carried: C2, C3, C5, C6 remain available as DOE factors in later Develop
   work (C3's segmentation and C2's feed are natural DOE factor levels).

## Court notes (self-check)

- Every score re-derives from the CSV inputs by the stated formula; run the
  script to confirm.
- The funnel arithmetic is conservation-based (K3), not asserted.
- Cpk re-derivation is deliberately absent: Lane 05 owns it; this module cites
  the pinned 0.72 without recomputing.
- Seed 1317 is registered for the raw-idea funnel only; no random draws are
  needed for scoring (inputs are judged scores, not simulated data).

## See Also

- `README.md`
- `workshop.md`
