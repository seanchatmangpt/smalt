#!/usr/bin/env python3
"""doctor_dod.py — supplemental Definition-of-Done check pass (DoD-5).

Companion to the pinned fail-closed court scripts/doctor.py (NOT modified by
this lane). Non-fatal INFO/WARN lines; hard FAIL only on the specific DoD
conditions listed below. Exit 0 unless a FAIL fires.

Checks (each from a filed finding, docs/jira/v26.10.14):
  1. stale substrate lock — /tmp/smalt-substrate.lock with no live smalt
     listeners -> WARN 'orphan lock holder' (+ holder pid via lsof if shown).
  2. lane build roots — _build-* dirs at repo root matching the lane-lease
     naming families -> WARN count + total bytes; remediation `just lane-clean`.
  3. workspace sanity — workspace/node_modules present, package.json parses,
     pin sanity: no "^21.x" @azure/arm-resources (nonexistent-pin class).
  4. smalt-cli sanity — .venv exists, `python -m py_compile smalt_cli/*.py`
     exit 0 (per-file error report on failure).
  5. receipts freshness — every file in docs/jira/v26.10.14/receipts/ with an
     mtime inside the session window -> INFO; a receipts/<lane>.md referenced
     in _LANES.md but missing on disk -> FAIL.
  6. envelope/defect cross-check — GAP(...) tokens present in docs/WIRE_PARITY.md
     (register sync with lane 13's census: 5 CLOSED + 9 UNSUPPORTED counts).

Usage: python3 scripts/doctor_dod.py [--json]
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LOCK = Path("/tmp/smalt-substrate.lock")
LANES_MD = REPO / "docs/jira/v26.10.14/_LANES.md"
RECEIPTS_DIR = REPO / "docs/jira/v26.10.14/receipts"
WIRE_PARITY = REPO / "docs/WIRE_PARITY.md"
WORKSPACE_PKG = REPO / "workspace/package.json"
WS_NODE_MODULES = REPO / "workspace/node_modules"
CLI_DIR = REPO / "smalt-cli"
SESSION_WINDOW_S = 24 * 3600  # "session window": files touched in the last day

# lane build root families (same classes as 06-lane-cleanup.just / lane-clean)
LANE_ROOT_RE = re.compile(
    r"^_build-(lane|l|f16|lens|verdict|docs|stab|compliance)", re.IGNORECASE
)
# smalt substrate listener ports (ARM :9443, wire/egress :8443)
SMALT_PORTS = [9443, 8443]

# envelope/defect cross-check tokens (lane 13 census)
EXPECTED_TOKENS = [
    "GAP(blob-comp-lease-absent)",
    "GAP(blob-error-envelope-json)",
    "GAP(cosmos-sql-translator-absent)",
    "GAP(ledger-lazy-create-default)",
    "GAP(eventgrid-eg1-schema-absent)",
    "GAP(eventhubs-partition-metadata-absent)",
    "GAP(eventhubs-consumer-group-enumeration-absent)",
    "GAP(atlas-search-relationship-get-absent)",
    "GAP(kql-datetime-dynamic-types-absent)",
]
# lane 13 census: 5 CLOSED (strikethrough/retired) + 9 UNSUPPORTED tokens kept
EXPECTED_CLOSED_COUNT = 5
EXPECTED_UNSUPPORTED_COUNT = 9

WARNINGS = []
FAILURES = []


def info(msg):
    print(f"INFO  {msg}")


def warn(msg):
    print(f"WARN  {msg}")
    WARNINGS.append(msg)


def fail(msg):
    print(f"FAIL  {msg}")
    FAILURES.append(msg)


def dir_size(p: Path) -> int:
    total = 0
    for root, _dirs, files in os.walk(p, onerror=lambda e: None):
        for f in files:
            try:
                total += (Path(root) / f).stat().st_size
            except OSError:
                pass
    return total


def human(n: int) -> str:
    for unit in ("B", "KiB", "MiB", "GiB"):
        n = n / 1024 if unit != "B" else n
        if n < 1024:
            return f"{n:.1f} {unit}"
    return f"{n:.1f} TiB"


# ---------------------------------------------------------------- check 1
def check_stale_lock():
    if not LOCK.exists():
        info("substrate lock: /tmp/smalt-substrate.lock absent (nothing to check)")
        return
    live = []
    for port in SMALT_PORTS:
        try:
            out = subprocess.run(
                ["/usr/sbin/lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN"],
                capture_output=True, text=True, timeout=10,
            ).stdout
        except Exception:
            out = ""
        for line in out.splitlines()[1:]:
            parts = line.split()
            if len(parts) >= 2:
                live.append((port, parts[0], parts[1]))
    if live:
        info(
            "substrate lock: lock present AND live listeners "
            f"{', '.join(f'{p} pid={pid} ({c})' for p, c, pid in live)} — not stale"
        )
        return
    # lsof on the lock path for the holder pid (flock holders may not show)
    holder = None
    try:
        out = subprocess.run(
            ["/usr/sbin/lsof", "-t", str(LOCK)], capture_output=True, text=True, timeout=10
        ).stdout.strip()
        holder = out.splitlines()[0] if out else None
    except Exception:
        holder = None
    body = LOCK.read_text(errors="replace").strip()[:200]
    pid_from_body = None
    m = re.search(r"\b(\d{2,7})\b", body)
    if m:
        pid_from_body = m.group(1)
    holder_desc = f", holder pid={holder}" if holder else ""
    if pid_from_body and not holder:
        holder_desc += f" (lock body pid={pid_from_body}, not confirmed live)"
    warn(
        "orphan lock holder: /tmp/smalt-substrate.lock exists but no live smalt "
        f"listeners on ports {SMALT_PORTS}{holder_desc}"
    )


# ---------------------------------------------------------------- check 2
def check_lane_roots():
    roots = sorted(
        d for d in REPO.iterdir()
        if d.is_dir() and LANE_ROOT_RE.match(d.name)
    )
    if not roots:
        info("lane build roots: none present (leases cleaned)")
        return
    total = 0
    for d in roots:
        total += dir_size(d)
    warn(
        f"lane build roots: {len(roots)} lane build-root lease(s) at repo root, "
        f"total {human(total)}; remediation: `just lane-clean`"
    )


# ---------------------------------------------------------------- check 3
def check_workspace():
    if not (REPO / "workspace").is_dir():
        info("workspace: no workspace/ dir (check skipped)")
        return
    if not WS_NODE_MODULES.is_dir():
        warn("workspace/node_modules absent — run npm install in workspace/")
    else:
        info("workspace: node_modules present")
    if not WORKSPACE_PKG.is_file():
        fail("workspace/package.json missing")
        return
    try:
        pkg = json.loads(WORKSPACE_PKG.read_text())
        deps = {**pkg.get("dependencies", {}), **pkg.get("devDependencies", {})}
        info(f"workspace: package.json parses ({len(deps)} deps)")
    except Exception as e:
        fail(f"workspace/package.json does not parse: {e}")
        return
    pin = deps.get("@azure/arm-resources")
    if pin is None:
        info("workspace: @azure/arm-resources not pinned (nothing to sanity-check)")
    elif isinstance(pin, str) and pin.startswith("^21."):
        fail(
            f"nonexistent-pin class: @azure/arm-resources pin '{pin}' (^21.x does not exist)"
        )
    else:
        info(f"workspace: @azure/arm-resources pin '{pin}' sane (no ^21.x)")


# ---------------------------------------------------------------- check 4
def check_cli():
    venv = CLI_DIR / ".venv"
    if not venv.is_dir():
        fail("smalt-cli/.venv missing")
        return
    py = venv / "bin/python"
    py_cmd = str(py) if py.exists() else shutil.which("python3")
    info(f"smalt-cli: .venv present (python: {py_cmd})")
    files = sorted((CLI_DIR / "smalt_cli").glob("*.py"))
    if not files:
        fail("smalt-cli/smalt_cli/*.py: no python files found")
        return
    proc = subprocess.run(
        [py_cmd, "-m", "py_compile", *[str(f) for f in files]],
        capture_output=True, text=True, timeout=120,
    )
    if proc.returncode == 0:
        info(f"smalt-cli: py_compile clean over {len(files)} files")
        return
    errs = proc.stderr
    per_file = []
    for f in files:
        p = subprocess.run(
            [py_cmd, "-m", "py_compile", str(f)], capture_output=True, text=True
        )
        if p.returncode != 0:
            per_file.append((f.name, p.stderr.strip().splitlines()[-1] if p.stderr.strip() else "error"))
    for name, msg in per_file:
        fail(f"py_compile {name}: {msg}")
    if not per_file:
        fail(f"py_compile batch exit {proc.returncode}: {errs.strip()[:300]}")


# ---------------------------------------------------------------- check 5
def check_receipts():
    lanes_txt = LANES_MD.read_text(errors="replace") if LANES_MD.is_file() else ""
    if not lanes_txt:
        fail(f"{LANES_MD.relative_to(REPO)} missing or empty")
        return
    # receipt references in _LANES.md: receipts/<name>.md
    refs = re.findall(r"receipts/([A-Za-z0-9._\-]+\.md)", lanes_txt)
    missing = [r for r in sorted(set(refs)) if not (RECEIPTS_DIR / r).is_file()]
    if missing:
        for m in missing:
            fail(f"receipt referenced in _LANES.md but missing: receipts/{m}")
    else:
        info(
            f"receipts: {len(set(refs))} referenced in _LANES.md, all present"
            if refs
            else "receipts: _LANES.md references no receipts/<lane>.md files (nothing to fail on)"
        )
    if not RECEIPTS_DIR.is_dir():
        fail(f"{RECEIPTS_DIR.relative_to(REPO)} missing")
        return
    now = time.time()
    fresh = []
    for f in sorted(RECEIPTS_DIR.iterdir()):
        if f.is_file():
            age = now - f.stat().st_mtime
            if age <= SESSION_WINDOW_S:
                fresh.append(f.name)
    info(
        f"receipts freshness: {len(fresh)}/{len(list(RECEIPTS_DIR.iterdir()))} "
        f"file(s) inside the {SESSION_WINDOW_S // 3600}h session window"
    )


# ---------------------------------------------------------------- check 6
def check_gap_register():
    if not WIRE_PARITY.is_file():
        fail("docs/WIRE_PARITY.md missing")
        return
    text = WIRE_PARITY.read_text(errors="replace")
    # tokenized rows appear in either GAP(...) (register grammar) or
    # UNSUPPORTED(...) (row-prose variant); GAP-form is the canon form
    missing_tokens = []
    drifted = []
    for t in EXPECTED_TOKENS:
        if f"GAP({t.split('(', 1)[1]}" in text:
            continue
        if t in text:  # present but in UNSUPPORTED(...) form
            drifted.append(t)
        else:
            missing_tokens.append(t)
    if missing_tokens:
        for t in missing_tokens:
            fail(f"envelope/defect cross-check: GAP token absent from WIRE_PARITY.md: {t}")
    else:
        info(f"envelope/defect cross-check: all {len(EXPECTED_TOKENS)} expected gap tokens present")
    for t in drifted:
        warn(
            f"gap register grammar drift: {t} present only in UNSUPPORTED(...) form, "
            "not GAP(...) — register sync with lane 13"
        )
    # live tokens: strip strikethrough (~~...~~) CLOSED spans first
    live_text = re.sub(r"~~.*?~~", "", text, flags=re.DOTALL)
    live_tokens = set(re.findall(r"GAP\([a-z0-9\-]+\)", live_text))
    live_tokens.discard("GAP(name)")  # grammar example on the convention line
    # CLOSED-stamped tokens are retired, not live-open — a token followed by an
    # inline 'CLOSED' stamp (e.g. GAP(lro-no-failed-path)` CLOSED 2026-10-15) is
    # closed-with-receipt exactly like a ~~strikethrough~~ token (lane-13 census:
    # 5 CLOSED + 9 live-open UNSUPPORTED)
    live_tokens -= set(re.findall(r"GAP\([a-z0-9\-]+\)(?=` CLOSED)", live_text))
    closed = len(re.findall(r"CLOSED 2026-10-15", text))
    info(
        f"gap register sync: {closed} 'CLOSED 2026-10-15' stamps; "
        f"{len(live_tokens)} distinct live GAP(...) tokens in WIRE_PARITY.md "
        f"(lane-13 census: {EXPECTED_CLOSED_COUNT} CLOSED + {EXPECTED_UNSUPPORTED_COUNT} UNSUPPORTED)"
    )
    if len(live_tokens) != EXPECTED_UNSUPPORTED_COUNT:
        warn(
            f"gap register count drift: {len(live_tokens)} distinct live GAP tokens "
            f"vs census {EXPECTED_UNSUPPORTED_COUNT}"
        )


def main():
    print(f"doctor_dod (DoD-5) — repo {REPO}")
    check_stale_lock()
    check_lane_roots()
    check_workspace()
    check_cli()
    check_receipts()
    check_gap_register()
    print(
        f"\nsummary: {len(FAILURES)} FAIL, {len(WARNINGS)} WARN "
        "(exit 0 unless FAIL fired)"
    )
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
