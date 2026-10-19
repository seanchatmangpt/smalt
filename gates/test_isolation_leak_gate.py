#!/usr/bin/env python3
"""Invariant gate: mechanical test-isolation leak court (static scan).

Subject: every `test/**/*.exs` file that mutates global test substrate:
  * Application.put_env / Application.delete_env on :smalt or :logger
  * :persistent_term.put/2
  * :ets.new(<literal>, [... :named_table ...])

Restore-discipline rule (per file, per mutated key):
  a mutation is COVERED iff the same file
    (a) SAVES the previous value (Application.get_env / fetch_env /
        :persistent_term.get bound to that key), and
    (b) RESTORES inside an on_exit block or a try/after `after` region.

A put_env whose on_exit restore writes a hardcoded literal (no save) does
NOT count -- that is the witnessed "on_exit-only" leak class (mcp_test
doctor_supervisor restores `Smalt.Supervisor` instead of the saved value).

Allowlist: files whose restore discipline was hand-verified and that the
scanner rules cannot yet express precisely (tls_test.exs saves the whole
:smalt env as a map via a comprehension). Allowlisted paths are EXEMPT from
the per-key rule but still scanned and reported as ALLOWED.

Fail-closed contract (matches gates/common.py run_gate):
  (a) positive: KNOWN-clean fixture files (save-prev + on_exit restore)
      must be found GREEN by the scanner, and every allowlist file must be
      seen to carry mutations (the scan actually observed the surface);
  (b) negative fixtures: mutated copies of a clean file (on_exit stripped;
      literal restore without save) MUST be REFUSED by the same scanner.

Exit: 0 = green tree; 1 = offenders exist or gate vacuous; never silent.
First-run expectation: exit 1 with the offender table (honest nonzero).
Stdlib only; no substrate boot; no git.
"""
import json
import os
import re
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RECEIPT_DIR = os.path.join(REPO, "tmp", "invariant-gates")
TEST_DIR = os.path.join(REPO, "test")

# Files whose restore discipline was hand-verified (see module docstring).
# Each entry: scanner cannot express the restore form used; discipline
# hand-verified on 2026-10-18 (receipt docs/jira/v26.10.18/receipts/
# i29-leak-remediation.md). Whole-file exemption, named per file.
ALLOWLIST = {
    # ORIGINAL: saves the whole :smalt env as a map via a comprehension.
    "test/tls_test.exs",
    # Variable-key save_restore/1 helper + on_exit restore-only shields
    # (for key <- [:token_audiences, :trusted_proxies] on_exit with
    # prev-keyed put/delete). Genuine nil-preserving restore; scanner
    # cannot bind variable keys.
    "test/auth_enforce_test.exs",
    # for-loop variable-key port pins in setup, restored via
    # SmaltTest.PortEnv.restore(prev_ports) + Lifecycle.restore_app/0 in
    # on_exit. Genuine discipline; variable keys inexpressible.
    "test/canonical_projection_test.exs",
    # :persistent_term twin metadata under module-scoped keys
    # {__MODULE__, :twin}/{__MODULE__, :twin_sup}; sup stopped in on_exit,
    # keys read only by this module. Tuple keys inexpressible.
    "test/kv_tls_test.exs",
    # restore_env/2 nil-preserving variable-key restore helper, called
    # from on_exit blocks; mutation keys themselves save + restore.
    "test/lro_test.exs",
    # ets.new with @table/module-attribute or per-test variable table
    # names, every table created by the test is deleted in on_exit
    # (:ets.delete(table)). Variable table names inexpressible.
    "test/store_dets_test.exs",
    "test/store_dets_growth_test.exs",
    "test/azsim/dets_recovery_test.exs",
    "test/data_plane/audit_planes_test.exs",
    # pterm key variables (key_ref/tp_ref/rs_ref = {Module, :keypair}
    # tuples) saved via :persistent_term.get and erased/restored in
    # try/after; plus variable-key env restore loops in after blocks.
    "test/trust_profile_test.exs",
    # pterm receipt counters under {__MODULE__, key} via bump/count
    # helpers -- intentionally suite-lifetime, module-scoped keys.
    "test/amqp/fuzz_test.exs",
    # pterm {__MODULE__, :port} pin for the court's own booted listener;
    # module-scoped, read only by the same file's port/0.
    "test/compliance/c3_cosmos.exs",
    "test/compliance/c4_blob.exs",
    # Module-body shifted-port boot config (test_helper-class, guarded by
    # :ets.info(:smalt_blobs) so it is a no-op when the app is up);
    # variable-key for-loop put.
    "test/data_plane/blob_service_test.exs",
    # pterm {Smalt.TrustProfile, :keypair} copy of the signer keypair,
    # erased in try/after (lens-5); tuple key inexpressible.
    "test/security/security_hardening_test.exs",
    # azb20 boot SCRIPT (mix run, not a test module): sets lane-private
    # port/planes/sb config before ensure_all_started in its own BEAM;
    # no test process, nothing to restore into.
    "test/sdk-full/azb20/boot_plane.exs",
    # The flagged put_env is inside a heredoc SCRIPT executed by a
    # subprocess BEAM (durability twin); zero leak into the test VM.
    "test/azsim/data_plane_test.exs",
}

