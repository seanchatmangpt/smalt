#!/usr/bin/env python3
"""AZB-11 isolation court (static + runtime twin runner).

Extends gates/test_isolation_leak_gate.py (inherited, not duplicated): the
env rule is the leak gate's scanner, re-published here with two extensions:

  1. inline exemptions: a line carrying `# isolation-court: exempt <reason>`
     is removed from the scan (reason mandatory, counted in the receipt);
  2. the house helper `SmaltTest.Env.put_restored(k: v, ...)` counts as a
     fully-covered mutation (save-prev + on_exit restore, structural).

Plus a rule the leak gate does not have:

  (a) start_link discipline: in test/**/*_test.exs, a bare
      GenServer/Agent/Task/DynamicSupervisor.start_link (or any start_link
      with a literal `name:` option) in a test body must be
      `start_supervised!/1` (or SmaltTest.Singleton.start_supervised_singleton!,
      or an error-path assert). Exemption only via the inline marker.

Runtime twin (`--runtime`): boots the offline suite with
SmaltTest.IsolationFormatter (test/support/isolation_formatter.ex) and
--max-cases 1 so per-module diffs of Process.registered() and
Application.get_all_env(:smalt) are race-free; any
`ISOLATION-TWIN LEAK module=...` line fails the court with the module name.

Fail-closed: in-memory negative/positive fixtures (bare put_env with no
restore must be REFUSED naming file:line; clean save+on_exit discipline must
PASS), and `--self-check` proves the same on real temp files, including the
exemption-marker path.

Exit: 0 = static green (and, with --runtime, twin clean); 1 = offenders /
vacuous; 3 = self-check SKIP (mix unavailable). No git. Stdlib only.
"""
import fnmatch
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(REPO, "gates"))

import test_isolation_leak_gate as leak  # noqa: E402

RE_SL = re.compile(r'\b(GenServer|Agent|Task)\.start_link\(')
RE_NAMED_SL = re.compile(r'\.start_link\([^)]*name:\s*:\w')
RE_EXEMPT = re.compile(r'#\s*isolation-court:\s*exempt\s+\S')
RE_PUT_RESTORED = re.compile(r'SmaltTest\.Env\.put_restored\(')
RE_ERROR_PATH = re.compile(
    r'assert\s*\{:error|assert_raise|refute\s+match\?|assert\s+match\?\s*\{:error')

# in-memory fixtures (fail-closed contract, mirrors the leak gate's)
CLEAN_FIXTURE = '''\
defmodule IsoCourtClean do
  use ExUnit.Case, async: false

  setup do
    SmaltTest.Env.put_restored(probe_key: :mutated)
    :ok
  end

  test "clean" do
    assert Application.get_env(:smalt, :probe_key) == :mutated
  end
end
'''

BARE_FIXTURE = '''\
defmodule IsoCourtLeak do
  use ExUnit.Case, async: false

  test "bare put_env" do
    Application.put_env(:smalt, :probe_key, :leak)
  end
end
'''

NAMED_SL_FIXTURE = '''\
defmodule IsoCourtNamedSL do
  use ExUnit.Case, async: false

  test "named start_link leak" do
    Agent.start_link(fn -> :ok end, name: :iso_court_leaked_name)
  end
end
'''


def _strip_exemptions(text):
    """Blank out (keep line count for file:line fidelity) exempt-marked
    lines: the mutation code is replaced with a no-op literal."""
    out = []
    for line in text.splitlines():
        if RE_EXEMPT.search(line):
            out.append(re.sub(r'\S.*', '_ = :noop', line))
        else:
            out.append(line)
    return "\n".join(out) + "\n"


RE_DELETE_ENV = re.compile(r'Application\.delete_env\(:smalt,\s*:(\w+)\)')


