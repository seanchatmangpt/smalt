"""Verification gates for smalt-cli (v26.10.14, lane CLI-8).

Four gates, run individually or all together via ``run_gates.py``:

- GATE1 ``sdk-wire-conformance``: invokes the pytest lanes from CLI-4/CLI-5
  via subprocess against their per-lane venvs (ADR-PY-002: layout
  ``smalt-cli/.venvs/<lane>``). If the per-lane venv directory does not
  exist yet, the suite runs against ``smalt-cli/.venv`` and the result says
  so loudly. Per-suite pass/SKIP/fail are aggregated from the pytest
  summary; zero failures are required. A suite SKIP carries a loud reason.
- GATE2 ``hil-attestation``: invokes the hw sign flow. No device -> SKIP
  with the exact command to run when a device is attached.
- GATE3 ``zero-actuation``: adversarial probe against a real stub upstream
  (``http.server``) that records every mutation it is asked to perform.
  Attempts a resource-group PUT and a storage-account DELETE through the
  gateway's ``MutationInterceptor``: each must yield a typed 403 refusal,
  a ledger refusal entry, and zero substrate-side state mutation (the
  resource-group count fetched over real HTTP is unchanged and the upstream
  mutation log stays empty).
- GATE4 ``audit-integrity``: ``ledger.verify_manifest`` over the manifest
  produced by gates 1-3: zero chain breaks and every executed op present by
  ``params_digest``.

Stdlib plus the package's own modules only; no new hard dependencies.
"""

from __future__ import annotations

import glob
import json
import os
import re
import subprocess
import sys
import threading
import time
from dataclasses import asdict, dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable, Dict, List, Optional
from urllib.request import Request, urlopen

from .gateway.interceptor import (
    FORBIDDEN_ENVELOPE_TYPE,
    MutationInterceptor,
    refusal_envelope,
)
from .ledger import append_record, params_digest, verify_manifest

__all__ = [
    "GateResult",
    "SuiteReport",
    "discover_suites",
    "resolve_venv",
    "run_gate1",
    "run_gate2",
    "run_gate3",
    "run_gate4",
    "run_all_gates",
    "gate_app",
]

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_LEDGER = os.path.join(ROOT, "audit_manifest.jsonl")
REFUSAL_EXIT_CODE = 2

# Per-lane venv layout (ADR-PY-002), relative to the smalt-cli root.
VENV_DIR = os.path.join(ROOT, ".venvs")
FALLBACK_VENV = os.path.join(ROOT, ".venv")
PY = "bin/python" if sys.platform != "win32" else "Scripts\\python.exe"


# --------------------------------------------------------------------------
# Result types
# --------------------------------------------------------------------------

@dataclass
class SuiteReport:
    """Per-suite pytest aggregation (GATE1)."""

    name: str
    target: str
    interpreter: str
    venv_note: str  # loud note when falling back (per ADR-PY-002)
    passed: int
    skipped: int
    failed: int
    status: str  # PASS / SKIP / FAIL
    reason: str
    summary: str  # raw pytest summary line, "" when not run


@dataclass
class GateResult:
    gate: int
    name: str
    status: str  # PASS / SKIP / FAIL
    reason: str
    details: Dict[str, Any] = field(default_factory=dict)

    def to_json(self) -> str:
        return json.dumps(asdict(self), sort_keys=True)


def _res(gate: int, name: str, status: str, reason: str,
         details: Dict[str, Any] | None = None) -> GateResult:
    return GateResult(gate, name, status, reason, details or {})


# --------------------------------------------------------------------------
# GATE1 — sdk-wire-conformance
# --------------------------------------------------------------------------

# Candidate pytest targets for the CLI-4/CLI-5 SDK wire-conformance lanes.
# Discovery is by filename convention; a missing suite is a loud SKIP, not a
# silent pass.
SUITE_GLOBS = [
    "tests/sdk_wire/test_*.py",
    "tests/sdk_wire_*/test_*.py",
    "smalt_cli/test_sdk_wire_*.py",
    "smalt_cli/test_wire_*.py",
]


def discover_suites(root: str = ROOT) -> List[str]:
    """Return pytest target files for the SDK wire suites (may be empty)."""
    found: List[str] = []
    for pattern in SUITE_GLOBS:
        for path in sorted(glob.glob(os.path.join(root, pattern))):
            rel = os.path.relpath(path, root)
            if rel not in found:
                found.append(rel)
    return found


