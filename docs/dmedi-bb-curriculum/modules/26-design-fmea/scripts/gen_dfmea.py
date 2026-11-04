#!/usr/bin/env python3
"""Lane 11 generator — Module 26 DFMEA worksheet (gimbal boring operation).

Authored (not sampled) worksheet: no seed, deterministic emission. Every RPN,
ranking, and AP class is RE-DERIVED by derive_keys.py from the emitted CSV —
never trusted from this file's literals. S/O/D ratings cite the anchored
tables in scales-anchored.md (S: CPPC outcomes; O: PPM bands; D: named controls).
"""
import csv, os

OUT = os.path.join(os.path.dirname(__file__), "..", "data", "dfmea-worksheet.csv")

# (mode_id, feature, failure_mode, effect, S, cause, O, det_ctrl_pre, det_ctrl_post, D_pre,
#  S_post, O_post, D_post, action_id, triz_link, doe_link)
ROWS = [
    ("FM-01", "Bore diameter", "Progressive tool wear (bore oversize)",
     "Bore drifts oversize toward USL; end-of-tool-life escapes possible", 10,
     "Insert flank wear over tool life; wear rate not modeled in offsets", 6,
     "End-of-line CMM sample n=3/shift (D6)", "AE tool monitor + in-process gauge with auto offset (D3)",
     6, 10, 3, 3, "DC-01",
     "C6 acoustic-emission tool monitor (TRIZ 23) + C1 compensated in-process gauge (TRIZ 24)",
     "spindle speed; feed rate (wear accelerates with speed x feed)"),
    ("FM-02", "Bore diameter", "Chatter marks (regenerative vibration)",
     "Ra degradation; out-of-round geometry; visual reject", 4,
     "Low-damping boring bar; conservative fixed cycle limits parameter window", 5,
     "Visual + Ra spot check per shift (D7)", "Adaptive feed control + Ra on production gauge 100% (D4)",
     7, 4, 2, 4, "DC-02",
     "C2 adaptive feed control (TRIZ 25); C8 gradient boring bar PARKED (feasibility 1)",
     "spindle speed (stability lobes); feed rate"),
    ("FM-03", "Bore diameter", "Bore taper along bore depth",
     "Fit-class bore varies with depth; assembly fit fails at depth", 6,
     "Spindle thermal growth along Z; wear concentrated at bore entry", 5,
     "Single-depth in-process gauge (D7)", "3-depth gauge traverse + segmented finish pass (D3)",
     7, 6, 2, 4, "DC-03", "C3 segmented rough/finish toolpath (TRIZ 3 local quality)",
     "coolant concentration; spindle speed (thermal)"),
    ("FM-04", "Bore diameter", "Undersize bore (wrong cutter comp at setup)",
     "Reworkable with one recut pass", 5,
     "Wrong cutter compensation entered at setup; no offset verification step", 4,
     "First-article layout 1st piece/shift (D7)", "Offset verify step + compensated gauge 100% (D2)",
     7, 5, 2, 2, "DC-04", "C1 compensated in-process gauge (TRIZ 24)",
     "none - error-proofing, not a DOE factor"),
    ("FM-05", "Tool/spindle", "Tool breakage inside bore",
     "Broken insert scores bore; likely scrap", 9,
     "Insert grade mismatch to 7075; insert run past change schedule", 3,
     "Operator hears/sees at tool change (D8)", "AE tool monitor + scheduled insert changes (D4)",
     8, 9, 2, 4, "DC-05", "C6 acoustic-emission tool monitor (TRIZ 23)",
     "feed rate; tool coating"),
    ("FM-06", "Fixture/part loading", "Misload: part not seated on datum A",
     "Feature-to-datum shift; bore position error; potential crash at entry", 9,
     "Manual load onto flat pad; no seating presence sensing", 4,
     "Operator visual check each load (D8)", "Seating sensor + poka-yoke fixture (D2)",
     8, 9, 2, 2, "DC-06",
     "Poka-yoke fixture (TRIZ 24 intermediary)", "none - fixture error-proofing"),
    ("FM-07", "Bore position", "True-position error (datum shift)",
     "Bearing fit misaligned; functional failure at customer", 8,
     "Fixture datum insert wear; chips under part", 3,
     "Weekly fixture PM inspection (D5)", "Weekly fixture PM + seating sensor interlock (D2)",
     5, 8, 2, 2, "DC-07", "C5 multi-axis re-grip elimination (TRIZ 17)",
     "coolant concentration (chip evacuation)"),
    ("FM-08", "Surface finish", "Ra drift (cosmetic-adjacent finish drift)",
     "Cosmetic/fit-class Ra drift; no functional failure while in spec", 3,
     "Feed marks; dull insert; coolant percentage drift", 6,
     "Ra spot check per shift (D7)", "Ra monitored on production gauge 100% (D4)",
     7, 3, 3, 4, "DC-08", "C2 adaptive feed control (TRIZ 25)", "coolant concentration"),
    ("FM-09", "Bore exit edge", "Burrs at bore exit",
     "Deburr labor; assembly hazard; loose chips", 4,
     "Exit-edge break too small; feed-exit geometry", 7,
     "Deburr station 100% manual visual (D8)", "Edge break on drawing prevents formation (D1)",
     8, 4, 3, 1, "DC-09", "C3 local quality (TRIZ 3)", "feed rate (exit burr height)"),
    ("FM-10", "Spindle thermal", "Thermal growth drift during warmup",
     "First-piece drifts off-size until spindle thermally stable", 7,
     "Cold-spindle cuts before thermal equilibrium; no warmup protocol", 5,
     "First-article each shift (D7)", "Warmup protocol + thermal offset model (D3)",
     7, 7, 2, 3, "DC-10",
     "C7 thermal-error model + offset (TRIZ 35); C4 cryo cooling PARKED (feasibility 2)",
     "spindle speed (heat generation)"),
    ("FM-11", "Coolant system", "Coolant concentration drift",
     "Compounds thermal drift, Ra drift, chip-evacuation loss", 5,
     "Weekly manual refractometer; drift between checks", 5,
     "Weekly refractometer (D5)", "Daily inline refractometer with alarm (D4)",
     4, 5, 2, 4, "DC-11", "C7 thermal-error model (TRIZ 35)",
     "coolant concentration (the DOE factor itself)"),
    ("FM-12", "NC program/offsets", "Wrong program/offset at setup",
     "Wrong geometry machined; potential scrap", 9,
     "Program picked from dropdown; no machine lockout on mismatch", 2,
     "Setup sheet cross-check (D6)", "Program-match interlock / machine lockout (D2)",
     6, 9, 2, 2, "DC-12",
     "Poka-yoke interlock (TRIZ 24 intermediary)", "none - PFMEA boundary"),
]

HDR = ["mode_id", "part_feature", "failure_mode", "failure_effect", "severity", "cause",
       "occurrence", "detection_control_pre", "detection_control_post", "detection_pre",
       "severity_post", "occurrence_post", "detection_post", "action_id", "triz_concept",
       "doe_factor_link"]

with open(OUT, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(HDR)
    for r in ROWS:
        w.writerow(r)

print(f"wrote {OUT} ({len(ROWS)} failure modes)")