MUT_APPS = ("smalt", "logger")

RE_ON_EXIT = re.compile(r'^\s*on_exit\s*\(')
RE_AFTER = re.compile(r'^(\s*)after\s*$')
RE_PUT_ENV = re.compile(
    r'Application\.put_env\(\s*:(\w+)\s*,\s*([^,()]+?)\s*,')
RE_DEL_ENV = re.compile(
    r'Application\.delete_env\(\s*:(\w+)\s*,\s*([^,()]+?)\s*[,)]')
RE_GET_ENV = re.compile(
    r'(?:Application\.get_env|Application\.fetch_env!?)\(\s*:(\w+)\s*,\s*([^,()]+?)\s*[,)]')
RE_PT_PUT = re.compile(r':persistent_term\.put\(\s*([^,()]+?)\s*,')
RE_PT_GET = re.compile(r':persistent_term\.get\(\s*([^,()]+?)\s*[,)]')
RE_ETSN = re.compile(r':ets\.new\(\s*([^,()\s]+?)\s*,([^)]*)\)')
RE_ETSD = re.compile(r':ets\.delete(?:_all_objects)?\(\s*([^,()\s]+?)\s*[,)]')


def _indent(line):
    return len(line) - len(line.lstrip())


def _code_lines(text):
    """Yield (lineno, line) with trailing comments stripped (approximate)."""
    for i, raw in enumerate(text.splitlines(), 1):
        line = raw
        m = re.search(r'\s#', line)
        if m and '"' not in line[:m.start()]:
            line = line[:m.start()]
        yield i, line.rstrip()


def _regions(lines):
    """Return (on_exit_lines, after_lines) as sets of line numbers."""
    on_exit, afters = set(), set()
    opens = []
    for i, line in lines:
        if RE_ON_EXIT.match(line):
            opens.append((i, _indent(line)))
            continue
        for o in list(opens):
            if re.search(r'\bend\)', line) and _indent(line) <= o[1]:
                for n in range(o[0], i + 1):
                    on_exit.add(n)
                opens.remove(o)
    for o in opens:
        on_exit.add(o[0])
    aopens = []
    for i, line in lines:
        if RE_AFTER.match(line):
            aopens.append((i, _indent(line)))
            continue
        for a in list(aopens):
            if re.match(r'^\s*end\s*$', line) and _indent(line) <= a[1]:
                for n in range(a[0], i + 1):
                    afters.add(n)
    for a in aopens:
        afters.add(a[0])
    return on_exit, afters


