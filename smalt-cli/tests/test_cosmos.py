"""CLI-4 cosmos lane: SQL whitelist gate (SELECT * FROM c only), stale-etag
412s, continuation >100 docs. Mirrors test/sdk-python/py_cosmos.py.
"""
import secrets

import pytest
from azure.core import MatchConditions
from azure.cosmos import exceptions
from azure.cosmos.partition_key import PartitionKey

pytestmark = [pytest.mark.anonymous, pytest.mark.usefixtures("anonymous_substrate")]

from conftest import cosmos_client

DB_ID = "cli4cosmos-" + secrets.token_hex(4)


@pytest.fixture(scope="module")
def container():
    client = cosmos_client()
    db = client.create_database(DB_ID)
    cont = db.create_container(id="c1", partition_key=PartitionKey(path="/pk"))
    yield cont
    try:
        client.delete_database(DB_ID)
    except Exception:
        pass


def test_whitelist_admits_select_star(container):
    rows = list(container.query_items("SELECT * FROM c", partition_key="w1"))
    assert isinstance(rows, list)


def test_whitelist_admits_root_alias(container):
    # Substrate gate is `SELECT * FROM <alias>` (cosmos.ex @sql_whitelist):
    # `root` is a valid alias, so this is ADMITTED — the repo probe
    # py_cosmos.py's expected-400 for "SELECT * FROM root" is stale.
    rows = list(container.query_items("SELECT * FROM root", partition_key="w1"))
    assert isinstance(rows, list)


@pytest.mark.parametrize("sql", [
    "SELECT VALUE c.n FROM c",
    "SELECT * FROM c WHERE BOGUS(",
    "SELECT * FROM a JOIN b",
])
def test_whitelist_refuses_grammar_external_queries_400(container, sql):
    # Only `SELECT * FROM <alias>` rides the fast path; other queries are
    # parsed by Smalt.CosmosSql (cosmos.ex do_query_docs). PREMISE CORRECTED
    # (BK-149C, live probe 2026-10-22): valid queries the parser now admits
    # (VALUE/OFFSET-LIMIT/TOP/projections) answer 200 — see
    # test_offset_limit_pair_admitted_200 and
    # test_cosmos_sql_evaluates_non_star_queries_200. Only genuine grammar
    # violations (VALUE projection, malformed WHERE/JOIN) still answer typed
    # 400 SyntaxError. A prior param row (" CosmosDB") was a corrupted
    # remnant, not a query.
    with pytest.raises(exceptions.CosmosHttpResponseError) as ei:
        list(container.query_items(sql))
    assert ei.value.status_code == 400, (sql, ei.value.status_code)


def test_offset_limit_pair_admitted_200(container):
    # Premise rot (KD-ROT class): Smalt.CosmosSql now admits the real-Cosmos
    # pair form OFFSET <n> LIMIT <m> (cosmos_sql.ex:962), so a valid pair is
    # 200 with paginated rows — not the typed 400 the old whitelist pinned.
    container.create_item({"id": "off-1", "pk": "off", "n": 1})
    container.create_item({"id": "off-2", "pk": "off", "n": 2})
    rows = list(container.query_items(
        "SELECT * FROM c OFFSET 1 LIMIT 1", partition_key="off"))
    assert len(rows) == 1, rows


def test_cosmos_sql_evaluates_non_star_queries_200(container):
    # GAP(cosmos-sql-translator-absent) closure: valid non-star queries are
    # parsed by Smalt.CosmosSql and answered — 200 with real evaluated
    # results, WHERE actually filters (premise rot fix, i11 receipt).
    container.create_item({"id": "sql-1", "pk": "sq", "n": 1})
    container.create_item({"id": "sql-2", "pk": "sq", "n": 2})
    rows = list(container.query_items("SELECT * FROM c WHERE c.n = 2",
                                      partition_key="sq"))
    assert [r["id"] for r in rows] == ["sql-2"], rows
    proj = list(container.query_items("SELECT c.id FROM c", partition_key="sq"))
    assert sorted(r["id"] for r in proj) == ["sql-1", "sql-2"], proj


def test_item_crud_and_stale_etag_412(container):
    d = container.create_item({"id": "e1", "pk": "s1", "n": 0})
    etag = d["_etag"]
    container.replace_item("e1", body={"id": "e1", "pk": "s1", "n": 1},
                           etag=etag, match_condition=MatchConditions.IfNotModified)
    # etag is now stale
    with pytest.raises(exceptions.CosmosHttpResponseError) as ei:
        container.replace_item("e1", body={"id": "e1", "pk": "s1", "n": 9},
                               etag=etag, match_condition=MatchConditions.IfNotModified)
    assert ei.value.status_code == 412, ei.value.status_code
    with pytest.raises(exceptions.CosmosHttpResponseError) as ei:
        container.delete_item("e1", partition_key="s1", etag=etag,
                              match_condition=MatchConditions.IfNotModified)
    assert ei.value.status_code == 412, ei.value.status_code
    fresh = container.read_item("e1", partition_key="s1")
    container.replace_item("e1", body={"id": "e1", "pk": "s1", "n": 10},
                           etag=fresh["_etag"],
                           match_condition=MatchConditions.IfNotModified)


def test_continuation_over_100_docs(container):
    N = 120
    for i in range(N):
        container.create_item({"id": f"pg-{i}", "pk": "pg", "n": i})
    it = container.query_items("SELECT * FROM c", partition_key="pg",
                               max_item_count=10)
    pages = list(it.by_page())
    got = [d for page in pages for d in page]
    assert len(pages) > 1, len(pages)
    assert len(got) == N, len(got)

    it2 = container.query_items("SELECT * FROM c", partition_key="pg",
                                max_item_count=10).by_page()
    first = list(next(it2))
    token = it2.continuation_token
    assert token
    rest = [d for page in container.query_items(
        "SELECT * FROM c", partition_key="pg", max_item_count=10
    ).by_page(continuation_token=token) for d in page]
    assert len(first) + len(rest) == N, (len(first), len(rest))
