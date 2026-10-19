#!/usr/bin/env python3
"""acceptance_gates.py — the 5-gate "100% replaced, not deleted" contract (V261019).

G1 exact-set:     git ls-files test/ == the enumerated fresh set (manifest 303
                  baseline; any legacy path reappearing = fail).
G2 revert-diff:   shim court coverage_falsifier_court.sh — suites must catch an
                  injected Cosmos-CAS protocol break (0 = witnessed; 3 = pending
                  green suites; 1 = VACUOUS COVERAGE = hard fail).
G3 cell coverage: sdk_coverage.py --strict exits 0 (every cell pass-or-registered).
G4 VM boundary:   non_duplication_gate.py exit 0 over test/internal +
                  internal_tier_census population fence via mix test census test.
G5 dual-pass:     court_x2 law — two consecutive `just court` greens at one SHA
                  (checked here via the court-x2 receipt, not re-executed).

Exit 0 only when no gate FAILs; PENDING gates (suites not landed) are reported
honestly and exit 3 overall until they resolve. Never fakes a pass.
"""
import subprocess, sys, os

REPO = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                      capture_output=True, text=True).stdout.strip()
EXPECTED_TEST_SET = {
    "test/test_helper.exs",
    "test/internal/poll_helper.exs",
    "test/internal/plane_blast_radius_test.exs",
    "test/internal/vm_zero_growth_test.exs",
    "test/internal/wasm_nif_lifecycle_test.exs",
    "test/internal/dets_mirror_recovery_test.exs",
    "test/internal/internal_tier_census_test.exs",
    # v26.10.19 amendments (fresh files, landed lanes; each census-registered):
    "test/cluster/cluster_test.exs",             # DNS-cluster lane (test/ seam per
                                                 #  _LANES.md WO-10 closure)
    "test/adaptive_health_test.exs",             # adaptive-probe lane (root: census-
}                                                #  fenced test/internal is closed)

def run(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kw)

results = []

# G1 — exact set-difference
r = run("git ls-files test/")
got = set(r.stdout.split())
if r.returncode != 0:
    results.append(("G1", "FAIL", "git ls-files failed"))
elif got == EXPECTED_TEST_SET:
    results.append(("G1", "PASS", f"{len(got)} files == enumerated fresh set"))
elif got and got <= EXPECTED_TEST_SET:
    missing = EXPECTED_TEST_SET - got
    results.append(("G1", "PENDING", f"{len(got)}/{len(EXPECTED_TEST_SET)} committed; uncommitted: {sorted(missing)}"))
else:
    results.append(("G1", "FAIL", f"UNEXPECTED paths present: {sorted(got - EXPECTED_TEST_SET)}"))

# G2 — revert-the-diff falsifier
r = run("bash scripts/shim_court/coverage_falsifier_court.sh",
        cwd=REPO, timeout=1800)
if r.returncode == 0:
    results.append(("G2", "PASS", "suites caught the injected CAS break"))
elif r.returncode == 3:
    results.append(("G2", "PENDING", "suites not green yet — falsifier deferred (typed SKIP)"))
else:
    results.append(("G2", "FAIL", "VACUOUS COVERAGE — suites green under the protocol break"))

# G3 — exhaustive cell discovery
r = run(f"{sys.executable} scripts/sdk_coverage.py --strict", cwd=REPO, timeout=300)
if r.returncode == 0:
    results.append(("G3", "PASS", "every surface cell pass-or-registered"))
else:
    results.append(("G3", "PENDING" if "MISSING" in r.stdout else "FAIL",
                    f"rc={r.returncode} (tail: {r.stdout.strip().splitlines()[-1] if r.stdout.strip() else r.stderr.strip()[-120:]})"))

# G4 — non-duplication + census fence
r = run(f"{sys.executable} scripts/non_duplication_gate.py", cwd=REPO)
g4a = r.returncode == 0
r2 = run("MIX_BUILD_ROOT=_build-acc-gate mix test test/internal/internal_tier_census_test.exs",
         cwd=REPO, timeout=600)
g4b = r2.returncode == 0 and "0 failures" in r2.stdout
if g4a and g4b:
    results.append(("G4", "PASS", "non-duplication clean + census fence green"))
elif g4a:
    results.append(("G4", "FAIL", "non-duplication clean but census fence red:\n" + r2.stdout[-400:]))
else:
    results.append(("G4", "FAIL", "non-duplication gate red:\n" + r.stdout[-400:]))

# G5 — dual-pass court-x2 (receipt-based here; full run is the release gate).
# Witness predicate: the receipt must carry an ALIVE/PASS standing AND an
# executed exit=0 tail — prose mentioning "two consecutive" in a skeleton is
# not evidence (the skeleton itself once false-passed this check).
rcpt = os.path.join(REPO, "docs/jira/v26.10.19/receipts/v261019-12-court-x2-close.md")
if os.path.exists(rcpt):
    text = open(rcpt).read()
    standing_ok = any(
        f"Standing: {s}" in text for s in ("ALIVE", "PASS", "LANDED"))
    executed = ("exit=0" in text or "EXIT=0" in text) and "court-x2" in text
    if standing_ok and executed:
        results.append(("G5", "PASS", "court-x2 receipt: standing + executed exit=0 witnessed"))
    else:
        results.append(("G5", "PENDING", "court-x2 receipt exists but lacks standing/exit evidence"))
else:
    results.append(("G5", "PENDING", "court-x2 not yet executed (wrap-time release gate)"))

print("=== 5-GATE ACCEPTANCE (100% replaced, not deleted) ===")
verdicts = [v for _, v, _ in results]
for g, v, d in results:
    print(f"  [{v:7}] {g}: {d}")
if "FAIL" in verdicts:
    print("GATE: FAIL — a fail-closed contract is broken")
    sys.exit(1)
if "PENDING" in verdicts:
    print("GATE: PENDING — contract intact, awaiting suite landing + wrap")
    sys.exit(3)
print("GATE: OK — 100% replaced, machine-proven")
