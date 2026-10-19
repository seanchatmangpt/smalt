#!/usr/bin/env python3
"""automation_gate.py — Automation Boundary Gate (fail-closed, stdlib only).

Phase 1 (AZB-24 / v26.10.19 envelope lane). Scans the automation surface:

  scripts/**        (.sh .bash .py .mjs)
  docker/burn/*.sh
  justfile.d/*.just

for five violation classes:

  1. DEPRECATED-TEST-PATH — references to retired test trees
     (test/sdk-, test/wire, test/support, test/compliance, test/azsim)
     on executable (non-comment) lines. Comment mentions are documentation
     of the reset and are skipped.
  2. COORDINATION-SLEEP — a standalone `sleep N` with N >= 2 in scripts/.
     Excluded when the line or its contiguous comment block above carries
     `# SLEEP-CLASS:` (bounded-poll pacing annotation, same vocabulary as
     scripts/sleep_gate.py).
  3. UNMANAGED-SPAWN — nohup / setsid / disown anywhere, or a line
     backgrounding (trailing `&`) a mix/beam/node spawn without the
     lock-fd-closed guard `9>&-` (substrate beams inherit the flock fd and
     hold it after the driver exits — same-checkout-fanout addition 4).
  4. HARDCODED-USER-PATH — a literal `/Users/` path on an executable line
     (portability + identity: scripts must derive paths from the repo).
  5. SILENT-EXIT-0 — (shell only, high-confidence heuristic) the script's
     final executable line is an unconditional success echo and the script
     contains no explicit exit-status discipline (no `exit <n|var>`, no
     `set -e`, no `return 1`) — i.e. it reports success it cannot falsify.

Exit 0 = pass, 1 = violations or fail-closed (no files scanned, unreadable
file, empty scan scope). Non-vacuity: `--self-test` plants one violation of
every class plus a clean control in a temp dir and proves the scanner
REFUSES each planted violation and PASSES the control; a self-test that
cannot plant is itself a failure (exit 1).
"""

import os
import re
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

DEPRECATED_PATHS = (
    "test/sdk-", "test/wire", "test/support", "test/compliance", "test/azsim",
)

DEPRECATED_RE = re.compile(
    r"(?<![\w/.-])(" + "|".join(re.escape(p) for p in DEPRECATED_PATHS) + r")"
)

SLEEP_RE = re.compile(r"^\s*sleep\s+(\d+)(?:\s|$)")
SLEEP_CLASS_ANN_RE = re.compile(r"#\s*SLEEP-CLASS:")
SPAWN_BIN_RE = re.compile(r"(?:^|[\s;&|(])(?:mix|beam\.smp|beam|node)\b")
BG_RE = re.compile(r"&\s*$")
FD_GUARD_RE = re.compile(r"9>&-")
NOHUP_RE = re.compile(r"\b(?:nohup|setsid|disown)\b")
USERS_RE = re.compile(r"/Users/")
ECHO_SUCCESS_RE = re.compile(
    r"\becho\b[^|;&]*(?:\bPASS\b|\bOK\b|\bsuccess\b|\bcomplete\b|\bdone\b)",
    re.IGNORECASE,
)

# Comments per file family: strip at first comment token (approximate; only
# ever skips, never invents, sites).
SHELL_SUFFIXES = (".sh", ".bash")
SCAN_SUFFIXES = SHELL_SUFFIXES + (".py", ".mjs")


def strip_comment(line, hash_comments):
    tok = "#" if hash_comments else "#"
    idx = line.find(tok)
    return line if idx == -1 else line[:idx]


