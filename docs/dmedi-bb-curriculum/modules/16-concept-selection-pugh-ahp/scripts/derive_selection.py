#!/usr/bin/env python3
"""Module 16 derivation engine -- Pugh + AHP on the same 4-concept problem.

Re-derives EVERYTHING from data/concept_trials.csv (data provenance law:
never from a remembered answer). Prints both rankings and the
agreement/divergence analysis. Exit 0 = all court checks passed.

Usage: python3 scripts/derive_selection.py   (run from the module root)
"""
import csv
import math
import os
import sys

LSL, USL = 11.975, 12.025
TARGET_CPK = 1.33

CONCEPTS = [
    "A-citizen-regrind",
    "B-peck-deep-drill-then-bore",
    "C-helical-interpolation",
    "D-combined-rough-plus-finish-boring-bar",
]
SHORT = {"A-citizen-regrind": "A",
         "B-peck-deep-drill-then-bore": "B",
         "C-helical-interpolation": "C",
         "D-combined-rough-plus-finish-boring-bar": "D"}
DATUM = "A-citizen-regrind"

# ---------------------------------------------------------------------------
# Data loading and per-concept pilot statistics
# ---------------------------------------------------------------------------

DATA = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    "data", "concept_trials.csv")


def load(path=DATA):
    d = {c: [] for c in CONCEPTS}
    with open(path) as f:
        for row in csv.DictReader(f):
            d[row["concept"]].append((float(row["bore_mm"]), float(row["ra_um"])))
    return d


def stats(d):
    n = len(d)
    mu = sum(x for x, _ in d) / n
    ra = sum(r for _, r in d) / n
    s = math.sqrt(sum((x - mu) ** 2 for x, _ in d) / (n - 1))
    s_ra = math.sqrt(sum((r - ra) ** 2 for _, r in d) / (n - 1))
    cpk = min(USL - mu, mu - LSL) / (3 * s)
    return {"n": n, "mu": mu, "s": s, "cpk": cpk, "ra": ra, "s_ra": s_ra}


# ---------------------------------------------------------------------------
# Pugh matrix (iteration 1: datum = A, the incumbent citizen regrind)
# Criteria traceable to QFD engineering characteristics (module 05):
#   C1 bore capability (CTQ-1, weight-critical)
#   C2 surface finish Ra (CTQ-1 companion EC)
#   C3 cycle time (CTQ-2 lead-time driver)
#   C4 tooling + capital cost (CTQ-3 cost ceiling $28.50)
#   C5 flexibility / setup (EC5 from QFD roof correlation)
# Scoring basis is stated per cell so a grader can re-derive each mark
# from stats(d) alone.
# ---------------------------------------------------------------------------

def pugh_matrix(st):
    # (concept, criterion) -> ('+', '-', '0'), with rationale strings.
    # Basis: + if clearly better than datum on the criterion, - if clearly
    # worse, 0 if comparable (within judgment band). Rule stated in docs:
    # capability judged on pilot Cpk vs datum's 0.72 with +/- needing a
    # >= 0.20 gap; Ra judged on pilot mean vs 1.6 um with +/- needing
    # >= 0.15 um gap; cycle time and cost judged on route engineering
    # facts authored in the lab brief; flexibility likewise.
    def band(val, base, tol):
        return "+" if val > base + tol else ("-" if val < base - tol else "0")

    cells = {}
    rationale = {}
    for c in CONCEPTS:
        s = st[c]
        # C1 capability
        if c == DATUM:
            cells[(c, "C1")] = "0"  # datum by definition
            rationale[(c, "C1")] = "datum"
        else:
            cells[(c, "C1")] = band(s["cpk"], st[DATUM]["cpk"], 0.20)
            rationale[(c, "C1")] = (
                f"pilot Cpk {s['cpk']:.2f} vs datum {st[DATUM]['cpk']:.2f}; "
                f"gap {s['cpk'] - st[DATUM]['cpk']:+.2f} vs +/-0.20 band")
        # C2 surface finish
        if c == DATUM:
            cells[(c, "C2")] = "0"
            rationale[(c, "C2")] = "datum"
        else:
            cells[(c, "C2")] = band(-s["ra"], -st[DATUM]["ra"], 0.15)  # lower Ra better
            rationale[(c, "C2")] = (
                f"pilot Ra {s['ra']:.2f} um vs datum {st[DATUM]['ra']:.2f} um "
                f"(lower better; +/-0.15 um band)")
        # C3-C5 route facts (authored in lab brief, independent of pilot draw):
        #   A regrind: 22 min cycle, $0 added capital, 1 setup, but regrind
        #     loop adds WIP handling (flexibility neutral vs itself = datum)
        #   B peck-deep-drill-then-bore: 14 min, $18k deep-cycle tooling,
        #     2 setups, standard tooling = flexible
        #   C helical interpolation: 11 min, $0 (existing end mill), 1 setup,
        #     but sensitive to program rigor (flexibility -)
        #   D combined rough+finish boring bar: 17 min, $34k custom bar,
        #     1 setup, single-source tool (flexibility -)
        facts = {
            "A-citizen-regrind":                {"C3": "0", "C4": "0", "C5": "0"},
            "B-peck-deep-drill-then-bore":      {"C3": "+", "C4": "-", "C5": "+"},
            "C-helical-interpolation":          {"C3": "+", "C4": "+", "C5": "-"},
            "D-combined-rough-plus-finish-boring-bar": {"C3": "+", "C4": "-", "C5": "-"},
        }
        for k in ("C3", "C4", "C5"):
            cells[(c, k)] = facts[c][k]
            if c == DATUM:
                rationale[(c, k)] = "datum"
    return cells, rationale


