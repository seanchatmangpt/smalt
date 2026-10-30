#!/usr/bin/env python3
"""GAP-17 must-not-migrate tripwire gate (fail-closed, stdlib only).

Normative source: docs/jira/posh/v26.10.31/gaps/17-what-must-not-migrate.md
(the Forbidden List). Tripwires wired this lane: T2 (F2 settlement-authority
leak), the smalt-side inverse of T2b (F1 GraphLaw admission migration), and
the F2b byte-identity pin on the sanctioned BLAKE3 kernel.

Fails closed: exit 0 only when (a) the live tree is clean AND (b) --self-check
proves every detector refuses a real injected violation on a /tmp scratch copy
(repo files are NEVER mutated; the falsifier is the non-vacuity proof).
Exit codes: 0 pass / 1 violation or vacuous self-check / 2 usage / 3 loud skip
(a sanctioned subject is missing from the tree — nothing to gate).

Tripwire coverage (normative table, gap doc §Accretion tripwires):
- T1  store/ledger imports + un-pinned schema-like reads in posh Go
- T2  posh-side settlement verbs (wired 2026-10-30)
- T3  persisted settlement/ledger/state files written from posh
      (the arm_gateway delegation clause of T3 is realized by the F2
      non-delegating-owner detector; see gap doc status note)
- T4  NOT MECHANICAL YET: subject apps/web/test/harness does not exist
      in this tree (harness lives in workspace/scripts/e2e-court.mjs and
      asserts smalt plane ports already); a detector over an absent subject
      is vacuous by construction. Recorded here and in the gap doc.
- T5  posh-side projection identity (posh Go writing .go sources)
"""

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# --- F1: GraphLaw admission + ontology ttl (lib/smalt/graphlaw_ex/,
#     lib/smalt/affidavit/, priv/ontologies/ are the sanctioned homes).
F1_SANCTIONED = (
    "lib/smalt/graphlaw_ex/",
    "lib/smalt/graphlaw/",
    "lib/smalt/affidavit/",
    "priv/ontologies/",
)
# A defmodule carrying the GraphLaw admission namespace outside the sanctioned
# homes is a migration of admission logic (charter law 2: dialects do not admit).
F1_DEFMODULE_RE = re.compile(r"defmodule\s+[A-Za-z0-9._]*GraphLaw")

# --- F2: turnstile / settlement / event-log logic (lib/smalt/posh/ is the
#     sanctioned seam) must not appear in lib/smalt/arm_gateway/ or in the
#     posh Go packages.
F2_ELIXIR_SCAN_ROOTS = ("lib/smalt/arm_gateway/",)
F2_SANCTIONED = ("lib/smalt/posh/",)
F2_TOKENS = ("Turnstile", "Settlement", "EventLog")
# posh-side settlement verbs on the receipt seam (deciding, not computing).
F2_GO_SCAN_ROOTS = ("posh/",)
F2_GO_VERB_RE = re.compile(r"\b(settle|Settle)[A-Za-z]*\s*\(")

# --- F2b: the one allowed exception, pinned byte-identical.
F2B_SUBJECT = "posh/internal/receipt/blake3.go"
# sha256 of posh/internal/receipt/blake3.go, pinned 2026-10-30 this lane
# (`shasum -a 256` over the file read at pin time; gaps/06 inheritance clause
# requires byte-identity with the Elixir lane's receipt kernel).
F2B_SHA256 = "5f2e394491a1504421cdf4607a5ca6fcc71425cdfceba343a2b6d58e2e7b9641"

# --- T1: store/ledger imports in posh Go (state ownership, F3/F4 class).
#     Detected on import statements only (import block or single import) so
#     prose/comments naming SQLite et al. do not false-positive.
T1_STORE_IMPORT_RE = re.compile(
    r'"[^"]*(database/sql|sqlite3?|boltdb|bbolt|badger|leveldb|pebble)[^"]*"')
# T1 second clause: os.ReadFile/embed of a schema-like source (Turtle
# ontology — the graph IS the admission allowlist, F4) with no adjacent
# sha256 pin anywhere in the file (pinned reads are verification, not
# ownership).
T1_SCHEMA_READ_RE = re.compile(
    r'(?:os\.ReadFile|[^A-Za-z0-9_]embed)\s*\(?[^)\n]*"\.?[A-Za-z0-9_./-]*\.ttl"')
T1_PIN_RE = re.compile(r"[0-9a-f]{64}")

# --- T3: persisted settlement/ledger/state files written from posh Go.
#     A posh component that persists settlement/event/state it can read back
#     owns a ledger (accretion clause 2). String-literal paths only.
T3_WRITE_RE = re.compile(r"os\.(WriteFile|OpenFile|Create)\s*\(")
T3_LEDGER_PATH_RE = re.compile(
    r'"[^"]*(ledger|settlement|eventlog|event_log|state\.db|\.db|\.sqlite)'
    r'[^"]*"')

