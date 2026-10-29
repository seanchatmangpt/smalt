"""Shared wire helpers for the smalt-cli Azure command groups.

Every command performs a REAL wire call (httpx, verify=False) against the
smalt substrate loopback planes:

  - blob / cosmos / keyvault  -> egress data plane (SMALT_EGRESS, :8443)
  - servicebus mgmt + deployment -> ARM control plane (SMALT_ARM, :9443)
  - servicebus data (send/receive) -> AMQP :5672 (SMALT_AMQP, host:port)

Cosmos rides the egress plane (/dbs...), NOT a separate :8081 — the emulator
mounts the Cosmos NoSQL face on the shared egress router (CosmosRoutes.ex).
"""
from __future__ import annotations

import base64
import hashlib
import json
import time
import urllib.parse

from typing import NoReturn

import httpx
import typer

from .config import Settings, enforce_loopback

# x-ms-version pinned to the blob API version the substrate implements
# (mirrors tests/test_blob.py raw helpers).
XMS_VERSION = "2021-04-01"

_KV_API = "7.4"


def settings() -> Settings:
    """Fresh Settings per call so tests can retarget via env."""
    s = Settings.from_env()
    # Settings defaults are https; the CLI test substrates are plain http on
    # their private ports. Honor scheme from the env value verbatim.
    return s


def _client() -> httpx.Client:
    return httpx.Client(verify=False, timeout=30.0)


def egress_endpoint() -> str:
    s = Settings.from_env()
    override = _env_endpoint()
    base = override or s.egress
    enforce_loopback(base)
    return base.rstrip("/")


def arm_endpoint() -> str:
    s = Settings.from_env()
    base = s.arm
    enforce_loopback(base)
    return base.rstrip("/")


def amqp_hostport() -> str:
    s = Settings.from_env()
    hostport = s.amqp
    # Endpoint law: AMQP rides loopback too (same rule as ARM/egress).
    enforce_loopback(f"sb://{hostport}")
    return hostport


def _env_endpoint() -> str | None:
    return None


# ---------------------------------------------------------------------------
# Auth: STS client_credentials against the ARM control plane (works in both
# anonymous and :enforce substrate modes — anonymous accepts any grant,
# enforce accepts the emulator-issued HS256/RS256 token). Mint failure is a
# typed ANDON (loud, exit 1) — never a silent degrade to tokenless.
# ---------------------------------------------------------------------------

_token_cache: dict[str, tuple[float, str]] = {}


def _sts_creds() -> tuple[str, str]:
    """(client_id, client_secret): env > login profile > CLI defaults."""
    from .profile import credentials

    return credentials()


def bearer_for_arm() -> dict[str, str]:
    """Bearer header for the ARM plane. STS mint failure is a typed ANDON
    (loud, exit 1) — never a silent degrade-to-tokenless (EXPL12V-F1)."""
    arm = arm_endpoint()
    hit = _token_cache.get(arm)
    if hit and hit[0] > time.time():
        return {"Authorization": f"Bearer {hit[1]}"}
    cid, csec = _sts_creds()
    try:
        resp = httpx.post(
            f"{arm}/oauth2/v2.0/token",
            data={
                "grant_type": "client_credentials",
                "client_id": cid,
                "client_secret": csec,
            },
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            verify=False,
            timeout=15.0,
        )
        tok = resp.json()["access_token"]
    except Exception as exc:
        andon(f"ARM bearer mint failed: STS unreachable or refused ({exc})")
    _token_cache[arm] = (time.time() + 300, tok)
    return {"Authorization": f"Bearer {tok}"}


# ---------------------------------------------------------------------------
# Output: json | table | tsv | receipt  (global --output/-o)
# ---------------------------------------------------------------------------


def emit(payload, fmt: str, title: str = "") -> None:
    if fmt == "json":
        typer.echo(json.dumps(payload, indent=2, default=str))
        return
    rows = _tabular(payload)
    if fmt == "tsv":
        for row in rows:
            typer.echo("\t".join(str(c) for c in row))
        return
    if fmt == "receipt":
        typer.echo(f"# receipt: {title}" if title else "# receipt")
        for row in rows:
            # _tabular can yield 1-tuples (scalar lists); index defensively.
            val = row[1] if len(row) > 1 else ""
            typer.echo(f"{row[0]}: {val}")
        return
    # table
    if not rows:
        if title:
            typer.echo(title)
        return
    width = [max(len(str(r[i])) for r in rows) for i in range(len(rows[0]))]
    for j, row in enumerate(rows):
        line = "  ".join(str(c).ljust(width[i]) for i, c in enumerate(row)).rstrip()
        typer.echo(line)
        if j == 0:
            typer.echo("  ".join("-" * w for w in width))


def _tabular(payload):
    if isinstance(payload, dict):
        return [("key", "value")] + [(k, json.dumps(v) if not isinstance(v, str) else v)
                                     for k, v in payload.items()]
    if isinstance(payload, list):
        if payload and isinstance(payload[0], dict):
            cols = list(payload[0].keys())
            return [cols] + [[r.get(c, "") for c in cols] for r in payload]
        return [("value",)] + [(v,) for v in payload]
    return [("result", payload)]


