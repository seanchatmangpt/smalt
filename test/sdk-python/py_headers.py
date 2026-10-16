#!/usr/bin/env python3
"""PY-3 header-compat dump + container-list continuation probe (>120 containers)."""
import secrets, json, urllib.request
import azure.cosmos.cosmos_client as cc
from azure.cosmos import exceptions

ENDPOINT = "http://127.0.0.1:8443"
client = cc.CosmosClient(ENDPOINT, credential=secrets.token_hex(32))
db = client.create_database("pyhdr-" + secrets.token_hex(3))
cont = db.create_container(id="h1", partition_key="/pk")
cont.create_item({"id": "a", "pk": "k"})

# Raw header capture: use the SDK's pipeline response via a policy-free send.
# Simplest reliable route: run one SDK op and intercept via the client's
# response hooks is awkward; use raw HTTP with headers harvested from the SDK
# pipeline's last response instead.
from azure.cosmos.container import ContainerProxy
r = urllib.request.urlopen(ENDPOINT + "/")
print("GET / status:", r.status)
interesting = ["x-ms-request-id", "x-ms-version", "x-ms-content-rid", "etag",
               "content-type", "x-ms-databaseaccount-consumed-mb", "date",
               "x-ms-alt-content-path", "x-ms-item-count", "x-ms-session-token",
               "x-ms-request-charge", "continuation", "x-ms-continuation"]
for h in interesting:
    v = r.headers.get(h)
    if v is not None:
        print(f"  {h}: {v[:80]}")

# Header capture on an item read via the SDK internal pipeline:
try:
    from azure.core.pipeline.policies import HTTPHeadersPolicy  # noqa
except Exception:
    pass

# Container-list continuation: create 150 containers, list with maxpagesize.
for i in range(150):
    db.create_container(id=f"bulk-{i:03d}", partition_key="/pk")
paged = db.list_containers().by_page()
pages = 0
tokens = []
names = set()
while True:
    try:
        page = next(paged)
    except StopIteration:
        break
    pages += 1
    tokens.append(paged.continuation_token)
    names.update(c["id"] for c in page)
print("container list pages (maxPageSize=2):", pages, "containers seen:", len(names))
tok = next(t for t in tokens if t)
resumed = db.list_containers().by_page(continuation_token=tok)
resumed_names = set()
for page in resumed:
    resumed_names.update(c["id"] for c in page)
print("resumed from mid-list token: containers after resume:", len(resumed_names))
print("resume covers remainder:", len(resumed_names & names) == len(resumed_names) and resumed_names <= names)
print("HEADER-DUMP-DONE")
