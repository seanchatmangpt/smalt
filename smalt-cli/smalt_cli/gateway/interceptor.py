"""Zero-actuation middleware (ADR-PY-003).

Mutating HTTP verbs are refused locally with a typed 403 envelope before any
bytes leave the process boundary; the refusal is forwarded to the ledger via
a callback seam. The interceptor holds no state and actuates nothing.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable, Mapping

__all__ = [
    "MUTATION_VERBS",
    "FORBIDDEN_ENVELOPE_TYPE",
    "refusal_envelope",
    "MutationInterceptor",
]

MUTATION_VERBS = frozenset({"POST", "PUT", "PATCH", "DELETE"})
GET_VERBS = frozenset({"GET", "HEAD", "OPTIONS"})
FORBIDDEN_ENVELOPE_TYPE = "smalt.gateway.mutation_refused"

LedgerCallback = Callable[[Mapping[str, Any]], None]


def refusal_envelope(
    method: str,
    path: str,
    *,
    reason: str = "mutation verbs are refused by local policy (ADR-PY-003)",
) -> dict[str, Any]:
    """Typed 403 envelope body."""
    return {
        "type": FORBIDDEN_ENVELOPE_TYPE,
        "status": 403,
        "error": {
            "code": "MutationRefused",
            "message": reason,
            "target": path,
            "method": method.upper(),
        },
    }


@dataclass
class MutationInterceptor:
    """Refuse mutation verbs with a typed envelope; allow reads through.

    ``ledger`` is the callback seam: invoked with the envelope plus a
    timestamp for every refusal. Exceptions from the ledger callback are
    swallowed so ledger failure can never block a refusal.
    """

    ledger: LedgerCallback | None = None

    def check(self, method: str, path: str = "/") -> tuple[int, dict[str, Any]] | None:
        """Return ``(403, envelope)`` for mutation verbs, ``None`` for reads."""
        if method.upper() not in MUTATION_VERBS:
            return None
        envelope = refusal_envelope(method, path)
        if self.ledger is not None:
            try:
                self.ledger(envelope)
            except Exception:
                pass
        return (403, envelope)
