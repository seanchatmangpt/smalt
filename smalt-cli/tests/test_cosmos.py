"""CLI-4 cosmos lane: SQL whitelist gate (SELECT * FROM c only), stale-etag
412s, continuation >100 docs. Mirrors test/sdk-python/py_cosmos.py.
"""
import secrets

import pytest
from azure.core import MatchConditions
from azure.cosmos import exceptions

pytestmark = [pytest.mark.anonymous, pytest.mark.usefixtures("anonymous_substrate")]

from conftest import cosmos_client

DB_ID = "cli4cosmos-" + secrets.token_hex(4)


@pytest.fixture(scope="module")
def container():
    client = cosmos_client()
    db = client.create_database(DB_ID)
    cont = db.create_container(id="c1", partition_key="/pk")
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
    "SELECT c.id FROM c",
    "SELECT * FROM c WHERE c.n = 2",
    "SELECT VALUE c.n FROM c",
    " CosmosDB",
    "SELECT * FROM c OFFSET 1 LIMIT 1",
])
def test_whitelist_refuses_non_star_queries_400(container, sql):
    with pytest.raises(exceptions.CosmosHttpResponseError) as ei:
        list(container.query_items(sql))
    assert ei.value.status_code == 400, (sql, ei.value.status_code)


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
