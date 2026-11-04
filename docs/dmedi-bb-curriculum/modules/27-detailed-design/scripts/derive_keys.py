#!/usr/bin/env python3
"""Lane 11 court — Module 27 detailed-design key derivation.

Two courts in one exit-check:
1. Tolerance-to-capability math from RUNNING-CASE pinned constants.
2. Linkage court: DFMEA actions (module 26) <-> design-control checklist.
Exit 0 = green; exit 1 = any mismatch.
"""
import csv, os

HERE = os.path.dirname(os.path.abspath(__file__))
M26 = os.path.join(HERE, "..", "..", "26-design-fmea", "data", "dfmea-worksheet.csv")
CHECKLIST = os.path.join(HERE, "..", "data", "design-control-checklist.csv")

fail = []

def check(label, got, want):
    ok = got == want
    if not ok:
        fail.append(f"{label}: got {got!r} want {want!r}")
    print(f"{'PASS' if ok else 'FAIL'} {label}: {got!r}")

# ---------- 1. Tolerance <-> capability derivation ----------
SPEC = 0.025          # customer spec half-width, mm (CTQ-1)
GUARD = 0.008         # internal drawing/control tolerance half-width, mm
SIGMA = 0.00417       # baseline sigma, mm (RUNNING-CASE pin)
CPK_TARGET = 1.33

sigma_max = GUARD / (3 * CPK_TARGET)
cpk_guard_baseline = GUARD / (3 * SIGMA)
cpk_spec_mu = (SPEC - 0.009) / (3 * SIGMA)     # (USL - mu)/(3 sigma), mu = 12.009 mm
cpk_spec_centered = SPEC / (3 * SIGMA)
sigma_ratio = SIGMA / sigma_max
var_factor = sigma_ratio ** 2

check("sigma_max in um", round(sigma_max * 1000, 1), 2.0)
check("Cpk guard-band baseline", round(cpk_guard_baseline, 2), 0.64)
check("Cpk spec (at mu=12.009)", round(cpk_spec_mu, 2), 1.28)
check("Cpk spec (if centered)", round(cpk_spec_centered, 2), 2.0)
check("sigma reduction needed (x)", round(sigma_ratio, 2), 2.08)
check("variance reduction needed (x)", round(var_factor, 2), 4.33)

# Adjudicated spine regime (MANIFEST rows 16/21/23: sigma 7.407 um, pilot Cpk 0.72)
SIGMA_SPINE = 0.007407
check("Cpk guard-band baseline (spine sigma 7.407 um)", round(GUARD / (3 * SIGMA_SPINE), 2), 0.36)
check("sigma reduction needed, spine regime (x)", round(SIGMA_SPINE / sigma_max, 2), 3.69)
check("variance reduction needed, spine regime (x)",
      round((SIGMA_SPINE / sigma_max) ** 2, 1), 13.6)

print()
print("Tolerance-to-capability derivation (guard band 0.008 mm inside spec 0.025 mm):")
print(f"  sigma_max = 0.008/(3 x 1.33) = {sigma_max*1000:.2f} um")
print(f"  baseline Cpk vs guard band = 0.008/(3 x 0.00417) = {cpk_guard_baseline:.2f}")
print(f"  Cpk vs customer spec at mu=12.009 = (0.025-0.009)/(3 x 0.00417) = {cpk_spec_mu:.2f}")
print(f"  Cpk vs customer spec if centered = 0.025/(3 x 0.00417) = {cpk_spec_centered:.2f}")
print(f"  sigma reduction needed = 4.17/2.005 = {sigma_ratio:.2f}x  "
      f"(variance = {var_factor:.2f}x)")

# ---------- 2. Linkage court: DFMEA <-> checklist ----------
fm_rows = list(csv.DictReader(open(M26)))
cl_rows = list(csv.DictReader(open(CHECKLIST)))

dfmea_ids = {r["action_id"] for r in fm_rows}
dfmea_modes = {r["mode_id"] for r in fm_rows}
cl_ids = {r["action_id"] for r in cl_rows}
base_ids = {i for i in cl_ids if not i.endswith("b") and i != "DC-13"}

check("DFMEA worksheet modes", len(fm_rows), 12)
check("DFMEA action ids", len(dfmea_ids), 12)
check("checklist rows", len(cl_rows), 18)
check("every DFMEA action has a checklist row", base_ids == dfmea_ids, True)
additions = {i for i in cl_ids if i.endswith("b") or i == "DC-13"}
check("detailed-design additions (expected 6)", len(additions), 6)
check("additions all documented", additions,
      {"DC-02b", "DC-04b", "DC-07b", "DC-10b", "DC-13", "DC-13b"})

plan_rows = [r["plan_row"] for r in cl_rows]
check("control-plan row ids unique", len(plan_rows), len(set(plan_rows)))
check("control-plan rows are CP-1..CP-18", sorted(plan_rows),
      sorted(f"CP-{i}" for i in range(1, 19)))

valid_types = {"process control", "error-proofing", "maintenance", "measurement",
               "design change", "documentation"}
valid_dfx = {"DFM", "DFA", "DFT", "meas", "poka"}
bad = [(r["action_id"], r["control_type"], r["dfx_class"]) for r in cl_rows
       if r["control_type"] not in valid_types or r["dfx_class"] not in valid_dfx]
check("control types and DFX classes in-domain", bad, [])

# DFX coverage: machinability (DFM), assembly (DFA), testability (DFT),
# measurement (meas), error-proofing (poka) — all five must be exercised
dfx_used = {r["dfx_class"] for r in cl_rows}
check("DFX classes covered", sorted(dfx_used), ["DFA", "DFM", "DFT", "meas", "poka"])

if fail:
    print(f"\nCOURT FAIL ({len(fail)} mismatches)")
    raise SystemExit(1)
print("\nCOURT PASS: tolerance math + linkage courts green")
