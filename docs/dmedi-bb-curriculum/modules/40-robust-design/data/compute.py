#!/usr/bin/env python3
"""Module 40 solution key — Taguchi robust design on the CPPC bore.
Inner array L8 = 2^3 control factors: A spindle speed, B feed rate, C tool
coating. Outer array 2^2 noise factors: N1 bar-stock hardness (soft/hard),
N2 coolant temperature (cool/warm). Response 1: bore deviation from 12.000 mm
(um). Response 2: tool life (min), larger-the-better demonstration.
Seed 40001. Computes all three S/N families:
  smaller-the-better  eta_STB = -10 log10( mean(y^2) )
  nominal-the-best    eta_NTB =  10 log10( ybar^2 / s^2 )
  larger-the-better   eta_LTB = -10 log10( mean(1/y^2) )
Per-run mean + S/N, control-by-noise interaction read, best setup chosen on
S/N, not on the mean. Regenerates robust-bore.csv; re-derives from disk.
"""
import csv, math, random, statistics as st

SEED = 40001
BASE = __file__.rsplit("/", 1)[0]

# control levels (natural): speed 6000/9000 RPM, feed 220/340 mm/min,
# coating uncoated/coated
CONTROL = [("V6000", "V9000"), ("F220", "F340"), ("uncoated", "coated")]
INNER = [(i, (i >> 2) & 1, (i >> 1) & 1, i & 1) for i in range(8)]
NOISE = [("soft", "cool"), ("soft", "warm"), ("hard", "cool"), ("hard", "warm")]

# true model: bore deviation um, target 0. Effects: speed high lowers
# deviation, feed high raises, coating lowers + cuts noise sensitivity,
# hard bar stock raises deviation, warm coolant raises deviation.
def true_dev(speed_hi, feed_hi, coated, hard, warm):
    y = (7.0 - 3.0 * speed_hi + 1.5 * feed_hi - 2.0 * coated
         + 1.2 * hard + 0.8 * warm
         + 1.4 * feed_hi * warm          # feed x coolant-temp interaction
         - 1.5 * coated * hard)          # coating damps hardness noise
    return y

def true_life(speed_hi, feed_hi, coated, hard, warm):
    base = 34 + 6 * coated - 5 * feed_hi + 2 * speed_hi - 2.5 * hard - 1.5 * warm
    return max(base, 3.0)

def generate():
    random.seed(SEED)
    with open(f"{BASE}/robust-bore.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["inner_run", "speed", "feed", "coating",
                    "hardness", "coolant_temp",
                    "bore_dev_um", "tool_life_min"])
        for run, s, f_, c in INNER:
            for hard, warm in NOISE:
                hv = 0 if hard == "soft" else 1
                wv = 0 if warm == "cool" else 1
                dev = random.gauss(true_dev(s, f_, c, hv, wv), 1.0)
                life = random.gauss(true_life(s, f_, c, hv, wv), 2.0)
                w.writerow([run + 1, CONTROL[0][s], CONTROL[1][f_],
                            CONTROL[2][c], hard, warm,
                            round(dev, 2), round(life, 1)])

generate()

rows = list(csv.DictReader(open(f"{BASE}/robust-bore.csv")))
def sn_stb(ys):  return -10 * math.log10(sum(y * y for y in ys) / len(ys))
def sn_ntb(ys):
    m, s = st.mean(ys), st.stdev(ys)
    return 10 * math.log10(m * m / (s * s))
def sn_ltb(ys):  return -10 * math.log10(sum(1 / (y * y) for y in ys) / len(ys))

print("== Module 40 solution key: inner/outer robust design ==")
print("inner L8 (control: speed, feed, coating) x outer 4 (noise: hardness,"
      " coolant temp) = 32 runs\n")

per = []
for run, s, f_, c in INNER:
    obs = [r for r in rows if int(r["inner_run"]) == run + 1]
    devs = [float(r["bore_dev_um"]) for r in obs]
    lives = [float(r["tool_life_min"]) for r in obs]
    per.append(dict(run=run + 1, s=s, f=f_, c=c, devs=devs, lives=lives,
                    m=st.mean(devs), sd=st.stdev(devs),
                    sn=sn_stb(devs), lsn=sn_ltb(lives)))

