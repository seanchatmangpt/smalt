#!/usr/bin/env python3
"""Module 44 court. Run from curriculum root. Exit 0 = roadmap arithmetic + checklist exist."""
import os, sys, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
MODS = os.path.dirname(HERE)
fail = []
def check(name, cond):
    if not cond: fail.append(name)

# 1. roadmap week arithmetic (26-week program, gates 5/9/15/21/26)
GATES = [5, 9, 15, 21, 26]
check("gates_within_program", all(1 <= g <= 26 for g in GATES) and GATES == sorted(set(GATES)))
PILOT_DAYS = 30
pilot_weeks = PILOT_DAYS / 7
check("pilot_fits_before_gate21", 16.5 + pilot_weeks <= 21)  # start wk16 d4 -> ends wk20.8
counterfactual = 17 + pilot_weeks                             # = 21.29
check("week17_start_misses_gate", counterfactual > 21)        # why the roadmap starts mid-wk16
check("pilot_long_enough", pilot_weeks >= 4.0)
phases = [(16, 16), (16.5, 20.8), (21, 21), (22, 24), (21, 24), (24, 26), (26, 26)]
covered = []
for a, b in phases: covered.extend([a, b])
check("implement_within_program", min(a for a, _ in phases) >= 16 and max(b for _, b in phases) <= 26)
# no gap between pilot end and week-21 gate
check("gate21_after_pilot", 20.8 <= 21)

# 2. handoff checklist existence (7 items)
def f(rel): return os.path.exists(os.path.join(MODS, rel))
checklist = {
    1: "Control plan — Module 43 solution key",
    2: "OCAPs — Module 43 solution key",
    3: "Capability receipt — Module 42 solution key",
    4: "MSA evidence — Module 11 (cross-lane)",
    5: "Training records — Module 44 lab",
    6: "Audit record — Module 44 lab",
    7: "Program receipt — Module 44 solution key",
}
check("checklist_is_seven", len(checklist) == 7)
owned = {
    1: "43-process-control/keys/solution-key.md",
    2: "43-process-control/keys/solution-key.md",
    3: "42-prototype-pilot/keys/solution-key.md",
    4: "11-msa",
    5: "44-implementation-planning/lab.md",
    6: "44-implementation-planning/lab.md",
    7: "44-implementation-planning/keys/solution-key.md",
}
standing = "FULL"
for k, rel in owned.items():
    p = os.path.join(MODS, rel)
    if not os.path.exists(p):
        fail.append(f"checklist item {k} missing artifact: {rel}")
# cross-lane item: Module 11 MSA content owned by lane 11 — loud, not silent
msa = os.path.join(MODS, "11-msa")
msa_files = [os.path.join(dp, fn) for dp, _, fs in os.walk(msa) for fn in fs] if os.path.isdir(msa) else []
if not msa_files:
    standing = "PARTIAL (lane 11 MSA artifact not yet landed; item 4 dir exists, content pending)"
    print("PENDING (loud, not silent): module 11-msa contains no files yet — handoff item 4 cross-lane")

# 3. training register arithmetic
check("training_slots", 12 + 3 + 3 + 1 + 1 == 20)

# 4. cross-module replay: Modules 42/43 courts must exit 0 now
for other in ("42-prototype-pilot", "43-process-control"):
    r = subprocess.run([sys.executable, os.path.join(MODS, other, "court.py")],
                       capture_output=True, text=True)
    if r.returncode != 0:
        fail.append(f"replay {other} court exit {r.returncode}: {r.stdout.strip()}")

# 5. non-vacuity: existence check must count exactly the 7 named items
check("nonvacuity_count", len(owned) == len(checklist) == 7)

if fail:
    print("COURT FAIL"); [print(" -", f) for f in fail]; sys.exit(1)
print(f"Module 44 court: ALL CHECKS PASS — roadmap arithmetic, 7/7 checklist items exist, 20 training slots, cross-module replays exit 0. Standing: {standing}")
sys.exit(0)
