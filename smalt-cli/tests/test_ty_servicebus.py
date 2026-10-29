"""azcli3 Typer lane — servicebus group court (real wire).

Queue create via the ARM registry face (Bearer from the emulator STS), then
send/receive over AMQP :5672 DIRECT (azure-servicebus SDK; no relay — the CLI
is on-host, and the MCP 9545 face is read-only by law). Registered AMQP
divergences (KD-21/KD-77 class) surface as loud skips, mirroring
tests/test_servicebus.py.
"""
import time
import uuid

import pytest
from typer.testing import CliRunner

pytestmark = [pytest.mark.enforce, pytest.mark.usefixtures("enforce_substrate")]

import conftest  # noqa: E402
from smalt_cli.cli import app  # noqa: E402

runner = CliRunner()
UNIQ = f"{int(time.time() * 1000)}{uuid.uuid4().hex[:6]}"
SUB, RG, NS = "ty-sub", f"ty-rg-{UNIQ}", f"ty-ns-{UNIQ}"
Q = f"ty-q-{UNIQ}"
Q2 = f"ty-azq-{UNIQ}"


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    monkeypatch.setenv("SMALT_ARM", conftest.ARM)
    monkeypatch.setenv("SMALT_AMQP", "127.0.0.1:%d" % conftest._ENF_AMQP_P)
    monkeypatch.setenv("SMALT_SB_SHARED_KEY", conftest._ENFORCE_SB_KEY)


def _kd_skip(exc_output: str):
    if ("socket-error" in exc_output or "unexpectedly closed" in exc_output
            or "object of type 'UUID'" in exc_output
            or "Target.__new__" in exc_output):
        pytest.skip("KD-21/KD-77 registered AMQP wire divergence "
                    "(docs/jira/v26.10.14/KNOWN_DIVERGENCES.md)")


def test_queue_send_receive_roundtrip():
    r = runner.invoke(app, ["servicebus", "queue-create", "--name", Q,
                            "--namespace", NS, "--resource-group", RG,
                            "--subscription", SUB, "-o", "json"])
    assert r.exit_code == 0, r.output

    r = runner.invoke(app, ["servicebus", "send", Q, "typer-hello", "-o", "json"])
    if r.exit_code != 0:
        _kd_skip(r.output)
    assert '"transport": "amqp:5672"' in r.output

    r = runner.invoke(app, ["servicebus", "receive", Q, "--max", "5", "-o", "json"])
    if r.exit_code != 0:
        _kd_skip(r.output)
    assert "typer-hello" in r.output


def test_queue_create_az_parity_short_n_is_entity_name():
    """az-parity leg (EXPL12-3): `queue-create -n myqueue` against the
    namespace DEFAULT (cli-ns, no --namespace given) -> 201, and the
    entity materializes for AMQP send. The old collision shape (POS queue
    name; `-n` = namespace) must be gone from the help."""
    r = runner.invoke(app, ["servicebus", "queue-create", "-n", Q2,
                            "--resource-group", RG, "--subscription", SUB,
                            "-o", "json"])
    assert r.exit_code == 0, r.output
    assert '"status": 201' in r.output, r.output

    # Materialized entity on the default namespace carries real traffic.
    r = runner.invoke(app, ["servicebus", "send", Q2, "az-parity", "-o", "json"])
    if r.exit_code != 0:
        _kd_skip(r.output)
    assert '"transport": "amqp:5672"' in r.output

    # Falsifier: `-n` no longer binds the namespace; a bare positional is
    # refused, and help carries no --entity / no `-n`-is-namespace shape.
    r = runner.invoke(app, ["servicebus", "queue-create", Q2])
    assert r.exit_code != 0, r.output
    r = runner.invoke(app, ["servicebus", "queue-create", "--help"])
    assert "--entity" not in r.output
    assert "--name" in r.output and "-n" in r.output
    assert "--namespace-name" in r.output


def test_topic_subscription_create_az_parity():
    """az-parity legs (EXPL12-D): topic-create and subscription-create bind
    `-n` to the ENTITY name (topic / subscription), namespace rides
    `--namespace-name` (default cli-ns) — the EXPL12-3 `-n` collision class
    is absent from both help surfaces."""
    T, S = f"ty-t-{UNIQ}", f"ty-s-{UNIQ}"

    r = runner.invoke(app, ["servicebus", "topic-create", "-n", T,
                            "--resource-group", RG, "--subscription", SUB,
                            "-o", "json"])
    assert r.exit_code == 0, r.output
    assert '"status": 201' in r.output, r.output

    r = runner.invoke(app, ["servicebus", "subscription-create", "-n", S,
                            "--topic-name", T,
                            "--resource-group", RG, "--subscription", SUB,
                            "-o", "json"])
    assert r.exit_code == 0, r.output
    assert '"status": 201' in r.output, r.output

    # Falsifier: no `-n`-is-namespace shape on either help surface.
    for cmd in ("topic-create", "subscription-create"):
        r = runner.invoke(app, ["servicebus", cmd, "--help"])
        assert r.exit_code == 0, r.output
        assert "-n" in r.output and "--name" in r.output
        assert "--namespace-name" in r.output
        assert "--entity" not in r.output