def scan_text(text, name="<text>"):
    """Scan one .exs body; returns a verdict dict for that file."""
    lines = list(_code_lines(text))
    on_exit_rng, after_rng = _regions(lines)
    restore_region = on_exit_rng | after_rng

    muts = {}        # (kind, key) -> first lineno
    saves = set()    # keys with an observed save of previous value
    restores = {}    # (kind, key) -> first restore lineno in a region
    unresolved = []  # (lineno, reason)

    for i, line in lines:
        in_region = i in restore_region
        for m in RE_PUT_ENV.finditer(line):
            app, key = m.group(1), m.group(2).strip()
            if app not in MUT_APPS:
                continue
            if key.startswith(":"):
                muts.setdefault(("env", app + "." + key), i)
            else:
                unresolved.append((i, "put_env non-literal key `%s`" % key))
        for m in RE_DEL_ENV.finditer(line):
            app, key = m.group(1), m.group(2).strip()
            if app not in MUT_APPS:
                continue
            if key.startswith(":"):
                # delete_env is itself a global mutation (destroys prev value)
                muts.setdefault(("env", app + "." + key), i)
            else:
                unresolved.append((i, "delete_env non-literal key `%s`" % key))
        for m in RE_GET_ENV.finditer(line):
            # a SAVE binds the previous value: `x = Application.get_env(...)`.
            # A bare read (assert/case) is not a save -- witnessed bug: the
            # clean fixture's `assert Application.get_env(...) == :mutated`
            # counted as a save and let the literal-restore fixture pass.
            if "==" not in line and (
                    re.search(r"[^=!<>]=", line)
                    or re.match(r"^\s*[\w@]+:\s", line)):
                key = m.group(2).strip()
                if key.startswith(":"):
                    saves.add("env." + m.group(1) + "." + key)
                else:
                    saves.add("@catchall-save@")
        for m in RE_PT_PUT.finditer(line):
            key = m.group(1).strip()
            if key.startswith(":"):
                muts.setdefault(("pterm", key), i)
            else:
                unresolved.append((i, "persistent_term non-literal key `%s`" % key))
        for m in RE_PT_GET.finditer(line):
            key = m.group(1).strip()
            saves.add("pterm." + key if key.startswith(":") else "@catchall-save@")
        for m in RE_ETSN.finditer(line):
            tname, opts = m.group(1), m.group(2)
            if ":named_table" in opts:
                if tname.startswith(":"):
                    muts.setdefault(("ets", tname), i)
                else:
                    # variable table name: restore = on_exit :ets.delete;
                    # untrackable statically -> require a catchall save
                    unresolved.append((i, "ets.new non-literal name `%s`" % tname))
        if in_region:
            for m in RE_PUT_ENV.finditer(line):
                app, key = m.group(1), m.group(2).strip()
                if app in MUT_APPS and key.startswith(":"):
                    restores.setdefault(("env", app + "." + key), i)
            for m in RE_DEL_ENV.finditer(line):
                app, key = m.group(1), m.group(2).strip()
                if app in MUT_APPS and key.startswith(":"):
                    restores.setdefault(("env", app + "." + key), i)
            for m in RE_ETSD.finditer(line):
                tname = m.group(1)
                if tname.startswith(":"):
                    restores.setdefault(("ets", tname), i)
            for m in RE_PT_PUT.finditer(line):
                key = m.group(1).strip()
                if key.startswith(":"):
                    restores.setdefault(("pterm", key), i)
            # delete of a variable table name inside on_exit: covered above
            # only for literals; a bare `:ets.delete(table, k)` with variable
            # name counts as a catchall restore
            if re.search(r':ets\.delete\(\s*[^:,()\s]+\s*,', line):
                restores.setdefault(("ets", "@catchall-restore@"), i)
            # variable-key restore inside a region (`for {k, v} <- prev` /
            # `Application.put_env(:smalt, k, v)`) or the house whole-env
            # restore helper (SmaltTest.Lifecycle.restore_app/0, see
            # test/test_helper.exs) is a catchall env restore
            for m in (list(RE_PUT_ENV.finditer(line))
                      + list(RE_DEL_ENV.finditer(line))):
                if m.group(1) in MUT_APPS and not m.group(2).strip().startswith(":"):
                    restores.setdefault(("env", "@catchall-restore@"), i)
            if "restore_app" in line:
                restores.setdefault(("env", "@catchall-restore@"), i)

    offenders = []
    for (kind, key), lineno in sorted(muts.items(), key=lambda kv: kv[1]):
        ksave = kind + "." + key
        covered = ksave in saves and ((kind, key) in restores or
                                      ("env", "@catchall-restore@")
                                      in restores)
        # ets literal tables may be restored via :ets.delete(:tbl) even
        # without a "save" (creation is not destruction of prior state)
        if kind == "ets":
            covered = (kind, key) in restores or \
                ("ets", "@catchall-restore@") in restores
        if not covered:
            why = "no save of prev value" if ksave not in saves else \
                "no restore in on_exit/after"
            offenders.append((lineno, "%s mutation `%s` (%s)"
                              % (kind, key, why)))

    return {
        "file": name,
        "mutations": len(muts) + len(unresolved),
        "unresolved": unresolved,
        "offenders": offenders,
        "verdict": "REFUSE" if (offenders or unresolved) else "PASS",
    }


