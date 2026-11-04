#!/usr/bin/env python3
"""Module 31 court. Run from curriculum root. Exit 0 = alias closure + effects + fold-over re-derive."""
import csv, math, sys, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # modules/
HERE = os.path.join(ROOT, "31-fractional-factorial-doe")
SRC = os.path.join(HERE, "data", "fractional-2k5-2.csv")
if not os.path.exists(SRC):
    sys.exit("VACUOUS COURT: Module 31 dataset missing — regenerate first")

fail = []
MUT = len(sys.argv) > 1 and sys.argv[1] == "--mutate"
DELTA = 1.0 if MUT else 0.0   # --mutate corrupts the A-chain pin; court must exit 1
def check(name, got, want, tol=0.0):
    ok = abs(got - want) <= tol if tol else got == want
    if not ok: fail.append(f"{name}: got {got}, want {want}")

L = "ABCDE"
def w2b(w):  # word -> bitmask ("I" = identity = 0)
    if w == "I": return 0
    b = 0
    for c in w: b |= 1 << L.index(c)
    return b
def b2w(b):  # bitmask -> word
    return "".join(L[i] for i in range(5) if b >> i & 1) or "I"

rows = list(csv.DictReader(open(SRC)))
check("N_rows", len(rows), 16)

# --- Court 1: defining group from generators D=AB, E=AC, closed by multiplication
G = {0, w2b("ABD"), w2b("ACE")}
closure = {a ^ b for a in G for b in G}          # product = letter-cancelling xor
check("closure_stable", closure == closure | G, True)
G = closure
check("defining_words", {b2w(w) for w in G} == {"I", "ABD", "ACE", "BCDE"}, True)
check("resolution_III", min(w.bit_count() for w in G if w), 3)

# 8 cosets of size 4; contents must match README §3 line-for-line (as sets)
seen, got = set(), set()
for e in range(32):
    if e in seen: continue
    ch = tuple(sorted(e ^ w for w in G)); seen |= set(ch); got.add(frozenset(ch))
want = {frozenset(w2b(x) for x in line.split("=")) for line in
        "A=BD=CE=ABCDE|B=AD=CDE=ABCE|C=AE=BDE=ABCD|D=AB=BCE=ACDE|E=AC=BCD=ABDE|"
        "BC=DE=ABE=ACD|BE=CD=ABC=ADE|I=ABD=ACE=BCDE".split("|")}
check("n_chains", len(got), 8)
check("chain_sizes", {len(c) for c in got}, {4})
check("chains_match_readme", got == want, True)

# --- Court 2: effects re-derived from the raw CSV (contrast-mean convention,
# matching the solution key: eff = sum(x_L * y) / N)
cols = {"A": "A_speed", "B": "B_feed", "C": "C_coolant",
        "D": "D_coating", "E": "E_toolholder"}
def eff(name):
    return sum(math.prod(int(r[cols[c]]) for c in name) * float(r["bore_deviation_um"])
               for r in rows) / len(rows)
check("eff_A_chain", round(eff("A"), 3), -7.948 + DELTA)
check("eff_B_chain", round(eff("B"), 3), 6.231)
check("eff_C_chain", round(eff("C"), 3), -4.159)
check("eff_D_chain", round(eff("D"), 3), 2.846)
check("eff_BC_chain", round(eff("BC"), 3), 2.240)
check("eff_E_chain", round(eff("E"), 3), -0.645)
check("eff_BE_chain", round(eff("BE"), 3), 0.159)
ybar = sum(float(r["bore_deviation_um"]) for r in rows) / len(rows)
check("grand_mean", round(ybar, 3), 9.751)

# alias contrasts are bit-identical within a chain (the mechanical alias proof)
check("alias_identical_A", eff("A") == eff("BD") == eff("CE") == eff("ABCDE"), True)
check("alias_identical_BC", eff("BC") == eff("DE"), True)
check("alias_identical_BE", eff("BE") == eff("CD"), True)

# the res-III lesson: D chain carries the planted AB=+3, D itself is 0
check("D_chain_is_AB_wearing_label", abs(eff("D") - 3.0) < 1.0, True)

# pure error from replicate pairs (key §4)
byo = {}
for r in rows: byo.setdefault(int(r["std_order"]), []).append(float(r["bore_deviation_um"]))
pe_sd = math.sqrt(sum((v[0] - v[1]) ** 2 for v in byo.values()) / (2 * 8))
check("pure_error_sd", round(pe_sd, 3), 1.734)
check("noise_chains_below_pure_error", abs(eff("E")) < pe_sd and abs(eff("BE")) < pe_sd, True)

# --- Court 3: fold-over — parity survivor set + res-IV alias recompute
par = {w: ("breaks" if w2b(w).bit_count() % 2 else "survives") for w in ("ABD", "ACE", "BCDE")}
check("foldover_ABD_breaks", par["ABD"], "breaks")
check("foldover_ACE_breaks", par["ACE"], "breaks")
check("foldover_BCDE_survives", par["BCDE"], "survives")
G2 = {0, w2b("BCDE")}
seen, pairs = set(), {}
for e in range(32):
    if e in seen: continue
    ch = tuple(sorted(e ^ w for w in G2)); seen |= set(ch)
    pairs[min(ch)] = tuple(b2w(w) for w in sorted(ch))
check("n_resIV_cosets", len(pairs), 16)
def pair_of(m):
    b = w2b(m); return pairs[min(b, b ^ w2b("BCDE"))]
check("fold_A_alias", pair_of("A"), ("A", "ABCDE"))
check("fold_AB_alias", pair_of("AB"), ("AB", "ACDE"))
check("fold_BC_alias", pair_of("BC"), ("BC", "DE"))
check("fold_BD_alias", pair_of("BD"), ("BD", "CE"))
check("fold_BE_alias", pair_of("BE"), ("CD", "BE"))
main_clear = all(len(next(w for w in pair_of(m) if w != m)) >= 3 for m in "ABCDE")
check("main_effects_clear_of_2fi", main_clear, True)

# MUTATION TEST: a wrong generator (E=BC instead of E=AC) must produce a
# different defining group and different chains — detectable divergence
Gw = {0, w2b("ABD"), w2b("BC")}
Gw = {a ^ b for a in Gw for b in Gw}
check("mutation_detected_wrong_generator",
      {b2w(w) for w in Gw} != {b2w(w) for w in G}, True)

# STALENESS SWEEP: retired 4.17 um sigma must not reappear in module prose
for dirpath, _, files in os.walk(HERE):
    for fn in files:
        if fn.endswith((".md", ".csv")) and "4.17" in open(os.path.join(dirpath, fn), errors="ignore").read():
            fail.append(f"stale 4.17 um sigma found in {fn}")

if fail:
    print("COURT FAIL"); [print(" -", f) for f in fail]; sys.exit(1)
print("Module 31 court: ALL CHECKS PASS (defining-group closure, 8x4 chains vs README §3, "
      "7 chain effects + pure error from CSV, alias contrast identity, fold-over parity + "
      "res-IV cosets, wrong-generator mutation, stale-4.17 sweep)")

# ---------- mutation test (module 28 pattern) ----------
if MUT:
    if round(eff("A"), 3) == round(-7.948 + DELTA, 3):
        print("VACUOUS COURT: corrupted A-chain pin still passes"); sys.exit(2)
    print("MUTATION DETECTED: eff_A_chain pinned at %.3f vs derived %.4f -> nonzero" % (-7.948 + DELTA, eff("A")))
    sys.exit(1)
sys.exit(0)
