#!/usr/bin/env python3
"""sleep_gate.py — NO-SLEEP-DOCTRINE Law 3 enforcement (fail-closed).

Scans lib/ and test/ for Process.sleep sites and enforces:

  test/  — every Process.sleep FAILS unless:
             (a) it lives inside an AUDITED poll implementation
                 (test/support/assert_eventually.ex, or a function in the
                 reviewed AUDITED_POLL_FNS allowlist), or
             (b) it is a `Process.sleep(:infinity)` park (process fixture),
                 or
             (c) it carries an adjacent `# SLEEP-CLASS: TIME-ADVANCE`
                 annotation (the B1 inherent-time-advance class:
                 the sleep crosses a real time window — rate-limit second
                 boundary, lock expiry, LRO retention — and no observable
                 can be polled because the condition under test is time
                 itself).

  lib/   — every Process.sleep FAILS unless it carries an adjacent
           `# SLEEP-CLASS: <CLASS>` annotation where CLASS is in the
           audited census vocabulary (SCHEDULING | POLL-STEP |
           SIGNALABLE-PENDING-REDESIGN | CONTRACT). Annotation removal
           re-fails the site; annotation growth is a reviewed diff.

AZB-21 (v26.10.18) scope extensions:
  docker/burn/*.sh — `sleep [0-9]` FAILS (burn scripts must delay via their
    own pacing mechanisms, never a literal shell sleep).
  :timer.sleep — treated identically to Process.sleep (lib + test).
  `after <integer> ->` on a single line — flagged as a delay primitive
    unless annotated (deadline receives that pair `after` with a matched
    message across multiple lines are not lexically delays; the same-line
    form is the delay idiom this gate targets). Escape hatch: same
    SLEEP-CLASS annotation.
  String-literal exemption — a match that lies inside a double-quoted
    string on the line is a fence fixture (a no-sleep assertion quoting
    the primitive), not a call site; skipped.
  Allowlist lives in a typed classification file,
    scripts/sleep_gate_classes.json ({files: [{path, reason}],
    functions: [{name, reason}]}), fail-closed if missing/unreadable.

Exit 0 = pass, 1 = violations (or fail-closed: no files scanned, unreadable
file). Stdlib only. Companion docs/NO_SLEEP_DOCTRINE.md.

Non-vacuity: scripts/shim_court/sleep_gate_court.sh proves a clean file
PASSES and a sleep-injected file is REFUSED (BEFORE/AFTER flip under the
shim-court protocol).
"""

import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Typed classification file (AZB-21): the ONLY allowlist. Loaded at start,
# fail-closed if missing/unreadable/malformed.
CLASSES_PATH = os.path.join(REPO, "scripts", "sleep_gate_classes.json")


def load_classes():
    try:
        with open(CLASSES_PATH, encoding="utf-8") as f:
            data = json.load(f)
        files = {os.path.normpath(e["path"]): e.get("reason", "") for e in data["files"]}
        fns = {e["name"]: e.get("reason", "") for e in data["functions"]}
        return files, fns
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print("[SLEEP-GATE] [FAIL] classification file unreadable: %s" % exc)
        sys.exit(1)


# Audited poll implementations: the sleep lives inside one bounded poll
# loop, owned and reviewed. Growth of this list is a reviewed diff.
AUDITED_POLL_FILES, AUDITED_POLL_FNS = load_classes()

# Function-name allowlist: per-suite bounded poll / retry helpers whose
# sleep is a poll STEP (bounded by the loop's deadline/attempt count), per
# the v26.10.18 census (rewrite-drafts/sleeps.md class C retry-loop idiom).
# (Moved to scripts/sleep_gate_classes.json — AZB-21 typed classification.)

# Lawful lib/ classes (census-audited vocabulary). Anything else fails.
LIB_CLASSES = {
    "SCHEDULING",
    "POLL-STEP",
    "SIGNALABLE-PENDING-REDESIGN",
    "SIGNALABLE",  # legacy short form, census table value
    "CONTRACT",
}

SLEEP_RE = re.compile(r"\b(?:Process|:timer)\.sleep\b")
ANN_RE = re.compile(r"#\s*SLEEP-CLASS:\s*([A-Za-z-]+)")
RECV_AFTER_RE = re.compile(r"\bafter\s+\d[\d_]*\s*->")
SH_SLEEP_RE = re.compile(r"\bsleep [0-9]")
DEF_RE = re.compile(r"^\s*def(p?)\s+([a-z_][a-zA-Z0-9_?!]*)")
TEST_RE = re.compile(r'^\s*(test|property|describe)\s+"')

