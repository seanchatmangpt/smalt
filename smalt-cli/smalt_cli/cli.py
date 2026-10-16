"""Typer dispatcher for smalt-cli.

Commands: test, hw, daemon, audit, gate. Each subcommand module lives in
smalt_cli/<module>/ and registers here (lanes add their own sub-apps).
"""

from __future__ import annotations

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


def _version_callback(value: bool) -> None:
    if value:
        typer.echo(f"smalt-cli {__version__}")
        raise typer.Exit()


@app.callback()
def _root(
    version: bool = typer.Option(
        False, "--version", callback=_version_callback, is_eager=True
    ),
) -> None:
    pass


def main() -> None:
    app()


if __name__ == "__main__":
    main()