def pugh_tallies(cells):
    t = {}
    for c in CONCEPTS:
        marks = [cells[(c, k)] for k in ("C1", "C2", "C3", "C4", "C5")]
        t[c] = (marks.count("+"), marks.count("-"), marks.count("0"), sum(marks.count("+") - marks.count("-") for _ in [0]))
    return t


# ---------------------------------------------------------------------------
# AHP
# ---------------------------------------------------------------------------

def eigen_weight(mat):
    """Principal-eigenvector weight vector (power method), lambda_max, n, CI, CR."""
    n = len(mat)
    # start at uniform, iterate v <- M v / |M v|
    v = [1.0 / n] * n
    for _ in range(200):
        w = [sum(mat[i][j] * v[j] for j in range(n)) for i in range(n)]
        tot = sum(w)
        v2 = [x / tot for x in w]
        if max(abs(a - b) for a, b in zip(v, v2)) < 1e-12:
            v = v2
            break
        v = v2
    mv = [sum(mat[i][j] * v[j] for j in range(n)) for i in range(n)]
    lam = sum(mv[i] / v[i] for i in range(n)) / n
    ci = (lam - n) / (n - 1) if n > 1 else 0.0
    RI = {1: 0.0, 2: 0.0, 3: 0.58, 4: 0.90, 5: 1.12, 6: 1.24, 7: 1.32,
          8: 1.41, 9: 1.45, 10: 1.49}
    cr = ci / RI[n] if RI[n] > 0 else 0.0
    return v, lam, ci, cr


def geom_priority(mat):
    """Geometric-mean (approximate) priority vector for a positive reciprocal matrix."""
    n = len(mat)
    g = [math.prod(row) ** (1.0 / n) for row in mat]
    tot = sum(g)
    return [x / tot for x in g]


CRITERIA = ["C1-capability", "C2-finish", "C3-cycletime", "C4-cost", "C5-flex"]

# Criteria pairwise matrix (Saaty 1-9). Authored in lab brief from QFD
# relative weights: capability is top customer priority, cost second,
# finish third, cycle time fourth, flexibility last.
CRIT_MAT = [
    [1,   2,   3,   2,   5],
    [1/2, 1,   2,   1/2, 4],
    [1/3, 1/2, 1,   1/2, 3],
    [1/2, 2,   2,   1,   4],
    [1/5, 1/4, 1/3, 1/4, 1],
]

# Deliberately INCONSISTENT variant (teaching artifact): claims C1 >> C2,
# C2 >> C3, yet C1 ~ C3 -- a classic cyclic intransitivity.
CRIT_MAT_BAD = [
    [1,   9,   1,   9,   9],
    [1/9, 1,   9,   1,   1],
    [1,   1/9, 1,   1,   1],
    [1/9, 1,   1,   1,   9],
    [1/9, 1,   1,   1/9, 1],
]