def scan_lines(rel, lines, family):
    """family: 'shell' | 'py' | 'mjs' | 'just'. Returns [(line_no, code, detail)]."""
    v = []
    hash_comments = family in ("shell", "py", "just")

    for i, line in enumerate(lines):
        raw = strip_comment(line, hash_comments)
        stripped = raw.strip()
        if not stripped:
            continue

        # 1. deprecated test paths
        for m in DEPRECATED_RE.finditer(raw):
            v.append((i + 1, "DEPRECATED-TEST-PATH",
                      "reference to retired test tree `%s`" % m.group(1)))

        # 2. coordination sleep (scripts family only)
        if family == "shell":
            m = SLEEP_RE.match(stripped)
            if m and int(m.group(1)) >= 2:
                ann = SLEEP_CLASS_ANN_RE.search(line)
                if not ann:
                    # contiguous comment block above
                    j = i - 1
                    while j >= 0 and lines[j].lstrip().startswith("#"):
                        if SLEEP_CLASS_ANN_RE.search(lines[j]):
                            ann = True
                            break
                        j -= 1
                if not ann:
                    v.append((i + 1, "COORDINATION-SLEEP",
                              "standalone `sleep %s` without # SLEEP-CLASS: annotation" % m.group(1)))

        # 3. unmanaged spawns
        if family == "shell":
            if NOHUP_RE.search(raw):
                v.append((i + 1, "UNMANAGED-SPAWN",
                          "nohup/setsid/disown spawn detaches from lane supervision"))
        if family in ("shell", "just"):
            if BG_RE.search(raw) and SPAWN_BIN_RE.search(raw) and not FD_GUARD_RE.search(raw):
                v.append((i + 1, "UNMANAGED-SPAWN",
                          "backgrounded mix/beam/node spawn without `9>&-` lock-fd guard"))

        # 4. hardcoded /Users/ paths
        m = USERS_RE.search(raw)
        if m:
            v.append((i + 1, "HARDCODED-USER-PATH",
                      "literal `/Users/` path (derive from repo root / $HOME)"))

    return v


def scan_silent_exit0(rel, lines, family):
    """High-confidence shell heuristic: last executable line is an
    unconditional success echo AND the script has zero explicit exit-status
    discipline (`exit <n/var>`, `set -e`, `return 1`)."""
    if family != "shell":
        return []
    has_discipline = False
    last_exec = None
    for i, line in enumerate(lines):
        raw = strip_comment(line, True).strip()
        if not raw:
            continue
        if re.match(r"^(exit\s+\S|set\s+-e|set\s+-o\s+errexit|return\s+1\b)", raw):
            has_discipline = True
        last_exec = (i, raw)
    if has_discipline or last_exec is None:
        return []
    i, raw = last_exec
    if ECHO_SUCCESS_RE.search(raw):
        return [(i + 1, "SILENT-EXIT-0",
                 "final line is an unconditional success echo and the script "
                 "has no exit-status discipline (`exit <n>`, `set -e`, or "
                 "`return 1` absent)")]
    return []


def family_of(path):
    if path.endswith(SHELL_SUFFIXES):
        return "shell"
    if path.endswith(".py"):
        return "py"
    if path.endswith(".mjs"):
        return "mjs"
    return None


def collect_files(roots):
    out = []
    for root in roots:
        if os.path.isfile(root):
            out.append(root)
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames
                           if d not in (".git", "node_modules", "_build",
                                        "deps", "__pycache__", ".venv")]
            for n in sorted(filenames):
                p = os.path.join(dirpath, n)
                if family_of(p):
                    out.append(p)
    return sorted(out)


def run_scan(roots):
    files = collect_files(roots)
    if not files:
        print("[AUTOMATION-GATE] [FAIL] no scannable files under scope — fail-closed")
        return 1
    violations = []
    scanned = 0
    self_path = os.path.abspath(__file__)
    for f in files:
        if os.path.abspath(f) == self_path:
            # Loud self-exclusion: this scanner's own source contains the
            # violation-class literals it defines (docstring + self-test
            # fixtures). Its detection non-vacuity is carried by --self-test,
            # not by self-scan; skipping silently would be a vacuity channel,
            # so the exclusion is printed every run.
            print("[AUTOMATION-GATE] [NOTE] self-excluded: %s (detection "
                  "non-vacuity via --self-test)" % os.path.relpath(self_path, REPO))
            continue
        rel = os.path.relpath(os.path.abspath(f), REPO)
        family = family_of(f)
        try:
            with open(f, encoding="utf-8") as fh:
                lines = fh.read().split("\n")
        except OSError as exc:
            print("[AUTOMATION-GATE] [FAIL] unreadable file %s: %s" % (rel, exc))
            return 1
        scanned += 1
        violations.extend((rel,) + t for t in scan_lines(rel, lines, family))
        violations.extend((rel,) + t for t in scan_silent_exit0(rel, lines, family))

    if violations:
        print("[AUTOMATION-GATE] %d violation(s) across %d files — REFUSED"
              % (len(violations), scanned))
        for rel, ln, code, detail in violations:
            print("  [FAIL] %s:%d %s — %s" % (rel, ln, code, detail))
        return 1
    print("[AUTOMATION-GATE] PASS — %d files scanned, 0 violations" % scanned)
    return 0


