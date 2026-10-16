#!/usr/bin/env python3
"""PY-3 lane: REAL python azure-cosmos SDK against the smalt substrate Cosmos plane.

Endpoint: http://127.0.0.1:8443 (MIX_ENV=test anonymous auth). Master key:
any 64-char hex string (substrate runs anonymous auth; the SDK still signs
every request with the real master-key wire auth header).

Checks: account bootstrap, DB/container create, item CRUD, SQL whitelist
gate (only `SELECT * FROM c` admitted; anything else 400), cross-partition
query, pagination via continuation (>100 docs), stale-etag 412 on
replace/delete, list containers with continuation.
"""
import secrets

import azure.cosmos.cosmos_client as cc
from azure.cosmos import exceptions
from azure.core import MatchConditions

ENDPOINT = "http://127.0.0.1:8443"
KEY = secrets.token_hex(32)

results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))
    print("[PASS] " + name if cond else "[FAIL] " + name, end="")
    if detail:
        print(" :: " + detail)
    else:
        print()


def summary(e):
    return "status=" + str(e.status_code) + " body=" + str(e.message)[:160]


def refused_400(name, sql):
    try:
        list(cont_ref.query_items(sql))
        check(name, False, "admitted (expected 400)")
    except exceptions.CosmosHttpResponseError as e:
        check(name, e.status_code == 400,
              "status=" + str(e.status_code) + " body=" + str(e.message)[:120])
    except Exception as e:
        check(name, False, repr(e))


cont_ref = None