# --- T5: a posh-side projection identity (posh Go writing .go sources) —
#     a second generator without a generator-plurality court (C20, F6).
T5_WRITE_RE = re.compile(r"os\.(WriteFile|OpenFile|Create)\s*\(")
T5_GO_PATH_RE = re.compile(r'"[^"]*\.go"')


def _elixir_files(root):
    # lib/ only: test/, docs/, tmp/ cite GraphLaw names by reference and are
    # not admission logic; the gate's subject is the shipped surface.
    lib = os.path.join(root, "lib")
    if not os.path.isdir(lib):
        return
    for dirpath, _dirnames, filenames in os.walk(lib):
        for fn in filenames:
            if fn.endswith(".ex") or fn.endswith(".exs"):
                yield os.path.join(dirpath, fn)


def scan(root):
    """Return a list of violation strings for the tree at `root`."""
    violations = []
    for rel in _elixir_files(root):
        rel_posix = os.path.relpath(rel, root).replace(os.sep, "/")
        if any(rel_posix.startswith(p) for p in F1_SANCTIONED + F2_SANCTIONED):
            continue
        try:
            text = open(rel, encoding="utf-8", errors="replace").read()
        except OSError as e:
            violations.append(f"F1/F2 unreadable {rel_posix}: {e}")
            continue
        if F1_DEFMODULE_RE.search(text):
            violations.append(
                f"F1 GraphLaw admission module outside sanctioned homes "
                f"(lib/smalt/graphlaw_ex/, lib/smalt/affidavit/, "
                f"priv/ontologies/): {rel_posix}")
        if any(rel_posix.startswith(p) for p in F2_ELIXIR_SCAN_ROOTS):
            # The sanctioned seam is the arm_gateway plug/router DELEGATING
            # to Smalt.Posh (receipt_turnstile.ex calls
            # Smalt.Posh.Egress.Settlement/EventLog). Two migrations:
            # (a) a module owning turnstile/settlement/event-log logic that
            #     does not delegate to Smalt.Posh;
            # (b) a defmodule claiming the Smalt.Posh.* namespace outside
            #     lib/smalt/posh/ — a verbatim copy that would smuggle past
            #     the delegation clause on its own namespace.
            f2_defmodule_re = re.compile(
                r"defmodule\s+[A-Za-z0-9._]*(" + "|".join(F2_TOKENS) + ")")
            owns_logic = bool(f2_defmodule_re.search(text))
            posh_ns = bool(re.search(r"defmodule\s+Smalt\.Posh\.", text))
            delegates = "Smalt.Posh" in text
            if (owns_logic and not delegates) or posh_ns:
                violations.append(
                    f"F2 turnstile/settlement/event-log logic in arm_gateway "
                    f"(owns-logic={owns_logic}, non-delegating="
                    f"{not delegates}, posh-namespace-claim={posh_ns}; "
                    f"sanctioned seam is lib/smalt/posh/): {rel_posix}")
    # F2 posh-side settlement verbs in Go sources (decide-not-compute),
    # plus the T1/T3/T5 posh-Go detectors (same walk).
    for dirpath, _dirnames, filenames in os.walk(os.path.join(root, "posh")):
        for fn in filenames:
            if not fn.endswith(".go"):
                continue
            full = os.path.join(dirpath, fn)
            rel_posix = os.path.relpath(full, root).replace(os.sep, "/")
            try:
                text = open(full, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for line_no, line in enumerate(text.splitlines(), 1):
                if F2_GO_VERB_RE.search(line):
                    violations.append(
                        f"F2 settlement verb in posh Go code "
                        f"({rel_posix}:{line_no}): {line.strip()[:100]}")
                    break
            # T1 clause a: store/ledger import lines.
            for line_no, line in enumerate(text.splitlines(), 1):
                if T1_STORE_IMPORT_RE.search(line):
                    violations.append(
                        f"T1 store/ledger import in posh Go (state "
                        f"ownership, F3/F4 class) ({rel_posix}:{line_no}): "
                        f"{line.strip()[:100]}")
                    break
            # T1 clause b: schema-like (Turtle) reads without a sha256 pin.
            if (T1_SCHEMA_READ_RE.search(text)
                    and not T1_PIN_RE.search(text)):
                violations.append(
                    f"T1 schema-like (.ttl) read without sha256 pin in posh "
                    f"Go ({rel_posix}): the graph is the admission "
                    f"allowlist (F4)")
            # T3/T5: write calls with persisted-ledger / .go paths.
            for line_no, line in enumerate(text.splitlines(), 1):
                if T3_WRITE_RE.search(line):
                    if T3_LEDGER_PATH_RE.search(line):
                        violations.append(
                            f"T3 persisted ledger/settlement/state write in "
                            f"posh Go ({rel_posix}:{line_no}): "
                            f"{line.strip()[:100]}")
                    if T5_GO_PATH_RE.search(line):
                        violations.append(
                            f"T5 posh-side projection write (.go) in posh "
                            f"Go ({rel_posix}:{line_no}): "
                            f"{line.strip()[:100]}")
    # F2b byte-identity pin.
    subject = os.path.join(root, F2B_SUBJECT)
    if not os.path.isfile(subject):
        violations.append(f"F2b pinned kernel missing: {F2B_SUBJECT}")
    else:
        digest = hashlib.sha256(open(subject, "rb").read()).hexdigest()
        if digest != F2B_SHA256:
            violations.append(
                f"F2b BLAKE3 kernel drifted from pinned digest "
                f"(pinned 2026-10-30, gaps/06 inheritance clause): "
                f"{F2B_SUBJECT} sha256={digest} expected={F2B_SHA256}")
    return violations


def _required_subjects(root):
    missing = [p for p in ("lib/smalt/graphlaw_ex/", "lib/smalt/posh/",
                           F2B_SUBJECT) if not os.path.exists(os.path.join(root, p))]
    return missing


def self_check():
    """Shim-court-style non-vacuity proof on /tmp scratch copies only.

    Inject one violation per family (F1, F2, F2b); every detector must refuse
    naming the family; the clean scratch tree must pass. Repo is never mutated.
    """
    tmp = tempfile.mkdtemp(prefix="must-not-migrate-selfcheck-")
    try:
        root = os.path.join(tmp, "tree")
        # Minimal sanctioned skeleton the gate requires to be non-skip.
        for d in ("lib/smalt/graphlaw_ex", "lib/smalt/affidavit",
                  "lib/smalt/arm_gateway", "lib/smalt/posh",
                  "priv/ontologies", os.path.dirname(F2B_SUBJECT)):
            os.makedirs(os.path.join(root, d), exist_ok=True)
        with open(os.path.join(root, F2B_SUBJECT), "wb") as f:
            f.write(open(os.path.join(REPO, F2B_SUBJECT), "rb").read())
        with open(os.path.join(root, "lib/smalt/graphlaw_ex",
                               "admission_gate.ex"), "w") as f:
            f.write("defmodule Smalt.GraphLawEx.AdmissionGate do\nend\n")
        with open(os.path.join(root, "lib/smalt/posh", "turnstile.ex"),
                  "w") as f:
            f.write("defmodule Smalt.Posh.Turnstile do\nend\n")

        clean = scan(root)
        if clean:
            print(f"FAIL must-not-migrate/self-check: clean scratch tree "
                  f"flagged {clean}")
            return False

        # F1 mutation: GraphLaw admission module outside sanctioned homes.
        p = os.path.join(root, "lib/smalt/arm_gateway", "graphlaw_admission.ex")
        with open(p, "w") as f:
            f.write("defmodule Smalt.GraphLaw.Admission do\nend\n")
        v = scan(root)
        if not any(x.startswith("F1 ") for x in v):
            print(f"FAIL must-not-migrate/self-check: F1 mutation ACCEPTED — "
                  f"VACUOUS GATE (violations: {v})")
            return False
        os.unlink(p)

        # F2 mutation A: verbatim copy of the posh turnstile into
        # arm_gateway (escapes the delegation clause via its namespace —
        # caught by the posh-namespace-claim clause).
        shutil.copy(os.path.join(root, "lib/smalt/posh", "turnstile.ex"),
                    os.path.join(root, "lib/smalt/arm_gateway",
                                 "turnstile_copy.ex"))
        # F2 mutation B: a non-delegating settlement owner.
        with open(os.path.join(root, "lib/smalt/arm_gateway",
                               "settlement_local.ex"), "w") as f:
            f.write("defmodule Smalt.ArmGateway.Settlement do\n"
                    "  def digest(op, ts, body), do: :ok\nend\n")
        v = scan(root)
        if not any(x.startswith("F2 ") for x in v):
            print(f"FAIL must-not-migrate/self-check: F2 mutation ACCEPTED — "
                  f"VACUOUS GATE (violations: {v})")
            return False
        os.unlink(os.path.join(root, "lib/smalt/arm_gateway",
                               "turnstile_copy.ex"))
        os.unlink(os.path.join(root, "lib/smalt/arm_gateway",
                               "settlement_local.ex"))

        # F2b mutation: one-byte drift of the pinned kernel.
        subj = os.path.join(root, F2B_SUBJECT)
        data = open(subj, "rb").read() + b"\n"
        open(subj, "wb").write(data)
        v = scan(root)
        if not any(x.startswith("F2b ") for x in v):
            print(f"FAIL must-not-migrate/self-check: F2b drift ACCEPTED — "
                  f"VACUOUS GATE (violations: {v})")
            return False
        os.unlink(subj)
        with open(subj, "wb") as f:
            f.write(open(os.path.join(REPO, F2B_SUBJECT), "rb").read())

        # T1 mutation a: store/ledger import (state ownership).
        p = os.path.join(root, "posh/internal/fake", "state.go")
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write('package fake\n\nimport (\n\t"net/http"\n\n'
                    '\t"github.com/boltdb/bolt"\n)\n\n'
                    "var _ = http.StatusOK\n\nfunc open() error {\n"
                    "\t_, err := bolt.Open(\"x.db\", 0o600, nil)\n"
                    "\treturn err\n}\n")
        v = scan(root)
        if not any(x.startswith("T1 ") for x in v):
            print(f"FAIL must-not-migrate/self-check: T1 store-import "
                  f"mutation ACCEPTED — VACUOUS GATE (violations: {v})")
            return False
        os.unlink(p)

        # T1 mutation b: un-pinned schema read.
        with open(p, "w") as f:
            f.write('package fake\n\nimport "os"\n\n'
                    'func load() ([]byte, error) {\n'
                    '\treturn os.ReadFile("ontologies/All.ttl")\n}\n')
        v = scan(root)
        if not any(x.startswith("T1 ") for x in v):
            print(f"FAIL must-not-migrate/self-check: T1 schema-read "
                  f"mutation ACCEPTED — VACUOUS GATE (violations: {v})")
            return False
        os.unlink(p)

        # T3 mutation: persisted settlement/ledger state.
        with open(p, "w") as f:
            f.write('package fake\n\nimport "os"\n\n'
                    'func settle(op string) error {\n'
                    '\treturn os.WriteFile("ledger/settlement.jsonl", '
                    "[]byte(op), 0o600)\n}\n")
        v = scan(root)
        if not any(x.startswith("T3 ") for x in v):
            print(f"FAIL must-not-migrate/self-check: T3 ledger-write "
                  f"mutation ACCEPTED — VACUOUS GATE (violations: {v})")
            return False
        os.unlink(p)

        # T5 mutation: posh-side projection identity (writing .go).
        with open(p, "w") as f:
            f.write('package fake\n\nimport "os"\n\n'
                    "func project(src []byte) error {\n"
                    '\treturn os.WriteFile("gen/adapter.go", src, 0o644)\n'
                    "}\n")
        v = scan(root)
        if not any(x.startswith("T5 ") for x in v):
            print(f"FAIL must-not-migrate/self-check: T5 projection-write "
                  f"mutation ACCEPTED — VACUOUS GATE (violations: {v})")
            return False
        os.unlink(p)

        # Restore-prove: after removing every mutation the tree is clean
        # again (the court flips red, then back to green).
        v = scan(root)
        if v:
            print(f"FAIL must-not-migrate/self-check: restored scratch tree "
                  f"still flagged {v}")
            return False
        print("PASS must-not-migrate/self-check: F1, F2, F2b, T1(a,b), T3, "
              "T5 mutations all REFUSED on scratch copies; clean tree passes "
              "and restored tree is clean")
        return True
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", default=REPO,
                    help="tree root to scan (default: this repo)")
    ap.add_argument("--self-check-only", action="store_true",
                    help="run only the non-vacuity self-check")
    ap.add_argument("--skip-self-check", action="store_true",
                    help="scan only (self-check runs by default; skipping it "
                         "is for local iteration, never for a gate verdict)")
    args = ap.parse_args(argv)
    root = os.path.abspath(args.root)

    if args.self_check_only:
        return 0 if self_check() else 1

    missing = _required_subjects(root)
    if missing:
        print(f"[SKIP] must-not-migrate: sanctioned subjects absent under "
              f"{root}: {missing} — nothing to gate (loud skip, not a pass "
              f"for a different tree)")
        return 3

    violations = scan(root)
    for v in violations:
        print(f"VIOLATION {v}")
    if violations:
        print(f"FAIL must-not-migrate: {len(violations)} violation(s) under "
              f"{root} (normative list: docs/jira/posh/v26.10.31/gaps/"
              f"17-what-must-not-migrate.md)")
        return 1

    print(f"PASS must-not-migrate/scan: tree clean ({root})")
    if args.skip_self_check:
        print("NOTE self-check skipped (--skip-self-check); verdict is scan-only")
        return 0
    return 0 if self_check() else 1


if __name__ == "__main__":
    sys.exit(main())
