"""Real-collaborator tests for the verification gates (lane CLI-8).

Chicago style: GATE3 runs against a real in-process http.server upstream that
records mutations; GATE4 runs against real manifests (an intact one built
through ``ledger.append_record`` and a tampered one); GATE1's aggregation is
exercised through a real pytest subprocess. No mocks.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

import pytest

from . import ledger
from .gates import (
    DEFAULT_LEDGER,
    ROOT,
    StubUpstreamServer,
    _run_pytest_suite,
    audit_integrity,
    discover_suites,
    parse_pytest_summary,
    resolve_venv,
    run_gate1,
    run_gate2,
    run_gate3,
    run_gate4,
    run_all_gates,
    zero_actuation_probe,
)


# --------------------------------------------------------------------------
# GATE1
# --------------------------------------------------------------------------

def test_parse_pytest_summary_counts_all_classes():
    line = "3 passed, 2 skipped, 1 failed, 1 error in 0.05s"
    counts = parse_pytest_summary(line)
    assert counts == {"passed": 3, "skipped": 2, "failed": 1, "error": 1}


def test_parse_pytest_summary_passed_only():
    assert parse_pytest_summary("5 passed in 0.01s")["passed"] == 5
    assert parse_pytest_summary("5 passed in 0.01s")["failed"] == 0


def test_gate1_runs_real_pytest_suite_and_aggregates(tmp_path):
    (tmp_path / "test_fake_suite.py").write_text(
        "def test_ok():\n    assert 1 + 1 == 2\n\n"
        "def test_skip():\n    import pytest\n    pytest.skip('loud reason')\n"
    )
    report = _run_pytest_suite("test_fake_suite.py", sys.executable,
                               root=str(tmp_path))
    assert report.status == "PASS"
    assert report.passed == 1
    assert report.skipped == 1
    assert report.failed == 0


def test_gate1_failing_suite_is_fail(tmp_path):
    (tmp_path / "test_bad_suite.py").write_text(
        "def test_bad():\n    assert False\n"
    )
    report = _run_pytest_suite("test_bad_suite.py", sys.executable,
                               root=str(tmp_path))
    assert report.status == "FAIL"
    assert report.failed >= 1


def test_gate1_no_suites_is_loud_skip():
    res = run_gate1(root=os.devnull)  # a dir-less root finds nothing
    assert res.status == "SKIP"
    assert res.reason.startswith("SKIP-LOUD")


def test_gate1_empty_dir_root_is_loud_skip(tmp_path):
    res = run_gate1(root=str(tmp_path))
    assert res.status == "SKIP"
    assert "SKIP-LOUD" in res.reason


def test_gate1_real_repo_discovery_runs_or_skips_loud():
    # In the real repo: suites may or may not have landed; either a PASS with
    # loud notes or a loud SKIP is honest, never a silent pass.
    res = run_gate1(ROOT)
    assert res.status in ("PASS", "SKIP")
    if res.status == "SKIP":
        assert res.reason.startswith("SKIP-LOUD")


def test_resolve_venv_falls_back_to_venv_with_note():
    interp, note = resolve_venv("no-such-lane", ROOT)
    assert os.path.exists(interp)
    assert "ADR-PY-002" in note
    assert ".venvs/no-such-lane" in note


# --------------------------------------------------------------------------
# GATE2
# --------------------------------------------------------------------------

def test_gate2_skip_loud_with_exact_command_when_no_device():
    res = run_gate2(ROOT, device_prober=lambda: [])
    assert res.status == "SKIP"
    assert "SKIP-LOUD" in res.reason
    exact = res.details["exact_command"]
    assert exact == "python -m smalt_cli.cli hw sign --device <PORT>"
    assert "--device" in res.reason and exact in res.reason


def test_gate2_uninvokable_flow_is_loud_skip_not_pass():
    # --device is now accepted (hw lane S-5 landed the alias): a fake device
    # path is invoked for real, the open fails, and the gate FAILs loudly —
    # never a silent pass. (Pre-landing this court expected SKIP "not landed"
    # because typer refused --device; the landing flips the expectation.)
    res = run_gate2(ROOT, device_prober=lambda: ["/dev/tty.usb-fake"])
    assert res.status == "FAIL"
    assert "exited 1" in res.reason
    assert res.details["exact_command"] == "python -m smalt_cli.cli hw sign --device <PORT>"


# --------------------------------------------------------------------------
# GATE3 — real stub upstream, real HTTP, real ledger
# --------------------------------------------------------------------------

@pytest.fixture()
def stub_upstream():
    srv = StubUpstreamServer()
    srv.start()
    yield srv
    srv.stop()


def test_stub_upstream_records_mutations_and_serves_count(stub_upstream):
    from urllib.request import Request, urlopen
    with urlopen(stub_upstream.base + "/__count", timeout=10) as resp:
        assert json.loads(resp.read())["resourceGroupCount"] == 3
    req = Request(stub_upstream.base + "/rgs/x", method="PUT")
    with urlopen(req, timeout=10) as resp:
        assert resp.status == 200
    assert len(stub_upstream.state["mutations"]) == 1
    assert stub_upstream.state["rg_count"] == 4  # substrate state changed


def test_gate3_put_and_delete_are_refused_with_no_mutation(tmp_path, stub_upstream):
    lp = str(tmp_path / "audit_manifest.jsonl")
    verdict = zero_actuation_probe(lp, upstream=stub_upstream)
    assert verdict["pass"] is True
    assert len(verdict["probes"]) == 2
    for probe in verdict["probes"]:
        assert probe["status"] == 403
        assert probe["typed_refusal"] is True
        assert probe["ledger_entry"] is True
        assert probe["mutated"] is False
    assert verdict["upstream_mutations"] == 0
    assert verdict["no_state_mutation"] is True
    assert verdict["rg_count_before"] == verdict["rg_count_after"] == 3
    # The refusals really landed in the ledger.
    check = ledger.verify_manifest(lp)
    assert check["intact"] is True and check["count"] == 2
    with open(lp) as fh:
        ops = [json.loads(l)["op"] for l in fh]
    assert ops == ["gate3.mutation_refusal", "gate3.mutation_refusal"]


def test_gate3_run_result_pass(tmp_path):
    res = run_gate3(ROOT, ledger_path=str(tmp_path / "m.jsonl"))
    assert res.status == "PASS"
    assert res.details["no_state_mutation"] is True


def test_gate3_refusal_envelope_is_typed(tmp_path, stub_upstream):
    from .gateway.interceptor import FORBIDDEN_ENVELOPE_TYPE, refusal_envelope
    env = refusal_envelope("PUT", "/rgs/x")
    assert env["type"] == FORBIDDEN_ENVELOPE_TYPE
    assert env["status"] == 403
    assert env["error"]["code"] == "MutationRefused"


# --------------------------------------------------------------------------
# GATE4 — intact vs tampered manifest
# --------------------------------------------------------------------------

def test_gate4_intact_manifest_passes_with_full_coverage(tmp_path):
    lp = str(tmp_path / "m.jsonl")
    expected = [
        {"op": "gate1.run", "params": {"suites": []}},
        {"op": "gate3.mutation_refusal", "params": {"method": "PUT"}},
    ]
    for e in expected:
        ledger.append_record(lp, op=e["op"], actor="test", params=e["params"],
                             ts=1700000000.0)
    verdict = audit_integrity(lp, expected)
    assert verdict["intact"] is True
    assert verdict["coverage_ok"] is True
    assert verdict["missing_ops"] == []
    res = run_gate4(ROOT, ledger_path=lp, expected_ops=expected)
    assert res.status == "PASS"


def test_gate4_tampered_manifest_detects_chain_break(tmp_path):
    lp = str(tmp_path / "m.jsonl")
    for i in range(3):
        ledger.append_record(lp, op="op%d" % i, actor="test", params={"i": i},
                             ts=1700000000.0)
    # Tamper: rewrite an op in place without recomputing hashes.
    lines = open(lp).read().splitlines()
    obj = json.loads(lines[1])
    obj["op"] = "forged.op"
    lines[1] = json.dumps(obj, sort_keys=True, separators=(",", ":"))
    with open(lp, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    verdict = audit_integrity(lp, [])
    assert verdict["intact"] is False
    assert verdict["first_break"] == 1
    res = run_gate4(ROOT, ledger_path=lp)
    assert res.status == "FAIL"
    assert "chain break" in res.reason


def test_gate4_missing_executed_op_fails_coverage(tmp_path):
    lp = str(tmp_path / "m.jsonl")
    ledger.append_record(lp, op="gate3.mutation_refusal", actor="test",
                         params={"method": "PUT"}, ts=1700000000.0)
    expected = [{"op": "gate1.run", "params": {"x": 1}}]  # never landed
    verdict = audit_integrity(lp, expected)
    assert verdict["coverage_ok"] is False
    assert verdict["missing_ops"] == ["gate1.run"]
    res = run_gate4(ROOT, ledger_path=lp, expected_ops=expected)
    assert res.status == "FAIL"
    assert "gate1.run" in res.reason


def test_gate4_missing_manifest_is_typed_fail(tmp_path):
    res = run_gate4(ROOT, ledger_path=str(tmp_path / "nope.jsonl"))
    assert res.status == "FAIL"
    assert res.details["reason"] == "missing_manifest"
