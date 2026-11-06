"""Py-verify lane: shared substrate fixtures (substrate-ctl delegation).

Three private substrates, all leased through scripts/substrate-ctl — the
raw raw-flock/sweep boot internals (_sweep/_listener_pids/_is_beamish/
_ensure_boot) are retired: ONE boot implementation everywhere
(scripts/lib/substrate_boot.sh; design notes:
scripts/lib/substrate_boot_registry.md). Port law:
docs/reference/port_law.md (v-blocks are 7 ports incl. kafka).

  enforce  — block v1 (booted by run.sh): wf1/3/4/6/7/8 legs
  anon     — block v3, --auth anonymous: wf2 cosmos/blob legs
             (SharedKey/master-key auth is an anonymous-mode surface)
  throttle — block v4, SMALT_ARM_RATE_LIMIT=20 env bridge (KD-110):
             wf5
  mesg     — block v5, SMALT_SB_SHARED_KEY env pin: wf3 (CBS SAS needs the
             client-side key to match the boot)

Reuse-else-boot + identity guard (marker {pid, booted, auth, env_pin}) is
inside substrate-ctl; a marker env-pin mismatch is a FOREIGN incumbent —
the up refuses with exit 3 and the incumbent is never swept.
"""
import json
import os
import pathlib
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import base64

import pytest

REPO = str(pathlib.Path(__file__).resolve().parents[2])
SB_CTL = os.path.join(REPO, "scripts", "substrate-ctl")

ARM = os.environ.get("SMALT_PY_ARM", "http://127.0.0.1:39712")
EGRESS = os.environ.get("SMALT_PY_EGRESS", "http://127.0.0.1:39713")
TLS = os.environ.get("SMALT_PY_TLS", "https://127.0.0.1:39714")
AMQP = os.environ.get("SMALT_PY_AMQP_PORT", "39710")
EH_PORT = os.environ.get("SMALT_PY_EH_PORT", "39711")
CA_CERT = os.environ.get("SMALT_CERT_DIR", os.path.join(REPO, ".smalt/tls")) + "/ca-cert.pem"

# Port law v-family: 7 ports (kafka = 7th slot). Only the six classic faces
# are consumed here; the +6 kafka slot is part of the block claim.
ANON_PORTS = (39730, 39731, 39732, 39733, 39734, 39735, 39736)      # v3
THROTTLE_PORTS = (39740, 39741, 39742, 39743, 39744, 39745, 39746)  # v4
MESG_PORTS = (39750, 39751, 39752, 39753, 39754, 39755, 39756)      # v5

AUD = "https://management.azure.com"
SUB = "py-verify-sub"

sys.path.insert(0, os.path.dirname(__file__))

ssl_ctx = ssl.create_default_context(cafile=CA_CERT)


def http(method, url, body=None, headers=None, timeout=15, ctx=None):
    """Raw JSON wire request. Returns (status, parsed-or-raw-body)."""
    hdrs = {"Content-Type": "application/json"}
    hdrs.update(headers or {})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx or ssl_ctx) as r:
            payload = r.read().decode()
            return r.status, (json.loads(payload) if payload else None)
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, raw


def sts_token(tenant="py-verify-tenant"):
    """client_credentials grant -> (access_token, claims)."""
    body = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": "py-verify-lane",
        "client_secret": "py-verify-lane-secret",
    }).encode()
    req = urllib.request.Request(
        f"{ARM}/oauth2/v2.0/token", data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=15, context=ssl_ctx) as resp:
        tok = json.loads(resp.read())
    token = tok["access_token"]
    payload = token.split(".")[1]
    claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    return token, claims


def bearer():
    token, _ = sts_token()
    return {"Authorization": f"Bearer {token}"}


def pytest_configure(config):
    config.addinivalue_line("markers", "anonymous: needs anonymous-auth substrate")
    config.addinivalue_line("markers", "enforce: needs enforce-auth substrate")


def _loud_skip(exc, log_path):
    tail = ""
    try:
        tail = open(log_path).read()[-300:]
    except OSError:
        pass
    pytest.skip(f"substrate unavailable: {exc}; log tail: {tail}", allow_module_level=False)


class SbUpError(RuntimeError):
    """substrate-ctl up refused/failed. rc carries the ctl exit contract
    (1 refused / 2 died-or-timeout / 3 lock-timeout, port-occupied-after-
    sweep, or FOREIGN-INCUMBENT env-pin mismatch)."""

    def __init__(self, rc, detail):
        super().__init__("substrate-ctl up rc=%s: %s" % (rc, detail))
        self.rc = rc


