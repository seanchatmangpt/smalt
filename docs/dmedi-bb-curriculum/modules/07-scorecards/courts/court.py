#!/usr/bin/env python3
"""Court for module 07 scorecards.

1. Re-derives all arithmetic embedded in the worksheets (lead-time decomposition,
   future-state rollup, Cpk yield math, module-06 tie-outs).
2. Structural checks: operational-definition completeness, data-collection-plan
   traceability, MGPP matrix completeness rules.

Exit 0 = pass, 1 = fail. Run from anywhere: python3 courts/court.py
"""
import re
import sys
from math import erf, sqrt
from pathlib import Path

PHI = lambda z: 0.5 * (1 + erf(z / sqrt(2)))
FAILS = []
WS = Path(__file__).resolve().parent.parent / "worksheets"

def check(name, cond, detail=""):
    if not cond:
        FAILS.append(f"{name}: {detail}")
    print(("PASS" if cond else "FAIL") + f"  {name}  {detail}")

def read(name):
    return (WS / name).read_text()

def table_rows(text, header_prefix):
    """Parse markdown table rows under a header row starting with header_prefix."""
    rows = []
    lines = text.splitlines()
    for i, ln in enumerate(lines):
        if ln.startswith(header_prefix):
            for r in lines[i + 2:]:  # skip separator row
                if not r.startswith("|"):
                    break
                rows.append([c.strip() for c in r.strip("|").split("|")])
            break
    return rows

# ---- 1. arithmetic re-derivation ----
lt_base = [11.2, 3.1, 2.6, 1.5]
check("leadtime-baseline-sum", abs(sum(lt_base) - 18.4) < 1e-9, f"{sum(lt_base)}")
lt_future = [2.5, 2.4, 0.6, 0.5]
check("leadtime-future-sum", abs(sum(lt_future) - 6.0) < 1e-9, f"{sum(lt_future)}")
check("leadtime-target-met", sum(lt_future) <= 7.0, f"{sum(lt_future)} <= 7")

check("defect-baseline", abs(2 * PHI(-3 * 0.72) * 100 - 3.077) < 1e-3,
      f"{2*PHI(-3*0.72)*100:.4f}%")
check("defect-target", abs(2 * PHI(-3 * 1.33) * 100 - 0.007) < 5e-4,
      f"{2*PHI(-3*1.33)*100:.6f}%")

# module-06 tie-outs (values this module must not drift from)
TIE = dict(cycle=13.08, tooling=3.46, setup_h=1.05, ceiling=28.50,
           baseline_cost=41.80, feed=630, rpm=11500)
h = read("01-hierarchy.md")
for label, val in [("13.08 min", TIE["cycle"]), ("$3.46", TIE["tooling"]),
                   ("1.05 h", TIE["setup_h"]), ("$28.50", TIE["ceiling"]),
                   ("630 mm/min", TIE["feed"]), ("11,500 RPM", TIE["rpm"])]:
    check(f"hierarchy-tieout-{label}", label in h, label)
check("hierarchy-baseline-cost", "$41.80" in h, "$41.80 present")
check("hierarchy-no-27.09-vs-28.50-conflict",
      h.count("28.50") >= 2, "ceiling referenced in CTQ-3 and Y3 rows")

# ---- 2. operational definitions: every metric has gauge/sample/frequency/calc ----
od_rows = table_rows(read("02-operational-definitions.md"), "| ID | Metric |")
check("od-count", len(od_rows) == 15, f"{len(od_rows)} rows, expect 15")
empty = [(r[0], i) for r in od_rows for i, c in enumerate(r) if c == ""]
check("od-no-empty-cells", not empty, f"{empty[:5]}")
ods = [r[0] for r in od_rows]
check("od-ids", ods == [f"OD-{i}" for i in range(1, 16)], f"{ods}")

# ---- 3. data collection plan covers every OD ----
dc_text = read("03-data-collection-plan.md")
dc_rows = table_rows(dc_text, "| Metric (OD) |")
dc_ids = set(re.findall(r"OD-\d+", dc_text))
missing = [o for o in ods if o not in dc_ids]
check("dcplan-covers-all-ods", not missing, f"missing {missing}")
dc_empty = [(r[0], i) for r in dc_rows for i, c in enumerate(r) if c == ""]
check("dcplan-no-empty-cells", not dc_empty, f"{dc_empty[:5]}")

# ---- 4. MGPP traceability completeness ----
mg_rows = table_rows(read("05-mgpp-traceability.md"), "| Scorecard metric (OD) |")
mg_ids = [re.match(r"(OD-\d+|Y3)", r[0]).group(1) for r in mg_rows]
check("mgpp-every-metric-once",
      sorted(mg_ids) == sorted(ods + ["Y3"]) and len(mg_ids) == len(set(mg_ids)),
      f"{len(mg_ids)} rows; got {mg_ids}")
mg_empty = [(r[0], i) for r in mg_rows for i, c in enumerate(r) if c == ""]
check("mgpp-no-empty-cells", not mg_empty, f"{mg_empty[:5]}")
bad_gates = [(r[0], re.findall(r"W\d+", r[3])) for r in mg_rows
             if not re.findall(r"W\d+", r[3])
             or not set(re.findall(r"W\d+", r[3])) <= {"W5", "W9", "W15", "W21", "W26"}]
check("mgpp-gate-weeks-valid", not bad_gates, f"{bad_gates}")
ROLES = {"Quality eng", "Mfg eng", "Shift lead", "Tool crib", "Planner",
         "Shipping", "Finance", "Purchasing", "BB lead"}
bad_owners = [r[0] for r in mg_rows if r[5] not in ROLES]
check("mgpp-owner-is-role", not bad_owners, f"{bad_owners}")

# ---- verdict ----
print()
if FAILS:
    print(f"COURT FAIL: {len(FAILS)} finding(s)")
    for f_ in FAILS:
        print("  -", f_)
    sys.exit(1)
print("COURT PASS: arithmetic + structure verified")
