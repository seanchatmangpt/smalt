# Workshop — Module 13 Concept Generation

Work in the CPPC spine (12.000 mm +/- 0.025 mm bore; baseline Cpk = 0.72;
target Cpk >= 1.33; unit-cost ceiling $28.50). Show your funnel and your
arithmetic; answers that cannot be re-derived receive zero credit.

## W1. Structured brainstorming run (pairs, 25 min)

Using the three stimulus prompts from the README (function / constraint /
resource), produce exactly 12 raw idea cards against the bore-accuracy gap.
Rules: one idea per card, no evaluation during capture, each card names the
function it attacks (offset, variation, or both).

Deliverable: a numbered card list with the attacked function annotated.

## W2. Affinity mapping (15 min)

Merge your cards into a distinct concept set of 8 (you may not score two cards
that share a mechanism). For each merge, write the one-line rule that justified
it (same reference holder? same actuator? same physical effect?).

## W3. Funnel arithmetic (5 min)

Confirm: 12 raw -> 8 concepts implies 4 merges. If your team produced 15 raw
cards targeting 8 concepts, how many merges are implied? State the general
rule.

## W4. Function-analysis ideation (20 min)

Draw the function model of the boring operation (at minimum: bar, tool,
coolant, spindle, operator). Identify every harmful function, then generate one
concept per harmful function. Mark which of your concepts are "episodic to
continuous" conversions.

## W5. SCAMPER one pass (15 min)

Fill the full SCAMPER table for the current single-pass manual-offset process.
At least two letters must produce concepts NOT already in the module's
portfolio; state why they were or were not better than C1.

## W6. Scoring (10 min)

Score your own 8 concepts using the module's novelty/feasibility anchors
(1-5 each, weights 0.4/0.6). Compute by hand and then verify with:

```bash
python3 modules/13-concept-generation/scripts/score_concepts.py
```

(from the `docs/dmedi-bb-curriculum` root). Your hand arithmetic must match the
script's to two decimals.

## W7. Portfolio decision memo (10 min)

Write a 5-line memo: which concept enters the week-9 pilot, which is the named
fallback, which is killed and why, which is parked and against which CTQ. A
memo that kills nothing or parks nothing is incomplete — a portfolio decides.

## See Also

- `solution-key.md`
- `README.md`