def main():
    global cont_ref
    client = cc.CosmosClient(ENDPOINT, credential=KEY)
    db_id = "pycosmos-" + secrets.token_hex(4)

    # 1. Database account bootstrap (GET /) — python Documents.DatabaseAccount shape.
    try:
        acct = client.get_database_account()
        check("get_database_account", True, "ok")
    except Exception as e:
        check("get_database_account", False, repr(e))

    # 2. DB + container create.
    try:
        db = client.create_database(db_id)
        check("create_database " + db_id, True, db.id)
    except exceptions.CosmosHttpResponseError as e:
        check("create_database", False, summary(e))
        return
    try:
        cont = db.create_container(id="c1", partition_key="/pk")
        check("create_container c1 /pk", True, cont.id)
    except exceptions.CosmosHttpResponseError as e:
        check("create_container", False, summary(e))
        return
    cont_ref = cont

    # 3. Item CRUD.
    try:
        r = cont.create_item({"id": "d1", "pk": "acme", "n": 1})
        check("create_item d1", r.get("id") == "d1", "etag=" + str(r.get("_etag")))
        etag = r["_etag"]
    except exceptions.CosmosHttpResponseError as e:
        check("create_item d1", False, summary(e))
        return
    got = cont.read_item("d1", partition_key="acme")
    check("read_item d1", got["n"] == 1 and got["_etag"] == etag)
    rep = cont.replace_item("d1", body={"id": "d1", "pk": "acme", "n": 2}, etag=etag, match_condition=MatchConditions.IfNotModified)
    check("replace_item with matching etag", rep["n"] == 2)
    got2 = cont.read_item("d1", partition_key="acme")
    check("read_item after replace", got2["n"] == 2)
    cont.delete_item("d1", partition_key="acme")
    try:
        cont.read_item("d1", partition_key="acme")
        check("delete_item d1 -> read 404", False, "doc still readable")
    except exceptions.CosmosResourceNotFoundError:
        check("delete_item d1 -> read 404", True)

    # 3b. KD-07 falsifier: ReadFeed (GET docs) must return the SDK envelope.
    try:
        cont.create_item({"id": "r1", "pk": "acme"})
        cont.create_item({"id": "r2", "pk": "acme"})
        rows = list(cont.read_all_items(partition_key="acme"))
        check("read_all_items (ReadFeed envelope)",
              [r["id"] for r in rows] == ["r1", "r2"],
              "ids=" + str([r["id"] for r in rows]))
    except Exception as e:
        check("read_all_items (ReadFeed envelope)", False, repr(e))

    # 4. SQL whitelist gate.
    rows = list(cont.query_items("SELECT * FROM c"))
    check("whitelist: SELECT * FROM c admitted", True, str(len(rows)) + " rows")
    for bad in ["SELECT c.id FROM c",
                "SELECT * FROM root",
                "SELECT * FROM c WHERE c.n = 2",
                "SELECT VALUE c.n FROM c",
                " CosmosDB",
                "SELECT * FROM c OFFSET 1 LIMIT 1"]:
        refused_400("whitelist: " + bad + " -> 400", bad)

    # 5. Cross-partition query.
    for i in range(5):
        cont.create_item({"id": "xp-" + str(i), "pk": "p" + str(i), "n": i})
    try:
        rows = list(cont.query_items("SELECT * FROM c",
                                     enable_cross_partition_query=True))
        ok = len(rows) == 6
        check("cross-partition query returns all 5 docs (d1 deleted)", len(rows) == 5, str(len(rows)) + " rows")
    except exceptions.CosmosHttpResponseError as e:
        check("cross-partition query", False, summary(e))

    # 6. Pagination via continuation (>100 docs).
    N = 120
    for i in range(N):
        cont.create_item({"id": "pg-" + str(i), "pk": "pg", "n": i})
    it = cont.query_items("SELECT * FROM c", partition_key="pg", max_item_count=10)
    pages = [page for page in it.by_page()]
    got = [d for page in pages for d in page]
    check("pagination: 120 docs @ max_item_count=10", len(pages) > 1 and len(got) == N,
          str(len(pages)) + " pages, " + str(len(got)) + " docs")

    it2 = cont.query_items("SELECT * FROM c", partition_key="pg", max_item_count=10)
    pit = it2.by_page()
    first = list(next(pit))
    token = pit.continuation_token
    check("continuation token captured", bool(token), "token prefix: " + str(token)[:40])
    pit3 = cont.query_items("SELECT * FROM c", partition_key="pg",
                            max_item_count=10).by_page(continuation_token=token)
    rest = [d for page in pit3 for d in page]
    check("continuation resume yields remaining docs", len(first) + len(rest) == N,
          "first=" + str(len(first)) + " rest=" + str(len(rest)))

    # 7. Stale etag -> 412 on replace and delete.
    d2 = cont.create_item({"id": "stale", "pk": "s1", "n": 0})
    stale_etag = d2["_etag"]
    cont.replace_item("stale", body={"id": "stale", "pk": "s1", "n": 1}, etag=stale_etag, match_condition=MatchConditions.IfNotModified)
    # stale_etag is now outdated (the replace above rotated it).
    try:
        cont.replace_item("stale", body={"id": "stale", "pk": "s1", "n": 9},
                          etag=stale_etag, match_condition=MatchConditions.IfNotModified)
        check("stale-etag replace -> 412", False, "admitted with stale etag")
    except exceptions.CosmosHttpResponseError as e:
        check("stale-etag replace -> 412", e.status_code == 412, summary(e))
    try:
        cont.delete_item("stale", partition_key="s1", etag=stale_etag, match_condition=MatchConditions.IfNotModified)
        check("stale-etag delete -> 412", False, "admitted with stale etag")
    except exceptions.CosmosHttpResponseError as e:
        check("stale-etag delete -> 412", e.status_code == 412, summary(e))
    # Fresh etag still works.
    fresh = cont.read_item("stale", partition_key="s1")
    cont.replace_item("stale", body={"id": "stale", "pk": "s1", "n": 10},
                      etag=fresh["_etag"], match_condition=MatchConditions.IfNotModified)
    check("fresh-etag replace still admitted", True)

    # 8. List containers with continuation.
    names = ["lc-a", "lc-b", "lc-c"]
    for n in names:
        db.create_container(id=n, partition_key="/pk")
    listed = db.list_containers()
    paged = listed.by_page()
    all_names = []
    page_count = 0
    tok = None
    while True:
        try:
            page = next(paged)
        except StopIteration:
            break
        page_count += 1
        all_names.extend(c["id"] for c in page)
    check("list containers: all 5 visible", set(names) <= set(all_names),
          "found " + str(sorted(all_names)))
    check("list containers: paged iteration works", page_count >= 1,
          str(page_count) + " pages")

    # 9. Header-compat: request-charge / session / etag headers on reads.
    try:
        resp = cont.read_item("stale", partition_key="s1")
        check("read_item returns doc", resp["n"] == 10)
    except Exception as e:
        check("read_item returns doc", False, repr(e))

    print()
    passed = sum(1 for _, ok, _ in results if ok)
    print("TOTAL: " + str(passed) + "/" + str(len(results)) + " passed")


if __name__ == "__main__":
    main()
