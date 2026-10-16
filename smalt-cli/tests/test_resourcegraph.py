"""CLI-4 resourcegraph lane: query + skipToken pagination + wire-level
string-subscriptions typed 400. Mirrors test/sdk-python/py_resourcegraph_monitor.py.
"""
import pytest
from azure.core.credentials import AccessToken
from azure.core.exceptions import HttpResponseError
from azure.mgmt.resourcegraph import ResourceGraphClient
from azure.mgmt.resourcegraph.models import QueryRequest, QueryRequestOptions

pytestmark = [pytest.mark.enforce, pytest.mark.usefixtures("enforce_substrate")]

import conftest
from conftest import bearer, http, sts_token

RG_API = "2022-10-01"


class StsCredential:
    def get_token(self, *scopes, **kwargs):
        token, claims = sts_token()
        return AccessToken(token, claims["exp"] - 300)


def rg_client():
    return ResourceGraphClient(credential=StsCredential(), base_url=conftest.EGRESS,
                               api_version=RG_API)


def test_query_and_skiptoken_pagination(seeded_resources):
    client = rg_client()
    names, pages, token = [], 0, None
    while True:
        pages += 1
        opts = QueryRequestOptions(top=2)
        if token:
            opts.skip_token = token
        req = QueryRequest(subscriptions=["sub-cli4"], query="project name",
                           options=opts)
        resp = client.resources(req, enforce_https=False)
        page_names = [r["name"] for r in resp.data]
        assert page_names, f"empty page {pages}"
        names.extend(page_names)
        token = resp.skip_token
        if not token:
            break
        assert pages < 20, "pagination did not terminate"
    assert len(names) == len(seeded_resources), names
    assert len(set(names)) == len(names), "duplicate names across pages"


def test_default_top_100_with_skip_token(seeded_resources):
    client = rg_client()
    req = QueryRequest(subscriptions=["sub-cli4"], query="project name")
    resp = client.resources(req, enforce_https=False)
    assert resp.count == len(seeded_resources)
    assert resp.total_records == len(seeded_resources)
    # fewer than 100 resources: no skipToken expected
    assert not resp.skip_token


def test_string_subscriptions_typed_400(seeded_resources):
    """SDK types refuse a bare string client-side; the server's typed 400 is
    exercised at the wire level (py7 p04b pattern)."""
    st, body = http("POST",
                    f"{conftest.EGRESS}/providers/Microsoft.ResourceGraph/resources"
                    f"?api-version={RG_API}",
                    {"subscriptions": "sub-cli4", "query": "project name"},
                    bearer())
    assert st == 400, (st, body)
    assert body["error"]["code"] == "InvalidParameter", body
