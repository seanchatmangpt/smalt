"""Endpoint configuration from environment variables (ADR-PY-001).

All endpoints default to the smalt substrate loopback ports. No network
egress beyond 127.0.0.1 is permitted; a non-loopback value is a config error.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from urllib.parse import urlparse

# smalt substrate ports
DEFAULT_ARM_PORT = 9443
DEFAULT_EGRESS_PORT = 8443
DEFAULT_AMQP_PORT = 5672


def _default(port: int) -> str:
    return f"https://127.0.0.1:{port}"


@dataclass(frozen=True)
class Settings:
    arm: str = _default(DEFAULT_ARM_PORT)        # SMALT_ARM
    egress: str = _default(DEFAULT_EGRESS_PORT)  # SMALT_EGRESS
    amqp: str = _default(DEFAULT_AMQP_PORT)      # SMALT_AMQP (host:port, no scheme)

    @classmethod
    def from_env(cls, env: dict | None = None) -> "Settings":
        e = env if env is not None else os.environ
        return cls(
            arm=e.get("SMALT_ARM", _default(DEFAULT_ARM_PORT)),
            egress=e.get("SMALT_EGRESS", _default(DEFAULT_EGRESS_PORT)),
            amqp=e.get("SMALT_AMQP", f"127.0.0.1:{DEFAULT_AMQP_PORT}"),
        )


def enforce_loopback(url: str) -> str:
    """Refuse any endpoint that is not loopback. Returns the host for logging."""
    parsed = urlparse(url)
    host = parsed.hostname or ""
    if host not in ("127.0.0.1", "localhost", "::1"):
        raise ValueError(
            f"NON_LOOPBACK_ENDPOINT: {url!r} — smalt-cli only talks to 127.0.0.1"
        )
    return host


# AZURE_* export plan (ADR-PY-001): official Azure SDKs are pointed at the
# local emulator by exporting these before any SDK client construction:
#
#   export AZURE_CLIENT_ID=...            # emulator-accepted dummy identity
#   export AZURE_TENANT_ID=...
#   export AZURE_CLIENT_SECRET=...
#   export AZURE_AUTHORITY_HOST=https://127.0.0.1:9443/
#   export AZURE_ARM_ENDPOINT=$SMALT_ARM   # arm endpoints -> smalt substrate
#   export AZURE_STORAGE_CONNECTION_STRING=...  # blob endpoints -> SMALT_EGRESS
#   AZURE_* values are read from the process environment only; smalt-cli never
#   writes credentials to disk and never forwards them off loopback.
AZURE_EXPORT_PLAN = {
    "AZURE_CLIENT_ID": "emulator-accepted dummy identity",
    "AZURE_TENANT_ID": "emulator-accepted tenant",
    "AZURE_CLIENT_SECRET": "emulator-accepted secret",
    "AZURE_AUTHORITY_HOST": "SMALT_ARM (authority surface)",
    "AZURE_ARM_ENDPOINT": "SMALT_ARM",
    "AZURE_STORAGE_CONNECTION_STRING": "SMALT_EGRESS (blob/data plane)",
}