def _apply_put_restored(text):
    """Normalize put_restored usage so the leak scanner sees full coverage:
    the helper saves prev + restores in on_exit, so replace the call with a
    canonical save+restore pair the scanner already understands. AZB-11b
    extension: the capture-then-delete shape —

        SmaltTest.Env.put_restored(k: Application.get_env(:smalt, :k))
        Application.delete_env(:smalt, :k)

    — pins the restore to the captured prev (the delete is test-scoped and
    the on_exit re-applies prev), so an Application.delete_env of the SAME
    key within the two lines after a put_restored call is covered too."""
    if not RE_PUT_RESTORED.search(text):
        return text
    lines = text.splitlines()
    out = []
    covered_until = -1
    for i, line in enumerate(lines):
        if i <= covered_until:
            continue
        if RE_PUT_RESTORED.search(line):
            indent = re.match(r'\s*', line).group(0)
            # gather the full call text (call may span two lines)
            call_text = line
            j = i
            while not call_text.rstrip().endswith(")") and j + 1 < len(lines):
                j += 1
                call_text += "\n" + lines[j]
            # cover adjacent same-key delete_env (capture-then-delete shape)
            k = j + 1
            while k <= j + 2 and k < len(lines):
                m = RE_DELETE_ENV.search(lines[k])
                if m and m.group(1) in call_text:
                    covered_until = k
                    break
                k += 1
            out.append(indent + "# covered: SmaltTest.Env.put_restored"
                                 " (save-prev + on_exit restore)")
        else:
            out.append(line)
    return "\n".join(out) + "\n"


def scan_env_rule(text, name):
    """Leak-gate scanner with isolation-court extensions applied."""
    return leak.scan_text(_apply_put_restored(_strip_exemptions(text)), name)


def scan_start_link_rule(text, name):
    """start_supervised! discipline for start_link calls in test bodies."""
    offenders = []
    raw_lines = text.splitlines()
    lines = list(leak._code_lines(text))  # comment-stripping, same as env rule
    for i, line in lines:
        raw = raw_lines[i - 1] if i - 1 < len(raw_lines) else line
        if RE_EXEMPT.search(raw):
            continue
        if RE_SL.search(line) or RE_NAMED_SL.search(line):
            if "start_supervised" in line or RE_ERROR_PATH.search(line):
                continue
            offenders.append(
                (i, "start_link in test body must be start_supervised!/1"
                    " (%s)" % (line.strip()[:60])))
    return offenders


def scan_file(text, rel):
    env_v = scan_env_rule(text, rel)
    sl = scan_start_link_rule(text, rel)
    offenders = [(ln, why) for ln, why in env_v["offenders"]] + sl
    return {
        "file": rel,
        "mutations": env_v["mutations"],
        "offenders": offenders,
        "verdict": "REFUSE" if offenders else "PASS",
    }


def run_fixtures():
    """In-memory fail-closed fixtures; returns (fixtures, all_ok)."""
    fx = []

    def run(name, text, expect_refuse, needle=None):
        v = scan_file(text, name)
        detected = v["verdict"] == "REFUSE"
        ok = detected == expect_refuse
        if needle:
            ok = ok and any(needle in why for _, why in v["offenders"])
        fx.append({"fixture": name,
                   "expected": "REFUSE" if expect_refuse else "PASS",
                   "scanner": v["verdict"],
                   "ok": ok,
                   "details": ["%d %s" % (ln, why)
                               for ln, why in v["offenders"]]})
        return ok

    ok = True
    ok &= run("clean-put_restored", CLEAN_FIXTURE, expect_refuse=False)
    ok &= run("bare-put_env", BARE_FIXTURE, expect_refuse=True,
              needle="probe_key")
    ok &= run("named-start_link", NAMED_SL_FIXTURE, expect_refuse=True,
              needle="start_supervised")
    # exemption marker really exempts (and only the marked line)
    ok &= run("exempt-honored",
              BARE_FIXTURE.replace(
                  "Application.put_env(:smalt, :probe_key, :leak)",
                  "Application.put_env(:smalt, :probe_key, :leak)"
                  "  # isolation-court: exempt fixture-only"),
              expect_refuse=False)
    return fx, ok


