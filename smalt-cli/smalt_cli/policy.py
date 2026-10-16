"""Zero-actuation gate (AU-10).

A frozen read-verb allowlist: GET/HEAD plus explicitly allowlisted read ops.
PUT/POST/PATCH/DELETE are refused unless explicitly allowlisted. Every refusal
is typed and carries a non-zero exit code.
"""

from __future__ import annotations

import json
import sys
import time
from dataclasses import dataclass, field, asdict
from urllib.parse import urlparse

# Frozen read verbs — never extended implicitly.
READ_VERBS: frozenset[str] = frozenset({"GET", "HEAD"})

# Verbs that mutate remote state. Refused unless explicitly allowlisted.
MUTATING_VERBS: frozenset[str] = frozenset({"PUT", "POST", "PATCH", "DELETE"})

# Explicit read ops that ride non-GET verbs (subset of known Azure read APIs).
# Extension requires a code review of this literal — it is the actuation surface.
EXPLICIT_READ_OPS: frozenset[str] = frozenset(
    {
        # none initially; add e.g. "POST:/subscriptions/listLocations" shape
        # entries as "VERB:path-prefix" when a real read op requires it.
    }
)

REFUSAL_EXIT_CODE = 2


@dataclass(frozen=True)
class Refusal:
    refused: bool
    reason: str
    verb: str
    url: str
    ts: float

    def to_json(self) -> str:
        return json.dumps(asdict(self), sort_keys=True)


@dataclass
class Policy:
    """Zero-actuation gate over (verb, url) pairs."""

    allowlist: frozenset[str] = field(default_factory=lambda: EXPLICIT_READ_OPS)

    def check(self, verb: str, url: str) -> Refusal | None:
        """Return a typed Refusal if the request must not proceed, else None."""
        v = verb.upper()
        if v in READ_VERBS:
            return None
        if v in MUTATING_VERBS:
            if self._explicitly_allowed(v, url):
                return None
            return Refusal(
                refused=True,
                reason=f"ZERO_ACTUATION: verb {v} is mutating and not allowlisted",
                verb=v,
                url=url,
                ts=time.time(),
            )
        return Refusal(
            refused=True,
            reason=f"ZERO_ACTUATION: verb {v} is not in the frozen read allowlist",
            verb=v,
            url=url,
            ts=time.time(),
        )

    def _explicitly_allowed(self, verb: str, url: str) -> bool:
        path = urlparse(url).path
        for entry in self.allowlist:
            ev, _, epath = entry.partition(":")
            if ev != verb:
                continue
            if path == epath or path.startswith(epath.rstrip("/") + "/"):
                return True
        return False


def guard(policy: Policy, verb: str, url: str) -> None:
    """Enforce the gate: print typed refusal JSON to stderr and exit non-zero."""
    refusal = policy.check(verb, url)
    if refusal is not None:
        print(refusal.to_json(), file=sys.stderr)
        raise SystemExit(REFUSAL_EXIT_CODE)
