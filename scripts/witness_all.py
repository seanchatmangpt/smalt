#!/usr/bin/env python3
"""witness_all — fail-closed receipt re-witness gate (BK-8 / BK-44).

Walks the receipt windows (PINNED by name: v26.10.20 + v26.10.22; overridable
via WITNESS_RECEIPTS_DIRS=os.pathsep list) and, for each
receipt:
  1. requires an explicit standing line (`Standing:`) — missing => FAIL.
  2. extracts candidate rerunnable commands from fenced/indented blocks.
  3. safe classes are RE-RUN for real (per-lane MIX_BUILD_ROOT) and the exit
     status is compared against the receipt's recorded standing (PASS expected).
  4. anything else is a loud `[WITNESS-STALE]` line with a typed reason —
     never a silent skip.

Exit 1 if any re-run fails or any receipt lacks both a runnable command and
an explicit standing line. `--dry-run` lists the disposition without running.

Safe-to-rerun classes (whitelist, fail-closed):
  A. `mix test test/...` (file-scoped, incl. `asdf exec mix test ...`) —
     re-run with MIX_BUILD_ROOT=_build-witness
  A2. backslash-newline continuations are joined before classification
  B. `just <recipe>` where <recipe> is in SAFE_RECIPES (cheap/read-only gates)
  C. `python3 scripts/...` verification scripts (kd_flip read-only, gates with --check)
  D. `grep`/`jq`/`cat` read-only verification of existing files
  E. cargo test under the graphlaw checkout (GRAPHLAW_ROOT; default ../graphlaw)

Everything else (curl/substrate/bench/mix run/destructive) => WITNESS-STALE.
"""

import argparse
import glob
import os
import re
import shlex
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from receipt_index import STANDING_LINE_RE, standing_field_value, STANDING_TOKENS  # noqa: E402  (BK-WPARSE: one canonical standing contract)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Receipt windows: PINNED BY NAME (BK-WIT4-1) — dir mtime is not scope
# authority (lane activity on an old window's RECEIPTS.md bumped v26.10.14's
# mtime above v26.10.20's, silently sweeping 128 pre-standing-law receipts in
# as NO-STANDING, totals 431 → 515). The standing contract covers the current
# window + the v26.10.20 exemplar (BK-WPARSE contract). Override with
# WITNESS_RECEIPTS_DIRS (os.pathsep-separated absolute paths) — the explicit
# env wins outright.
PINNED_WINDOWS = ("v26.10.20", "v26.10.22")


def discover_receipts_dirs():
    env = os.environ.get("WITNESS_RECEIPTS_DIRS")
    if env:
        return [p for p in env.split(os.pathsep) if p]
    return [
        os.path.join(REPO, "docs/jira", w, "receipts")
        for w in PINNED_WINDOWS
        if os.path.isdir(os.path.join(REPO, "docs/jira", w, "receipts"))
    ]
BUILD_ROOT = "_build-witness"
# Default assumes the sibling canonical checkout; override with GRAPHLAW_ROOT.
GRAPHLAW = os.environ.get("GRAPHLAW_ROOT", os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "graphlaw")))

# just recipes cheap/read-only enough to re-run as witness evidence
SAFE_RECIPES = {
    "doctor", "status", "receipts", "logs",
    "docs-dod-check", "sleep-gate", "receipt-index",
    "invariant-gates",
}

# python scripts that are verification-only (read-only or --check-fenced)
SAFE_SCRIPTS = {
    "scripts/kd_flip.py",            # read-only without --apply
    "scripts/test_budget_gate.py",
    "scripts/naming_sweep.sh",
}

READONLY_PREFIXES = ("grep", "jq", "cat", "ls", "wc", "head", "tail", "sha256sum", "shasum")

CMD_RE = re.compile(r"^\s{0,4}\$\s+(.+)$")
FENCE_RE = re.compile(r"```[a-z]*\n(.*?)```", re.S)
# BK-WPARSE: STANDING_RE replaced by the canonical contract in
# receipt_index.py (STANDING_LINE_RE + standing_field_value). The old regex
# captured the markdown emphasis literally — `**Standing:** **ALIVE**`
# yielded `* **ALIVE** ...` whose split()[0] is `*` — and missed bullet- and
# heading-prefixed field lines, typing them NO-STANDING. The canonical
# contract strips emphasis and still requires a standing token (fail-closed,
# no vacuous widening: prose sentences mentioning standing never match).


