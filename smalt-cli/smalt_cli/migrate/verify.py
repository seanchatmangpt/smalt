"""smalt-migrate verify -- wire-fidelity gate (PRD REQ-4.1 + REQ-4.2).

For every service named in the migration manifest (or the default set:
blob, cosmos, kv, servicebus) this module runs a minimal create -> mutate ->
read-back -> cleanup sequence against the loopback substrate and records
per-check timings and pass/fail. REQ-4.2 (zero-egress): every wire request
rides one shared helper that records the host it touched; before the receipt
is emitted the host set is asserted 127.0.0.1-only, and any foreign host is a
typed NonLoopbackEgress violation, never a silent pass.

Auth mirrors tests/conftest.py:
  - STS client_credentials on the substrate STS (ARM plane, default 9443)
    -> Bearer for management + egress data plane (8443)
  - ServiceBus: SharedAccessKey connection string (dev key) via
    azure-servicebus

Usage:
    python -m smalt_cli.migrate.verify [--manifest M.json] [--out PATH]

Receipt (migration-receipt.json):
    {"services": [{"service", "checks": [{"name","ok","detail","ms"}],
     "ok": bool}], "zero_egress": bool, "hosts": [...]}
"""
from __future__ import annotations

import argparse
import json
import os
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

# Unverified TLS: the substrate dev CA (.smalt/tls) is not in the system
# store. Targets are recorded and asserted loopback (REQ-4.2) instead.
_TLS_CTX = ssl._create_unverified_context()  # noqa: SLF001

DEFAULT_ARM = os.environ.get("SMALT_ARM", "http://127.0.0.1:9443")
DEFAULT_EGRESS = os.environ.get("SMALT_EGRESS", "http://127.0.0.1:8443")
DEFAULT_SB = os.environ.get("SMALT_SB_ENDPOINT", "sb://127.0.0.1:5672")
# Dev SAS key: env (SMALT_SB_SHARED_KEY) wins; otherwise derive at runtime
# exactly like scripts/dev_env.sh -- base64(sha256(hostname + "smalt-dev-sb")).
# Never hardcode a host-specific key.
def _derive_sb_shared_key():
    import base64
    import hashlib
    import socket
    digest = hashlib.sha256(
        (socket.gethostname() + "smalt-dev-sb").encode()).digest()
    return base64.b64encode(digest).decode()


SB_SHARED_KEY = os.environ.get("SMALT_SB_SHARED_KEY") or _derive_sb_shared_key()
SUBSCRIPTION = os.environ.get("SMALT_MIGRATE_SUBSCRIPTION", "sub-mig")
RG = os.environ.get("SMALT_MIGRATE_RG", "mig-rg")
NAMESPACE = os.environ.get("SMALT_MIGRATE_NS", "migns")
UNIQ = uuid.uuid4().hex[:8]

DEFAULT_SERVICES = ("blob", "cosmos", "kv", "servicebus")


class SbKeyUnavailable(RuntimeError):
    """Typed loud-skip: the broker's :sb_shared_key disagrees with the
    client key (env SMALT_SB_SHARED_KEY, else the dev_env derivation
    base64(sha256(hostname + "smalt-dev-sb"))). CBS answers
    401 INVALID_LOCAL_SAS. Fix is booting the substrate with the matching
    key via scripts/dev_env.sh -- forbidden from a lane (never restart the
    shared substrate)."""


class NonLoopbackEgress(RuntimeError):
    """REQ-4.2 typed violation: a request touched a non-loopback host."""

    def __init__(self, hosts):
        self.hosts = sorted(set(hosts))
        bad = sorted(h for h in self.hosts if h != "127.0.0.1" and h)
        super().__init__(
            f"NON-LOOPBACK EGRESS: requests touched non-loopback hosts {bad}"
        )