EX_RE = re.compile(r"\.(ex|exs)$")


def strip_comment(line):
    """Cut the line at the first # that starts a comment (no Elixir string
    semantics needed for this tree's sleep sites; approximate but only ever
    skips, never invents, sites)."""
    idx = line.find("#")
    return line if idx == -1 else line[:idx]


def enclosing_function(lines, idx):
    """Walk backwards from line idx for the nearest defp/def name, or a
    test/property block (reported as <test body>)."""
    for j in range(idx, -1, -1):
        m = DEF_RE.match(lines[j])
        if m:
            return m.group(2)
        if TEST_RE.match(lines[j]):
            return "<test body>"
    return None


def annotate_class(lines, idx):
    """Adjacent annotation = same line or the immediately-preceding
    comment/annotation block directly above (contiguous SLEEP-CLASS block
    ending on the line above the sleep). Returns class token or None."""
    m = ANN_RE.search(lines[idx])
    if m:
        return m.group(1)
    # walk up over the contiguous comment block ending on idx-1
    j = idx - 1
    found = None
    while j >= 0 and lines[j].lstrip().startswith("#"):
        mm = ANN_RE.search(lines[j])
        if mm:
            found = mm.group(1)
            if found:
                break
        j -= 1
    return found


def in_string_literal(line, start, end):
    """True if the span [start:end) lies inside a double-quoted string on
    this line (single-quote/double-quote toggle scan; only ever skips
    fence fixtures, never skips real call sites — a real Process.sleep
    call is never syntactically inside a string)."""
    quote = None
    i = 0
    while i < len(line):
        c = line[i]
        if quote is None:
            if c == '"':
                quote = '"'
        elif c == '"' and line[i - 1] != "\\":
            if start >= i:
                return True
            quote = None
        if quote is not None and start >= i:
            return True
        i += 1
    return False


def scan_file(path, rel):
    violations = []
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().split("\n")
    except OSError as exc:
        violations.append((rel, 0, "FAIL-CLOSED: unreadable file: %s" % exc))
        return violations

    # Skip sites inside triple-quoted docstrings (@doc/@moduledoc mention
    # `Process.sleep` prose, e.g. wasm_engine's redesign note). Toggle on
    # lines containing \"\"\" (parity per file; this tree's style puts the
    # delimiters on their own lines).
    in_doc = False
    doc = [False] * len(lines)
    for i, line in enumerate(lines):
        n = line.count('"""')
        if in_doc:
            doc[i] = True
            if n % 2 == 1:
                in_doc = False
        elif n >= 1:
            doc[i] = True
            in_doc = n % 2 == 1

    is_lib = rel == "lib" or rel.startswith("lib/")
    is_test = rel == "test" or rel.startswith("test/")

    for i, line in enumerate(lines):
        if doc[i]:
            continue

        raw = strip_comment(line)

        # :infinity park (process fixture) — allowed both sides.
        if re.search(r"(?:Process|:timer)\.sleep\(\s*:?infinity\s*\)", raw):
            continue

        sleep_hits = [
            m
            for m in SLEEP_RE.finditer(raw)
            if not in_string_literal(raw, m.start(), m.end())
        ]

        # Same-line `after <integer> ->` delay primitive (AZB-21).
        after_hit = RECV_AFTER_RE.search(raw)

        if not sleep_hits and not after_hit:
            continue

        if is_test:
            fn = enclosing_function(lines, i - 1)
            if os.path.normpath(rel) in AUDITED_POLL_FILES:
                continue
            if fn in AUDITED_POLL_FNS:
                continue
            cls = annotate_class(lines, i)
            if cls in TEST_CLASSES:
                continue
            where = fn or "<module body>"
            violations.append(
                (
                    rel,
                    i + 1,
                    "unclassified test sleep primitive in %s (audited-poll "
                    "allowlist or # SLEEP-CLASS: <TIME-ADVANCE|POLL-STEP> "
                    "required): `%s`" % (where, raw.strip()),
                )
            )
        elif is_lib:
            cls = annotate_class(lines, i)
            if cls in LIB_CLASSES:
                continue
            violations.append(
                (
                    rel,
                    i + 1,
                    "unclassified lib sleep primitive (# SLEEP-CLASS: "
                    "<SCHEDULING|POLL-STEP|SIGNALABLE-PENDING-REDESIGN|CONTRACT> "
                    "required): `%s`" % raw.strip(),
                )
            )
        else:
            # Outside lib/ and test/ (scripts/, workspace/ ...): not in the
            # gate's jurisdiction; skipped by path filter below.
            pass

    return violations


