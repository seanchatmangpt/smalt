#!/usr/bin/env python3
"""Lane 11 court — Module 26 DFMEA key re-derivation.

Re-derives every RPN (S x O x D), every ranking, and every action-priority (AP)
class from data/dfmea-worksheet.csv, then exit-checks them against the values
published in solution-key.md. Exit 0 = all courts green; exit 1 = any mismatch.
Also enforces structural laws: S/O/D in 1..10, post-action scores never worse
than pre, and AP recomputed independently of the published RPN.
"""
import csv, os

HERE = os.path.dirname(os.path.abspath(__file__))
CSV = os.path.join(HERE, "..", "data", "dfmea-worksheet.csv")

fail = []

def check(label, got, want):
    ok = got == want
    if not ok:
        fail.append(f"{label}: got {got!r} want {want!r}")
    print(f"{'PASS' if ok else 'FAIL'} {label}: {got!r}")

def ap_class(s, o, d):
    """Condensed AIAG-VDA-style action-priority lookup (documented in
    scales-anchored.md). Severity-first: RPN can never override it."""
    if s >= 9:
        if o >= 3 or d >= 4:
            return "High"
        return "Medium"          # S 9-10 is never Low
    if 6 <= s <= 8:
        if o >= 5 and d >= 5:
            return "High"
        if o >= 4 or d >= 5:
            return "Medium"
        return "Low"
    # s <= 5
    if o >= 7 or (o >= 5 and d >= 5):
        return "Medium"
    return "Low"

rows = list(csv.DictReader(open(CSV)))
check("failure-mode count", len(rows), 12)

# Published in solution-key.md: (rpn_pre, rpn_post, rank_pre, ap_pre, ap_post).
# Any drift between worksheet and solution key makes this court exit 1.
EXPECTED = {
    "FM-01": (360, 90, 1, "High", "High"),
    "FM-02": (140, 32, 8, "Medium", "Low"),
    "FM-03": (210, 48, 6, "High", "Low"),
    "FM-04": (140, 20, 7, "Low", "Low"),
    "FM-05": (216, 72, 5, "High", "High"),
    "FM-06": (288, 36, 2, "High", "Medium"),
    "FM-07": (120, 32, 10, "Medium", "Low"),
    "FM-08": (126, 36, 9, "Medium", "Low"),
    "FM-09": (224, 12, 4, "Medium", "Low"),
    "FM-10": (245, 42, 3, "High", "Low"),
    "FM-11": (100, 40, 12, "Low", "Low"),
    "FM-12": (108, 36, 11, "High", "Medium"),
}

# structural laws
for r in rows:
    s, o, d = int(r["severity"]), int(r["occurrence"]), int(r["detection_pre"])
    sp, op, dp = int(r["severity_post"]), int(r["occurrence_post"]), int(r["detection_post"])
    mid = r["mode_id"]
    check(f"{mid} S range", 1 <= s <= 10, True)
    check(f"{mid} O range", 1 <= o <= 10, True)
    check(f"{mid} D range", 1 <= d <= 10, True)
    check(f"{mid} post not worse", (sp <= s) and (op <= o) and (dp <= d), True)

rpns = {}
for r in rows:
    mid = r["mode_id"]
    pre = int(r["severity"]) * int(r["occurrence"]) * int(r["detection_pre"])
    post = int(r["severity_post"]) * int(r["occurrence_post"]) * int(r["detection_post"])
    rpns[mid] = pre
    exp = EXPECTED[mid]
    check(f"{mid} rpn_pre", pre, exp[0])
    check(f"{mid} rpn_post", post, exp[1])
    check(f"{mid} ap_pre", ap_class(int(r["severity"]), int(r["occurrence"]), int(r["detection_pre"])), exp[3])
    check(f"{mid} ap_post", ap_class(int(r["severity_post"]), int(r["occurrence_post"]), int(r["detection_post"])), exp[4])

# ranking re-derivation: severity-desc tiebreak, then mode_id for determinism
order = sorted(rpns, key=lambda m: (-rpns[m], -int(next(r for r in rows if r["mode_id"] == m)["severity"]), m))
ranks = {m: i + 1 for i, m in enumerate(order)}
for m, rk in ranks.items():
    check(f"{m} rank_pre", rk, EXPECTED[m][2])

print("\nRanked DFMEA (pre-action):")
for m in order:
    r = next(r for r in rows if r["mode_id"] == m)
    print(f"  {ranks[m]:>2}. {m}  RPN={rpns[m]:>3}  S={r['severity']} O={r['occurrence']} D={r['detection_pre']}  AP={EXPECTED[m][3]}")

if fail:
    print(f"\nCOURT FAIL ({len(fail)} mismatches)")
    raise SystemExit(1)
print("\nCOURT PASS: all RPNs, rankings, and AP classes re-derived and green")
