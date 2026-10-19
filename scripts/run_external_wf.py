#!/usr/bin/env python3
"""Run external verification workflows (primary tier) and mint receipts.

Reads verification/workflows.json, resolves each workflow's entry points
(verification/ts/wfN via the TS suite's own node runner, verification/py
test_wfN* via the suite's own pytest runner), runs one workflow (--wf) or
all, against an already-booted substrate (SMALT_*/AZURE_* env), and ALWAYS
writes the primary-tier receipt
docs/jira/v<window>/sdk-results/wfN-<lang>-<slug>.md (5-field header +
per-cell tags; BLOCKED tags on abort via try/finally).

Exit codes: 0 every cell PASS / 1 some cell not PASS / 2 substrate env
missing / 3 usage (unknown workflow, unparseable registry).
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sdk_coverage import (  # noqa: E402
    ROOT, WF_JSON, WF_VERSION, cell_verdict, parse_cell_tags,
)

SUBJECT_SHA = subprocess.run(
    ["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True
).stdout.strip() or "unknown"

TS_TIMEOUT = 1800
PY_TIMEOUT = 1800

# Surface-token aliases: leading tokens of a test/check name -> canonical
# surface id. Only applied when the resolved surface is in the workflow's
# declared non-cap surfaces; a recognized surface outside the wf's list is
# SKIPPED (it exercises a different wf's cell), an unrecognized name falls
# back to ALL of the wf's non-cap surfaces (lifecycle-style tests).
SURFACE_ALIASES = {
    "arm": "arm", "vnet": "arm", "storage": "arm", "policy": "arm",
    "rg": "resource-graph", "resource": "resource-graph",
    "graph": "resource-graph",
    "purview": "purview-atlas", "atlas": "purview-atlas",
    "appconfig": "appconfig", "blob": "blob", "cosmos": "cosmos",
    "ledger": "ledger", "keyvault": "keyvault", "kv": "keyvault",
    "skr": "skr", "eventgrid": "eventgrid", "eg": "eventgrid",
    "eventhubs": "eventhubs", "eh": "eventhubs", "eventhub": "eventhubs",
    "servicebus": "servicebus", "sb": "servicebus",
    "sentinel": "sentinel",
}
KD_RE = re.compile(r"KD-\d+")


def wf_surfaces(wf):
    return [s for s in wf["surfaces"] if not s.startswith("cap:")]


def kebab(name):
    return name.replace("_", "-").lower()


def map_verdict(raw):
    return {"PASSED": "PASS", "FAILED": "FAIL", "ERROR": "FAIL",
            "XFAIL": "SKIP", "XFAILED": "SKIP", "SKIPPED": "SKIP",
            "GREEN": "PASS", "MISSING": "BLOCKED",
            "PASS": "PASS", "FAIL": "FAIL", "SKIP": "SKIP",
            "BLOCKED": "BLOCKED"}.get(raw, "FAIL")


def surface_for(name, surfaces):
    """Leading surface token -> canonical surface, or None when unrecognized
    (caller falls back to all of the wf's non-cap surfaces)."""
    tok = kebab(name).split("-")[0]
    return SURFACE_ALIASES.get(tok)


def emit(tags, wf, test, raw_verdict, kds=()):
    """Append per-cell tags for one test/check outcome. Attribution: a
    recognized surface inside the wf's list takes the tag; a recognized
    surface outside the list is skipped (different wf's cell) UNLESS the wf
    declares exactly one non-cap surface (then it absorbs every check);
    unrecognized names fan out to all of the wf's non-cap surfaces — but
    only for non-SKIP verdicts (an xfail that names no surface must not
    mark every surface skipped)."""
    verd = map_verdict(raw_verdict)
    surfaces = wf_surfaces(wf)
    surf = surface_for(test, surfaces)
    if surf is None:
        if verd == "SKIP" or not surfaces:
            return
        targets = surfaces
    elif surf in surfaces:
        targets = [surf]
    else:
        if len(surfaces) == 1:
            targets = surfaces
        else:
            return
    op = kebab(re.sub(r"^(kv|rg|sb|eh|eg)-", "", test) if surf else test)
    for s in targets:
        tags.append({"surface": s, "op": op, "verdict": verd,
                     "kds": sorted(set(KD_RE.findall(" ".join(kds))))})


PY_SUMMARY_RE = re.compile(
    r"^\s*(?P<verdict>PASSED|FAILED|ERROR|XFAIL|XFAILED|SKIPPED)\s+"
    r"(?P<file>[ \w./-]*test_(?P<wfn>wf\d+)_\w+\.py)::(?P<test>\w+)"
    r"(?:\s+-\s+(?P<reason>.*))?$", re.M)


def parse_py_summary(out, wf):
    """pytest -rA short-summary lines -> cell tags (wf-scoped)."""
    tags = []
    for m in PY_SUMMARY_RE.finditer(out):
        if m.group("wfn") != wf["id"].split("-", 1)[0]:
            continue
        kds = [m.group("reason")] if m.group("reason") else []
        emit(tags, wf, m.group("test"), m.group("verdict"), kds)
    return tags


TS_ROW_RE = re.compile(
    r"^\s*\[(?P<verdict>GREEN|FAIL|MISSING|REGISTERED-DIVERGENCE[^\]]*)\]\s+"
    r"(?P<name>[\w-]+)\s+—\s+(?P<detail>.*)$", re.M)
TS_SECTION_RE = re.compile(r"^-- (wf\d+):", re.M)


def parse_ts_section(out, wf):
    """run-all.mjs verdict table -> cell tags for this wf's section."""
    wfn = wf["id"].split("-", 1)[0]
    sections = TS_SECTION_RE.split(out)
    # split yields [pre, 'wf1', body1, 'wf2', body2, ...]
    body = ""
    for i in range(1, len(sections) - 1, 2):
        if sections[i] == wfn:
            body = sections[i + 1]
    tags = []
    for m in TS_ROW_RE.finditer(body):
        raw = m.group("verdict")
        verd = "SKIP" if raw.startswith("REGISTERED-DIVERGENCE") else raw
        emit(tags, wf, m.group("name"), verd,
             [m.group("name"), m.group("detail")])
    return tags


def load_registry():
    if not WF_JSON.exists():
        sys.exit("EXIT-3: verification/workflows.json absent — no registry")
    try:
        data = json.loads(WF_JSON.read_text())
    except json.JSONDecodeError as e:
        sys.exit(f"EXIT-3: workflows.json unparseable: {e}")
    if data.get("version") != WF_VERSION:
        sys.exit(f"EXIT-3: workflows.json version {data.get('version')!r} "
                 f"unsupported (want {WF_VERSION})")
    return data


def substrate_env_ready(env):
    """Portable-Azure-Target law: the runner only retargets official SDKs via
    env; a substrate address must be present or every cell would BLOCKED."""
    return any(k.startswith(("SMALT_", "AZURE_")) for k in env)


def blocked_tags(surfaces, reason):
    return [{"surface": s, "op": "abort", "verdict": "BLOCKED", "kds": []}
            for s in surfaces], reason


def run_ts(wf, wfn, env):
    """Run the TS workflow via the TS suite's own runner. Returns
    (returncode, tags, tail)."""
    entry = ROOT / wf["entry"]["ts"]
    ts_root = ROOT / "verification/ts"
    if not entry.exists():
        return None, *blocked_tags(wf["surfaces"],
                                   f"TS entry absent: {entry}")
    # The landed suites are wfN/index.ts driven by the TS suite's own
    # sequential runner (run-all.mjs sections -- wfN:); scope it to this wf.
    cmd_env = dict(env)
    cmd_env["SMALT_TS_WF"] = wfn
    cmd, cwd = ["node", "run-all.mjs"], ts_root
    env = cmd_env
    try:
        p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True,
                           text=True, timeout=TS_TIMEOUT)
        out = (p.stdout or "") + (p.stderr or "")
        tags = parse_ts_section(out, wf)
        return p.returncode, tags + parse_cell_tags(out), out[-2000:]
    except (subprocess.TimeoutExpired, OSError) as e:
        return None, *blocked_tags(wf["surfaces"], f"TS runner abort: {e}")