CLEAN_SNIPPET = '''\
defmodule IsoProbeClean do
  use ExUnit.Case, async: false

  setup do
    prev = Application.get_env(:smalt, :probe_key, :unset)
    on_exit(fn ->
      if prev == :unset do
        Application.delete_env(:smalt, :probe_key)
      else
        Application.put_env(:smalt, :probe_key, prev)
      end
    end)
    Application.put_env(:smalt, :probe_key, :mutated)
    :ok
  end

  test "clean discipline" do
    assert Application.get_env(:smalt, :probe_key) == :mutated
  end
end
'''


def _strip_on_exit(text):
    out = []
    skipping = False
    depth_indent = None
    for raw in text.splitlines():
        if not skipping and re.match(r'^\s*on_exit\s*\(', raw):
            skipping = True
            depth_indent = _indent(raw)
            continue
        if skipping:
            if re.search(r'\bend\)', raw) and _indent(raw) <= depth_indent:
                skipping = False
            continue
        out.append(raw)
    return "\n".join(out) + "\n"


def _literal_restore_variant(text):
    return text.replace(
        "prev = Application.get_env(:smalt, :probe_key, :unset)",
        "_ = :noop").replace(
        "if prev == :unset do", "if false do").replace(
        "Application.put_env(:smalt, :probe_key, prev)",
        "Application.put_env(:smalt, :probe_key, Smalt.Supervisor)")


def run_fixtures():
    """Negative/positive fixtures on temp copies via the same scanner.

    Returns (list of fixture dicts, all_detected_ok: bool).
    """
    fixtures = []

    def run(name, text, expect):
        v = scan_text(text, name)
        detected = v["verdict"] == "REFUSE"
        ok = detected == expect
        fixtures.append({
            "fixture": name,
            "expected": "REFUSE" if expect else "PASS",
            "scanner": v["verdict"],
            "detected": detected,
            "ok": ok,
            "details": ["L%d %s" % (ln, why) for ln, why in v["offenders"]],
        })
        return ok

    ok = True
    # positive: intact clean discipline must be found GREEN
    ok &= run("clean-intact-save-plus-on_exit", CLEAN_SNIPPET, expect=False)
    # negative: on_exit stripped -> leak must be REFUSED
    ok &= run("on_exit-stripped", _strip_on_exit(CLEAN_SNIPPET), expect=True)
    # negative: restore without save (hardcoded literal, mcp-style)
    ok &= run("literal-restore-no-save", _literal_restore_variant(CLEAN_SNIPPET),
              expect=True)
    return fixtures, ok


