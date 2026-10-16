"""Zero-actuation gate unit tests: read passes, mutation refused typed,
allowlist edge cases."""

from __future__ import annotations

import json

import pytest

from smalt_cli.policy import Policy, REFUSAL_EXIT_CODE, guard


@pytest.fixture()
def policy() -> Policy:
    return Policy()


# --- reads pass ---

@pytest.mark.parametrize("verb", ["GET", "HEAD", "get", "head"])
def test_read_verbs_pass(policy: Policy, verb: str) -> None:
    assert policy.check(verb, "https://127.0.0.1:9443/subscriptions") is None


# --- mutations refused, typed ---

@pytest.mark.parametrize("verb", ["PUT", "POST", "PATCH", "DELETE"])
def test_mutations_refused_typed(policy: Policy, verb: str) -> None:
    r = policy.check(verb, "https://127.0.0.1:9443/subscriptions/s/resource")
    assert r is not None
    payload = json.loads(r.to_json())
    assert set(payload) == {"refused", "reason", "verb", "url", "ts"}
    assert payload["refused"] is True
    assert payload["verb"] == verb
    assert payload["url"].startswith("https://127.0.0.1:9443/")
    assert "ZERO_ACTUATION" in payload["reason"]
    assert payload["ts"] > 0


def test_unknown_verb_refused(policy: Policy) -> None:
    r = policy.check("TRACE", "https://127.0.0.1:9443/")
    assert r is not None and "frozen read allowlist" in r.reason


# --- allowlist edge cases ---

def test_allowlisted_post_passes() -> None:
    p = Policy(allowlist=frozenset({"POST:/providers/Microsoft.Network/listLocations"}))
    assert p.check("POST", "https://127.0.0.1:9443/providers/Microsoft.Network/listLocations?api=1") is None


def test_allowlist_matches_exact_path_or_subpath() -> None:
    p = Policy(allowlist=frozenset({"POST:/x/read"}))
    assert p.check("POST", "https://127.0.0.1:9443/x/read?token=z") is None  # query ignored
    assert p.check("POST", "https://127.0.0.1:9443/x/read/sub") is None      # subpath ok
    assert p.check("POST", "https://127.0.0.1:9443/x/READ") is not None      # case-sensitive path
    assert p.check("PUT", "https://127.0.0.1:9443/x/read") is not None       # wrong verb
    assert p.check("POST", "https://127.0.0.1:9443/x/readother") is not None # not a path boundary


def test_default_policy_allowlist_empty() -> None:
    assert Policy().allowlist == frozenset()


# --- guard() exit behavior ---

def test_guard_exits_nonzero_on_refusal(policy: Policy, capsys) -> None:
    with pytest.raises(SystemExit) as ei:
        guard(policy, "DELETE", "https://127.0.0.1:9443/r")
    assert ei.value.code == REFUSAL_EXIT_CODE and ei.value.code != 0
    err = capsys.readouterr().err
    payload = json.loads(err.strip().splitlines()[-1])
    assert payload["refused"] is True and payload["verb"] == "DELETE"


def test_guard_passes_through_on_read(policy: Policy) -> None:
    guard(policy, "GET", "https://127.0.0.1:9443/r")  # no SystemExit