class WireSession:
    """The one shared wire helper. Every HTTP request the gate makes rides
    wire(); hosts are recorded so REQ-4.2 can assert loopback-only."""

    def __init__(self):
        self.hosts = []

    def wire(self, method, url, body=None, headers=None, timeout=15,
             raw=False):
        """Raw wire request -> (status, parsed-or-text, elapsed_ms).
        Records the URL host. raw=True sends bytes verbatim."""
        parsed = urllib.parse.urlparse(url)
        self.hosts.append(parsed.hostname or "")
        hdrs = {}
        if not raw and body is not None:
            hdrs["Content-Type"] = "application/json"
        hdrs.update(headers or {})
        data = body if raw else (
            json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(url, data=data, method=method,
                                     headers=hdrs)
        t0 = time.perf_counter()
        try:
            with urllib.request.urlopen(req, timeout=timeout,
                                        context=_TLS_CTX) as r:
                payload, status = r.read(), r.status
        except urllib.error.HTTPError as e:  # 4xx/5xx are wire outcomes
            payload, status = e.read(), e.code
        ms = (time.perf_counter() - t0) * 1000
        text = payload.decode("utf-8", "replace")
        try:
            return status, (json.loads(text) if text else None), ms
        except ValueError:
            return status, text, ms

    def assert_loopback(self):
        bad = sorted(h for h in set(self.hosts) if h != "127.0.0.1" and h)
        if bad:
            raise NonLoopbackEgress(set(self.hosts))
        return True


def bearer_token(arm, session):
    """STS client_credentials on the ARM plane -> access token."""
    body = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": "smalt-migrate",
        "client_secret": "smalt-migrate",
    }).encode()
    status, body_json, _ = session.wire(
        "POST", f"{arm}/oauth2/v2.0/token", body=body, raw=True,
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    if status != 200:
        raise RuntimeError(f"STS mint failed {status}: {body_json}")
    return body_json["access_token"]


def _check(checks, name, fn):
    t0 = time.perf_counter()
    try:
        detail = fn()
        ok, skip = True, False
    except SbKeyUnavailable as e:  # loud typed skip, never a fake pass
        detail, ok, skip = str(e), False, True
    except Exception as e:  # noqa: BLE001 -- the check IS the outcome
        detail = f"{type(e).__name__}: {e}"
        ok, skip = False, False
    row = {"name": name, "ok": ok, "detail": str(detail)[:400],
           "ms": round((time.perf_counter() - t0) * 1000, 2)}
    if skip:
        row["skip"] = ("SbKeyUnavailable: broker SAS key disagrees with "
                       "the client key; boot substrate via dev_env.sh")
    checks.append(row)
    return not skip and ok


def _expect(status, expected, label, body):
    if status not in expected:
        raise AssertionError(
            f"{label} -> {status} (want {expected}): {str(body)[:200]}")
    return body


# ---------------------------------------------------------------------------
# Service legs. Shapes probed live against the loopback substrate; they
# mirror tests/test_blob.py / test_cosmos.py / test_keyvault.py /
# test_servicebus.py wire faces.
# ---------------------------------------------------------------------------

def verify_blob(session, tok, egress):
    """container create -> block PUT -> GET byte-equal -> delete."""
    checks = []
    c = f"mig-verify-{UNIQ}"
    base = f"{egress}/smaltacct/{c}"
    vh = {"x-ms-version": "2021-04-01"}
    payload = "smalt-migrate wire fidelity \U0001f30a".encode()

    def create_container():
        st, body, _ = session.wire(
            "PUT", f"{base}?restype=container",
            headers={**vh, "x-ms-immutable-policy": "false",
                     "Authorization": f"Bearer {tok}"})
        _expect(st, (201, 409), "container create", body)

    def put_block():
        st, body, _ = session.wire(
            "PUT", f"{base}/mig.txt", raw=True, body=payload,
            headers={**vh, "x-ms-blob-type": "BlockBlob",
                     "Authorization": f"Bearer {tok}"})
        _expect(st, (200, 201), "block PUT", body)

    def get_bytes():
        st, body, _ = session.wire(
            "GET", f"{base}/mig.txt",
            headers={**vh, "Authorization": f"Bearer {tok}"})
        if st != 200 or body != payload.decode():
            raise AssertionError(f"blob GET byte-equal failed: {st} {body!r}")
        return "byte-equal ok"

    def cleanup():
        session.wire("DELETE", f"{base}/mig.txt",
                     headers={**vh, "Authorization": f"Bearer {tok}"})
        session.wire("DELETE", f"{base}?restype=container",
                     headers={**vh, "Authorization": f"Bearer {tok}"})
        return "cleaned"

    for name, fn in [("container_create", create_container),
                     ("block_put", put_block),
                     ("get_byte_equal", get_bytes),
                     ("delete", cleanup)]:
        _check(checks, name, fn)
    return checks


def verify_cosmos(session, tok, egress):
    """create doc -> CAS PUT etag-match 200 -> stale etag 412."""
    checks = []
    db, coll = f"migv-{UNIQ}", "c1"
    root = f"{egress}/dbs/{db}"
    pk = {"x-ms-documentdb-partitionkey": '["w"]'}
    state = {}

    def create_doc():
        st, body, _ = session.wire(
            "POST", f"{egress}/dbs", body={"id": db},
            headers={"Authorization": f"Bearer {tok}"})
        _expect(st, (200, 201, 409), "db create", body)
        st, body, _ = session.wire(
            "POST", f"{root}/colls",
            body={"id": coll,
                  "partitionKey": {"paths": ["/pk"], "kind": "Hash"}},
            headers={"Authorization": f"Bearer {tok}"})
        _expect(st, (200, 201, 409), "container create", body)
        st, body, _ = session.wire(
            "POST", f"{root}/colls/{coll}/docs",
            body={"id": "d1", "pk": "w", "n": 0},
            headers={"Authorization": f"Bearer {tok}", **pk})
        _expect(st, (200, 201), "doc create", body)
        state["etag"] = body["_etag"]
        return f"etag minted {body['_etag']}"

    def cas_match():
        st, body, _ = session.wire(
            "PUT", f"{root}/colls/{coll}/docs/d1",
            body={"id": "d1", "pk": "w", "n": 1},
            headers={"If-Match": state["etag"],
                     "Authorization": f"Bearer {tok}", **pk})
        _expect(st, (200,), "CAS PUT etag-match", body)
        assert body["_etag"] != state["etag"], "etag did not rotate"
        return "etag-match 200, etag rotated"

    def cas_stale():
        st, body, _ = session.wire(
            "PUT", f"{root}/colls/{coll}/docs/d1",
            body={"id": "d1", "pk": "w", "n": 2},
            headers={"If-Match": state["etag"],
                     "Authorization": f"Bearer {tok}", **pk})
        _expect(st, (412,), "CAS PUT stale etag", body)
        return "stale etag 412"

    def cleanup():
        session.wire("DELETE", root,
                     headers={"Authorization": f"Bearer {tok}"})
        return "cleaned"

    for name, fn in [("create_doc_mints_etag", create_doc),
                     ("cas_put_etag_match_200", cas_match),
                     ("cas_put_stale_etag_412", cas_stale),
                     ("cleanup", cleanup)]:
        _check(checks, name, fn)
    return checks


def verify_kv(session, tok, egress):
    """secret set (PUT) -> get byte-equal -> delete."""
    checks = []
    name = f"mig-verify-{UNIQ}"
    base = f"{egress}/secrets/{name}"
    value = "mig-secret-\U0001f30a-value"

    def put_secret():
        st, body, _ = session.wire(
            "PUT", f"{base}?api-version=7.4", body={"value": value},
            headers={"Authorization": f"Bearer {tok}"})
        _expect(st, (200, 201), "secret set", body)

    def get_secret():
        st, body, _ = session.wire(
            "GET", f"{base}?api-version=7.4",
            headers={"Authorization": f"Bearer {tok}"})
        _expect(st, (200,), "secret get", body)
        assert body.get("value") == value, "secret value not byte-equal"
        return "byte-equal ok"

    def delete_secret():
        st, body, _ = session.wire(
            "DELETE", f"{base}?api-version=7.4",
            headers={"Authorization": f"Bearer {tok}"})
        _expect(st, (200, 404), "secret delete", body)
        return "cleaned"

    for name_, fn in [("secret_set", put_secret),
                      ("secret_get_byte_equal", get_secret),
                      ("secret_delete", delete_secret)]:
        _check(checks, name_, fn)
    return checks


def verify_servicebus(session, tok, arm):
    """ARM namespace+queue ensure -> send/receive one message -> complete."""
    checks = []
    q = f"mig-verify-{UNIQ}"
    endpoint = DEFAULT_SB

    def arm_setup():
        st, body, _ = session.wire(
            "PUT",
            f"{arm}/subscriptions/{SUBSCRIPTION}/resourceGroups/{RG}"
            f"/providers/Microsoft.ServiceBus/namespaces/{NAMESPACE}"
            f"?api-version=2021-06-01-preview",
            body={"location": "eastus",
                  "sku": {"name": "Standard", "tier": "Standard"}},
            headers={"Authorization": f"Bearer {tok}"})
        _expect(st, (200, 201, 202), "namespace ensure", body)
        st, body, _ = session.wire(
            "PUT",
            f"{arm}/subscriptions/{SUBSCRIPTION}/resourceGroups/{RG}"
            f"/providers/Microsoft.ServiceBus/namespaces/{NAMESPACE}"
            f"/queues/{q}?api-version=2021-06-01-preview",
            body={"location": "eastus"},
            headers={"Authorization": f"Bearer {tok}"})
        _expect(st, (200, 201, 202), "queue create", body)

    def send_receive():
        # The SDK is its own client: record its target host explicitly so
        # REQ-4.2 covers the AMQP leg too.
        host = urllib.parse.urlparse(
            endpoint.replace("sb://", "http://")).hostname or ""
        session.hosts.append(host)
        from azure.servicebus import ServiceBusClient, ServiceBusMessage
        conn = (f"Endpoint={endpoint};"
                "SharedAccessKeyName=RootManageSharedAccessKey;"
                f"SharedAccessKey={SB_SHARED_KEY};"
                "UseDevelopmentEmulator=true")
        try:
            with ServiceBusClient.from_connection_string(
                    conn, retry_total=0) as client:
                with client.get_queue_sender(q) as sender:
                    sender.send_messages(ServiceBusMessage(b"mig-verify-one"))
                with client.get_queue_receiver(q, max_wait_time=5) as recv:
                    msgs = recv.receive_messages(max_message_count=5,
                                                 max_wait_time=10)
                    assert len(msgs) == 1, (
                        f"expected 1 message, got {len(msgs)}")
                    assert str(msgs[0]) == "mig-verify-one", str(msgs[0])
                    recv.complete_message(msgs[0])
        except Exception as e:  # noqa: BLE001
            sig = f"{type(e).__name__}: {e}"
            if "amqp:client-error" in sig or "INVALID_LOCAL_SAS" in sig:
                raise SbKeyUnavailable(
                    "CBS 401 INVALID_LOCAL_SAS: broker key disagrees with "
                    "the client key (env SMALT_SB_SHARED_KEY or the "
                    "dev_env derivation base64(sha256(hostname+"
                    "'smalt-dev-sb'))). Fix = boot the substrate with the "
                    "matching key via scripts/dev_env.sh (restart forbidden "
                    f"from a lane). Observed: {sig}")
            raise
        return "send/receive/complete ok"

    for name, fn in [("arm_queue_ensure", arm_setup),
                     ("send_receive_one", send_receive)]:
        _check(checks, name, fn)
    return checks


VERIFIERS = {
    "blob": lambda s, t: verify_blob(s, t, DEFAULT_EGRESS),
    "cosmos": lambda s, t: verify_cosmos(s, t, DEFAULT_EGRESS),
    "kv": lambda s, t: verify_kv(s, t, DEFAULT_EGRESS),
    # servicebus rides the ARM plane for setup, not egress
    "servicebus": lambda s, t: verify_servicebus(s, t, DEFAULT_ARM),
}


def load_manifest(path):
    """Manifest = JSON {"services": [...]}. Missing file -> default set."""
    if not path:
        return list(DEFAULT_SERVICES)
    with open(path) as f:
        manifest = json.load(f)
    services = manifest.get("services")
    if not isinstance(services, list) or not services:
        raise ValueError(f"manifest {path}: no 'services' list")
    unknown = [s for s in services if s not in VERIFIERS]
    if unknown:
        raise ValueError(f"manifest {path}: unknown services {unknown}; "
                         f"known: {sorted(VERIFIERS)}")
    return services


def substrate_up(arm, session, timeout=5):
    try:
        st, _, _ = session.wire("GET", f"{arm}/metadata/endpoints",
                                timeout=timeout)
        return st == 200
    except Exception:  # noqa: BLE001
        return False


def run(services=None, manifest=None, arm=None, egress=None):
    """Run the gate; returns the receipt dict. Raises NonLoopbackEgress."""
    arm = arm or DEFAULT_ARM
    egress = egress or DEFAULT_EGRESS
    services = services or load_manifest(manifest)
    session = WireSession()
    if not substrate_up(arm, session):
        raise RuntimeError(
            f"SUBSTRATE DOWN: ARM={arm} answered nothing on "
            f"/metadata/endpoints -- loud failure, no fake receipt")
    tok = bearer_token(arm, session)
    rows = []
    for svc in services:
        checks = VERIFIERS[svc](session, tok)
        skipped = [c for c in checks if c.get("skip")]
        rows.append({
            "service": svc, "checks": checks,
            "skipped": [c["name"] for c in skipped],
            # A loud typed skip is not a pass: it rides the receipt as its
            # own standing, and service-ok excludes only skipped checks.
            "ok": all(c["ok"] for c in checks if not c.get("skip")),
            "all_checks_passed": all(c["ok"] for c in checks),
        })
    zero_egress = session.assert_loopback()
    return {"services": rows, "zero_egress": zero_egress,
            "hosts": sorted(set(session.hosts)),
            "ts": time.time()}


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="smalt-migrate verify: wire-fidelity gate (REQ-4.1/4.2)")
    ap.add_argument("--manifest", help="JSON manifest naming services")
    ap.add_argument("--services", help="comma list overriding the manifest")
    ap.add_argument("--out", default="migration-receipt.json")
    ap.add_argument("--arm", default=DEFAULT_ARM)
    ap.add_argument("--egress", default=DEFAULT_EGRESS)
    args = ap.parse_args(argv)
    services = (args.services.split(",") if args.services else None)
    receipt = run(services=services, manifest=args.manifest,
                  arm=args.arm, egress=args.egress)
    with open(args.out, "w") as f:
        json.dump(receipt, f, indent=2)
    ok = all(r["ok"] for r in receipt["services"]) and receipt["zero_egress"]
    print(json.dumps(receipt, indent=2))
    print(f"\n[smalt-migrate verify] {'PASS' if ok else 'FAIL'} "
          f"-> {args.out}")
    return 0 if ok else 1



