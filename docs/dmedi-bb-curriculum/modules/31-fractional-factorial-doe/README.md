# Module 31 — Fractional Factorial Designs: Generators, Aliases, and the CPPC 5-Factor Screen

Case: CPPC bore-deviation screen, five machining factors (`data/fractional-2k5-2.csv`,
seed 43108). Prerequisite: Module 30-level full factorial intuition (Yates order,
effects = contrast means).

## Learning objectives

- Read and build a 2^(k−p) design from its **generator table**: choose p generators,
  multiply them out, derive the defining relation.
- Derive an alias structure **by hand** using the defining-relation algebra, and
  verify it mechanically (python3 group-closure check in the key).
- Apply the resolution hierarchy: why resolution III confounds two-factor
  interactions with main effects, why IV protects main effects, why V isolates
  two-factor interactions.
- Run and interpret a 16-run (two-replicate) 2^(5−2) screen on the CPPC line, and
  design the follow-up fold-over that breaks the dangerous aliases.

**Session timing** (3.5 h total): why fractionate + price of aliasing, §1
(20 min); generator tables k = 3..7, §2 (25 min); hand derivation of the
2^(5−2) with alias algebra, §3 (45 min); mapping the CPPC screen, §4
(20 min); analysis walkthrough against the CSV, §5 (35 min); fold-over
design, §6 (30 min); Minitab path demo, §7 (10 min); key court re-runs
(30 min); debrief (15 min).

## 1. Why fractionate, and the price

A full 2^k needs 2^k runs to estimate 1 + k + k(k−1)/2 + … + 1 effects. At k = 7
that is 128 runs to pin down 128 orthogonal contrasts — but almost all of them are
5-fi and up, which physics says are negligible. A 2^(k−p) runs 2^(k−p) of the full
cube and *spends* the savings on confounding: effects are no longer estimated
separately; they are estimated as **alias chains**.

The mechanism is group algebra over effect names with multiplication "letters
cancel in pairs, I is the identity":

- Choose p **generators**: word equations that pin a new factor to a product of
  base factors, e.g. D = AB.
- The **defining relation** is the full set of words that equal I: every product
  of generators (and their pairings with I). A 2^(k−p) with p generators has
  2^p defining words.
- The alias set of any effect X is {X·W : W in the defining relation} — a coset
  of the defining group. The 2^(k−1)… effect columns partition into 2^(k−p)
  alias chains, each of length 2^p.

**Resolution** = length of the shortest defining word:

| resolution | what is confounded with what | when to use |
|---|---|---|
| III | some 1-fi aliased with 2-fi | screening: factors few, budget tight, assume sparsity |
| IV | no 1-fi with 2-fi; some 2-fi aliased in pairs | screen + protect main effects |
| V | no ≤2-fi with ≤2-fi (2-fi aliased only with 3-fi) | when 2-fi matter and a full 2^k is unaffordable |

The hierarchy: effects shrink with order (sparsity/heredity), so a res III design
is a *bet* that interactions are small; res IV is the insurance policy; res V is
an audit-grade design at half (or less) of full-factorial cost.

## 2. Generator table, k = 3..7 (resolutions III–V)

| k | runs | design | res | generators | defining relation |
|---|---|---|---|---|---|
| 3 | 4 | 2^(3−1) | III | C = AB | I = ABC |
| 4 | 8 | 2^(4−1) | IV | D = ABC | I = ABCD |
| 5 | 16 | 2^(5−1) | V | E = ABCD | I = ABCDE |
| 5 | 8 | **2^(5−2)** | **III** | **D = AB, E = AC** | **I = ABD = ACE = BCDE** |
| 6 | 32 | 2^(6−2) | IV | E = ABC, F = BCD | I = ABCE = BCDF = DEF |
| 6 | 8 | 2^(6−3) | III | D = AB, E = AC, F = BC | I = ABD = ACE = BCF = DEF = BCDE = ACDF = ABEF = ABCDEF |
| 7 | 64 | 2^(7−1) | VII | G = ABCDEF | I = ABCDEFG |
| 7 | 32 | 2^(7−2) | IV | F = ABC, G = BCD | I = ABCF = BCDG = ADFG |
| 7 | 16 | 2^(7−3) | IV | E = ABC, F = ABD, G = ACD | I = ABCE = ABDF = ACDG = CDEF = BDEG = BCFG = ABCDEFG |
| 7 | 8 | 2^(7−4) | III | D = AB, E = AC, F = BC, G = ABC | I and 15 products of ABD, ACE, BCF, ABCG |

Rule of thumb the table encodes: at 8 runs, k > 4 forces resolution III; at 16
runs, k > 5 forces IV or worse. Resolution is bought with runs.

## 3. The 2^(5−2): hand derivation, line by line

Generators D = AB, E = AC. Defining relation (every way the generators multiply
back to I):

- first powers: **ABD**, **ACE**
- their product: (ABD)(ACE) = A·A·B·C·D·D·E = **BCDE** (squares cancel)
- identity: **I**