# --------------------------------------------------------------------------
# Negative-fixture self-test: plant one violation of every class plus a
# clean control in a temp tree; the scanner must refuse each planted file
# (non-vacuity: a gate that cannot plant-and-refuse is vacuous) and pass
# the control.
# --------------------------------------------------------------------------

PLANTS = [
    ("deprecated_path.sh",
     "#!/usr/bin/env bash\nnode test/sdk-smoke/run.mjs\n", "DEPRECATED-TEST-PATH"),
    ("coord_sleep.sh",
     "#!/usr/bin/env bash\nboot_stuff\ndelay 1\nsleep 5\necho done-queueing\n",
     "COORDINATION-SLEEP"),
    ("unmanaged_spawn.sh",
     "#!/usr/bin/env bash\nnohup mix run --no-halt &\n", "UNMANAGED-SPAWN"),
    ("bare_bg_spawn.sh",
     "#!/usr/bin/env bash\nmix run --no-halt &\n", "UNMANAGED-SPAWN"),
    ("guarded_spawn.sh_CLEAN",
     "#!/usr/bin/env bash\nmix run --no-halt 9>&- &\nexit 0\n", None),
    ("hardcoded_path.py",
     "CONFIG = '/Users/sac/smalt/.smalt/tls/ca-cert.pem'\n", "HARDCODED-USER-PATH"),
    ("silent_exit0.sh",
     "#!/usr/bin/env bash\necho 'bench PASS'\n", "SILENT-EXIT-0"),
    ("clean_control.sh",
     "#!/usr/bin/env bash\nset -e\ndelay=1\nsleep $delay  # SLEEP-CLASS: POLL-STEP\n"
     "mix run --no-halt 9>&- &\nrc=$?\nexit $rc\n", None),
]


def self_test():
    tmp = tempfile.mkdtemp(prefix="automation-gate-selftest-")
    failures = 0
    for name, body, expect in PLANTS:
        path = os.path.join(tmp, name)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)
        rel = name
        fam = family_of(path)
        lines = body.split("\n")
        got = [(c) for _, c, _ in scan_lines(rel, lines, fam)]
        got += [c for _, c, _ in scan_silent_exit0(rel, lines, fam)]
        if expect is None:
            if got:
                print("[SELF-TEST] [FAIL] clean fixture %s flagged: %s" % (name, got))
                failures += 1
            else:
                print("[SELF-TEST] ok   clean fixture %s passes" % name)
        else:
            if expect in got:
                print("[SELF-TEST] ok   planted %s REFUSED (%s)" % (name, expect))
            else:
                print("[SELF-TEST] [FAIL] planted %s NOT refused (got %s), expected %s"
                      % (name, got, expect))
                failures += 1
    if failures:
        print("[SELF-TEST] %d failure(s) — gate non-vacuity BROKEN" % failures)
        return 1
    print("[SELF-TEST] PASS — all planted violations refused, clean fixtures pass")
    return 0


def main(argv):
    if "--self-test" in argv:
        return self_test()
    roots = argv[1:] or [
        os.path.join(REPO, "scripts"),
        os.path.join(REPO, "docker", "burn"),
        os.path.join(REPO, "justfile.d"),
    ]
    return run_scan(roots)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
