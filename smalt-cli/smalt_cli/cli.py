"""Typer dispatcher for smalt-cli.

Commands: test, hw, daemon, audit, gate. Each subcommand module lives in
smalt_cli/<module>/ and registers here (lanes add their own sub-apps).
"""

from __future__ import annotations

import os

import typer

from . import __version__
from .config import Settings, enforce_loopback
from .policy import Policy, guard

app = typer.Typer(
    name="smalt-cli",
    help="Headless CLI companion to the smalt emulator. Zero-actuation enforced.",
    no_args_is_help=True,
)
policy = Policy()
settings = Settings.from_env()


@app.command()
def test() -> None:
    """Run hardware-in-the-loop test profiles against the smalt substrate."""
    enforce_loopback(settings.arm)
    enforce_loopback(settings.egress)
    typer.echo(f"test: arm={settings.arm} egress={settings.egress} (scaffold: lane not landed)")


# hw sub-app (lane CLI-GATE2). Registration is conditional: hw/cli.py sets
# hw_app = None when typer is unavailable, in which case the scaffold echo
# below stays authoritative.
try:
    from .hw.cli import hw_app as _hw_app
except ImportError:
    _hw_app = None

if _hw_app is not None:
    app.add_typer(_hw_app, name="hw", help="AtomVM hardware bridge (USB-CDC).")
else:

    @app.command()
    def hw() -> None:
        """Enumerate/interact with hardware targets via pyserial (local only)."""
        typer.echo("hw: serial transport scaffold (lane not landed)")


@app.command()
def daemon() -> None:
    """Run the long-lived loopback daemon (reads only; gate-protected)."""
    enforce_loopback(settings.arm)
    typer.echo(f"daemon: arm={settings.arm} amqp={settings.amqp} (scaffold: lane not landed)")


@app.command()
def audit() -> None:
    """Emit the AU-10 audit surface (verdicts observed by the gate)."""
    typer.echo("audit: AU-10 audit surface (scaffold: lane not landed)")


# Verification-gates sub-app (lane CLI-8, documented one-liner in
# smalt_cli/gates.py:gate_app()). Typer refuses a command and a sub-app with
# the same name, so the scaffold `gate` (verb, url) command above is retired
# in favor of the real gate surface.
from .gates import gate_app

app.add_typer(gate_app(), name="gate", help="Verification gates.")


# smalt-migrate sub-app (PRD Module 1, REQ-1.1): Terraform -> topology scan.
from .migrate import migrate_app

app.add_typer(migrate_app, name="migrate", help="Terraform -> smalt topology migration.")

# M2 (REQ-2.1): `smalt-cli migrate generate` — topology IR -> smalt.manifest.json.
from .migrate.manifest import generate_command

migrate_app.command(name="generate")(generate_command)


def _version_callback(value: bool) -> None:
    if value:
        typer.echo(f"smalt-cli {__version__}")
        raise typer.Exit()


# Azure command groups (v26.10.22 azcli3 Typer lane). Wire transport lives in
# wire.py; each group is a real-wire sub-app (no mocks). Registration is
# additive — the existing test/hw/daemon/audit/gate/migrate surface is
# untouched.
from .commands import cosmosdb, deployment, keyvault, monitor, servicebus, storage

app.add_typer(storage.app, name="storage", help="Blob storage (8443).")
app.add_typer(cosmosdb.app, name="cosmosdb", help="Cosmos DB NoSQL (/dbs).")
app.add_typer(servicebus.app, name="servicebus", help="Service Bus (ARM + AMQP 5672).")
app.add_typer(keyvault.app, name="keyvault", help="Key Vault keys/secrets.")
app.add_typer(deployment.app, name="deployment", help="ARM deployments (9443).")
app.add_typer(monitor.app, name="monitor", help="Substrate telemetry (metrics/OCEL/discovery).")

# EXPL12-B: az-parity login/logout as top-level commands + `account show`.
from .commands.login import account_app, login as _login_cmd, logout as _logout_cmd

app.command(name="login", help="Verify via real STS round-trip and persist the profile.")(_login_cmd)
app.command(name="logout", help="Remove the persisted login profile.")(_logout_cmd)
app.add_typer(account_app, name="account", help="Login profile state (az account parity).")


@app.callback()
def _root(
    ctx: typer.Context,
    version: bool = typer.Option(
        False, "--version", callback=_version_callback, is_eager=True
    ),
    endpoint: str = typer.Option(
        "", "--endpoint", "-e",
        envvar="SMALT_ENDPOINT",
        help="Egress data-plane base URL override (blob/cosmos/keyvault).",
    ),
    output: str = typer.Option(
        "table", "--output", "-o",
        help="Output format: json|table|tsv|receipt (per-command -o overrides).",
    ),
) -> None:
    # The global endpoint override flows through the environment so wire.py's
    # fresh-per-call Settings resolution picks it up (SMALT_ENDPOINT > SMALT_EGRESS).
    if endpoint:
        os.environ["SMALT_EGRESS"] = endpoint


def main() -> None:
    app()


if __name__ == "__main__":
    main()