def run_py(wf, wfn, env):
    """Run the Python workflow via the PY suite's own runner."""
    py_root = ROOT / "verification/py"
    run_sh = py_root / "run.sh"
    files = sorted(py_root.glob(f"test_{wfn}_*.py"))
    if not files:
        return None, *blocked_tags(wf["surfaces"],
                                   f"no verification/py/test_{wfn}_*.py")
    if run_sh.exists():
        # run.sh takes no wf argument (any $1 would reach pytest as an
        # unknown selector -> rc=4). Run the full suite; per-wf attribution
        # happens in parse_py_summary via the test_ file's wfN segment.
        cmd, cwd = ["bash", "run.sh"], py_root
    else:
        cmd, cwd = [sys.executable, "-m", "pytest", "-x", "-q", *files], py_root
    try:
        p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True,
                           text=True, timeout=PY_TIMEOUT)
        out = (p.stdout or "") + (p.stderr or "")
        tags = parse_py_summary(out, wf) or []
        return p.returncode, tags + parse_cell_tags(out), out[-2000:]
    except (subprocess.TimeoutExpired, OSError) as e:
        return None, *blocked_tags(wf["surfaces"], f"PY runner abort: {e}")


def write_receipt(win, wf, lang, tags, tail):
    wfn = wf["id"].split("-", 1)[0]
    slug = wf["id"].split("-", 1)[1]
    out_dir = ROOT / "docs/jira" / win / "sdk-results"
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{wfn}-{lang}-{slug}.md"
    lines = [
        f"# External workflow receipt: {wf['id']} ({lang})",
        "",
        f"Workflow: {wf['id']}",
        f"Lang: {lang}",
        f"Window: {win}",
        f"SUBJECT_SHA: {SUBJECT_SHA}",
        "Profile: primary-tier external suite (official Azure SDKs; "
        f"surfaces: {', '.join(wf['surfaces'])})",
        f"Generated: {datetime.now(timezone.utc).isoformat()}",
        "",
        "## Cell tags",
        "",
    ]
    for t in tags:
        kd = f" ({', '.join(t['kds'])})" if t["kds"] else ""
        lines.append(f"{t['surface']}:{t['op']}: {t['surface']}/{t['op']} "
                     f"{t['verdict']}{kd}")
    lines += ["", "## Runner output tail", "", "```", tail.rstrip(), "```", ""]
    path.write_text("\n".join(lines))
    return path


