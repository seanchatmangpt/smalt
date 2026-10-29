"""login / logout / account show (EXPL12-B): az-parity profile auth.

`login` performs the REAL STS round-trip first (client_credentials against
the ARM control plane /oauth2/v2.0/token — the emulator's loopback STS mints
an HS256 bearer) and only persists the profile on a 200 carrying an
access_token. Failure is an ANDON refusal (exit 1), never a saved profile.
"""
from __future__ import annotations

import httpx
import typer

from .. import profile, wire

account_app = typer.Typer(help="Login profile state (az account parity).")


def _sts_round_trip(arm: str, client_id: str, client_secret: str) -> dict:
    """Real token mint. Returns the parsed token response; ANDON on failure."""
    try:
        resp = httpx.post(
            f"{arm}/oauth2/v2.0/token",
            data={
                "grant_type": "client_credentials",
                "client_id": client_id,
                "client_secret": client_secret,
            },
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            verify=False,
            timeout=15.0,
        )
    except httpx.HTTPError as exc:
        wire.andon(f"login STS unreachable at {arm}: {exc.__class__.__name__}")
    if resp.status_code != 200:
        wire.andon("login STS refused", status=resp.status_code)
    body = resp.json()
    if not body.get("access_token"):
        wire.andon("login STS response carried no access_token")
    return body


def login(
    arm: str = typer.Option("", "--arm", help="ARM control plane base URL."),
    egress: str = typer.Option("", "--egress", help="Egress data-plane base URL."),
    amqp: str = typer.Option("", "--amqp", help="AMQP host:port."),
    client_id: str = typer.Option("", "--client-id", help="STS client_id."),
    client_secret: str = typer.Option("", "--client-secret", help="STS client_secret."),
    tenant: str = typer.Option("", "--tenant", help="Tenant id recorded in the profile."),
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Verify credentials via a real STS round-trip, then persist the profile."""
    import os

    s = wire.settings()
    arm = arm or os.environ.get("SMALT_ARM", "") or s.arm
    egress = egress or os.environ.get("SMALT_EGRESS", "") or s.egress
    amqp = amqp or os.environ.get("SMALT_AMQP", "") or s.amqp
    cid = client_id or os.environ.get("SMALT_CLIENT_ID", "") or "smalt-cli"
    csec = client_secret or os.environ.get("SMALT_CLIENT_SECRET", "") or "smalt-cli-local"
    tenant = tenant or os.environ.get("SMALT_TENANT", "") or "00000000-0000-0000-0000-000000000000"

    wire.enforce_loopback(arm)
    wire.enforce_loopback(egress)
    tok = _sts_round_trip(arm, cid, csec)

    prof = {
        "arm": arm, "egress": egress, "amqp": amqp,
        "client_id": cid, "client_secret": csec, "tenant": tenant,
    }
    path = profile.save(prof)
    wire.emit(
        {
            "verified": True,
            "profile": str(path),
            "arm": arm,
            "egress": egress,
            "amqp": amqp,
            "tenant": tenant,
            "token_type": tok.get("token_type", ""),
            "expires_in": tok.get("expires_in", ""),
        },
        output, title="login verified (real STS round-trip)",
    )


def logout() -> None:
    """Remove the persisted login profile."""
    if profile.delete():
        typer.echo("logout: profile removed")
    else:
        wire.andon("logout: no login profile at " + str(profile.profile_path()))


@account_app.command("show")
def account_show(
    output: str = typer.Option("table", "--output", "-o"),
) -> None:
    """Show the persisted login profile (az account show parity)."""
    prof = profile.load()
    if not prof:
        wire.andon("account show: not logged in (run `smalt-cli login`)")
    shown = dict(prof)
    if shown.get("client_secret"):
        shown["client_secret"] = "***"
    wire.emit(shown, output, title="account")
