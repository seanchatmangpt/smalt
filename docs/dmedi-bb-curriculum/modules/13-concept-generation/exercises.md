# Module 13 Exercises — Concept Generation

Complete the workshop (`workshop.md`) sections W1-W7, then do the following.
All numbers re-derive from `datasets/concept-portfolio.csv` via
`scripts/score_concepts.py` (run from the `docs/dmedi-bb-curriculum` root).
The CPPC spine constants are pinned by the workshop: bore 12.000 mm
+/- 0.025 mm, baseline Cpk 0.72, target Cpk >= 1.33, unit-cost ceiling
$28.50.

1. **E1 — Funnel arithmetic drill.** Confirm the workshop W3 conservation
   rule: merges = raw cards - distinct concepts. Verify the reference run
   (12 raw -> 8 concepts = 4 merges, per `solution-key.md` K2/K3) and then
   compute merges for 15 raw -> 8 concepts and for your own W1/W2 card
   counts. State the rule in one sentence.
2. **E2 — Score re-derivation.** Score your W2 concept set by hand using
   Score = 0.4 x novelty + 0.6 x feasibility, then run
   `python3 modules/13-concept-generation/scripts/score_concepts.py` and
   confirm your C1..C8 hand scores match the script's to two decimals
   (C1 4.20 top, C8 2.60 bottom). Explain why the feasibility-heavy weights
   make C8's novelty 5 unsalvageable.
3. **E3 — Episodic-to-continuous audit.** From your W4 function model, list
   every harmful function and mark which of your concepts convert an
   episodic function to a continuous one. Check against the reference set:
   C1 and C7 both convert the episodic operator trial cut; any concept that
   converts an episodic function attacks both offset and variation. Name
   one concept in the portfolio that attacks only one function and state
   what it misses.
4. **E4 — Decision memo discipline.** Write your W7 memo, then audit it
   against the reference (solution-key K7): it must kill one concept
   permanently (C8), park one against a named CTQ (C4 vs CTQ-3, cost
   ceiling $28.50), and name a fallback that fails differently from the
   pilot (C7). A memo that kills or parks nothing is incomplete — a
   portfolio decides.

## See Also

- `workshop.md`
- `solution-key.md`
- `datasets/concept-portfolio.csv`
- `scripts/score_concepts.py`
