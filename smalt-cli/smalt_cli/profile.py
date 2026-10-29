"""CLI login profile (EXPL12-B): az-parity persistent credentials.

`smalt-cli login` performs a REAL STS round-trip (client_credentials against
the ARM control plane /oauth2/v2.0/token) and only then persists the
endpoint+credential set to the profile file (default
`~/.smalt-cli/config.json`, overridable with SMALT_CLI_CONFIG for tests).
Subsequent commands resolve endpoints/credentials with the precedence:

    env > profile > defaults

Env-only operation is unchanged: no profile file means exactly the old
Settings.from_env behavior. The profile is chmod 0600 on write.
"""
from __future__ import annotations

import json
import os
import pathlib
import stat

PROFILE_FIELDS = ("arm", "egress", "amqp", "client_id", "client_secret", "tenant")

# Keys read by config.Settings.from_env for endpoint fallback.
_ENDPOINT_FIELDS = ("arm", "egress", "amqp")


def profile_path() -> pathlib.Path:
    return pathlib.Path(
        os.environ.get("SMALT_CLI_CONFIG", "~/.smalt-cli/config.json")
    ).expanduser()


def load() -> dict | None:
    """Load the profile, or None when absent/corrupt (never raises)."""
    p = profile_path()
    try:
        data = json.loads(p.read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    return {k: data[k] for k in PROFILE_FIELDS if k in data}


def save(profile: dict) -> pathlib.Path:
    data = {k: profile[k] for k in PROFILE_FIELDS if k in profile}
    p = profile_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    try:
        os.chmod(p, 0o600)
    except OSError:
        pass
    return p


def delete() -> bool:
    """Remove the profile file; True when a profile was removed."""
    p = profile_path()
    try:
        p.unlink()
        return True
    except OSError:
        return False


def endpoint_overrides() -> dict:
    """Endpoint values from the profile, for Settings.from_env fallback."""
    prof = load()
    if not prof:
        return {}
    return {k: prof[k] for k in _ENDPOINT_FIELDS if prof.get(k)}


def credentials() -> tuple[str, str]:
    """(client_id, client_secret) for the STS round-trip: env first, then
    profile, then the emulator-accepted CLI defaults."""
    cid = os.environ.get("SMALT_CLIENT_ID", "")
    csec = os.environ.get("SMALT_CLIENT_SECRET", "")
    prof = load() or {}
    cid = cid or prof.get("client_id", "") or "smalt-cli"
    csec = csec or prof.get("client_secret", "") or "smalt-cli-local"
    return cid, csec


def tenant() -> str:
    return (load() or {}).get("tenant", "")
