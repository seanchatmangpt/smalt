"""WF9 - real confluent-kafka (librdkafka) legs against the smalt AZ-1 Kafka
wire face on lane-private substrates.

Blocks (v-formula 39700+10n+i, 7th slot = kafka at +6):
  v9  (39790-39796) - PLAINTEXT legs: produce -> consumer group
      (subscribe -> poll -> commit -> resume-after-commit).
  v11 (39810-39816) - SASL leg: kafka put_env [sasl_required: true,
      sasl_mechanisms: [:plain]]; SASL_PLAINTEXT + PLAIN.

Fail-closed rc contract:
  0 pass / 1 real client-or-wire failure (THE FINDING - never fixed here,
  exact errors printed; KD candidate recording is upstream) /
  2 substrate never up / 3 client absent (loud skip).

Every wait is a deadline-bounded poll on a real observable (no-sleep law).
Run with the scratch venv python (confluent-kafka resident there):
  /Users/sac/.claude/jobs/462babfd/tmp/hc-venv/venv/bin/python \\
    verification/py/test_wf9_kafka.py
"""
import os
import pathlib
import socket
import sys
import time

REPO = str(pathlib.Path(__file__).resolve().parents[2])
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from conftest import _kill, _port_open, _sweep  # noqa: E402

VENV_PY = "/Users/sac/.claude/jobs/462babfd/tmp/hc-venv/venv/bin/python"

# [amqp, eh, arm, egress, tls, mcp, kafka] - kafka at +6
PORTS_PLAIN = (39790, 39791, 39792, 39793, 39794, 39795, 39796)
PORTS_SASL = (39810, 39811, 39812, 39813, 39814, 39815, 39816)
pathlib.Path("/tmp/smalt-substrate-state/logs").mkdir(parents=True, exist_ok=True)
pathlib.Path("/tmp/smalt-substrate-state/markers").mkdir(parents=True, exist_ok=True)
pathlib.Path("/tmp/smalt-substrate-state/locks").mkdir(parents=True, exist_ok=True)
LOG_DIR = "/tmp/smalt-substrate-state/logs"
LOG_PLAIN = LOG_DIR + "/v9.log"
LOG_SASL = LOG_DIR + "/v11.log"


def _port_open(port, timeout=1.0):
    with socket.socket() as s:
        s.settimeout(timeout)
        return s.connect_ex(("127.0.0.1", port)) == 0


def _wait_ports(ports, label, deadline_s=120):
    """Deadline-bounded poll until all 7 ports answer; typed failure."""
    deadline = time.monotonic() + deadline_s
    while time.monotonic() < deadline:
        if all(_port_open(p, 0.25) for p in ports):
            return
        time.sleep(0.25)
    raise RuntimeError("SUBSTRATE_KAFKA_PORT_TIMEOUT: %s" % label)


