"""smalt-migrate package: Terraform -> smalt topology migration (PRD Module 1).

Exports `migrate_app` (Typer sub-app) for registration in smalt_cli/cli.py.
"""

from . import inject  # noqa: F401  # registers inject/rollback commands (M3 handoff)
from . import verify  # noqa: F401  # registers verify command (M6 audit finding 2)
from .pipeline import pipeline_all_command  # M5 handoff
from .scan import migrate_app

migrate_app.command(name="all")(pipeline_all_command)

__all__ = ["migrate_app"]