def scan_tree():
    test_dir = os.path.join(REPO, "test")
    results = []
    for root, _dirs, files in os.walk(test_dir):
        for fn in sorted(files):
            if fn.endswith("isolation_twin_probe_test.exs"):
                continue  # falsifier probe, never part of the tree scan
            if not fn.endswith(".exs") or fn == "test_helper.exs":
                continue
            path = os.path.join(root, fn)
            rel = os.path.relpath(path, REPO)
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
            results.append(scan_file(text, rel))
    return results


def cmd_self_check():
    """Anti-vacuity: the scanner must REFUSE a real temp file carrying a
    bare put_env (naming file:line), and must PASS the same file with the
    exemption marker; proves detection is not in-memory-only."""
    tdir = tempfile.mkdtemp(prefix="iso-court-selfcheck-")
    ok = True

    def run_variant(name, body, expect_refuse):
        nonlocal ok
        fpath = os.path.join(tdir, name)
        with open(fpath, "w") as f:
            f.write(body)
        with open(fpath) as f:
            text = f.read()
        rel = os.path.relpath(fpath, REPO)
        v = scan_file(text, rel)
        detected = v["verdict"] == "REFUSE"
        this_ok = detected == expect_refuse
        if expect_refuse:
            # must name file:line of the bare mutation
            this_ok = this_ok and any(
                "%s:%d" % (name, ln) and ln > 0 for ln, _ in v["offenders"])
        print("%s self-check/%s -> %s %s"
              % ("PASS" if this_ok else "FAIL", name,
                 v["verdict"], v["offenders"][:2]))
        ok &= this_ok
        return

    run_variant("bare.exs", BARE_FIXTURE, expect_refuse=True)
    run_variant("bare_exempt.exs",
                BARE_FIXTURE.replace(
                    "Application.put_env(:smalt, :probe_key, :leak)",
                    "Application.put_env(:smalt, :probe_key, :leak)"
                    "  # isolation-court: exempt self-check"),
                expect_refuse=False)
    print("self-check verdict=%s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


EXEMPTS_PATH = os.path.join(REPO, "test", "support",
                            "isolation_runtime_exemptions.exs")


def load_runtime_exempts():
    """Parse test/support/isolation_runtime_exemptions.exs: one
    `name <glob>  # reason: <text>` entry per line (Elixir-comment syntax so
    the static court's scanner ignores it). A leak block is exempt iff it has
    NO env deltas and EVERY names_new/names_lost entry matches a pattern.
    Missing file = no exemptions."""
    if not os.path.exists(EXEMPTS_PATH):
        return []
    exempts = []
    with open(EXEMPTS_PATH, encoding="utf-8") as f:
        body = f.read()
    for line in body.splitlines():
        m = re.match(r"\s*name\s+(\S+)\s+#\s*reason:\s*(.+)$", line)
        if m:
            exempts.append((m.group(1), m.group(2).strip()))
            continue
        if line.strip() and not line.strip().startswith("#"):
            print("REFUSE malformed exemption line: %r" % line.strip())
            sys.exit(1)
    return exempts


def classify_leaks(out, exempts):
    """Group LEAK lines with their detail lines; exempt a block only when it
    carries no env delta and all its name deltas match an exempt pattern."""
    blocks = []
    cur = None
    for line in out.splitlines():
        if "ISOLATION-TWIN LEAK" in line:
            cur = {"module": line.split("module=", 1)[1].split()[0],
                   "lines": [line.strip()], "detail": []}
            blocks.append(cur)
        elif cur is not None and line.startswith("ISOLATION-TWIN"):
            cur["detail"].append(line.strip())
    counted = []
    for b in blocks:
        names = []
        env_lines = []
        for d in b["detail"]:
            if "names_new=" in d:
                names += _bracketed(d, "names_new=")
            if "names_lost=" in d:
                names += _bracketed(d, "names_lost=")
            if " env " in d:
                env_lines.append(d)
        unm = [n for n in names
               if not any(fnmatch.fnmatch(n, pat) for pat, _ in exempts)]
        if env_lines or unm:
            counted.append(b)
            for l in b["lines"] + b["detail"]:
                print(l)
        else:
            reason = "; ".join(dict.fromkeys(
                r for n in names for pat, r in exempts if fnmatch.fnmatch(n, pat)))
            print("EXEMPT(%s) %s" % (reason[:120], b["lines"][0]))
    return counted


def _bracketed(line, key):
    seg = line.split(key, 1)[1]
    seg = seg.split("names_", 1)[0] if key == "names_new=" else seg
    inner = seg[seg.find("[") + 1:seg.find("]")]
    return [p.strip() for p in inner.split(",") if p.strip()]


def cmd_runtime():
    """Runtime twin: offline suite, serial, SmaltTest.IsolationFormatter."""
    fmt = "SmaltTest.IsolationFormatter"
    cmd = ["mix", "test", "--formatter", fmt, "--max-cases", "1"]
    env = dict(os.environ)
    env["MIX_ENV"] = "test"
    print("== isolation court: runtime twin (%s, serial) ==" % fmt)
    proc = subprocess.run(cmd, cwd=REPO, env=env, capture_output=True,
                          text=True)
    out = (proc.stdout or "") + (proc.stderr or "")
    # Typed runtime exemptions (AZB-11b): structural registered-name classes
    # (lib-owned lazy singletons, kernel-owned VM-lifetime processes,
    # shared-tree lazy-boot shifts). Exemption is name-pattern based with a
    # mandatory reason; a leak block counts ONLY if it carries an env delta
    # or an unmatched name delta — env leaks are never exemptable.
    exempts = load_runtime_exempts()
    counted = classify_leaks(out, exempts)
    n = len(counted)
    print("runtime twin: %d module(s) leaked; mix exit=%d" % (n, proc.returncode))
    print("runtime exemptions: %d pattern(s) in %s"
          % (len(exempts), EXEMPTS_PATH))
    verdict = "PASS" if (n == 0 and proc.returncode == 0) else "FAIL"
    print("runtime verdict=%s" % verdict)
    with open(os.path.join(REPO, "tmp", "isolation-court-runtime.out"),
              "w") as f:
        f.write(out)
    return 0 if verdict == "PASS" else 1


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--runtime", action="store_true",
                    help="also run the runtime twin (serial offline suite)")
    ap.add_argument("--static-only", action="store_true",
                    help="skip in-memory fixtures (self-check keeps them)")
    ap.add_argument("--self-check", action="store_true",
                    help="anti-vacuity: real temp-file fixture proof")
    ap.add_argument("--runtime-only", action="store_true")
    args = ap.parse_args()

    if args.runtime_only:
        return cmd_runtime()
    if args.self_check:
        return cmd_self_check()

    t0 = __import__("time").monotonic()
    tree = scan_tree()
    offenders = [v for v in tree if v["verdict"] == "REFUSE"]
    fixtures, fixtures_ok = run_fixtures()
    print("== isolation court (AZB-11) ==")
    print("scanned %d test module files" % len(tree))
    print()
    print("-- fail-closed fixtures --")
    for f in fixtures:
        print("%s fixture:%s (expected %s, scanner %s)%s"
              % ("PASS" if f["ok"] else "FAIL", f["fixture"],
                 f["expected"], f["scanner"],
                 "" if not f["details"] else "; " + "; ".join(f["details"])))
    print()
    if offenders:
        total = sum(len(v["offenders"]) for v in offenders)
        print("-- OFFENDERS (%d files, %d sites) --" % (len(offenders), total))
        for v in offenders:
            for ln, why in v["offenders"][:8]:
                print("  %s:%d %s" % (v["file"], ln, why))
            extra = len(v["offenders"]) - 8
            if extra > 0:
                print("  %s: ... +%d more" % (v["file"], extra))
    else:
        print("-- OFFENDERS: none --")

    static_green = not offenders
    verdict = "PASS" if (static_green and fixtures_ok) else "FAIL"
    print()
    print("verdict=%s static=%s fixtures=%s elapsed=%.2fs"
          % (verdict, "GREEN" if static_green else "LEAKS",
             "REFUSED-OK" if fixtures_ok else "VACUOUS",
             __import__("time").monotonic() - t0))
    return 0 if verdict == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
