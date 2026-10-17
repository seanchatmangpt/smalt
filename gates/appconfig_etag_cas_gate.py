#!/usr/bin/python3
"""Invariant gate: App Configuration /kv ETag CAS — compare-and-swap writes.

Positive: PUT a fresh {key,label} (201), then race TWO conditional PUTs
carrying the SAME If-Match etag but different values. The ETS-backed router
(lib/smalt/egress_router.ex put "/kv/:key") serializes them: exactly one wins
(2xx) and the loser takes 412 PreconditionFailed. The stored etag must equal
the quoted hex sha256 of Erlang term_to_binary({key, label, value,
contentType}) — recomputed here independently in Python. Negative arms on the
live wire: an unconditional overwrite of an existing kv (no If-Match) must 409
WriteConflict, and a stale If-Match must 412.

Negative fixtures: mutated transcripts (both racers win, unconditional
overwrite accepted, stale If-Match accepted, etag formula mismatch) must each
be refused by the same verdict.

Usage: python3 gates/appconfig_etag_cas_gate.py   (exit 0 = hold, 1 = violated)
"""
import base64
import hashlib
import os
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common

ACCT = "gatekvacct"
KEY, LABEL = "gatekey", "gatelabel"


def expected_etag(key, label, value, content_type):
    """Quoted hex sha256 of term_to_binary({key,label,value,contentType}).

    All four fields are binaries -> SMALL_TUPLE_EXT (104) with arity 4, each
    element a BINARY_EXT (109, 4-byte big-endian length). Matches
    egress_router.kv_write/4 (:crypto.hash :sha256 |> Base.encode16).
    """
    h = hashlib.sha256()
    h.update(b"\x83\x68\x04")
    for s in (key, label, value, content_type):
        b = s.encode()
        h.update(b"\x6d" + len(b).to_bytes(4, "big") + b)
    return '"' + h.hexdigest().upper() + '"'