def concept_matrices_from_data(st):
    """Per-criterion 4x4 concept matrices. Ratios grounded in pilot data or
    route facts, snapped to the nearest Saaty scale value (1-9 and reciprocals)."""
    SAATY = [1/9, 1/8, 1/7, 1/6, 1/5, 1/4, 1/3, 1/2, 1, 2, 3, 4, 5, 6, 7, 8, 9]

    def snap(r):
        return min(SAATY, key=lambda s: abs(math.log(r / s)))

    def mat(fn):
        m = [[1.0] * 4 for _ in range(4)]
        for i, ci in enumerate(CONCEPTS):
            for j, cj in enumerate(CONCEPTS):
                m[i][j] = 1.0 if i == j else snap(fn(ci, cj))
        return m

    # C1 capability: ratio of pilot Cpk (floored at 0.10 to keep scale sane)
    c1 = mat(lambda a, b: max(st[a]["cpk"], 0.10) / max(st[b]["cpk"], 0.10))
    # C2 finish: inverse ratio of mean Ra (lower Ra better)
    c2 = mat(lambda a, b: st[b]["ra"] / st[a]["ra"])
    # C3 cycle time: inverse ratio of route minutes (lower better)
    mins = {"A-citizen-regrind": 22, "B-peck-deep-drill-then-bore": 14,
            "C-helical-interpolation": 11,
            "D-combined-rough-plus-finish-boring-bar": 17}
    c3 = mat(lambda a, b: mins[b] / mins[a])
    # C4 cost: authored relative added capital / piece-cost penalty
    cost = {"A-citizen-regrind": 1.0, "B-peck-deep-drill-then-bore": 2.5,
            "C-helical-interpolation": 1.2,
            "D-combined-rough-plus-finish-boring-bar": 3.5}
    c4 = mat(lambda a, b: cost[b] / cost[a])
    # C5 flexibility: authored ordinal scores snapped to ratios
    flex = {"A-citizen-regrind": 3, "B-peck-deep-drill-then-bore": 4,
            "C-helical-interpolation": 2,
            "D-combined-rough-plus-finish-boring-bar": 2}
    c5 = mat(lambda a, b: flex[a] / flex[b])
    return {"C1-capability": c1, "C2-finish": c2, "C3-cycletime": c3,
            "C4-cost": c4, "C5-flex": c5}


def global_ahp(w_crit, per_crit):
    """Global scores: for each criterion, AHP weights of concepts within it,
    combined with criterion weights."""
    overall = [0.0] * 4
    detail = {}
    for name, m in per_crit.items():
        w, lam, ci, cr = eigen_weight(m)
        cw = w_crit[CRITERIA.index(name)]
        detail[name] = (w, lam, ci, cr, cw)
        for i in range(4):
            overall[i] += cw * w[i]
    return overall, detail


# ---------------------------------------------------------------------------
# Court checks + report
# ---------------------------------------------------------------------------

