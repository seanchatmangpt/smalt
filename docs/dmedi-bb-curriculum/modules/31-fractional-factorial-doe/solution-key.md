# Solution Key — Module 31 Fractional Factorial (2^(5−2), seed 43108)

Every number below was re-derived from `data/fractional-2k5-2.csv` (read back from
disk) in this session; the alias algebra is machine-checked by group closure.
Commands shown are the actual court runs; each exits 0 on pass.

## 1. Court 1 — alias group closure (verified)

```python
# generators D=AB, E=AC -> defining words ABD, ACE; closure over all products
words = {0b01001: "ABD", 0b10100: "ACE"}     # A^B^D, A^C^E (bitmask per letter)
# closure: {0, ABD, ACE, ABD*ACE}
# ABD*ACE = A^2 B C D^2 E = BCDE  ->  4 words: I, ABD, ACE, BCDE
```

Machine check: the defining group has exactly 4 words `{I, ABD, ACE, BCDE}`;
the 32 effects partition into exactly 8 cosets of size 4:

```
A  = BD = CE = ABCDE
B  = AD = CDE = ABCE
C  = AE = BDE = ABCD
D  = AB = BCE = ACDE
E  = AC = BCD = ABDE
BC = DE = ABE = ACD
BE = CD = ABC = ADE
I  = ABD = ACE = BCDE
```

Line-by-line worked example (chain of A), by hand:

- A·I = **A**
- A·ABD = A·A·B·D = **BD** (AA = I)
- A·ACE = **CE**
- A·BCDE = **ABCDE**

max word length in the defining relation = 3 ⇒ resolution III. PASS.

## 2. Design construction (seed 43108)

Base = full 2^3 in A, B, C (Yates order); D = A·B, E = A·C read off per row.
Replicated twice (replicate blocks 1 and 2), run order shuffled within replicate
with `random.seed(43108)`. Generator script:

```python
random.seed(43108)
for rep in (1, 2):
    for (A, B, C) in [(a,b,c) for a in (1,-1) for b in (1,-1) for c in (1,-1)]:
        D, E = A*B, A*C
        dev = 9.0 - 8*A + 6*B - 4*C + 3*A*B + 2*D*E + random.gauss(0, 1.5)
```

Planted truth (um, deviation from 12.000 mm): intercept 9, A −8, B +6, C −4,
AB +3, DE +2, noise sd 1.5. File shape: 16 rows × 9 cols
(`replicate, std_order, run_order, A_speed, B_feed, C_coolant, D_coating,
E_toolholder, bore_deviation_um`). Court: `csv.DictReader` reads back exactly 16 rows — exit 0.

## 3. Court 2 — effects re-derived from the raw CSV (exit-checked)

```python
data = list(csv.DictReader(open("data/fractional-2k5-2.csv")))
assert len(data) == 16
# contrast of any product of letters = product of the factor columns
eff("A") == eff("B","D") == eff("C","E")   # alias contrasts bit-identical: PASS
```

Derived effects (um), sorted by |effect| — every alias chain shares one number by
construction (verified: all 8 sampled chain-equivalences identical):

| chain (as estimated) | effect (um) | contains (planted) |
|---|---|---|
| A / BD / CE / ABCDE | **−7.948** | A = −8 |
| B / AD / CDE / ABCE | **+6.231** | B = +6 |
| C / AE / BDE / ABCD | **−4.159** | C = −4 |
| D / AB / BCE / ACDE | **+2.846** | **AB = +3** (D itself = 0!) |
| BC / DE / ABE / ACD | **+2.240** | **DE = +2** |
| E / AC / BCD / ABDE | −0.645 | nothing (noise) |
| BE / CD / ABC / ADE | +0.159 | nothing (noise) |
| mean | +9.751 | intercept 9 + noise |

Reading: the third-largest coefficient sits on the **D chain**, and the plant is
AB — an interaction masquerading as a main effect because D = AB was the
generator. The E chain (−0.645 um) and BE chain (+0.159 um) are indistinguishable
from noise. This is the worked demonstration of §5 of the README.

## 4. Pure error from the replicate pairs

```
pure-error variance = sum (y_rep1 - y_rep2)^2 / (2 * 8)  ->  sd = 1.734 um
```

(the planted sd is 1.5; the estimate is consistent at df = 8). Chains ≤ ~0.2 um
are noise; chains ≥ ~2.2 um are real signals pending alias resolution.

## 5. Court 3 — fold-over derivation (exit-checked)

Fold over ALL five factors (flip every sign in a second 8-run block). A defining
word W changes sign iff it contains an odd number of flipped letters:

| word | letters | parity | fate |
|---|---|---|---|
| ABD | 3 | odd | breaks (−ABD) |
| ACE | 3 | odd | breaks (−ACE) |
| BCDE | 4 | even | survives (+BCDE) |

Combined design: I = BCDE only ⇒ resolution IV. Recomputed alias table (16 pairs,
each effect aliased with exactly one partner):

```
A=ABCDE  B=CDE   C=BDE   D=BCE   E=BCD      (main effects clear of ALL 2-fi)
AB=ACDE  AC=ABDE AD=ABCE AE=ABCD            (these 2-fi fully clear)
BC=DE    BD=CE   BE=CD                      (these 2-fi pair up)
```

Machine check: sign-flip parity derived from word lengths {3,3,4} → survivor set
{BCDE}; cosets of {I, BCDE} recomputed and match the table above — exit 0.

Which aliases break, stated plainly: **A=BD, A=CE, B=AD, C=AE, D=AB, E=AC all
break** (every main-effect/2-fi weld). What survives: BC=DE, BD=CE, BE=CD
(interaction-interaction pairs) and single 4-fi aliases of main effects. If the
BD=CE pair is still live after fold-over, escalate to a targeted full 2^2 in the
implicated factors rather than a third fraction.

## 6. Minitab mirror

Stat > DOE > Factorial > Create: 5 factors, 8 runs, generators D=AB, E=AC;
Analyze with effects table + Pareto. Fold-over: Pre-Process > Fold Over Design >
all factors. Expected Minitab effect values = §3 table (within rounding).

## Standing

ALIVE. Courts: group closure (PASS, exit 0), 16-row read-back + bit-identical
alias contrasts (PASS, exit 0), fold-over parity + res-IV coset recompute
(PASS, exit 0). Data registered in MANIFEST.md (seed 43108).