def mint_token(ports):
    """Emulator STS (arm plane): client_credentials, any id/secret accepted."""
    import json as _json
    import urllib.parse

    form = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": "gate-client",
        "client_secret": "gate-secret",
        "scope": "https://management.azure.com/.default",
    })
    status, _, body = common.http(
        ports["arm"], "POST", "/gatekvacct/oauth2/v2.0/token", body=form,
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    if status != 200 or not isinstance(body, dict) or "access_token" not in body:
        raise RuntimeError(f"STS mint failed: {status} {body}")
    return body["access_token"]


def capture(ports, shared_key):
    egress = ports["egress"]
    token = mint_token(ports)
    auth = {"Authorization": f"Bearer {token}"}
    path = f"/kv/{KEY}?label={LABEL}"

    # create (no If-Match, absent) -> 201 with the content-hash etag
    s_create, h_create, body_create = common.http(
        egress, "PUT", path,
        body={"value": "v0", "contentType": "text/plain"}, headers=auth)
    etag_v0 = expected_etag(KEY, LABEL, "v0", "text/plain")

    # CAS write 1 and write 2: same If-Match (etag_v0), different values.
    # Barrier keeps the launch tight so both are in flight together.
    # Lane DEF-2 fix (v26.10.16): which racer wins the race is scheduler
    # luck — the gate must assert WINNER-IDENTITY (the stored value/etag
    # equals the racer that got the 2xx), never pre-race which-racer-wins.
    barrier = threading.Barrier(2)
    race_results = []

    def racer(value):
        barrier.wait()
        st, _, _ = common.http(
            egress, "PUT", path,
            body={"value": value, "contentType": "text/plain"},
            headers={**auth, "If-Match": etag_v0})
        race_results.append({"value": value, "status": st})

    t1 = threading.Thread(target=racer, args=("racer-a",))
    t2 = threading.Thread(target=racer, args=("racer-b",))
    t1.start(); t2.start(); t1.join(); t2.join()
    race = sorted(r["status"] for r in race_results)

    s_get, h_get, body_get = common.http(egress, "GET", path, headers=auth)

    # negative arm 1: unconditional overwrite of an existing kv -> 409
    s_uncond, _, uncond_body = common.http(
        egress, "PUT", path, body={"value": "sneaky", "contentType": "text/plain"},
        headers=auth)

    # negative arm 2: stale If-Match (etag of v0, current is the race winner) -> 412
    s_stale, _, stale_body = common.http(
        egress, "PUT", path,
        body={"value": "stale", "contentType": "text/plain"},
        headers={**auth, "If-Match": etag_v0})

    def code(body):
        return (body or {}).get("error", {}).get("code") if isinstance(body, dict) else None

    stored_etag = (body_get or {}).get("etag") if isinstance(body_get, dict) else None
    stored_value = (body_get or {}).get("value") if isinstance(body_get, dict) else None
    return {
        "create_status": s_create,
        "create_etag": (body_create or {}).get("etag") if isinstance(body_create, dict) else None,
        "race_statuses": race,
        "race_outcomes": race_results,
        "get_status": s_get,
        "stored_etag": stored_etag,
        "stored_value": stored_value,
        "unconditional_status": s_uncond,
        "unconditional_code": code(uncond_body),
        "stale_status": s_stale,
        "stale_code": code(stale_body),
    }


def verdict(obs):
    details = []
    ok = True

    def check(cond, msg):
        nonlocal ok
        details.append(("PASS" if cond else "FAIL") + " " + msg)
        ok = ok and cond

    check(obs.get("create_status") == 201,
          f"create -> 201 (got {obs.get('create_status')})")
    check(obs.get("create_etag") == expected_etag(KEY, LABEL, "v0", "text/plain"),
          f"create etag == quoted sha256({KEY},{LABEL},v0,text/plain) "
          f"(got {obs.get('create_etag')})")
    race = obs.get("race_statuses") or []
    check(len(race) == 2, f"both racers answered (got {race})")
    check(sum(1 for s in race if 200 <= s < 300) == 1,
          f"exactly one 2xx in the race (got {race})")
    check(race.count(412) == 1,
          f"exactly one 412 in the race (got {race})")
    outcomes = obs.get("race_outcomes") or []
    winners = [o["value"] for o in outcomes if 200 <= o.get("status", 0) < 300]
    losers = [o["value"] for o in outcomes if not 200 <= o.get("status", 0) < 300]
    check(len(winners) == 1 and len(losers) == 1,
          f"exactly one winner and one loser identified (got {outcomes})")
    winner_value = winners[0] if len(winners) == 1 else None
    want_etag = (expected_etag(KEY, LABEL, winner_value, "text/plain")
                 if winner_value is not None else None)
    check(obs.get("get_status") == 200, f"read-back -> 200 (got {obs.get('get_status')})")
    check(obs.get("stored_value") == winner_value,
          f"the 2xx racer's value is the stored one (winner-identity; "
          f"got {obs.get('stored_value')}, winner {winner_value})")
    check(obs.get("stored_etag") == want_etag,
          f"stored etag == quoted sha256 of winner content "
          f"(got {obs.get('stored_etag')}, want {want_etag})")
    check(obs.get("unconditional_status") == 409,
          f"unconditional overwrite of existing kv -> 409 (got {obs.get('unconditional_status')})")
    check(obs.get("unconditional_code") == "WriteConflict",
          "unconditional overwrite refusal carries WriteConflict")
    check(obs.get("stale_status") == 412,
          f"stale If-Match -> 412 (got {obs.get('stale_status')})")
    check(obs.get("stale_code") == "PreconditionFailed",
          "stale If-Match refusal carries PreconditionFailed")
    return ok, details


def mutate_fixtures(obs):
    def both_win(o):
        o = dict(o)
        o["race_statuses"] = [200, 201]
        return o

    def both_lose(o):
        o = dict(o)
        o["race_statuses"] = [412, 412]
        return o

    def uncond_accepted(o):
        o = dict(o)
        o["unconditional_status"] = 200
        o["unconditional_code"] = None
        return o

    def stale_accepted(o):
        o = dict(o)
        o["stale_status"] = 200
        o["stale_code"] = None
        return o

    def etag_formula_wrong(o):
        o = dict(o)
        o["stored_etag"] = '"DEADBEEF"'
        return o

    def lost_write_stored(o):
        # the LOSER's value landed — CAS did not actually bind. The loser
        # is identified post-race (the racer that did NOT get the 2xx).
        o = dict(o)
        outcomes = o.get("race_outcomes") or []
        losers = [x["value"] for x in outcomes if not 200 <= x.get("status", 0) < 300]
        if losers:
            o["stored_value"] = losers[0]
        return o

    return [(n, f(obs)) for n, f in
            [("both-racers-win", both_win),
             ("both-racers-lose", both_lose),
             ("unconditional-overwrite-accepted", uncond_accepted),
             ("stale-if-match-accepted", stale_accepted),
             ("etag-formula-wrong", etag_formula_wrong),
             ("loser-value-stored", lost_write_stored)]]


if __name__ == "__main__":
    sys.exit(common.run_gate("appconfig-etag-cas", capture, verdict, mutate_fixtures))