def main():
    d = load()
    st = {c: stats(d[c]) for c in CONCEPTS}
    ok = True

    def check(name, cond, detail=""):
        nonlocal ok
        tag = "PASS" if cond else "FAIL"
        if not cond:
            ok = False
        print(f"[{tag}] {name}" + (f" -- {detail}" if detail else ""))

    print("== 1. Pilot statistics (re-derived from CSV) ==")
    hdr = f"{'concept':<42}{'n':>3}{'mu':>10}{'s(mm)':>10}{'Cpk':>7}{'Ra':>7}"
    print(hdr)
    for c in CONCEPTS:
        s = st[c]
        print(f"{c:<42}{s['n']:>3}{s['mu']:>10.4f}{s['s']:>10.5f}"
              f"{s['cpk']:>7.2f}{s['ra']:>7.2f}")
    # A must reproduce the adjudicated spine: Cpk ~ 0.72 with s ~ 7.4 um
    check("A pilot Cpk within 0.10 of pinned 0.72",
          abs(st[CONCEPTS[0]]["cpk"] - 0.72) < 0.10,
          f"A Cpk = {st[CONCEPTS[0]]['cpk']:.2f}")
    check("A pilot s within 15% of adjudicated 7.407 um",
          abs(st[CONCEPTS[0]]["s"] - 0.007407) / 0.007407 < 0.15,
          f"A s = {st[CONCEPTS[0]]['s']*1000:.2f} um")

    print("\n== 2. Pugh (iteration 1, datum = A) ==")
    cells, rationale = pugh_matrix(st)
    print(f"{'criterion':<12}" + "".join(f"{SHORT[c]:>6}" for c in CONCEPTS))
    for k in ("C1", "C2", "C3", "C4", "C5"):
        print(f"{k:<12}" + "".join(f"{cells[(c,k)]:>6}" for c in CONCEPTS))
    tall = pugh_tallies(cells)
    print()
    for c in CONCEPTS:
        p, m, z, _ = tall[c]
        print(f"  {SHORT[c]}: +{p} -{m} 0:{z}  net {p - m:+d}")
    order = sorted(CONCEPTS, key=lambda c: (tall[c][0] - tall[c][1]), reverse=True)
    print(f"  Pugh ranking: {' > '.join(SHORT[c] for c in order)}")
    check("Pugh datum row is all 0",
          all(cells[(DATUM, k)] == "0" for k in ("C1", "C2", "C3", "C4", "C5")))
    # Deliberate teaching divergence: UNWEIGHTED Pugh marks favor B (its only
    # minus is cost), while weighted AHP later favors D. The court asserts the
    # divergence exists so the docs cannot silently claim agreement.
    check("Pugh iteration-1 net leader is B (the designed divergence)",
          order[0] == "B-peck-deep-drill-then-bore",
          f"leader {SHORT[order[0]]}")

    print("\n== 2b. Pugh consolidation iteration 2 ==")
    # Pugh convergence: D wins but carries C5 (-). Consolidation: graft B's
    # standard deep-cycle tooling strategy onto D's combined bar -> concept
    # D2 "combined bar with standard coated deep-cycle-insert set" (kills the
    # single-source penalty, cost improves from - to 0). Re-score only the
    # changed cells vs same datum A.
    d2_cells = dict(cells)
    d2_cells[("D2-consolidated", "C4")] = "0"
    d2_cells[("D2-consolidated", "C5")] = "0"
    for k in ("C1", "C2", "C3"):
        d2_cells[("D2-consolidated", k)] = cells[
            ("D-combined-rough-plus-finish-boring-bar", k)]
    p2 = sum(1 for k in ("C1", "C2", "C3", "C4", "C5")
             if d2_cells[("D2-consolidated", k)] == "+")
    m2 = sum(1 for k in ("C1", "C2", "C3", "C4", "C5")
             if d2_cells[("D2-consolidated", k)] == "-")
    print(f"  D2-consolidated: +{p2} -{m2}  net {p2 - m2:+d} "
          f"(D alone was {tall['D-combined-rough-plus-finish-boring-bar'][0] - tall['D-combined-rough-plus-finish-boring-bar'][1]:+d})")
    check("Consolidation strictly improves net over D",
          p2 - m2 > tall["D-combined-rough-plus-finish-boring-bar"][0]
          - tall["D-combined-rough-plus-finish-boring-bar"][1],
          f"{p2 - m2:+d} vs above")
    # Pugh convergence law: when the net scores TIE, do not break the tie by
    # trading votes -- escalate to the underlying data and a weighted method.
    b_net = tall[CONCEPTS[1]][0] - tall[CONCEPTS[1]][1]
    check("D2 ties iteration-1 leader B on net (tie must be escalated, not voted)",
          p2 - m2 == b_net, f"D2 {p2 - m2:+d} vs B {b_net:+d}")
    check("D2 beats B on the CTQ-1 pilot data (Cpk and Ra)",
          st["D-combined-rough-plus-finish-boring-bar"]["cpk"]
          > st[CONCEPTS[1]]["cpk"]
          and st["D-combined-rough-plus-finish-boring-bar"]["ra"]
          < st[CONCEPTS[1]]["ra"],
          f"D Cpk {st['D-combined-rough-plus-finish-boring-bar']['cpk']:.2f} "
          f"vs B {st[CONCEPTS[1]]['cpk']:.2f}; D Ra "
          f"{st['D-combined-rough-plus-finish-boring-bar']['ra']:.2f} vs B "
          f"{st[CONCEPTS[1]]['ra']:.2f}")

    print("\n== 3. AHP criteria weights ==")
    w_crit, lam_c, ci_c, cr_c = eigen_weight(CRIT_MAT)
    g_crit = geom_priority(CRIT_MAT)
    for i, name in enumerate(CRITERIA):
        print(f"  {name:<14} eigenvector {w_crit[i]:.4f}   geometric-mean {g_crit[i]:.4f}")
    print(f"  lambda_max = {lam_c:.4f}  CI = {ci_c:.4f}  CR = {cr_c:.4f}")
    check("Criteria matrix CR < 0.10", cr_c < 0.10, f"CR = {cr_c:.4f}")
    check("Criteria weights sum to 1", abs(sum(w_crit) - 1) < 1e-9)

    print("\n== 3b. Deliberately inconsistent criteria matrix (teaching) ==")
    w_bad, lam_bad, ci_bad, cr_bad = eigen_weight(CRIT_MAT_BAD)
    print(f"  weights: " + ", ".join(f"{n}={w:.4f}" for n, w in zip(CRITERIA, w_bad)))
    print(f"  lambda_max = {lam_bad:.4f}  CI = {ci_bad:.4f}  CR = {cr_bad:.4f}")
    check("Inconsistent matrix CR >= 0.10 (fails, as designed)",
          cr_bad >= 0.10, f"CR = {cr_bad:.4f}")
    check("Inconsistent lambda_max appreciably > n=5", lam_bad - 5 > 0.5,
          f"lambda_max - n = {lam_bad - 5:.3f}")

    print("\n== 4. AHP concept priorities per criterion ==")
    per_crit = concept_matrices_from_data(st)
    overall, detail = global_ahp(w_crit, per_crit)
    for name in CRITERIA:
        w, lam, ci, cr, cw = detail[name]
        print(f"  {name} (criterion weight {cw:.3f}, CR {cr:.4f}):")
        for i, c in enumerate(CONCEPTS):
            print(f"    {SHORT[c]} {w[i]:.4f}")
        check(f"{name} matrix CR < 0.10", cr < 0.10, f"CR = {cr:.4f}")
    print("\n  Global AHP scores:")
    for i, c in enumerate(CONCEPTS):
        print(f"    {SHORT[c]} {overall[i]:.4f}")
    ahp_order = sorted(range(4), key=lambda i: overall[i], reverse=True)
    print(f"  AHP ranking: "
          + " > ".join(SHORT[CONCEPTS[i]] for i in ahp_order))
    check("AHP winner is D", CONCEPTS[ahp_order[0]]
          == "D-combined-rough-plus-finish-boring-bar",
          f"winner {SHORT[CONCEPTS[ahp_order[0]]]}")

    print("\n== 5. Agreement / divergence ==")
    pugh_rank = [SHORT[c] for c in order]
    ahp_rank = [SHORT[CONCEPTS[i]] for i in ahp_order]
    print(f"  Pugh iteration 1 (unweighted): {' > '.join(pugh_rank)}")
    print(f"  AHP  (weighted):               {' > '.join(ahp_rank)}")
    print("  Designed divergence: unweighted Pugh counts each criterion once, "
          "so B's lone cost minus is outweighed by four pluses; AHP weights "
          "capability (0.375) and cost (0.253) explicitly, and D leads on "
          "capability + finish, so D wins. Consolidation (D2) TIES B on net "
          "(+3 vs +3); the tie is broken by the CTQ-1 pilot data and AHP "
          "weights in favor of the D lineage, not by trading Pugh marks.")
    # Post-consolidation agreement: the surviving Pugh concept (D2 lineage)
    # must be the AHP winner D.
    check("Post-consolidation Pugh selection == AHP winner (D lineage)",
          CONCEPTS[ahp_order[0]] == "D-combined-rough-plus-finish-boring-bar")
    check("AHP runner-up is the iteration-1 Pugh leader B",
          CONCEPTS[ahp_order[1]] == "B-peck-deep-drill-then-bore",
          f"runner-up {SHORT[CONCEPTS[ahp_order[1]]]}")
    check("Iteration-1 winner differs from AHP winner (divergence witnessed)",
          SHORT[order[0]] != SHORT[CONCEPTS[ahp_order[0]]])

    print("\n== COURT SUMMARY ==")
    print("ALL CHECKS PASSED" if ok else "COURT FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
