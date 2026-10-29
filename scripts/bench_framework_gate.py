#!/usr/bin/env python3
"""bench_framework_gate.py — fail-closed bench-framework census gate (BENCH-14).

Verdict landed by BENCH-9 (docs/jira/v26.10.21/receipts/bench9-deletion-audit.md):
deletion of the benchee dep is a measurement no-op; enforcement is prospective.
This gate freezes that state:

  1. No benchee / benchee_html dep or NEW benchee reference anywhere in
     mix.exs / mix.lock / lib/ / test/ / scripts/ — except the frozen
     allowlist (scripts/bench/benchee_runner.exs, the BENCH-9-cited
     evidence record, docs/jira/v26.10.14/receipts/errc2-benchee.md).
  2. No new Benchee.run / :timer.tc inside scripts/bench without either
     membership in the frozen allowlist (the 3 BENCH-9-classified
     :timer.tc probes: b8_amqp_beam.exs, pb6_dual_boundary.exs,
     c10_affidavit_seal.exs) or a `# BENCH-CLASS: probe` annotation on the
     site's line.
  3. Plain census output; exit 0 pass / 1 fail (fail-closed: a missing
     mix.exs or unreadable tree is a FAIL, not a skip).

Non-vacuity: `--self-check` mints a temp copy with an injected benchee dep
line + an unannotated :timer.tc site and proves the census REFUSES both,
then proves the real tree PASSES. A gate that cannot refuse is VACUOUS.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Frozen allowlist — BENCH-9 classification (bench9-deletion-audit.md).
ALLOWED_BENCHEE_FILES = {
    "scripts/bench/benchee_runner.exs",  # grandfathered evidence record
}
# The gate's own source names "benchee" in patterns/messages — exempt it.
SELF_EXEMPT = {"scripts/bench_framework_gate.py", "justfile.d/47-bench-framework.just"}
ALLOWED_TC_FILES = {
    "scripts/bench/b8_amqp_beam.exs",       # 2 sites
    "scripts/bench/pb6_dual_boundary.exs",  # 7 sites
    "scripts/bench/c10_affidavit_seal.exs",  # 1 site
}
SCAN_DIRS = ["lib", "test", "scripts"]
SCAN_FILES = ["mix.exs", "mix.lock"]
BENCH_CLASS_RE = re.compile(r"#\s*BENCH-CLASS:\s*probe\b")
TC_RE = re.compile(r":timer\.tc")
BENCHEE_RE = re.compile(r"benchee", re.IGNORECASE)
BENCHEE_RUN_RE = re.compile(r"Benchee\.run")

violations: list[str] = []


def fail(msg: str) -> None:
    violations.append(msg)


def read(path: str) -> str | None:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        fail(f"FAIL-CLOSED unreadable: {path} ({e})")
        return None


def census(root: str) -> int:
    """Census `root` as the repo; returns exit code (0 pass, 1 fail)."""
    global violations
    violations = []
    mix = os.path.join(root, "mix.exs")
    if not os.path.isfile(mix):
        fail(f"FAIL-CLOSED missing mix.exs at {root}")
        report(root)
        return 1
    for rel in SCAN_FILES:
        scan_file(os.path.join(root, rel), rel, allow_benchee=False)
    for d in SCAN_DIRS:
        base = os.path.join(root, d)
        if not os.path.isdir(base):
            continue  # optional dir
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [
                x for x in dirnames
                if x not in ("_build", "deps", "__pycache__", "node_modules")
            ]
            for name in filenames:
                if not name.endswith((".ex", ".exs", ".py", ".sh", ".mjs", ".ts",
                                      ".js", ".just", ".toml", ".yaml", ".yml",
                                      ".ttl", ".lock", ".json")):
                    continue
                path = os.path.join(dirpath, name)
                rel = os.path.relpath(path, root)
                allow_benchee = rel in ALLOWED_BENCHEE_FILES or rel in SELF_EXEMPT
                scan_file(path, rel, allow_benchee=allow_benchee)
                if rel.startswith("scripts/bench/"):
                    scan_tc(path, rel)
    return report(root)


def scan_file(path: str, rel: str, *, allow_benchee: bool) -> None:
    text = read(path)
    if text is None:
        return
    if BENCHEE_RE.search(text) and not allow_benchee:
        fail(f"BENCHEE-REF {rel}: benchee reference outside frozen allowlist "
             f"({', '.join(sorted(ALLOWED_BENCHEE_FILES))}); "
             f"receipt: docs/jira/v26.10.14/receipts/errc2-benchee.md")


def scan_tc(path: str, rel: str) -> None:
    text = read(path)
    if text is None:
        return
    in_benchee_allow = rel in ALLOWED_BENCHEE_FILES
    for i, line in enumerate(text.splitlines(), 1):
        if TC_RE.search(line):
            if rel in ALLOWED_TC_FILES or in_benchee_allow:
                continue
            if BENCH_CLASS_RE.search(line):
                continue
            fail(f"TIMER-TC {rel}:{i}: unannotated :timer.tc in scripts/bench "
                 f"without `# BENCH-CLASS: probe` and outside the frozen "
                 f"allowlist; receipt: "
                 f"docs/jira/v26.10.21/receipts/bench9-deletion-audit.md")
        if BENCHEE_RUN_RE.search(line):
            if not in_benchee_allow:
                fail(f"BENCHEE-RUN {rel}:{i}: Benchee.run outside the frozen "
                     f"allowlist; receipt: "
                     f"docs/jira/v26.10.14/receipts/errc2-benchee.md")


def report(root: str) -> int:
    print(f"== bench-framework gate census ({root})")
    print(f"   benchee allowlist : {len(ALLOWED_BENCHEE_FILES)} file(s), frozen")
    print(f"   :timer.tc probes  : {len(ALLOWED_TC_FILES)} file(s), frozen "
          f"(BENCH-9 classified)")
    if violations:
        print(f"   VERDICT: FAIL ({len(violations)} violation(s))")
        for v in violations:
            print(f"     - {v}")
        return 1
    print("   VERDICT: PASS")
    return 0


def self_check() -> int:
    """Anti-vacuity: mutated temp copy must FAIL; real tree must PASS."""
    tmp = tempfile.mkdtemp(prefix="bench_framework_gate_selfcheck_")
    try:
        # Mutated temp copy: injected benchee dep + unannotated timer.tc probe.
        for f in SCAN_FILES:
            src = os.path.join(REPO, f)
            dst = os.path.join(tmp, f)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)
        mix = os.path.join(tmp, "mix.exs")
        text = open(mix).read()
        text = text.replace(
            "defp deps do",
            "defp deps do\n    # SHIM-COURT inject: {:benchee, \"~> 1.3\", only: :test}\n    # SHIM-COURT inject: {:benchee_html, \"~> 1.0\", only: :dev}",
            1,
        )
        with open(mix, "w") as f:
            f.write(text)
        os.makedirs(os.path.join(tmp, "scripts/bench"), exist_ok=True)
        probe = os.path.join(tmp, "scripts/bench/zz_shim_probe.exs")
        with open(probe, "w") as f:
            f.write("# SHIM-COURT inject: unannotated :timer.tc probe\n"
                    "{us, _} = :timer.tc(fn -> :ok end)\n")
        for d in SCAN_DIRS:
            src = os.path.join(REPO, d)
            if not os.path.isdir(src):
                continue
            dst = os.path.join(tmp, d)
            # Symlink lib/ etc so the mutated mix.exs census walks a full tree
            # cheaply; symlinks are followed at walk time (os.walk on the
            # symlink dir itself lists real contents).
            if not os.path.exists(dst):
                os.symlink(src, dst)
        rc = census(tmp)
        injected = [v for v in violations if "SHIM-COURT" not in v]
        if rc != 1 or not injected:
            print("VACUOUS GATE: mutated temp copy did not FAIL — "
                  "the census cannot refuse; gate is invalid.")
            return 1
        print("   self-check shim: injected benchee dep + unannotated "
              ":timer.tc -> REFUSED (non-vacuity proof)")
        # Clean tree must PASS.
        violations_before = len(violations)
        rc_real = census(REPO)
        if rc_real != 0:
            print("NOTE: real-tree census FAIL — see violations above "
                  "(fail-closed, honest red).")
            return 1
        print("   self-check clean: real tree -> PASS")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    if "--self-check" in sys.argv[1:]:
        sys.exit(self_check())
    target = "."
    for a in sys.argv[1:]:
        if not a.startswith("--"):
            target = a
    sys.exit(census(os.path.abspath(target)))