def run_one(reg, wf, env):
    win = reg.get("window", "unknown")
    wfn = wf["id"].split("-", 1)[0]
    # cap: cells are witnessed by capability receipts (CAP_CELLS family in
    # sdk_coverage.py), not per-cell tags — the tag grammar's ":" separator
    # cannot express "cap:<id>" surfaces. Gate only on plain surfaces.
    gate_surfaces = [s for s in wf["surfaces"] if not s.startswith("cap:")]
    all_ok = True
    for lang in wf.get("langs", []):
        runner = run_ts if lang == "ts" else run_py
        rc, tags, tail = runner(wf, wfn, env)
        if rc == 0 and tags:
            verdicts = {s: cell_verdict(tags, s) for s in gate_surfaces}
        else:
            if tags:
                # runner failed mid-flight: keep its tags, add BLOCKED for
                # surfaces with no verdict yet
                have = {t["surface"] for t in tags}
                tags += [{"surface": s, "op": "abort", "verdict": "BLOCKED",
                          "kds": []}
                         for s in gate_surfaces if s not in have]
            else:
                tags, _ = blocked_tags(gate_surfaces,
                                       f"runner exit={rc}, no cell tags")
            verdicts = {s: cell_verdict(tags, s) for s in gate_surfaces}
        path = write_receipt(win, wf, lang, tags, tail)
        bad = {s: v for s, (v, _k) in verdicts.items() if v != "PASS"}
        status = "PASS" if not bad else f"NOT-PASS {bad}"
        if bad:
            all_ok = False
        print(f"[wf] {wf['id']}/{lang}: rc={rc} -> {status}"
              f" receipt={path.relative_to(ROOT)}")
    return all_ok


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("workflow", nargs="?", default=None,
                    help="workflow id (default: all)")
    args = ap.parse_args()
    reg = load_registry()
    env = dict(os.environ)
    if not substrate_env_ready(env):
        print("EXIT-2: no SMALT_*/AZURE_* substrate env "
              "(eval \"$(just relay-env)\" first)")
        sys.exit(2)
    wfs = reg.get("workflows", [])
    if args.workflow:
        wfs = [w for w in wfs if w["id"] == args.workflow]
        if not wfs:
            sys.exit(f"EXIT-3: unknown workflow {args.workflow!r}")
    ok = True
    for wf in wfs:
        ok = run_one(reg, wf, env) and ok
    print("GATE: OK — every cell PASS" if ok
          else "GATE: FAIL — some cells not PASS")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