def andon(message: str, status: int | None = None) -> NoReturn:
    """ANDON refusal: red on stderr, exit 1. Never a silent failure."""
    suffix = f" (HTTP {status})" if status is not None else ""
    typer.secho(f"ANDON {message}{suffix}", fg=typer.colors.RED, err=True)
    raise typer.Exit(code=1)


def expect(resp: httpx.Response, ok_statuses, what: str):
    if resp.status_code not in ok_statuses:
        andon(f"{what} refused", status=resp.status_code)
    return resp


# ---------------------------------------------------------------------------
# Group-specific wire helpers
# ---------------------------------------------------------------------------


def blob_url(container: str, blob: str = "") -> str:
    base = egress_endpoint()
    url = f"{base}/smaltacct/{container}"
    if blob:
        url += f"/{blob}"
    return url


def container_put_headers(immutable: bool) -> dict:
    h = {"x-ms-version": XMS_VERSION}
    # Default containers are WORM/immutable (blob_storage.ex worm_blocked?);
    # mutable opt-out mirrors tests/test_blob.py make_mutable_container.
    if not immutable:
        h["x-ms-immutable-policy"] = "false"
    return h


def kv_headers() -> dict:
    return {"x-version": XMS_VERSION}


def kv_request(method: str, path: str, json_body=None) -> httpx.Response:
    """KV wire call with the KD-15 challenge handshake: tokenless first
    touch takes the 401 + WWW-Authenticate, then a bearer retry (mirrors the
    real @azure SDK first-touch contract; corpus premise pin)."""
    url = kv_url(path)
    resp = _client().request(method, url, json=json_body)
    if resp.status_code == 401:
        tok = _sts_token()
        if tok:
            resp = _client().request(
                method, url, json=json_body,
                headers={"Authorization": f"Bearer {tok}"},
            )
    return resp


def _sts_token() -> str:
    hit = _token_cache.get("sts")
    if hit and hit[0] > time.time():
        return hit[1]
    try:
        cid, csec = _sts_creds()
        tok = httpx.post(
            f"{arm_endpoint()}/oauth2/v2.0/token",
            data={
                "grant_type": "client_credentials",
                "client_id": cid,
                "client_secret": csec,
            },
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            verify=False, timeout=15.0,
        ).json()["access_token"]
    except Exception:
        return ""
    _token_cache["sts"] = (time.time() + 300, tok)
    return tok


def kv_url(path: str) -> str:
    sep = "&" if "?" in path else "?"
    return f"{egress_endpoint()}/{path}{sep}api-version={_KV_API}"


def cosmos_url(path: str) -> str:
    return f"{egress_endpoint()}/{path}"


def cosmos_request(method: str, path: str, json_body=None,
                   extra_headers: dict | None = None) -> httpx.Response:
    """Cosmos wire call with the KD-15 challenge handshake (tokenless first
    touch takes the 401, then one bearer retry)."""
    url = cosmos_url(path)
    hdrs = dict(extra_headers or {})
    resp = _client().request(method, url, json=json_body, headers=hdrs)
    if resp.status_code == 401:
        tok = _sts_token()
        if tok:
            hdrs["Authorization"] = f"Bearer {tok}"
            resp = _client().request(method, url, json=json_body, headers=hdrs)
    return resp


def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def sha256_b64u(data: bytes) -> str:
    return b64u(hashlib.sha256(data).digest())


def arm_url(path: str, api_version: str = "2021-04-01") -> str:
    return f"{arm_endpoint()}/{path.lstrip('/')}?api-version={api_version}"


def arm_request(method: str, url: str, *, json_body: dict | None = None,
                params: dict | None = None) -> httpx.Response:
    """ARM wire call with the KD-15 challenge handshake (EXPL12-W repair of
    EXPL12V-F1): tokenless first touch takes the 401 + WWW-Authenticate, then
    one bearer retry — same contract as kv_request/cosmos_request. If the
    bearer mint fails, this is a typed ANDON (loud, exit 1), never a silent
    tokenless fallback (the old bearer_for_arm() pre-attach degraded to {}
    silently and the request 401'd with no retry)."""
    resp = _client().request(method, url, json=json_body, params=params)
    if resp.status_code == 401:
        tok = _sts_token()
        if not tok:
            andon("ARM bearer mint failed: STS unreachable or refused "
                  "(no tokenless fallback; EXPL12V-F1)")
        resp = _client().request(method, url, json=json_body, params=params,
                                 headers={"Authorization": f"Bearer {tok}"})
    return resp


def arm_put(path: str, body: dict, api_version: str = "2021-04-01") -> httpx.Response:
    return arm_request("PUT", arm_url(path, api_version), json_body=body)


def arm_get(path: str, api_version: str = "2021-04-01") -> httpx.Response:
    return arm_request("GET", arm_url(path, api_version))


def qs(extra: dict | None = None) -> str:
    if not extra:
        return ""
    return "&" + urllib.parse.urlencode(extra)