def scan_tree():
    results = []
    for root, _dirs, files in os.walk(TEST_DIR):
        for fn in sorted(files):
            if not fn.endswith(".exs"):
                continue
            path = os.path.join(root, fn)
            rel = os.path.relpath(path, REPO)
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
            v = scan_text(text, rel)
            if rel in ALLOWLIST:
                v["allowlisted"] = True
                v["verdict"] = "ALLOWED" if v["mutations"] else "PASS"
                if not v["mutations"]:
                    v["verdict"] = "STALE-ALLOWLIST"  # allowlist entry that no longer mutates
            results.append(v)
    return results


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true", help="dump JSON to stdout")
    args = ap.parse_args()

    t0 = __import__("time").monotonic()
    tree = scan_tree()
    fixtures, fixtures_ok = run_fixtures()

    offenders = [v for v in tree
                 if v["verdict"] == "REFUSE"]
    allow = [v for v in tree if v.get("allowlisted")]
    stale = [v for v in tree if v["verdict"] == "STALE-ALLOWLIST"]

    positives_ok = fixtures_ok and not stale and all(
        v["mutations"] > 0 for v in allow)

    print("== test-isolation-leak court ==")
    print("scanned %d .exs files under test/ (%d allowlisted)"
          % (len(tree), len(allow)))
    print()
    print("-- positive: KNOWN-clean discipline fixtures --")
    for fx in fixtures:
        print("%s fixture:%s (expected %s, scanner said %s%s)"
              % ("PASS" if fx["ok"] else "FAIL", fx["fixture"],
                 fx["expected"], fx["scanner"],
                 "" if not fx["details"] else "; " + "; ".join(fx["details"])))
    print()
    print("-- allowlist --")
    for v in allow:
        print("%s %s (%d tracked mutations, exempt: hand-verified restore)"
              % (v["verdict"], v["file"], v["mutations"]))
    print()
    if offenders:
        print("-- OFFENDERS (%d files, %d mutations uncovered) --"
              % (len(offenders),
                 sum(len(v["offenders"]) + len(v["unresolved"])
                     for v in offenders)))
        for v in offenders:
            for ln, why in v["offenders"][:6]:
                print("  %s:%d %s" % (v["file"], ln, why))
            extra = len(v["offenders"]) - 6
            if extra > 0:
                print("  %s: ... +%d more" % (v["file"], extra))
    else:
        print("-- OFFENDERS: none --")

    tree_green = not offenders
    gate_ok = positives_ok and fixtures_ok
    # The gate MECHANICS must be non-vacuous (positives green, fixtures
    # refused); the TREE verdict is separate: today it is expected red.
    verdict = "PASS" if (gate_ok and tree_green) else \
        ("FAIL" if not gate_ok else "FAIL-TREE-LEAKS")
    receipt = {
        "schema": "smalt-invariant-gate/v1",
        "name": "test-isolation-leak",
        "date": __import__("time").strftime("%Y-%m-%d"),
        "elapsed_s": round(__import__("time").monotonic() - t0, 3),
        "subject": {"repo": REPO, "scope": "test/**/*.exs (static scan)"},
        "scanned_files": len(tree),
        "allowlist": sorted(ALLOWLIST),
        "positive": "PASS" if positives_ok else "FAIL",
        "fixtures": fixtures,
        "offender_files": [v["file"] for v in offenders],
        "offender_count": len(offenders),
        "tree_verdict": "GREEN" if tree_green else "LEAKS",
        "verdict": verdict,
    }
    os.makedirs(RECEIPT_DIR, exist_ok=True)
    rpath = os.path.join(RECEIPT_DIR, "test-isolation-leak-receipt.json")
    with open(rpath, "w") as f:
        json.dump(receipt, f, indent=2)
    print()
    print("verdict=%s tree=%s offenders=%d fixtures_refused=%s receipt=%s"
          % (verdict, receipt["tree_verdict"], len(offenders),
             fixtures_ok, rpath))
    if args.json:
        print(json.dumps(receipt, indent=2))
    # exit 1 whenever the tree leaks OR the gate itself is vacuous
    return 0 if verdict == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