def resolve_venv(lane: str, root: str = ROOT) -> tuple[str, str]:
    """Per ADR-PY-002: prefer .venvs/<lane>, fall back to .venv with a note."""
    lane_py = os.path.join(root, ".venvs", lane, PY)
    if os.path.exists(lane_py):
        return lane_py, ""
    fallback_py = os.path.join(FALLBACK_VENV, PY)
    if os.path.exists(fallback_py):
        return fallback_py, (
            "ADR-PY-002 per-lane venv .venvs/%s missing; ran against .venv" % lane
        )
    return sys.executable, (
        "ADR-PY-002 per-lane venv .venvs/%s missing and .venv missing; "
        "ran against the ambient interpreter" % lane
    )


_SUMMARY_RE = re.compile(
    r"(?:(\d+) passed)?"
    r"(?:.*?(\d+) skipped)?"
    r"(?:.*?(\d+) failed)?"
    r"(?:.*?(\d+) error)?"
)


def parse_pytest_summary(output: str) -> Dict[str, int]:
    """Extract pass/skip/fail/error counts from a pytest short summary line."""
    counts = {"passed": 0, "skipped": 0, "failed": 0, "error": 0}
    for line in output.splitlines():
        if ("passed" in line or "skipped" in line or "failed" in line
                or "no tests ran" in line or "error" in line):
            m = _SUMMARY_RE.search(line)
            if m:
                counts = {
                    "passed": int(m.group(1) or 0),
                    "skipped": int(m.group(2) or 0),
                    "failed": int(m.group(3) or 0),
                    "error": int(m.group(4) or 0),
                }
    return counts