def _ctl_up(block, auth, extra_env=None):
    """Lease a block through substrate-ctl (the ONE boot implementation).
    Returns the receipt dict (last stdout line, JSON). Raises SbUpError on
    any nonzero ctl exit."""
    env = dict(os.environ)
    if extra_env:
        env.update(extra_env)
    r = subprocess.run([SB_CTL, "up", "--block", block, "--auth", auth],
                       cwd=REPO, env=env, capture_output=True, text=True,
                       timeout=240)
    if r.returncode != 0:
        raise SbUpError(r.returncode, (r.stderr or r.stdout)[-300:])
    receipt = json.loads(r.stdout.strip().splitlines()[-1])
    return receipt


def _ctl_down(block):
    r = subprocess.run([SB_CTL, "down", "--block", block, "--mode", "sweep"],
                       cwd=REPO, capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        print(f"[conftest] down {block} rc={r.returncode}: {(r.stderr or '')[-200:]}",
              file=sys.stderr)


def _pytest_session_scoped_fixture(block, auth, extra_env, log):
    try:
        return _ctl_up(block, auth, extra_env)
    except SbUpError as e:
        _loud_skip(e, log)


@pytest.fixture(scope="session")
def enforce_arm():
    """v1 enforce substrate (booted by run.sh via substrate-ctl): reuse, else
    attempt substrate-ctl up, else loud skip."""
    st, _ = http("GET", f"{ARM}/metadata/endpoints", timeout=5)
    if st != 200:
        rc = subprocess.run(
            [SB_CTL, "up", "--block", "v1", "--auth", "enforce"],
            cwd=REPO, capture_output=True, text=True, timeout=240,
        )
        if rc.returncode != 0:
            _loud_skip(f"substrate-ctl up rc={rc.returncode}: {rc.stderr[-300:]}",
                       "/tmp/smalt-substrate-state/logs/v1.log")
    yield ARM


@pytest.fixture(scope="session")
def cred(enforce_arm):
    from azure.identity import CredentialUnavailableError

    from harness.credential import make_credential

    try:
        return make_credential(enforce_arm)
    except CredentialUnavailableError as e:  # azure leg loud-skip
        pytest.skip(f"credential unavailable: {e}")


@pytest.fixture(scope="session")
def anon_substrate():
    """Anonymous substrate for wf2 cosmos/blob (master-key/SharedKey surfaces).
    Block v3 (39730-39736), leased via substrate-ctl --auth anonymous with
    marker env-pin identity guard."""
    _pytest_session_scoped_fixture("v3", "anonymous", None,
                                   "/tmp/smalt-substrate-state/logs/v3.log")
    yield {"egress": f"http://127.0.0.1:{ANON_PORTS[3]}", "arm": f"http://127.0.0.1:{ANON_PORTS[2]}"}
    _ctl_down("v3")


@pytest.fixture(scope="session")
def throttle_arm():
    """Enforce substrate with arm_rate_limit=20 for wf5 — block v4
    (39740-39746), leased via substrate-ctl with the SMALT_ARM_RATE_LIMIT
    env bridge (KD-110: the ctl boot-eval put_envs integer SMALT_*_LIMIT
    values into app env). The bridge value is part of the marker env_pin,
    so a reuse without it is a foreign incumbent (typed refusal)."""
    _pytest_session_scoped_fixture("v4", "enforce", {"SMALT_ARM_RATE_LIMIT": "20"},
                                   "/tmp/smalt-substrate-state/logs/v4.log")
    yield f"http://127.0.0.1:{THROTTLE_PORTS[2]}"
    _ctl_down("v4")


MESG_SB_KEY = "cHktdmVyaWZ5LW1lc2ctbGFuZS1zYi1zaGFyZWQta2V5LTIwMjY="


@pytest.fixture(scope="session")
def messaging_substrate():
    """Enforce substrate with a KNOWN sb_shared_key (SMALT_SB_SHARED_KEY env
    pin — the unpinned ctl boot generates a random, unrecoverable key; CBS
    SAS verification needs the client-side key to match). Block v5
    (39750-39756). The pin is part of the marker env_pin."""
    _pytest_session_scoped_fixture(
        "v5", "enforce", {"SMALT_SB_SHARED_KEY": MESG_SB_KEY},
        "/tmp/smalt-substrate-state/logs/v5.log")
    yield {
        "arm": f"http://127.0.0.1:{MESG_PORTS[2]}",
        "amqp": MESG_PORTS[0],
        "eh": MESG_PORTS[1],
    }
    _ctl_down("v5")