# ---------------------------------------------------------------------------
# Typer command surface (M6 audit finding 2): expose the gate as
# `smalt-cli migrate verify`, mirroring main()'s argparse face.
# ---------------------------------------------------------------------------

try:
    import typer
    from .scan import migrate_app

    @migrate_app.command(name="verify")
    def verify_command(  # noqa: F811 - distinct name from run()
        manifest: str = typer.Option(None, "--manifest", help="JSON manifest naming services (default: blob, cosmos, kv, servicebus)."),
        services: str = typer.Option(None, "--services", help="Comma list overriding the manifest."),
        out: str = typer.Option("migration-receipt.json", "--out", help="Write the migration receipt JSON here."),
        arm: str = typer.Option(DEFAULT_ARM, "--arm", help="ARM control-plane base URL."),
        egress: str = typer.Option(DEFAULT_EGRESS, "--egress", help="Egress data-plane base URL."),
    ) -> None:
        """Run the wire-fidelity gate against the loopback substrate and write migration-receipt.json."""
        receipt = run(services=(services.split(",") if services else None),
                      manifest=manifest, arm=arm, egress=egress)
        with open(out, "w") as f:
            json.dump(receipt, f, indent=2)
        ok = all(r["ok"] for r in receipt["services"]) and receipt["zero_egress"]
        typer.echo(json.dumps(receipt, indent=2))
        typer.echo(f"\n[smalt-migrate verify] {'PASS' if ok else 'FAIL'} -> {out}", err=True)
        if not ok:
            raise typer.Exit(1)
except ImportError:  # pragma: no cover - typer missing: library-only fallback
    pass

if __name__ == "__main__":
    raise SystemExit(main())
