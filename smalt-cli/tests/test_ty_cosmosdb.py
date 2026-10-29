"""azcli3 Typer lane — cosmosdb group court (real wire).

Doc CRUD + If-Match ETag-CAS: stale etag replace must ANDON with 412.
"""
import time
import uuid

import pytest
from typer.testing import CliRunner

pytestmark = [pytest.mark.anonymous, pytest.mark.usefixtures("anonymous_substrate")]

import conftest  # noqa: E402
from smalt_cli.cli import app  # noqa: E402

runner = CliRunner()
UNIQ = f"ty{int(time.time() * 1000)}{uuid.uuid4().hex[:6]}"
DB, COLL = f"tydb{UNIQ}", f"tycol{UNIQ}"


@pytest.fixture(scope="module", autouse=True)
def _env():
    import os
    os.environ["SMALT_EGRESS"] = conftest.ANON_EGRESS
    os.environ["SMALT_ARM"] = conftest.ANON_ARM
    yield
    del os.environ["SMALT_EGRESS"]


@pytest.fixture(scope="module", autouse=True)
def _db(_env):
    r = runner.invoke(app, ["cosmosdb", "database-create", DB, "-o", "json"])
    assert r.exit_code == 0, r.output
    r = runner.invoke(app, ["cosmosdb", "container-create", DB, COLL,
                            "--partition-key", "/pk", "-o", "json"])
    assert r.exit_code == 0, r.output


DOC = {"id": "doc1", "pk": "p1", "balance": 10}


def _put_doc(doc, extra=()):
    args = ["cosmosdb", "doc-replace", DB, COLL, doc["id"],
            __import__("json").dumps(doc), *extra, "-o", "json"]
    return runner.invoke(app, args)


def test_doc_crud():
    r = runner.invoke(app, ["cosmosdb", "doc-put", DB, COLL, "doc1",
                            __import__("json").dumps(DOC), "-o", "json"])
    assert r.exit_code == 0, r.output
    etag = __import__("json").loads(r.output)["_etag"]
    assert etag

    r = runner.invoke(app, ["cosmosdb", "doc-get", DB, COLL, "doc1", "-o", "json"])
    assert r.exit_code == 0, r.output
    assert __import__("json").loads(r.output)["balance"] == 10

    # CAS: replace with the CURRENT etag succeeds and mints a new etag.
    r = _put_doc({"id": "doc1", "pk": "p1", "balance": 11},
                 ("--if-match", etag))
    assert r.exit_code == 0, r.output
    etag2 = __import__("json").loads(r.output)["_etag"]
    assert etag2 != etag

    # CAS: the now-STALE etag must 412 -> ANDON exit 1.
    r = _put_doc({"id": "doc1", "pk": "p1", "balance": 12},
                 ("--if-match", etag))
    assert r.exit_code == 1, r.output
    assert "ANDON" in r.output
    assert "412" in r.output

    r = runner.invoke(app, ["cosmosdb", "doc-delete", DB, COLL, "doc1", "-o", "json"])
    assert r.exit_code == 0, r.output
    r = runner.invoke(app, ["cosmosdb", "doc-get", DB, COLL, "doc1"])
    assert r.exit_code == 1  # 404 ANDON after delete