def join_continuations(text):
    """Join backslash-newline line continuations so split commands classify."""
    return re.sub(r"\\\s*\n\s*", " ", text)


def extract_commands(text):
    """Candidate commands: from fenced blocks and `$ `-prefixed lines."""
    text = join_continuations(text)
    cmds = []

    def clean(s):
        s = s.strip()
        # strip trailing shell-style comment (but not ${...} or quotes)
        out = re.sub(r"\s+#(?!\{).*$", "", s)
        return out.strip()

    for block in FENCE_RE.findall(text):
        for line in block.splitlines():
            m = CMD_RE.match(line)
            if m:
                cmds.append(clean(m.group(1)))
            elif line.strip() and not line.startswith("#"):
                cmds.append(clean(line))
    for line in text.splitlines():
        m = CMD_RE.match(line)
        if m:
            cmds.append(clean(m.group(1)))
    # dedupe, keep order
    seen, out = set(), []
    for c in cmds:
        if c not in seen:
            seen.add(c)
            out.append(c)
    return out


def strip_env(cmd):
    """Return (env_dict, bare_cmd) for leading VAR=value tokens."""
    env = {}
    parts = cmd.split()
    i = 0
    while i < len(parts) and re.match(r"^[A-Z_][A-Z0-9_]*=", parts[i]):
        k, _, v = parts[i].partition("=")
        env[k] = v
        i += 1
    bare = parts[i:]
    # tool-manager wrappers are transparent: `asdf exec mix test ...` == `mix test ...`
    while len(bare) >= 2 and bare[0] in ("asdf", "mise", "rtx") and bare[1] == "exec":
        bare = bare[2:]
    return env, " ".join(bare)


def classify(cmd):
    """Return (class, payload) or (None, reason)."""
    _, bare = strip_env(cmd)
    try:
        parts = shlex.split(bare)
    except ValueError:
        return None, "unparseable command"
    if not parts:
        return None, "empty command"
    head = parts[0]
    if head == "mix" and parts[1:2] == ["test"]:
        files = [p for p in parts[2:] if p.endswith(".exs")]
        if files and all(os.path.exists(os.path.join(REPO, f)) for f in files):
            return "mix-test", files
        return None, "mix test with missing/non-file targets"
    if head == "just":
        if len(parts) >= 2 and parts[1] in SAFE_RECIPES:
            return "just", parts[1:]
        return None, "just recipe not in SAFE_RECIPES (%s)" % (parts[1] if len(parts) > 1 else "?")
    if head == "cargo" and parts[1:2] == ["test"]:
        if os.path.isdir(GRAPHLAW):
            return "cargo-test", None
        return None, "graphlaw checkout missing"
    if head == "python3" and len(parts) >= 2:
        script = parts[1]
        if any(script == s or script.endswith("/" + s) for s in SAFE_SCRIPTS):
            if "--apply" in parts or "--force" in parts:
                return None, "verification script invoked in mutating mode"
            if os.path.exists(os.path.join(REPO, script)):
                return "script", parts
            return None, "script missing: %s" % script
        return None, "python script not in SAFE_SCRIPTS"
    if head in READONLY_PREFIXES:
        # pipelines: every segment must itself be a readonly prefix, else refuse
        for seg in bare.split("|"):
            try:
                seg_parts = shlex.split(seg.strip())
            except ValueError:
                return None, "unparseable pipeline segment"
            if not seg_parts or seg_parts[0] not in READONLY_PREFIXES:
                return None, "pipeline segment outside readonly classes (%s)" % (seg_parts[0] if seg_parts else "?")
        return "readonly", bare
    return None, "outside safe classes (%s)" % head


def toolchain_env():
    """Prepend the asdf-pinned elixir/erlang (from .tool-versions) to PATH —
    homebrew elixir (1.19.5) shadows and fails the ~> 1.20 mix.exs gate."""
    env = dict(os.environ)
    try:
        pins = dict(
            l.split(None, 1)
            for l in open(os.path.join(REPO, ".tool-versions")).read().splitlines()
            if len(l.split(None, 1)) == 2
        )
        asdf = os.path.expanduser("~/.asdf/installs")
        extra = [
            os.path.join(asdf, "elixir", pins["elixir"], "bin"),
            os.path.join(asdf, "erlang", pins["erlang"], "bin"),
        ]
        env["PATH"] = os.pathsep.join(extra + [env.get("PATH", "")])
    except (OSError, KeyError):
        pass  # fall back to ambient PATH
    return env