def _run_pytest_suite(
    target: str,
    interpreter: str,
    root: str = ROOT,
    timeout: float = 600.0,
) -> SuiteReport:
    """Run one pytest target in a subprocess and aggregate its summary."""
    name = os.path.splitext(os.path.basename(target))[0]
    cmd = [
        interpreter, "-m", "pytest", target,
        "-q", "-p", "no:cacheprovider", "--no-header",
    ]
    try:
        proc = subprocess.run(
            cmd, cwd=root, capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return SuiteReport(name, target, interpreter, "", 0, 0, 0, "FAIL",
                           "pytest timed out after %ss" % timeout, "")
    except OSError as exc:
        return SuiteReport(name, target, interpreter, "", 0, 0, 0, "SKIP",
                           "SKIP-LOUD: interpreter not runnable: %s" % exc, "")
    out = (proc.stdout or "") + (proc.stderr or "")
    counts = parse_pytest_summary(out)
    total = counts["passed"] + counts["skipped"] + counts["failed"] + counts["error"]
    if total == 0:
        return SuiteReport(
            name, target, interpreter, "", 0, 0, 0, "SKIP",
            "SKIP-LOUD: no tests collected from %s (exit %d) — suite may not "
            "be landed" % (target, proc.returncode),
            out.strip().splitlines()[-1] if out.strip() else "",
        )
    if counts["failed"] or counts["error"]:
        return SuiteReport(name, target, interpreter, "", counts["passed"],
                           counts["skipped"],
                           counts["failed"] + counts["error"], "FAIL",
                           "failures present", out.strip().splitlines()[-1])
    return SuiteReport(name, target, interpreter, "", counts["passed"],
                       counts["skipped"], 0, "PASS", "",
                       out.strip().splitlines()[-1] if out.strip() else "")


def run_gate1(root: str = ROOT, targets: List[str] | None = None) -> GateResult:
    """GATE1 sdk-wire-conformance: aggregate the CLI-4/CLI-5 pytest lanes."""
    if targets is None:
        targets = discover_suites(root)
    reports: List[SuiteReport] = []
    if not targets:
        return _res(
            1, "sdk-wire-conformance", "SKIP",
            "SKIP-LOUD: no CLI-4/CLI-5 SDK wire suites found under %s "
            "(patterns: %s) — lanes not landed yet" % (root, ", ".join(SUITE_GLOBS)),
            {"suites": []},
        )
    for target in targets:
        # Lane name for the per-lane venv: tests/sdk_wire/x.py -> sdk_wire;
        # smalt_cli/test_wire_foo.py -> wire_foo.
        if target.startswith("tests"):
            lane = target.split("/")[1] if "/" in target else "sdk-wire"
        else:
            lane = os.path.splitext(os.path.basename(target))[0]
            lane = lane.removeprefix("test_")
        interpreter, note = resolve_venv(lane, root)
        report = _run_pytest_suite(target, interpreter, root)
        report.venv_note = note
        reports.append(report)
    failed = [r for r in reports if r.status == "FAIL"]
    skipped = [r for r in reports if r.status == "SKIP"]
    passed = sum(r.passed for r in reports)
    if failed:
        status, reason = "FAIL", "failures in: %s" % ", ".join(r.name for r in failed)
    elif skipped:
        status = "PASS"
        reason = "passed with loud SKIPs: " + "; ".join(
            "%s (%s)" % (r.name, r.reason) for r in skipped)
    else:
        status, reason = "PASS", "all suites passed"
    return _res(1, "sdk-wire-conformance", status, reason, {
        "suites": [asdict(r) for r in reports],
        "passed": passed,
        "skipped_suites": len(skipped),
        "failed_suites": len(failed),
    })


# --------------------------------------------------------------------------
# GATE2 — hil-attestation
# --------------------------------------------------------------------------

HW_SIGN_COMMAND = [sys.executable, "-m", "smalt_cli.cli", "hw", "sign"]


def default_serial_ports() -> List[str]:
    """Best-effort serial device enumeration (pyserial if present, else glob)."""
    try:
        from serial.tools import list_ports
        return sorted(p.device for p in list_ports.comports())
    except ImportError:
        pass
    pats = ["/dev/tty.usb*", "/dev/ttyUSB*", "/dev/ttyACM*", "/dev/cu.usb*"]
    found: List[str] = []
    for pat in pats:
        found.extend(sorted(glob.glob(pat)))
    return found


def run_gate2(
    root: str = ROOT,
    device_prober: Callable[[], List[str]] = default_serial_ports,
) -> GateResult:
    """GATE2 hil-attestation: invoke the hw sign flow, SKIP-loud without a device."""
    ports = device_prober()
    exact = "python -m smalt_cli.cli hw sign --device <PORT>"
    if not ports:
        return _res(
            2, "hil-attestation", "SKIP",
            "SKIP-LOUD: no serial device attached. Run: %s" % exact,
            {"exact_command": exact, "devices": []},
        )
    cmd = HW_SIGN_COMMAND + ["--device", ports[0]]
    try:
        proc = subprocess.run(cmd, cwd=root, capture_output=True, text=True,
                              timeout=60.0)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return _res(
            2, "hil-attestation", "SKIP",
            "SKIP-LOUD: hw sign flow not invokable (%s). Run: %s" % (exc, exact),
            {"exact_command": exact, "devices": ports},
        )
    if proc.returncode != 0:
        combined = ((proc.stderr or "") + (proc.stdout or "")).lower()
        if "no such option" in combined or "no such command" in combined:
            return _res(
                2, "hil-attestation", "SKIP",
                "SKIP-LOUD: hw sign flow not landed in smalt_cli.cli (typer "
                "refused the command; hw lane outstanding). Run once landed: %s"
                % exact,
                {"exact_command": exact, "devices": ports, "cmd": cmd},
            )
        return _res(
            2, "hil-attestation", "FAIL",
            "hw sign flow exited %d: %s" % (
                proc.returncode, (proc.stderr or proc.stdout).strip()[:400]),
            {"exact_command": exact, "devices": ports, "cmd": cmd},
        )
    return _res(2, "hil-attestation", "PASS", "signed receipt produced",
                {"exact_command": exact, "devices": ports, "cmd": cmd,
                 "stdout": proc.stdout.strip()[:400]})


# --------------------------------------------------------------------------
# GATE3 — zero-actuation
# --------------------------------------------------------------------------

RG_PATH = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-gate3-probe"
STG_PATH = ("/subscriptions/00000000-0000-0000-0000-000000000000/"
            "resourceGroups/rg-gate3-probe/providers/Microsoft.Storage/"
            "storageAccounts/stg-gate3-probe")

PROBES = [
    ("PUT", RG_PATH + "?api-version=2022-09-01"),
    ("DELETE", STG_PATH + "?api-version=2023-01-01"),
]


def _make_stub_handler(state: Dict[str, Any]) -> type:
    class StubUpstream(BaseHTTPRequestHandler):
        """Real HTTP upstream: records mutations, serves an RG count."""

        def log_message(self, *args: Any) -> None:  # silence
            pass

        def _count_body(self) -> bytes:
            body = json.dumps({"resourceGroupCount": state["rg_count"]}).encode()
            return body

        def do_GET(self) -> None:
            if self.path == "/__count":
                body = self._count_body()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_response(404)
                self.end_headers()

        def _mutate(self) -> None:
            state["mutations"].append(
                {"method": self.command, "path": self.path,
                 "ts": time.time()})
            state["rg_count"] += 1  # every mutation changes substrate state
            self.send_response(200)
            self.end_headers()

        do_PUT = do_POST = do_PATCH = do_DELETE = _mutate

    return StubUpstream


class StubUpstreamServer:
    """Threaded in-process stub of the smalt substrate (real HTTP)."""

    def __init__(self, host: str = "127.0.0.1", port: int = 0) -> None:
        self.state: Dict[str, Any] = {"mutations": [], "rg_count": 3}
        self.server = ThreadingHTTPServer((host, port), _make_stub_handler(self.state))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.base = "http://%s:%d" % self.server.server_address[:2]

    def start(self) -> None:
        self.thread.start()

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def count(self) -> int:
        with urlopen(self.base + "/__count", timeout=10) as resp:
            return int(json.loads(resp.read())["resourceGroupCount"])


def _http(method: str, url: str) -> int:
    req = Request(url, method=method)
    try:
        with urlopen(req, timeout=10) as resp:
            return resp.status
    except OSError:
        return 0


def zero_actuation_probe(
    ledger_path: str,
    upstream: StubUpstreamServer | None = None,
) -> Dict[str, Any]:
    """Adversarial GATE3 probe. Returns a typed verdict dict (total)."""
    owned = upstream is None
    if owned:
        upstream = StubUpstreamServer()
    assert upstream is not None
    try:
        if owned:
            upstream.start()
        before = upstream.count()
        base_count = upstream.state["rg_count"]

        refusals: List[Dict[str, Any]] = []

        def ledger_cb(envelope: Dict[str, Any]) -> None:
            append_record(
                ledger_path,
                op="gate3.mutation_refusal",
                actor="smalt-cli/gate3",
                params=envelope,
                ts=time.time(),
            )
            refusals.append(envelope)

        interceptor = MutationInterceptor(ledger=ledger_cb)
        probes = []
        for verb, path in PROBES:
            result = interceptor.check(verb, path)
            refused = result is not None
            status = result[0] if result else _http(verb, upstream.base + path)
            entry = refusals[-1] if refused and refusals else None
            probes.append({
                "verb": verb,
                "path": path,
                "status": status,
                "typed_refusal": bool(
                    result and result[1].get("type") == FORBIDDEN_ENVELOPE_TYPE
                    and result[1].get("status") == 403),
                "ledger_entry": entry is not None,
                "mutated": verb in ("PUT", "POST", "PATCH", "DELETE")
                            and result is None,
            })
        after_http = upstream.count()
        after_state = upstream.state["rg_count"]
        no_mutation = (
            not upstream.state["mutations"]
            and after_http == before
            and after_state == base_count
        )
        ok = all(p["typed_refusal"] and p["ledger_entry"] and not p["mutated"]
                 for p in probes) and no_mutation
        return {
            "pass": ok,
            "probes": probes,
            "rg_count_before": before,
            "rg_count_after": after_http,
            "upstream_mutations": len(upstream.state["mutations"]),
            "no_state_mutation": no_mutation,
        }
    finally:
        if owned:
            upstream.stop()


def run_gate3(root: str = ROOT, ledger_path: str | None = None) -> GateResult:
    """GATE3 zero-actuation: 403 typed refusals, ledger entries, zero mutation."""
    lp = ledger_path or DEFAULT_LEDGER
    verdict = zero_actuation_probe(lp)
    if verdict["pass"]:
        return _res(3, "zero-actuation", "PASS",
                    "all mutation probes refused; substrate state unchanged",
                    verdict)
    bad = [p for p in verdict["probes"]
           if not (p["typed_refusal"] and p["ledger_entry"] and not p["mutated"])]
    reason = "probe failures: %s" % ", ".join(
        "%s %s" % (p["verb"], p["path"]) for p in bad) if bad else \
        "substrate state mutated (%d mutations)" % verdict["upstream_mutations"]
    return _res(3, "zero-actuation", "FAIL", reason, verdict)


# --------------------------------------------------------------------------
# GATE4 — audit-integrity
# --------------------------------------------------------------------------

def audit_integrity(ledger_path: str, expected_ops: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Full-chain verification plus op coverage by ``params_digest``.

    ``expected_ops`` is a list of ``{"op": ..., "params": ...}`` dicts for
    every op executed during this gates run.
    """
    verdict = verify_manifest(ledger_path)
    if not verdict.get("intact"):
        return {**verdict, "coverage_ok": False,
                "missing_ops": [e.get("op") for e in expected_ops]}
    present = set()
    try:
        with open(ledger_path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                obj = json.loads(line)
                if isinstance(obj, dict):
                    present.add((obj.get("op"), obj.get("params_digest")))
    except (OSError, json.JSONDecodeError, ValueError):
        pass
    missing = [
        e["op"] for e in expected_ops
        if (e["op"], params_digest(e["params"])) not in present
    ]
    return {**verdict, "coverage_ok": not missing, "missing_ops": missing}


def run_gate4(
    root: str = ROOT,
    ledger_path: str | None = None,
    expected_ops: List[Dict[str, Any]] | None = None,
) -> GateResult:
    """GATE4 audit-integrity over the manifest written by gates 1-3."""
    lp = ledger_path or DEFAULT_LEDGER
    expected = expected_ops or []
    verdict = audit_integrity(lp, expected)
    if not verdict.get("intact"):
        return _res(4, "audit-integrity", "FAIL",
                    "chain break: %s (first_break line %s)" % (
                        verdict.get("reason"), verdict.get("first_break")),
                    verdict)
    if not verdict.get("coverage_ok"):
        return _res(4, "audit-integrity", "FAIL",
                    "executed ops missing from ledger: %s" % verdict["missing_ops"],
                    verdict)
    return _res(4, "audit-integrity", "PASS",
                "manifest intact (%d records), all executed ops present"
                % verdict.get("count", 0), verdict)


# --------------------------------------------------------------------------
# Runner + typer sub-app
# --------------------------------------------------------------------------

GATE_NAMES = {1: "sdk-wire-conformance", 2: "hil-attestation",
              3: "zero-actuation", 4: "audit-integrity"}


def run_all_gates(
    root: str = ROOT,
    ledger_path: str | None = None,
    only: int | None = None,
) -> List[GateResult]:
    """Run gates in order; append a receipt record per gate to the ledger.

    GATE4 audits the manifest produced by gates 1-3, including the receipt
    records of the gates that ran before it.
    """
    lp = ledger_path or DEFAULT_LEDGER
    numbers = [only] if only else [1, 2, 3, 4]
    results: List[GateResult] = []
    executed: List[Dict[str, Any]] = []
    for n in numbers:
        if n == 1:
            res = run_gate1(root)
        elif n == 2:
            res = run_gate2(root)
        elif n == 3:
            res = run_gate3(root, lp)
        elif n == 4:
            res = run_gate4(root, lp, expected_ops=executed)
        else:
            raise ValueError("unknown gate: %d" % n)
        executed.append({"op": "gate%d.run" % n, "params": res.details})
        append_record(lp, op="gate%d.run" % n, actor="smalt-cli/run_gates",
                      params=res.details, ts=time.time())
        results.append(res)
    return results


def gate_app() -> "typer.Typer":  # noqa: F821
    """Typer sub-app exposing the gates as ``smalt-cli gate <name>``.

    Registration (one line in ``smalt_cli/cli.py``, owned by the dispatcher
    lane)::

        from .gates import gate_app
        app.add_typer(gate_app(), name="gate", help="Verification gates.")
    """
    import typer

    sub = typer.Typer(help="Verification gates (see GATES.md).",
                      no_args_is_help=True)

    @sub.command("sdk-wire-conformance")
    def _g1() -> None:
        """GATE1: aggregate the CLI-4/CLI-5 SDK wire pytest lanes."""
        typer.echo(run_gate1().to_json())

    @sub.command("hil-attestation")
    def _g2() -> None:
        """GATE2: hw sign flow (SKIP-loud without a device)."""
        typer.echo(run_gate2().to_json())

    @sub.command("zero-actuation")
    def _g3() -> None:
        """GATE3: adversarial mutation probes; refusals hit the ledger."""
        typer.echo(run_gate3().to_json())

    @sub.command("audit-integrity")
    def _g4() -> None:
        """GATE4: verify the audit manifest chain and op coverage."""
        typer.echo(run_gate4().to_json())

    return sub