# Lawful test-side annotation classes (AZB-21): TIME-ADVANCE (the sleep
# crosses a real time window — rate-limit boundary, lock expiry, LRO
# retention, teardown/propagation settle) or POLL-STEP (the sleep is one
# bounded step inside a poll/retry loop with a numeric attempt/deadline
# bound).
TEST_CLASSES = {"TIME-ADVANCE", "POLL-STEP"}


def scan_sh_file(path, rel):
    """docker/burn/*.sh: any literal `sleep [0-9]` is a violation. Shell
    comments (# ...) stripped. No annotation escape: burn scripts delay
    via their own pacing (loops/poll), never a literal sleep."""
    violations = []
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().split("\n")
    except OSError as exc:
        return [(rel, 0, "FAIL-CLOSED: unreadable burn script: %s" % exc)]
    for i, line in enumerate(lines):
        raw = line.split("#", 1)[0]
        if SH_SLEEP_RE.search(raw):
            violations.append(
                (rel, i + 1, "unclassified burn-script `sleep N` (literal shell "
                 "sleep banned in docker/burn/; see docs/NO_SLEEP_DOCTRINE.md): "
                 "`%s`" % raw.strip())
            )
    return violations


def main(argv):
    force_as = None
    paths = []
    for a in argv[1:]:
        if a == "--as=test":
            force_as = "test"
        elif a == "--as=lib":
            force_as = "lib"
        elif a.startswith("--as="):
            print("[SLEEP-GATE] [FAIL] unknown --as value: %s" % a)
            return 1
        else:
            paths.append(a)
    # Default scan target set (AZB-21: burn scripts in scope).
    paths = paths or [
        os.path.join(REPO, "lib"),
        os.path.join(REPO, "test"),
        os.path.join(REPO, "docker", "burn"),
    ]
    violations = []
    files_scanned = 0

    def walk(p):
        if os.path.isfile(p):
            yield p
        elif os.path.isdir(p):
            for root, dirs, names in os.walk(p):
                dirs[:] = [d for d in dirs if d not in (".git", "node_modules", "_build", "deps")]
                for n in sorted(names):
                    yield os.path.join(root, n)

    for p in paths:
        if not os.path.exists(p):
            print("[SLEEP-GATE] [FAIL] path not found: %s" % p)
            return 1
        for f in walk(p):
            if f.endswith(".sh"):
                rel = os.path.relpath(os.path.abspath(f), REPO)
                if rel.startswith("docker" + os.sep + "burn" + os.sep):
                    violations.extend(scan_sh_file(f, rel))
                    files_scanned += 1
                continue
            if not EX_RE.search(f):
                continue
            rel = os.path.relpath(os.path.abspath(f), REPO)
            if rel.startswith(".." + os.sep):
                # outside the repo tree: only legal with an explicit class
                if force_as is None:
                    print(
                        "[SLEEP-GATE] [FAIL] %s is outside the repo; pass "
                        "--as=test or --as=lib to classify it" % f
                    )
                    return 1
                rel = os.path.join(force_as, os.path.basename(f))
            files_scanned += 1
            violations.extend(scan_file(f, rel))

    if files_scanned == 0:
        print("[SLEEP-GATE] [FAIL] no .ex/.exs/.sh files scanned — fail-closed")
        return 1

    if violations:
        print("[SLEEP-GATE] %d violation(s) across %d files — REFUSED" % (len(violations), files_scanned))
        for rel, ln, why in violations:
            print("  [FAIL] %s:%d %s" % (rel, ln, why))
        print(
            "[SLEEP-GATE] lawful forms: bounded poll inside an audited "
            "implementation, or # SLEEP-CLASS: TIME-ADVANCE (test) / census "
            "class (lib). See docs/NO_SLEEP_DOCTRINE.md"
        )
        return 1

    print("[SLEEP-GATE] PASS — %d files, 0 unclassified sleep primitives" % files_scanned)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
