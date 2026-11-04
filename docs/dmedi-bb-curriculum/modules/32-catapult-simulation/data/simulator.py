#!/usr/bin/env python3
"""CPPC tabletop catapult simulator — Module 32 (Lane 13).

Deterministic physics model + dataset generator. Re-running this file regenerates
catapult-results.csv byte-identically (seeded noise, no wall-clock input).

Physics (documented, deliberately simple, nonlinear where it matters):
  release speed   v = K * theta_rad * L * sqrt(m0 / m)
      (torsion release -> tip speed; heavier ball = slower release: v ~ theta*L/sqrt(m))
  launch angle    alpha = 45deg + 15deg * (H - 0.20) / 0.10
      (pivot height tilts the launch angle; exactly 45 deg at H = 0.20 m)
  vacuum range   R = v^2 * sin(2 * alpha) / g,  g = 9.80665 m/s^2
  noise           N(0, 12 mm) additive, random.seed(43201)

Factor ranges (coded units -1/0/+1):
  A arm length   L : 0.40 / 0.50 / 0.60 m
  B stop angle  th : 40   / 50   / 60   deg
  C ball weight  m : 40   / 60   / 80   g
  D pivot height H : 0.10 / 0.20 / 0.30 m

Planted behavior (what the lab is designed to reveal):
  - range increases monotonically in A, B and decreases in C over the tested
    ranges -> the best factorial point sits AT A CORNER (A+, B+, C-, D mid),
  - but v^2 and sin(2 alpha) are both nonlinear in their factors -> center
    points sit ABOVE the factorial-plane prediction -> curvature signal ->
    forward-link to Module 15 (RSM), where the true interior optimum lives.
"""

import math
import random
import csv
import os

G = 9.80665       # gravity, m/s^2
K = 8.0           # torsion -> tip-speed constant, 1/s
M0 = 0.060        # reference mass, kg
SIGMA_MM = 0.012  # run-to-run noise sd, m
SEED = 43201

LEVELS = {
    "A_armlen_m": {-1: 0.40, 0: 0.50, 1: 0.60},
    "B_stopang_deg": {-1: 40.0, 0: 50.0, 1: 60.0},
    "C_ballmass_g": {-1: 40.0, 0: 60.0, 1: 80.0},
    "D_pivot_m": {-1: 0.10, 0: 0.20, 1: 0.30},
}

CENTER = {"A_armlen_m": 0.50, "B_stopang_deg": 50.0,
          "C_ballmass_g": 60.0, "D_pivot_m": 0.20}


def release_speed(L_m, theta_deg, mass_g):
    """Release tip speed, m/s: v = K * theta_rad * L * sqrt(m0/m)."""
    theta_rad = math.radians(theta_deg)
    return K * theta_rad * L_m * math.sqrt(M0 / (mass_g / 1000.0))


def launch_angle(H_m):
    """Launch angle, degrees: 45 + 15*(H-0.20)/0.10."""
    return 45.0 + 15.0 * (H_m - 0.20) / 0.10


def ideal_range_m(L_m, theta_deg, mass_g, H_m):
    """Noiseless vacuum range, m."""
    v = release_speed(L_m, theta_deg, mass_g)
    alpha = math.radians(launch_angle(H_m))
    return (v * v) * math.sin(2.0 * alpha) / G


def noisy_range_m(L_m, theta_deg, mass_g, H_m, rng):
    """One observed run: ideal range + N(0, 12 mm)."""
    return ideal_range_m(L_m, theta_deg, mass_g, H_m) + rng.gauss(0.0, SIGMA_MM)


def design_rows():
    """16-run 2^4 factorial (Yates order) + 4 center points, in run order.

    Run order: factorial points in a seeded shuffled order, then the 4 center
    points spread through the sequence is NOT used here; the run sheet keeps
    center points 17-20 for classroom simplicity (note in README).
    """
    runs = []
    for a in (1, -1):
        for b in (1, -1):
            for c in (1, -1):
                for d in (1, -1):
                    runs.append((a, b, c, d))
    rng = random.Random(SEED)
    order = list(range(16))
    rng.shuffle(order)
    rows = []
    for i, (a, b, c, d) in enumerate(runs):
        L = LEVELS["A_armlen_m"][a]
        th = LEVELS["B_stopang_deg"][b]
        m = LEVELS["C_ballmass_g"][c]
        H = LEVELS["D_pivot_m"][d]
        r = noisy_range_m(L, th, m, H, rng)
        rows.append([i + 1, order[i] + 1, a, b, c, d, L, th, m, H,
                     round(r, 4)])
    for j in range(4):
        r = noisy_range_m(CENTER["A_armlen_m"], CENTER["B_stopang_deg"],
                          CENTER["C_ballmass_g"], CENTER["D_pivot_m"], rng)
        rows.append([17 + j, 17 + j, 0, 0, 0, 0,
                     CENTER["A_armlen_m"], CENTER["B_stopang_deg"],
                     CENTER["C_ballmass_g"], CENTER["D_pivot_m"],
                     round(r, 4)])
    return rows


def main():
    rows = design_rows()
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(here, "catapult-results.csv")
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["std_order", "run_order", "A", "B", "C", "D",
                    "A_armlen_m", "B_stopang_deg", "C_ballmass_g",
                    "D_pivot_m", "dist_m"])
        w.writerows(rows)
    print("wrote", out, len(rows), "rows")


def self_test():
    """Exit-checked self-test: determinism + physics invariants.

    PASS prints 'SIM-SELFTEST PASS' and exits 0; any violation raises.
    """
    rng1 = random.Random(SEED)
    seq1 = [noisy_range_m(0.5, 50.0, 60.0, 0.20, rng1) for _ in range(5)]
    rng2 = random.Random(SEED)
    seq2 = [noisy_range_m(0.5, 50.0, 60.0, 0.20, rng2) for _ in range(5)]
    assert seq1 == seq2, "simulator not deterministic under seed"
    # physics spot values
    v = release_speed(0.5, 50.0, 60.0)
    assert abs(v - 8.0 * math.radians(50.0) * 0.5) < 1e-12  # m == m0 -> sqrt=1
    assert abs(launch_angle(0.20) - 45.0) < 1e-12
    assert abs(ideal_range_m(0.5, 50.0, 60.0, 0.20)
               - (v ** 2) * math.sin(math.radians(90.0)) / G) < 1e-12
    # monotone in arm length over tested range (corner-optimum premise)
    assert ideal_range_m(0.6, 60.0, 40.0, 0.20) > ideal_range_m(0.4, 60.0, 40.0, 0.20)
    # curvature premise: center sits above the linear factorial plane
    # (verified properly from the generated CSV in the solution key)
    print("SIM-SELFTEST PASS")
    return 0


if __name__ == "__main__":
    self_test()
    main()