so I = ABD = ACE = BCDE — four defining words, 2^p with p = 2. Shortest word
length 3 ⇒ **resolution III**. Eight alias chains of 32/8 = 4 members each; the
chain containing I is empty-effect (error), so 15 df of contrasts pack into 7
estimable chains + mean.

Each chain, derived by multiplying each defining word into the effect
(each line worked and machine-checked in `solution-key.md`):

```
A  = BD = CE = ABCDE        (A  confounded with two 2-fi — the res-III sin)
B  = AD = CDE = ABCE
C  = AE = BDE = ABCD
D  = AB = BCE = ACDE
E  = AC = BCD = ABDE
BC = DE = ABE = ACD
BE = CD = ABC = ADE
I  = ABD = ACE = BCDE       (error/mean chain)
```

Read the first line slowly: if the "A" column moves the response, you *cannot*
know whether it was speed (A), or the speed×feed-style pairings BD and CE, or the
5-fi. That is exactly the risk resolution III accepts in exchange for 8 runs.

## 4. The CPPC 5-factor screen mapped onto the 2^(5−2)

Factors (RUNNING-CASE Develop factors + toolholder), each at two levels chosen
from current operating windows on the SR-71 gimbal line:

| coded | factor | −1 | +1 |
|---|---|---|---|
| A | spindle speed | 6,000 RPM | 9,000 RPM |
| B | feed rate | 1,200 mm/min | 2,400 mm/min |
| C | coolant concentration | 5 % | 12 % |
| D | tool coating | uncoated | coated |
| E | toolholder | standard | shrink-fit |

Generators D = AB, E = AC mean: coated tools are run *with* the high-speed/high-feed
corner (D follows A·B) and shrink-fit holders follow speed×coolant. Design: the
full 2^3 in A, B, C, with D and E read off as products — 8 distinct runs,
**replicated twice → 16 runs** (replication is what funds the pure-error estimate;
see `solution-key.md` §4). Seed 43108; run order randomized within replicate.

## 5. Analysis walkthrough (data/fractional-2k5-2.csv)

Computed in the key from the raw CSV (never from memory):

- effect estimates (contrast means, 16 runs): the A-chain ≈ −7.9, B-chain ≈ +6.2,
  C-chain ≈ −4.2, D-chain ≈ +2.8, BC/DE-chain ≈ +2.2, E-chain ≈ −0.6,
  BE/CD-chain ≈ +0.2 (um).
- interpretation under the alias table: the "D effect" is really **D + AB** — and
  the data were generated with AB = +3 um, so the third-largest "effect" in the
  screen is an interaction wearing a main-effect label. This is the module's
  central lesson: in a res III design, a big coefficient is a *suspect list*, not
  a verdict.
- pure error from the replicate pairs: sd ≈ 1.7 um — every "large" chain clears
  it; the E and BE chains do not.
- judgment call: A and B chains are followed (big, and consistent with physics);
  D/AB and DE chains are ambiguous → fold-over.

## 6. Follow-up fold-over: designed and derived

**Fold-over on all five factors**: run a second 8-run fraction with every sign
flipped (A→−A, …, E→−E). A word changes sign when it contains an *odd* number of
flipped letters:

- ABD (3 letters, odd) → −ABD: **breaks** (no longer in the defining relation)
- ACE (3, odd) → −ACE: **breaks**
- BCDE (4, even) → +BCDE: **survives**

Combined 16-run design defining relation: I = BCDE only ⇒ **resolution IV**.
Which aliases break, derived from the new relation (verified in the key):

- Main effects are now clear of all 2-fi: A = BCDE (its only alias is a 4-fi).
  The res-III sins A = BD and A = CE are *gone*.
- Half the 2-fi become fully clear (aliased only with 3-fi and up):
  AB = ACDE, AC = ABDE, AD = ABCE, AE = ABCD.
- The remaining 2-fi pair up with each other: BC = DE, BD = CE, BE = CD.

So the fold-over resolves exactly the ambiguities the screen flagged — but BD
stays welded to CE; if both chains are still live after fold-over, the next step
is not another fraction, it is a targeted full 2^2 in the implicated factors.

## 7. Minitab path

Stat > DOE > Factorial > Create Factorial Design: 2-level factorial (specify
generators); Analyze Factorial Design with terms through the chains of interest.
The python3 mirror (effects, alias closure, fold-over) is in `solution-key.md`.

## Courts (all exit-checked in the key)

1. Alias derivations verified by python3 group closure: 4 defining words, 8
   chains × 4 members, chain contents match §3 line-for-line.
2. Effects re-derived from the raw CSV (read back from disk, not from constants).
3. Fold-over survivor set derived from word parity (odd letters flip, even
   survive) and the res-IV alias table recomputed from I = BCDE.

## See also

Module 30 (full factorials, Yates order), Module 15 (RSM: what to run when
curvature appears), RUNNING-CASE.md (pinned factor/response definitions).
