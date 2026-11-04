# Module 12 — Process Capability

**DMEDI phase**: Measure · **Runtime**: 4 h · **Prerequisites**: Module 10 (control charts), Module 11 (MSA)

## Order law (recap)

MSA first (module 11 verdict: gage marginal-acceptable for process analysis),
stability second (control chart), **only then** capability. A capability index
on an unstable or badly measured process is fiction with a decimal point.

## Learning objectives

1. Derive **Cp/Cpk** (within, σ = R̄/d₂) and **Pp/Ppk** (overall, sample s)
   from **raw measurements** — never from a remembered constant.
2. Check the **stability precondition** with the X̄-R chart before interpreting
   any index.
3. Test **normality** and execute the **transformation decision** (Box-Cox,
   with Johnson as the alternative) — and see a case where the transformation
   **changes the capability verdict**.
4. Estimate expected PPM from Z-scores and reconcile against observed defects.

## Labs

| lab | dataset | key |
|---|---|---|
| [Capability derivation + spine court](labs/capability-derivation.md) | `data/cpk072-bore-subgroups.csv` | `keys/capability_key.py` |
| [Non-normal capability lab](labs/non-normal-capability.md) | `data/flatness-lognormal.csv` | `keys/capability_key.py` (part 4) |

Dataset provenance: `datasets/MANIFEST.md` (seeds 512, 1203).

## The spine re-derivation (module's court)

The running case pins **Cpk = 0.72** on the bore. Module 12 re-derives it from
raw measurements: 25 subgroups × 4, σ_within = R̄/d₂ = 0.007407 mm,
grand mean 12.0090 mm →

  Cpk = min(12.025 − 12.009, 12.009 − 11.975)/(3 × 0.007407) = **0.72** ✓

**Spine-sigma note (ADJUDICATED 2026-11-04, see RUNNING-CASE.md)**: the ORIGINAL
spine sigma = 4.17 um was inconsistent with the pinned Cpk = 0.72 and mu = 12.009
(0.016/(3 × 0.00417) = 1.28) and was adjudicated stale. The adjudicated coherent
pair is **sigma = 7.407 um with mu = 12.009** (reproduces Cpk = 0.72 exactly). Lane 04's raw individual baseline
(`data/bore-baseline-100.csv`, seed 42008) re-derives Ppk = 1.24 overall —
that dataset was drawn at the 4.17 um scale and cannot serve as the 0.72
baseline. Downstream modules: use `data/cpk072-bore-subgroups.csv` for any
"baseline Cpk = 0.72" narrative.

## Capability vs performance — the four indices

| index | sigma used | answers |
|---|---|---|
| Cp / Cpk | within (R̄/d₂) | what the *process* can do when centered/stable (short-term) |
| Pp / Ppk | overall (sample s) | what the *customer* actually received (long-term) |

On the spine dataset: Cp 1.12 / Cpk 0.72 / Pp 1.32 / Ppk 0.84. Cpk < Ppk
here tells the improvement story: subgroup-level (short-term) variation is
larger than the between-subgroup drift over the study — and the mean sits
9 um above target, so **centering the mean buys Cpk 0.72 → 1.12** (Cp) with
zero variation reduction. That is the cheapest first move, and it is exactly
the gap the Define gate (Cpk ≥ 1.33) must close.

## Timing (per activity)

- Capability-derivation lab, Steps 1-6 (`labs/capability-derivation.md`) (90 min)
- Non-normal capability lab, Steps 1-6 (`labs/non-normal-capability.md`) (50 min)
- Key run + court exits: `keys/capability_key.py` (all four courts) (10 min)
- Index interpretation drill (Cp vs Cpk vs Pp vs Ppk verdict writing) (20 min)
- Spine-sigma adjudication discussion (coherence across modules) (10 min)

Total: 3 h lab + drill; the 4 h Runtime header leaves 1 h for the Module 11
prerequisite recap and gate checklist.
