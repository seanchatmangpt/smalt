"""keyvault sub-app: secret set/get, key create (RSA/EC/oct + release_policy),
PS256 sign.

Wire face: KV keys/secrets on the egress plane (/keys, /secrets; api-version
7.4). Sign rides POST /keys/:name/sign with a pre-hashed SHA-256 digest
(b64url); PS256 is externally verifiable (KvPss, KD-105/KD-119).
"""
from __future__ import annotations

import json

import httpx
import typer

from .. import wire

app = typer.Typer(help="Key Vault keys/secrets (egress plane).")


@app.command("secret-set")
def secret_set(
    name: str = typer.Argument(...),
    value: str = typer.Argument(...),
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Set a secret (PUT /secrets/:name; 201 create, 200 re-set)."""
    resp = wire.kv_request("PUT", f"secrets/{name}", {"value": value})
    wire.expect(resp, (200, 201), f"secret-set {name}")
    out = resp.json()
    wire.emit({"name": name, "id": out.get("id", ""),
               "status": resp.status_code}, output, title=f"secret {name}")


@app.command("secret-get")
def secret_get(
    name: str = typer.Argument(...),
    output: str = typer.Option("json", "--output", "-o"),
) -> None:
    """Get a secret (GET /secrets/:name)."""
    resp = wire.kv_request("GET", f"secrets/{name}")
    wire.expect(resp, (200,), f"secret-get {name}")
    wire.emit(resp.json(), output, title=f"secret {name}")


@app.command("key-create")
def key_create(
    name: str = typer.Argument(...),
    kty: str = typer.Option("RSA", "--kty", help="RSA | EC | oct-HSM."),
    release_policy: str = typer.Option(
        "", "--release-policy",
        help="Release-policy JSON (AZ-4 MHSM face: anyOf/claim/equals + "
             "dataExecution/exportable). Empty omits it.",
    ),
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Create a key (POST /keys/:name/create)."""
    body: dict = {"kty": kty}
    if release_policy:
        try:
            body["release_policy"] = json.loads(release_policy)
        except ValueError as e:
            wire.andon(f"key-create invalid --release-policy JSON: {e}")
    resp = wire.kv_request("POST", f"keys/{name}/create", body)
    wire.expect(resp, (200, 201), f"key-create {name}")
    out = resp.json()
    key = out.get("key", out)
    wire.emit({"name": name, "kid": out.get("kid", key.get("kid", "")),
               "kty": key.get("kty", kty),
               "release_policy": bool(key.get("release_policy")
                                      or out.get("release_policy")),
               "status": resp.status_code}, output, title=f"key {name}")


@app.command("sign")
def sign(
    name: str = typer.Argument(...),
    data: str = typer.Argument(..., help="Pre-image; SHA-256 digest is taken here."),
    alg: str = typer.Option("PS256", "--alg"),
    verify: bool = typer.Option(False, "--verify/--no-verify",
                                help="Also verify via POST /keys/:name/verify."),
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Sign a SHA-256 digest (POST /keys/:name/sign, PS256 default)."""
    digest = wire.sha256_b64u(data.encode("utf-8"))
    resp = wire.kv_request("POST", f"keys/{name}/sign", {"alg": alg, "value": digest})
    wire.expect(resp, (200,), f"sign {name} ({alg})")
    out = resp.json()
    result = {"kid": out.get("kid", ""), "alg": alg,
              "signature": out.get("value", "")}
    if verify:
        vresp = wire.kv_request("POST", f"keys/{name}/verify",
                                {"alg": alg, "digest": digest, "value": out.get("value", "")})
        if vresp.status_code != 200:
            wire.andon(f"verify {name}", status=vresp.status_code)
        result["valid"] = bool(vresp.json().get("value"))
    wire.emit(result, output, title=f"sign {name}")


@app.command("certificate-create")
def certificate_create(
    name: str = typer.Argument(...),
    subject: str = typer.Option("CN=smalt-cli.local", "--subject"),
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Create a certificate (POST /certificates/:name/create)."""
    resp = wire.kv_request("POST", f"certificates/{name}/create",
                           {"policy": {"x509_props": {"subject": subject}}})
    out = _expect_json(resp, (200, 201), f"certificate-create {name}")
    wire.emit({"name": name, "id": out.get("id", ""),
               "status": resp.status_code}, output, title=f"certificate {name}")


@app.command("certificate-get")
def certificate_get(
    name: str = typer.Argument(...),
    output: str = typer.Option("json", "--output", "-o"),
) -> None:
    """Get a certificate (GET /certificates/:name)."""
    resp = wire.kv_request("GET", f"certificates/{name}")
    out = _expect_json(resp, (200,), f"certificate-get {name}")
    wire.emit(out, output, title=f"certificate {name}")


def _expect_json(resp: httpx.Response, ok, what):
    wire.expect(resp, ok, what)
    return resp.json()
