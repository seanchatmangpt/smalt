#!/usr/bin/env python3
"""Module 40 court — independent re-derivation of every S/N value, effects,
noise structure, and the coating x hardness interaction. Exit 0/1.
"""
import csv, math, sys, statistics as st

BASE = __file__.replace("courts/court.py", "")
fails = []

def check(nm, got, exp, tol=0.01):
    ok = abs(got - exp) <= tol
    if not ok:
        fails.append(nm)
    print(f"  {'PASS' if ok else 'FAIL'}  {nm}: got {got:.4f} expected {exp}")

rows = list(csv.DictReader(open(f"{BASE}data/robust-bore.csv")))
check("32 runs total", len(rows), 32, 0)
per = {}
for r in rows:
    per.setdefault(int(r["inner_run"]), []).append(r)
check("4 outer obs per inner run, 8 inner runs",
      1.0 if all(len(v) == 4 for v in per.values()) and len(per) == 8
      else 0.0, 1.0, 0.0)

def sn_stb(ys):
    return -10 * math.log10(sum(v * v for v in ys) / len(ys))

def sn_ltb(ys):
    return -10 * math.log10(sum(1 / (v * v) for v in ys) / len(ys))

ctl = {}
for run in range(1, 9):
    obs = per[run]
    devs = [float(r["bore_dev_um"]) for r in obs]
    ctl[run] = dict(
        s=0 if obs[0]["speed"] == "V6000" else 1,
        f=0 if obs[0]["feed"] == "F220" else 1,
        c=0 if obs[0]["coating"] == "uncoated" else 1,
        m=st.mean(devs), sn=sn_stb(devs),
        lsn=sn_ltb([float(r["tool_life_min"]) for r in obs]),
        m_soft=st.mean([float(r["bore_dev_um"]) for r in obs
                        if r["hardness"] == "soft"]),
        m_hard=st.mean([float(r["bore_dev_um"]) for r in obs
                        if r["hardness"] == "hard"]))

exp_table = {1: (6.79, -16.72, 30.10), 2: (5.12, -14.49, 31.75),
             3: (10.34, -20.41, 28.68), 4: (7.22, -17.43, 30.00),
             5: (6.79, -16.66, 30.53), 6: (3.23, -10.26, 31.84),
             7: (6.97, -17.31, 28.88), 8: (3.86, -11.91, 31.24)}
for run, (m, sn, lsn) in exp_table.items():
    check(f"run {run} mean (um)", ctl[run]["m"], m, 0.01)
    check(f"run {run} S/N STB (dB)", ctl[run]["sn"], sn, 0.01)
    check(f"run {run} S/N LTB on tool life (dB)", ctl[run]["lsn"], lsn, 0.01)

def eff(attr, lv, key):
    return st.mean([p[key] for p in ctl.values() if p[attr] == lv])

check("speed S/N effect", eff("s", 1, "sn") - eff("s", 0, "sn"), 3.23, 0.01)
check("feed S/N effect", eff("f", 1, "sn") - eff("f", 0, "sn"), -2.24, 0.01)
check("coating S/N effect", eff("c", 1, "sn") - eff("c", 0, "sn"), 4.25, 0.01)
check("speed mean effect", eff("s", 1, "m") - eff("s", 0, "m"), -2.15, 0.01)
check("feed mean effect", eff("f", 1, "m") - eff("f", 0, "m"), 1.62, 0.01)
check("coating mean effect", eff("c", 1, "m") - eff("c", 0, "m"), -2.87, 0.01)
check("noise lift uncoated (+0.84 um)", eff("c", 0, "m_hard") -
      eff("c", 0, "m_soft"), 0.84, 0.01)
check("noise lift coated (-0.41 um)", eff("c", 1, "m_hard") -
      eff("c", 1, "m_soft"), -0.41, 0.01)
check("best run on S/N is 6", 1.0 if max(ctl, key=lambda k: ctl[k]["sn"]) == 6
      else 0.0, 1.0, 0.0)
check("run 6 raw deviations", 1.0 if [float(r["bore_dev_um"]) for r in per[6]]
      == [3.61, 3.70, 2.83, 2.78] else 0.0, 1.0, 0.0)

md = open(f"{BASE}slides-outline.md").read()
for token in ("-10.26", "+3.23", "+4.25", "3.23", "16.72", "+0.84"):
    check(f"outline cites {token}", 1.0 if token in md else 0.0, 1.0, 0.0)

print(f"\nMODULE 40 COURT: {'PASS' if not fails else 'FAIL'} "
      f"({len(fails)} failures)")
sys.exit(1 if fails else 0)