hdr = f"{'run':<4}{'speed':<8}{'feed':<7}{'coat':<10}{'mean_um':>8}{'s':>6}{'S/N_STB':>9}{'life':>7}{'S/N_LTB':>9}"
print(hdr)
for p in per:
    print(f"{p['run']:<4}{CONTROL[0][p['s']]:<8}{CONTROL[1][p['f']]:<7}"
          f"{CONTROL[2][p['c']]:<10}{p['m']:8.2f}{p['sd']:6.2f}"
          f"{p['sn']:9.2f}{st.mean(p['lives']):7.1f}{p['lsn']:9.2f}")

# ---------------------------------------------------------------- effects on S/N
def sn_effect(k, lvl, key):
    vals = [p[key] for p in per if p[("s", "f", "c")[k]] == lvl]
    return st.mean(vals)

print("\n-- control-factor mean effects on S/N_STB (dB) --")
for k, nm in enumerate(("speed", "feed", "coating")):
    lo = sn_effect(k, 0, "sn")
    hi = sn_effect(k, 1, "sn")
    print(f"  {nm:<8} lo {lo:6.2f}  hi {hi:6.2f}  effect {hi - lo:+6.2f} dB")

print("\n-- control-factor effects on the MEAN deviation (um) --")
for k, nm in enumerate(("speed", "feed", "coating")):
    lo = sn_effect(k, 0, "m")
    hi = sn_effect(k, 1, "m")
    print(f"  {nm:<8} lo {lo:6.2f}  hi {hi:6.2f}  effect {hi - lo:+6.2f}")

best = max(per, key=lambda p: p["sn"])
print(f"\nbest setup on S/N_STB: run {best['run']} "
      f"({CONTROL[0][best['s']]}/{CONTROL[1][best['f']]}/{CONTROL[2][best['c']]}) "
      f"S/N = {best['sn']:.2f} dB, mean {best['m']:.2f} um, SD {best['sd']:.2f} um")

# noise sensitivity: mean deviation at each noise combo, averaged over controls
print("\n-- noise main effects (averaged over all 8 controls) --")
for i, (hard, warm) in enumerate(NOISE):
    obs = [r for r in rows if r["hardness"] == hard and r["coolant_temp"] == warm]
    m = st.mean([float(r["bore_dev_um"]) for r in obs])
    print(f"  {hard:<5}+{warm:<5} mean deviation {m:6.2f} um")

# control-by-noise interaction: coating x hardness (does coating damp noise?)
print("\n-- coating x hardness interaction (control x noise) --")
for coat in (0, 1):
    m_soft = st.mean([r["bore_dev_um"] and float(r["bore_dev_um"]) for r in rows
                      if int(r["inner_run"]) - 1 in
                      [i for i in range(8) if INNER[i][3] == coat]
                      and r["hardness"] == "soft"])
    m_hard = st.mean([float(r["bore_dev_um"]) for r in rows
                      if int(r["inner_run"]) - 1 in
                      [i for i in range(8) if INNER[i][3] == coat]
                      and r["hardness"] == "hard"])
    print(f"  {CONTROL[2][coat]:<9} soft {m_soft:5.2f} um | hard {m_hard:5.2f} um"
          f" | noise lift {m_hard - m_soft:+5.2f} um")

# demonstration of all three S/N families on the SAME best run's outer data
print("\n-- S/N family comparison on run "
      f"{best['run']}'s four outer observations --")
print(f"  deviations (um): {best['devs']}")
print(f"  eta_STB = -10log10(mean(y^2))          = {sn_stb(best['devs']):.2f} dB")
print(f"  eta_NTB = 10log10(ybar^2/s^2)          = {sn_ntb(best['devs']):.2f} dB")
print(f"  eta_LTB on tool life {best['lives']} = {sn_ltb(best['lives']):.2f} dB")
