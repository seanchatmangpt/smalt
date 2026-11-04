# Module 31 Exercises — 2^(5−2) Fractional Factorial (Alias Chains)

Source: `data/fractional-2k5-2.csv` (16 rows, seed 43108, registered — no new
seeds). Every number below is pinned by `court.py` (exit 0 = defining-group
closure, 8×4 chains, 7 chain effects, pure error, fold-over parity, res-IV
cosets all re-derive; wrong-generator mutation detected). Re-run, do not trust.

**Time: 40 min** (Ex 1: 12 min, Ex 2: 10 min, Ex 3: 8 min, Ex 4: 10 min).

## Exercise 1 — Build the defining relation by hand (12 min)

Generators D = AB, E = AC. Derive the full defining group, the resolution, and
the alias chain of A. Court pins: words {I, ABD, ACE, BCDE}, resolution III,
chain A = BD = CE = ABCDE.

### Key (derivation shown)

- D = AB → ABD joins I; E = AC → ACE joins I.
- Closure: ABD·ACE = A²BCD²E = BCDE. Group = {I, ABD, ACE, BCDE} (4 words —
  court: `closure_stable`, `defining_words`).
- Shortest word length 3 → **resolution III** (main effects aliased with
  2-factor interactions).
- Chain of A: A·I = A; A·ABD = BD; A·ACE = CE; A·BCDE = ABCDE.
  **A = BD = CE = ABCDE** — every one of the 32 effects sits in exactly one of
  8 chains of size 4 (court: `n_chains`, `chain_sizes`).

## Exercise 2 — Read the effects table against the alias chains (10 min)

The court re-derives from the CSV (contrast means, seed 43108 data):

| chain | effect (um) |
|---|---|
| A / BD / CE / ABCDE | −7.948 |
| B / AD / CDE / ABCE | +6.231 |
| C / AE / BDE / ABCD | −4.159 |
| D / AB / BCE / ACDE | +2.846 |
| BC / DE / ABE / ACD | +2.240 |
| E / AC / BCD / ABDE | −0.645 |
| BE / CD / ABC / ADE | +0.159 |
| mean | +9.751 |

(a) Verify mechanically that aliased contrasts are bit-identical
    (eff(A) == eff(BD) == eff(CE) == eff(ABCDE)).
(b) The D chain carries +2.846. Which planted term is wearing the D label, and
    why can you tell?

### Key (derivation shown)

(a) D = AB means the D column of the design matrix IS the AB product column, so
    Σ(x_D·y) and Σ(x_A·x_B·y) sum over the identical 16 signed values — the
    contrasts cannot differ (court: `alias_identical_A/BC/BE`, exact equality).
(b) The plant is **AB = +3**; D itself was planted at 0. You can tell because
    the generator D = AB welds the D column to the AB column — resolution III
    means a 2-fi can masquerade as a main effect. Confirmation path: fold over
    all factors (Ex 3), which breaks every main/2-fi weld and re-labels the
    +2.846 as AB (court: `D_chain_is_AB_wearing_label`).

## Exercise 3 — Pure error and the noise floor (8 min)

Compute the pure-error SD from the 8 replicate pairs and classify the E and BE
chains against it. Court pins: sd = 1.734 um on df 8; |E| = 0.645, |BE| = 0.159
both below it.

### Key (derivation shown)

pure-error var = Σ(y_rep1 − y_rep2)² / (2·8) → sd = **1.734 um** (planted 1.5,
consistent at df 8). The E chain (−0.645) and BE chain (+0.159) sit inside the
noise floor — no fold-over budget should be spent resolving them. Chains
≥ ~2.2 um (D, BC chains) are real signals pending alias resolution.

## Exercise 4 — Fold-over parity and the resolution IV upgrade (10 min)

Flip ALL five factors in a second 8-run block. Using word-length parity, state
which defining words break and which survives, then give the new alias of A and
of BC. Court pins: ABD breaks, ACE breaks, BCDE survives; fold pairs A=ABCDE,
AB=ACDE, BC=DE, BD=CE, BE=CD.

### Key (derivation shown)

A word W changes sign iff it contains an odd number of flipped letters:

- ABD (3 letters, odd) → breaks. ACE (3, odd) → breaks. BCDE (4, even) →
  **survives**. Combined design: I = BCDE only ⇒ **resolution IV**.
- Res-IV cosets (16 pairs): **A = ABCDE** (a 4-fi — every main effect is clear
  of all 2-fi; court: `main_effects_clear_of_2fi`); AB = ACDE (2-fi fully
  clear); **BC = DE**, BD = CE, BE = CD (2-fi pair up with each other).
- What broke: all six main/2-fi welds (A=BD, A=CE, B=AD, C=AE, D=AB, E=AC).
- If BD = CE is still live after fold-over, escalate to a targeted full 2^2 in
  the implicated factors rather than a third fraction.

## See also

README §3 (hand derivation), §5 (analysis walkthrough), §6 (fold-over);
`solution-key.md` (court receipts); Module 32 (curvature — the next failure
mode after aliasing is handled).
