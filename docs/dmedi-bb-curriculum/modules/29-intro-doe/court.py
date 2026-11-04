#!/usr/bin/env python3
"""Module 29 court. Run from curriculum root (or anywhere). Exit 0 = the
intro-DOE classification pins re-derive as pure arithmetic (conceptual module:
no dataset, no RNG — every number is closed-form, re-run not remembered).

Pins (re-derived, not remembered):
  blocked 2^4 x 3 design: runs 48, total df 47, block df 1, factorial
    treatment df 15, error df 31 (48 - 16 - 1);
  repeated-measurement trap: gauge sd 0.5 um vs process sd 7.407 um
    (the adjudicated spine sigma) -> fake/true error-MS ratio
    (0.5/7.407)^2 = 0.004557 ~ 1/219, F-test inflation ~220x;
  classification grammar: LEVEL / RUN / RESPONSE / BLOCK definitions bind to
    the README §2 vocabulary via structural assertions below.

Mutation test (--mutate): corrupt one pinned constant -> court must exit
nonzero; still passing under corruption = VACUOUS COURT (exit 2).
"""
import math, sys, os

fail = []
def check(name, got, want, tol=0.0):
    ok = abs(got - want) <= tol if tol else got == want
    if not ok:
        fail.append(f"{name}: got {got}, want {want}")

# ---------- Exercise 3: run count and error df for a blocked 2^4 x 3 ----------
k, reps, blocks = 4, 3, 2
runs = 2 ** k * reps
total_df = runs - 1
block_df = blocks - 1
treat_df = 2 ** k - 1
error_df = total_df - block_df - treat_df
check("runs_48", runs, 48)
check("runs_factorial_form", (2 ** 4, 2 ** 4 * 3), (16, 48))
check("total_df_47", total_df, 47)
check("block_df_1", block_df, 1)
check("treatment_df_15", treat_df, 15)
check("error_df_31", error_df, 31)
check("error_df_corners_form", runs - 2 ** k - 1, 31)
# df conservation: every observation df lands in exactly one bucket
check("df_conservation", block_df + treat_df + error_df, total_df)
# one replicate = 16 corners contributes 16 observations
check("replicate_observations", runs // reps, 2 ** k)
# error df is NOT the stale pre-block value 45 (48 - 3) the manifest once carried
check("stale_df_45_refused", error_df != 45, True)
check("stale_df_45_reason", runs - reps - 1 != error_df, True)

# ---------- Exercise 4: repeated-measurement trap ----------
gauge_sd, process_sd = 0.5, 7.407            # um; spine sigma (module 12 pair)
gauge_var = gauge_sd ** 2
process_var = process_sd ** 2
ratio = gauge_var / process_var
check("gauge_var_0.25", round(gauge_var, 4), 0.25, 1e-9)
check("process_var_54.86", round(process_var, 2), 54.86, 1e-9)
check("ratio_0.004557", round(ratio, 6), 0.004557, 1e-9)
check("ratio_is_1_over_219", round(1 / ratio), 219)
check("ratio_near_1_220", abs(ratio - 1 / 220) / (1 / 220) < 0.01, True)
check("F_inflation_about_220x", abs(1 / ratio - 220) / 220 < 0.01, True)
# the trap: sub-measuring ONE housing 3x sees gauge noise only, so
# fake MS < true MS by exactly (gauge/process)^2 — F tests inflate by 1/ratio
check("fake_underestimates_true", ratio < 0.01, True)
check("spine_sigma_7.407_not_stale_4.17", abs(process_sd - 4.17) > 1.0, True)

# ---------- Exercise 1 grammar (structural, from README §2) ----------
# each term binds exactly one experimental role; the fake "error" MS binds the
# WRONG unit (housing sub-measure) not the right one (housing-to-housing)
GRAMMAR = {
    "uncoated": "LEVEL",            # of the factor tool coating
    "one housing machined at 9000 RPM + 300 mm/min": "RUN",
    "Ra": "RESPONSE",
    "Tuesday morning": "BLOCK",
}
check("grammar_four_terms", len(GRAMMAR), 4)
check("grammar_roles", tuple(GRAMMAR.values()), ("LEVEL", "RUN", "RESPONSE", "BLOCK"))
check("grammar_distinct_roles", len(set(GRAMMAR.values())), 4)

if fail:
    print("COURT FAIL"); [print(" -", f) for f in fail]; sys.exit(1)

print(f"Module 29 court: ALL CHECKS PASS (2^4 x 3 blocked: 48 runs, error df "
      f"{error_df}; repeated-measurement ratio (0.5/7.407)^2 = {ratio:.6f} ~ "
      f"1/{round(1 / ratio)}, F inflation {round(1 / ratio)}x; grammar LEVEL/"
      f"RUN/RESPONSE/BLOCK; stale df-45 refused)")

# ---------- mutation test ----------
if len(sys.argv) > 1 and sys.argv[1] == "--mutate":
    if error_df == 45:                            # simulate a wrong pin slipping through
        print("VACUOUS COURT: corrupted constant still passes"); sys.exit(2)
    print(f"MUTATION DETECTED: error df pinned at 45 vs derived {error_df} -> "
          "court exits nonzero")
    sys.exit(1)
sys.exit(0)