def run_class(cls, payload):
    env = toolchain_env()
    env["MIX_BUILD_ROOT"] = BUILD_ROOT
    if cls == "mix-test":
        cmd = ["mix", "test"] + payload
        return subprocess.run(cmd, cwd=REPO, env=env, capture_output=True, text=True, timeout=900)
    if cls == "just":
        return subprocess.run(["just"] + payload, cwd=REPO, env=env, capture_output=True, text=True, timeout=600)
    if cls == "script":
        return subprocess.run(payload, cwd=REPO, env=env, capture_output=True, text=True, timeout=300)
    if cls == "cargo-test":
        return subprocess.run(["cargo", "test"], cwd=GRAPHLAW, capture_output=True, text=True, timeout=1200)
    if cls == "readonly":
        # payload is the classified-safe pipeline string; run under a shell
        return subprocess.run(payload, cwd=REPO, shell=True,
                              capture_output=True, text=True, timeout=60)
    raise AssertionError(cls)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--class-filter", default=None,
                    help="only exercise receipts whose chosen command is this class (e.g. mix-test)")
    ap.add_argument("--limit", type=int, default=0, help="cap re-runs (0 = no cap)")
    args = ap.parse_args()

    receipts_dirs = discover_receipts_dirs()
    print("[WITNESS-SCOPE] windows=%s" % " ".join(os.path.relpath(d, REPO) for d in receipts_dirs))
    paths = []
    for d in receipts_dirs:
        paths.extend(glob.glob(os.path.join(d, "*.md")))
    paths = sorted(p for p in paths if os.path.basename(p) != "INDEX.md")

    total = witnessed = stale = failed = 0
    reruns = 0
    for path in paths:
        name = os.path.relpath(path, REPO)
        text = open(path, encoding="utf-8", errors="replace").read()
        m = None
        for line in text.splitlines():
            val = standing_field_value(line)
            if val is not None and any(tok in val for tok in STANDING_TOKENS):
                m = line
        standing = standing_field_value(m).replace("**", "") if m else None
        chosen = None
        for cmd in extract_commands(text):
            cls, payload = classify(cmd)
            if cls:
                chosen = (cls, payload, cmd)
                break
        total += 1
        if standing is None:
            failed += 1
            print("[WITNESS-FAIL] %s NO-STANDING" % name)
            continue
        if chosen is None:
            # every command classed unsafe OR no commands at all
            cmds = extract_commands(text)
            reason = "no rerunnable command in receipt" if not cmds else "no command in a safe class"
            stale += 1
            print("[WITNESS-STALE] %s %s (standing: %s)" % (name, reason, standing.split()[0]))
            continue
        cls, payload, cmd = chosen
        if args.class_filter and cls != args.class_filter:
            print("[WITNESS-SKIP-FILTER] %s class=%s" % (name, cls))
            continue
        if args.limit and reruns >= args.limit:
            print("[WITNESS-SKIP-LIMIT] %s class=%s" % (name, cls))
            continue
        if args.dry_run:
            print("[WITNESS-DRY] %s class=%s cmd=%s (standing: %s)" % (name, cls, cmd[:100], standing.split()[0]))
            continue
        reruns += 1
        print("[WITNESS-RUN] %s class=%s cmd=%s" % (name, cls, cmd[:100]))
        sys.stdout.flush()
        try:
            proc = run_class(cls, payload)
            out = (proc.stdout or "") + (proc.stderr or "")
            tail = " | ".join(l.strip() for l in out.strip().splitlines()[-2:])
            if proc.returncode == 0:
                witnessed += 1
                print("[WITNESS-GREEN] %s exit=0 :: %s" % (name, tail[:160]))
            else:
                failed += 1
                print("[WITNESS-RED] %s exit=%d :: %s" % (name, proc.returncode, tail[:200]))
        except subprocess.TimeoutExpired:
            failed += 1
            print("[WITNESS-RED] %s TIMEOUT" % name)

    print("")
    print("[WITNESS-SUMMARY] total=%d witnessed-green=%d stale-typed=%d failed=%d%s"
          % (total, witnessed, stale, failed, " (DRY-RUN)" if args.dry_run else ""))
    # dry-run lists dispositions; only a real run gates.
    return 1 if (failed and not args.dry_run) else 0


if __name__ == "__main__":
    sys.exit(main())
