#!/usr/bin/env python3
"""BK-57 heir-guard gate (fail-closed).

Law (BK-33 warm-restart rebind class): every ETS table created with
`{:heir, Process.whereis(:init), []}` must have an existence guard on its
init path — `:ets.info(table)` / `:ets.whereis(table)` (with delete-stale or
rescue-ArgumentError) — before the `:ets.new`, or a warm `System.restart/0`
halts the VM ("table name already exists").

Mechanics
  1. Scan lib/ for `:ets.new` sites whose option list contains `:heir`.
  2. For each site, look for a guard expression in the same file:
       :ets.info(TBL)   / :ets.whereis(TBL)
     where TBL matches the new site's table token (e.g. `@table`,
     `table`, or the resolved `@table :name` atom).
  3. Classification per site:
       GUARDED    guard expression found for this table
       UNGUARDED  zero :ets.info/:ets.whereis occurrences in the file
                  (guard provably absent)
       UNPROVABLE guards exist in the file but none matches this table
                  (heuristic cannot prove presence OR absence)
     UNGUARDED and UNPROVABLE are both failures — no silent passes.

Self-test (--self-test): plants a temp module with an heir :ets.new and no
guard; the gate must classify it as a failure, else exit 2 (VACUOUS GATE).
"""

import os
import re
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DIR = os.path.join(ROOT, "lib")

NEW_RE = re.compile(r":ets\.new\s*\(")
GUARD_RE = re.compile(r":ets\.(?:info|whereis)\s*\(\s*([^()\s,]+)\s*\)")
ATTR_RE = re.compile(r"@\w+\s+:(\w+)")


def extract_calls(text, start_re):
    """Yield (start_offset, call_text) for each call matching start_re,
    call text extending to the balanced closing paren."""
    out = []
    for m in start_re.finditer(text):
        depth = 0
        i = m.start()
        n = len(text)
        # walk to the opening paren and balance it
        while i < n:
            if text[i] == "(":
                depth += 1
                if depth == 1:
                    open_off = i
                i += 1
                break
            i += 1
        else:
            continue
        while i < n:
            c = text[i]
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    out.append((m.start(), text[m.start():i + 1]))
                    break
            i += 1
    return out


def resolved_name(attr_token, lines_before):
    """@table -> atom name from the nearest `@table :name` attribute."""
    m = re.match(r"@(\w+)$", attr_token or "")
    if not m:
        return None
    pat = re.compile(r"@%s\s+:(\w+)" % m.group(1))
    for line in lines_before:
        am = pat.search(line)
        if am:
            return am.group(1)
    return None


def classify_site(call_text, file_text, lines_before):
    if ":heir" not in call_text:
        return "NOT-HEIR", None
    # table token = first argument of :ets.new(
    inner = call_text[call_text.index("(") + 1:]
    tok_m = re.match(r"\s*([^,\s(]+)", inner)
    if not tok_m:
        return "UNPROVABLE", "cannot parse table token from :ets.new"
    tok = tok_m.group(1)
    accepted = {tok}
    rname = resolved_name(tok, lines_before)
    if rname:
        accepted.add(":" + rname)

    guards = GUARD_RE.findall  # noqa: F841
    guard_hits = [g for g in GUARD_RE.finditer(file_text)]
    matching = [g for g in guard_hits
                if g.group(1) in accepted]
    if matching:
        return "GUARDED", "guard %s for %s" % (
            matching[0].group(0), sorted(accepted))
    if not guard_hits:
        return "UNGUARDED", "no :ets.info/:ets.whereis anywhere in file"
    return "UNPROVABLE", (
        "guards exist in file (%s) but none matches table token %s"
        % (sorted({g.group(0) for g in guard_hits}), sorted(accepted)))


def scan_dir(target):
    """Return list of (file, line, status, detail) for heir :ets.new sites."""
    rows = []
    for dirpath, _dirs, files in os.walk(target):
        for fn in sorted(files):
            if not fn.endswith(".ex"):
                continue
            path = os.path.join(dirpath, fn)
            try:
                text = open(path).read()
            except OSError as e:
                rows.append((path, 0, "UNPROVABLE", "unreadable: %s" % e))
                continue
            if ":heir" not in text:
                continue
            for off, call in extract_calls(text, NEW_RE):
                line = text.count("\n", 0, off) + 1
                lines_before = text[:off].splitlines()
                status, detail = classify_site(call, text, lines_before)
                if status != "NOT-HEIR":
                    rows.append((path, line, status, detail))
    return rows


BAD_MODULE = """\
defmodule HeirGuardSelfTestBad do
  @table :heir_guard_selftest_bad
  def init(_opts) do
    :ets.new(@table, [:set, :named_table, :public,
                      {:heir, Process.whereis(:init), []}])
    {:ok, %{}}
  end
end
"""

GOOD_MODULE = """\
defmodule HeirGuardSelfTestGood do
  @table :heir_guard_selftest_good
  def init(_opts) do
    case :ets.info(@table) do
      :undefined -> :ok
      _ -> :ets.delete(@table)
    end

    :ets.new(@table, [:set, :named_table, :public,
                      {:heir, Process.whereis(:init), []}])
    {:ok, %{}}
  end
end
"""

def self_test():
    with tempfile.TemporaryDirectory() as td:
        bad = os.path.join(td, "bad.ex")
        good = os.path.join(td, "good.ex")
        with open(bad, "w") as f:
            f.write(BAD_MODULE)
        with open(good, "w") as f:
            f.write(GOOD_MODULE + "\nend\n")
        rows = scan_dir(td)
        bad_rows = [r for r in rows if r[0].endswith("bad.ex")]
        good_rows = [r for r in rows if r[0].endswith("good.ex")]
        if not bad_rows:
            print("VACUOUS GATE: planted unguarded heir site was not even "
                  "seen (0 rows for bad.ex)")
            return 2
        if all(s == "GUARDED" for _f, _l, s, _d in bad_rows):
            heuristic_filter(bad)  # probe the gate's own parser
            print("VACUOUS GATE: unguarded heir site classified GUARDED — "
                  "heuristic admits the exact BK-33 defect class")
            return 2
        print("[self-test] bad.ex -> %s (%s)" % (bad_rows[0][2], bad_rows[0][3]))
        print("[self-test] good.ex -> %s" % (good_rows[0][2],) if good_rows
              else "[self-test] good.ex -> not classified (parser hiccup)")
        print("self-test PASS: planted unguarded heir site is refused")
        return 0


def heuristic_filter(path):
    try:
        with open(path) as f:
            f.read()
    except OSError:
        pass


def main():
    if "--self-test" in sys.argv:
        return self_test()
    rows = scan_dir(DEFAULT_DIR)
    if not rows:
        print("heir-guard: no heir :ets.new sites found — nothing to check "
              "(UNPROVABLE coverage failure, refusing)")
        return 1
    n_bad = 0
    for path, line, status, detail in rows:
        rel = os.path.relpath(path, ROOT)
        mark = {"GUARDED": "[ok]", "UNGUARDED": "[FAIL]",
                "UNPROVABLE": "[UNPROVABLE]"}.get(status, "[??]")
        print("%-13s %s:%d %s" % (mark, rel, line, detail or ""))
        if status != "GUARDED":
            n_bad += 1
    print("heir-guard: %d heir :ets.new sites, %d guarded, %d failing"
          % (len(rows), len(rows) - n_bad, n_bad))
    return 0 if n_bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
