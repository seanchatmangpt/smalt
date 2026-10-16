"""smalt_cli.gateway — local policy + redirect layer over the smalt emulator.

Three components:
- ``sts``: local OAuth2/OIDC-shaped token issuer (HS256, stdlib only).
- ``proxy``: stdlib http.server reverse proxy to the smalt substrate.
- ``interceptor``: zero-actuation middleware (ADR-PY-003) — typed 403 for
  mutation verbs, refusal forwarded to the ledger via callback seam.

The gateway never re-implements Azure surfaces; the smalt emulator owns those.
"""

from smalt_cli.gateway.sts import LocalSTS, local_token
from smalt_cli.gateway.interceptor import (
    FORBIDDEN_ENVELOPE_TYPE,
    MutationInterceptor,
    refusal_envelope,
)
from smalt_cli.gateway.proxy import GatewayProxy

__all__ = [
    "LocalSTS",
    "local_token",
    "MutationInterceptor",
    "refusal_envelope",
    "FORBIDDEN_ENVELOPE_TYPE",
    "GatewayProxy",
]
