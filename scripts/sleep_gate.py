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

Exit 0 = pass, 1 = violations (or fail-closed: no files scanned, unreadable
file). Stdlib only. Companion docs/NO_SLEEP_DOCTRINE.md.

Non-vacuity: scripts/shim_court/sleep_gate_court.sh proves a clean file
PASSES and a sleep-injected file is REFUSED (BEFORE/AFTER flip under the
shim-court protocol).
"""

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Audited poll implementations: the sleep lives inside one bounded poll
# loop, owned and reviewed. Growth of this list is a reviewed diff.
AUDITED_POLL_FILES = {
    os.path.normpath(os.path.join("test", "support", "assert_eventually.ex")),
}

# Function-name allowlist: per-suite bounded poll / retry helpers whose
# sleep is a poll STEP (bounded by the loop's deadline/attempt count), per
# the v26.10.18 census (rewrite-drafts/sleeps.md class C retry-loop idiom).
AUDITED_POLL_FNS = {
    "sweep_until_terminal",
    "poll_until_succeeded",
    "poll_until_terminal",
    "poll_until",
    "poll_loop",
    "do_poll",
    "resilient_clear",
    "resilient_delete",
    "wait_until",
    "wait_gone",
    "wait_for_gone",
    "wait_for_fresh_window",
    "wait_listener",
    "wait_for_ephemeral_port",
    "connect_with_heal",
    "retry_5xx",
    "boot_with_retry",
    "typed_start",
    "await_dead",
    "consume",
    "port_verdict_agrees?",
    "evict_until",
    "sweep_until",
    "wait_until_gone",
    "wait_twin",
    "wait_terminal",
    "wait_store_tables",
    "do_ensure_store_up",
    "ensure_store_up",
    "collect_traced_calls",
    "collect_publish_ops",
    "do_snapshot",
    "do_resilient_clear",
    "do_clear",
    "wait_connect",
    "wait_for_new_store",
}

# Lawful lib/ classes (census-audited vocabulary). Anything else fails.
LIB_CLASSES = {
    "SCHEDULING",
    "POLL-STEP",
    "SIGNALABLE-PENDING-REDESIGN",
    "SIGNALABLE",  # legacy short form, census table value
    "CONTRACT",
}

SLEEP_RE = re.compile(r"\bProcess\.sleep\b")
ANN_RE = re.compile(r"#\s*SLEEP-CLASS:\s*([A-Za-z-]+)")
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
        if doc[i] or not SLEEP_RE.search(strip_comment(line)):
            continue

        # :infinity park (process fixture) — allowed both sides.
        if re.search(r"Process\.sleep\(\s*:?infinity\s*\)", line):
            continue

        if is_test:
            fn = enclosing_function(lines, i - 1)
            if os.path.normpath(rel) in AUDITED_POLL_FILES:
                continue
            if fn in AUDITED_POLL_FNS:
                continue
            cls = annotate_class(lines, i)
            if cls == "TIME-ADVANCE":
                continue
            where = fn or "<module body>"
            violations.append(
                (
                    rel,
                    i + 1,
                    "unclassified test Process.sleep in %s (audited-poll "
                    "allowlist or # SLEEP-CLASS: TIME-ADVANCE required)" % where,
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
                    "unclassified lib Process.sleep (# SLEEP-CLASS: "
                    "<SCHEDULING|POLL-STEP|SIGNALABLE-PENDING-REDESIGN|CONTRACT> "
                    "required)",
                )
            )
        else:
            # Outside lib/ and test/ (scripts/, workspace/ ...): not in the
            # gate's jurisdiction; skipped by path filter below.
            pass

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
    paths = paths or [os.path.join(REPO, "lib"), os.path.join(REPO, "test")]
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
        print("[SLEEP-GATE] [FAIL] no .ex/.exs files scanned — fail-closed")
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

    print("[SLEEP-GATE] PASS — %d files, 0 unclassified Process.sleep" % files_scanned)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
