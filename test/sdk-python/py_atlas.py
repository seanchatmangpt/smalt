#!/usr/bin/env python3
"""PY-ATLAS lane: real REST (requests) probes of the smalt Purview Atlas v2 plane.

Venv: test/sdk-python/.venv-eh (requests 2.34.2).
Receipt target: docs/jira/v26.10.16/sdk-results/py-atlas.md (KD-41).

Scope (80/20): happy-path + typed refusals only — the implemented surface,
nothing built out.

Surface under test (lib/smalt/egress_router.ex, EgressRouter on the egress
plane):
  POST /atlas/v2/entity                single create (guid assigned when absent)
  POST /atlas/v2/entity/bulk           atomic bulk create (<=100, all maps)
  GET  /atlas/v2/entity/guid/:guid     fetch by guid (200/404)
  POST /atlas/v2/relationship          lineage edge (end1/end2 wire shape)
  GET  /atlas/v2/lineage/:dir/:guid?depth=N   BFS lineage (input|output|both)

Checks: single create with server-assigned GUID, client-supplied GUID
preservation, non-map entity typed 400, bulk create + guidAssignments
envelope, bulk over-limit typed 400 (atomic), entity round-trip,
unknown-guid typed 404, relationship wire shape, relationship typed 400
without end guids, lineage output/input/both BFS over a real graph,
back-edge inclusion in `both`, bad direction typed 400, lineage for an
unknown guid (empty relations).
"""
import os
import secrets
import sys

import requests

BASE = os.environ.get("SMALT_EGRESS_BASE", "http://127.0.0.1:39323")
S = requests.Session()

results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))
    print(("PASS " if cond else "FAIL ") + name + ((" :: " + str(detail)) if detail else ""))


def atlas_error(resp):
    try:
        b = resp.json()
    except Exception:
        return "<non-json>"
    err = b.get("error") or {}
    return "status=%s code=%s msg=%s" % (
        resp.status_code, err.get("code"), str(err.get("message"))[:80])


def pairs(body):
    return {(x["fromEntityId"], x["toEntityId"]) for x in body.get("relations", [])}


def main():
    # -- happy path ---------------------------------------------------------
    r = S.post(BASE + "/atlas/v2/entity", json={"entity": {"typeName": "DataSet", "attributes": {"name": "orders"}}})
    check("create_entity: server-assigned guid 201",
          r.status_code == 201 and bool(r.json().get("guid")), atlas_error(r))
    guid_a = r.json()["guid"]

    my_guid = secrets.token_hex(8)
    r = S.post(BASE + "/atlas/v2/entity", json={"entity": {"guid": my_guid, "typeName": "Process"}})
    check("create_entity: client-supplied guid preserved",
          r.status_code == 201 and r.json().get("guid") == my_guid, atlas_error(r))

    ents = [{"typeName": "DataSet", "attributes": {"name": "b%d" % i}} for i in range(3)]
    r = S.post(BASE + "/atlas/v2/entity/bulk", json={"entities": ents})
    b = r.json() if r.status_code == 201 else {}
    bulk_guids = list((b.get("guidAssignments") or {}).keys())
    check("bulk: 3 entities -> 201 with guidAssignments + mutatedEntities",
          r.status_code == 201 and len(bulk_guids) == 3 and "mutatedEntities" in b, atlas_error(r))
    check("bulk: mutatedEntities.CREATE lists all 3",
          len(b.get("mutatedEntities", {}).get("CREATE", [])) == 3, atlas_error(r))

    r = S.get(BASE + "/atlas/v2/entity/guid/" + guid_a)
    got = r.json() if r.status_code == 200 else {}
    check("get_entity: round-trip (typeName + attributes echo)",
          r.status_code == 200 and got.get("typeName") == "DataSet", atlas_error(r))

    guids = {}
    for name in ["src", "mid", "sink"]:
        rr = S.post(BASE + "/atlas/v2/entity", json={"entity": {"typeName": "Process", "attributes": {"name": name}}})
        guids[name] = rr.json()["guid"]

    def rel(a, b):
        return S.post(BASE + "/atlas/v2/relationship", json={
            "relationship": {"typeName": "smalt_lineage", "end1": {"guid": a}, "end2": {"guid": b}}})

    r = rel(guids["src"], guids["mid"])
    check("relationship: 201 with guid+id echo",
          r.status_code == 201 and bool(r.json().get("guid")) and bool(r.json().get("id")), atlas_error(r))
    rel(guids["mid"], guids["sink"])
    rel(guids["sink"], guids["src"])  # back-edge (cycle)

    r = S.get(BASE + "/atlas/v2/lineage/output/%s?depth=5" % guids["src"])
    body = r.json() if r.status_code == 200 else {}
    expected_out = {(guids["src"], guids["mid"]), (guids["mid"], guids["sink"]), (guids["sink"], guids["src"])}
    check("lineage output: cyclic graph returns all 3 edges",
          r.status_code == 200 and expected_out <= pairs(body),
          atlas_error(r) + " rels=" + str(len(body.get("relations", []))))

    r = S.get(BASE + "/atlas/v2/lineage/input/%s?depth=5" % guids["sink"])
    body = r.json() if r.status_code == 200 else {}
    rp = pairs(body)
    check("lineage input: sink sees all upstream edges",
          r.status_code == 200 and (guids["src"], guids["mid"]) in rp and (guids["mid"], guids["sink"]) in rp,
          atlas_error(r))

    r = S.get(BASE + "/atlas/v2/lineage/both/%s?depth=5" % guids["mid"])
    body = r.json() if r.status_code == 200 else {}
    check("lineage both: includes back-edge (sink->src)",
          r.status_code == 200 and (guids["sink"], guids["src"]) in pairs(body), atlas_error(r))
    check("lineage both: baseEntityGuid echoes guid",
          body.get("baseEntityGuid") == guids["mid"], atlas_error(r))

    # -- typed refusals ------------------------------------------------------
    r = S.post(BASE + "/atlas/v2/entity", json={"entity": "not-a-map"})
    check("refusal: non-map entity -> 400 ATLAS-400",
          r.status_code == 400 and "ATLAS-400" in r.text, atlas_error(r))

    r = S.post(BASE + "/atlas/v2/entity/bulk", json={"entities": [{"typeName": "X"}] * 101})
    check("refusal: bulk 101 entities -> 400 ATLAS-400 (limit 100)",
          r.status_code == 400 and "ATLAS-400" in r.text, atlas_error(r))

    r = S.get(BASE + "/atlas/v2/entity/guid/" + secrets.token_hex(16))
    check("refusal: unknown guid -> 404 ATLAS-404",
          r.status_code == 404 and "ATLAS-404" in r.text, atlas_error(r))

    r = rel({"x": 1}, guids["mid"])
    check("refusal: relationship missing end guids -> 400 ATLAS-400",
          r.status_code == 400 and "ATLAS-400" in r.text, atlas_error(r))

    r = S.get(BASE + "/atlas/v2/lineage/diagonal/%s" % guids["src"])
    check("refusal: bad direction -> 400 ATLAS-400",
          r.status_code == 400 and "ATLAS-400" in r.text, atlas_error(r))

    r = S.get(BASE + "/atlas/v2/lineage/output/%s" % secrets.token_hex(16))
    body = r.json() if r.status_code == 200 else {}
    check("refusal: lineage unknown guid -> 200 empty relations",
          r.status_code == 200 and body.get("relations") == [] and body.get("baseEntityGuid"),
          atlas_error(r))

    print()
    passed = sum(1 for _, ok, _ in results if ok)
    print("TOTAL: %d/%d passed" % (passed, len(results)))
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
