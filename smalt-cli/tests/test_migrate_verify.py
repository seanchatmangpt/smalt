"""smalt-migrate verify lane (PRD REQ-4.1 + REQ-4.2).

Per-service wire-fidelity checks against the LIVE loopback substrate
(ARM 9443 / egress 8443), plus the zero-egress assertion. Loud SKIP when the
substrate is down -- never a fake pass. Mirrors the wire faces of
tests/test_blob.py / test_cosmos.py / test_keyvault.py / test_servicebus.py.
"""
import json
import pathlib
import sys

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from smalt_cli.migrate import verify as mv

ARM = "http://127.0.0.1:9443"
EGRESS = "http://127.0.0.1:8443"


def _substrate_up():
    s = mv.WireSession()
    return mv.substrate_up(ARM, s, timeout=3)


pytestmark = pytest.mark.skipif(
    not _substrate_up(),
    reason="LOUD SKIP: substrate down on 127.0.0.1:9443 -- live legs need it",
)


@pytest.fixture(scope="module")
def session():
    s = mv.WireSession()
    tok = mv.bearer_token(ARM, s)
    yield s, tok


def _run_checks(checks):
    failed = [c for c in checks if not c["ok"] and not c.get("skip")]
    assert not failed, f"wire checks failed: {failed}"
    skips = [c for c in checks if c.get("skip")]
    if skips:
        pytest.skip("LOUD SKIP: " + "; ".join(c["detail"] for c in skips))


def test_blob_wire_gate(session):
    s, tok = session
    _run_checks(mv.verify_blob(s, tok, EGRESS))


def test_cosmos_wire_gate(session):
    s, tok = session
    _run_checks(mv.verify_cosmos(s, tok, EGRESS))


def test_kv_wire_gate(session):
    s, tok = session
    _run_checks(mv.verify_kv(s, tok, EGRESS))


def test_servicebus_wire_gate(session):
    s, tok = session
    _run_checks(mv.verify_servicebus(s, tok, ARM))


def test_zero_egress_loopback_only(session):
    """REQ-4.2: after all four legs, the touched-host set is loopback-only
    and assert_loopback() admits it. A foreign host must raise typed
    NonLoopbackEgress."""
    s, tok = session
    assert s.hosts, "no wire requests recorded -- gate did not run"
    assert all(h == "127.0.0.1" for h in s.hosts), sorted(set(s.hosts))
    assert s.assert_loopback() is True


def test_zero_egress_typed_violation_on_foreign_host():
    """Non-vacuity: a recorded non-loopback host is a typed refusal, never a
    silent pass."""
    s = mv.WireSession()
    s.hosts.append("example.com")
    with pytest.raises(mv.NonLoopbackEgress, match="NON-LOOPBACK EGRESS"):
        s.assert_loopback()


def test_run_receipt_end_to_end(tmp_path):
    """Full run(): all four services pass, receipt carries timings + hosts,
    zero_egress True."""
    receipt = mv.run(arm=ARM, egress=EGRESS)
    assert receipt["zero_egress"] is True
    assert set(receipt["hosts"]) == {"127.0.0.1"}
    services = {r["service"] for r in receipt["services"]}
    assert services == {"blob", "cosmos", "kv", "servicebus"}
    for row in receipt["services"]:
        assert row["ok"], row
        for c in row["checks"]:
            assert isinstance(c["ms"], (int, float)) and c["ms"] >= 0
    sb = [r for r in receipt["services"] if r["service"] == "servicebus"][0]
    # KD-131 CBS witness: the substrate boots with the dev_env-derived
    # per-host key, so the AMQP leg is a real send/receive pass. The typed
    # SbKeyUnavailable loud-skip remains the contract for key disagreement.
    assert sb.get("skipped") == [], sb
    sb_checks = {c["name"]: c for c in sb["checks"]}
    assert sb_checks["send_receive_one"]["ok"] is True, sb
    out = tmp_path / "migration-receipt-test.json"
    out.write_text(json.dumps(receipt, indent=2))
    assert out.exists() and json.loads(out.read_text())["zero_egress"] is True