def _boot(ports, log, marker, lock, extra_put_env):
    """Self-contained reuse-else-boot on the ASDF-pinned toolchain
    (conftest._ensure_boot hardcodes /opt/homebrew/bin/mix, which is Elixir
    1.19.5 — refused by mix.exs ~> 1.20; the asdf shim is 1.20.4-otp-29)."""
    import fcntl
    import json
    import signal
    import subprocess

    amqp, eh, arm, egress, tls, mcp, kafka = ports
    parts = [
        # >=32-byte SAS shared key (SasVerifier.validate_boot_key!/0 floor)
        'Application.put_env(:smalt, :sb_shared_key, '
        '"d2Y5LXNicy1rZXktMzItYnl0ZXMtbWluaW11bS1wYXNzMTIz");',
        'Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:%d");' % amqp,
        'Application.put_env(:smalt, :amqp_port, %d);' % amqp,
        'Application.put_env(:smalt, :event_hubs_port, %d);' % eh,
        'Application.put_env(:smalt, :arm_port, %d);' % arm,
        'Application.put_env(:smalt, :egress_port, %d);' % egress,
        'Application.put_env(:smalt, :arm_tls_port, %d);' % tls,
        'Application.put_env(:smalt, :mcp_port, %d);' % mcp,
        'Application.put_env(:smalt, :kafka_port, %d);' % kafka,
        'Application.put_env(:smalt, :auth_mode, :enforce);',
    ]
    parts.extend(extra_put_env)
    boot_eval = "".join(parts) + "{:ok, _} = Application.ensure_all_started(:smalt)"

    # WO-32 cordon: arm (index 2) and arm_tls (index 4) are NOT bound by a
    # BEAM-only private boot (posh owns 9443) — gate on the post-cordon set.
    bound = [p for i, p in enumerate(ports) if i not in (2, 4)]

    def healthy():
        return all(_port_open(p, 0.25) for p in bound)

    reused = False
    if healthy():
        return None, True
    fd = os.open(lock, os.O_CREAT | os.O_RDWR)
    deadline = time.time() + 20
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            if time.time() > deadline:
                os.close(fd)
                raise RuntimeError("SUBSTRATE_LOCK_TIMEOUT: %s" % lock)
            time.sleep(0.5)
    try:
        if healthy():
            return None, True
        if any(_port_open(p) for p in ports):
            if not _sweep(ports):
                raise RuntimeError("SUBSTRATE_SWEEP_BLOCKED: %s" % (ports,))
        env = dict(os.environ, MIX_ENV="test")
        logf = open(log, "w")
        proc = subprocess.Popen(
            [os.path.expanduser("~/.asdf/shims/mix"), "run", "--no-start",
             "--no-halt", "-e", boot_eval],
            cwd=REPO, env=env, stdout=logf, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        deadline = time.monotonic() + 240
        while time.monotonic() < deadline:
            rc_ = proc.poll()
            if rc_ is not None:
                tail = open(log).read()[-400:]
                raise RuntimeError("SUBSTRATE_DIED rc=%s: %s" % (rc_, tail))
            if healthy():
                with open(marker, "w") as mf:
                    json.dump({"pid": proc.pid, "booted": time.time()}, mf)
                _wait_ports(ports, log)
                return proc, False
            time.sleep(0.25)
        raise RuntimeError("SUBSTRATE_TIMEOUT: %s" % log)
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


# ---------------------------------------------------------------------------
# confluent-kafka legs
# ---------------------------------------------------------------------------

BROKER = lambda ports: "127.0.0.1:%d" % ports[6]  # noqa: E731
TOPIC = "wf9-topic"


def _producer(ports, sasl=False):
    from confluent_kafka import Producer

    conf = {
        "bootstrap.servers": BROKER(ports),
        "client.id": "wf9-producer",
        "api.version.request": True,
        "message.timeout.ms": 15000,
        "socket.timeout.ms": 10000,
    }
    if sasl:
        conf.update({
            "security.protocol": "SASL_PLAINTEXT",
            "sasl.mechanisms": "PLAIN",
            "sasl.username": "wf9-user",
            "sasl.password": "wf9-pass",
        })
    return Producer(conf)


def _consumer(ports, group, sasl=False):
    from confluent_kafka import Consumer

    conf = {
        "bootstrap.servers": BROKER(ports),
        "group.id": group,
        "client.id": "wf9-consumer-" + group,
        "auto.offset.reset": "earliest",
        "enable.auto.commit": False,
        "api.version.request": True,
        "session.timeout.ms": 10000,
        "socket.timeout.ms": 10000,
    }
    if sasl:
        conf.update({
            "security.protocol": "SASL_PLAINTEXT",
            "sasl.mechanisms": "PLAIN",
            "sasl.username": "wf9-user",
            "sasl.password": "wf9-pass",
        })
    return Consumer(conf)


def _deliver_flush(p, n, label):
    """Flush with a delivery-report deadline poll; any failed msg is a finding."""
    remaining = p.flush(20)
    if remaining != 0:
        raise RuntimeError("PRODUCE_NOT_DELIVERED(%s): %d undelivered" % (label, remaining))


def leg_produce_consume(ports, sasl=False):
    """produce N -> consumer group subscribe/poll -> commit -> resume."""
    from confluent_kafka import KafkaException, TopicPartition

    p = _producer(ports, sasl)
    payloads = ["wf9-msg-%02d" % i for i in range(10)]
    for pl in payloads:
        p.produce(TOPIC, value=pl.encode(), key=("k%d" % len(pl)).encode())
    _deliver_flush(p, 10, "plaintext" if not sasl else "sasl")

    c = _consumer(ports, "wf9-group", sasl)
    c.subscribe([TOPIC])
    got = []
    deadline = time.monotonic() + 60
    while len(got) < 10 and time.monotonic() < deadline:
        msg = c.poll(1.0)
        if msg is None:
            continue
        if msg.error():
            raise RuntimeError("CONSUME_ERROR: %s" % msg.error())
        got.append(msg.value().decode())
    if len(got) != 10:
        raise RuntimeError("CONSUME_SHORT: got %d/10 in 60s" % len(got))

    # commit current positions, close, resume-from-commit in the same group
    c.commit(asynchronous=False)
    c.close()

    c2 = _consumer(ports, "wf9-group", sasl)
    c2.subscribe([TOPIC])
    stale = []
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        msg = c2.poll(1.0)
        if msg is None:
            continue
        if msg.error():
            raise RuntimeError("RESUME_CONSUME_ERROR: %s" % msg.error())
        stale.append(msg.value().decode())
    c2.close()
    if stale:
        raise RuntimeError(
            "RESUME_REDELIVERED %d committed messages: %r" % (len(stale), stale[:3])
        )
    return sorted(got)


def main():
    try:
        import confluent_kafka  # noqa: F401
    except ImportError:
        print("WF9 SKIP-LOUD rc=3: confluent-kafka client absent (%s)" % VENV_PY)
        return 3
    procs = []
    findings = []
    substrate_fail = None
    rc = 0
    try:
        proc_plain, reused = _boot(
            PORTS_PLAIN, LOG_PLAIN,
            "/tmp/smalt-substrate-state/markers/wf9-v9.json",
            "/tmp/smalt-substrate-state/locks/wf9-v9.lock", [],
        )
        if proc_plain:
            procs.append(proc_plain)
        print("substrate v9 up (reused=%s) kafka=39796" % reused)
    except Exception as e:
        substrate_fail = "v9: %r" % (e,)
    if substrate_fail is None:
        try:
            got = leg_produce_consume(PORTS_PLAIN, sasl=False)
            print("PASS plaintext produce/consume/commit/resume: %d msgs %s..%s"
                  % (len(got), got[0], got[-1]))
        except Exception as e:
            findings.append("PLAINTEXT leg: %r" % (e,))

    try:
        proc_sasl, reused2 = _boot(
            PORTS_SASL, LOG_SASL,
            "/tmp/smalt-substrate-state/markers/wf9-v11.json",
            "/tmp/smalt-substrate-state/locks/wf9-v11.lock",
            ['Application.put_env(:smalt, :kafka, '
             '[sasl_required: true, sasl_mechanisms: [:plain]]);'],
        )
        if proc_sasl:
            procs.append(proc_sasl)
        print("substrate v11 up (reused=%s) kafka=39816 (sasl_required)" % reused2)
        try:
            got = leg_produce_consume(PORTS_SASL, sasl=True)
            print("PASS sasl produce/consume/commit/resume: %d msgs %s..%s"
                  % (len(got), got[0], got[-1]))
        except Exception as e:
            findings.append("SASL leg: %r" % (e,))
    except Exception as e:
        substrate_fail = (substrate_fail or "") + " v11: %r" % (e,)

    for pr in procs:
        _kill(pr)
    for f in findings:
        print("FAIL " + f)
    if substrate_fail:
        print("FAIL substrate: %s" % substrate_fail)
        if not findings:
            rc = 2
        else:
            rc = 1 if findings else 2
    if findings and rc == 0:
        rc = 1
    print("WF9 rc=%d" % rc)
    return rc


if __name__ == "__main__":
    sys.exit(main())
